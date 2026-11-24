//! The GTK theme of the desktop, from the settings portal
//! (org.freedesktop.portal.Settings) on the session bus. toggle-theme of
//! nix-config sets the GSettings key org.gnome.desktop.interface gtk-theme;
//! the portal then sends SettingChanged, and kwm reads the colors of the new
//! theme (theme.set_gtk_theme). At the start, without GTK_THEME, kwm reads
//! the key with ReadOne. portal_setting.zig chooses the setting.
//!
//! kwm also follows the key icon-theme: the bar shows the icon of the
//! program of the focused window from this icon theme (icons.set_app_theme).
//! GTK_THEME does not change the icon theme: kwm always reads this key.
//!
//! kwm also follows the color scheme (org.freedesktop.appearance
//! color-scheme): a window of a sandbox that follows the color scheme of the
//! host uses the dark GTK theme of the sandbox when the host prefers dark
//! (theme.set_prefer_dark).
//!
//! kwm uses the connection of the tray: tray.zig calls `attach` after it
//! connects and `detach` before it disconnects. Thus kwm follows the theme
//! only with the tray.

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.settings_portal);

const sd = @import("sd_bus.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const portal_setting = @import("portal_setting.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_interface = "org.freedesktop.portal.Settings";

var signal_slot: ?*sd.Slot = null;

/// A call of ReadOne, for a key of portal_setting.zig.
const Read = struct {
    namespace: [:0]const u8 = portal_setting.namespace,
    key: [:0]const u8,
    slot: ?*sd.Slot = null,
};
var reads = [_]Read {
    .{ .key = portal_setting.key },
    .{ .key = portal_setting.icon_key },
    .{ .namespace = portal_setting.appearance_namespace, .key = portal_setting.color_scheme_key },
};


/// Follow the GTK theme and the icon theme on the bus `bus`.
pub fn attach(bus: *sd.Bus) void {
    _ = sd.check(
        sd.sd_bus_match_signal_async(
            bus, &signal_slot, portal_name, portal_path, settings_interface,
            "SettingChanged", on_setting_changed, null, null,
        ),
        "match SettingChanged",
    ) catch return;

    for (&reads) |*read| {
        // GTK_THEME comes first, as for GTK.
        if (mem.eql(u8, read.key, portal_setting.key) and ctx.env.get("GTK_THEME") != null) continue;
        _ = sd.check(
            sd.sd_bus_call_method_async(
                bus, &read.slot, portal_name, portal_path, settings_interface,
                "ReadOne", on_read_one, read, "ss",
                read.namespace.ptr, read.key.ptr,
            ),
            "call ReadOne",
        ) catch continue;
    }
}


pub fn detach() void {
    signal_slot = sd.sd_bus_slot_unref(signal_slot);
    for (&reads) |*read| read.slot = sd.sd_bus_slot_unref(read.slot);
}


/// Read a number in a variant.
fn read_variant_u32(m: *sd.Message) ?u32 {
    if (sd.sd_bus_message_enter_container(m, 'v', "u") <= 0) return null;
    var n: u32 = 0;
    if (sd.sd_bus_message_read_basic(m, 'u', @ptrCast(&n)) <= 0) return null;
    return n;
}


/// Read a string in a variant.
fn read_variant_string(m: *sd.Message) ?[]const u8 {
    if (sd.sd_bus_message_enter_container(m, 'v', "s") <= 0) return null;
    var s: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read_basic(m, 's', @ptrCast(&s)) <= 0) return null;
    return mem.span(s orelse return null);
}


/// Apply the setting (namespace, key) with the value in the variant of `m`.
fn apply(namespace: []const u8, key: []const u8, m: *sd.Message) void {
    if (portal_setting.is_color_scheme(namespace, key)) {
        const value = read_variant_u32(m) orelse return;
        log.info("color scheme from the settings portal: {}", .{ value });
        theme.set_prefer_dark(portal_setting.prefer_dark(value));
        return;
    }

    const value = read_variant_string(m) orelse return;
    if (portal_setting.gtk_theme(namespace, key, value)) |name| {
        log.info("GTK theme from the settings portal: {s}", .{ name });
        theme.set_gtk_theme(name);
    } else if (portal_setting.icon_theme(namespace, key, value)) |name| {
        log.info("icon theme from the settings portal: {s}", .{ name });
        icons.set_app_theme(name);
    }
}


/// SettingChanged (namespace, key, value).
fn on_setting_changed(m: *sd.Message, _: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    var namespace: ?[*:0]const u8 = null;
    var key: ?[*:0]const u8 = null;
    if (sd.sd_bus_message_read(m, "ss", &namespace, &key) <= 0) return 0;
    apply(mem.span(namespace orelse return 0), mem.span(key orelse return 0), m);
    return 0;
}


/// The reply of ReadOne: the value in a variant. `userdata` is the Read.
fn on_read_one(m: *sd.Message, userdata: ?*anyopaque, _: *sd.Error) callconv(.c) c_int {
    const read: *Read = @ptrCast(@alignCast(userdata orelse return 0));
    read.slot = sd.sd_bus_slot_unref(read.slot);
    if (sd.sd_bus_message_get_error(m)) |err| {
        // Without a portal, kwm keeps the colors of the configuration, and
        // the icons of hicolor.
        log.warn("read {s} from the settings portal failed: {s}", .{ read.key, err.message orelse err.name orelse "unknown error" });
        return 0;
    }
    apply(read.namespace, read.key, m);
    return 0;
}
