//! Disk widget: the free space of the file systems, from statvfs(3). The
//! text is the smallest free space, the tooltip has a line for each file
//! system. It shows only when a disk is full enough or the free space is
//! low.
//!
//! With a `path`, the widget reads only the file system of that path.
//! Without it, the widget reads all the mounted file systems on a block
//! device or in a ZFS pool, but not the boot partition. Refer to storage.zig.
//!
//! The approach follows w_dysk.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const common = @import("common.zig");
const ctx = common.ctx;
const storage = @import("storage.zig");

const log = std.log.scoped(.disk);

// glibc on 64-bit Linux.
const Statvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [6]c_int,
};
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

/// kwm reads not more file systems.
const max_file_systems = 32;
const max_path = std.fs.max_path_bytes;
/// The maximum length of the key of a file system. Refer to Found.
const max_key = 256;


pub fn update(cfg: anytype, out: *common.Output) !void {
    var usages: [max_file_systems]storage.Usage = undefined;
    const count = if (cfg.path) |path| one: {
        usages[0] = try usage(path);
        break :one 1;
    } else try mounted_usages(&usages);

    const sum = storage.summary(usages[0..count]) orelse {
        out.hidden = true;
        return;
    };
    mem.sort(storage.Usage, usages[0..count], {}, storage.less_than);

    const alert = sum.low(cfg.alert);
    out.hidden = !sum.shown(cfg.show, cfg.alert);

    const critical = ctx.cfg.bar.widget_colors.critical;
    var buffer: [32]u8 = undefined;
    try common.append_colored(
        &out.text,
        if (alert) critical else null,
        try fmt.bufPrint(&buffer, "{}G", .{ sum.free / storage.gb }),
    );

    for (usages[0..count], 0..) |*u, i| {
        if (i > 0) try out.tooltip.append(ctx.gpa, '\n');
        if (u.free < cfg.alert) try out.tooltip.print(ctx.gpa, "^#{x:0>8}", .{ critical });
        try out.tooltip.print(ctx.gpa, "{f}", .{ u });
    }
}


fn usage(mount_point: []const u8) !storage.Usage {
    var path_buffer: [max_path]u8 = undefined;
    const path = try fmt.bufPrintZ(&path_buffer, "{s}", .{ mount_point });
    var st: Statvfs = undefined;
    if (statvfs(path.ptr, &st) != 0) return error.Statvfs;
    return .init(
        mount_point,
        st.blocks * st.frsize,
        st.bavail * st.frsize,
        (st.blocks -| st.bfree) * st.frsize,
    );
}


/// A file system of /proc/self/mounts. A file system can have more mount
/// points (bind mounts, ZFS datasets): the widget shows the shortest one.
const Found = struct {
    /// The block device ("/dev/dm-0"), or "zfs:" and the pool.
    key_buffer: [max_key]u8 = undefined,
    key_len: usize = 0,
    target_buffer: [max_path]u8 = undefined,
    target_len: usize = 0,

    fn key(self: *const Found) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    fn target(self: *const Found) []const u8 {
        return self.target_buffer[0..self.target_len];
    }
};


/// Write the usage of the mounted file systems into `usages`. Return their
/// number. Refer to storage.source_of.
fn mounted_usages(usages: []storage.Usage) !usize {
    const text = try common.read_file_alloc(ctx.gpa, "/proc/self/mounts", 1 << 20);
    defer ctx.gpa.free(text);

    var found: [max_file_systems]Found = undefined;
    var found_count: usize = 0;
    var lines = mem.splitScalar(u8, text, '\n');
    next: while (lines.next()) |line| {
        const m = storage.parse_mount(line) orelse continue;
        var key_buffer: [max_key]u8 = undefined;
        const key = switch (storage.source_of(m)) {
            .none => continue,
            .device => |path| device_key(path, &key_buffer) orelse continue,
            .zfs => |pool| fmt.bufPrint(&key_buffer, "zfs:{s}", .{ pool }) catch continue,
        };
        var target_buffer: [max_path]u8 = undefined;
        const target = storage.unescape(m.target, &target_buffer);

        for (found[0..found_count]) |*f| {
            if (!mem.eql(u8, f.key(), key)) continue;
            if (target.len < f.target_len) {
                @memcpy(f.target_buffer[0..target.len], target);
                f.target_len = target.len;
            }
            continue :next;
        }

        if (found_count == found.len) break;

        const f = &found[found_count];
        found_count += 1;
        f.* = .{ .key_len = key.len, .target_len = target.len };
        @memcpy(f.key_buffer[0..key.len], key);
        @memcpy(f.target_buffer[0..target.len], target);
    }

    var count: usize = 0;
    for (found[0..found_count]) |*f| {
        usages[count] = usage(f.target()) catch |err| {
            log.debug("statvfs {s} failed: {}", .{ f.target(), err });
            continue;
        };
        count += 1;
    }
    return count;
}


/// The key of a block device: its path without links ("/dev/dm-0"). Two
/// paths of one device give one key. When kwm cannot read the links, the key
/// is `path`. null: the key is too long.
fn device_key(path: []const u8, buffer: []u8) ?[]const u8 {
    var real_buffer: [max_path]u8 = undefined;
    const real = real_path(path, &real_buffer) orelse path;
    if (real.len > buffer.len) return null;
    @memcpy(buffer[0..real.len], real);
    return buffer[0..real.len];
}


/// The path without links, or null.
fn real_path(path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    var path_buffer: [max_path]u8 = undefined;
    const path_z = fmt.bufPrintZ(&path_buffer, "{s}", .{ path }) catch return null;
    const real = std.c.realpath(path_z.ptr, buffer) orelse return null;
    return mem.span(real);
}
