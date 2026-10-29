//! The classes of a script widget, without Wayland objects. script.zig
//! reads them, bar.zig draws the result. `zig build test` runs the tests
//! below.
//!
//!   - "critical", "warning" and "accent" give a color, in this order of
//!     precedence.
//!   - "blink" makes the widget flash. A flashing widget is red ("critical")
//!     when no class gives a color.
//!   - "badge": the color fills the widget, and the text is in the color
//!     `badge_text` (white). A badge is red when no class gives a color. A
//!     flashing badge changes between its fill and the bar without a fill.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


pub const Colors = struct {
    warning: u32,
    critical: u32,
    accent: u32,
    badge_text: u32,
};

pub const Style = struct {
    /// The color of the text, or of the fill of a badge. null: the color of
    /// the bar text.
    color: ?u32 = null,
    blink: bool = false,
    badge: bool = false,
};


pub fn apply(style: *Style, name: []const u8, colors: *const Colors) void {
    if (mem.eql(u8, name, "critical")) style.color = colors.critical;
    if (mem.eql(u8, name, "warning") and style.color != colors.critical) style.color = colors.warning;
    if (mem.eql(u8, name, "accent") and style.color == null) style.color = colors.accent;
    if (mem.eql(u8, name, "blink")) style.blink = true;
    if (mem.eql(u8, name, "badge")) style.badge = true;
}


/// Call after all the classes.
pub fn finish(style: *Style, colors: *const Colors) void {
    if ((style.blink or style.badge) and style.color == null) style.color = colors.critical;
}


pub const Badge = struct {
    fill: u32,
    text: u32,
};


/// The fill and the text color of a badge now. null: no fill, the text in
/// the color of the bar text. `blink_on` is the phase of the flashing.
pub fn badge_now(fill: ?u32, blink: bool, blink_on: bool, colors: *const Colors) ?Badge {
    const f = fill orelse return null;
    if (blink and !blink_on) return null;
    return .{ .fill = f, .text = colors.badge_text };
}


const test_colors: Colors = .{
    .warning = 0xffa500ff,
    .critical = 0xff5555ff,
    .accent = 0xf29718ff,
    .badge_text = 0xffffffff,
};

fn style_of(names: []const []const u8) Style {
    var style: Style = .{};
    for (names) |name| apply(&style, name, &test_colors);
    finish(&style, &test_colors);
    return style;
}

test "critical has precedence over warning and accent" {
    try testing.expectEqual(test_colors.critical, style_of(&.{ "critical", "warning", "accent" }).color);
    try testing.expectEqual(test_colors.critical, style_of(&.{ "accent", "warning", "critical" }).color);
    try testing.expectEqual(test_colors.warning, style_of(&.{ "accent", "warning" }).color);
    try testing.expectEqual(test_colors.accent, style_of(&.{"accent"}).color);
}

test "a widget without classes has the color of the bar text" {
    const style = style_of(&.{});
    try testing.expectEqual(null, style.color);
    try testing.expect(!style.blink and !style.badge);
}

test "a flashing widget or a badge is red without a color class" {
    try testing.expectEqual(test_colors.critical, style_of(&.{"blink"}).color);
    try testing.expectEqual(test_colors.critical, style_of(&.{"badge"}).color);
    try testing.expectEqual(test_colors.accent, style_of(&.{ "badge", "accent" }).color);
}

test "a badge has its fill and white text" {
    const badge = badge_now(test_colors.critical, false, false, &test_colors).?;
    try testing.expectEqual(test_colors.critical, badge.fill);
    try testing.expectEqual(test_colors.badge_text, badge.text);
}

test "a flashing badge has no fill in the off phase" {
    try testing.expect(badge_now(test_colors.critical, true, true, &test_colors) != null);
    try testing.expectEqual(null, badge_now(test_colors.critical, true, false, &test_colors));
}

test "a widget that is not a badge has no fill" {
    try testing.expectEqual(null, badge_now(null, true, true, &test_colors));
    try testing.expectEqual(null, badge_now(null, false, false, &test_colors));
}
