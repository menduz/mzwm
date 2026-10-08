//! The focus that follows the pointer (sloppy_focus), without Wayland
//! objects. seat.zig gives the values of the window below the pointer to this
//! function. `zig build test` runs the tests below.
//!
//! In a workspace where all windows float, as on a desktop of Windows, a
//! window gets the focus only with a click. The pointer can then move over
//! other windows on the way to a window. river tells kwm about a click only
//! at the press of the button (window_interaction), thus the focus changes at
//! the press, not at the release.


const std = @import("std");
const testing = std.testing;


pub const Window = struct {
    /// A collapsed window of the deck layout. It opens only with a click or
    /// with the focus keys.
    collapsed: bool,
    /// The number of visible windows on the output of the window that the
    /// layout places (not floating).
    tiled_windows: usize,
};


/// True when the pointer over `window` gives the focus to it.
pub fn focuses(sloppy_focus: bool, window: Window) bool {
    if (!sloppy_focus) return false;
    if (window.collapsed) return false;
    return window.tiled_windows > 0;
}


test "focuses: the pointer focuses a window in a workspace with tiled windows" {
    try testing.expect(focuses(true, .{ .collapsed = false, .tiled_windows = 2 }));
    // A floating window above a tiled window.
    try testing.expect(focuses(true, .{ .collapsed = false, .tiled_windows = 1 }));
}

test "focuses: only a click focuses a window when all windows float" {
    try testing.expect(!focuses(true, .{ .collapsed = false, .tiled_windows = 0 }));
}

test "focuses: only a click or the focus keys open a collapsed window" {
    try testing.expect(!focuses(true, .{ .collapsed = true, .tiled_windows = 3 }));
}

test "focuses: without sloppy_focus, the pointer does not focus" {
    try testing.expect(!focuses(false, .{ .collapsed = false, .tiled_windows = 2 }));
}
