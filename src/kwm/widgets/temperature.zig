//! Temperature widget: the hottest sensor of /sys/class/hwmon as a meter.
//! The tooltip has all the sensors, one on each line. Without sensors, the
//! widget hides.
//!
//! With `nvidia_smi`, the widget also shows the NVIDIA GPUs. Their driver
//! has no hwmon device. nvidia-smi runs in the background (as a script
//! widget), and the widget uses its last output.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

const posix = @import("posix");

const common = @import("common.zig");
const script = @import("script.zig");
const thermal = @import("thermal.zig");
const ctx = common.ctx;

/// kwm ignores the sensors after this number.
const max_readings = 64;
const max_gpus = 4;

/// stderr goes to /dev/null: without a driver, nvidia-smi writes an error
/// at each update.
const nvidia_smi_command =
    "exec nvidia-smi --query-gpu=name,temperature.gpu --format=csv,noheader,nounits 2>/dev/null";

/// The last output of nvidia-smi.
pub const Data = struct {
    gpus: [max_gpus]thermal.Reading = undefined,
    gpu_count: usize = 0,
};


/// Start nvidia-smi when the widget needs it, it does not run yet, and an
/// NVIDIA GPU is awake. nvidia-smi wakes a GPU that sleeps (runtime D3),
/// thus a GPU that sleeps has no reading.
pub fn start_nvidia_smi(cfg: anytype, data: *Data, process: *script.Data) void {
    if (!cfg.nvidia_smi or process.* != null) return;
    if (!nvidia_awake()) {
        data.gpu_count = 0;
        return;
    }
    process.* = script.start(nvidia_smi_command);
}


/// Read the output of nvidia-smi. Return true when it stopped: `data` then
/// has its GPUs and `process` is null.
pub fn read_nvidia_smi(data: *Data, process: *script.Data) bool {
    const p = if (process.*) |*p| p else return false;

    var buffer: [1024]u8 = undefined;
    while (true) {
        const n = posix.read(p.fd, &buffer) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => 0,
        };
        if (n == 0) break;
        p.line.appendSlice(ctx.gpa, buffer[0..n]) catch break;
    }

    data.gpu_count = 0;
    var lines = mem.splitScalar(u8, p.line.items, '\n');
    while (lines.next()) |line| {
        if (data.gpu_count == max_gpus) break;
        const gpu = thermal.parse_nvidia_smi(line) orelse continue;
        if (!thermal.plausible(gpu.millidegrees)) continue;
        data.gpus[data.gpu_count] = .init(thermal.nvidia_smi_device, @intCast(data.gpu_count), gpu.millidegrees, "nvidia", gpu.name);
        data.gpu_count += 1;
    }

    posix.close(p.fd);
    p.line.deinit(ctx.gpa);
    process.* = null;
    return true;
}


pub fn update(cfg: anytype, data: *const Data, out: *common.Output) !void {
    var readings: [max_readings + max_gpus]thermal.Reading = undefined;
    var count = read_sensors(cfg.ignore, readings[0..max_readings]);
    if (cfg.nvidia_smi) {
        for (data.gpus[0..data.gpu_count]) |gpu| {
            readings[count] = gpu;
            count += 1;
        }
    }
    const all = readings[0..count];
    mem.sort(thermal.Reading, all, {}, thermal.less_than);

    const hottest = thermal.hottest(all) orelse {
        out.hidden = true;
        return;
    };
    out.hidden = !thermal.shown(hottest.millidegrees, cfg.show);

    const percent = thermal.percent(hottest.millidegrees, cfg.low, cfg.high);
    const color = common.level_color(percent, cfg.warning, cfg.critical);
    switch (cfg.format) {
        .braille => try common.append_braille(&out.text, color, percent),
        .celsius => {
            var buffer: [16]u8 = undefined;
            const text = try thermal.celsius_text(&buffer, hottest.millidegrees);
            try common.append_colored(&out.text, color, text);
        },
    }

    // A sensor above the warning or critical percentage has that color.
    // Refer to tooltip_line.zig.
    for (all, 0..) |*r, i| {
        if (i > 0) try out.tooltip.append(ctx.gpa, '\n');
        const level = thermal.percent(r.millidegrees, cfg.low, cfg.high);
        if (common.level_color(level, cfg.warning, cfg.critical)) |c| {
            try out.tooltip.print(ctx.gpa, "^#{x:0>8}", .{ c });
        }
        try out.tooltip.print(ctx.gpa, "{f}", .{ r.* });
    }
}


/// Read the temp<N>_input files of the hwmon devices into `readings`. The
/// devices with a name in `ignore` are not read. Return the number of
/// readings. A sensor that gives an error (for example a device that
/// sleeps) or a wrong value is not in the list.
fn read_sensors(ignore: []const []const u8, readings: []thermal.Reading) usize {
    var class = Io.Dir.openDirAbsolute(ctx.io, "/sys/class/hwmon", .{ .iterate = true }) catch return 0;
    defer class.close(ctx.io);

    var count: usize = 0;
    var devices = class.iterate();
    while (devices.next(ctx.io) catch null) |device| {
        const hwmon = thermal.parse_index(device.name, "hwmon", "") orelse continue;
        var dir = class.openDir(ctx.io, device.name, .{ .iterate = true }) catch continue;
        defer dir.close(ctx.io);

        var name_buffer: [64]u8 = undefined;
        const name = read_text(dir, "name", &name_buffer) orelse device.name;
        if (thermal.ignored(name, ignore)) continue;

        var files = dir.iterate();
        while (files.next(ctx.io) catch null) |file| {
            if (count == readings.len) return count;
            const index = thermal.parse_index(file.name, "temp", "_input") orelse continue;

            var value_buffer: [32]u8 = undefined;
            const value = read_text(dir, file.name, &value_buffer) orelse continue;
            const millidegrees = fmt.parseInt(i64, value, 10) catch continue;
            if (!thermal.plausible(millidegrees)) continue;

            var path_buffer: [32]u8 = undefined;
            const label_path = fmt.bufPrint(&path_buffer, "temp{}_label", .{ index }) catch continue;
            var label_buffer: [64]u8 = undefined;
            const label = read_text(dir, label_path, &label_buffer);

            readings[count] = .init(hwmon, index, millidegrees, name, label);
            count += 1;
        }
    }
    return count;
}


/// True when an NVIDIA display controller of /sys/bus/pci is not in runtime
/// suspend. False without an NVIDIA GPU.
fn nvidia_awake() bool {
    var bus = Io.Dir.openDirAbsolute(ctx.io, "/sys/bus/pci/devices", .{ .iterate = true }) catch return false;
    defer bus.close(ctx.io);

    var devices = bus.iterate();
    while (devices.next(ctx.io) catch null) |device| {
        var dir = bus.openDir(ctx.io, device.name, .{}) catch continue;
        defer dir.close(ctx.io);

        var buffer: [32]u8 = undefined;
        const vendor = read_text(dir, "vendor", &buffer) orelse continue;
        if (!mem.eql(u8, vendor, "0x10de")) continue;
        // Class 0x03: a display controller (not the audio device of the GPU).
        const class = read_text(dir, "class", &buffer) orelse continue;
        if (!mem.startsWith(u8, class, "0x03")) continue;
        const status = read_text(dir, "power/runtime_status", &buffer) orelse return true;
        if (!mem.eql(u8, status, "suspended")) return true;
    }
    return false;
}


/// The text of a file in `dir`, without the new line. null: an error.
fn read_text(dir: Io.Dir, path: []const u8, buffer: []u8) ?[]const u8 {
    const text = dir.readFile(ctx.io, path, buffer) catch return null;
    return mem.trim(u8, text, " \n");
}
