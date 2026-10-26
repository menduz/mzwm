//! Gauge widget: vertical bars for the memory and the CPU use. The CPU bar
//! has a column for each core. The tooltip has the lines of the memory and
//! CPU widgets. Refer to ../gauge.zig for the drawing.

const std = @import("std");

const common = @import("common.zig");
const ctx = common.ctx;
const cpu = @import("cpu.zig");
const mem = @import("mem.zig");
const gauge = @import("../gauge.zig");


pub fn update(cfg: anytype, cpu_data: *cpu.Data, out: *common.Output) !void {
    for (cfg.bars[0..@min(cfg.bars.len, gauge.max_bars)], 0..) |bar, i| {
        if (i > 0) try out.tooltip.append(ctx.gpa, '\n');
        var columns: [gauge.max_columns]gauge.Level = undefined;
        const n: usize = switch (bar) {
            .memory => blk: {
                const reading = try mem.read();
                try mem.print_tooltip(&out.tooltip, reading);
                columns[0] = level(cfg, reading.percent);
                break :blk 1;
            },
            .cpu => blk: {
                var cores: [gauge.max_columns]u8 = undefined;
                const use = try cpu.read_cores(cpu_data, &cores);
                try out.tooltip.print(ctx.gpa, "CPU {}%", .{ use.all });
                for (cores[0..use.cores], columns[0..use.cores]) |percent, *column| column.* = level(cfg, percent);
                break :blk use.cores;
            },
        };
        out.gauge.add_bar(columns[0..n]);
    }
}


/// The value of a column, with the warning or critical color of `cfg`.
fn level(cfg: anytype, percent: u64) gauge.Level {
    return .{
        .percent = @intCast(@min(percent, 100)),
        .color = common.level_color(percent, cfg.warning, cfg.critical),
    };
}
