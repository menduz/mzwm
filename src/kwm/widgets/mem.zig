//! Memory widget: the used memory as a meter, from /proc/meminfo.
//!
//! The approach follows w_mem.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const common = @import("common.zig");
const ctx = common.ctx;


/// The value of a "Key:   1234 kB" line, in kB.
fn value(data: []const u8, key: []const u8) ?u64 {
    var lines = mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!mem.startsWith(u8, line, key)) continue;
        var fields = mem.tokenizeAny(u8, line[key.len..], " \t");
        return fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
    }
    return null;
}


/// The used memory.
pub const Reading = struct {
    used_kb: u64,
    percent: u64,
};


pub fn read() !Reading {
    var buffer: [4096]u8 = undefined;
    const data = try common.read_file("/proc/meminfo", &buffer);
    const total = value(data, "MemTotal:") orelse return error.NoMemTotal;
    const available = value(data, "MemAvailable:") orelse return error.NoMemAvailable;
    if (total == 0) return error.NoMemTotal;

    const used = total -| available;
    return .{ .used_kb = used, .percent = used * 100 / total };
}


/// The tooltip line, for example "RAM 5.2G - 33%".
pub fn print_tooltip(list: *std.ArrayList(u8), reading: Reading) !void {
    // kB to GiB, rounded to 0.1, as the waybar tooltip.
    const tenths = (reading.used_kb * 10 + 512 * 1024) / (1024 * 1024);
    try list.print(ctx.gpa, "RAM {}.{}G - {}%", .{ tenths / 10, tenths % 10, reading.percent });
}


pub fn update(cfg: anytype, out: *common.Output) !void {
    const reading = try read();
    try common.append_meter(&out.text, cfg, reading.percent);
    try print_tooltip(&out.tooltip, reading);
}
