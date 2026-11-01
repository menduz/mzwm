//! The cycle of the layouts, without Wayland objects.
//!
//! `cycle_layouts` in the configuration holds the layouts of the cycle, in
//! their order. The other layouts stay: switch_layout, default_layout and the
//! rules can select them. cycle_layout of output.zig uses `next`. The menu of
//! the layouts (tooltip.zig) shows the same layouts.
//!
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


/// The layout after `current` in `list`, or before it when `forward` is
/// false. After the last layout comes the first layout again. A layout that
/// is not in `list` goes to the first layout, or to the last layout. null:
/// `list` is empty.
pub fn next(comptime T: type, list: []const T, current: T, forward: bool) ?T {
    if (list.len == 0) return null;
    const i = std.mem.indexOfScalar(T, list, current) orelse
        return if (forward) list[0] else list[list.len - 1];
    return if (forward) list[(i + 1) % list.len] else list[(i + list.len - 1) % list.len];
}


const L = enum { tile, grid, monocle, deck, scroller, centered_master, float };

test "next: the layouts of the list, in a circle" {
    const list = [_]L{ .tile, .centered_master, .float, .monocle };
    try testing.expectEqual(@as(?L, .centered_master), next(L, &list, .tile, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .float, true));
    try testing.expectEqual(@as(?L, .tile), next(L, &list, .monocle, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .tile, false));
    try testing.expectEqual(@as(?L, .float), next(L, &list, .monocle, false));
}

test "next: a layout out of the list goes into the list" {
    const list = [_]L{ .tile, .centered_master, .float, .monocle };
    try testing.expectEqual(@as(?L, .tile), next(L, &list, .grid, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .deck, false));
    try testing.expectEqual(@as(?L, null), next(L, &.{}, .tile, true));
    try testing.expectEqual(@as(?L, .tile), next(L, &.{.tile}, .tile, true));
}
