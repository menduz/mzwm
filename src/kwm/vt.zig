//! A terminal without a renderer: libghostty-vt reads the output of a
//! program (text and escape sequences), and keeps the grid of cells. kwm
//! draws the cells itself (overlay.zig). This file has no Wayland objects.
//! `zig build test` runs the tests below, with libghostty-vt.
//!
//! The declarations below are those of <ghostty/vt.h> that kwm uses. A C
//! enum of libghostty-vt has the size of an int.


const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,

    /// From 0xRRGGBBAA, as the configuration of kwm has the colors.
    pub fn from_rgba(rgba: u32) Rgb {
        return .{
            .r = @truncate(rgba >> 24),
            .g = @truncate(rgba >> 16),
            .b = @truncate(rgba >> 8),
        };
    }

    pub fn to_rgba(self: Rgb) u32 {
        return @as(u32, self.r) << 24 | @as(u32, self.g) << 16 | @as(u32, self.b) << 8 | 0xff;
    }
};

const TerminalImpl = opaque {};
const RenderStateImpl = opaque {};
const RowIteratorImpl = opaque {};
const RowCellsImpl = opaque {};

const success: c_int = 0;

const TerminalOptions = extern struct {
    cols: u16,
    rows: u16,
    max_scrollback: usize,
};

const StyleColor = extern struct {
    tag: c_int,
    value: u64,
};

const Style = extern struct {
    size: usize = @sizeOf(Style),
    fg_color: StyleColor = undefined,
    bg_color: StyleColor = undefined,
    underline_color: StyleColor = undefined,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: c_int = 0,
};

// GhosttyTerminalOption
const opt_color_foreground: c_int = 11;
const opt_color_background: c_int = 12;
const opt_color_palette: c_int = 14;
// GhosttyTerminalData
const data_color_palette_default: c_int = 25;
// GhosttyRenderStateData
const state_row_iterator: c_int = 4;
// GhosttyRenderStateRowData
const row_data_cells: c_int = 3;
// GhosttyRenderStateRowCellsData
const cell_raw: c_int = 1;
const cell_style: c_int = 2;
const cell_graphemes_len: c_int = 3;
const cell_graphemes_buf: c_int = 4;
const cell_bg_color: c_int = 5;
const cell_fg_color: c_int = 6;
// GhosttyCellData
const cell_data_wide: c_int = 3;
// GhosttyCellWide
const wide_wide: c_int = 1;
const wide_spacer_tail: c_int = 2;
const wide_spacer_head: c_int = 3;

extern fn ghostty_terminal_new(allocator: ?*const anyopaque, terminal: *?*TerminalImpl, options: TerminalOptions) c_int;
extern fn ghostty_terminal_free(terminal: ?*TerminalImpl) void;
extern fn ghostty_terminal_resize(terminal: *TerminalImpl, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) c_int;
extern fn ghostty_terminal_set(terminal: *TerminalImpl, option: c_int, value: ?*const anyopaque) c_int;
extern fn ghostty_terminal_get(terminal: *TerminalImpl, data: c_int, out: *anyopaque) c_int;
extern fn ghostty_terminal_vt_write(terminal: *TerminalImpl, data: [*]const u8, len: usize) void;
extern fn ghostty_render_state_new(allocator: ?*const anyopaque, state: *?*RenderStateImpl) c_int;
extern fn ghostty_render_state_free(state: ?*RenderStateImpl) void;
extern fn ghostty_render_state_update(state: *RenderStateImpl, terminal: *TerminalImpl) c_int;
extern fn ghostty_render_state_get(state: *RenderStateImpl, data: c_int, out: *anyopaque) c_int;
extern fn ghostty_render_state_row_iterator_new(allocator: ?*const anyopaque, iterator: *?*RowIteratorImpl) c_int;
extern fn ghostty_render_state_row_iterator_free(iterator: ?*RowIteratorImpl) void;
extern fn ghostty_render_state_row_iterator_next(iterator: *RowIteratorImpl) bool;
extern fn ghostty_render_state_row_get(iterator: *RowIteratorImpl, data: c_int, out: *anyopaque) c_int;
extern fn ghostty_render_state_row_cells_new(allocator: ?*const anyopaque, cells: *?*RowCellsImpl) c_int;
extern fn ghostty_render_state_row_cells_free(cells: ?*RowCellsImpl) void;
extern fn ghostty_render_state_row_cells_next(cells: *RowCellsImpl) bool;
extern fn ghostty_render_state_row_cells_get(cells: *RowCellsImpl, data: c_int, out: *anyopaque) c_int;
extern fn ghostty_cell_get(cell: u64, data: c_int, out: *anyopaque) c_int;


/// A cell with text or with a background color.
pub const Cell = struct {
    row: u16,
    col: u16,
    /// The code points of the grapheme. A longer grapheme keeps only the
    /// first code points.
    text: [4]u32 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    /// Two columns wide.
    wide: bool = false,
    /// null: the default color of the terminal.
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    bold: bool = false,
    faint: bool = false,
    inverse: bool = false,

    pub fn codepoints(self: *const Cell) []const u32 {
        return self.text[0..self.len];
    }
};

pub const Snapshot = struct {
    cells: []Cell,
    /// The rows down to the last row with a cell.
    used_rows: u16,

    pub fn deinit(self: *Snapshot, gpa: mem.Allocator) void {
        gpa.free(self.cells);
    }
};

pub const Error = error{ OutOfMemory, Terminal };

pub const Terminal = struct {
    handle: *TerminalImpl,
    state: *RenderStateImpl,
    rows: *RowIteratorImpl,
    row_cells: *RowCellsImpl,

    pub fn init(cols: u16, rows: u16) Error!Terminal {
        var handle: ?*TerminalImpl = null;
        if (ghostty_terminal_new(null, &handle, .{ .cols = cols, .rows = rows, .max_scrollback = 0 }) != success) return error.Terminal;
        errdefer ghostty_terminal_free(handle);

        var state: ?*RenderStateImpl = null;
        if (ghostty_render_state_new(null, &state) != success) return error.Terminal;
        errdefer ghostty_render_state_free(state);

        var iterator: ?*RowIteratorImpl = null;
        if (ghostty_render_state_row_iterator_new(null, &iterator) != success) return error.Terminal;
        errdefer ghostty_render_state_row_iterator_free(iterator);

        var row_cells: ?*RowCellsImpl = null;
        if (ghostty_render_state_row_cells_new(null, &row_cells) != success) return error.Terminal;

        return .{
            .handle = handle orelse return error.Terminal,
            .state = state orelse return error.Terminal,
            .rows = iterator orelse return error.Terminal,
            .row_cells = row_cells orelse return error.Terminal,
        };
    }

    pub fn deinit(self: *Terminal) void {
        ghostty_render_state_row_cells_free(self.row_cells);
        ghostty_render_state_row_iterator_free(self.rows);
        ghostty_render_state_free(self.state);
        ghostty_terminal_free(self.handle);
    }

    /// The pixel size of a cell answers the size reports of a program.
    pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        _ = ghostty_terminal_resize(self.handle, cols, rows, cell_width, cell_height);
    }

    /// The default colors, and other colors in place of palette entries.
    pub fn set_colors(self: *Terminal, fg: Rgb, bg: Rgb, palette: []const struct { u8, Rgb }) void {
        _ = ghostty_terminal_set(self.handle, opt_color_foreground, &fg);
        _ = ghostty_terminal_set(self.handle, opt_color_background, &bg);
        if (palette.len == 0) return;
        var colors: [256]Rgb = undefined;
        if (ghostty_terminal_get(self.handle, data_color_palette_default, &colors) != success) return;
        for (palette) |entry| colors[entry[0]] = entry[1];
        _ = ghostty_terminal_set(self.handle, opt_color_palette, &colors);
    }

    /// The output of the program.
    pub fn write(self: *Terminal, bytes: []const u8) void {
        ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// The cells with text or with a background color, row by row.
    pub fn snapshot(self: *Terminal, gpa: mem.Allocator) Error!Snapshot {
        if (ghostty_render_state_update(self.state, self.handle) != success) return error.Terminal;

        var rows = self.rows;
        if (ghostty_render_state_get(self.state, state_row_iterator, @ptrCast(&rows)) != success) return error.Terminal;

        var cells: std.ArrayList(Cell) = .empty;
        errdefer cells.deinit(gpa);
        var used_rows: u16 = 0;

        var row: u16 = 0;
        while (ghostty_render_state_row_iterator_next(self.rows)) : (row += 1) {
            var row_cells = self.row_cells;
            if (ghostty_render_state_row_get(self.rows, row_data_cells, @ptrCast(&row_cells)) != success) continue;

            var col: u16 = 0;
            while (ghostty_render_state_row_cells_next(self.row_cells)) : (col += 1) {
                var cell: Cell = .{ .row = row, .col = col };

                var raw: u64 = 0;
                if (ghostty_render_state_row_cells_get(self.row_cells, cell_raw, &raw) == success) {
                    var wide: c_int = 0;
                    if (ghostty_cell_get(raw, cell_data_wide, &wide) == success) {
                        if (wide == wide_spacer_tail or wide == wide_spacer_head) continue;
                        cell.wide = wide == wide_wide;
                    }
                }

                var len: u32 = 0;
                _ = ghostty_render_state_row_cells_get(self.row_cells, cell_graphemes_len, &len);
                if (len > 0) {
                    var buffer: [16]u32 = undefined;
                    if (len <= buffer.len and
                        ghostty_render_state_row_cells_get(self.row_cells, cell_graphemes_buf, &buffer) == success)
                    {
                        cell.len = @intCast(@min(len, cell.text.len));
                        @memcpy(cell.text[0..cell.len], buffer[0..cell.len]);
                    }
                }

                var color: Rgb = undefined;
                if (ghostty_render_state_row_cells_get(self.row_cells, cell_fg_color, &color) == success) cell.fg = color;
                if (ghostty_render_state_row_cells_get(self.row_cells, cell_bg_color, &color) == success) cell.bg = color;

                var style: Style = .{};
                if (ghostty_render_state_row_cells_get(self.row_cells, cell_style, &style) == success) {
                    cell.bold = style.bold;
                    cell.faint = style.faint;
                    cell.inverse = style.inverse;
                    if (style.invisible) cell.len = 0;
                }

                // A space without a background color draws nothing.
                const blank = cell.len == 0 or (cell.len == 1 and cell.text[0] == ' ');
                if (blank and cell.bg == null and !cell.inverse) continue;

                try cells.append(gpa, cell);
                used_rows = row + 1;
            }
        }

        return .{ .cells = try cells.toOwnedSlice(gpa), .used_rows = used_rows };
    }
};


fn find(snapshot: *const Snapshot, row: u16, col: u16) ?*const Cell {
    for (snapshot.cells) |*cell| {
        if (cell.row == row and cell.col == col) return cell;
    }
    return null;
}

test "Terminal: text, bold, palette color and the used rows" {
    var terminal = try Terminal.init(20, 5);
    defer terminal.deinit();
    const accent: Rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    terminal.set_colors(.{ .r = 0, .g = 0, .b = 0 }, .{ .r = 255, .g = 255, .b = 225 }, &.{.{ 4, accent }});
    terminal.write("\x1b[1;34mSuper+F\x1b[0m  brave\r\nx");

    var snapshot = try terminal.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), snapshot.used_rows);

    const s = find(&snapshot, 0, 0) orelse return error.NoCell;
    try testing.expectEqualSlices(u32, &.{'S'}, s.codepoints());
    try testing.expect(s.bold);
    try testing.expectEqual(accent, s.fg.?);

    // The spaces between the chord and the description draw nothing.
    try testing.expect(find(&snapshot, 0, 7) == null);

    const b = find(&snapshot, 0, 9) orelse return error.NoCell;
    try testing.expectEqualSlices(u32, &.{'b'}, b.codepoints());
    try testing.expect(!b.bold);
    try testing.expect(b.fg == null);

    const x = find(&snapshot, 1, 0) orelse return error.NoCell;
    try testing.expectEqualSlices(u32, &.{'x'}, x.codepoints());
}

test "Terminal: a wide character takes two columns" {
    var terminal = try Terminal.init(10, 2);
    defer terminal.deinit();
    terminal.write("\u{65e5}a");

    var snapshot = try terminal.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    const wide = find(&snapshot, 0, 0) orelse return error.NoCell;
    try testing.expect(wide.wide);
    try testing.expect(find(&snapshot, 0, 1) == null);
    const a = find(&snapshot, 0, 2) orelse return error.NoCell;
    try testing.expectEqualSlices(u32, &.{'a'}, a.codepoints());
}

test "Terminal: no wrap at the right edge with DECAWM off" {
    var terminal = try Terminal.init(4, 3);
    defer terminal.deinit();
    terminal.write("\x1b[?7labcdefgh");

    var snapshot = try terminal.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), snapshot.used_rows);
}

test "Terminal: no text, no rows" {
    var terminal = try Terminal.init(4, 3);
    defer terminal.deinit();
    var snapshot = try terminal.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0), snapshot.used_rows);
}

test "Rgb: from and to 0xRRGGBBAA" {
    const color = Rgb.from_rgba(0x11223344);
    try testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, color);
    try testing.expectEqual(@as(u32, 0x112233ff), color.to_rgba());
}
