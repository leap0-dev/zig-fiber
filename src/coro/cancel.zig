const std = @import("std");

pub const CancelError = error{Cancelled};

pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn reset(self: *CancelToken) void {
        self.cancelled.store(false, .release);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Scope = struct {
    token_state: CancelToken = .{},
    parent: ?*const Scope = null,

    pub fn init() Scope {
        return .{};
    }

    pub fn child(self: *const Scope) Scope {
        return .{ .parent = self };
    }

    pub fn token(self: *Scope) *CancelToken {
        return &self.token_state;
    }

    pub fn cancel(self: *Scope) void {
        self.token_state.cancel();
    }

    pub fn reset(self: *Scope) void {
        self.token_state.reset();
    }

    pub fn isCancelled(self: *const Scope) bool {
        if (self.token_state.isCancelled()) return true;
        if (self.parent) |parent| return parent.isCancelled();
        return false;
    }

    pub fn checkpoint(self: *const Scope) CancelError!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub const Group = struct {
    scope_state: Scope = .{},
    active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub const Ticket = struct {
        group: ?*Group,

        pub fn done(self: *Ticket) void {
            if (self.group) |group| {
                _ = group.active.fetchSub(1, .acq_rel);
                self.group = null;
            }
        }
    };

    pub fn init() Group {
        return .{};
    }

    pub fn scope(self: *Group) *Scope {
        return &self.scope_state;
    }

    pub fn token(self: *Group) *CancelToken {
        return self.scope().token();
    }

    pub fn cancel(self: *Group) void {
        self.scope_state.cancel();
    }

    pub fn begin(self: *Group) Ticket {
        _ = self.active.fetchAdd(1, .acq_rel);
        return .{ .group = self };
    }

    pub fn wait(self: *Group) void {
        while (self.active.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn isIdle(self: *const Group) bool {
        return self.active.load(.acquire) == 0;
    }
};
