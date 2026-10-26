//! The gauge widget, without Wayland objects: vertical bars side by side,
//! one for each value (for example memory and CPU use). widgets/gauge.zig
//! reads the values, and bar.zig draws the rectangles of `layout`.
//! `zig build test` runs the tests below.
//!
//! Each bar has the height of a tray icon. A bar has one or more columns
//! (the CPU bar has a column for each core). The inside of a bar is a glyph
//! of the bar font wide, or one pixel for each column if that is wider; the
//! columns divide the inside between them, without borders. A border of 1
//! pixel in the inactive color of the symbolic icons (the text color at 35%
//! on the background of the bar) goes around each bar; two bars share the
//! border between them. The inside has the background of the bar, and the
//! value of each column fills it from the bottom, in the text color at 80%,
//! or in the warning or critical color.

const std = @import("std");
const testing = std.testing;

/// The most bars in one gauge.
pub const max_bars = 4;

/// The most columns of all the bars of one gauge.
pub const max_columns = 256;

/// The value of one column.
pub const Level = struct {
    /// 0 to 100.
    percent: u8,
    /// The warning or critical color, as 0xRRGGBBAA. null: the text color at
    /// 80%.
    color: ?u32 = null,
};

/// The values of a gauge.
pub const Levels = struct {
    /// The columns of all the bars, from left to right.
    columns: [max_columns]Level = undefined,
    len: u16 = 0,
    /// The number of columns of each bar.
    bars: [max_bars]u16 = undefined,
    bars_len: u8 = 0,

    /// Add a bar with `columns` at the right. Columns after `max_columns`
    /// are not added. A bar without columns is not added.
    pub fn add_bar(self: *Levels, columns: []const Level) void {
        if (self.bars_len == max_bars) return;
        const n: u16 = @intCast(@min(columns.len, max_columns - self.len));
        if (n == 0) return;
        @memcpy(self.columns[self.len..][0..n], columns[0..n]);
        self.len += n;
        self.bars[self.bars_len] = n;
        self.bars_len += 1;
    }

    pub fn slice(self: *const Levels) []const Level {
        return self.columns[0..self.len];
    }

    pub fn eql(a: *const Levels, b: *const Levels) bool {
        if (a.len != b.len or a.bars_len != b.bars_len) return false;
        if (!std.mem.eql(u16, a.bars[0..a.bars_len], b.bars[0..b.bars_len])) return false;
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

/// The width of the inside of a bar with `columns` columns: `bar_width`,
/// or one pixel for each column if that is wider.
pub fn inside_width(columns: u16, bar_width: i32) i32 {
    return @max(bar_width, @as(i32, columns));
}

/// The width of a gauge whose bars have `bar_width` pixels inside or
/// more. Refer to `inside_width`.
pub fn width(levels: *const Levels, bar_width: i32) i32 {
    if (levels.bars_len == 0) return 0;
    var result: i32 = 1;
    for (levels.bars[0..levels.bars_len]) |columns| result += inside_width(columns, bar_width) + 1;
    return result;
}

/// The height of the fill of a bar with `inside` pixels inside: 0 at 0%,
/// all of them at 100%, rounded to the nearest pixel.
pub fn fill_height(percent: u8, inside: i32) i32 {
    const p: i32 = @min(percent, 100);
    return @divFloor(inside * p + 50, 100);
}

/// The rectangles of a gauge at (`x`, `y`) with a total height of
/// `height`: first the outer box (the border color), then the inside of
/// each bar (the background), and the fill of each column.
pub fn layout(levels: *const Levels, x: i32, y: i32, bar_width: i32, height: i32) struct {
    box: Rect,
    insides: [max_bars]Rect,
    fills: [max_columns]Rect,
} {
    var result: @TypeOf(layout(levels, x, y, bar_width, height)) = .{
        .box = .{ .x = x, .y = y, .width = width(levels, bar_width), .height = height },
        .insides = undefined,
        .fills = undefined,
    };
    const inside = @max(0, height - 2);
    var left = x + 1;
    var column: usize = 0;
    for (levels.bars[0..levels.bars_len], 0..) |columns, i| {
        const w = inside_width(columns, bar_width);
        result.insides[i] = .{ .x = left, .y = y + 1, .width = w, .height = inside };
        // Column j has the pixels from j * w / n to (j + 1) * w / n.
        const n: i32 = columns;
        for (0..columns) |j| {
            const a = @divFloor(@as(i32, @intCast(j)) * w, n);
            const b = @divFloor(@as(i32, @intCast(j + 1)) * w, n);
            const filled = fill_height(levels.columns[column].percent, inside);
            result.fills[column] = .{ .x = left + a, .y = y + 1 + inside - filled, .width = b - a, .height = filled };
            column += 1;
        }
        left += w + 1;
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


fn test_levels(bars: []const []const Level) Levels {
    var levels: Levels = .{};
    for (bars) |columns| levels.add_bar(columns);
    return levels;
}

test "width: the bars and one border more than bars" {
    try testing.expectEqual(@as(i32, 0), width(&test_levels(&.{}), 6));
    try testing.expectEqual(@as(i32, 8), width(&test_levels(&.{&.{.{ .percent = 0 }}}), 6));
    // Two bars of 6 pixels share the border between them: 1 + 6 + 1 + 6 + 1.
    const one: []const Level = &.{.{ .percent = 0 }};
    try testing.expectEqual(@as(i32, 15), width(&test_levels(&.{ one, one }), 6));
}

test "width: a bar with more columns than the glyph width has a pixel for each column" {
    const one: []const Level = &.{.{ .percent = 0 }};
    const cores: []const Level = &(.{Level{ .percent = 0 }} ** 16);
    try testing.expectEqual(@as(i32, 1 + 6 + 1 + 16 + 1), width(&test_levels(&.{ one, cores }), 6));
    // Fewer columns than the glyph width: the bar stays a glyph wide.
    try testing.expectEqual(@as(i32, 1 + 6 + 1 + 6 + 1), width(&test_levels(&.{ one, cores[0..4] }), 6));
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
    const levels = test_levels(&.{ &.{.{ .percent = 50 }}, &.{.{ .percent = 100 }} });
    const l = layout(&levels, 100, 2, 6, 16);
    try testing.expectEqual(Rect{ .x = 100, .y = 2, .width = 15, .height = 16 }, l.box);
    try testing.expectEqual(Rect{ .x = 101, .y = 3, .width = 6, .height = 14 }, l.insides[0]);
    try testing.expectEqual(Rect{ .x = 108, .y = 3, .width = 6, .height = 14 }, l.insides[1]);
    try testing.expectEqual(Rect{ .x = 101, .y = 10, .width = 6, .height = 7 }, l.fills[0]);
    try testing.expectEqual(Rect{ .x = 108, .y = 3, .width = 6, .height = 14 }, l.fills[1]);
}

test "layout: a column of one pixel for each core, without borders" {
    var cores: [8]Level = undefined;
    for (&cores, 0..) |*c, i| c.* = .{ .percent = @intCast(i * 10) };
    const levels = test_levels(&.{ &.{.{ .percent = 50 }}, &cores });
    const l = layout(&levels, 100, 2, 6, 16);
    try testing.expectEqual(@as(i32, 1 + 6 + 1 + 8 + 1), l.box.width);
    try testing.expectEqual(Rect{ .x = 108, .y = 3, .width = 8, .height = 14 }, l.insides[1]);
    for (0..8) |i| {
        const filled = fill_height(cores[i].percent, 14);
        try testing.expectEqual(Rect{ .x = 108 + @as(i32, @intCast(i)), .y = 3 + 14 - filled, .width = 1, .height = filled }, l.fills[1 + i]);
    }
}

test "layout: fewer columns than the glyph width divide the inside" {
    const levels = test_levels(&.{&.{ .{ .percent = 100 }, .{ .percent = 100 }, .{ .percent = 100 }, .{ .percent = 100 } }});
    const l = layout(&levels, 0, 0, 6, 16);
    // 6 pixels for 4 columns: 1, 2, 1, 2 pixels, side by side.
    try testing.expectEqual(@as(i32, 6), l.insides[0].width);
    const xs = [_]i32{ 1, 2, 4, 5 };
    const ws = [_]i32{ 1, 2, 1, 2 };
    for (0..4) |i| {
        try testing.expectEqual(xs[i], l.fills[i].x);
        try testing.expectEqual(ws[i], l.fills[i].width);
    }
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
    a.add_bar(&.{.{ .percent = 3 }});
    try testing.expect(!a.eql(&b));
    b.add_bar(&.{.{ .percent = 3 }});
    try testing.expect(a.eql(&b));
    b.columns[0].color = 0xff0000ff;
    try testing.expect(!a.eql(&b));
}

test "Levels.eql: the same columns in other bars" {
    var a: Levels = .{};
    var b: Levels = .{};
    a.add_bar(&.{ .{ .percent = 1 }, .{ .percent = 2 } });
    b.add_bar(&.{.{ .percent = 1 }});
    b.add_bar(&.{.{ .percent = 2 }});
    try testing.expect(!a.eql(&b));
}

test "Levels.add_bar: at most max_columns columns" {
    var levels: Levels = .{};
    const many: []const Level = &(.{Level{ .percent = 0 }} ** 200);
    levels.add_bar(many);
    levels.add_bar(many);
    levels.add_bar(many);
    try testing.expectEqual(@as(u16, max_columns), levels.len);
    try testing.expectEqual(@as(u8, 2), levels.bars_len);
    try testing.expectEqual(@as(u16, max_columns - 200), levels.bars[1]);
}
