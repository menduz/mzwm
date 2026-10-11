//! The list of the key bindings that `kwm bindings` writes, without Wayland
//! objects. The overlay (overlay.zig) runs `kwm bindings` in a pseudo
//! terminal. `zig build test` runs the tests below.
//!
//! Each entry has the chord ("Super+Shift+Return") and the description of
//! the binding. A binding without a description gets a text from its action.
//! The entries are in the lexicographic order of the chord, without case.
//!
//! The list fills columns from top to bottom, as `ls`. In each column, the
//! chords align on the left, and the descriptions align after the widest
//! chord. The chords have the escape sequence `chord_style`: bold, palette
//! color 4. The overlay sets color 4 to the accent color of the theme.


const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;

pub const Entry = struct {
    chord: []const u8,
    description: []const u8,
};

/// Bold text in palette color 4 (blue).
pub const chord_style = "\x1b[1;34m";
pub const reset_style = "\x1b[0m";
/// Do not wrap a long line at the right edge. The terminal cuts it.
pub const no_wrap = "\x1b[?7l";

/// The spaces between the chord and the description.
pub const chord_gap = 2;
/// The spaces between two columns.
pub const column_gap = 4;

/// The modifiers in the order of the chord text, with their names.
const modifier_names = [_]struct { []const u8, []const u8 }{
    .{ "mod4", "Super" },
    .{ "ctrl", "Ctrl" },
    .{ "mod1", "Alt" },
    .{ "shift", "Shift" },
    .{ "mod3", "Mod3" },
    .{ "mod5", "Mod5" },
};


/// The chord text of a binding: the modifiers in a fixed order, then the
/// keysym with an upper case first letter. Each part has "+" between.
/// `modifiers` is a struct with a bool field for each modifier.
pub fn chord(gpa: mem.Allocator, modifiers: anytype, keysym: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);

    inline for (modifier_names) |pair| {
        if (@hasField(@TypeOf(modifiers), pair[0]) and @field(modifiers, pair[0])) {
            try text.appendSlice(gpa, pair[1]);
            try text.append(gpa, '+');
        }
    }
    const start = text.items.len;
    try text.appendSlice(gpa, keysym);
    if (text.items.len > start) text.items[start] = std.ascii.toUpper(text.items[start]);
    return text.toOwnedSlice(gpa);
}


/// A text for a binding without a description: the name of the action and
/// its values, for example "focus iter forward". For a command, the name of
/// the program.
pub fn describe(gpa: mem.Allocator, action: anytype) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try describe_into(gpa, &text, action);
    return text.toOwnedSlice(gpa);
}


fn describe_into(gpa: mem.Allocator, text: *std.ArrayList(u8), action: anytype) !void {
    const T = @TypeOf(action);
    switch (@typeInfo(T)) {
        .@"union" => switch (action) {
            inline else => |payload, tag| {
                const name = @tagName(tag);
                if (comptime mem.eql(u8, name, "spawn")) {
                    if (payload.argv.len > 0) try append_program(gpa, text, payload.argv[0]);
                } else if (comptime mem.eql(u8, name, "spawn_shell")) {
                    var words = mem.tokenizeAny(u8, payload.cmd, " \t\n");
                    if (words.next()) |word| try append_program(gpa, text, word);
                } else if (comptime mem.eql(u8, name, "group")) {
                    for (payload.actions, 0..) |nested, i| {
                        if (i > 0) try text.appendSlice(gpa, ", ");
                        try describe_into(gpa, text, nested);
                    }
                } else {
                    try append_name(gpa, text, name);
                    try append_values(gpa, text, payload);
                }
            },
        },
        else => {},
    }
}


/// The values of an action, after its name: the enum values, the numbers
/// and the text. A field with its default value does not show.
fn append_values(gpa: mem.Allocator, text: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            const field_value = @field(value, field.name);
            const default = field.defaultValue();
            if (default == null or !std.meta.eql(field_value, default.?)) {
                try append_values(gpa, text, field_value);
            }
        },
        .@"union" => switch (value) {
            // A field with a value gives only its value: `.tag = .{ .tag = 4 }`
            // gives "4". A field without a value gives its name.
            inline else => |payload, tag| if (@TypeOf(payload) == void) {
                try text.append(gpa, ' ');
                try append_name(gpa, text, @tagName(tag));
            } else {
                try append_values(gpa, text, payload);
            },
        },
        .@"enum" => {
            try text.append(gpa, ' ');
            try append_name(gpa, text, @tagName(value));
        },
        .int, .float => try text.print(gpa, " {d}", .{value}),
        .optional => if (value) |inner| try append_values(gpa, text, inner),
        .pointer => if (T == []const u8) {
            try text.append(gpa, ' ');
            try text.appendSlice(gpa, value);
        },
        else => {},
    }
}


fn append_name(gpa: mem.Allocator, text: *std.ArrayList(u8), name: []const u8) !void {
    for (name) |c| try text.append(gpa, if (c == '_') ' ' else c);
}


fn append_program(gpa: mem.Allocator, text: *std.ArrayList(u8), path: []const u8) !void {
    const base = path[if (mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
    try text.appendSlice(gpa, "run ");
    try text.appendSlice(gpa, base);
}


/// The sorted entries of the key bindings in `mode`. A binding without a
/// mode is in `default_mode`. Two bindings with the same chord give one
/// entry: the first binding. Free the result with `free`.
///
/// `keys` is the list `bindings.key` of the configuration. The event of a
/// binding is `.repeat` with an action, or `.click` with a `pressed` and a
/// `released` action.
pub fn collect(gpa: mem.Allocator, keys: anytype, mode: []const u8, default_mode: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer free(gpa, entries.items);
    defer entries.deinit(gpa);

    for (keys) |key| {
        if (!mem.eql(u8, key.mode orelse default_mode, mode)) continue;

        const chord_text = try chord(gpa, key.modifiers, key.keysym);
        errdefer gpa.free(chord_text);
        const seen = for (entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.chord, chord_text)) break true;
        } else false;
        if (seen) {
            gpa.free(chord_text);
            continue;
        }

        const description = if (key.description) |text|
            try gpa.dupe(u8, text)
        else switch (key.event) {
            .repeat => |action| try describe(gpa, action),
            .click => |click| if (click.pressed orelse click.released) |action|
                try describe(gpa, action)
            else
                try gpa.dupe(u8, ""),
        };
        errdefer gpa.free(description);
        try entries.append(gpa, .{ .chord = chord_text, .description = description });
    }

    sort(entries.items);
    return entries.toOwnedSlice(gpa);
}


pub fn free(gpa: mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| {
        gpa.free(entry.chord);
        gpa.free(entry.description);
    }
    gpa.free(entries);
}


fn less_than(_: void, a: Entry, b: Entry) bool {
    return std.ascii.lessThanIgnoreCase(a.chord, b.chord);
}


/// Sort the entries by the chord, without case. Entries with the same chord
/// keep their order.
pub fn sort(entries: []Entry) void {
    mem.sort(Entry, entries, {}, less_than);
}


/// The width of a text in cells. Each code point is one cell.
pub fn width(text: []const u8) usize {
    return unicode.utf8CountCodepoints(text) catch text.len;
}


pub const Column = struct {
    chord_width: usize,
    description_width: usize,
};

pub const Layout = struct {
    rows: usize,
    columns: []Column,

    pub fn deinit(self: *Layout, gpa: mem.Allocator) void {
        gpa.free(self.columns);
    }

    /// The cells of all columns and of the gaps between them.
    pub fn total_width(self: *const Layout) usize {
        var sum: usize = 0;
        for (self.columns, 0..) |column, i| {
            if (i > 0) sum += column_gap;
            sum += column.chord_width + chord_gap + column.description_width;
        }
        return sum;
    }
};


fn columns_for(gpa: mem.Allocator, entries: []const Entry, rows: usize) ![]Column {
    const count = (entries.len + rows - 1) / rows;
    const columns = try gpa.alloc(Column, count);
    for (columns, 0..) |*column, c| {
        column.* = .{ .chord_width = 0, .description_width = 0 };
        const end = @min(entries.len, (c + 1) * rows);
        for (entries[c * rows .. end]) |entry| {
            column.chord_width = @max(column.chord_width, width(entry.chord));
            column.description_width = @max(column.description_width, width(entry.description));
        }
    }
    return columns;
}


/// The layout with the fewest rows that fits in `cols` cells. With
/// `max_rows` more than 0, the layout has not more rows. When the columns
/// for `max_rows` do not fit, the descriptions get less cells, and the
/// writer cuts them.
pub fn layout(gpa: mem.Allocator, entries: []const Entry, cols: usize, max_rows: usize) !Layout {
    if (entries.len == 0) return .{ .rows = 0, .columns = try gpa.alloc(Column, 0) };

    const limit = if (max_rows == 0) entries.len else @min(max_rows, entries.len);
    var rows: usize = 1;
    while (rows <= limit) : (rows += 1) {
        var result: Layout = .{ .rows = rows, .columns = try columns_for(gpa, entries, rows) };
        if (result.total_width() <= cols) return result;
        result.deinit(gpa);
    }

    // No layout fits. Use all rows, and share the cells that the chords and
    // the gaps do not use between the descriptions. A short description
    // takes only its cells, and the other descriptions get the rest.
    const result: Layout = .{ .rows = limit, .columns = try columns_for(gpa, entries, limit) };
    var fixed: usize = 0;
    for (result.columns, 0..) |column, i| {
        if (i > 0) fixed += column_gap;
        fixed += column.chord_width + chord_gap;
    }
    var free_cells = if (cols > fixed) cols - fixed else 0;

    const order = try gpa.alloc(usize, result.columns.len);
    defer gpa.free(order);
    for (order, 0..) |*index, i| index.* = i;
    mem.sort(usize, order, result.columns, struct {
        fn less(columns: []Column, a: usize, b: usize) bool {
            return columns[a].description_width < columns[b].description_width;
        }
    }.less);
    for (order, 0..) |index, i| {
        const column = &result.columns[index];
        const share = free_cells / (order.len - i);
        column.description_width = @min(column.description_width, share);
        free_cells -= column.description_width;
    }
    return result;
}


/// Write the entries in the layout for a terminal of `cols` cells and
/// `max_rows` rows (0: no limit). No line ends with "\n" after the last
/// row, so a terminal with exactly that many rows does not scroll. With
/// `styled` false, the text has no escape sequences, for a pipe.
pub fn write(gpa: mem.Allocator, w: *std.Io.Writer, entries: []const Entry, cols: usize, max_rows: usize, styled: bool) !void {
    var result = try layout(gpa, entries, cols, max_rows);
    defer result.deinit(gpa);

    if (styled) try w.writeAll(no_wrap);
    for (0..result.rows) |row| {
        if (row > 0) try w.writeAll(if (styled) "\r\n" else "\n");
        for (result.columns, 0..) |column, c| {
            const index = c * result.rows + row;
            if (index >= entries.len) break;
            const entry = entries[index];
            if (c > 0) try w.splatByteAll(' ', column_gap);
            if (styled) try w.writeAll(chord_style);
            try w.writeAll(entry.chord);
            if (styled) try w.writeAll(reset_style);

            // The last column needs no spaces after its description.
            const last = c + 1 == result.columns.len or index + result.rows >= entries.len;
            const description = cut(entry.description, column.description_width);
            if (description.len == 0 and last) continue;
            try w.splatByteAll(' ', column.chord_width - width(entry.chord) + chord_gap);
            try w.writeAll(description);
            if (!last) try w.splatByteAll(' ', column.description_width - width(description));
        }
    }
}


/// The start of `text` with not more than `cells` code points.
fn cut(text: []const u8, cells: usize) []const u8 {
    var it = unicode.Utf8View.initUnchecked(text).iterator();
    var count: usize = 0;
    while (count < cells) : (count += 1) {
        _ = it.nextCodepointSlice() orelse return text;
    }
    return text[0..it.i];
}


// The tests use their own types, as the configuration of kwm has them.

const TestModifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    mod1: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
};

const TestDirection = enum { forward, reverse };

const TestAction = union(enum) {
    close,
    spawn: struct { argv: []const []const u8 },
    spawn_shell: struct { cmd: []const u8 },
    focus_iter: struct { direction: TestDirection, skip: enum { none, floating } = .none },
    modify_mfact: struct { change: union(enum) { set: f32, step: f32 } },
    set_output_tag: struct { tag: union(enum) { tag: u32, direction: TestDirection } },
    switch_mode: struct { mode: []const u8 },
    group: struct { actions: []const TestAction },
};


test "chord: the modifiers in a fixed order, then the keysym" {
    const gpa = testing.allocator;
    const text = try chord(gpa, TestModifiers{ .shift = true, .mod4 = true, .ctrl = true }, "return");
    defer gpa.free(text);
    try testing.expectEqualStrings("Super+Ctrl+Shift+Return", text);
}

test "chord: no modifier" {
    const gpa = testing.allocator;
    const text = try chord(gpa, TestModifiers{}, "XF86AudioMute");
    defer gpa.free(text);
    try testing.expectEqualStrings("XF86AudioMute", text);
}

test "chord: alt" {
    const gpa = testing.allocator;
    const text = try chord(gpa, TestModifiers{ .mod1 = true }, "Period");
    defer gpa.free(text);
    try testing.expectEqualStrings("Alt+Period", text);
}

test "describe: the name and the values of the action" {
    const gpa = testing.allocator;
    const cases = [_]struct { TestAction, []const u8 }{
        .{ .close, "close" },
        .{ .{ .focus_iter = .{ .direction = .reverse } }, "focus iter reverse" },
        .{ .{ .focus_iter = .{ .direction = .reverse, .skip = .floating } }, "focus iter reverse floating" },
        .{ .{ .modify_mfact = .{ .change = .{ .step = -0.05 } } }, "modify mfact -0.05" },
        .{ .{ .set_output_tag = .{ .tag = .{ .tag = 4 } } }, "set output tag 4" },
        .{ .{ .set_output_tag = .{ .tag = .{ .direction = .forward } } }, "set output tag forward" },
        .{ .{ .switch_mode = .{ .mode = "passthrough" } }, "switch mode passthrough" },
    };
    for (cases) |case| {
        const text = try describe(gpa, case[0]);
        defer gpa.free(text);
        try testing.expectEqualStrings(case[1], text);
    }
}

test "describe: a command gives the name of its program" {
    const gpa = testing.allocator;
    const shell = try describe(gpa, TestAction{ .spawn_shell = .{ .cmd = "/nix/store/abc-scrn/bin/scrn --area" } });
    defer gpa.free(shell);
    try testing.expectEqualStrings("run scrn", shell);

    const argv = try describe(gpa, TestAction{ .spawn = .{ .argv = &.{ "rofi", "-show", "drun" } } });
    defer gpa.free(argv);
    try testing.expectEqualStrings("run rofi", argv);
}

test "describe: a group gives each action" {
    const gpa = testing.allocator;
    const text = try describe(gpa, TestAction{ .group = .{ .actions = &.{ .close, .{ .spawn = .{ .argv = &.{"ghostty"} } } } } });
    defer gpa.free(text);
    try testing.expectEqualStrings("close, run ghostty", text);
}

const TestKey = struct {
    mode: ?[]const u8 = null,
    keysym: []const u8,
    modifiers: TestModifiers,
    description: ?[]const u8 = null,
    event: union(enum) {
        repeat: TestAction,
        click: struct { pressed: ?TestAction = null, released: ?TestAction = null },
    },
};

test "collect: the bindings of the mode, sorted, with a text for each" {
    const gpa = testing.allocator;
    const keys = [_]TestKey{
        .{ .keysym = "q", .modifiers = .{ .mod4 = true }, .event = .{ .click = .{ .pressed = .close } } },
        .{ .keysym = "f", .modifiers = .{ .mod4 = true }, .description = "open brave browser", .event = .{ .click = .{ .pressed = .close } } },
        // Not in the default mode.
        .{ .mode = "lock", .keysym = "a", .modifiers = .{ .mod4 = true }, .event = .{ .click = .{ .pressed = .close } } },
        // The same chord again: the first binding stays.
        .{ .keysym = "F", .modifiers = .{ .mod4 = true }, .description = "other", .event = .{ .click = .{ .pressed = .close } } },
        .{ .mode = "default", .keysym = "j", .modifiers = .{ .mod4 = true }, .event = .{ .repeat = .{ .focus_iter = .{ .direction = .forward } } } },
        .{ .keysym = "x", .modifiers = .{ .mod4 = true }, .event = .{ .click = .{} } },
    };
    const entries = try collect(gpa, &keys, "default", "default");
    defer free(gpa, entries);

    const expected = [_]Entry{
        .{ .chord = "Super+F", .description = "open brave browser" },
        .{ .chord = "Super+J", .description = "focus iter forward" },
        .{ .chord = "Super+Q", .description = "close" },
        .{ .chord = "Super+X", .description = "" },
    };
    try testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |e, a| {
        try testing.expectEqualStrings(e.chord, a.chord);
        try testing.expectEqualStrings(e.description, a.description);
    }
}

test "sort: lexicographic order of the chord, without case" {
    var entries = [_]Entry{
        .{ .chord = "Super+f", .description = "1" },
        .{ .chord = "Alt+Return", .description = "2" },
        .{ .chord = "Super+E", .description = "3" },
        .{ .chord = "Super+1", .description = "4" },
        .{ .chord = "Super+Shift+E", .description = "5" },
    };
    sort(&entries);
    const expected = [_][]const u8{ "Alt+Return", "Super+1", "Super+E", "Super+f", "Super+Shift+E" };
    for (expected, entries) |chord_text, entry| try testing.expectEqualStrings(chord_text, entry.chord);
}

test "layout: the fewest rows that fit" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "A", .description = "aaaa" },
        .{ .chord = "BB", .description = "b" },
        .{ .chord = "C", .description = "c" },
        .{ .chord = "D", .description = "d" },
    };
    // One column: 2 + 2 + 4 = 8 cells. Two columns of two rows:
    // (2 + 2 + 4) + 4 + (1 + 2 + 1) = 16 cells.
    var one = try layout(gpa, &entries, 15, 0);
    defer one.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), one.rows);
    try testing.expectEqual(@as(usize, 1), one.columns.len);

    var two = try layout(gpa, &entries, 16, 0);
    defer two.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), two.rows);
    try testing.expectEqual(@as(usize, 16), two.total_width());

    // All in one row: 8 + 4 + 4 + 4 + 4 + 4 + 4 = 32 cells.
    var flat = try layout(gpa, &entries, 100, 0);
    defer flat.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), flat.rows);
}

test "layout: not more rows than max_rows; the descriptions get less cells" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "A", .description = "a long description" },
        .{ .chord = "B", .description = "b" },
        .{ .chord = "C", .description = "c long" },
    };
    var result = try layout(gpa, &entries, 12, 2);
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), result.rows);
    try testing.expectEqual(@as(usize, 2), result.columns.len);
    // Chords and gaps: (1 + 2) + 4 + (1 + 2) = 10 cells. 2 cells are free,
    // 1 for each description.
    try testing.expectEqual(@as(usize, 1), result.columns[0].description_width);
    try testing.expectEqual(@as(usize, 1), result.columns[1].description_width);
}

test "layout: a short description gives its free cells to the others" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "A", .description = "a long description" },
        .{ .chord = "B", .description = "b" },
    };
    // Chords and gaps: (1 + 2) + 4 + (1 + 2) = 10 cells. 10 cells are free:
    // "b" takes 1, "a long description" gets 9.
    var result = try layout(gpa, &entries, 20, 1);
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 9), result.columns[0].description_width);
    try testing.expectEqual(@as(usize, 1), result.columns[1].description_width);
    try testing.expectEqual(@as(usize, 20), result.total_width());
}

test "write: aligned chords and descriptions in columns" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "Super+E", .description = "files" },
        .{ .chord = "Super+Return", .description = "terminal" },
        .{ .chord = "Super+Q", .description = "close" },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // One column: 12 + 2 + 8 = 22 cells. Two columns:
    // (12 + 2 + 8) + 4 + (7 + 2 + 5) = 40 cells.
    try write(gpa, &out.writer, &entries, 40, 0, true);

    const b = chord_style;
    const r = reset_style;
    const expected = no_wrap ++
        b ++ "Super+E" ++ r ++ "       files   " ++ "    " ++ b ++ "Super+Q" ++ r ++ "  close" ++ "\r\n" ++
        b ++ "Super+Return" ++ r ++ "  terminal";
    try testing.expectEqualStrings(expected, out.written());
}

test "write: no escape sequences for a pipe" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "Super+E", .description = "files" },
        .{ .chord = "Super+Return", .description = "terminal" },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &entries, 22, 0, false);
    try testing.expectEqualStrings("Super+E       files\nSuper+Return  terminal", out.written());
}

test "write: a cut description" {
    const gpa = testing.allocator;
    const entries = [_]Entry{
        .{ .chord = "A", .description = "abcdef" },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &entries, 6, 1, true);
    try testing.expectEqualStrings(no_wrap ++ chord_style ++ "A" ++ reset_style ++ "  abc", out.written());
}

test "write: no entries, no rows" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, &.{}, 80, 10, true);
    try testing.expectEqualStrings(no_wrap, out.written());
}

test "cut: code points, not bytes" {
    try testing.expectEqualStrings("é→", cut("é→x", 2));
    try testing.expectEqualStrings("ab", cut("ab", 5));
}
