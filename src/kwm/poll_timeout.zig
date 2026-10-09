//! The timeout of poll() in the main loop of kwm, without Wayland objects.
//! kwm.zig gives the time of the next timer task and the timeout of the tray
//! bus to this function. `zig build test` runs the tests below.
//!
//! A timer task can become due after run_timer_tasks, for example when the
//! tray bus is slow after a resume. Then the time of the task is in the past.
//! poll() does not have a timeout for a negative value. Thus the task waits
//! for the next event, for example the start of kwim after a new keyboard.


const std = @import("std");
const testing = std.testing;


/// The timeout of poll() in milliseconds. -1 is no timeout.
/// `task_ms` is the time of the next timer task, `tray_ms` is the timeout of
/// the tray bus.
pub fn get(task_ms: ?i64, now_ms: i64, tray_ms: ?i64) i64 {
    const task_timeout: ?i64 = if (task_ms) |time| @max(time - now_ms, 0) else null;
    if (task_timeout) |t| {
        if (tray_ms) |tray| return @min(t, tray);
        return t;
    }
    return tray_ms orelse -1;
}


test "get: no timer task and no tray, no timeout" {
    try testing.expectEqual(@as(i64, -1), get(null, 1000, null));
}

test "get: the time until the next timer task" {
    try testing.expectEqual(@as(i64, 100), get(1100, 1000, null));
}

test "get: a timer task in the past runs now" {
    try testing.expectEqual(@as(i64, 0), get(990, 1000, null));
    try testing.expectEqual(@as(i64, 0), get(990, 1000, 50));
}

test "get: the tray timeout without a timer task" {
    try testing.expectEqual(@as(i64, 50), get(null, 1000, 50));
}

test "get: the smaller of the two timeouts" {
    try testing.expectEqual(@as(i64, 50), get(1100, 1000, 50));
    try testing.expectEqual(@as(i64, 20), get(1020, 1000, 50));
}
