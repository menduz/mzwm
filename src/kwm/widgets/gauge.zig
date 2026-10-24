//! Gauge widget: vertical bars for the memory and the CPU use. The tooltip
//! has the lines of the memory and CPU widgets. Refer to ../gauge.zig for
//! the drawing.

const std = @import("std");

const common = @import("common.zig");
const ctx = common.ctx;
const cpu = @import("cpu.zig");
const mem = @import("mem.zig");
const gauge = @import("../gauge.zig");


pub fn update(cfg: anytype, cpu_data: *cpu.Data, out: *common.Output) !void {
    for (cfg.bars[0..@min(cfg.bars.len, gauge.max_bars)], 0..) |bar, i| {
        if (i > 0) try out.tooltip.append(ctx.gpa, '\n');
        const percent = switch (bar) {
            .memory => blk: {
                const reading = try mem.read();
                try mem.print_tooltip(&out.tooltip, reading);
                break :blk reading.percent;
            },
            .cpu => blk: {
                const percent = try cpu.read(cpu_data);
                try out.tooltip.print(ctx.gpa, "CPU {}%", .{ percent });
                break :blk percent;
            },
        };
        out.gauge.items[i] = .{
            .percent = @intCast(@min(percent, 100)),
            .color = common.level_color(percent, cfg.warning, cfg.critical),
        };
        out.gauge.len += 1;
    }
}
