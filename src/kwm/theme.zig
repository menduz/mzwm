//! The current GTK theme, for the colors of the raised border and of the
//! title bars. Refer to `border.raised.gtk_colors` in the configuration.
//!
//! At the start, the name comes from GTK_THEME. `set_gtk_theme` gives a new
//! name at run time. kwm reads the colors of xfwm4/themerc of that theme
//! (refer to themerc.zig), in the folders where GTK looks for a theme. A
//! themerc is a simple list of keys; the CSS of GTK is not.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.theme);

const posix = @import("posix");
const config = @import("config");

const Context = @import("context.zig");
const themerc = @import("themerc.zig");
const bar_colors = @import("bar_colors.zig");

const ctx = Context.get();

/// The colors of xfwm4/themerc, by key, as 0xRRGGBBAA.
const Colors = std.StringHashMapUnmanaged(u32);

var gtk_theme: ?[]u8 = null;
var colors: Colors = .empty;
/// The colors of other GTK themes, by theme name. The window of a sandbox
/// can have its own GTK_THEME. Refer to sandbox.zig.
var other_themes: std.StringHashMapUnmanaged(Colors) = .empty;


pub fn init() void {
    // GTK_THEME can give a variant after the name: "Name:dark".
    const env = ctx.env.get("GTK_THEME") orelse return;
    const name = env[0 .. mem.indexOfScalar(u8, env, ':') orelse env.len];
    if (name.len == 0) return;

    gtk_theme = ctx.gpa.dupe(u8, name) catch return;
    load(&colors, name);
}


pub fn deinit() void {
    clear_colors(&colors);
    var it = other_themes.iterator();
    while (it.next()) |entry| {
        clear_colors(entry.value_ptr);
        ctx.gpa.free(entry.key_ptr.*);
    }
    other_themes.deinit(ctx.gpa);
    if (gtk_theme) |name| ctx.gpa.free(name);
    gtk_theme = null;
}


/// The GTK theme changed. Read its colors, and draw the borders again.
pub fn set_gtk_theme(name: []const u8) void {
    if (gtk_theme) |current| {
        if (mem.eql(u8, current, name)) return;
    }

    const copy = ctx.gpa.dupe(u8, name) catch |err| {
        log.err("dupe theme name failed: {}", .{ err });
        return;
    };
    if (gtk_theme) |old| ctx.gpa.free(old);
    gtk_theme = copy;

    load(&colors, name);
    ctx.desktop_color_changed();
    if (ctx.cfg.bar.gtk_colors != null or bar_caption()) ctx.bar_colors_changed();
    ctx.manage_dirty(@src());
}


/// The color of the desktop in the current GTK theme: the key
/// `background_gtk_color` of the configuration. null: the theme does not
/// give it. Refer to desktop.zig.
pub fn desktop_color() ?u32 {
    const key = ctx.cfg.background_gtk_color orelse return null;
    return colors.get(key);
}


/// The color of the key `key` in xfwm4/themerc of the current GTK theme.
/// null: the theme does not give it.
pub fn color(key: []const u8) ?u32 {
    return colors.get(key);
}


/// The colors of the bar in `area`, with the colors of the current GTK theme.
/// Refer to bar_colors.zig.
pub fn bar_scheme(area: bar_colors.Bar.BarArea) bar_colors.Bar.Scheme {
    return bar_colors.scheme(&ctx.cfg.bar, area, color);
}


/// The scheme of the bar without `override_colors`, with the colors of the
/// current GTK theme.
pub fn bar_base_scheme() bar_colors.Bar.Scheme {
    return bar_colors.themed(ctx.cfg.bar.scheme, ctx.cfg.bar.gtk_colors, color);
}


/// The colors of the title area of the bar. `name`: the GTK theme of the
/// window, as in its title bar. `focused`: the output has the focus. Refer
/// to `bar.title.caption` in the configuration.
pub fn bar_title(name: ?[]const u8, focused: bool) bar_colors.Caption {
    const caption: ?bar_colors.Caption = if (bar_caption()) blk: {
        const c = title_colors_of(name, focused);
        break :blk .{ .start = c.start, .end = c.end, .fg = c.text };
    } else null;
    return bar_colors.title(bar_scheme(.title), focused, caption);
}


fn bar_caption() bool {
    const area = ctx.cfg.bar.title orelse return false;
    return area.caption;
}


/// The text color of the tags without windows, with the colors of the
/// current GTK theme. null: the color of the scheme.
pub fn bar_empty_fg() ?u32 {
    return bar_colors.empty_fg(&ctx.cfg.bar, color);
}


/// The colors of a raised border for the current GTK theme.
pub fn bevel(focused: bool) config.Bevel {
    return bevel_of(null, focused);
}


/// The colors of a raised border for the GTK theme `name`. null: the current
/// GTK theme.
pub fn bevel_of(name: ?[]const u8, focused: bool) config.Bevel {
    const raised = &ctx.cfg.border.raised;
    var result = if (focused) raised.focus else raised.unfocus;

    const names = raised.gtk_colors orelse return result;
    const map = colors_of(name);
    result.face = map.get(names.face) orelse result.face;
    result.highlight = map.get(names.highlight) orelse result.highlight;
    result.shadow = map.get(names.shadow) orelse result.shadow;
    result.frame = map.get(names.frame) orelse result.frame;
    if (if (focused) names.focus_outline else names.unfocus_outline) |color_name| {
        result.outline = map.get(color_name) orelse result.outline;
    }
    return result;
}


/// The colors of the title bar of win-classic-theme. Refer to decoration.zig
/// and title_bar.zig.
pub const TitleColors = struct {
    /// The caption: a gradient from `start` at the left to `end` at the
    /// right.
    start: u32,
    end: u32,
    text: u32,
    /// The glyph of the close button (ControlText).
    button_text: u32,
};


/// The title bar colors of the GTK theme `name`. null: the current GTK theme.
/// Without a theme, the colors of the Windows Standard scheme.
pub fn title_colors_of(name: ?[]const u8, focused: bool) TitleColors {
    const map = colors_of(name);
    const button_text = map.get("buttons_color") orelse 0x000000ff;
    if (focused) {
        const start = map.get("active_color_1") orelse 0x000080ff;
        return .{
            .start = start,
            // A theme without the gradient color has a caption of one color.
            .end = map.get("active_gradient_color") orelse
                if (map.contains("active_color_1")) start else 0x1084d0ff,
            .text = map.get("active_text_color") orelse 0xffffffff,
            .button_text = button_text,
        };
    }
    const start = map.get("inactive_color_1") orelse 0x808080ff;
    return .{
        .start = start,
        .end = map.get("inactive_gradient_color") orelse start,
        .text = map.get("inactive_text_color") orelse 0xc0c0c0ff,
        .button_text = button_text,
    };
}


/// The colors of the GTK theme `name`. kwm reads a theme other than the
/// current theme one time, and keeps its colors.
fn colors_of(name: ?[]const u8) *const Colors {
    const theme_name = name orelse return &colors;
    if (gtk_theme) |current| {
        if (mem.eql(u8, current, theme_name)) return &colors;
    }
    if (other_themes.getPtr(theme_name)) |map| return map;

    const owned = ctx.gpa.dupe(u8, theme_name) catch return &colors;
    const entry = other_themes.getOrPut(ctx.gpa, owned) catch {
        ctx.gpa.free(owned);
        return &colors;
    };
    entry.value_ptr.* = .empty;
    load(entry.value_ptr, theme_name);
    return entry.value_ptr;
}


fn clear_colors(map: *Colors) void {
    var it = map.keyIterator();
    while (it.next()) |key| ctx.gpa.free(key.*);
    map.clearAndFree(ctx.gpa);
}


/// Read the colors of the theme `name` into `map`: the colors of its
/// xfwm4/themerc. Refer to themerc.zig. Without the file, the borders and the
/// title bars use the colors of the configuration and of Windows Standard.
fn load(map: *Colors, name: []const u8) void {
    clear_colors(map);

    var buffer: [64 * 1024]u8 = undefined;
    const text = read_theme_file(name, &buffer) orelse {
        log.warn("GTK theme {s}: no xfwm4/themerc found", .{ name });
        return;
    };

    var it = themerc.iterate(text);
    while (it.next()) |entry| {
        const owned = ctx.gpa.dupe(u8, entry.key) catch continue;
        const slot = map.getOrPut(ctx.gpa, owned) catch {
            ctx.gpa.free(owned);
            continue;
        };
        if (slot.found_existing) ctx.gpa.free(owned);
        slot.value_ptr.* = entry.color;
    }
    log.info("GTK theme {s}: {} colors", .{ name, map.count() });
}


/// Find xfwm4/themerc of the theme in the folders that GTK searches for the
/// theme.
fn read_theme_file(name: []const u8, buffer: []u8) ?[]const u8 {
    const home = ctx.env.get("HOME") orelse "";
    var path_buffer: [4096]u8 = undefined;

    // $XDG_DATA_HOME/themes, ~/.themes, then $XDG_DATA_DIRS/themes.
    const data_home = ctx.env.get("XDG_DATA_HOME");
    if (data_home) |dir| {
        if (read_file(&path_buffer, buffer, dir, "/themes", name)) |text| return text;
    } else {
        if (read_file(&path_buffer, buffer, home, "/.local/share/themes", name)) |text| return text;
    }
    if (read_file(&path_buffer, buffer, home, "/.themes", name)) |text| return text;

    const data_dirs = ctx.env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var dirs = mem.tokenizeScalar(u8, data_dirs, ':');
    while (dirs.next()) |dir| {
        if (read_file(&path_buffer, buffer, dir, "/themes", name)) |text| return text;
    }
    return null;
}


fn read_file(path_buffer: []u8, buffer: []u8, dir: []const u8, sub: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const path = fmt.bufPrintZ(path_buffer, "{s}{s}/{s}/xfwm4/themerc", .{ dir, sub, name }) catch return null;

    const fd = posix.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer posix.close(fd);

    var len: usize = 0;
    while (len < buffer.len) {
        const n = posix.read(fd, buffer[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    log.debug("read {s}", .{ path });
    return buffer[0..len];
}
