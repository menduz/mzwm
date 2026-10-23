//! The collapsed tray, without Wayland objects. tray.zig and bar.zig give
//! the values of the items and of the pointer to these functions.
//! `zig build test` runs the tests below.
//!
//! With `tray.collapse`, the bar shows only the items with a symbolic icon
//! and the items that need attention. While the pointer is on the tray of a
//! bar, that bar shows all items. An item that needs attention no longer
//! hides again, unless its icon is symbolic. When no item has a symbolic icon
//! or needs attention, the bar shows the last item, so the pointer has an
//! item to go to.

const std = @import("std");
const testing = std.testing;


/// True when the bar shows the item. `expanded`: the pointer is on the tray
/// of this bar.
pub fn shown(collapse: bool, expanded: bool, symbolic: bool, needs_attention: bool) bool {
    if (!collapse or expanded) return true;
    return symbolic or needs_attention;
}


/// The items that the tray shows.
pub const Show = enum {
    /// Every item.
    all,
    /// The items with a symbolic icon and the items that need attention.
    kept,
    /// Only the last item, in the order of the bar.
    last,
};


/// The items that the tray shows. `expanded`: the pointer is on the tray of
/// this bar. `kept`: the number of items with a symbolic icon or that need
/// attention.
pub fn show(collapse: bool, expanded: bool, kept: usize) Show {
    if (!collapse or expanded) return .all;
    return if (kept == 0) .last else .kept;
}


test "shown: without collapse, every item" {
    try testing.expect(shown(false, false, false, false));
    try testing.expect(shown(false, true, false, false));
}

test "shown: collapsed, the symbolic items and the items that need attention" {
    try testing.expect(shown(true, false, true, false));
    try testing.expect(shown(true, false, false, true));
    try testing.expect(shown(true, false, true, true));
    try testing.expect(!shown(true, false, false, false));
}

test "shown: the pointer on the tray shows every item" {
    try testing.expect(shown(true, true, false, false));
}

test "show: every item without collapse, or under the pointer" {
    try testing.expectEqual(Show.all, show(false, false, 0));
    try testing.expectEqual(Show.all, show(false, false, 2));
    try testing.expectEqual(Show.all, show(true, true, 0));
    try testing.expectEqual(Show.all, show(true, true, 2));
}

test "show: collapsed, the kept items, else the last item" {
    try testing.expectEqual(Show.kept, show(true, false, 1));
    try testing.expectEqual(Show.last, show(true, false, 0));
}
