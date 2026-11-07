//! The file systems of the disk widget, without Wayland objects and without
//! files. widgets/disk.zig reads /proc/self/mounts and calls statvfs(3).
//! `zig build test` runs the tests below.
//!
//! Without a `path`, the widget counts all the mounted file systems on a
//! block device or in a ZFS pool. These file systems do not count:
//!   - The boot partition (/boot, /boot/efi, /efi).
//!   - Read-only images (squashfs, ISO 9660, UDF, EROFS). They are always
//!     full.
//! The swap is not mounted. Thus it does not count.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// The maximum length of a mount point. kwm cuts longer ones.
const max_label = 128;

/// One line of /proc/self/mounts. The fields are not unescaped.
pub const Mount = struct {
    source: []const u8,
    target: []const u8,
    fs_type: []const u8,
};

pub fn parse_mount(line: []const u8) ?Mount {
    var fields = mem.tokenizeScalar(u8, line, ' ');
    const source = fields.next() orelse return null;
    const target = fields.next() orelse return null;
    const fs_type = fields.next() orelse return null;
    return .{ .source = source, .target = target, .fs_type = fs_type };
}


/// The kernel writes a space, a tab, a new line and a backslash in a mount
/// point as an octal code ("\040" for a space). Write the mount point into
/// `buffer` without the codes. A longer mount point is cut.
pub fn unescape(field: []const u8, buffer: []u8) []const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < field.len and len < buffer.len) {
        if (field[i] == '\\' and i + 4 <= field.len) {
            if (std.fmt.parseInt(u8, field[i + 1 .. i + 4], 8)) |c| {
                buffer[len] = c;
                len += 1;
                i += 4;
                continue;
            } else |_| {}
        }
        buffer[len] = field[i];
        len += 1;
        i += 1;
    }
    return buffer[0..len];
}


/// Where a file system keeps its data.
pub const Source = union(enum) {
    /// The path of a block device, for example /dev/mapper/root.
    device: []const u8,
    /// The name of a ZFS pool.
    zfs: []const u8,
    /// Not on a disk (proc, tmpfs, a network file system), or not counted.
    none,
};

pub fn source_of(m: Mount) Source {
    if (boot(m.target)) return .none;
    for (images) |image| {
        if (mem.eql(u8, m.fs_type, image)) return .none;
    }
    if (mem.eql(u8, m.fs_type, "zfs")) {
        const end = mem.indexOfScalar(u8, m.source, '/') orelse m.source.len;
        if (end == 0) return .none;
        return .{ .zfs = m.source[0..end] };
    }
    if (mem.startsWith(u8, m.source, "/dev/")) return .{ .device = m.source };
    return .none;
}

/// The file system types of read-only images.
const images = [_][]const u8{ "squashfs", "iso9660", "udf", "erofs" };

/// True when `target` is the mount point of the boot partition, or a mount
/// point in it. The boot partition is small, and only an update writes to it.
fn boot(target: []const u8) bool {
    for ([_][]const u8{ "/boot", "/efi" }) |dir| {
        if (!mem.startsWith(u8, target, dir)) continue;
        if (target.len == dir.len or target[dir.len] == '/') return true;
    }
    return false;
}


/// The space of one file system.
pub const Usage = struct {
    label_buffer: [max_label]u8 = undefined,
    label_len: usize = 0,
    /// Bytes.
    total: u64 = 0,
    free: u64 = 0,
    used: u64 = 0,

    pub fn init(mount_point: []const u8, total: u64, free: u64, used: u64) Usage {
        var u: Usage = .{ .total = total, .free = free, .used = used };
        u.label_len = @min(u.label_buffer.len, mount_point.len);
        @memcpy(u.label_buffer[0..u.label_len], mount_point[0..u.label_len]);
        return u;
    }

    pub fn label(self: *const Usage) []const u8 {
        return self.label_buffer[0..self.label_len];
    }

    /// The used part in percent. As df(1): the space for root is not
    /// available to the user.
    pub fn percent(self: *const Usage) u64 {
        const usable = self.used + self.free;
        return if (usable == 0) 0 else self.used * 100 / usable;
    }

    /// The line of the tooltip, in GB with two decimals as the waybar
    /// tooltip: "/: 12.34 GB out of 500.00 GB available (97% used)".
    pub fn format(self: *const Usage, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}: {}.{:0>2} GB out of {}.{:0>2} GB available ({}% used)", .{
            self.label(),
            self.free / gb, self.free % gb / (gb / 100),
            self.total / gb, self.total % gb / (gb / 100),
            self.percent(),
        });
    }
};

pub const gb: u64 = 1_000_000_000;


/// The order of the tooltip: the order of the mount points.
pub fn less_than(_: void, a: Usage, b: Usage) bool {
    return mem.lessThan(u8, a.label(), b.label());
}


/// The file systems of the widget, together.
pub const Summary = struct {
    /// The smallest free space: the text of the widget.
    free: u64,
    /// The largest used part in percent.
    percent: u64,

    /// True when a file system has less than `alert` bytes free.
    pub fn low(self: Summary, alert: u64) bool {
        return self.free < alert;
    }

    /// True when the widget shows: a file system is `show` percent used or
    /// more, or has less than `alert` bytes free.
    pub fn shown(self: Summary, show: u64, alert: u64) bool {
        return self.low(alert) or self.percent >= show;
    }
};

/// null: no file system.
pub fn summary(usages: []const Usage) ?Summary {
    if (usages.len == 0) return null;
    var s: Summary = .{ .free = std.math.maxInt(u64), .percent = 0 };
    for (usages) |*u| {
        s.free = @min(s.free, u.free);
        s.percent = @max(s.percent, u.percent());
    }
    return s;
}


test "a line of /proc/self/mounts" {
    const m = parse_mount("/dev/mapper/root / ext4 rw,relatime 0 0").?;
    try testing.expectEqualStrings("/dev/mapper/root", m.source);
    try testing.expectEqualStrings("/", m.target);
    try testing.expectEqualStrings("ext4", m.fs_type);
    try testing.expectEqual(null, parse_mount("/dev/sda1 /mnt"));
    try testing.expectEqual(null, parse_mount(""));
}

test "a mount point with a space and a backslash" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("/media/My Disk", unescape("/media/My\\040Disk", &buffer));
    try testing.expectEqualStrings("/a\\b", unescape("/a\\134b", &buffer));
    try testing.expectEqualStrings("/a\\9", unescape("/a\\9", &buffer));
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("/hom", unescape("/home", &small));
}

test "the source of a file system" {
    const root = source_of(parse_mount("/dev/mapper/root / ext4 rw 0 0").?);
    try testing.expectEqualStrings("/dev/mapper/root", root.device);
    const code = source_of(parse_mount("tank/home/code /home/u/code zfs rw 0 0").?);
    try testing.expectEqualStrings("tank", code.zfs);
    const pool = source_of(parse_mount("tank /tank zfs rw 0 0").?);
    try testing.expectEqualStrings("tank", pool.zfs);
    // USB disks and FAT file systems count.
    const usb = source_of(parse_mount("/dev/sdb1 /run/media/u/STICK vfat rw 0 0").?);
    try testing.expectEqualStrings("/dev/sdb1", usb.device);
    // The boot partition does not count.
    try testing.expectEqual(.none, source_of(parse_mount("/dev/nvme0n1p1 /boot vfat rw 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("/dev/nvme0n1p1 /boot/efi vfat rw 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("/dev/nvme0n1p1 /efi vfat rw 0 0").?));
    try testing.expect(source_of(parse_mount("/dev/sda1 /bootstrap ext4 rw 0 0").?) == .device);
    // Read-only images are always full. They do not count.
    try testing.expectEqual(.none, source_of(parse_mount("/dev/loop0 /snap/core squashfs ro 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("/dev/sr0 /run/media/u/CD iso9660 ro 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("tmpfs /tmp tmpfs rw 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("server:/x /mnt nfs4 rw 0 0").?));
}

test "the text is the smallest free space, the percent the largest use" {
    const usages = [_]Usage{
        .init("/", 500 * gb, 200 * gb, 300 * gb),
        .init("/home/u/code", 1000 * gb, 50 * gb, 400 * gb),
    };
    const s = summary(&usages).?;
    try testing.expectEqual(50 * gb, s.free);
    try testing.expectEqual(88, s.percent);
    try testing.expectEqual(null, summary(&.{}));
}

test "a full disk shows the widget when another disk has much free space" {
    const usages = [_]Usage{
        .init("/", 288 * gb, 3 * gb, 270 * gb),
        .init("/home/u/code", 454 * gb, 424 * gb, 30 * gb),
    };
    const s = summary(&usages).?;
    try testing.expect(s.shown(80, 10 * gb));
    try testing.expect(s.low(10 * gb));
    // Below the alert, also when the percent is below `show`.
    const big = [_]Usage{
        .init("/", 4000 * gb, 5 * gb, 3000 * gb),
        .init("/home/u/code", 454 * gb, 424 * gb, 30 * gb),
    };
    try testing.expect(summary(&big).?.shown(80, 10 * gb));
    // No file system is near the limits.
    const calm = [_]Usage{
        .init("/", 288 * gb, 100 * gb, 188 * gb),
        .init("/home/u/code", 454 * gb, 424 * gb, 30 * gb),
    };
    try testing.expect(!summary(&calm).?.shown(80, 10 * gb));
    try testing.expect(!summary(&calm).?.low(10 * gb));
}

test "the tooltip line of a file system" {
    const u: Usage = .init("/", 500 * gb, 12_345_678_900, 487 * gb);
    var buffer: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{f}", .{ &u });
    try testing.expectEqualStrings("/: 12.34 GB out of 500.00 GB available (97% used)", line);
}

test "the tooltip is in the order of the mount points" {
    var usages = [_]Usage{ .init("/media", 1, 1, 0), .init("/", 1, 1, 0), .init("/home", 1, 1, 0) };
    mem.sort(Usage, &usages, {}, less_than);
    try testing.expectEqualStrings("/", usages[0].label());
    try testing.expectEqualStrings("/home", usages[1].label());
    try testing.expectEqualStrings("/media", usages[2].label());
}
