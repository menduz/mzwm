//! The long press of the Super key, without Wayland objects. The overlay
//! (overlay.zig) shows when Super stays down for some time.
//! `zig build test` runs the tests below.
//!
//! river tells kwm about a change of the watched modifiers
//! (modifiers_update), and about each key binding and pointer binding that
//! the user presses. river does not tell kwm about a key without a binding,
//! thus Super and such a key can also show the overlay. kwm watches only
//! Super while Super is up, and all modifiers while the sequence runs
//! (`watched`).
//!
//! The sequence:
//!   1. Super goes down: `waiting`. Other modifiers can be down.
//!   2. At `delay - lead` milliseconds, the overlay starts its command
//!      (`prepare_due`), so the text is ready at `delay`.
//!   3. At `delay` milliseconds, the overlay shows (`show_due`).
//!   4. Super goes up: the overlay goes away.
//! A binding before Super goes up stops the sequence. Then the overlay stays
//! away until Super goes up and down again.
//!
//! The overlay shows the bindings with all the modifiers that are down
//! (`filter`). When only Super is down, it shows all bindings. When another
//! modifier goes down or up, the overlay starts its command again
//! (`.update`).


const std = @import("std");
const testing = std.testing;

/// The bit of Super (mod4) in the modifiers of river.
pub const super: u32 = 64;

/// The modifiers of the bindings: shift, ctrl, mod1, mod3, mod4 and mod5.
/// river also gives the locked modifiers Caps Lock (2) and Num Lock (16).
/// The sequence ignores them.
pub const all: u32 = 1 | 4 | 8 | 32 | 64 | 128;

/// Milliseconds before `delay` when the command starts.
pub const lead = 500;

pub const Phase = enum {
    /// Super is up.
    idle,
    /// Super is down alone. The overlay waits for the delay.
    waiting,
    /// The overlay shows.
    shown,
    /// A binding came while Super is down, or the overlay is not allowed.
    blocked,
};

pub const Effect = enum {
    none,
    /// Start the timers of `prepare_due` and `show_due`.
    arm,
    /// Stop the command and remove the overlay.
    stop,
    /// The modifiers changed. Start the command again for the new
    /// `filter`, if it started.
    update,
};

pub const State = struct {
    phase: Phase = .idle,
    /// The time when Super went down, in milliseconds.
    start: i64 = 0,
    /// The command started for this press.
    prepared: bool = false,
    /// The modifiers that are down, without the locked modifiers.
    mods: u32 = 0,

    /// The modifiers changed from `old` to `new`. `allowed` is false when
    /// the overlay must not show, for example in the lock mode.
    pub fn modifiers(self: *State, old: u32, new: u32, now: i64, allowed: bool) Effect {
        if (new & super == 0) return self.reset(.idle);

        if (old & super == 0) {
            if (!allowed) return self.reset(.blocked);
            self.* = .{ .phase = .waiting, .start = now, .mods = new & all };
            return .arm;
        }

        // Super stays down, and another modifier changed.
        if (self.phase != .waiting and self.phase != .shown) return .none;
        if (new & all == self.mods) return .none;
        self.mods = new & all;
        return .update;
    }

    /// The modifiers that each binding in the overlay must have. 0: all
    /// bindings.
    pub fn filter(self: *const State) u32 {
        return if (self.mods == super) 0 else self.mods;
    }

    /// The modifiers that river must tell kwm about: all modifiers while
    /// the sequence runs, else only Super.
    pub fn watched(self: *const State) u32 {
        return switch (self.phase) {
            .waiting, .shown => all,
            .idle, .blocked => super,
        };
    }

    /// The user pressed a key binding or a pointer binding.
    pub fn binding(self: *State) Effect {
        return switch (self.phase) {
            .waiting, .shown => self.reset(.blocked),
            .idle, .blocked => .none,
        };
    }

    /// True once for a press, when the command must start.
    pub fn prepare_due(self: *State, now: i64, delay: u32) bool {
        if (self.phase != .waiting or self.prepared) return false;
        if (now < self.start + @as(i64, delay) - lead) return false;
        self.prepared = true;
        return true;
    }

    /// True once for a press, when the overlay must show. A timer of an
    /// old press comes too early for the new press, and does nothing.
    pub fn show_due(self: *State, now: i64, delay: u32) bool {
        if (self.phase != .waiting) return false;
        if (now < self.start + @as(i64, delay)) return false;
        self.phase = .shown;
        return true;
    }

    fn reset(self: *State, phase: Phase) Effect {
        const active = self.phase == .waiting or self.phase == .shown;
        self.* = .{ .phase = phase };
        return if (active) .stop else .none;
    }
};


const shift: u32 = 1;
const ctrl: u32 = 4;

test "Super alone: arm, prepare, show, stop at the release" {
    var s: State = .{};
    try testing.expectEqual(Effect.arm, s.modifiers(0, super, 1000, true));
    try testing.expect(!s.prepare_due(2499, 2000));
    try testing.expect(s.prepare_due(2500, 2000));
    try testing.expect(!s.prepare_due(2600, 2000));
    try testing.expect(!s.show_due(2999, 2000));
    try testing.expect(s.show_due(3000, 2000));
    try testing.expect(!s.show_due(3100, 2000));
    try testing.expectEqual(Phase.shown, s.phase);
    try testing.expectEqual(Effect.stop, s.modifiers(super, 0, 4000, true));
    try testing.expectEqual(Phase.idle, s.phase);
}

test "a binding before the delay: no overlay until the next press" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    try testing.expectEqual(Effect.stop, s.binding());
    try testing.expect(!s.prepare_due(1500, 2000));
    try testing.expect(!s.show_due(2000, 2000));
    try testing.expectEqual(Effect.none, s.binding());
    try testing.expectEqual(Effect.none, s.modifiers(super, 0, 3000, true));
    try testing.expectEqual(Effect.arm, s.modifiers(0, super, 4000, true));
}

test "a binding while the overlay shows removes it" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    try testing.expect(s.show_due(2000, 2000));
    try testing.expectEqual(Effect.stop, s.binding());
    try testing.expectEqual(Phase.blocked, s.phase);
}

test "Super alone: all bindings" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    try testing.expectEqual(@as(u32, 0), s.filter());
}

test "another modifier first, then Super: the overlay filters for both" {
    var s: State = .{};
    try testing.expectEqual(Effect.arm, s.modifiers(shift, shift | super, 0, true));
    try testing.expectEqual(shift | super, s.filter());
    try testing.expect(s.show_due(2000, 2000));
    // Shift goes up, Super stays: all bindings.
    try testing.expectEqual(Effect.update, s.modifiers(shift | super, super, 2100, true));
    try testing.expectEqual(@as(u32, 0), s.filter());
}

test "another modifier after Super: update, and the overlay still shows" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    try testing.expectEqual(Effect.update, s.modifiers(super, super | ctrl, 100, true));
    try testing.expectEqual(super | ctrl, s.filter());
    try testing.expect(s.show_due(2000, 2000));
    try testing.expectEqual(Effect.update, s.modifiers(super | ctrl, super | ctrl | shift, 2100, true));
    try testing.expectEqual(super | ctrl | shift, s.filter());
    try testing.expectEqual(Phase.shown, s.phase);
}

test "the locked modifiers do not change the filter" {
    const caps_lock: u32 = 2;
    const num_lock: u32 = 16;
    var s: State = .{};
    try testing.expectEqual(Effect.arm, s.modifiers(num_lock, num_lock | super, 0, true));
    try testing.expectEqual(@as(u32, 0), s.filter());
    try testing.expectEqual(Effect.none, s.modifiers(num_lock | super, num_lock | caps_lock | super, 100, true));
    try testing.expectEqual(@as(u32, 0), s.filter());
}

test "after a binding, other modifiers do nothing" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    _ = s.binding();
    try testing.expectEqual(Effect.none, s.modifiers(super, super | shift, 100, true));
    try testing.expect(!s.show_due(5000, 2000));
}

test "watched: all modifiers only while the sequence runs" {
    var s: State = .{};
    try testing.expectEqual(super, s.watched());
    _ = s.modifiers(0, super, 0, true);
    try testing.expectEqual(all, s.watched());
    try testing.expect(s.show_due(2000, 2000));
    try testing.expectEqual(all, s.watched());
    _ = s.binding();
    try testing.expectEqual(super, s.watched());
    _ = s.modifiers(super, 0, 3000, true);
    try testing.expectEqual(super, s.watched());
    _ = s.modifiers(0, super, 4000, false);
    try testing.expectEqual(super, s.watched());
}

test "not allowed: no overlay" {
    var s: State = .{};
    try testing.expectEqual(Effect.none, s.modifiers(0, super, 0, false));
    try testing.expect(!s.show_due(5000, 2000));
}

test "the timer of an old press does nothing for a new press" {
    var s: State = .{};
    _ = s.modifiers(0, super, 0, true);
    _ = s.modifiers(super, 0, 300, true);
    _ = s.modifiers(0, super, 1000, true);
    // The timers of the first press.
    try testing.expect(!s.prepare_due(1500, 2000));
    try testing.expect(!s.show_due(2000, 2000));
    // The timers of the second press.
    try testing.expect(s.prepare_due(2500, 2000));
    try testing.expect(s.show_due(3000, 2000));
}

test "a delay shorter than the lead prepares at once" {
    var s: State = .{};
    _ = s.modifiers(0, super, 1000, true);
    try testing.expect(s.prepare_due(1000, 100));
}
