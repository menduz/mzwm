const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.deck);

const types = @import("../types.zig");
const utils = @import("../utils.zig");
const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Layout = @import("../layout.zig");
const Window = @import("../window.zig");
const accordion = @import("accordion.zig");
const decoration = @import("../decoration.zig");

pub const MasterLocation = types.LayoutMasterLocation;

const ctx = Context.get();


nmaster: i32,
mfact: f32,
inner_gap: i32,
outer_gap: i32,
master_location: MasterLocation,


/// The main window (the master) at the left, and the other windows as an
/// accordion in the stack area: the window of the stack with the last focus
/// is open, and the other ones show only their title bars. A click on a title
/// bar or the focus keys (focus_iter) open a window; the pointer over a title
/// bar does not. zoom (Alt+Return) swaps the open window and the main window.
/// Refer to accordion.zig.
pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    var windows = blk: {
        var windows: std.ArrayList(*Window) = .empty;
        errdefer windows.deinit(ctx.gpa);

        {
            var it = ctx.windows.safeIterator(.forward);
            while (windows.items.len < self.nmaster) {
                const window = it.next() orelse break :blk windows;
                if (!window.is_visible_in(output) or window.floating) continue;
                try windows.append(ctx.gpa, window);
            }
        }

        // The stack keeps its order.
        {
            var it = ctx.windows.safeIterator(.forward);
            while (it.next()) |window| {
                const masters = windows.items[0..@intCast(self.nmaster)];
                if (mem.containsAtLeastScalar(*Window, masters, 1, window)) continue;
                if (!window.is_visible_in(output) or window.floating) continue;
                try windows.append(ctx.gpa, window);
            }
        }
        break :blk windows;
    };
    defer windows.deinit(ctx.gpa);

    if (windows.items.len == 0) return;
    const outer_gap = Layout.outer_gap(self.outer_gap, windows.items.len);

    const usable_width, const usable_height = blk: {
        const width = @max(0, output.exclusive_width() - 2*outer_gap);
        const height = @max(0, output.exclusive_height() - 2*outer_gap);
        break :blk switch (self.master_location) {
            .left, .right => .{ width, height },
            .top, .bottom => .{ height, width },
        };
    };

    var master_width: i32 = undefined;
    var master_height: i32 = undefined;
    var master_remain: i32 = undefined;
    var stack_width: i32 = undefined;
    var stack_height: i32 = undefined;

    const window_num: i32 = @intCast(windows.items.len);
    const nmaster = @min(window_num, self.nmaster);
    const nstack = window_num - self.nmaster;
    if (nstack > 0) {
        master_width = @intFromFloat(self.mfact * @as(f32, @floatFromInt(usable_width)));
        master_height = @divFloor(usable_height, nmaster);
        master_remain = @mod(usable_height, nmaster);

        stack_width = usable_width - master_width;
        stack_height = usable_height;
    } else {
        master_width = usable_width;
        master_height = @divFloor(usable_height, nmaster);
        master_remain = @mod(usable_height, nmaster);
    }

    for (0.., windows.items) |i, window| {
        if (i >= nmaster) break;
        const x: i32 = 0;
        const y: i32 = (@as(i32, @intCast(i)) * master_height) + if (i > 0) master_remain + self.inner_gap else 0;
        const w: i32 = @max(0, if (nstack > 0) master_width - @divFloor(self.inner_gap, 2) else master_width);
        const h: i32 = @max(0, (master_height + if (i == 0) master_remain else 0) - if (i > 0) self.inner_gap else 0);
        const r = self.to_output(usable_width, outer_gap, .{ .x = x, .y = y, .width = w, .height = h });
        window.unbound_move(r.x, r.y);
        window.unbound_resize(r.width, r.height);
    }
    if (nstack <= 0) return;

    const area = self.to_output(usable_width, outer_gap, .{
        .x = master_width + @divFloor(self.inner_gap, 2),
        .y = 0,
        .width = @max(0, stack_width - @divFloor(self.inner_gap, 2)),
        .height = stack_height,
    });
    const stack = windows.items[@intCast(nmaster)..];

    // The open window: the window of the stack with the last focus.
    const open = blk: {
        var it = ctx.focus_stack.safeIterator(.forward);
        while (it.next()) |window| {
            if (mem.indexOfScalar(*Window, stack, window)) |index| break :blk index;
        }
        break :blk 0;
    };
    for (0.., stack) |k, window| {
        const p = accordion.place(area, stack.len, k, open, decoration.height, ctx.cfg.border.width);
        window.unbound_move(p.rect.x, p.rect.y);
        window.unbound_resize(p.rect.width, p.rect.height);
        window.collapsed = p.collapsed;
        window.collapsed_bottom = p.bottom_border;
    }

    // The contents of a collapsed window are below the open window: the
    // collapsed windows go on top of the tiled windows first, then the open
    // window.
    if (stack.len > 1) {
        for (stack) |window| {
            if (window.collapsed) window.place(.{ .below = ctx.layer_marker.rwm_shell_surface_node });
        }
        stack[open].place(.{ .below = ctx.layer_marker.rwm_shell_surface_node });
    }
}


/// A rectangle of the layout (the master at the left) on the output, at the
/// master location.
fn to_output(self: *const Self, usable_width: i32, outer_gap: i32, r: accordion.Rect) accordion.Rect {
    return switch (self.master_location) {
        .left => .{ .x = r.x + outer_gap, .y = r.y + outer_gap, .width = r.width, .height = r.height },
        .right => .{ .x = usable_width - r.x - r.width + outer_gap, .y = r.y + outer_gap, .width = r.width, .height = r.height },
        .top => .{ .x = r.y + outer_gap, .y = r.x + outer_gap, .width = r.height, .height = r.width },
        .bottom => .{ .x = r.y + outer_gap, .y = usable_width - r.x - r.width + outer_gap, .width = r.height, .height = r.width },
    };
}
