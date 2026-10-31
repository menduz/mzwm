//! The file systems of the disk widget, without Wayland objects and without
//! files. widgets/disk.zig reads /proc/self/mounts, sysfs and the udev
//! database. `zig build test` runs the tests below.
//!
//! Without a `path`, the widget counts the file systems on local SSD and
//! NVMe disks: the disk name starts with "nvme" or "sd", the disk does not
//! rotate, is not removable, and is not on USB. A device-mapper volume (for
//! example LUKS) counts when all its disks count. A ZFS pool counts when all
//! the partitions with its label count.

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
    // FAT is the EFI system partition. It is small, and its free space is
    // always less than the free space of the other file systems.
    if (mem.eql(u8, m.fs_type, "vfat")) return .none;
    if (mem.eql(u8, m.fs_type, "zfs")) {
        const end = mem.indexOfScalar(u8, m.source, '/') orelse m.source.len;
        if (end == 0) return .none;
        return .{ .zfs = m.source[0..end] };
    }
    if (mem.startsWith(u8, m.source, "/dev/")) return .{ .device = m.source };
    return .none;
}


/// True when a disk is a local SSD or NVMe disk. `path` is the sysfs path
/// of the disk without links. `removable` and `rotational` are the text of
/// its files "removable" and "queue/rotational", null when they are not
/// there.
pub fn local_flash(name: []const u8, path: []const u8, removable: ?[]const u8, rotational: ?[]const u8) bool {
    if (!mem.startsWith(u8, name, "nvme") and !mem.startsWith(u8, name, "sd")) return false;
    if (mem.indexOf(u8, path, "/usb") != null) return false;
    const fixed = removable orelse return false;
    const solid = rotational orelse return false;
    return mem.eql(u8, fixed, "0") and mem.eql(u8, solid, "0");
}


/// The sysfs path of the disk of a block device. `path` is the sysfs path
/// of the block device without links. The directory of a partition is in
/// the directory of its disk.
pub fn disk_path(path: []const u8, partition: bool) []const u8 {
    if (!partition) return path;
    const end = mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[0..end];
}


/// The pool of a ZFS partition, from its file in /run/udev/data. null: the
/// device is not in a ZFS pool.
pub fn udev_zfs_pool(text: []const u8) ?[]const u8 {
    var zfs = false;
    var label: ?[]const u8 = null;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (mem.eql(u8, line, "E:ID_FS_TYPE=zfs_member")) zfs = true;
        if (mem.startsWith(u8, line, "E:ID_FS_LABEL=")) label = line["E:ID_FS_LABEL=".len..];
    }
    return if (zfs) label else null;
}


/// The "major:minor" of a block device file in /run/udev/data ("b259:3").
/// null: not a block device.
pub fn udev_block_device(file_name: []const u8) ?[]const u8 {
    if (file_name.len < 2 or file_name[0] != 'b') return null;
    if (mem.indexOfScalar(u8, file_name, ':') == null) return null;
    return file_name[1..];
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
    try testing.expectEqual(.none, source_of(parse_mount("/dev/nvme0n1p1 /boot vfat rw 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("tmpfs /tmp tmpfs rw 0 0").?));
    try testing.expectEqual(.none, source_of(parse_mount("server:/x /mnt nfs4 rw 0 0").?));
}

test "local SSD and NVMe disks count, USB, removable and rotating disks do not" {
    const pci_nvme = "/sys/devices/pci0000:00/0000:00:06.0/0000:02:00.0/nvme/nvme1/nvme1n1";
    try testing.expect(local_flash("nvme1n1", pci_nvme, "0", "0"));
    // With NVMe multipath, the disk is in /sys/devices/virtual.
    try testing.expect(local_flash("nvme0n1", "/sys/devices/virtual/nvme-subsystem/nvme-subsys0/nvme0n1", "0", "0"));
    const sata = "/sys/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda";
    try testing.expect(local_flash("sda", sata, "0", "0"));
    try testing.expect(!local_flash("sda", sata, "0", "1"));
    const usb = "/sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host1/target1:0:0/1:0:0:0/block/sdb";
    try testing.expect(!local_flash("sdb", usb, "0", "0"));
    try testing.expect(!local_flash("sdc", sata, "1", "0"));
    try testing.expect(!local_flash("mmcblk0", "/sys/devices/platform/mmc/mmcblk0", "0", "0"));
    try testing.expect(!local_flash("loop0", "/sys/devices/virtual/block/loop0", "0", "0"));
    try testing.expect(!local_flash("nvme1n1", pci_nvme, null, "0"));
    try testing.expect(!local_flash("nvme1n1", pci_nvme, "0", null));
}

test "the disk of a partition" {
    const part = "/sys/devices/pci0000:00/nvme/nvme1/nvme1n1/nvme1n1p3";
    try testing.expectEqualStrings("/sys/devices/pci0000:00/nvme/nvme1/nvme1n1", disk_path(part, true));
    try testing.expectEqualStrings(part, disk_path(part, false));
}

test "the ZFS pool of a udev database file" {
    const member =
        \\S:disk/by-id/nvme-Samsung-part1
        \\E:ID_FS_LABEL=tank
        \\E:ID_FS_LABEL_ENC=tank
        \\E:ID_FS_TYPE=zfs_member
        \\E:ID_FS_USAGE=filesystem
    ;
    try testing.expectEqualStrings("tank", udev_zfs_pool(member).?);
    try testing.expectEqual(null, udev_zfs_pool("E:ID_FS_LABEL=data\nE:ID_FS_TYPE=ext4\n"));
    try testing.expectEqual(null, udev_zfs_pool("E:ID_FS_TYPE=zfs_member\n"));
}

test "the block devices of the udev database" {
    try testing.expectEqualStrings("259:3", udev_block_device("b259:3").?);
    try testing.expectEqual(null, udev_block_device("c13:64"));
    try testing.expectEqual(null, udev_block_device("n3"));
    try testing.expectEqual(null, udev_block_device("+usb:1-1"));
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
