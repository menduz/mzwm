const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const zon = std.zon;
const process = std.process;
const log = std.log.scoped(.config);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const rule = @import("config/rule.zig");
const constants = @import("config/constants.zig");
const preprocess = @import("config/preprocess.zig");
pub const meta = @import("config/meta.zig");
pub const widget = @import("config/widget.zig");

// work around for zig issue: https://codeberg.org/ziglang/zig/issues/31570
pub const Modifiers = meta.unpacked(river.SeatV1.Modifiers);

pub const Config = struct {
    env: []const struct { []const u8, []const u8 },

    working_directory: union(enum) {
        none,
        home,
        custom: []const u8,
    },

    startup_cmds: []const []const []const u8,

    xcursor_theme: ?struct {
        name: [:0]const u8,
        size: u32,
    },

    background: ?u32,
    /// Read the color of the desktop from xfwm4/themerc of the current GTK
    /// theme: the key of the color in that file. The color replaces
    /// `background`, and follows each change of the theme. Without the key
    /// in the file, kwm uses `background`. With `background` null, kwm does
    /// not fill the desktop. null: use only `background`. Refer to
    /// desktop.zig and theme.zig.
    background_gtk_color: ?[]const u8 = null,

    bar: @import("config/bar.zig"),

    single_tagset: bool,

    /// The pointer over a window focuses it. In a workspace where all
    /// windows float, only a click focuses a window. Refer to
    /// src/kwm/hover_focus.zig.
    sloppy_focus: bool,

    /// No gap at the edges of the output when one tiled window fills it, and
    /// no gap in the monocle layout.
    smart_gaps: bool,

    cursor_warp: enum {
        none,
        on_output_changed,
        on_focus_changed,
    },

    disable_wrap_around_for_scroller: bool,

    remember_floating_geometry: bool,

    /// A window that the pointer moves. Refer to src/kwm/drag.zig.
    drag: struct {
        /// A tiled window that the pointer moves by its title bar becomes
        /// floating when the pointer goes farther than this distance from the
        /// press, in logical pixels. null: the window stays tiled.
        float_distance: ?i32 = 32,
        /// A floating window that the pointer releases this distance or less
        /// from an edge of the output becomes tiled, in logical pixels. The
        /// edge on the side of the master area gives a master window, and
        /// the opposite edge a window at the top of the stack. The bar of
        /// the output also gives a master window. null: the window stays
        /// floating, also on the bar.
        tile_edge: ?i32 = 8,
        /// While the pointer is at such an edge, the other windows show their
        /// places after the drop, and a rectangle shows the place of the
        /// window: a fill and an outline, as 0xRRGGBBAA. null: no preview.
        preview: ?struct {
            fill: u32 = 0xf2971840,
            outline: u32 = 0xf29718ff,
            outline_width: i32 = 2,
        } = .{},
    } = .{},

    auto_swallow: bool,

    default_attach_mode: meta.enum_struct(kwm.Layout.Type, kwm.WindowAttachMode),

    default_window_decoration: kwm.WindowDecoration,
    /// A title bar on each window with server side decorations that is not
    /// maximized or fullscreen, as the caption of win-classic-theme: the title
    /// and a close button. kwm always tries server side decorations. Refer to
    /// src/kwm/decoration.zig.
    title_bar: bool = true,
    /// The command that asks to kill the process of a window that does not
    /// close: a click on the close button 2 seconds after the close request.
    /// It gets the rows "Kill it" and "Cancel" on its standard input, and
    /// writes the index of the row. "{title}" is "<title> does not close".
    /// Refer to src/kwm/force_close.zig.
    kill_prompt: []const []const u8 = &.{ "rofi", "-dmenu", "-i", "-no-custom", "-format", "i", "-p", "{title}" },

    /// A band at the bottom of the focused output, from the left edge to the
    /// right edge, while the Super key stays down alone for `delay`
    /// milliseconds. Super up removes it. A key binding or another modifier
    /// before that stops it until the next press of Super. Only in the
    /// default mode. Refer to src/kwm/overlay.zig and super_hold.zig.
    ///
    /// kwm runs `command` in a pseudo terminal with the width of the output
    /// and `max_height` of its height, and draws the text of the terminal
    /// (libghostty-vt reads the escape sequences). The band has the height
    /// of the rows with text. The default command is the list of the key
    /// bindings: `kwm bindings`. It needs the build option `-Doverlay`.
    overlay: struct {
        enabled: bool = false,
        /// "{config}" is the configuration file of this kwm.
        command: []const []const u8 = &.{ "kwm", "-c", "{config}", "bindings" },
        delay: u32 = 2000,
        /// A fontconfig pattern of a monospace font with a bold face, for
        /// example Iosevka. null: the font of the bar. A bold cell uses the
        /// same font with "weight=bold".
        font: ?[]const u8 = "monospace:size=10",
        /// The highest band, as a part of the height of the output.
        max_height: f32 = 0.5,
        /// The default text and background colors of the terminal.
        fg: u32 = 0x000000ff,
        bg: u32 = 0xffffe1ff,
        /// The color of palette entries 4 and 12 (blue and bright blue).
        /// `kwm bindings` writes the chords in bold color 4.
        accent: u32 = 0x000080ff,
        /// Read the colors from xfwm4/themerc of the current GTK theme. Each
        /// field is a key of that file. A color that the file does not give
        /// comes from the fields above. null: use only the fields above.
        gtk_colors: ?struct {
            fg: []const u8 = "tooltip_text_color",
            bg: []const u8 = "tooltip_color",
            accent: []const u8 = "active_color_1",
        } = .{},
    } = .{},

    border: struct {
        width: i32,
        color: struct {
            focus: u32,
            unfocus: u32,
            swallowing: u32,
        },
        /// The space on each side between a tiled window with client side
        /// decorations and its place in the layout. The client draws its
        /// frame outside its geometry, in this space and in the border. With
        /// the raised style and a value more than 0, kwm draws the outline
        /// of the border around such a window, and no edges. Example: a GTK
        /// frame of 4 pixels has its two edges in a border of 3 pixels with
        /// a margin of 2. A window without the outline (refer to
        /// `raised.outline`) takes the pixel of the outline: its margin is 1
        /// pixel less.
        csd_margin: i32 = 0,
        /// .flat: the compositor draws the border in `color.focus` or
        /// `color.unfocus`.
        /// .raised: kwm draws the window border style of Windows: a raised
        /// outer edge and a raised inner edge, with an outline of 1 pixel
        /// outside them when the border is 3 pixels or more. Refer to `raised`.
        /// A window with client side decorations draws its own frame, thus
        /// kwm draws only the outline around it. Refer to `csd_margin`.
        style: enum { flat, raised } = .flat,
        raised: struct {
            /// The outline of 1 pixel outside the edges, with a border of 3
            /// pixels or more. A title bar shows the focused window, thus the
            /// outline is not necessary.
            /// .all: each window has the outline.
            /// .sandboxes: only a window of a sandbox (not the host), in the
            /// color of the sandbox.
            /// .csd: only a window with client side decorations. kwm draws
            /// no edges around it (refer to `csd_margin`), thus the outline
            /// shows its focus. A window with server side decorations has a
            /// title bar.
            /// .none: no outline. The face takes its pixel.
            outline: enum { all, sandboxes, csd, none } = .all,
            focus: Bevel = .{ .outline = 0x000080ff },
            unfocus: Bevel = .{},
            /// Read the colors from xfwm4/themerc of the current GTK theme.
            /// Each field is a key of that file. A color that the file does
            /// not give comes from `focus` and `unfocus` above. null: use only
            /// `focus` and `unfocus`. Refer to theme.zig and themerc.zig.
            gtk_colors: ?struct {
                face: []const u8 = "active_color_2",
                highlight: []const u8 = "active_hilight_2",
                shadow: []const u8 = "active_shadow_2",
                frame: []const u8 = "active_border_color",
                /// null: the outline comes from `focus` and `unfocus`.
                focus_outline: ?[]const u8 = "active_color_1",
                unfocus_outline: ?[]const u8 = null,
            } = .{},
        } = .{},
    },

    /// The windows of a sandbox. A sandbox launcher starts a program in a
    /// systemd scope below "sandbox-<name>.slice". kwm then shows the name
    /// in the bar, and draws the border in the color of the sandbox from
    /// /etc/sandboxes/config.json. Refer to sandbox.zig.
    sandbox: struct {
        /// Show a label with the name of the sandbox at the top right corner
        /// of each window of a sandbox. A window on the host has no label.
        label: bool = true,
    } = .{},

    default_layout: kwm.Layout.Type,
    layout: kwm.Layout,

    /// The layouts of cycle_layout, of a quick second press of a tag and of
    /// the menu of the selected tag in the bar, in this order. The other
    /// layouts stay: switch_layout, default_layout and the rules can select
    /// them. Refer to src/kwm/layout_cycle.zig.
    cycle_layouts: []const kwm.Layout.Type = &.{ .tile, .centered_master, .float, .monocle },

    /// A set_output_tag to the tag that the output shows, this number of
    /// milliseconds or less after the last set_output_tag to the same tag,
    /// goes to the next layout of `cycle_layouts`. Thus a quick second press
    /// of a tag key changes the layout of the tag. A click on the shown tag
    /// in the bar changes the layout at once, without this delay. null: no
    /// change.
    tag_repeat_cycle: ?u32 = 500,

    bindings: struct {
        repeat_info: struct {
            rate: i32,
            delay: i32,
        },
        key: []const struct {
            mode: ?[]const u8 = null,
            layout: ?u32 = null,
            keysym: []const u8,
            modifiers: Modifiers,
            /// The text of the binding in the list of `kwm bindings`, for
            /// example "Open the browser". null: a text from the action.
            description: ?[]const u8 = null,
            event: kwm.XkbBindingEvent,
        },
        pointer: []const struct {
            mode: ?[]const u8 = null,
            button: kwm.Button,
            modifiers: Modifiers,
            event: kwm.PointerBindingEvent,
        }
    },

    window_rules: []const rule.Window,
    output_rules: []const rule.Output,
};

/// The colors of a raised border. The defaults are those of the classic
/// scheme of Windows 98.
pub const Bevel = struct {
    /// The top and left line of the outer edge.
    face: u32 = 0xc0c0c0ff,
    /// The top and left line of the inner edge.
    highlight: u32 = 0xffffffff,
    /// The bottom and right line of the inner edge.
    shadow: u32 = 0x808080ff,
    /// The bottom and right line of the outer edge.
    frame: u32 = 0x000000ff,
    /// The line of 1 pixel outside the outer edge. Transparent: no outline.
    outline: u32 = 0x00000000,
};

pub const default: Config = @import("default_config");
pub const lock_mode = constants.lock_mode;
pub const default_mode = constants.default_mode;
pub const WindowRule = rule.Window;
pub const OutputRule = rule.Output;


pub fn load(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    path: []const u8,
) !Config {
    log.info("loading configuration from `{s}`", .{ path });

    var buffer = try preprocess.preprocess(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer buffer.deinit(ctx.gpa);

    @setEvalBranchQuota(20000);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(ctx.gpa);
    const config = zon.parse.fromSliceAlloc(
        meta.add_default(Config, default),
        ctx.gpa,
        buffer.items[0..buffer.items.len-1:0],
        &diag,
        // After an error, zon frees the fields that it parsed. These fields
        // can hold slices of `default`, which are not in the heap. Do not
        // free them: kwm uses `default` after an error.
        .{ .ignore_unknown_fields = true, .free_on_error = false },
    ) catch |err| {
        if (err == error.ParseZon) {
            log.err("parse configuration failed: {f}", .{ diag });
        }
        return err;
    };
    return @as(*const Config, @ptrCast(&config)).*;
}


pub fn reload(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    old: *Config,
    path: []const u8
) !meta.field_mask(Config) {
    log.debug("reload configuration from `{s}`", .{ path });

    var new = try load(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer free(ctx.gpa, new);

    var mask: meta.field_mask(Config) = .{};

    const struct_info = @typeInfo(Config).@"struct";
    inline for (struct_info.fields) |field| {
        if (
            !meta.deep_equal(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            )
        ) {
            mem.swap(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            );
            @field(mask, field.name) = true;
        }
    }

    return mask;
}


pub fn free(gpa: mem.Allocator, config: Config) void {
    log.debug("free configuration", .{});

    meta.zon_free(
        gpa,
        @as(*const meta.add_default(Config, default), @ptrCast(&config)).*,
        null
    );
}
