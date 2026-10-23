const Self = @This();

const std = @import("std");
const mem = std.mem;

const kwm = @import("kwm");

const meta = @import("meta.zig");
pub const widget = @import("widget.zig");

pub const Color = struct {
    fg: u32,
    bg: u32,
};
pub const Scheme = struct {
    normal: Color,
    select: Color,
};
pub const BarArea = union(kwm.BarArea) {
    tags,
    mode: ?[]const u8,
    layout: ?kwm.Layout.Type,
    title,
    status,
};


show_default: bool,

position: enum {
    top,
    bottom,
},

font: []const u8,

/// The minimum height of the bar, in logical pixels. When the bar is higher
/// than the font, the text is in the vertical center.
min_height: u32 = 0,

scheme: Scheme,

/// Read the colors of the bar from xfwm4/themerc of the current GTK theme.
/// Each field is a key of that file. The colors replace the colors of
/// `scheme` and `tags.empty_fg`, and follow each change of the theme.
/// `override_colors` apply after them. A color that the file does not give
/// comes from the configuration. null: use only the configuration. Refer to
/// src/kwm/bar_colors.zig.
gtk_colors: ?GtkColors = null,

tags: ?struct {
    tags: []const []const u8,
    /// Text color of the tags without windows. null uses the color of the scheme.
    empty_fg: ?u32 = null,
    /// The background of the selected tags is the color of the desktop
    /// (refer to `background` and `background_gtk_color`), not `select.bg`
    /// of the scheme.
    select_bg_desktop: bool = false,
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

mode: ?struct {
    tags: []const struct { []const u8, []const u8 },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),

    pub fn tag(self: *const @This(), mode: []const u8) ?[]const u8 {
        for (self.tags) |pair| {
            const m, const t = pair;
            if (mem.eql(u8, m, mode)) return t;
        }
        return null;
    }
},

layout: ?struct {
    tags: struct {
        tile: meta.enum_struct(kwm.Layout.Tile.MasterLocation, []const u8),
        grid: meta.enum_struct(kwm.Layout.Grid.Direction, []const u8),
        monocle: []const u8,
        deck: meta.enum_struct(kwm.Layout.Deck.MasterLocation, []const u8),
        scroller: []const u8,
        centered_master: meta.enum_struct(kwm.Layout.CenteredMaster.Direction, []const u8),
        float: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

title: ?struct {
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

status: ?struct {
    data: union(enum) {
        text: []const u8,
        stdin,
        fifo: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

/// Widgets in the center of the bar, and at the right end of the bar.
/// Refer to widget.zig.
center: []const widget.Widget = &.{},
right: []const widget.Widget = &.{},
/// Widgets at the right of the tray, at the right end of the bar.
end: []const widget.Widget = &.{},

widget_colors: struct {
    warning: u32 = 0xffa500ff,
    critical: u32 = 0xff5555ff,
} = .{},

/// Milliseconds that the pointer stays on a widget before its tooltip shows.
/// With 0, the tooltip shows at once.
tooltip_delay: u32 = 500,

/// The system tray (StatusNotifierItem), at the right end of the bar. null:
/// no tray. kwm must be built with -Dtray=true.
tray: ?struct {
    /// The icon size in logical pixels. 0: the height of the bar.
    icon_size: u32 = 0,
    /// Logical pixels between two icons.
    spacing: u32 = 4,
    /// The icon theme for the icon names of the items.
    icon_theme: []const u8 = "hicolor",
    /// Show the items with the status "Passive".
    show_passive: bool = false,
    /// The color saturation of the icons. 1: the colors of the icon.
    /// 0: grayscale. 0.1: 90% grayscale and 10% color.
    saturation: f32 = 1.0,
    /// The program of the menus of the items. kwm writes one row for each
    /// menu item to its standard input, with the row options of rofi, and
    /// reads the index of the chosen row from its standard output. kwm
    /// replaces {title} with the name of the item, and {x}, {y} and {right}
    /// with the place of the icon. Refer to src/kwm/tray_menu.zig.
    menu_command: []const []const u8 = &.{ "rofi", "-dmenu", "-i", "-no-custom", "-format", "i", "-p", "{title}" },
} = null,

override_colors: []const struct {
    area: BarArea,
    scheme: meta.make_fields_optional(Scheme),

    fn is_match(self: *const @This(), area: BarArea) bool {
        if (std.meta.activeTag(self.area) != std.meta.activeTag(area)) return false;

        return switch (area) {
            .mode => |mode|
                if (self.area.mode) |m| mem.eql(u8, mode.?, m)
                else true,
            .layout => |layout|
                if (self.area.layout) |l| layout.? == l
                else true,
            else => true,
        };
    }
},


pub fn get(self: *const Self, comptime area: kwm.BarArea) @FieldType(Self, @tagName(area)) {
    return @field(self, @tagName(area));
}


pub const GtkColors = struct {
    fg: []const u8 = "bar_text_color",
    bg: []const u8 = "bar_color",
    /// The selected tag and the title of the focused output.
    select_fg: []const u8 = "bar_selected_text_color",
    select_bg: []const u8 = "bar_color",
    /// The tags without windows.
    empty_fg: []const u8 = "bar_empty_text_color",
};


pub fn get_scheme(
    self: *const Self,
    area: BarArea,
) Scheme {
    return self.override_scheme(self.scheme, area);
}


/// `base` with the colors of `override_colors` for `area`.
pub fn override_scheme(
    self: *const Self,
    base: Scheme,
    area: BarArea,
) Scheme {
    for (self.override_colors) |item| {
        if (!item.is_match(area)) continue;

        return meta.override(base, item.scheme);
    }

    return base;
}


pub fn empty(self: *const Self) bool {
    inline for (@typeInfo(kwm.BarArea).@"enum".fields) |field| {
        if (@field(self, field.name) != null) return false;
    }
    return true;
}
