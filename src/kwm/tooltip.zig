//! The tooltip of the bar widgets, of the layout area and of the tray items.
//! There is one tooltip for all outputs.
//!
//! The tooltip of a selected tag and of the layout area is the menu of the
//! layouts of `cycle_layouts`: each line shows the mark of the layout and
//! its name. A click on a line selects the layout. Refer to tag_mark.zig.
//!
//! The pointer events of the bar select the target widget. After
//! `bar.tooltip_delay` milliseconds, the next render sequence makes a surface
//! below the widget. Shell surfaces change only in a manage or render
//! sequence, so `render` makes all changes.
//!
//! The surface is a layer surface on the overlay layer: river puts shell
//! surfaces below the top and overlay layers, and then the notifications
//! (dunst) and the menus (rofi) cover the tooltip. A new layer surface is
//! above the other layer surfaces, and each tooltip is a new surface. Without
//! wlr-layer-shell, the surface is a shell surface.
//!
//! A script widget can give a click command for each line of its tooltip.
//! Then the tooltip is below the pointer, and stays `leave_delay`
//! milliseconds after the pointer leaves the widget, so the pointer can go to
//! the tooltip. The line with a command under the pointer has the inverse
//! colors, and a left click runs the command.

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.tooltip);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const pixman = @import("pixman");
const fcft = @import("fcft");

const utils = @import("utils.zig");
const render_ = @import("render.zig");
const widgets = @import("widgets.zig");
const Context = @import("context.zig");
const ShellSurface = @import("shell_surface.zig");
const build_options = @import("build_options");
const Bar = @import("bar.zig");
const tray = @import("tray.zig");
const Output = @import("output.zig");
const Layout = @import("layout.zig");
const types = @import("types.zig");
const tooltip_place = @import("tooltip_place.zig");
const tooltip_line = @import("tooltip_line.zig");
const theme = @import("theme.zig");

const ctx = Context.get();

pub const Area = union(enum) {
    widget: struct {
        side: widgets.Side,
        index: usize,
    },
    /// The tooltip shows the menu of the layouts.
    layout,
    /// The tooltip of a tray item.
    tray: *tray.Item,
};

pub const Target = struct {
    bar: *Bar,
    area: Area,
    /// The left edge of the area, in logical coordinates of the output.
    x: i32,
    /// The pointer position, in logical coordinates of the output.
    pointer_x: i32,
    pointer_y: i32,
};

const Surface = struct {
    wl_surface: *wl.Surface,
    role: union(enum) {
        layer: struct {
            zwlr_layer_surface: *zwlr.LayerSurfaceV1,
            /// The surface got its first configure event. Before it, the
            /// surface has no buffer.
            configured: bool = false,
        },
        shell: ShellSurface,
    },
    /// The output of the layer surface.
    output: *Output,
    wp_viewport: *wp.Viewport,
    buffers: [2]render_.Buffer = .{ .{}, .{} },

    fn create(output: *Output) !*Surface {
        const self = try ctx.gpa.create(Surface);
        errdefer ctx.gpa.destroy(self);

        const wl_surface = try ctx.wl_compositor.createSurface();
        errdefer wl_surface.destroy();

        const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
        errdefer wp_viewport.destroy();

        self.* = .{
            .wl_surface = wl_surface,
            .role = undefined,
            .output = output,
            .wp_viewport = wp_viewport,
        };

        if (ctx.zwlr_layer_shell) |layer_shell| if (output.wl_output) |wl_output| {
            const layer_surface = try layer_shell.getLayerSurface(wl_surface, wl_output, .overlay, "kwm-tooltip");
            self.role = .{ .layer = .{ .zwlr_layer_surface = layer_surface } };
            layer_surface.setListener(*Surface, layer_surface_listener, self);
            // The margins from the top left corner of the output place the
            // tooltip. The exclusive zones of other surfaces do not move it.
            layer_surface.setAnchor(.{ .top = true, .left = true });
            layer_surface.setExclusiveZone(-1);
            layer_surface.setKeyboardInteractivity(.none);
            // A size for the first commit. draw gives the size of the text.
            layer_surface.setSize(1, 1);
            wl_surface.commit();
            return self;
        };

        self.role = .{ .shell = undefined };
        try self.role.shell.init(wl_surface, .tooltip);
        return self;
    }

    fn destroy(self: *Surface) void {
        switch (self.role) {
            .layer => |layer| layer.zwlr_layer_surface.destroy(),
            .shell => |*shell| shell.deinit(),
        }
        self.wp_viewport.destroy();
        self.wl_surface.destroy();
        self.buffers[0].deinit();
        self.buffers[1].deinit();
        ctx.gpa.destroy(self);
    }

    /// The surface can show a buffer.
    fn ready(self: *const Surface) bool {
        return switch (self.role) {
            .layer => |layer| layer.configured,
            .shell => true,
        };
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


fn layer_surface_listener(
    zwlr_layer_surface: *zwlr.LayerSurfaceV1,
    event: zwlr.LayerSurfaceV1.Event,
    s: *Surface,
) void {
    switch (event) {
        .configure => |data| {
            zwlr_layer_surface.ackConfigure(data.serial);
            const layer = &s.role.layer;
            if (!layer.configured) {
                layer.configured = true;
                // Now draw the tooltip.
                request_render();
            }
        },
        // The output went away.
        .closed => if (surface == s) hide(),
    }
}


var target: ?Target = null;
var visible = false;
var dirty = false;
var surface: ?*Surface = null;
/// Each new target increases the generation, so an old delay does nothing.
var generation: u64 = 0;
var shown_generation: u64 = 0;

/// Milliseconds that a tooltip with click commands stays after the pointer
/// leaves the widget.
const leave_delay = 300;
/// Awake-clock milliseconds when the tooltip goes away, after the pointer
/// left the widget. null: the pointer did not leave.
var leave_time: ?i64 = null;
/// The pointer is on the tooltip.
var pointer_on = false;
/// The line under the pointer, or null.
var hovered: ?usize = null;
/// The place of the lines of the tooltip that shows, in buffer pixels.
var line_box: struct {
    top: i32 = 0,
    height: i32 = 1,
    count: usize = 0,
    scale: u32 = 120,
} = .{};


fn same(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.bar == b.?.bar and std.meta.eql(a.?.area, b.?.area);
}


/// The pointer is on this widget now, or on no widget.
pub fn hover(new: ?Target) void {
    if (same(target, new)) {
        // Keep the newest pointer position until the tooltip shows. Then the
        // tooltip does not move.
        if (!visible) target = new;
        leave_time = null;
        return;
    }
    // The pointer left the widget. Keep a tooltip with click commands for
    // some time, so the pointer can go to it.
    if (new == null and visible and clickable()) {
        if (leave_time == null) {
            leave_time = now() + leave_delay;
            ctx.run_later(.fromMilliseconds(leave_delay), leave_later);
        }
        return;
    }
    set_target(new);
}


/// Remove the tooltip now.
pub fn close() void {
    set_target(null);
}


fn set_target(new: ?Target) void {
    log.debug("hover {?}", .{ if (new) |t| std.meta.activeTag(t.area) else null });

    target = new;
    generation += 1;
    leave_time = null;
    pointer_on = false;
    hovered = null;
    if (visible) {
        visible = false;
        request_render();
    }
    if (new != null) {
        if (ctx.cfg.bar.tooltip_delay == 0) {
            show_later(ctx);
        } else {
            ctx.run_later(.fromMilliseconds(ctx.cfg.bar.tooltip_delay), show_later);
        }
    }
}


fn now() i64 {
    return std.Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
}


fn leave_later(_: *Context) void {
    // The pointer came back, or it left again later.
    const time = leave_time orelse return;
    if (pointer_on or now() < time) return;
    set_target(null);
}


/// True when `wl_surface` is the surface of the tooltip.
pub fn is_surface(wl_surface: *wl.Surface) bool {
    return if (surface) |s| s.wl_surface == wl_surface else false;
}


/// The pointer is on the tooltip at `surface_y`, in logical pixels, or it is
/// not on the tooltip (null).
pub fn pointer(surface_y: ?i32) void {
    pointer_on = surface_y != null;
    if (pointer_on) leave_time = null;
    const line = if (surface_y) |y| line_at(y) else null;
    if (line != hovered) {
        hovered = line;
        if (visible) request_render();
    }
}


/// A button of the pointer on `wl_surface`. river sends no interaction event
/// for a layer surface: a press on the layer surface of the tooltip is a
/// click. True when `wl_surface` is that surface.
pub fn pointer_button(wl_surface: *wl.Surface, button: types.Button, pressed: bool) bool {
    const s = surface orelse return false;
    if (s.wl_surface != wl_surface or s.role != .layer) return false;
    if (pressed) click(button);
    return true;
}


/// A click on the tooltip runs the command of the line under the pointer,
/// or selects the layout of the line.
pub fn click(button: types.Button) void {
    if (button != .left or !visible) return;
    const t = target orelse return;
    const line = hovered orelse return;
    if (line_layout(&t, line)) |layout| {
        log.debug("click line {}: layout {s}", .{ line, @tagName(layout) });
        t.bar.output.set_current_layout(layout);
        ctx.manage_dirty(@src());
        close();
        return;
    }
    const cmd = line_command(&t, line) orelse return;
    log.debug("click line {}: {s}", .{ line, cmd });
    ctx.spawn_shell(cmd);
}


fn line_at(surface_y: i32) ?usize {
    const y = utils.logical2physics(i32, surface_y, line_box.scale) - line_box.top;
    if (y < 0) return null;
    const line: usize = @intCast(@divFloor(y, line_box.height));
    return if (line < line_box.count) line else null;
}


/// The click command of a line of the tooltip of `t`, or null.
fn line_command(t: *const Target, line: usize) ?[]const u8 {
    return switch (t.area) {
        .widget => |w| widgets.tooltip_command(w.side, w.index, line),
        else => null,
    };
}


/// The layout of a line of the menu of the layouts, or null.
fn line_layout(t: *const Target, line: usize) ?Layout.Type {
    if (t.area != .layout) return null;
    const layouts = ctx.cfg.cycle_layouts;
    return if (line < layouts.len) layouts[line] else null;
}


/// True when a click on line `line` does something.
fn line_clickable(t: *const Target, line: usize) bool {
    return line_layout(t, line) != null or line_command(t, line) != null;
}


/// True when a line of the tooltip has a click command, or the tooltip is
/// the menu of the layouts.
fn clickable() bool {
    const t = target orelse return false;
    switch (t.area) {
        .layout => return ctx.cfg.cycle_layouts.len > 0,
        .widget => |w| {
            const list = widgets.states(w.side);
            if (w.index >= list.len) return false;
            return mem.indexOfNone(u8, list[w.index].tooltip_on_click.items, "\x00") != null;
        },
        else => return false,
    }
}


fn show_later(_: *Context) void {
    // Show only the target of the newest hover.
    if (target == null or shown_generation == generation) return;
    shown_generation = generation;
    visible = true;
    request_render();
}


/// The text of a widget changed, or the layout changed.
pub fn damage() void {
    if (visible) dirty = true;
}


/// True when the tooltip waits for a render sequence.
pub fn needs_render() bool {
    return dirty;
}


/// The bar goes away. Forget it.
pub fn forget(bar: *Bar) void {
    if (target) |t| if (t.bar == bar) close();
}


fn request_render() void {
    dirty = true;
    ctx.manage_dirty(@src());
}


/// Call in each render sequence.
pub fn render() void {
    if (!dirty) return;
    dirty = false;
    log.debug("render, target: {}, visible: {}", .{ target != null, visible });

    const t = target orelse return hide();
    if (!visible) return hide();

    var layout_buffer: [256]u8 = undefined;
    var tray_buffer: [1024]u8 = undefined;
    const text = switch (t.area) {
        .widget => |w| blk: {
            const states = widgets.states(w.side);
            if (w.index >= states.len or states[w.index].hidden) return hide();
            break :blk states[w.index].tooltip.items;
        },
        .layout => layout_list(t.bar.output, &layout_buffer),
        .tray => |ptr| if (comptime build_options.tray_enabled)
                (tray.find(ptr) orelse return hide()).tooltip(&tray_buffer)
            else "",
    };
    if (text.len == 0) return hide();

    // A layer surface stays on its output.
    if (surface) |s| if (s.output != t.bar.output) hide();
    if (surface == null) {
        surface = Surface.create(t.bar.output) catch |err| {
            log.err("create tooltip surface failed: {}", .{ err });
            return;
        };
    }
    // The configure event of the layer surface requests a render again.
    if (!surface.?.ready()) return;
    draw(surface.?, &t, text) catch |err| {
        log.err("draw tooltip failed: {}", .{ err });
        hide();
    };
}


pub fn deinit() void {
    target = null;
    visible = false;
    hide();
}


/// The layouts of `cycle_layouts`, in their order. ">> <<" is around the
/// current layout. draw puts the mark of each layout before its line.
fn layout_list(output: *Output, buffer: []u8) []const u8 {
    const current = std.meta.activeTag(output.current_layout());
    var len: usize = 0;
    for (ctx.cfg.cycle_layouts, 0..) |layout, i| {
        const selected = layout == current;
        const line = std.fmt.bufPrint(buffer[len..], "{s}{s}{s}{s}", .{
            if (i == 0) "" else "\n",
            if (selected) ">> " else "   ",
            @tagName(layout),
            if (selected) " <<" else "",
        }) catch break;
        // "centered master", not "centered_master".
        mem.replaceScalar(u8, buffer[len..][0..line.len], '_', ' ');
        len += line.len;
    }
    return buffer[0..len];
}


fn hide() void {
    if (surface) |s| {
        s.destroy();
        surface = null;
    }
}


fn draw(s: *Surface, t: *const Target, text: []const u8) !void {
    const bar = t.bar;
    const font = &bar.font;
    const scheme = theme.bar_base_scheme().normal;
    const pad: i32 = @divFloor(font.height(), 2);
    const line_height: i32 = font.height();
    // The menu of the layouts: the mark of the layout before each line, and
    // half of a pad between the mark and the text.
    const mark = bar.mark_place();
    const mark_w: i32 = if (t.area == .layout) mark.side + @divFloor(pad, 2) else 0;

    // Rasterize each line. Refer to tooltip_line.zig for the colors.
    var runs: std.ArrayList(*const fcft.TextRun) = .empty;
    var colors: std.ArrayList(?u32) = .empty;
    defer {
        for (runs.items) |run| run.destroy();
        runs.deinit(ctx.gpa);
        colors.deinit(ctx.gpa);
    }
    var width: i32 = 0;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = tooltip_line.parse(raw);
        try colors.append(ctx.gpa, line.color);
        const utf8 = try render_.utils.to_utf8(ctx.gpa, line.text);
        defer ctx.gpa.free(utf8);
        const run = font.rasterize_text_run(utf8) orelse return error.RasterizeFailed;
        runs.append(ctx.gpa, run) catch |err| {
            run.destroy();
            return err;
        };
        width = @max(width, @as(i32, @intCast(render_.utils.text_width(run))));
    }

    // Not larger than the output.
    const size = tooltip_place.size(
        width + mark_w,
        runs.items.len,
        line_height,
        pad,
        utils.logical2physics(i32, bar.output.width, bar.scale),
        utils.logical2physics(i32, bar.output.height, bar.scale),
    );
    const w = size.width;
    const h = size.height;
    const shown = runs.items[0..size.lines];

    const buffer = s.next_buffer() orelse return error.NoBuffer;
    try buffer.init(w, h);

    // A border in the text color around the background.
    const fg = render_.utils.color(scheme.fg);
    const bg = render_.utils.color(scheme.bg);
    var rect = [_]pixman.Rectangle16 {
        .{ .x = 0, .y = 0, .width = @intCast(w), .height = @intCast(h) },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &fg, 1, &rect);
    rect[0] = .{ .x = 1, .y = 1, .width = @intCast(w - 2), .height = @intCast(h - 2) };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &rect);

    const top: i32 = @divFloor(pad, 2);
    line_box = .{
        .top = top,
        .height = line_height,
        .count = shown.len,
        .scale = bar.scale,
    };

    // The line under the pointer has the inverse colors, if it has a click
    // command.
    var y: i32 = top;
    for (shown, 0..) |run, i| {
        const selected = hovered == i and line_clickable(t, i);
        if (selected) {
            rect[0] = .{ .x = 1, .y = @intCast(y), .width = @intCast(w - 2), .height = @intCast(line_height) };
            _ = pixman.Image.fillRectangles(.src, buffer.image, &fg, 1, &rect);
        }
        const color = if (colors.items[i]) |c| render_.utils.color(c) else fg;
        const text_color = if (selected) &bg else &color;
        if (line_layout(t, i)) |layout| {
            Bar.draw_mark(buffer, text_color, Bar.layout_shape(bar.output, layout), pad, y + mark.top, mark.side, mark.gap);
        }
        _ = font.render_text(buffer, run, text_color, pad + mark_w, y);
        y += line_height;
    }

    // Below a bar at the top, and above a bar at the bottom. Refer to
    // tooltip_place.zig.
    const output = bar.output;
    const logical_w = utils.physics2logical(i32, w, bar.scale);
    const logical_h = utils.physics2logical(i32, h, bar.scale);
    const position = tooltip_place.place(.{
        .pointer_x = t.pointer_x,
        .pointer_y = t.pointer_y,
        .area_x = t.x,
        .width = logical_w,
        .output_x = output.x,
        .output_width = output.width,
        .bar_y = switch (ctx.cfg.bar.position) {
            .top => output.y + bar.height(true),
            .bottom => output.y + output.height - bar.height(true) - logical_h,
        },
        .bar_top = ctx.cfg.bar.position == .top,
        .cursor = cursor_size(),
        .clickable = clickable(),
    });

    switch (s.role) {
        .layer => |layer| {
            const margin = tooltip_place.on_output(position, output.x, output.y);
            layer.zwlr_layer_surface.setSize(@intCast(logical_w), @intCast(logical_h));
            layer.zwlr_layer_surface.setMargin(margin.y, 0, 0, margin.x);
        },
        .shell => |*shell| {
            shell.sync_next_commit();
            shell.place(.top);
            shell.set_position(position.x, position.y);
        },
    }

    s.wl_surface.attach(buffer.wl_buffer, 0, 0);
    s.wl_surface.damageBuffer(0, 0, w, h);
    s.wp_viewport.setDestination(logical_w, logical_h);
    s.wl_surface.commit();
}


/// The size of the cursor, in logical pixels. river uses the size of the
/// xcursor theme, or XCURSOR_SIZE, or 24.
fn cursor_size() i32 {
    if (ctx.cfg.xcursor_theme) |cursor_theme| return @intCast(cursor_theme.size);
    if (ctx.env.get("XCURSOR_SIZE")) |size| {
        return std.fmt.parseInt(i32, size, 10) catch 24;
    }
    return 24;
}
