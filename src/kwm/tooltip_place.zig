//! The position of the tooltip of the bar, without Wayland objects.
//! tooltip.zig gives the values of the tooltip to this function. `zig build
//! test` runs the tests below. All values are logical pixels in the
//! coordinates of the outputs.
//!
//! A tooltip is at the right of the cursor, thus the cursor does not cover
//! it. A tooltip with click commands is below the pointer, next to the bar:
//! the pointer goes straight down into it. On the way, it does not cross
//! other areas of the bar (the pointer over another area shows the tooltip
//! of that area), or a window (the window gets the focus, and the tooltip
//! goes away after `leave_delay`). The cursor can cover a part of such a
//! tooltip.

const std = @import("std");
const testing = std.testing;


pub const Tooltip = struct {
    pointer_x: i32,
    pointer_y: i32,
    /// The left edge of the area of the bar.
    area_x: i32,
    width: i32,
    output_x: i32,
    output_width: i32,
    /// The top of the tooltip next to the bar: below a bar at the top, or
    /// above a bar at the bottom.
    bar_y: i32,
    bar_top: bool,
    /// The size of the cursor.
    cursor: i32,
    /// A line of the tooltip has a click command.
    clickable: bool,
};


pub const Position = struct { x: i32, y: i32 };


pub fn place(t: Tooltip) Position {
    const right = t.output_x + t.output_width;

    const beside = t.pointer_x + t.cursor;
    if (!t.clickable and beside + t.width <= right) return .{ .x = beside, .y = t.bar_y };

    // Below the cursor. The tooltip starts at the left edge of the area, and
    // the pointer is above the tooltip, not near its right end.
    const reach = @min(t.cursor, @divFloor(t.width, 2));
    var x = @max(t.area_x, t.pointer_x + reach - t.width);
    x = @max(@min(x, right - t.width), t.output_x);

    // Below the cursor, thus the cursor does not cover the tooltip. Above a
    // bar at the bottom, the cursor goes down from the pointer, thus it does
    // not cover the tooltip.
    const y = if (t.bar_top and !t.clickable) @max(t.bar_y, t.pointer_y + t.cursor) else t.bar_y;
    return .{ .x = x, .y = y };
}


/// A bar at the top of an output of 1920 pixels, 20 pixels high. The area
/// starts at x 1500, the pointer is 10 pixels to its right.
const media: Tooltip = .{
    .pointer_x = 1510,
    .pointer_y = 10,
    .area_x = 1500,
    .width = 300,
    .output_x = 0,
    .output_width = 1920,
    .bar_y = 20,
    .bar_top = true,
    .cursor = 24,
    .clickable = false,
};

fn below_pointer(t: Tooltip, p: Position) bool {
    return p.x <= t.pointer_x and t.pointer_x < p.x + t.width;
}

test "place: a tooltip at the right of the cursor, below the bar" {
    try testing.expectEqual(Position{ .x = 1534, .y = 20 }, place(media));
}

test "place: a tooltip with click commands is below the pointer, next to the bar" {
    var t = media;
    t.clickable = true;
    const p = place(t);
    try testing.expectEqual(Position{ .x = 1500, .y = 20 }, p);
    try testing.expect(below_pointer(t, p));
}

test "place: without space at the right of the cursor, below the pointer" {
    var t = media;
    t.width = 410;
    var p = place(t);
    try testing.expectEqual(Position{ .x = 1500, .y = 34 }, p);
    try testing.expect(below_pointer(t, p));
    // The right edge of the output pushes the tooltip to the left.
    t.area_x = 1840;
    t.pointer_x = 1850;
    p = place(t);
    try testing.expectEqual(Position{ .x = 1510, .y = 34 }, p);
    try testing.expect(below_pointer(t, p));
}

test "place: a narrow tooltip of a wide area stays below the pointer" {
    var t = media;
    t.clickable = true;
    t.area_x = 1000;
    t.width = 100;
    const p = place(t);
    // 24 pixels of the tooltip are at the right of the pointer.
    try testing.expectEqual(Position{ .x = 1434, .y = 20 }, p);
    try testing.expect(below_pointer(t, p));
}

test "place: the tooltip stays on the output" {
    var t = media;
    t.clickable = true;
    t.output_x = 1920;
    t.pointer_x = 1925;
    t.area_x = 1920;
    t.width = 600;
    try testing.expectEqual(Position{ .x = 1920, .y = 20 }, place(t));
}

test "place: above a bar at the bottom, the cursor does not cover the tooltip" {
    var t = media;
    t.clickable = true;
    t.bar_top = false;
    t.pointer_y = 1070;
    t.bar_y = 900;
    try testing.expectEqual(Position{ .x = 1500, .y = 900 }, place(t));
}
