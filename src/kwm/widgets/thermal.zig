//! The readings of the temperature widget, without Wayland objects and
//! without files. widgets/temperature.zig reads the sensors. `zig build test`
//! runs the tests below.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

/// The maximum length of a sensor name and of a label. kwm cuts longer ones.
const max_text = 64;

/// The `hwmon` of the GPUs of nvidia-smi. They come after the hwmon devices.
pub const nvidia_smi_device = std.math.maxInt(u32);

/// One temp<index>_input file of /sys/class/hwmon/hwmon<hwmon>, or GPU
/// <index> of nvidia-smi.
pub const Reading = struct {
    hwmon: u32,
    index: u32,
    millidegrees: i64,
    name_buffer: [max_text]u8 = undefined,
    name_len: usize = 0,
    label_buffer: [max_text]u8 = undefined,
    label_len: usize = 0,

    pub fn init(hwmon: u32, index: u32, millidegrees: i64, device_name: []const u8, sensor_label: ?[]const u8) Reading {
        var r: Reading = .{ .hwmon = hwmon, .index = index, .millidegrees = millidegrees };
        r.name_len = copy(&r.name_buffer, device_name);
        r.label_len = if (sensor_label) |l|
            copy(&r.label_buffer, l)
        else
            if (fmt.bufPrint(&r.label_buffer, "temp{}", .{ index })) |l| l.len else |_| 0;
        return r;
    }

    pub fn name(self: *const Reading) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn label(self: *const Reading) []const u8 {
        return self.label_buffer[0..self.label_len];
    }

    /// The line of the tooltip, for example "k10temp Tctl: 54°C".
    pub fn format(self: *const Reading, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} {s}: {}°C", .{ self.name(), self.label(), degrees(self.millidegrees) });
    }
};

fn copy(buffer: []u8, text: []const u8) usize {
    const len = @min(buffer.len, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    return len;
}


/// The order of the tooltip: the order of the devices and of the sensors.
pub fn less_than(_: void, a: Reading, b: Reading) bool {
    if (a.hwmon != b.hwmon) return a.hwmon < b.hwmon;
    return a.index < b.index;
}


/// The reading with the highest temperature. null: no readings.
pub fn hottest(readings: []const Reading) ?*const Reading {
    if (readings.len == 0) return null;
    var max = &readings[0];
    for (readings[1..]) |*r| {
        if (r.millidegrees > max.millidegrees) max = r;
    }
    return max;
}


/// True when the hwmon device `name` is in the `ignore` list of the widget.
pub fn ignored(name: []const u8, ignore: []const []const u8) bool {
    for (ignore) |i| {
        if (mem.eql(u8, i, name)) return true;
    }
    return false;
}


/// A line of `nvidia-smi --query-gpu=name,temperature.gpu
/// --format=csv,noheader,nounits`, for example
/// "NVIDIA GeForce RTX 3060 Laptop GPU, 37". null: another line, for example
/// an error or "[N/A]".
pub fn parse_nvidia_smi(line: []const u8) ?struct { name: []const u8, millidegrees: i64 } {
    const comma = mem.lastIndexOf(u8, line, ", ") orelse return null;
    const name = mem.trim(u8, line[0..comma], " ");
    const value = mem.trim(u8, line[comma + 2 ..], " \r");
    if (name.len == 0) return null;
    const celsius = fmt.parseInt(i64, value, 10) catch return null;
    return .{ .name = name, .millidegrees = celsius * 1000 };
}


/// Some sensors give a wrong value instead of an error. For example, the
/// embedded controller of a Lenovo Legion (legion_hwmon) gives 209°C for a
/// GPU at 37°C, and 0°C for a sensor that it does not have. No sensor of a
/// computer is at 0°C or less, or above 150°C.
pub fn plausible(millidegrees: i64) bool {
    return millidegrees > 0 and millidegrees <= 150_000;
}


/// Millidegrees to the nearest degree.
pub fn degrees(millidegrees: i64) i64 {
    return @divFloor(millidegrees + 500, 1000);
}


/// The text of the format .celsius, for example "41C".
pub fn celsius_text(buffer: []u8, millidegrees: i64) fmt.BufPrintError![]u8 {
    return fmt.bufPrint(buffer, "{}C", .{ degrees(millidegrees) });
}


/// The widget shows the hottest sensor at `show` degrees Celsius or more,
/// as the text shows it (to the nearest degree). null: always.
pub fn shown(millidegrees: i64, show: ?i32) bool {
    const limit = show orelse return true;
    return degrees(millidegrees) >= limit;
}


/// The meter percentage: 0 at `low` degrees Celsius or less, 100 at `high`
/// or more.
pub fn percent(millidegrees: i64, low: i32, high: i32) u64 {
    if (high <= low) return if (millidegrees >= @as(i64, high) * 1000) 100 else 0;
    const range = (@as(i64, high) - low) * 1000;
    const above = millidegrees - @as(i64, low) * 1000;
    return @intCast(std.math.clamp(@divFloor(above * 100, range), 0, 100));
}


/// The number in a file name: "hwmon3" with "hwmon" and "" gives 3,
/// "temp12_input" with "temp" and "_input" gives 12. null: another name.
pub fn parse_index(file: []const u8, prefix: []const u8, suffix: []const u8) ?u32 {
    if (!mem.startsWith(u8, file, prefix) or !mem.endsWith(u8, file, suffix)) return null;
    if (file.len <= prefix.len + suffix.len) return null;
    const digits = file[prefix.len .. file.len - suffix.len];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return fmt.parseInt(u32, digits, 10) catch null;
}


test "30 degrees is an empty meter and 80 degrees a full one" {
    try testing.expectEqual(0, percent(30_000, 30, 80));
    try testing.expectEqual(0, percent(12_000, 30, 80));
    try testing.expectEqual(0, percent(-5_000, 30, 80));
    try testing.expectEqual(50, percent(55_000, 30, 80));
    try testing.expectEqual(70, percent(65_000, 30, 80));
    try testing.expectEqual(90, percent(75_000, 30, 80));
    try testing.expectEqual(100, percent(80_000, 30, 80));
    try testing.expectEqual(100, percent(105_000, 30, 80));
}

test "the widget shows from the limit, as the text rounds the degrees" {
    try testing.expect(!shown(59_000, 60));
    try testing.expect(!shown(59_499, 60));
    try testing.expect(shown(59_500, 60));
    try testing.expect(shown(60_000, 60));
    try testing.expect(shown(95_000, 60));
    try testing.expect(shown(20_000, null));
}

test "a range without width is empty below the limit and full at it" {
    try testing.expectEqual(0, percent(59_999, 60, 60));
    try testing.expectEqual(100, percent(60_000, 60, 60));
}

test "wrong values of a sensor are not readings" {
    try testing.expect(!plausible(209_000));
    try testing.expect(!plausible(0));
    try testing.expect(!plausible(-273_000));
    try testing.expect(plausible(150_000));
    try testing.expect(plausible(17_000));
    try testing.expect(plausible(45_000));
}

test "the text of the format celsius" {
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("41C", try celsius_text(&buffer, 40_600));
    try testing.expectEqualStrings("100C", try celsius_text(&buffer, 100_000));
}

test "the ignore list has hwmon names" {
    const ignore = [_][]const u8 { "legion_hwmon" };
    try testing.expect(ignored("legion_hwmon", &ignore));
    try testing.expect(!ignored("k10temp", &ignore));
    try testing.expect(!ignored("legion_hwmon", &.{}));
}

test "the GPU lines of nvidia-smi" {
    const gpu = parse_nvidia_smi("NVIDIA GeForce RTX 3060 Laptop GPU, 37").?;
    try testing.expectEqualStrings("NVIDIA GeForce RTX 3060 Laptop GPU", gpu.name);
    try testing.expectEqual(37_000, gpu.millidegrees);
    try testing.expectEqual(37_000, parse_nvidia_smi("A, B, 37\r").?.millidegrees);
    try testing.expectEqual(null, parse_nvidia_smi("NVIDIA GeForce RTX 3060 Laptop GPU, [N/A]"));
    try testing.expectEqual(null, parse_nvidia_smi("NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver."));
    try testing.expectEqual(null, parse_nvidia_smi(", 37"));
}

test "the GPUs of nvidia-smi come after the hwmon devices" {
    var readings = [_]Reading {
        .init(nvidia_smi_device, 0, 37_000, "nvidia", "NVIDIA GeForce RTX 3060 Laptop GPU"),
        .init(5, 1, 45_000, "k10temp", "Tctl"),
    };
    mem.sort(Reading, &readings, {}, less_than);
    try testing.expectEqualStrings("k10temp", readings[0].name());
    try testing.expectEqualStrings("NVIDIA GeForce RTX 3060 Laptop GPU", readings[1].label());
}

test "degrees round to the nearest degree" {
    try testing.expectEqual(54, degrees(54_499));
    try testing.expectEqual(55, degrees(54_500));
    try testing.expectEqual(-3, degrees(-3_000));
}

test "the index of hwmon directories and temperature files" {
    try testing.expectEqual(3, parse_index("hwmon3", "hwmon", ""));
    try testing.expectEqual(12, parse_index("temp12_input", "temp", "_input"));
    try testing.expectEqual(null, parse_index("temp1_label", "temp", "_input"));
    try testing.expectEqual(null, parse_index("temp_input", "temp", "_input"));
    try testing.expectEqual(null, parse_index("tempx_input", "temp", "_input"));
    try testing.expectEqual(null, parse_index("in0_input", "temp", "_input"));
    try testing.expectEqual(null, parse_index("power", "hwmon", ""));
}

test "the gauge uses the hottest reading" {
    const readings = [_]Reading {
        .init(0, 1, 41_000, "acpitz", null),
        .init(2, 1, 67_250, "k10temp", "Tctl"),
        .init(4, 1, 38_000, "nvme", "Composite"),
    };
    try testing.expectEqual(&readings[1], hottest(&readings).?);
    try testing.expectEqual(null, hottest(&.{}));
}

test "the tooltip lines are in the order of the devices and the sensors" {
    var readings = [_]Reading {
        .init(4, 2, 38_000, "nvme", "Sensor 1"),
        .init(2, 1, 67_250, "k10temp", "Tctl"),
        .init(4, 1, 39_000, "nvme", "Composite"),
        .init(0, 1, 41_000, "acpitz", null),
    };
    mem.sort(Reading, &readings, {}, less_than);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (readings, 0..) |r, i| {
        if (i > 0) try writer.writeByte('\n');
        try writer.print("{f}", .{ r });
    }
    try testing.expectEqualStrings(
        \\acpitz temp1: 41°C
        \\k10temp Tctl: 67°C
        \\nvme Composite: 39°C
        \\nvme Sensor 1: 38°C
    , writer.buffered());
}

test "long names are cut" {
    const r: Reading = .init(0, 1, 0, "n" ** 80, "l" ** 80);
    try testing.expectEqual(max_text, r.name().len);
    try testing.expectEqual(max_text, r.label().len);
}
