//! The size of the tray icons, without Wayland objects. bar.zig and tray.zig
//! give the values to these functions. `zig build test` runs the tests below.
//!
//! A symbolic icon is 1 logical pixel smaller on each side than a regular
//! icon: with `tray.icon_size = 16`, a regular icon is 16 pixels and a
//! symbolic icon is 14 pixels. The two margins of a symbolic icon are equal,
//! thus the two icons have the same middle line.

const std = @import("std");
const testing = std.testing;


/// The margin on each side of a symbolic icon, in logical pixels.
pub const symbolic_margin = 1;


/// The size of a symbolic icon, in physical pixels, when a regular icon is
/// `size` physical pixels. `scale`: the scale of the output, 120 is 1.
/// The margin is a minimum of 1 physical pixel.
pub fn symbolic_size(size: i32, scale: u32) i32 {
    const margin = @max(1, @divFloor(symbolic_margin * @as(i32, @intCast(scale)), 120));
    return @max(1, size - 2 * margin);
}


/// The position of an icon of `icon_size` in a square of `size`, from the
/// left or from the top.
pub fn offset(size: i32, icon_size: i32) i32 {
    return @divFloor(size - icon_size, 2);
}


test "symbolic_size: 2 logical pixels smaller" {
    try testing.expectEqual(14, symbolic_size(16, 120));
    try testing.expectEqual(28, symbolic_size(32, 240));
}

test "symbolic_size: a fractional scale keeps equal margins" {
    // 1.5: 16 logical pixels are 24 physical pixels.
    try testing.expectEqual(22, symbolic_size(24, 180));
    // 1.25: 16 logical pixels are 20 physical pixels.
    try testing.expectEqual(18, symbolic_size(20, 150));
}

test "symbolic_size: a minimum margin of 1 physical pixel" {
    try testing.expectEqual(14, symbolic_size(16, 60));
}

test "symbolic_size: never smaller than 1 pixel" {
    try testing.expectEqual(1, symbolic_size(2, 120));
    try testing.expectEqual(1, symbolic_size(1, 120));
}

test "offset: the same middle line" {
    try testing.expectEqual(1, offset(16, 14));
    try testing.expectEqual(0, offset(16, 16));
    for ([_]u32 { 120, 150, 180, 240 }) |scale| {
        const size: i32 = @intCast(@divFloor(16 * scale, 120));
        const small = symbolic_size(size, scale);
        // The two middle lines, at twice the size, to keep the half pixels.
        try testing.expectEqual(size, 2 * offset(size, small) + small);
    }
}
