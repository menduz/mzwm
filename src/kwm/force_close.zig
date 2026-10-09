//! The close button for a window that does not close, without Wayland
//! objects. window.zig gives the values to these functions. `zig build test`
//! runs the tests below.
//!
//! A click on the close button asks the client to close its window. A client
//! that does not answer (for example a Qt program that hangs) keeps its
//! window. A click `delay` milliseconds or more after the last request runs
//! `kill_prompt` of the configuration, as xfwm4 does. The prompt gets the
//! rows "Kill it" and "Cancel" on its standard input, and writes the index of
//! the selected row. With "Kill it" (0), the process of the window gets
//! SIGKILL.
//!
//! The pid of a window comes from the unreliable_pid event of river. It can be
//! the pid of a process that holds more programs: Xwayland, or the Sentry of
//! gVisor (runsc) for all programs of a sandbox. kwm does not kill such a
//! process, or river, or itself. A process can stop and its pid can go to a
//! new process before the answer, thus the kill compares the start time of
//! the process with the start time at the click.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;


/// The time between a close request and a click that runs the prompt, in
/// milliseconds.
pub const delay = 2000;

/// The programs that kwm does not kill, by the name of the executable.
const protected = [_][]const u8 { "Xwayland", "river", "kwm", "runsc" };


pub const Action = enum {
    /// Ask the client to close the window.
    close,
    /// Run the kill prompt.
    ask,
};


/// The action of a click on the close button. `requested_ms` is the time of
/// the last close request, null: no request yet.
pub fn action(requested_ms: ?i64, now_ms: i64) Action {
    const requested = requested_ms orelse return .close;
    return if (now_ms - requested >= delay) .ask else .close;
}


/// The name of the executable, from the target of /proc/<pid>/exe.
pub fn exe_name(target: []const u8) []const u8 {
    const path = if (mem.endsWith(u8, target, " (deleted)")) target[0 .. target.len - " (deleted)".len] else target;
    const slash = mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}


/// Whether kwm can kill the process `pid` with the executable `exe`. `own_pid`
/// is the pid of kwm.
pub fn may_kill(pid: i32, own_pid: i32, exe: []const u8) bool {
    if (pid <= 1 or pid == own_pid or exe.len == 0) return false;
    for (protected) |name| {
        if (mem.eql(u8, exe, name)) return false;
    }
    return true;
}


/// The start time of the process (field 22 of /proc/<pid>/stat), from the
/// contents of that file. The name of the program (field 2) can hold spaces
/// and parentheses, thus the fields start after the last ")".
pub fn start_time(stat: []const u8) ?[]const u8 {
    const close_paren = mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
    // The fields after the name start at field 3. Field 22 is the 20th.
    var i: usize = 3;
    while (fields.next()) |field| : (i += 1) {
        if (i == 22) return field;
    }
    return null;
}


/// The shell script that runs the prompt (its arguments, "$@") and kills the
/// process `pid` after "Kill it", if the process has the start time `start`.
pub fn script(buffer: []u8, pid: i32, start: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        \\[ "$(printf '{s}' | "$@")" = 0 ] || exit 0
        \\stat=$(cat /proc/{d}/stat 2>/dev/null) || exit 0
        \\[ "$(printf '%s' "${{stat##*) }}" | cut -d ' ' -f 20)" = {s} ] || exit 0
        \\kill -KILL {d}
    , .{ "Kill it\\nCancel\\n", pid, start, pid });
}


test "action: the first click asks the client to close" {
    try testing.expectEqual(Action.close, action(null, 5000));
}

test "action: a click soon after the request asks the client again" {
    try testing.expectEqual(Action.close, action(5000, 5000 + delay - 1));
}

test "action: a click after the delay runs the prompt" {
    try testing.expectEqual(Action.ask, action(5000, 5000 + delay));
}

test "exe_name: the last part of the path" {
    try testing.expectEqualStrings("opensnitch-ui", exe_name("/nix/store/abc-opensnitch-ui/bin/opensnitch-ui"));
    try testing.expectEqualStrings("Xwayland", exe_name("/nix/store/abc-xwayland/bin/Xwayland (deleted)"));
    try testing.expectEqualStrings("runsc", exe_name("runsc"));
}

test "may_kill: a program of the user" {
    try testing.expect(may_kill(4242, 100, "opensnitch-ui"));
}

test "may_kill: not a process that holds more programs, river or kwm" {
    try testing.expect(!may_kill(4242, 100, "Xwayland"));
    try testing.expect(!may_kill(4242, 100, "runsc"));
    try testing.expect(!may_kill(4242, 100, "river"));
    try testing.expect(!may_kill(100, 100, "kwm-wrapped"));
    try testing.expect(!may_kill(4242, 100, "kwm"));
}

test "may_kill: no pid or an unknown executable" {
    try testing.expect(!may_kill(0, 100, "opensnitch-ui"));
    try testing.expect(!may_kill(1, 100, "systemd"));
    try testing.expect(!may_kill(4242, 100, ""));
}

test "start_time: field 22, also with spaces and parentheses in the name" {
    const stat = "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 3 0 987654 1000 200";
    try testing.expectEqualStrings("987654", start_time(stat).?);
    try testing.expect(start_time("4242 (x) S 1 2") == null);
    try testing.expect(start_time("no name") == null);
}

test "script: the prompt, then the kill of the same process" {
    var buffer: [512]u8 = undefined;
    const text = try script(&buffer, 4242, "987654");
    try testing.expect(mem.indexOf(u8, text, "printf 'Kill it\\nCancel\\n' | \"$@\"") != null);
    try testing.expect(mem.indexOf(u8, text, "/proc/4242/stat") != null);
    try testing.expect(mem.indexOf(u8, text, "= 987654 ]") != null);
    try testing.expect(mem.endsWith(u8, text, "kill -KILL 4242"));
}
