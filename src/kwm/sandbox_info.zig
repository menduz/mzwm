//! The tooltip of the name of a sandbox: on the label of a window
//! (sandbox_label.zig), in a title bar and in the bar. It shows:
//!
//! - The capabilities that the sandbox allows, from its block in
//!   sandbox.config_path: the true options ("gui", "nvidia"), the access
//!   modes that are not "none" ("ssh read", "zed write"), and the lists
//!   ("paths: ~/code"). The values that only describe the sandbox (color,
//!   theme, files, environment) do not show.
//! - The mount points of the program of the window, from
//!   /proc/<pid>/mountinfo, as a tree sorted by path. Each mount shows its
//!   path below the mount that contains it, "ro" for a read-only mount, and
//!   the type of a file system that is not on a device (tmpfs, proc).
//!   The mounts of a gVisor sandbox are inside the gVisor kernel: kwm cannot
//!   see them.
//!
//! `zig build test` runs the tests below.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const testing = std.testing;

const sandbox = @import("sandbox.zig");
const common = @import("widgets/common.zig");
const Context = @import("context.zig");

const ctx = Context.get();


/// The width of a line of the capabilities, in characters. A longer list
/// continues on the next line.
const line_width = 64;

/// The keys of a sandbox block that do not give a capability.
const skipped_keys = [_][]const u8{
    "backend",        "backendArgs", "bin",         "color",
    "configMounts",   "description", "env",         "files",
    "gtkTheme",       "homeDirectory", "homePatterns", "hostname",
    "opensnitch",     "passEnv",     "socksProxy",
    // These limit the sandbox.
    "cleanTmp",       "disableNetworking", "privacyFilter",
};


/// Write the tooltip of the sandbox `name`: its capabilities from the JSON
/// text `config` (null: no configuration file), then the mount points of
/// `mountinfo` (null: kwm cannot see the mounts, `no_mounts` tells why).
pub fn write(
    allocator: mem.Allocator,
    w: *Io.Writer,
    name: []const u8,
    config: ?[]const u8,
    mountinfo: ?[]const u8,
    no_mounts: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const environment = if (config) |text| environment_of(a, text, name) else null;
    if (environment) |env| {
        try write_capabilities(a, w, name, env);
    } else {
        try w.print("{s}\n", .{ name });
    }

    try w.writeAll("\nmounts:");
    if (mountinfo) |text| {
        try w.writeByte('\n');
        try write_mounts(a, w, text);
    } else {
        try w.print(" {s}", .{ no_mounts });
    }
}


/// Write the tooltip of a window of the sandbox `name`, whose client is the
/// process `pid`.
pub fn write_of_process(allocator: mem.Allocator, w: *Io.Writer, name: []const u8, pid: i32) !void {
    const config: ?[]u8 = common.read_file_alloc(allocator, sandbox.config_path, 1 << 20) catch null;
    defer if (config) |c| allocator.free(c);

    var mountinfo: ?[]u8 = null;
    defer if (mountinfo) |m| allocator.free(m);
    var no_mounts: []const u8 = "";
    mounts: {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        if (config) |c| if (backend(arena.allocator(), c, name)) |b| if (mem.eql(u8, b, "gvisor")) {
            no_mounts = "inside the gVisor kernel, kwm cannot see them";
            break :mounts;
        };
        if (pid <= 0) {
            no_mounts = "unknown, the window gives no process";
            break :mounts;
        }
        if (same_mount_namespace(pid)) {
            no_mounts = "the mounts of the host";
            break :mounts;
        }
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{}/mountinfo", .{ pid }) catch break :mounts;
        mountinfo = common.read_file_alloc(allocator, path, 1 << 20) catch {
            no_mounts = "unknown, the process stopped";
            break :mounts;
        };
    }
    try write(allocator, w, name, config, mountinfo, no_mounts);
}


/// The process `pid` has the mount namespace of kwm. false: an other
/// namespace, or kwm cannot read it.
fn same_mount_namespace(pid: i32) bool {
    var own_buffer: [64]u8 = undefined;
    const own = Io.Dir.readLinkAbsolute(ctx.io, "/proc/self/ns/mnt", &own_buffer) catch return false;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{}/ns/mnt", .{ pid }) catch return false;
    var buffer: [64]u8 = undefined;
    const other = Io.Dir.readLinkAbsolute(ctx.io, path, &buffer) catch return false;
    return mem.eql(u8, own_buffer[0..own], buffer[0..other]);
}


/// The block of the sandbox `name` in the configuration, or null.
fn environment_of(a: mem.Allocator, config: []const u8, name: []const u8) ?std.json.ObjectMap {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, config, .{}) catch return null;
    if (root != .object) return null;
    const environments = root.object.get("environments") orelse return null;
    if (environments != .object) return null;
    const environment = environments.object.get(name) orelse return null;
    return if (environment == .object) environment.object else null;
}


/// The backend of the sandbox `name` in the configuration, for example
/// "gvisor". null: no configuration, or no backend.
pub fn backend(a: mem.Allocator, config: []const u8, name: []const u8) ?[]const u8 {
    const environment = environment_of(a, config, name) orelse return null;
    const value = environment.get("backend") orelse return null;
    return if (value == .string) value.string else null;
}


/// The first lines of the tooltip: the name and the description, the
/// backend, and the capabilities.
fn write_capabilities(a: mem.Allocator, w: *Io.Writer, name: []const u8, env: std.json.ObjectMap) !void {
    if (env.get("description")) |d| if (d == .string and d.string.len > 0) {
        try w.print("{s}: {s}\n", .{ name, d.string });
    } else {
        try w.print("{s}\n", .{ name });
    } else try w.print("{s}\n", .{ name });
    if (env.get("backend")) |b| if (b == .string) try w.print("backend: {s}\n", .{ b.string });

    var allowed: std.ArrayList([]const u8) = .empty;
    var access: std.ArrayList([]const u8) = .empty;
    var lists: std.ArrayList([]const u8) = .empty;

    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (skipped(key)) continue;
        const label = try words(a, key);
        switch (entry.value_ptr.*) {
            .bool => |on| if (on) try allowed.append(a, label),
            .string => |mode| if (mode.len > 0 and !mem.eql(u8, mode, "none")) {
                try access.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ label, mode }));
            },
            .array => |items| {
                var values: std.ArrayList([]const u8) = .empty;
                for (items.items) |item| if (item == .string) try values.append(a, item.string);
                if (values.items.len == 0) continue;
                const joined = try mem.join(a, ", ", values.items);
                try lists.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ label, joined }));
            },
            else => {},
        }
    }
    // An opensnitch block that is on.
    if (env.get("opensnitch")) |o| if (o == .object) if (o.object.get("enable")) |e| {
        if (e == .bool and e.bool) try allowed.append(a, "opensnitch");
    };

    try write_list(w, "allowed: ", allowed.items);
    try write_list(w, "access: ", access.items);
    for (lists.items) |line| try w.print("{s}\n", .{ line });
}


fn skipped(key: []const u8) bool {
    for (skipped_keys) |k| if (mem.eql(u8, k, key)) return true;
    return false;
}


/// "internetAccess" -> "internet access".
fn words(a: mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (key, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) try out.append(a, ' ');
            try out.append(a, std.ascii.toLower(c));
        } else try out.append(a, c);
    }
    return out.items;
}


/// "<title>a, b, c" on lines of `line_width`. The next lines have an indent
/// of two spaces. Nothing for an empty list.
fn write_list(w: *Io.Writer, title: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try w.writeAll(title);
    var column = title.len;
    for (items, 0..) |item, i| {
        const last = i + 1 == items.len;
        const len = item.len + @as(usize, if (last) 0 else 1);
        if (i > 0) {
            if (column + 1 + len > line_width) {
                try w.writeAll("\n  ");
                column = 2;
            } else {
                try w.writeByte(' ');
                column += 1;
            }
        }
        try w.writeAll(item);
        if (!last) try w.writeByte(',');
        column += len;
    }
    try w.writeByte('\n');
}


const Mount = struct {
    path: []const u8,
    read_only: bool,
    /// The file system type, for a file system that is not on a device.
    virtual: ?[]const u8,
};


/// The mount points of `mountinfo` (the text of /proc/<pid>/mountinfo) as a
/// tree, one line for each mount point.
pub fn write_mounts(a: mem.Allocator, w: *Io.Writer, mountinfo: []const u8) !void {
    var mounts: std.ArrayList(Mount) = .empty;
    var lines = mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        const mount = try parse_line(a, line) orelse continue;
        // A later mount on the same path hides the earlier one.
        for (mounts.items) |*m| {
            if (mem.eql(u8, m.path, mount.path)) {
                m.* = mount;
                break;
            }
        } else try mounts.append(a, mount);
    }
    mem.sort(Mount, mounts.items, {}, path_less);

    // The parent of each mount: the nearest mount before it that contains
    // its path. The order of the paths puts the parent before its children.
    const n = mounts.items.len;
    const parents = try a.alloc(?usize, n);
    var stack: std.ArrayList(usize) = .empty;
    for (mounts.items, 0..) |m, i| {
        while (stack.items.len > 0 and !contains(mounts.items[stack.items[stack.items.len - 1]].path, m.path)) {
            _ = stack.pop();
        }
        parents[i] = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
        try stack.append(a, i);
    }

    for (mounts.items, 0..) |m, i| {
        // The lines of the ancestors: "│  " when an ancestor has a next
        // sibling, else spaces. A mount without a parent has no prefix.
        var ancestors: std.ArrayList(usize) = .empty;
        var p = parents[i];
        while (p) |parent| : (p = parents[parent]) try ancestors.append(a, parent);
        // The top ancestor has no line.
        if (ancestors.items.len > 0) {
            var k = ancestors.items.len - 1;
            while (k > 0) : (k -= 1) {
                const ancestor = ancestors.items[k - 1];
                try w.writeAll(if (last_child(parents, ancestor)) "   " else "│  ");
            }
            try w.writeAll(if (last_child(parents, i)) "└─ " else "├─ ");
        }

        const label = if (parents[i]) |parent| relative(mounts.items[parent].path, m.path) else m.path;
        try w.writeAll(label);
        if (m.read_only) try w.writeAll("  ro");
        if (m.virtual) |fstype| try w.print("  {s}", .{ fstype });
        if (i + 1 < n) try w.writeByte('\n');
    }
}


/// No mount after `i` has the parent of `i`.
fn last_child(parents: []const ?usize, i: usize) bool {
    for (parents[i + 1 ..]) |p| {
        if (std.meta.eql(p, parents[i])) return false;
    }
    return true;
}


/// A line of mountinfo: "id parent major:minor root mount_point options
/// [optional fields] - fstype source super_options". null: not a valid line.
fn parse_line(a: mem.Allocator, line: []const u8) !?Mount {
    const separator = mem.indexOf(u8, line, " - ") orelse return null;
    var fields = mem.tokenizeScalar(u8, line[0..separator], ' ');
    for (0..4) |_| _ = fields.next() orelse return null;
    const path = fields.next() orelse return null;
    const options = fields.next() orelse return null;

    var rest = mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
    const fstype = rest.next() orelse return null;
    const source = rest.next() orelse "";

    var read_only = false;
    var it = mem.tokenizeScalar(u8, options, ',');
    while (it.next()) |option| {
        if (mem.eql(u8, option, "ro")) read_only = true;
    }
    return .{
        .path = try unescape(a, path),
        .read_only = read_only,
        .virtual = if (mem.startsWith(u8, source, "/")) null else fstype,
    };
}


/// mountinfo writes a space, a tab, a new line and a backslash in a path
/// as an octal escape: "\040".
fn unescape(a: mem.Allocator, text: []const u8) ![]const u8 {
    if (mem.indexOfScalar(u8, text, '\\') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 4 <= text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 4], 8)) |c| {
                try out.append(a, c);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, text[i]);
    }
    return out.items;
}


/// The order of a tree: "/" comes before the other characters, so a path
/// is right before the paths in it ("/home/a", "/home/a/b", "/home/a-b").
fn path_less(_: void, x: Mount, y: Mount) bool {
    const len = @min(x.path.len, y.path.len);
    for (x.path[0..len], y.path[0..len]) |cx, cy| {
        if (cx == cy) continue;
        if (cx == '/') return true;
        if (cy == '/') return false;
        return cx < cy;
    }
    return x.path.len < y.path.len;
}


/// The mount point `parent` contains the path `path`.
fn contains(parent: []const u8, path: []const u8) bool {
    if (mem.eql(u8, parent, "/")) return path.len > 1;
    return path.len > parent.len and mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}


/// `path` without the mount point `parent` that contains it.
fn relative(parent: []const u8, path: []const u8) []const u8 {
    if (mem.eql(u8, parent, "/")) return path[1..];
    return path[parent.len + 1 ..];
}


test "write_mounts: a tree sorted by path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const mountinfo =
        \\559 67 0:52 /newroot / rw,nosuid - tmpfs tmpfs rw
        \\570 559 0:30 /home/a/code /home/a/code rw,relatime - btrfs /dev/nvme0n1p2 rw
        \\560 559 0:82 / /proc rw,nosuid - proc proc rw
        \\561 559 0:83 / /dev rw,nosuid - tmpfs tmpfs rw
        \\562 561 0:6 /null /dev/null rw,nosuid master:8 - devtmpfs devtmpfs rw
        \\565 559 0:30 /nix/store /nix/store ro,relatime - btrfs /dev/nvme0n1p2 rw
        \\568 559 0:30 /home/a/.local/share/home /home/a rw,relatime - btrfs /dev/nvme0n1p2 rw
        \\569 568 0:30 /home/a/.claude /home/a/.claude rw,relatime - btrfs /dev/nvme0n1p2 rw
        \\571 559 0:30 /home/a-b /home/a-b ro - btrfs /dev/nvme0n1p2 rw
        \\572 559 0:30 /my\040dir /my\040dir ro - btrfs /dev/nvme0n1p2 rw
    ;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write_mounts(arena.allocator(), &out.writer, mountinfo);
    try testing.expectEqualStrings(
        \\/  tmpfs
        \\├─ dev  tmpfs
        \\│  └─ null  devtmpfs
        \\├─ home/a
        \\│  ├─ .claude
        \\│  └─ code
        \\├─ home/a-b  ro
        \\├─ my dir  ro
        \\├─ nix/store  ro
        \\└─ proc  proc
    , out.written());
}

test "write_mounts: a later mount on the same path hides the earlier one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const mountinfo =
        \\1 0 0:1 / / rw - tmpfs tmpfs rw
        \\2 1 0:2 / /tmp rw - tmpfs tmpfs rw
        \\3 1 0:3 /x /tmp ro - ext4 /dev/sda1 rw
    ;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write_mounts(arena.allocator(), &out.writer, mountinfo);
    try testing.expectEqualStrings("/  tmpfs\n└─ tmp  ro", out.written());
}

test "write: the capabilities that the sandbox allows, then the mounts" {
    const config =
        \\{"environments": {"code": {
        \\  "description": "code and editors", "backend": "bwrap", "color": "#008080",
        \\  "gui": true, "audio": false, "internetAccess": true, "cleanTmp": true,
        \\  "dbus": "private", "ssh": "read", "gemini": "none", "zed": "write",
        \\  "paths": ["~/code"], "allowHosts": [], "env": {"A": "b"},
        \\  "opensnitch": {"enable": true}
        \\}}}
    ;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, "code", config, "1 0 0:1 / / rw - tmpfs tmpfs rw", "");
    try testing.expectEqualStrings(
        \\code: code and editors
        \\backend: bwrap
        \\allowed: gui, internet access, opensnitch
        \\access: dbus private, ssh read, zed write
        \\paths: ~/code
        \\
        \\mounts:
        \\/  tmpfs
    , out.written());
}

test "write: a sandbox without configuration, and mounts that kwm cannot see" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, "ai", null, null, "inside gVisor");
    try testing.expectEqualStrings("ai\n\nmounts: inside gVisor", out.written());
}

test "write_list: long lists continue on the next line" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const items = [_][]const u8{ "a" ** 30, "b" ** 30, "c" ** 10 };
    try write_list(&out.writer, "allowed: ", &items);
    try testing.expectEqualStrings("allowed: " ++ "a" ** 30 ++ ",\n  " ++ "b" ** 30 ++ ", " ++ "c" ** 10 ++ "\n", out.written());
}

test "backend: from the block of the sandbox" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("gvisor", backend(arena.allocator(), "{\"environments\": {\"ai\": {\"backend\": \"gvisor\"}}}", "ai").?);
    try testing.expectEqual(@as(?[]const u8, null), backend(arena.allocator(), "{}", "ai"));
}
