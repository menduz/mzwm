//! The color of the desktop, without Wayland objects. background.zig fills
//! each output with it.
//! `zig build test` runs the tests below.
//!
//! The configuration gives `background`. With `background_gtk_color`, the
//! color comes from xfwm4/themerc of the current GTK theme (refer to
//! theme.zig), and follows each change of the theme.

const std = @import("std");
const testing = std.testing;


/// The color of the desktop, as 0xRRGGBBAA. `background` is the color of the
/// configuration, and `theme` the color of the GTK theme. null: kwm does not
/// fill the desktop (another program draws a wallpaper), thus the theme does
/// not change it.
pub fn color(background: ?u32, theme: ?u32) ?u32 {
    if (background == null) return null;
    return theme orelse background;
}


test "color: the GTK theme replaces the color of the configuration" {
    try testing.expectEqual(@as(?u32, 0x3a6ea5ff), color(0x29272bff, 0x3a6ea5ff));
}

test "color: without a color in the theme, the color of the configuration" {
    try testing.expectEqual(@as(?u32, 0x29272bff), color(0x29272bff, null));
}

test "color: without a background, the theme does not fill the desktop" {
    try testing.expectEqual(@as(?u32, null), color(null, 0x3a6ea5ff));
    try testing.expectEqual(@as(?u32, null), color(null, null));
}
