//! The mark of a selected tag in the bar, in the place of the label. The
//! shape of the mark shows the layout of the tag (`Shape`):
//! - monocle: a square.
//! - tile: two columns, 0.6 and 0.4 of the width. The second column (the
//!   stack) has three windows, one gap apart; the last window is the
//!   smallest.
//! - centered master: three columns, 0.2, 0.6 and 0.2 of the width.
//! - float: two windows, the front window at the bottom right, as the
//!   restore button of a title bar of Windows 98.
//!
//! The corners are square.
//!
//! bar.zig draws the mark, also in the menu of the layouts (tooltip.zig).
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


/// The height of a digit for a font of `font_height` pixels: two thirds of
/// the height, as in Terminus.
pub fn digit_height(font_height: i32) i32 {
    return @max(1, @divFloor(font_height * 2 + 1, 3));
}


/// The place of the square, from the top of the text.
pub const Place = struct {
    top: i32,
    side: i32,
};


/// The square covers the place of a digit, on the baseline at `ascent`, and
/// `margin` pixels more on each side.
pub fn place(font_height: i32, ascent: i32, margin: i32) Place {
    const digit = digit_height(font_height);
    return .{ .top = ascent - digit - margin, .side = digit + 2 * margin };
}


/// The side of the master area of the tile layout.
pub const Side = enum { left, right, top, bottom };

/// The direction of the centered master layout: `.horizontal` gives
/// columns, `.vertical` gives rows.
pub const Axis = enum { horizontal, vertical };

/// The shape of the mark: the layout of the tag.
pub const Shape = union(enum) {
    /// The monocle layout, and the layouts without a shape of their own.
    square,
    /// The tile layout: the master area (0.6) on its side, and the stack
    /// (0.4) of three windows.
    tile: Side,
    /// The centered master layout: the master area (0.6) between two
    /// stacks (0.2).
    centered: Axis,
    /// The float layout: two windows.
    float,
};


/// A part of the mark along its width (or its height for rows): it starts
/// at `start` and has `len` pixels.
const Part = struct { start: i32, len: i32 };


/// True when the pixel (`x`, `y`) of a mark of `side` pixels is in the mark.
/// `gap` is the space between two parts and the width of a line, in pixels:
/// 1 for each scale of 1.
pub fn covers(shape_: Shape, side: i32, gap: i32, x: i32, y: i32) bool {
    if (x < 0 or y < 0 or x >= side or y >= side) return false;
    return switch (shape_) {
        .square => true,
        .tile => |master| {
            // The parts are columns. For rows, turn the mark.
            const along, const across = switch (master) {
                .left, .right => .{ x, y },
                .top, .bottom => .{ y, x },
            };
            const free = side - gap;
            const master_len = round_fraction(free, 6);
            const first: Part = .{ .start = 0, .len = switch (master) {
                .left, .top => master_len,
                .right, .bottom => free - master_len,
            } };
            const second: Part = .{ .start = first.len + gap, .len = free - first.len };
            const master_part, const stack = switch (master) {
                .left, .top => .{ first, second },
                .right, .bottom => .{ second, first },
            };
            if (in_parts(&.{master_part}, along)) return true;
            if (!in_parts(&.{stack}, along)) return false;
            // The stack has three windows, one gap apart. The pixels that
            // do not divide by three go to the first windows: the last
            // window is the smallest.
            const free_across = side - 2 * gap;
            const small = @divFloor(free_across, 3);
            const top = small + @as(i32, if (@mod(free_across, 3) > 0) 1 else 0);
            const middle = free_across - top - small;
            return in_parts(&.{
                .{ .start = 0, .len = top },
                .{ .start = top + gap, .len = middle },
                .{ .start = side - small, .len = small },
            }, across);
        },
        .centered => |axis| {
            const along = switch (axis) {
                .horizontal => x,
                .vertical => y,
            };
            const free = side - 2 * gap;
            const stack = round_fraction(free, 2);
            return in_parts(&.{
                .{ .start = 0, .len = stack },
                .{ .start = stack + gap, .len = free - 2 * stack },
                .{ .start = side - stack, .len = stack },
            }, along);
        },
        .float => {
            // Each window is 0.7 of the side. The front window covers the
            // window behind it.
            const size = round_fraction(side, 7);
            const offset = side - size;
            if (x >= offset and y >= offset) return on_frame(size, gap, x - offset, y - offset);
            return on_frame(size, gap, x, y);
        },
    };
}


/// `tenths` tenths of `len`, to the nearest pixel.
fn round_fraction(len: i32, tenths: i32) i32 {
    return @divFloor(len * tenths + 5, 10);
}


/// True when the pixel at `along` is in one of `parts`. Each part is a
/// rectangle across the whole mark.
fn in_parts(parts: []const Part, along: i32) bool {
    for (parts) |part| {
        if (along >= part.start and along < part.start + part.len) return true;
    }
    return false;
}


/// True when the pixel (`x`, `y`) is on the frame of a window of `size`
/// pixels: lines of `line` pixels, and a title bar of two lines at the top.
fn on_frame(size: i32, line: i32, x: i32, y: i32) bool {
    if (x < 0 or y < 0 or x >= size or y >= size) return false;
    return x < line or x >= size - line or y < 2 * line or y >= size - line;
}


test "digit_height: the height of a digit of Terminus" {
    try testing.expectEqual(@as(i32, 8), digit_height(12));
    try testing.expectEqual(@as(i32, 12), digit_height(18));
    try testing.expectEqual(@as(i32, 16), digit_height(24));
    try testing.expectEqual(@as(i32, 1), digit_height(1));
}

test "place: the digit and the margin on each side" {
    // Terminus at scale 1: the digit is on rows 2 to 9 of the text, the
    // square on rows 1 to 10.
    try testing.expectEqual(Place{ .top = 1, .side = 10 }, place(12, 10, 1));
    // At scale 2, the margin is 2 pixels.
    try testing.expectEqual(Place{ .top = 2, .side = 20 }, place(24, 20, 2));
}

/// The rows of a mark of `size` pixels, as "#" for a pixel of the mark.
fn mark_rows(comptime size: i32, shape_: Shape, gap: i32) [size][size]u8 {
    var result: [size][size]u8 = undefined;
    for (0..size) |row| {
        for (0..size) |col| {
            result[row][col] = if (covers(shape_, size, gap, @intCast(col), @intCast(row))) '#' else '.';
        }
    }
    return result;
}

fn expect_mark(comptime size: i32, shape_: Shape, gap: i32, expected: []const []const u8) !void {
    const got = mark_rows(size, shape_, gap);
    try testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |line, row| {
        try testing.expectEqualStrings(line, &got[row]);
    }
}

test "covers: the monocle layout, a square with square corners" {
    try expect_mark(8, .square, 1, &.{
        "########",
        "########",
        "########",
        "########",
        "########",
        "########",
        "########",
        "########",
    });
}

test "covers: the tile layout, two columns of 0.6 and 0.4, three windows in the stack" {
    // The windows of the stack have 3, 3 and 2 rows, with gaps of 1 row.
    try expect_mark(10, .{ .tile = .left }, 1, &.{
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.....",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.....",
        "#####.####",
        "#####.####",
    });
    // At scale 2: windows of 6, 5 and 5 rows, with gaps of 2 rows.
    const got = mark_rows(20, .{ .tile = .left }, 2);
    const window = "###########..#######";
    const gap = "###########.........";
    for (got, 0..) |row, i| {
        const in_gap = (i >= 6 and i < 8) or (i >= 13 and i < 15);
        try testing.expectEqualStrings(if (in_gap) gap else window, &row);
    }
}

test "covers: the master area at the right, and at the top" {
    try expect_mark(10, .{ .tile = .right }, 1, &.{
        "####.#####",
        "####.#####",
        "####.#####",
        ".....#####",
        "####.#####",
        "####.#####",
        "####.#####",
        ".....#####",
        "####.#####",
        "####.#####",
    });
    try expect_mark(10, .{ .tile = .top }, 1, &.{
        "##########",
        "##########",
        "##########",
        "##########",
        "##########",
        "..........",
        "###.###.##",
        "###.###.##",
        "###.###.##",
        "###.###.##",
    });
}

test "covers: the centered master layout, three columns of 0.2, 0.6 and 0.2" {
    try expect_mark(10, .{ .centered = .horizontal }, 1, &.{
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
    });
    // At scale 2: 3, 10 and 3 pixels, with gaps of 2 pixels.
    const got = mark_rows(20, .{ .centered = .horizontal }, 2);
    try testing.expectEqualStrings("###..##########..###", &got[10]);
}

test "covers: the centered master layout with the vertical direction gives rows" {
    const got = mark_rows(10, .{ .centered = .vertical }, 1);
    try testing.expectEqualStrings("##########", &got[0]);
    try testing.expectEqualStrings("..........", &got[2]);
    try testing.expectEqualStrings("##########", &got[4]);
    try testing.expectEqualStrings("..........", &got[7]);
    try testing.expectEqualStrings("##########", &got[9]);
}

test "covers: the float layout, the front window at the bottom right covers the other window" {
    try expect_mark(10, .float, 1, &.{
        "#######...",
        "#######...",
        "#.....#...",
        "#..#######",
        "#..#######",
        "#..#.....#",
        "####.....#",
        "...#.....#",
        "...#.....#",
        "...#######",
    });
}

test "covers: no pixel out of the mark" {
    inline for (.{ Shape.square, Shape{ .tile = .left }, Shape{ .centered = .horizontal }, Shape.float }) |s| {
        try testing.expect(!covers(s, 10, 1, -1, 5));
        try testing.expect(!covers(s, 10, 1, 10, 5));
        try testing.expect(!covers(s, 10, 1, 5, 10));
    }
}
