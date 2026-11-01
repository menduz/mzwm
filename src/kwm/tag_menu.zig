//! When the menu of the layouts shows on a selected tag of the bar, without
//! Wayland objects.
//!
//! - The pointer enters the cell of a selected tag: the menu shows.
//! - The pointer enters the cell of a tag that is not selected, and a click
//!   selects the tag: the menu does not show. The pointer did not enter a
//!   selected tag.
//! - A click on a selected tag shows the menu.
//! - A left or right click on the tag that the output shows only shows the
//!   menu: it does not do the action of the configuration
//!   (`only_shows_menu`). A click on a line of the menu selects the layout.
//! - The pointer leaves the cell and comes back: the menu shows again.
//!
//! bar.zig holds one `State` for all bars. `zig build test` runs the tests
//! below.

const std = @import("std");
const testing = std.testing;


/// The cell of a tag: the bar and the index of the tag.
pub const Cell = struct {
    owner: *const anyopaque,
    index: usize,
};


pub const State = struct {
    /// The cell under the pointer, or null.
    cell: ?Cell = null,
    /// The menu shows while the pointer stays on `cell` and the tag stays
    /// selected.
    open: bool = false,

    /// The pointer is on `cell` (null: on no tag). `selected`: the tag of
    /// the cell is selected. Only a new cell changes the menu.
    pub fn hover(self: *State, cell: ?Cell, selected: bool) void {
        if (same(self.cell, cell)) return;
        self.cell = cell;
        self.open = cell != null and selected;
    }

    /// A click on `cell`. `selected`: the tag of the cell is selected before
    /// the click.
    pub fn click(self: *State, cell: Cell, selected: bool) void {
        self.cell = cell;
        self.open = selected;
    }

    /// True when the menu shows on `cell`. `selected`: the tag of the cell
    /// is selected now.
    pub fn shows(self: *const State, cell: Cell, selected: bool) bool {
        return self.open and selected and same(self.cell, cell);
    }
};


/// A button of the pointer, for `only_shows_menu`.
pub const Button = enum { left, right, other };


/// A click with `button` on the label of `tag` in the bar. `shown` holds the
/// tags that the output shows. True: the output shows only `tag`, and the
/// button is left or right. Then the click only shows the menu. False: the
/// click also does the action of the configuration. `enabled` is
/// `bar.tags.layout`: false gives false.
pub fn only_shows_menu(enabled: bool, button: Button, tag: u32, shown: u32) bool {
    return enabled and tag == shown and button != .other;
}


fn same(a: ?Cell, b: ?Cell) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.owner == b.?.owner and a.?.index == b.?.index;
}


test "State: the pointer enters a selected tag" {
    var bar: u8 = 0;
    var s: State = .{};
    const tag1: Cell = .{ .owner = &bar, .index = 0 };
    s.hover(tag1, true);
    try testing.expect(s.shows(tag1, true));
    // The tag is not selected any more, for example after Super+9.
    try testing.expect(!s.shows(tag1, false));
}

test "State: a click selects the tag under the pointer, a second click shows the menu" {
    var bar: u8 = 0;
    var s: State = .{};
    const tag1: Cell = .{ .owner = &bar, .index = 0 };
    // Tag 9 shows. The pointer enters tag 1, and a click selects tag 1.
    s.hover(tag1, false);
    s.click(tag1, false);
    s.hover(tag1, true);
    try testing.expect(!s.shows(tag1, true));
    // A click again, in the same place.
    s.click(tag1, true);
    s.hover(tag1, true);
    try testing.expect(s.shows(tag1, true));
}

test "State: the pointer leaves the cell and comes back" {
    var bar: u8 = 0;
    var s: State = .{};
    const tag1: Cell = .{ .owner = &bar, .index = 0 };
    const tag2: Cell = .{ .owner = &bar, .index = 1 };
    s.hover(tag1, false);
    s.click(tag1, false);
    s.hover(null, false);
    try testing.expect(!s.shows(tag1, true));
    s.hover(tag1, true);
    try testing.expect(s.shows(tag1, true));
    // The next cell, and the same cell of another bar.
    s.hover(tag2, true);
    try testing.expect(!s.shows(tag1, true));
    try testing.expect(s.shows(tag2, true));
    var other: u8 = 0;
    const other1: Cell = .{ .owner = &other, .index = 0 };
    s.hover(other1, true);
    try testing.expect(s.shows(other1, true));
    try testing.expect(!s.shows(tag1, true));
}

test "only_shows_menu: a left or right click on the tag that the output shows" {
    try testing.expect(only_shows_menu(true, .left, 1, 1));
    try testing.expect(only_shows_menu(true, .right, 1, 1));
    // The middle button does the action of the configuration.
    try testing.expect(!only_shows_menu(true, .other, 1, 1));
    // Another tag: the click selects it (the action of the configuration).
    try testing.expect(!only_shows_menu(true, .left, 2, 1));
    // The output shows tags 1 and 2: the click does the action of the
    // configuration, for example it shows only tag 1.
    try testing.expect(!only_shows_menu(true, .left, 1, 3));
    // No mark of the layout and no menu.
    try testing.expect(!only_shows_menu(false, .left, 1, 1));
}
