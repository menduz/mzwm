//! The placeholder of a floating window that the pointer holds at a drop
//! target: a fill and an outline at the place of the window after the drop
//! (`drop_placeholder` of context.zig). The placeholder is above all
//! windows: the dragged window is often above the place, and the fill lets
//! the windows below show through. Refer to drag.zig and to `drag.preview`
//! in the configuration.

const std = @import("std");
const log = std.log.scoped(.drop_preview);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;

const drag = @import("drag.zig");
const Context = @import("context.zig");
const ShellSurface = @import("shell_surface.zig");
const SolidColorComponent = @import("render/solid_color_component.zig");

const ctx = Context.get();


const Surface = struct {
    wl_surface: *wl.Surface,
    wp_viewport: *wp.Viewport,
    shell_surface: ShellSurface = undefined,
    fill: SolidColorComponent = undefined,
    top: SolidColorComponent = undefined,
    bottom: SolidColorComponent = undefined,
    left: SolidColorComponent = undefined,
    right: SolidColorComponent = undefined,
    /// The area that the surface shows. null: the surface has no buffer.
    shown: ?drag.Area = null,
};

var surface: ?Surface = null;


fn init() !void {
    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    // The pointer goes through the placeholder.
    const wl_region = try ctx.wl_compositor.createRegion();
    defer wl_region.destroy();
    wl_surface.setInputRegion(wl_region);

    surface = .{ .wl_surface = wl_surface, .wp_viewport = wp_viewport };
    errdefer surface = null;
    const s = &surface.?;
    try s.shell_surface.init(wl_surface, .drop_preview);
    errdefer s.shell_surface.deinit();

    try s.fill.init(wl_surface);
    errdefer s.fill.deinit();
    try s.top.init(wl_surface);
    errdefer s.top.deinit();
    try s.bottom.init(wl_surface);
    errdefer s.bottom.deinit();
    try s.left.init(wl_surface);
    errdefer s.left.deinit();
    try s.right.init(wl_surface);
}


pub fn deinit() void {
    const s = &(surface orelse return);
    s.right.deinit();
    s.left.deinit();
    s.bottom.deinit();
    s.top.deinit();
    s.fill.deinit();
    s.shell_surface.deinit();
    s.wp_viewport.destroy();
    s.wl_surface.destroy();
    surface = null;
}


/// Show the placeholder at `drop_placeholder`, or hide it. Only a change of
/// the place draws the placeholder again.
pub fn render() void {
    const area = ctx.drop_placeholder;
    const colors = ctx.cfg.drag.preview orelse return;
    if (surface == null) {
        if (area == null) return;
        init() catch |err| {
            log.err("init failed: {}", .{ err });
            return;
        };
    }
    const s = &surface.?;
    if (std.meta.eql(area, s.shown)) {
        // A window that kwm lifts goes above the placeholder: the
        // placeholder goes back to the top.
        if (area != null) s.shell_surface.place(.top);
        return;
    }
    s.shown = area;

    const a = area orelse {
        log.debug("hide", .{});
        s.wl_surface.attach(null, 0, 0);
        s.wl_surface.commit();
        return;
    };
    log.debug("show at (x: {}, y: {}, width: {}, height: {})", .{ a.x, a.y, a.width, a.height });

    // The surface itself is transparent. Only its parts have a color.
    const buffer = ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0) catch |err| {
        log.err("create buffer failed: {}", .{ err });
        return;
    };
    defer buffer.destroy();

    const w = std.math.clamp(colors.outline_width, 0, @divFloor(@min(a.width, a.height), 2));
    const fill = drag.premultiplied(colors.fill);
    const outline = drag.premultiplied(colors.outline);
    s.fill.render(w, w, @max(1, a.width - 2 * w), @max(1, a.height - 2 * w), fill);
    s.top.render(0, 0, a.width, @max(1, w), if (w > 0) outline else 0);
    s.bottom.render(0, a.height - @max(1, w), a.width, @max(1, w), if (w > 0) outline else 0);
    s.left.render(0, w, @max(1, w), @max(1, a.height - 2 * w), if (w > 0) outline else 0);
    s.right.render(a.width - @max(1, w), w, @max(1, w), @max(1, a.height - 2 * w), if (w > 0) outline else 0);

    s.shell_surface.sync_next_commit();
    s.shell_surface.place(.top);
    s.shell_surface.set_position(a.x, a.y);
    s.wl_surface.attach(buffer, 0, 0);
    s.wl_surface.damageBuffer(0, 0, 1, 1);
    s.wp_viewport.setDestination(a.width, a.height);
    s.wl_surface.commit();
}
