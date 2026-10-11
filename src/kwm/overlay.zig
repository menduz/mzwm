//! The overlay: a band at the bottom of the focused output, from the left
//! edge to the right edge, while the Super key stays down alone. Refer to
//! `overlay` in the configuration, and to super_hold.zig for the sequence.
//!
//! kwm runs `overlay.command` in a pseudo terminal. The terminal has the
//! width of the output and `max_height` of its height, in cells of the
//! font. libghostty-vt reads the output of the command (vt.zig), and kwm
//! draws the cells with fcft. There is no renderer of libghostty. The band
//! has the height of the rows with text.
//!
//! The command starts `super_hold.lead` milliseconds before the band shows,
//! so its text is ready. The terminal has the colors of the overlay: the
//! default text and background colors, and the accent color in palette
//! entries 4 and 12. When Super goes up, kwm stops the command and removes
//! the band.

const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const log = std.log.scoped(.overlay);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const pixman = @import("pixman");
const fcft = @import("fcft");

const posix = @import("posix");
const config = @import("config");

const utils = @import("utils.zig");
const render_ = @import("render.zig");
const theme = @import("theme.zig");
const vt = @import("vt.zig");
const super_hold = @import("super_hold.zig");
const Context = @import("context.zig");
const Output = @import("output.zig");
const ShellSurface = @import("shell_surface.zig");

const ctx = Context.get();

const fallback_font = "monospace:size=10";

const Surface = struct {
    wl_surface: *wl.Surface,
    shell_surface: ShellSurface,
    wp_viewport: *wp.Viewport,
    buffers: [2]render_.Buffer = .{ .{}, .{} },

    fn create() !*Surface {
        const self = try ctx.gpa.create(Surface);
        errdefer ctx.gpa.destroy(self);

        const wl_surface = try ctx.wl_compositor.createSurface();
        errdefer wl_surface.destroy();

        const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
        errdefer wp_viewport.destroy();

        self.* = .{
            .wl_surface = wl_surface,
            .shell_surface = undefined,
            .wp_viewport = wp_viewport,
        };
        try self.shell_surface.init(wl_surface, .overlay);
        return self;
    }

    fn destroy(self: *Surface) void {
        self.shell_surface.deinit();
        self.wp_viewport.destroy();
        self.wl_surface.destroy();
        self.buffers[0].deinit();
        self.buffers[1].deinit();
        ctx.gpa.destroy(self);
    }

    fn next_buffer(self: *Surface) ?*render_.Buffer {
        for (&self.buffers) |*buffer| {
            if (!buffer.busy) {
                buffer.occupy();
                return buffer;
            }
        }
        return null;
    }
};

/// The regular and the bold font for one scale, and the size of a cell in
/// buffer pixels.
const Fonts = struct {
    regular: *fcft.Font,
    bold: *fcft.Font,
    name: [:0]u8,
    scale: u32,
    cell_width: i32,
    cell_height: i32,

    fn load(name: []const u8, scale: u32) !Fonts {
        const name_z = try ctx.gpa.dupeZ(u8, name);
        errdefer ctx.gpa.free(name_z);
        var names = [_][*:0]const u8{ name_z.ptr, fallback_font };

        var buffer: [32]u8 = undefined;
        const dpi = @divFloor(scale * 96, 120);
        const regular_attrs = try std.fmt.bufPrintZ(&buffer, "dpi={}", .{dpi});
        const regular = try fcft.Font.fromName(&names, regular_attrs.ptr);
        errdefer regular.destroy();

        var bold_buffer: [32]u8 = undefined;
        const bold_attrs = try std.fmt.bufPrintZ(&bold_buffer, "dpi={}:weight=bold", .{dpi});
        const bold = fcft.Font.fromName(&names, bold_attrs.ptr) catch regular.clone() orelse return error.NoFont;

        // A monospace font: the advance of "M" is the width of each cell.
        const cell_width: i32 = if (regular.rasterizeCharUtf32('M', .default)) |glyph|
            glyph.advance.x
        else |_|
            regular.max_advance.x;

        return .{
            .regular = regular,
            .bold = bold,
            .name = name_z,
            .scale = scale,
            .cell_width = @max(cell_width, 1),
            .cell_height = @max(regular.height, 1),
        };
    }

    fn deinit(self: *Fonts) void {
        self.regular.destroy();
        self.bold.destroy();
        ctx.gpa.free(self.name);
    }
};

/// The command in its pseudo terminal.
const Session = struct {
    terminal: vt.Terminal,
    /// The output of the band.
    output: *Output,
    /// The process group of the command. 0: the command stopped.
    pid: posix.pid_t = 0,
    /// The controlling side of the pseudo terminal. null: the command closed
    /// it.
    fd: ?posix.fd_t = null,
};

var hold: super_hold.State = .{};
var session: ?Session = null;
var fonts: ?Fonts = null;
var surface: ?*Surface = null;
var visible = false;
var dirty = false;


fn now() i64 {
    return std.Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
}


/// The modifiers of a seat changed, from river (modifiers_update).
pub fn modifiers(old: u32, new: u32) void {
    const allowed = ctx.cfg.overlay.enabled and mem.eql(u8, ctx.mode, config.default_mode);
    switch (hold.modifiers(old, new, now(), allowed)) {
        .none => {},
        .arm => {
            const delay = ctx.cfg.overlay.delay;
            const prepare = if (delay > super_hold.lead) delay - super_hold.lead else 0;
            ctx.run_later(.fromMilliseconds(prepare), prepare_later);
            ctx.run_later(.fromMilliseconds(delay), show_later);
        },
        .stop => stop(),
    }
}


/// The user pressed a key binding or a pointer binding.
pub fn binding() void {
    if (hold.binding() == .stop) stop();
}


fn prepare_later(_: *Context) void {
    if (!hold.prepare_due(now(), ctx.cfg.overlay.delay)) return;
    start() catch |err| log.err("start the overlay command failed: {}", .{err});
}


fn show_later(_: *Context) void {
    if (!hold.show_due(now(), ctx.cfg.overlay.delay)) return;
    if (session == null) start() catch |err| {
        log.err("start the overlay command failed: {}", .{err});
        return;
    };
    visible = true;
    request_render();
}


fn request_render() void {
    dirty = true;
    ctx.manage_dirty(@src());
}


/// The colors of the overlay: those of the configuration, or of the theme.
fn colors() struct { fg: u32, bg: u32, accent: u32 } {
    const cfg = &ctx.cfg.overlay;
    var result: @TypeOf(colors()) = .{ .fg = cfg.fg, .bg = cfg.bg, .accent = cfg.accent };
    if (cfg.gtk_colors) |keys| {
        result.fg = theme.color(keys.fg) orelse result.fg;
        result.bg = theme.color(keys.bg) orelse result.bg;
        result.accent = theme.color(keys.accent) orelse result.accent;
    }
    return result;
}


fn load_fonts(scale: u32) !*Fonts {
    const name = ctx.cfg.overlay.font orelse ctx.cfg.bar.font;
    if (fonts) |*f| {
        if (f.scale == scale and mem.eql(u8, f.name, name)) return f;
        f.deinit();
        fonts = null;
    }
    fonts = try Fonts.load(name, scale);
    return &fonts.?;
}


/// The space around the cells, in buffer pixels.
fn padding(f: *const Fonts) struct { x: i32, y: i32 } {
    return .{ .x = f.cell_width, .y = @divFloor(f.cell_height, 2) };
}


/// Start the command in a new pseudo terminal, with the size of the band on
/// the focused output.
fn start() !void {
    stop_command();

    const output = ctx.current_output orelse return error.NoOutput;
    const scale = output.bar.scale;
    const f = try load_fonts(scale);
    const pad = padding(f);

    const width = utils.logical2physics(i32, output.width, scale);
    const height = utils.logical2physics(i32, output.height, scale);
    const max_height: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) * std.math.clamp(ctx.cfg.overlay.max_height, 0, 1));
    const cols: u16 = @intCast(std.math.clamp(@divFloor(width - 2 * pad.x, f.cell_width), 1, std.math.maxInt(u16)));
    const rows: u16 = @intCast(std.math.clamp(@divFloor(max_height - 2 * pad.y - 1, f.cell_height), 1, std.math.maxInt(u16)));

    var terminal = try vt.Terminal.init(cols, rows);
    errdefer terminal.deinit();
    terminal.resize(cols, rows, @intCast(f.cell_width), @intCast(f.cell_height));
    const c = colors();
    const accent = vt.Rgb.from_rgba(c.accent);
    terminal.set_colors(vt.Rgb.from_rgba(c.fg), vt.Rgb.from_rgba(c.bg), &.{ .{ 4, accent }, .{ 12, accent } });

    session = .{ .terminal = terminal, .output = output };
    const process = spawn(cols, rows, f) catch |err| {
        terminal.deinit();
        session = null;
        return err;
    };
    session.?.pid = process.pid;
    session.?.fd = process.fd;
    log.debug("command started: pid {}, {}x{} cells", .{ process.pid, cols, rows });
}


/// Open a pseudo terminal, and run the command with the other side as its
/// controlling terminal.
fn spawn(cols: u16, rows: u16, f: *const Fonts) !struct { pid: posix.pid_t, fd: posix.fd_t } {
    var arena_allocator: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const command = ctx.cfg.overlay.command;
    if (command.len == 0) return error.NoCommand;
    const argv = try arena.allocSentinel(?[*:0]const u8, command.len, null);
    for (command, 0..) |arg, i| {
        // "{config}" is the configuration file of this kwm.
        const value = try mem.replaceOwned(u8, arena, arg, "{config}", ctx.config_path);
        argv[i] = try arena.dupeZ(u8, value);
    }

    var env = try ctx.env.clone(arena);
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    const env_block = try env.createPosixBlock(arena, .{});

    const master = try posix.openZ("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    errdefer posix.close(master);

    var unlock: c_int = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyUnlock;
    var number: c_uint = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number))) != .SUCCESS) return error.PtyNumber;
    const size: std.posix.winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = @intCast(@as(i32, cols) * f.cell_width),
        .ypixel = @intCast(@as(i32, rows) * f.cell_height),
    };
    _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&size));
    const path = try std.fmt.allocPrintSentinel(arena, "/dev/pts/{}", .{number}, 0);

    const pid = try posix.fork();
    if (pid == 0) {
        _ = posix.setsid() catch {};
        _ = posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null);
        // The first terminal that a session leader opens is its controlling
        // terminal.
        const slave = posix.openZ(path, .{ .ACCMODE = .RDWR }, 0) catch posix.exit(127);
        _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
        for (0..3) |i| {
            if (linux.errno(linux.dup2(slave, @intCast(i))) != .SUCCESS) posix.exit(127);
        }
        if (slave > 2) posix.close(slave);
        if (ctx.env.get("HOME")) |home| posix.chdir(home) catch {};
        const err = posix.execve(argv[0].?, argv, env_block.slice.ptr);
        log.err("execve failed: {}", .{err});
        posix.exit(127);
    }

    return .{ .pid = pid, .fd = master };
}


/// The pseudo terminal of the command, for poll() in the main loop.
pub fn poll_fd() ?posix.pollfd {
    const s = session orelse return null;
    const fd = s.fd orelse return null;
    return .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
}


/// Read the output of the command into the terminal.
pub fn handle_fd() void {
    const s = if (session) |*s| s else return;
    const fd = s.fd orelse return;
    var buffer: [4096]u8 = undefined;
    var changed = false;
    while (true) {
        // After the command stops, Linux gives EIO for the pseudo terminal.
        const n = posix.read(fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => break,
            else => 0,
        };
        if (n == 0) {
            posix.close(fd);
            s.fd = null;
            s.pid = 0;
            break;
        }
        s.terminal.write(buffer[0..n]);
        changed = true;
    }
    if (changed and visible) request_render();
}


/// Stop the command. It is the leader of its process group (setsid), thus
/// the signal goes to the group.
fn stop_command() void {
    const s = if (session) |*s| s else return;
    if (s.pid > 0) {
        if (std.c.kill(-s.pid, .TERM) != 0) _ = std.c.kill(s.pid, .TERM);
    }
    if (s.fd) |fd| posix.close(fd);
    s.terminal.deinit();
    session = null;
}


/// Stop the command and remove the band.
fn stop() void {
    stop_command();
    if (visible) {
        visible = false;
        request_render();
    }
}


/// Call in each render sequence.
pub fn render() void {
    if (!dirty) return;
    dirty = false;

    const s = if (session) |*s| s else return hide();
    if (!visible or !output_exists(s.output)) return hide();

    var snapshot = s.terminal.snapshot(ctx.gpa) catch |err| {
        log.err("read the terminal failed: {}", .{err});
        return hide();
    };
    defer snapshot.deinit(ctx.gpa);
    // No text yet. The output of the command shows the band.
    if (snapshot.used_rows == 0) return hide();

    if (surface == null) {
        surface = Surface.create() catch |err| {
            log.err("create the overlay surface failed: {}", .{err});
            return;
        };
    }
    draw(surface.?, s.output, &snapshot) catch |err| {
        log.err("draw the overlay failed: {}", .{err});
        hide();
    };
}


fn output_exists(output: *Output) bool {
    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o == output) return true;
    }
    return false;
}


fn hide() void {
    if (surface) |s| {
        s.destroy();
        surface = null;
    }
}


pub fn deinit() void {
    stop_command();
    visible = false;
    hide();
    if (fonts) |*f| f.deinit();
    fonts = null;
}


fn draw(s: *Surface, output: *Output, snapshot: *const vt.Snapshot) !void {
    const scale = output.bar.scale;
    const f = try load_fonts(scale);
    const pad = padding(f);
    const c = colors();

    const w = utils.logical2physics(i32, output.width, scale);
    // A line of 1 pixel in the text color at the top, as the border of a
    // tooltip.
    const h = 1 + 2 * pad.y + @as(i32, snapshot.used_rows) * f.cell_height;

    const buffer = s.next_buffer() orelse return error.NoBuffer;
    try buffer.init(w, h);

    const fg = render_.utils.color(c.fg);
    const bg = render_.utils.color(c.bg);
    fill(buffer, &bg, 0, 0, w, h);
    fill(buffer, &fg, 0, 0, w, 1);

    var solid: ?struct { rgba: u32, image: *pixman.Image } = null;
    defer if (solid) |entry| {
        _ = entry.image.unref();
    };

    for (snapshot.cells) |*cell| {
        const x = pad.x + @as(i32, cell.col) * f.cell_width;
        const y = 1 + pad.y + @as(i32, cell.row) * f.cell_height;
        const cells: i32 = if (cell.wide) 2 else 1;

        var text_rgba = if (cell.fg) |rgb| rgb.to_rgba() else c.fg;
        var back_rgba: ?u32 = if (cell.bg) |rgb| rgb.to_rgba() else null;
        if (cell.inverse) {
            const old_text = text_rgba;
            text_rgba = back_rgba orelse c.bg;
            back_rgba = old_text;
        }
        if (cell.faint) text_rgba = blend(text_rgba, back_rgba orelse c.bg);

        if (back_rgba) |rgba| {
            fill(buffer, &render_.utils.color(rgba), x, y, cells * f.cell_width, f.cell_height);
        }
        if (cell.len == 0) continue;

        if (solid == null or solid.?.rgba != text_rgba) {
            if (solid) |entry| _ = entry.image.unref();
            solid = null;
            const image = pixman.Image.createSolidFill(&render_.utils.color(text_rgba)) orelse continue;
            solid = .{ .rgba = text_rgba, .image = image };
        }

        const font = if (cell.bold) f.bold else f.regular;
        const codepoints = cell.codepoints();
        if (codepoints.len == 1) {
            const glyph = font.rasterizeCharUtf32(codepoints[0], .default) catch continue;
            draw_glyph(buffer, font, glyph, solid.?.image, x, y);
        } else {
            const grapheme = font.rasterizeGraphemeUtf32(codepoints, .default) catch continue;
            var offset: i32 = 0;
            for (grapheme.glyphs[0..grapheme.count]) |glyph| {
                draw_glyph(buffer, font, glyph, solid.?.image, x + offset, y);
                offset += glyph.advance.x;
            }
        }
    }

    const logical_w = output.width;
    const logical_h = utils.physics2logical(i32, h, scale);

    s.shell_surface.sync_next_commit();
    s.shell_surface.place(.top);
    s.shell_surface.set_position(output.x, output.y + output.height - logical_h);

    s.wl_surface.attach(buffer.wl_buffer, 0, 0);
    s.wl_surface.damageBuffer(0, 0, w, h);
    s.wp_viewport.setDestination(logical_w, logical_h);
    s.wl_surface.commit();
}


fn fill(buffer: *render_.Buffer, color: *const pixman.Color, x: i32, y: i32, width: i32, height: i32) void {
    var rect = [_]pixman.Rectangle16{.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
    }};
    _ = pixman.Image.fillRectangles(.src, buffer.image, color, 1, &rect);
}


/// A color glyph (an emoji) has its own colors. Other glyphs are a mask for
/// the text color.
fn draw_glyph(buffer: *render_.Buffer, font: *const fcft.Font, glyph: *const fcft.Glyph, color: *pixman.Image, x: i32, y: i32) void {
    const color_glyph = glyph.pix.getFormat() == .a8r8g8b8;
    pixman.Image.composite32(
        .over,
        if (color_glyph) glyph.pix else color,
        if (color_glyph) null else glyph.pix,
        buffer.image,
        0,
        0,
        0,
        0,
        x + glyph.x,
        y + font.ascent - glyph.y,
        glyph.width,
        glyph.height,
    );
}


/// The middle of two 0xRRGGBBAA colors, for faint text.
fn blend(a: u32, b: u32) u32 {
    var result: u32 = 0xff;
    inline for (.{ 24, 16, 8 }) |shift| {
        const ca = (a >> shift) & 0xff;
        const cb = (b >> shift) & 0xff;
        result |= ((ca + cb) / 2) << shift;
    }
    return result;
}
