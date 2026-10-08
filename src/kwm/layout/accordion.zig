//! The stack of the deck layout as an accordion, without Wayland objects.
//! deck.zig gives the stack area, the number of windows and the open window
//! to these functions. `zig build test` runs the tests below.
//!
//!     [title bar of a collapsed window]
//!     [title bar of a collapsed window]
//!     [title bar of the open window   ]
//!     |contents of the open window    |
//!     [title bar of a collapsed window]
//!
//! The windows keep the order of the stack. All the windows have the size of
//! the open window, thus a change of the open window moves windows and changes
//! their clip, but does not resize them. A collapsed window shows only its
//! title bar and the border above it: deck.zig clips the rest. The last
//! collapsed window also shows the border below its title bar, at the bottom
//! of the area. Below the open window, its border and the border of the next
//! window share one row.

const std = @import("std");
const testing = std.testing;


pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Place = struct {
    rect: Rect,
    collapsed: bool,
    /// The border below the title bar of a collapsed window shows: the last
    /// window of the stack.
    bottom_border: bool = false,
};


/// The place of the window `index` of `count` windows in `area`. `open` is
/// the index of the open window. `title` is the height of a title bar: the
/// visible part of a collapsed window. `border` is the border around a
/// window. As for the other windows of a layout, the borders of the first and
/// the last window are in the gap around `area`.
///
/// Between two collapsed windows there is the border of the next window.
/// Below the open window there are its border and the border of the next
/// window, which share one row. When the open window is the last one, the
/// window above it shows the border below its title bar, and this border
/// shares one row with the border of the open window. Thus the windows have
/// one size for each open window.
pub fn place(area: Rect, count: usize, index: usize, open: usize, title: i32, border: i32) Place {
    if (count <= 1) return .{ .rect = area, .collapsed = false };
    const n: i32 = @intCast(count);
    const i: i32 = @intCast(@min(index, count - 1));
    const o: i32 = @intCast(@min(open, count - 1));

    // A collapsed window and the border of the next window.
    const step = title + border;
    // The two borders that share one row: one row less than two borders.
    const shared = border - 1;
    const height = @max(title, area.height - (n - 1) * step - shared);

    var y = area.y + i * step;
    if (o == n - 1) {
        // The window above the open window shows its bottom border.
        if (i == o) y += shared;
    } else if (i > o) {
        // The open window is taller than a title bar. Its border and the
        // border of the next window share one row.
        y += height - title + shared;
    }

    return .{
        .rect = .{ .x = area.x, .y = y, .width = area.width, .height = height },
        .collapsed = i != o,
        .bottom_border = i != o and ((o < n - 1 and i == n - 1) or (o == n - 1 and i == n - 2)),
    };
}


const test_area: Rect = .{ .x = 700, .y = 10, .width = 560, .height = 680 };

test "place: one window fills the area" {
    try testing.expectEqual(Place{ .rect = test_area, .collapsed = false }, place(test_area, 1, 0, 0, 19, 3));
}

test "place: the open window between collapsed windows" {
    // Four windows, the second one is open: title bars of 19 pixels, a
    // border of 3 pixels. The height of each window: 680 - 3 * 22 - 2.
    const height = 612;
    try testing.expectEqual(Place{ .rect = .{ .x = 700, .y = 10, .width = 560, .height = height }, .collapsed = true }, place(test_area, 4, 0, 1, 19, 3));
    try testing.expectEqual(Place{ .rect = .{ .x = 700, .y = 32, .width = 560, .height = height }, .collapsed = false }, place(test_area, 4, 1, 1, 19, 3));
    // Below the open window: its bottom border and the border of this one,
    // less one row.
    try testing.expectEqual(Place{ .rect = .{ .x = 700, .y = 32 + height + 5, .width = 560, .height = height }, .collapsed = true }, place(test_area, 4, 2, 1, 19, 3));
    try testing.expectEqual(Place{ .rect = .{ .x = 700, .y = 32 + height + 5 + 22, .width = 560, .height = height }, .collapsed = true, .bottom_border = true }, place(test_area, 4, 3, 1, 19, 3));
}

test "place: the stack ends where the border of a window of the area ends" {
    // A window of the whole area has its border below the area: the stack
    // ends there too, for each open window.
    const end = test_area.y + test_area.height + 3;
    for (2..8) |count| {
        for (0..count) |open| {
            const last = place(test_area, count, count - 1, open, 19, 3);
            const visible = if (last.collapsed) 19 + 3 else last.rect.height + 3;
            try testing.expectEqual(end, last.rect.y + visible);
            // The first window starts at the top of the area.
            try testing.expectEqual(test_area.y, place(test_area, count, 0, open, 19, 3).rect.y);
        }
    }
}

test "place: the border below a title bar shows above the open window or at the bottom" {
    for (0..4) |open| {
        for (0..4) |index| {
            const p = place(test_area, 4, index, open, 19, 3);
            const expected = (open < 3 and index == 3) or (open == 3 and index == 2);
            try testing.expectEqual(expected, p.bottom_border);
        }
    }
}

test "place: the open window at the bottom shares a border row with the window above" {
    const above = place(test_area, 4, 2, 3, 19, 3);
    const open = place(test_area, 4, 3, 3, 19, 3);
    // The title bar and the border of the window above, then the border of the
    // open window: one row is shared.
    try testing.expectEqual(above.rect.y + 19 + 3 + 3 - 1, open.rect.y);
}

test "place: all the windows have one size, for each open window" {
    for (0..4) |open| {
        for (0..4) |index| {
            const p = place(test_area, 4, index, open, 19, 3);
            try testing.expectEqual(@as(i32, 560), p.rect.width);
            try testing.expectEqual(@as(i32, 612), p.rect.height);
            try testing.expectEqual(index != open, p.collapsed);
        }
    }
}

test "place: the title bars do not overlap" {
    for (0..4) |open| {
        var previous_end: i32 = test_area.y;
        for (0..4) |index| {
            const p = place(test_area, 4, index, open, 19, 3);
            try testing.expect(p.rect.y >= previous_end);
            previous_end = p.rect.y + (if (p.collapsed) @as(i32, 19) else p.rect.height);
        }
    }
}
