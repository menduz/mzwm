//! The position of a floating window, without Wayland objects. window.zig and
//! seat.zig give the values of a window to these functions.
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


pub const Position = struct {
    x: i32,
    y: i32,
};


pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};


/// Two equal-width columns, with half the windows (rounded up) on the
/// left. Each column divides all its height evenly. One window fills the
/// whole area. The cells include the window's borders and title bar.
pub fn flex_cell(index: usize, count: usize, width: i32, height: i32, outer_gap: i32, inner_gap: i32) Rect {
    std.debug.assert(count > 0 and index < count);
    const columns: usize = @min(count, 2);
    const left_count = count / 2 + count % 2;
    const column: usize = if (index < left_count) 0 else 1;
    const rows = if (column == 0) left_count else count - left_count;
    const row = if (column == 0) index else index - left_count;
    const outer_x = @min(@max(0, outer_gap), @divFloor(@max(0, width), 2));
    const outer_y = @min(@max(0, outer_gap), @divFloor(@max(0, height), 2));
    const x = flex_span(column, columns, @max(0, width - 2 * outer_x), inner_gap);
    const y = flex_span(row, rows, @max(0, height - 2 * outer_y), inner_gap);
    return .{ .x = outer_x + x.start, .y = outer_y + y.start, .width = x.size, .height = y.size };
}


fn flex_span(index: usize, count: usize, extent: i32, gap: i32) struct { start: i32, size: i32 } {
    const n: i64 = @intCast(count);
    const i: i64 = @intCast(index);
    const spacing = if (n == 1) 0 else @min(@max(0, gap), @divFloor(extent, n - 1));
    const available = extent - spacing * (n - 1);
    const start = @divFloor(available * i, n);
    const end = @divFloor(available * (i + 1), n);
    return .{ .start = @intCast(start + spacing * i), .size = @intCast(end - start) };
}


/// The position of a window at the center of an area. The coordinates are
/// relative to the area.
pub fn center(width: i32, height: i32, area_width: i32, area_height: i32) Position {
    return .{
        .x = @divFloor(area_width - width, 2),
        .y = @divFloor(area_height - height, 2),
    };
}


/// The position of a floating window that keeps at least one pixel of the
/// window in the area. Other parts of the window can be outside the area.
/// The coordinates are relative to the area.
pub fn keep_overlap(x: i32, y: i32, width: i32, height: i32, area_width: i32, area_height: i32) Position {
    return .{
        .x = @max(@min(x, area_width - 1), 1 - width),
        .y = @max(@min(y, area_height - 1), 1 - height),
    };
}


/// True when kwm moves a window to the center after the toggle_floating
/// action. Only a window that becomes floating moves. A floating geometry that
/// kwm remembers (remember_floating_geometry) stays as it is.
pub fn centers_on_toggle(floating: bool, remembered_geometry: bool) bool {
    return floating and !remembered_geometry;
}


test "center: the window is at the center of the area" {
    try testing.expectEqual(Position{ .x = 320, .y = 148 }, center(640, 400, 1280, 696));
    // The area has the size of the window.
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, center(1280, 696, 1280, 696));
}

test "center: an odd difference rounds down" {
    try testing.expectEqual(Position{ .x = 0, .y = 0 }, center(1279, 695, 1280, 696));
    try testing.expectEqual(Position{ .x = 1, .y = 1 }, center(1277, 693, 1280, 696));
}

test "center: a window larger than the area has a negative position" {
    try testing.expectEqual(Position{ .x = -10, .y = -5 }, center(1300, 706, 1280, 696));
}

test "keep_overlap: a window partly outside the area stays where it is" {
    try testing.expectEqual(Position{ .x = -299, .y = 10 }, keep_overlap(-299, 10, 300, 200, 1280, 696));
    try testing.expectEqual(Position{ .x = 1279, .y = 695 }, keep_overlap(1279, 695, 300, 200, 1280, 696));
    try testing.expectEqual(Position{ .x = 10, .y = -199 }, keep_overlap(10, -199, 300, 200, 1280, 696));
}

test "keep_overlap: a window without overlap moves back by the smallest distance" {
    // Left and top: the last column and row of the window stay in the area.
    try testing.expectEqual(Position{ .x = -299, .y = -199 }, keep_overlap(-300, -500, 300, 200, 1280, 696));
    // Right and bottom: the first column and row of the window stay in the area.
    try testing.expectEqual(Position{ .x = 1279, .y = 695 }, keep_overlap(1280, 900, 300, 200, 1280, 696));
}

test "keep_overlap: a window larger than the area can be on each side" {
    try testing.expectEqual(Position{ .x = -1999, .y = -10 }, keep_overlap(-2500, -10, 2000, 1000, 1280, 696));
    try testing.expectEqual(Position{ .x = 1279, .y = -10 }, keep_overlap(1500, -10, 2000, 1000, 1280, 696));
}

test "centers_on_toggle: only a window that becomes floating" {
    try testing.expect(centers_on_toggle(true, false));
    // The window becomes tiled. The layout gives its position.
    try testing.expect(!centers_on_toggle(false, false));
    try testing.expect(!centers_on_toggle(false, true));
}

test "centers_on_toggle: a remembered floating geometry stays" {
    try testing.expect(!centers_on_toggle(true, true));
}


test "flex: one window fills the area" {
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 1280, .height = 696 }, flex_cell(0, 1, 1280, 696, 0, 10));
}


test "flex: odd counts fill both columns, with equal cells within each" {
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 640, .height = 348 }, flex_cell(0, 3, 1280, 696, 0, 0));
    try testing.expectEqual(Rect{ .x = 0, .y = 348, .width = 640, .height = 348 }, flex_cell(1, 3, 1280, 696, 0, 0));
    try testing.expectEqual(Rect{ .x = 640, .y = 0, .width = 640, .height = 696 }, flex_cell(2, 3, 1280, 696, 0, 0));
}


test "flex: gaps and rounding leave no unused strip in either column" {
    for (2..14) |count| {
        const left_count = count / 2 + count % 2;
        const first = flex_cell(0, count, 1281, 697, 9, 11);
        const right = flex_cell(left_count, count, 1281, 697, 9, 11);
        try testing.expectEqual(first.x + first.width + 11, right.x);
        try testing.expect(@abs(first.width - right.width) <= 1);
        try testing.expectEqual(@as(i32, 1281 - 9), right.x + right.width);
        for (0..count) |i| {
            const cell = flex_cell(i, count, 1281, 697, 9, 11);
            if (i == 0 or i == left_count) try testing.expectEqual(@as(i32, 9), cell.y);
            if (i + 1 == left_count or i + 1 == count) {
                try testing.expectEqual(@as(i32, 697 - 9), cell.y + cell.height);
            } else {
                const next = flex_cell(i + 1, count, 1281, 697, 9, 11);
                try testing.expectEqual(cell.y + cell.height + 11, next.y);
                try testing.expect(@abs(cell.height - next.height) <= 1);
            }
        }
    }
}


test "flex: small areas and oversized gaps never produce negative sizes" {
    for (0..7) |i| {
        const cell = flex_cell(i, 7, 5, 3, 100, 100);
        try testing.expect(cell.x >= 0 and cell.y >= 0 and cell.width >= 0 and cell.height >= 0);
        try testing.expect(cell.x + cell.width <= 5 and cell.y + cell.height <= 3);
    }
}
