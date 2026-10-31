//! When the menu of the layouts shows on a selected tag of the bar, without
//! Wayland objects.
//!
//! - The pointer enters the cell of a selected tag: the menu shows.
//! - The pointer enters the cell of a tag that is not selected, and a click
//!   selects the tag: the menu does not show. The pointer did not enter a
//!   selected tag.
//! - A click on a selected tag shows the menu.
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
