//! The mark of a selected tag in the bar, in the place of the label. The
//! shape of the mark shows the layout of the tag (`Shape`):
//! - monocle: a square with round corners, as the glyph U+F14FB
//!   (nf-md-square_rounded) of Nerd Fonts, but in whole pixels.
//! - tile: two columns with round corners, 0.6 and 0.4 of the width.
//! - centered master: three columns, 0.2, 0.6 and 0.2 of the width.
//! - float: two windows, the front window at the bottom right, as the
//!   restore button of a title bar of Windows 98.
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


/// The radius of the corners of a square of `size` pixels: about an eighth
/// of the side, and 1 pixel or more.
pub fn radius(size: i32) i32 {
    return @max(1, @divFloor(size + 4, 8));
}


/// The pixels at each end of row `row` of a square of `size` pixels that are
/// not in the square: the corners are quarter circles of `radius(size)`.
pub fn inset(size: i32, row: i32) i32 {
    return inset_of(size, row, radius(size));
}


/// The pixels at each end of row `row` of a rectangle of `height` pixels
/// that are not in the rectangle: the corners are quarter circles of `r`.
fn inset_of(height: i32, row: i32, r: i32) i32 {
    const from_edge = @min(row, height - 1 - row);
    if (from_edge < 0 or from_edge >= r) return 0;
    const dy: f32 = @floatFromInt(r - from_edge);
    const rf: f32 = @floatFromInt(r);
    const dx: i32 = @intFromFloat(@round(@sqrt(rf * rf - dy * dy)));
    return r - dx;
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
    /// (0.4).
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
        .square => in_rounded(side, side, x, y, radius(side)),
        .tile => |master| {
            // The parts are columns. For rows, turn the mark.
            const along, const across = switch (master) {
                .left, .right => .{ x, y },
                .top, .bottom => .{ y, x },
            };
            const free = side - gap;
            const master_len = round_fraction(free, 6);
            const first: i32 = switch (master) {
                .left, .top => master_len,
                .right, .bottom => free - master_len,
            };
            return in_parts(&.{
                .{ .start = 0, .len = first },
                .{ .start = first + gap, .len = free - first },
            }, side, along, across, master == .top or master == .bottom);
        },
        .centered => |axis| {
            const along, const across = switch (axis) {
                .horizontal => .{ x, y },
                .vertical => .{ y, x },
            };
            const free = side - 2 * gap;
            const stack = round_fraction(free, 2);
            return in_parts(&.{
                .{ .start = 0, .len = stack },
                .{ .start = stack + gap, .len = free - 2 * stack },
                .{ .start = side - stack, .len = stack },
            }, side, along, across, axis == .vertical);
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


/// True when the pixel at `along` and `across` is in one of `parts`. Each
/// part is a rectangle with round corners, `side` pixels across. `turned`:
/// the parts are rows, thus `along` is the row.
fn in_parts(parts: []const Part, side: i32, along: i32, across: i32, turned: bool) bool {
    const r = radius(side);
    for (parts) |part| {
        if (along < part.start or along >= part.start + part.len) continue;
        const a = along - part.start;
        // The corners must not be larger than half of the part.
        const part_r = @max(1, @min(r, @divFloor(part.len, 2)));
        return if (turned) in_rounded(side, part.len, across, a, part_r)
            else in_rounded(part.len, side, a, across, part_r);
    }
    return false;
}


/// True when the pixel (`x`, `y`) is in a rectangle of `width` by `height`
/// pixels with corners of radius `r`.
fn in_rounded(width: i32, height: i32, x: i32, y: i32, r: i32) bool {
    if (x < 0 or y < 0 or x >= width or y >= height) return false;
    const in = inset_of(height, y, r);
    return x >= in and x < width - in;
}


/// True when the pixel (`x`, `y`) is on the frame of a window of `size`
/// pixels: lines of `line` pixels, and a title bar of two lines at the top.
fn on_frame(size: i32, line: i32, x: i32, y: i32) bool {
    if (x < 0 or y < 0 or x >= size or y >= size) return false;
    return x < line or x >= size - line or y < 2 * line or y >= size - line;
}


/// The rows of a square of `size` pixels, as "#" for a pixel of the square.
fn shape(comptime size: i32) [size][size]u8 {
    var result: [size][size]u8 = undefined;
    for (0..size) |row| {
        const in = inset(size, @intCast(row));
        for (0..size) |col| {
            const c: i32 = @intCast(col);
            result[row][col] = if (c < in or c >= size - in) '.' else '#';
        }
    }
    return result;
}

fn expect_shape(comptime size: i32, expected: []const []const u8) !void {
    const got = shape(size);
    for (expected, 0..) |line, row| {
        try testing.expectEqualStrings(line, &got[row]);
    }
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

test "radius: an eighth of the side, 1 pixel or more" {
    try testing.expectEqual(@as(i32, 1), radius(4));
    try testing.expectEqual(@as(i32, 1), radius(8));
    try testing.expectEqual(@as(i32, 2), radius(16));
    try testing.expectEqual(@as(i32, 3), radius(24));
}

test "inset: at scale 1, the square of a digit of Terminus loses its corner pixels" {
    try expect_shape(8, &.{
        ".######.",
        "########",
        "########",
        "########",
        "########",
        "########",
        "########",
        ".######.",
    });
}

test "inset: at scale 2, each corner loses two pixels" {
    const got = shape(16);
    try testing.expectEqualStrings("..############..", &got[0]);
    try testing.expectEqualStrings("################", &got[1]);
    try testing.expectEqualStrings("################", &got[8]);
    try testing.expectEqualStrings("################", &got[14]);
    try testing.expectEqualStrings("..############..", &got[15]);
}

test "inset: the corners of a large square are quarter circles" {
    try testing.expectEqual(@as(i32, 3), inset(24, 0));
    try testing.expectEqual(@as(i32, 1), inset(24, 1));
    try testing.expectEqual(@as(i32, 0), inset(24, 2));
    try testing.expectEqual(@as(i32, 0), inset(24, 12));
    try testing.expectEqual(@as(i32, 1), inset(24, 22));
    try testing.expectEqual(@as(i32, 3), inset(24, 23));
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

test "covers: the square of the monocle layout is the square of a selected tag" {
    try expect_mark(8, .square, 1, &.{
        ".######.",
        "########",
        "########",
        "########",
        "########",
        "########",
        "########",
        ".######.",
    });
}

test "covers: the tile layout, two columns of 0.6 and 0.4 with round corners" {
    try expect_mark(10, .{ .tile = .left }, 1, &.{
        ".###...##.",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.####",
        "#####.####",
        ".###...##.",
    });
}

test "covers: the master area at the right, and at the top" {
    try expect_mark(10, .{ .tile = .right }, 1, &.{
        ".##...###.",
        "####.#####",
        "####.#####",
        "####.#####",
        "####.#####",
        "####.#####",
        "####.#####",
        "####.#####",
        "####.#####",
        ".##...###.",
    });
    try expect_mark(10, .{ .tile = .top }, 1, &.{
        ".########.",
        "##########",
        "##########",
        "##########",
        ".########.",
        "..........",
        ".########.",
        "##########",
        "##########",
        ".########.",
    });
}

test "covers: the centered master layout, three columns of 0.2, 0.6 and 0.2" {
    try expect_mark(10, .{ .centered = .horizontal }, 1, &.{
        "....##....",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "##.####.##",
        "....##....",
    });
    // At scale 2: 3, 10 and 3 pixels, with gaps of 2 pixels.
    const got = mark_rows(20, .{ .centered = .horizontal }, 2);
    try testing.expectEqualStrings("###..##########..###", &got[10]);
}

test "covers: the centered master layout with the vertical direction gives rows" {
    const got = mark_rows(10, .{ .centered = .vertical }, 1);
    try testing.expectEqualStrings(".########.", &got[0]);
    try testing.expectEqualStrings("..........", &got[2]);
    try testing.expectEqualStrings("##########", &got[4]);
    try testing.expectEqualStrings("..........", &got[7]);
    try testing.expectEqualStrings(".########.", &got[9]);
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
