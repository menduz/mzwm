//! The number of master windows (nmaster) of a layout, without Wayland
//! objects. context.zig gives the windows of an output to these functions.
//! `zig build test` runs the tests below.
//!
//! - A drop starts from the master windows that the layout shows.
//! - A window that the pointer drops at the edge of the master area is a new
//!   master window (refer to drag.zig).
//! - When a master window closes and the master area has more than one
//!   window, the master area gets one window less.

const std = @import("std");
const testing = std.testing;


/// The number of master windows that a drop starts from: the master windows
/// that the layout shows, at least 1. `tiled` is the number of the other
/// tiled windows of the output. A larger nmaster (for example after
/// modify_nmaster) puts all windows in one master column, and the dropped
/// window then has no side of the output.
pub fn for_drop(nmaster: i32, tiled: usize) i32 {
    return @max(1, @min(nmaster, @as(i32, @intCast(@min(tiled, std.math.maxInt(i32))))));
}


/// The number of master windows after a new master window. `tiled` is the
/// number of the other tiled windows of the output. When the stack has
/// windows, the master area gets one more window: the master windows stay in
/// the master area. Else the last master window goes to the stack, and the
/// new window has a side of the output for itself.
pub fn with_new_master(nmaster: i32, tiled: usize) i32 {
    if (tiled > @as(usize, @intCast(@max(0, nmaster)))) return nmaster + 1;
    return nmaster;
}


/// The number of master windows after a tiled window closes. `index` is the
/// place of the window among the `tiled` windows of the output (the window
/// is one of them). A master window closes, and the master area has more
/// than one window: one master window less. Else a window of the stack
/// would go into the master area. The number is never less than 1.
pub fn after_close(nmaster: i32, index: usize, tiled: usize) i32 {
    const masters = @min(tiled, @as(usize, @intCast(@max(0, nmaster))));
    if (index < masters and masters > 1) return @max(1, nmaster - 1);
    return nmaster;
}


test "with_new_master: one more only when the stack has windows" {
    // One master and two windows in the stack: two masters.
    try testing.expectEqual(@as(i32, 2), with_new_master(1, 3));
    // One window: it goes to the stack, and the new window is the master.
    try testing.expectEqual(@as(i32, 1), with_new_master(1, 1));
    // No other tiled window.
    try testing.expectEqual(@as(i32, 1), with_new_master(1, 0));
    // Two masters and no stack: the second master goes to the stack.
    try testing.expectEqual(@as(i32, 2), with_new_master(2, 2));
    try testing.expectEqual(@as(i32, 3), with_new_master(2, 3));
}

test "after_close: a master window of two closes" {
    // Two masters and a stack: the stack keeps its window.
    try testing.expectEqual(@as(i32, 1), after_close(2, 0, 3));
    try testing.expectEqual(@as(i32, 1), after_close(2, 1, 3));
    // Two masters and no stack.
    try testing.expectEqual(@as(i32, 1), after_close(2, 1, 2));
    try testing.expectEqual(@as(i32, 2), after_close(3, 2, 5));
}

test "after_close: a window of the stack, or the only master window" {
    try testing.expectEqual(@as(i32, 2), after_close(2, 2, 3));
    try testing.expectEqual(@as(i32, 1), after_close(1, 0, 3));
    try testing.expectEqual(@as(i32, 1), after_close(1, 0, 1));
}

test "after_close: fewer windows than nmaster" {
    // nmaster 3 with two windows: two masters, one closes.
    try testing.expectEqual(@as(i32, 2), after_close(3, 0, 2));
    // nmaster 3 with one window: the master area has one window.
    try testing.expectEqual(@as(i32, 3), after_close(3, 0, 1));
}

test "for_drop: the drop starts from the master windows that the layout shows" {
    // nmaster 2 and one other window: one master window.
    try testing.expectEqual(@as(i32, 1), for_drop(2, 1));
    try testing.expectEqual(@as(i32, 2), for_drop(5, 2));
    // No other window: at least 1.
    try testing.expectEqual(@as(i32, 1), for_drop(2, 0));
    // nmaster at most the other windows: no change.
    try testing.expectEqual(@as(i32, 2), for_drop(2, 2));
    try testing.expectEqual(@as(i32, 1), for_drop(1, 3));
}
