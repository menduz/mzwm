//! The cycle of the layouts, without Wayland objects.
//!
//! - `cycle_layouts` in the configuration holds the layouts of the cycle, in
//!   their order. The other layouts stay: switch_layout, default_layout and
//!   the rules can select them. cycle_layout of output.zig uses `next`.
//! - A quick second press of the binding of the tag that the output shows
//!   goes to the next layout (`TagRepeat`). seat.zig uses it for
//!   set_output_tag.
//! - A left click on the tag that the output shows in the bar goes to the
//!   next layout at once, without a delay. A right click goes to the
//!   previous layout (`click_direction`). bar.zig uses it.
//!
//! `zig build test` runs the tests below.

const std = @import("std");
const testing = std.testing;


/// The layout after `current` in `list`, or before it when `forward` is
/// false. After the last layout comes the first layout again. A layout that
/// is not in `list` goes to the first layout, or to the last layout. null:
/// `list` is empty.
pub fn next(comptime T: type, list: []const T, current: T, forward: bool) ?T {
    if (list.len == 0) return null;
    const i = std.mem.indexOfScalar(T, list, current) orelse
        return if (forward) list[0] else list[list.len - 1];
    return if (forward) list[(i + 1) % list.len] else list[(i + list.len - 1) % list.len];
}


/// A button of the pointer, for `click_direction`.
pub const Button = enum { left, right, other };


/// A click with `button` on the label of `tag` in the bar. `shown` holds
/// the tags that the output shows. When the output shows only `tag`, a left
/// click goes to the next layout (true), and a right click to the previous
/// layout (false). null: the click does the action of the configuration.
/// `enabled` is `bar.tags.layout`: false gives null.
pub fn click_direction(enabled: bool, button: Button, tag: u32, shown: u32) ?bool {
    if (!enabled or tag != shown) return null;
    return switch (button) {
        .left => true,
        .right => false,
        .other => null,
    };
}


/// The last press of a binding that shows a tag.
pub const TagRepeat = struct {
    output: ?*const anyopaque = null,
    tag: u32 = 0,
    /// Milliseconds of the awake clock.
    time: i64 = 0,

    /// A press of a binding that shows `tag` on `output`, at `now`
    /// milliseconds. `shown` holds the tags that the output shows. True:
    /// the output shows `tag` already, and the last press for the same tag
    /// and output is `delay` milliseconds before `now` or less. Then the
    /// press goes to the next layout. `delay` null: always false.
    pub fn press(self: *TagRepeat, output: *const anyopaque, tag: u32, shown: u32, now: i64, delay: ?u32) bool {
        const repeat = if (delay) |d|
            shown == tag and self.output == output and self.tag == tag and now - self.time <= d
        else false;
        self.* = .{ .output = output, .tag = tag, .time = now };
        return repeat;
    }
};


const L = enum { tile, grid, monocle, deck, scroller, centered_master, float };

test "next: the layouts of the list, in a circle" {
    const list = [_]L{ .tile, .centered_master, .float, .monocle };
    try testing.expectEqual(@as(?L, .centered_master), next(L, &list, .tile, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .float, true));
    try testing.expectEqual(@as(?L, .tile), next(L, &list, .monocle, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .tile, false));
    try testing.expectEqual(@as(?L, .float), next(L, &list, .monocle, false));
}

test "next: a layout out of the list goes into the list" {
    const list = [_]L{ .tile, .centered_master, .float, .monocle };
    try testing.expectEqual(@as(?L, .tile), next(L, &list, .grid, true));
    try testing.expectEqual(@as(?L, .monocle), next(L, &list, .deck, false));
    try testing.expectEqual(@as(?L, null), next(L, &.{}, .tile, true));
    try testing.expectEqual(@as(?L, .tile), next(L, &.{.tile}, .tile, true));
}

test "TagRepeat: a quick second press of the shown tag" {
    var a: u8 = 0;
    var b: u8 = 0;
    var r: TagRepeat = .{};
    // Tag 2 shows. A press of tag 1 shows tag 1, a quick press again goes to
    // the next layout, and the next quick press also.
    try testing.expect(!r.press(&a, 1, 2, 1000, 500));
    try testing.expect(r.press(&a, 1, 1, 1300, 500));
    try testing.expect(r.press(&a, 1, 1, 1800, 500));
    // A slow press does nothing, but a quick press after it goes on.
    try testing.expect(!r.press(&a, 1, 1, 2400, 500));
    try testing.expect(r.press(&a, 1, 1, 2500, 500));
    // Another tag, or the same tag on another output.
    try testing.expect(!r.press(&a, 2, 1, 2600, 500));
    try testing.expect(!r.press(&b, 2, 2, 2700, 500));
    // The output shows more tags than the tag of the binding.
    try testing.expect(!r.press(&b, 2, 3, 2800, 500));
}

test "TagRepeat: no delay, no cycle" {
    var a: u8 = 0;
    var r: TagRepeat = .{};
    try testing.expect(!r.press(&a, 1, 1, 1000, null));
    try testing.expect(!r.press(&a, 1, 1, 1001, null));
}

test "click_direction: only a click on the tag that the output shows" {
    try testing.expectEqual(@as(?bool, true), click_direction(true, .left, 1, 1));
    try testing.expectEqual(@as(?bool, false), click_direction(true, .right, 1, 1));
    try testing.expectEqual(@as(?bool, null), click_direction(true, .other, 1, 1));
    try testing.expectEqual(@as(?bool, null), click_direction(true, .left, 2, 1));
    try testing.expectEqual(@as(?bool, null), click_direction(true, .right, 2, 1));
    // The output shows tags 1 and 2: the click does the action of the
    // configuration, for example it shows only tag 1.
    try testing.expectEqual(@as(?bool, null), click_direction(true, .left, 1, 3));
    try testing.expectEqual(@as(?bool, null), click_direction(false, .left, 1, 1));
}
