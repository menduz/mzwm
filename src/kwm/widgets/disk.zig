//! Disk widget: the free space of the file systems, from statvfs(3). The
//! text is the smallest free space, the tooltip has a line for each file
//! system. It shows only when a disk is full enough or the free space is
//! low.
//!
//! With a `path`, the widget reads only the file system of that path.
//! Without it, the widget reads the file systems on local SSD and NVMe disks.
//! Refer to storage.zig.
//!
//! The approach follows w_dysk.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

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
/// The depth of device-mapper volumes on other volumes.
const max_depth = 4;
const max_path = std.fs.max_path_bytes;


pub fn update(cfg: anytype, out: *common.Output) !void {
    var usages: [max_file_systems]storage.Usage = undefined;
    const count = if (cfg.path) |path| one: {
        usages[0] = try usage(path);
        break :one 1;
    } else try local_usages(&usages);

    const sum = storage.summary(usages[0..count]) orelse {
        out.hidden = true;
        return;
    };
    mem.sort(storage.Usage, usages[0..count], {}, storage.less_than);

    const alert = sum.free < cfg.alert;
    out.hidden = !alert and sum.percent < cfg.show;

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
    /// The block device ("dm-0"), or "zfs:" and the pool.
    key_buffer: [64]u8 = undefined,
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


/// Write the usage of the file systems on local SSD and NVMe disks into
/// `usages`. Return their number.
fn local_usages(usages: []storage.Usage) !usize {
    const text = try Io.Dir.cwd().readFileAlloc(ctx.io, "/proc/self/mounts", ctx.gpa, .limited(1 << 20));
    defer ctx.gpa.free(text);

    var found: [max_file_systems]Found = undefined;
    var found_count: usize = 0;
    var lines = mem.splitScalar(u8, text, '\n');
    next: while (lines.next()) |line| {
        const m = storage.parse_mount(line) orelse continue;
        var key_buffer: [64]u8 = undefined;
        const key = switch (storage.source_of(m)) {
            .none => continue,
            .device => |path| device_name(path, &key_buffer) orelse continue,
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

        const local = switch (storage.source_of(m)) {
            .none => unreachable,
            .device => local_block(key, 0),
            .zfs => |pool| local_pool(pool),
        };
        if (!local) continue;
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


/// The name of a block device in /sys/class/block ("dm-0", "nvme1n1p3"),
/// from its path in /dev.
fn device_name(path: []const u8, buffer: []u8) ?[]const u8 {
    var real_buffer: [max_path]u8 = undefined;
    const real = real_path(path, &real_buffer) orelse return null;
    const name = std.fs.path.basename(real);
    if (name.len > buffer.len) return null;
    @memcpy(buffer[0..name.len], name);
    return buffer[0..name.len];
}


/// True when the block device `name` is on local SSD or NVMe disks only.
/// A device-mapper volume is on the devices in its directory "slaves".
fn local_block(name: []const u8, depth: usize) bool {
    if (depth > max_depth) return false;

    var path_buffer: [max_path]u8 = undefined;
    const slaves_path = fmt.bufPrint(&path_buffer, "/sys/class/block/{s}/slaves", .{ name }) catch return false;
    if (Io.Dir.openDirAbsolute(ctx.io, slaves_path, .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(ctx.io);
        var slaves: usize = 0;
        var it = dir.iterate();
        while (it.next(ctx.io) catch return false) |slave| {
            if (!local_block(slave.name, depth + 1)) return false;
            slaves += 1;
        }
        if (slaves > 0) return true;
    } else |_| {}

    const class_path = fmt.bufPrint(&path_buffer, "/sys/class/block/{s}", .{ name }) catch return false;
    var real_buffer: [max_path]u8 = undefined;
    const real = real_path(class_path, &real_buffer) orelse return false;
    var partition_buffer: [16]u8 = undefined;
    const partition = read_text(real, "partition", &partition_buffer) != null;
    const disk = storage.disk_path(real, partition);

    var removable_buffer: [8]u8 = undefined;
    var rotational_buffer: [8]u8 = undefined;
    return storage.local_flash(
        std.fs.path.basename(disk),
        disk,
        read_text(disk, "removable", &removable_buffer),
        read_text(disk, "queue/rotational", &rotational_buffer),
    );
}


/// True when the ZFS pool `pool` is on local SSD or NVMe disks only. The
/// partitions of the pool have its name as label in the udev database.
fn local_pool(pool: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(ctx.io, "/run/udev/data", .{ .iterate = true }) catch return false;
    defer dir.close(ctx.io);

    var members: usize = 0;
    var it = dir.iterate();
    while (it.next(ctx.io) catch return false) |entry| {
        const device = storage.udev_block_device(entry.name) orelse continue;
        var text_buffer: [16 * 1024]u8 = undefined;
        const text = dir.readFile(ctx.io, entry.name, &text_buffer) catch continue;
        const label = storage.udev_zfs_pool(text) orelse continue;
        if (!mem.eql(u8, label, pool)) continue;

        var path_buffer: [64]u8 = undefined;
        const path = fmt.bufPrint(&path_buffer, "/sys/dev/block/{s}", .{ device }) catch return false;
        var real_buffer: [max_path]u8 = undefined;
        const real = real_path(path, &real_buffer) orelse return false;
        if (!local_block(std.fs.path.basename(real), 0)) return false;
        members += 1;
    }
    return members > 0;
}


/// The path without links, or null.
fn real_path(path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    var path_buffer: [max_path]u8 = undefined;
    const path_z = fmt.bufPrintZ(&path_buffer, "{s}", .{ path }) catch return null;
    const real = std.c.realpath(path_z.ptr, buffer) orelse return null;
    return mem.span(real);
}


/// The text of the file `file` in the directory `dir`, without the new line.
/// null: an error.
fn read_text(dir: []const u8, file: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [max_path]u8 = undefined;
    const path = fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ dir, file }) catch return null;
    const text = common.read_file(path.ptr, buffer) catch return null;
    return mem.trim(u8, text, " \n");
}
