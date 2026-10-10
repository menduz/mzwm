//! The tags of a child window (for example a dialog), without Wayland objects.
//! A child window goes to the output of its parent and gets the tags from
//! these functions. Then the child shows on the same output as its parent,
//! also when the current output of kwm is a different output. Refer to the
//! .init event in window.zig.
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


/// The tags of a new child window. The child gets the tags of the parent. A
/// sticky parent shows on all tags, thus its tags do not tell where it shows.
/// Then the child gets the tags that the output of the parent shows.
pub fn tag(parent_tag: u32, parent_sticky: bool, output_tag: u32) u32 {
    return if (parent_sticky) output_tag else parent_tag;
}


test "tag: the child gets the tags of the parent" {
    try testing.expectEqual(@as(u32, 0b100), tag(0b100, false, 0b1));
    try testing.expectEqual(@as(u32, 0b110), tag(0b110, false, 0b10));
}

test "tag: the child of a sticky parent gets the tags of the output" {
    try testing.expectEqual(@as(u32, 0b1000), tag(0b1, true, 0b1000));
}
