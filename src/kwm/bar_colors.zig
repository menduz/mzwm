//! The colors of the bar, without Wayland objects. bar.zig and tooltip.zig
//! take them from here. `zig build test` runs the tests below.
//!
//! The configuration gives `scheme` and `tags.empty_fg`. With `gtk_colors`,
//! the colors come from xfwm4/themerc of the current GTK theme (refer to
//! theme.zig), and follow each change of the theme. `override_colors` apply
//! after the colors of the theme.

const std = @import("std");
const testing = std.testing;

const config = @import("config");

pub const Bar = @FieldType(config.Config, "bar");

/// The color of a key of xfwm4/themerc, as 0xRRGGBBAA. null: the theme does
/// not give it.
pub const Lookup = *const fn (key: []const u8) ?u32;


/// The scheme of `area`.
pub fn scheme(bar: *const Bar, area: Bar.BarArea, lookup: Lookup) Bar.Scheme {
    return bar.override_scheme(themed(bar.scheme, bar.gtk_colors, lookup), area);
}


/// The text color of the tags without windows. null: the color of the
/// scheme.
pub fn empty_fg(bar: *const Bar, lookup: Lookup) ?u32 {
    const configured = if (bar.tags) |tags| tags.empty_fg else null;
    return themed_empty_fg(configured, bar.gtk_colors, lookup);
}


/// `configured` with the color of the theme.
pub fn themed_empty_fg(configured: ?u32, keys: ?Bar.GtkColors, lookup: Lookup) ?u32 {
    const k = keys orelse return configured;
    return lookup(k.empty_fg) orelse configured;
}


/// `base` with the colors of the theme. A color that the theme does not give
/// stays.
pub fn themed(base: Bar.Scheme, keys: ?Bar.GtkColors, lookup: Lookup) Bar.Scheme {
    const k = keys orelse return base;
    return .{
        .normal = .{
            .fg = lookup(k.fg) orelse base.normal.fg,
            .bg = lookup(k.bg) orelse base.normal.bg,
        },
        .select = .{
            .fg = lookup(k.select_fg) orelse base.select.fg,
            .bg = lookup(k.select_bg) orelse base.select.bg,
        },
    };
}


const base_scheme: Bar.Scheme = .{
    .normal = .{ .fg = 0xa1a1a1ff, .bg = 0x000000ff },
    .select = .{ .fg = 0xffffffff, .bg = 0x000000ff },
};

/// The bar colors of a light scheme of win-classic-theme.
fn light_theme(key: []const u8) ?u32 {
    const colors = .{
        .{ "bar_color", 0xffffffff },
        .{ "bar_text_color", 0x000000ff },
        .{ "bar_selected_text_color", 0x000000ff },
        .{ "bar_empty_text_color", 0x808080ff },
    };
    inline for (colors) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return null;
}

/// A theme with only the background of the bar.
fn background_only(key: []const u8) ?u32 {
    return if (std.mem.eql(u8, key, "bar_color")) 0xffffffff else null;
}

fn no_theme(_: []const u8) ?u32 {
    return null;
}

test "themed: the theme replaces the colors of the configuration" {
    const result = themed(base_scheme, .{}, light_theme);
    try testing.expectEqual(@as(u32, 0x000000ff), result.normal.fg);
    try testing.expectEqual(@as(u32, 0xffffffff), result.normal.bg);
    try testing.expectEqual(@as(u32, 0x000000ff), result.select.fg);
    try testing.expectEqual(@as(u32, 0xffffffff), result.select.bg);
}

test "themed: a color that the theme does not give stays" {
    const result = themed(base_scheme, .{}, background_only);
    try testing.expectEqual(@as(u32, 0xa1a1a1ff), result.normal.fg);
    try testing.expectEqual(@as(u32, 0xffffffff), result.normal.bg);
    try testing.expectEqual(@as(u32, 0xffffffff), result.select.fg);
    try testing.expectEqual(@as(u32, 0xffffffff), result.select.bg);

    try testing.expectEqual(base_scheme, themed(base_scheme, .{}, no_theme));
}

test "themed: without gtk_colors, only the configuration" {
    try testing.expectEqual(base_scheme, themed(base_scheme, null, light_theme));
}

test "themed: the configuration names the keys" {
    const result = themed(base_scheme, .{ .fg = "bar_empty_text_color" }, light_theme);
    try testing.expectEqual(@as(u32, 0x808080ff), result.normal.fg);
}

test "themed_empty_fg: the color of the theme, else of the configuration" {
    try testing.expectEqual(@as(?u32, 0x808080ff), themed_empty_fg(0x1d2023ff, .{}, light_theme));
    try testing.expectEqual(@as(?u32, 0x1d2023ff), themed_empty_fg(0x1d2023ff, .{}, background_only));
    try testing.expectEqual(@as(?u32, 0x1d2023ff), themed_empty_fg(0x1d2023ff, null, light_theme));
    // The theme gives the color, also when the configuration gives none.
    try testing.expectEqual(@as(?u32, 0x808080ff), themed_empty_fg(null, .{}, light_theme));
    try testing.expectEqual(@as(?u32, null), themed_empty_fg(null, .{}, no_theme));
}
