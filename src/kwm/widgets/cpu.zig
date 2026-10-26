//! CPU widget: the CPU use since the last update as a meter, from /proc/stat.
//!
//! The approach follows w_cpu.zig of ziew (https://github.com/gryzus24/ziew,
//! MIT license).

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const common = @import("common.zig");
const ctx = common.ctx;

/// The most cores with their own counters.
pub const max_cores = 256;

/// The counters of one line of /proc/stat.
const Counters = struct {
    total: u64 = 0,
    idle: u64 = 0,

    /// The use since `last`, in percent.
    fn percent(self: Counters, last: Counters) u8 {
        const delta_total = self.total -| last.total;
        const delta_idle = self.idle -| last.idle;
        return if (delta_total == 0) 0 else @intCast(@min(100, (delta_total -| delta_idle) * 100 / delta_total));
    }
};

/// The counters of the last update: of all the cores, and of each core.
pub const Data = struct {
    all: Counters = .{},
    cores: [max_cores]Counters = .{ Counters{} } ** max_cores,
};

/// The CPU use since the last update.
pub const Use = struct {
    /// Of all the cores, in percent.
    all: u8,
    /// The number of items of `cores` that `parse` wrote.
    cores: usize,
};


/// The CPU use since the last call, in percent.
pub fn read(data: *Data) !u64 {
    return (try read_cores(data, &.{})).all;
}

/// The CPU use since the last call: of all the cores, and of each core in
/// `cores` (until it is full), in percent.
pub fn read_cores(data: *Data, cores: []u8) !Use {
    // The "cpu" lines are at the start of /proc/stat, about 60 to 100 bytes
    // each.
    var buffer: [max_cores * 128]u8 = undefined;
    const stat = try common.read_file("/proc/stat", &buffer);
    return parse(stat, data, cores);
}

/// Read the "cpu" and "cpuN" lines of `stat` (the text of /proc/stat),
/// and keep their counters in `data`. A line without '\n' at its end is
/// not complete, and parse ignores it.
pub fn parse(stat: []const u8, data: *Data, cores: []u8) !Use {
    var result: Use = .{ .all = 0, .cores = 0 };
    var found = false;
    var lines = mem.splitScalar(u8, stat, '\n');
    while (lines.next()) |line| {
        // The last item is after the last '\n'.
        if (lines.index == null) break;
        // "cpu  user nice system idle iowait irq softirq steal ..."
        var fields = mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next() orelse continue;
        if (!mem.startsWith(u8, name, "cpu")) break;

        var values: [8]u64 = .{ 0 } ** 8;
        for (&values) |*v| {
            v.* = fmt.parseInt(u64, fields.next() orelse break, 10) catch 0;
        }
        var counters: Counters = .{ .idle = values[3] + values[4] };
        for (values) |v| counters.total += v;

        if (name.len == 3) {
            result.all = counters.percent(data.all);
            data.all = counters;
            found = true;
            continue;
        }
        // Offline cores have no line: the number of the core is the index.
        const core = fmt.parseInt(usize, name[3..], 10) catch continue;
        if (core >= max_cores) continue;
        if (result.cores < cores.len) {
            cores[result.cores] = counters.percent(data.cores[core]);
            result.cores += 1;
        }
        data.cores[core] = counters;
    }
    if (!found) return error.BadProcStat;
    return result;
}


pub fn update(cfg: anytype, data: *Data, out: *common.Output) !void {
    const percent = try read(data);
    try common.append_meter(&out.text, cfg, percent);
    try out.tooltip.print(ctx.gpa, "CPU {}%", .{ percent });
}


test "parse: the use of all the cores and of each core" {
    var data: Data = .{};
    var cores: [4]u8 = undefined;
    _ = try parse(
        \\cpu  100 0 100 800 0 0 0 0 0 0
        \\cpu0 50 0 50 400 0 0 0 0 0 0
        \\cpu1 50 0 50 400 0 0 0 0 0 0
        \\intr 1 2 3
        \\
    , &data, &cores);
    // cpu0: 100 of 100 busy, cpu1: 0 of 100 busy (idle and iowait).
    const use = try parse(
        \\cpu  200 0 100 850 50 0 0 0 0 0
        \\cpu0 100 0 100 400 0 0 0 0 0 0
        \\cpu1 50 0 50 450 50 0 0 0 0 0
        \\intr 1 2 3
        \\
    , &data, &cores);
    try std.testing.expectEqual(@as(u8, 50), use.all);
    try std.testing.expectEqual(@as(usize, 2), use.cores);
    try std.testing.expectEqualSlices(u8, &.{ 100, 0 }, cores[0..2]);
}

test "parse: no line that is not complete, no core after the end of cores" {
    var data: Data = .{};
    var cores: [1]u8 = undefined;
    const use = try parse(
        \\cpu  100 0 100 800 0 0 0 0 0 0
        \\cpu0 50 0 50 400 0 0 0 0 0 0
        \\cpu1 50 0 50 400 0 0 0 0 0 0
        \\cpu2 50 0 5
    , &data, &cores);
    try std.testing.expectEqual(@as(usize, 1), use.cores);
    try std.testing.expectEqual(@as(u64, 500), data.cores[1].total);
    try std.testing.expectEqual(@as(u64, 0), data.cores[2].total);
}

test "parse: no cpu line is an error" {
    var data: Data = .{};
    try std.testing.expectError(error.BadProcStat, parse("intr 1 2 3\n", &data, &.{}));
}
