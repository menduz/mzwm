//! The gauge widget, without Wayland objects: vertical bars side by side,
//! one for each value (for example memory and CPU use). widgets/gauge.zig
//! reads the values, and bar.zig draws the rectangles of `layout`.
//! `zig build test` runs the tests below.
//!
//! Each bar has the width of a glyph of the bar font and the height of a
//! tray icon. A border of 1 pixel in the inactive color of the symbolic
//! icons (the text color at 35% on the background of the bar) goes around
//! each bar; two bars share the border between them. The inside has the background of the bar, and the value fills it
//! from the bottom, in the text color at 80%, or in the warning or critical
//! color.

const std = @import("std");
const testing = std.testing;

/// The most bars in one gauge.
pub const max_bars = 4;

/// The value of one bar.
pub const Level = struct {
    /// 0 to 100.
    percent: u8,
    /// The warning or critical color, as 0xRRGGBBAA. null: the text color at
    /// 80%.
    color: ?u32 = null,
};

/// The values of a gauge.
pub const Levels = struct {
    items: [max_bars]Level = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Levels) []const Level {
        return self.items[0..self.len];
    }

    pub fn eql(a: *const Levels, b: *const Levels) bool {
        if (a.len != b.len) return false;
        for (a.slice(), b.slice()) |x, y| {
            if (!std.meta.eql(x, y)) return false;
        }
        return true;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// The width of a gauge with `bars` bars of `bar_width` pixels inside.
pub fn width(bars: usize, bar_width: i32) i32 {
    const n: i32 = @intCast(bars);
    return if (n == 0) 0 else n * bar_width + n + 1;
}

/// The height of the fill of a bar with `inside` pixels inside: 0 at 0%,
/// all of them at 100%, rounded to the nearest pixel.
pub fn fill_height(percent: u8, inside: i32) i32 {
    const p: i32 = @min(percent, 100);
    return @divFloor(inside * p + 50, 100);
}

/// The rectangles of a gauge at (`x`, `y`) with a total height of
/// `height`: first the outer box (the border color), then for each bar its
/// inside (the background) and its fill.
pub fn layout(levels: []const Level, x: i32, y: i32, bar_width: i32, height: i32) struct {
    box: Rect,
    insides: [max_bars]Rect,
    fills: [max_bars]Rect,
} {
    var result: @TypeOf(layout(levels, x, y, bar_width, height)) = .{
        .box = .{ .x = x, .y = y, .width = width(levels.len, bar_width), .height = height },
        .insides = undefined,
        .fills = undefined,
    };
    const inside = @max(0, height - 2);
    for (levels, 0..) |level, i| {
        const left = x + 1 + @as(i32, @intCast(i)) * (bar_width + 1);
        result.insides[i] = .{ .x = left, .y = y + 1, .width = bar_width, .height = inside };
        const filled = fill_height(level.percent, inside);
        result.fills[i] = .{ .x = left, .y = y + 1 + inside - filled, .width = bar_width, .height = filled };
    }
    return result;
}

/// The opacity of the inactive parts of a symbolic icon, in percent, as the
/// symbolic icons of Adwaita and Papirus draw them (opacity 0.35).
pub const inactive_opacity = 35;

/// The color of the border: `fg` at `inactive_opacity` on `bg`, as an
/// opaque color. The colors are 0xRRGGBBAA.
pub fn border_color(fg: u32, bg: u32) u32 {
    var result: u32 = 0xff;
    inline for (.{ 24, 16, 8 }) |shift| {
        const f: u32 = (fg >> shift) & 0xff;
        const b: u32 = (bg >> shift) & 0xff;
        result |= ((f * inactive_opacity + b * (100 - inactive_opacity) + 50) / 100) << shift;
    }
    return result;
}


/// The color of a fill: the color of the level, else `fg` with each color
/// channel at 80%. The colors are 0xRRGGBBAA.
pub fn fill_color(fg: u32, level: Level) u32 {
    if (level.color) |c| return c;
    var result: u32 = fg & 0xff;
    inline for (.{ 24, 16, 8 }) |shift| {
        const c: u32 = (fg >> shift) & 0xff;
        result |= ((c * 8 + 5) / 10) << shift;
    }
    return result;
}


test "width: the bars and one border more than bars" {
    try testing.expectEqual(@as(i32, 0), width(0, 6));
    try testing.expectEqual(@as(i32, 8), width(1, 6));
    // Two bars of 6 pixels share the border between them: 1 + 6 + 1 + 6 + 1.
    try testing.expectEqual(@as(i32, 15), width(2, 6));
}

test "fill_height: rounded, from empty to full" {
    try testing.expectEqual(@as(i32, 0), fill_height(0, 14));
    try testing.expectEqual(@as(i32, 14), fill_height(100, 14));
    try testing.expectEqual(@as(i32, 7), fill_height(50, 14));
    // 14 * 33% = 4.62.
    try testing.expectEqual(@as(i32, 5), fill_height(33, 14));
    try testing.expectEqual(@as(i32, 14), fill_height(250, 14));
}

test "layout: the insides share the borders, the fills start at the bottom" {
    const levels = [_]Level{ .{ .percent = 50 }, .{ .percent = 100 } };
    const l = layout(&levels, 100, 2, 6, 16);
    try testing.expectEqual(Rect{ .x = 100, .y = 2, .width = 15, .height = 16 }, l.box);
    try testing.expectEqual(Rect{ .x = 101, .y = 3, .width = 6, .height = 14 }, l.insides[0]);
    try testing.expectEqual(Rect{ .x = 108, .y = 3, .width = 6, .height = 14 }, l.insides[1]);
    try testing.expectEqual(Rect{ .x = 101, .y = 10, .width = 6, .height = 7 }, l.fills[0]);
    try testing.expectEqual(Rect{ .x = 108, .y = 3, .width = 6, .height = 14 }, l.fills[1]);
}

test "fill_color: the text color at 80%, else the color of the level" {
    // 0xa1 * 0.8 = 128.8: 0x81. The alpha stays.
    try testing.expectEqual(@as(u32, 0x818181ff), fill_color(0xa1a1a1ff, .{ .percent = 10 }));
    try testing.expectEqual(@as(u32, 0x000000ff), fill_color(0x000000ff, .{ .percent = 10 }));
    try testing.expectEqual(@as(u32, 0xff3333ff), fill_color(0xa1a1a1ff, .{ .percent = 95, .color = 0xff3333ff }));
}

test "border_color: the text color at 35% on the background" {
    // 0xa1 * 0.35 + 0x0e * 0.65 = 65.45: 0x41.
    try testing.expectEqual(@as(u32, 0x414549ff), border_color(0xa1a1a1ff, 0x0e1419ff));
    // Black text on white: 0xff * 0.65 = 165.75: 0xa6.
    try testing.expectEqual(@as(u32, 0xa6a6a6ff), border_color(0x000000ff, 0xffffffff));
    try testing.expectEqual(@as(u32, 0xa1a1a1ff), border_color(0xa1a1a1ff, 0xa1a1a1ff));
}

test "Levels.eql: the same values" {
    var a: Levels = .{};
    var b: Levels = .{};
    try testing.expect(a.eql(&b));
    a.items[0] = .{ .percent = 3 };
    a.len = 1;
    try testing.expect(!a.eql(&b));
    b.items[0] = .{ .percent = 3 };
    b.len = 1;
    try testing.expect(a.eql(&b));
    b.items[0].color = 0xff0000ff;
    try testing.expect(!a.eql(&b));
}
