//! A window that the pointer moves, without Wayland objects. seat.zig and
//! context.zig give the values of the window and of the output to these
//! functions. `zig build test` runs the tests below.
//!
//! - A move of a tiled window by its title bar makes the window floating
//!   when the pointer goes farther than `drag.float_distance`.
//! - A floating window that the pointer releases at an edge of the output
//!   becomes tiled (`drag.tile_edge`). The edge on the side of the master
//!   area gives a master window. The opposite edge gives a window at the top
//!   of the stack. Refer to nmaster.zig for the number of master windows.
//! - While the pointer is at such an edge, the layout shows the other
//!   windows in their places after the drop, and a placeholder shows the
//!   place of the window (drop_preview.zig).

const std = @import("std");
const testing = std.testing;

const types = @import("types.zig");

pub const MasterLocation = types.LayoutMasterLocation;


/// True when a move of (`dx`, `dy`) logical pixels from the press is farther
/// than `distance`. null: a tiled window does not become floating.
pub fn floats(dx: i32, dy: i32, distance: ?i32) bool {
    const limit: i64 = distance orelse return false;
    const x: i64 = dx;
    const y: i64 = dy;
    return x * x + y * y > limit * limit;
}


pub const Area = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};


/// The edge of `area` at `distance` logical pixels or less from the pointer
/// (`x`, `y`). A pointer outside the area is at the edge that it crossed.
/// null: no edge, or `distance` is null. With two edges (a corner), the left
/// or right edge.
pub fn edge(x: i32, y: i32, area: Area, distance: ?i32) ?MasterLocation {
    const d = distance orelse return null;
    if (x - area.x <= d) return .left;
    if (area.x + area.width - 1 - x <= d) return .right;
    if (y - area.y <= d) return .top;
    if (area.y + area.height - 1 - y <= d) return .bottom;
    return null;
}


pub const Place = enum {
    /// The first tiled window.
    master,
    /// The first window after the master windows. In a layout without
    /// master windows, the last window.
    stack,
};


/// The place of a window that the pointer releases at `side`, in a layout
/// with its master area at `master`. null: the window stays floating. A
/// layout without a master side (grid, monocle, scroller, centered_master)
/// uses .left. Refer to `drop_window` in context.zig.
pub fn place(side: MasterLocation, master: MasterLocation) ?Place {
    if (side == master) return .master;
    if (side == opposite(master)) return .stack;
    return null;
}


fn opposite(side: MasterLocation) MasterLocation {
    return switch (side) {
        .left => .right,
        .right => .left,
        .top => .bottom,
        .bottom => .top,
    };
}


/// The placeholder of a window in the place `slot` of the layout. The slot
/// has the coordinates of the window in the exclusive area of the output,
/// at (`origin_x`, `origin_y`) in the coordinates of the compositor. The
/// placeholder also covers the border of the window.
pub fn placeholder(slot: Area, origin_x: i32, origin_y: i32, border: i32) Area {
    return .{
        .x = origin_x + slot.x - border,
        .y = origin_y + slot.y - border,
        .width = @max(1, slot.width + 2 * border),
        .height = @max(1, slot.height + 2 * border),
    };
}


pub const Size = struct {
    width: i32,
    height: i32,
};


/// The size of a window that a drag of its title in the bar takes out of its
/// place. A window that was not `full` (maximized, or alone in the layout)
/// keeps its size `current`. A full window gets the floating size that kwm
/// remembers, else two thirds of the exclusive area `area`.
pub fn detach_size(full: bool, current: Size, remembered: ?Size, area: Size) Size {
    if (!full) return current;
    if (remembered) |size| return size;
    return .{
        .width = @max(1, @divFloor(area.width * 2, 3)),
        .height = @max(1, @divFloor(area.height * 2, 3)),
    };
}


/// The place (x, y) of a window of `size` that a drag of its title in the
/// bar takes out of the layout. The window was at `window_x` with
/// `window_width` at the press at `press_x`. The pointer, now at
/// (`pointer_x`, `pointer_y`), keeps its place along the width of the
/// window, and is `grab` pixels below the top of the title bar.
/// `title_height` is the height of the title bar above the window: 0 for a
/// window without a title bar of kwm. All values are in the coordinates of
/// the exclusive area of the output.
pub fn detach_place(
    size: Size,
    window_x: i32,
    window_width: i32,
    press_x: i32,
    pointer_x: i32,
    pointer_y: i32,
    title_height: i32,
    grab: i32,
) struct { x: i32, y: i32 } {
    const along: i64 = std.math.clamp(press_x - window_x, 0, @max(0, window_width - 1));
    const offset: i64 = if (window_width > 0) @divFloor(along * size.width, window_width) else 0;
    return .{
        .x = pointer_x - @as(i32, @intCast(offset)),
        .y = pointer_y - grab + title_height,
    };
}


/// The color 0xRRGGBBAA with each color channel multiplied by the alpha
/// channel: wp_single_pixel_buffer_v1 takes premultiplied values.
pub fn premultiplied(color: u32) u32 {
    const a: u32 = color & 0xff;
    var result: u32 = a;
    inline for (.{ 24, 16, 8 }) |shift| {
        const c: u32 = (color >> shift) & 0xff;
        result |= ((c * a + 127) / 255) << shift;
    }
    return result;
}


test "floats: only farther than the distance" {
    try testing.expect(!floats(0, 0, 32));
    try testing.expect(!floats(32, 0, 32));
    try testing.expect(!floats(0, -32, 32));
    try testing.expect(floats(33, 0, 32));
    try testing.expect(floats(0, -33, 32));
    // 23 * 23 + 23 * 23 = 1058 > 1024: farther than 32 on a diagonal.
    try testing.expect(floats(23, 23, 32));
    try testing.expect(!floats(22, 22, 32));
}

test "floats: null keeps the window tiled" {
    try testing.expect(!floats(1000, 1000, null));
}

test "edge: the pointer near an edge of the output" {
    const area: Area = .{ .x = 1920, .y = 0, .width = 1920, .height = 1080 };
    try testing.expectEqual(@as(?MasterLocation, .left), edge(1920, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .left), edge(1928, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, null), edge(1929, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .right), edge(3839, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .right), edge(3831, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, null), edge(3830, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .top), edge(2500, 0, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .bottom), edge(2500, 1079, area, 8));
    try testing.expectEqual(@as(?MasterLocation, null), edge(2500, 500, area, 8));
}

test "edge: a pointer outside the output, and a corner" {
    const area: Area = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    try testing.expectEqual(@as(?MasterLocation, .left), edge(-40, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .right), edge(2000, 500, area, 8));
    try testing.expectEqual(@as(?MasterLocation, .left), edge(0, 0, area, 8));
    try testing.expectEqual(@as(?MasterLocation, null), edge(0, 500, area, null));
}

test "place: the master side gives a master, the opposite side the stack" {
    try testing.expectEqual(@as(?Place, .master), place(.left, .left));
    try testing.expectEqual(@as(?Place, .stack), place(.right, .left));
    try testing.expectEqual(@as(?Place, null), place(.top, .left));
    try testing.expectEqual(@as(?Place, null), place(.bottom, .left));

    try testing.expectEqual(@as(?Place, .master), place(.right, .right));
    try testing.expectEqual(@as(?Place, .stack), place(.left, .right));

    try testing.expectEqual(@as(?Place, .master), place(.top, .top));
    try testing.expectEqual(@as(?Place, .stack), place(.bottom, .top));
    try testing.expectEqual(@as(?Place, null), place(.left, .top));
}

test "placeholder: the slot and the border, in the coordinates of the compositor" {
    const slot: Area = .{ .x = 9, .y = 9, .width = 752, .height = 663 };
    try testing.expectEqual(Area{ .x = 1927, .y = 27, .width = 756, .height = 667 }, placeholder(slot, 1920, 20, 2));
    try testing.expectEqual(Area{ .x = 0, .y = 0, .width = 1, .height = 4 }, placeholder(.{ .x = 2, .y = 2, .width = -10, .height = 0 }, 0, 0, 2));
}

test "premultiplied: the color channels take the alpha" {
    try testing.expectEqual(@as(u32, 0xf29718ff), premultiplied(0xf29718ff));
    try testing.expectEqual(@as(u32, 0x00000000), premultiplied(0xf2971800));
    // 0xf2 * 0x40 / 0xff = 60.7: 0x3d.
    try testing.expectEqual(@as(u32, 0x3d260640), premultiplied(0xf2971840));
}

test "detach_size: a full window gets the remembered size, else two thirds of the area" {
    const full: Size = .{ .width = 1280, .height = 700 };
    try testing.expectEqual(Size{ .width = 640, .height = 480 }, detach_size(true, full, .{ .width = 640, .height = 480 }, full));
    try testing.expectEqual(Size{ .width = 853, .height = 466 }, detach_size(true, full, null, full));
}

test "detach_size: another window keeps its size" {
    const current: Size = .{ .width = 500, .height = 682 };
    try testing.expectEqual(current, detach_size(false, current, .{ .width = 640, .height = 480 }, .{ .width = 1280, .height = 700 }));
}

test "detach_place: the pointer keeps its place along the width, on the title bar" {
    // A press at the middle of a window of 1280 pixels: the window of 853
    // pixels has its middle under the pointer. The pointer is 9 pixels
    // below the top of the title bar of 19 pixels.
    const middle = detach_place(.{ .width = 853, .height = 466 }, 0, 1280, 640, 700, 100, 19, 9);
    try testing.expectEqual(@as(i32, 700 - 426), middle.x);
    try testing.expectEqual(@as(i32, 110), middle.y);
    // A press at the left end keeps the left end under the pointer.
    try testing.expectEqual(@as(i32, 300), detach_place(.{ .width = 800, .height = 400 }, 0, 1280, 0, 300, 50, 19, 9).x);
    // A window without a title bar of kwm: the pointer is 9 pixels below
    // the top of the window.
    try testing.expectEqual(@as(i32, 41), detach_place(.{ .width = 800, .height = 400 }, 0, 1280, 0, 300, 50, 0, 9).y);
}

test "detach_place: a press out of the window counts as its nearest end" {
    try testing.expectEqual(@as(i32, 300), detach_place(.{ .width = 800, .height = 400 }, 100, 1280, 20, 300, 50, 19, 9).x);
    try testing.expectEqual(@as(i32, 300 - 799), detach_place(.{ .width = 800, .height = 400 }, 0, 800, 5000, 300, 50, 19, 9).x);
}
