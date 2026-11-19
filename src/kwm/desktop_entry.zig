//! The keys of a desktop entry (a .desktop file of the XDG Desktop Entry
//! specification) that give the icon of a program: Icon, and
//! StartupWMClass to find the entry of a window when its app_id is not the
//! name of the file. Only the group [Desktop Entry] is read. A localized key
//! ("Icon[de]") is not used. icons.zig reads the files. `zig build test`
//! runs the tests below.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


/// The value of Icon: a name of the icon theme, or an absolute path. null:
/// no icon.
pub fn icon(text: []const u8) ?[]const u8 {
    return value(text, "Icon");
}


/// The value of StartupWMClass. null: the entry does not give it.
pub fn startup_wm_class(text: []const u8) ?[]const u8 {
    return value(text, "StartupWMClass");
}


/// The value of `key` in the group [Desktop Entry]. null: no key, or an
/// empty value.
fn value(text: []const u8, key: []const u8) ?[]const u8 {
    var in_entry = false;
    var lines = mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!mem.eql(u8, mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const v = mem.trim(u8, line[eq + 1 ..], " \t");
        return if (v.len > 0) v else null;
    }
    return null;
}


/// The names of the desktop entry of `app_id`, in the order to try, without
/// ".desktop": the app_id, and the app_id in lower case when it has capital
/// letters (the class of an X11 window, as "KeePassXC"). `buffer` holds the
/// name in lower case.
pub fn file_names(app_id: []const u8, buffer: []u8) struct { [2][]const u8, usize } {
    if (app_id.len == 0) return .{ .{ "", "" }, 0 };
    if (app_id.len > buffer.len) return .{ .{ app_id, "" }, 1 };
    const lower = std.ascii.lowerString(buffer, app_id);
    if (mem.eql(u8, lower, app_id)) return .{ .{ app_id, "" }, 1 };
    return .{ .{ app_id, lower }, 2 };
}


test "icon: the key of the group Desktop Entry" {
    const text =
        \\# A comment
        \\[Desktop Entry]
        \\Name=Ghostty
        \\Icon[de]=other
        \\Icon = com.mitchellh.ghostty
        \\StartupWMClass=com.mitchellh.ghostty
        \\
        \\[Desktop Action new-window]
        \\Icon=new-window
    ;
    try testing.expectEqualStrings("com.mitchellh.ghostty", icon(text).?);
    try testing.expectEqualStrings("com.mitchellh.ghostty", startup_wm_class(text).?);
}

test "icon: not in an other group, not empty" {
    const text =
        \\[Desktop Action new-window]
        \\Icon=new-window
        \\StartupWMClass=
        \\[Desktop Entry]
        \\Name=Thing
        \\StartupWMClass=
    ;
    try testing.expectEqual(@as(?[]const u8, null), icon(text));
    try testing.expectEqual(@as(?[]const u8, null), startup_wm_class(text));
}

test "icon: an absolute path" {
    try testing.expectEqualStrings("/opt/app/icon.png", icon("[Desktop Entry]\r\nIcon=/opt/app/icon.png\r\n").?);
}

test "file_names: the app_id, then in lower case" {
    var buffer: [64]u8 = undefined;
    const names, const n = file_names("KeePassXC", &buffer);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("KeePassXC", names[0]);
    try testing.expectEqualStrings("keepassxc", names[1]);

    const same, const one = file_names("firefox", &buffer);
    try testing.expectEqual(@as(usize, 1), one);
    try testing.expectEqualStrings("firefox", same[0]);

    _, const none = file_names("", &buffer);
    try testing.expectEqual(@as(usize, 0), none);
}
