//! The mark of a selected tag in the bar: a square with round corners in the
//! place of the label, as the glyph U+F14FB (nf-md-square_rounded) of Nerd
//! Fonts, but in whole pixels. bar.zig draws it. `zig build test` runs the
//! tests below.

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
    const r = radius(size);
    const from_edge = @min(row, size - 1 - row);
    if (from_edge < 0 or from_edge >= r) return 0;
    const dy: f32 = @floatFromInt(r - from_edge);
    const rf: f32 = @floatFromInt(r);
    const dx: i32 = @intFromFloat(@round(@sqrt(rf * rf - dy * dy)));
    return r - dx;
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
