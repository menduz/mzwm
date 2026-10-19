//! The color of a tooltip line, without Wayland objects. tooltip.zig draws
//! the lines. `zig build test` runs the tests below.
//!
//! A line that starts with `^#RRGGBBAA` has that color, as the text of the
//! bar. A `^#!` at the end of the line is not shown. Other color codes are
//! text.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;


pub const Line = struct {
    /// null: the text color of the tooltip.
    color: ?u32,
    text: []const u8,
};


pub fn parse(line: []const u8) Line {
    const code_len = "^#RRGGBBAA".len;
    if (line.len < code_len or !mem.startsWith(u8, line, "^#")) return .{ .color = null, .text = line };
    const color = fmt.parseInt(u32, line[2..code_len], 16) catch return .{ .color = null, .text = line };
    var text = line[code_len..];
    if (mem.endsWith(u8, text, "^#!")) text = text[0 .. text.len - 3];
    return .{ .color = color, .text = text };
}


test "a line without a color code has the text color" {
    const line = parse("nvme Composite: 39°C");
    try testing.expectEqual(null, line.color);
    try testing.expectEqualStrings("nvme Composite: 39°C", line.text);
}

test "a color code at the start gives the color of the line" {
    const line = parse("^#ff3333ffk10temp Tctl: 81°C");
    try testing.expectEqual(0xff3333ff, line.color);
    try testing.expectEqualStrings("k10temp Tctl: 81°C", line.text);
}

test "the reset code at the end is not shown" {
    const line = parse("^#ffb354ffk10temp Tctl: 70°C^#!");
    try testing.expectEqual(0xffb354ff, line.color);
    try testing.expectEqualStrings("k10temp Tctl: 70°C", line.text);
}

test "a code that is not a color is text" {
    try testing.expectEqualStrings("^#xyz12345 text", parse("^#xyz12345 text").text);
    try testing.expectEqualStrings("^#ff33", parse("^#ff33").text);
    try testing.expectEqual(null, parse("^#ff33").color);
    try testing.expectEqualStrings("a ^#ff3333ff b", parse("a ^#ff3333ff b").text);
}
