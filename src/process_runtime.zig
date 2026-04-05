const std = @import("std");
const coro = @import("coro.zig");

const linux = std.os.linux;

pub const RuntimeError = error{
    MissingCoroutine,
    UnexpectedYield,
};

pub const YieldAction = enum {
    pending,
    completed,
};

pub const Completion = struct {
    user_data: u64,
    res: i32,
};

pub const PIPE_READ_BUF_SIZE = 4096;

pub const PipeState = struct {
    stdout_fd: i32 = -1,
    stderr_fd: i32 = -1,
    child_pid: i32 = -1,
    stdout_eof: bool = false,
    stderr_eof: bool = false,
    stdout_pending: bool = false,
    stderr_pending: bool = false,
    child_exited: bool = false,
    exit_status: i32 = -1,
    active: bool = false,
    timed_out: bool = false,
    terminate_requested: bool = false,
    timeout_sec: u32 = 0,

    pub fn reset(self: *PipeState) void {
        if (self.stdout_fd >= 0) _ = linux.close(self.stdout_fd);
        if (self.stderr_fd >= 0) _ = linux.close(self.stderr_fd);
        self.* = .{};
    }

    pub fn closePipes(self: *PipeState) void {
        if (self.stdout_fd >= 0) {
            _ = linux.close(self.stdout_fd);
            self.stdout_fd = -1;
        }
        if (self.stderr_fd >= 0) {
            _ = linux.close(self.stderr_fd);
            self.stderr_fd = -1;
        }
    }

    pub fn allDone(self: *const PipeState) bool {
        return self.stdout_eof and self.stderr_eof and self.child_exited;
    }
};

pub const RuntimeState = struct {
    coro_ref: ?*coro.Coro = null,
    pipe_state: PipeState = .{},
    pipe_stdout_buf: [PIPE_READ_BUF_SIZE]u8 = undefined,
    pipe_stderr_buf: [PIPE_READ_BUF_SIZE]u8 = undefined,
    timeout_spec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    reap_retry_spec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    pub fn reset(self: *RuntimeState) void {
        self.coro_ref = null;
        self.pipe_state = .{};
        self.timeout_spec = .{ .sec = 0, .nsec = 0 };
        self.reap_retry_spec = .{ .sec = 0, .nsec = 0 };
    }
};

pub const IoUringDriver = struct {
    ring: *linux.IoUring,
    timeout_remove_user_data: u64,

    pub fn init(ring: *linux.IoUring, timeout_remove_user_data: u64) IoUringDriver {
        return .{ .ring = ring, .timeout_remove_user_data = timeout_remove_user_data };
    }

    pub fn submitPipeRead(self: *IoUringDriver, user_data: u64, fd: i32, buffer: []u8, coro_index: usize, stream_name: []const u8) bool {
        return submitPipeReadWithRetry(self.ring, user_data, fd, buffer, coro_index, stream_name);
    }

    pub fn submitTimeout(self: *IoUringDriver, user_data: u64, spec: *linux.kernel_timespec, coro_index: usize, pipe_type: u64) bool {
        _ = self.ring.timeout(user_data, spec, 0, 0) catch |err| {
            std.log.err("failed to submit timeout: coro_id={d} pipe_type={d} err={s}", .{ coro_index, pipe_type, @errorName(err) });
            return false;
        };
        return true;
    }

    pub fn cancelTimeout(self: *IoUringDriver, user_data: u64) void {
        _ = self.ring.timeout_remove(self.timeout_remove_user_data, user_data, 0) catch {};
    }
};

pub const Runtime = struct {
    state: RuntimeState = .{},

    pub fn reset(self: *Runtime) void {
        self.state.reset();
    }

    pub fn bind(self: *Runtime, co: *coro.Coro) void {
        self.state.coro_ref = co;
    }

    pub fn handleYield(self: *Runtime, driver: anytype, co: *coro.Coro) RuntimeError!YieldAction {
        self.bind(co);

        return switch (co.yield_val) {
            .watch_pipes => |pipes| blk: {
                beginWatch(driver, &self.state, pipes, co.index);
                break :blk .pending;
            },
            .completed => .completed,
            else => error.UnexpectedYield,
        };
    }

    pub fn owns(self: *const Runtime, user_data: u64) bool {
        return isUserData(user_data) and decodeState(user_data) == &self.state;
    }

    pub fn handleCqe(self: *Runtime, driver: anytype, completion: Completion, callback_ctx: anytype, comptime on_yield: anytype) void {
        if (!self.owns(completion.user_data)) return;
        handleCompletion(driver, completion.user_data, completion.res, callback_ctx, on_yield);
    }
};

pub const USER_DATA_FLAG: u64 = 1 << 63;
pub const TYPE_STDOUT: u64 = 0;
pub const TYPE_STDERR: u64 = 1;
pub const TYPE_WAITID: u64 = 2;
pub const TYPE_TIMEOUT: u64 = 3;

pub fn encodeUserData(runtime: *RuntimeState, pipe_type: u64) u64 {
    return (@intFromPtr(runtime) & ~@as(u64, 0x7)) | (pipe_type & 0x7) | USER_DATA_FLAG;
}

pub fn isUserData(user_data: u64) bool {
    return (user_data & USER_DATA_FLAG) != 0;
}

pub fn decodeState(user_data: u64) *RuntimeState {
    return @ptrFromInt(user_data & ~(USER_DATA_FLAG | @as(u64, 0x7)));
}

pub fn decodeType(user_data: u64) u64 {
    return user_data & 0x7;
}

pub fn beginWatch(driver: anytype, runtime: *RuntimeState, pipes: coro.WatchPipes, coro_index: usize) void {
    std.debug.assert(runtime.coro_ref != null);
    runtime.pipe_state = .{
        .stdout_fd = pipes.stdout_fd,
        .stderr_fd = pipes.stderr_fd,
        .child_pid = pipes.child_pid,
        .active = true,
        .timeout_sec = pipes.timeout_sec,
    };
    submitPipeReads(driver, runtime, coro_index);
    tryReapChild(runtime);
    if (runtime.pipe_state.stdout_eof and runtime.pipe_state.stderr_eof and !runtime.pipe_state.child_exited) {
        scheduleReapRetry(driver, runtime, coro_index);
    }
    if (pipes.timeout_sec > 0 and !submitTimeout(driver, runtime, coro_index, pipes.timeout_sec)) {
        runtime.pipe_state.timeout_sec = 0;
    }
}

pub fn submitPipeReads(driver: anytype, runtime: *RuntimeState, coro_index: usize) void {
    const ps = &runtime.pipe_state;

    if (ps.stdout_fd >= 0 and !ps.stdout_eof and !ps.stdout_pending) {
        if (driver.submitPipeRead(encodeUserData(runtime, TYPE_STDOUT), ps.stdout_fd, runtime.pipe_stdout_buf[0..], coro_index, "stdout")) {
            ps.stdout_pending = true;
        } else {
            ps.stdout_eof = true;
            ps.stdout_pending = false;
        }
    }

    if (ps.stderr_fd >= 0 and !ps.stderr_eof and !ps.stderr_pending) {
        if (driver.submitPipeRead(encodeUserData(runtime, TYPE_STDERR), ps.stderr_fd, runtime.pipe_stderr_buf[0..], coro_index, "stderr")) {
            ps.stderr_pending = true;
        } else {
            ps.stderr_eof = true;
            ps.stderr_pending = false;
        }
    }
}

pub fn submitTimeout(driver: anytype, runtime: *RuntimeState, coro_index: usize, timeout_sec: u32) bool {
    runtime.timeout_spec = .{ .sec = @intCast(timeout_sec), .nsec = 0 };
    if (!driver.submitTimeout(encodeUserData(runtime, TYPE_TIMEOUT), &runtime.timeout_spec, coro_index, TYPE_TIMEOUT)) {
        runtime.timeout_spec = .{ .sec = 0, .nsec = 0 };
        return false;
    }
    return true;
}

pub fn cancelTimeout(driver: anytype, runtime: *RuntimeState) void {
    driver.cancelTimeout(encodeUserData(runtime, TYPE_TIMEOUT));
}

pub fn handleCompletion(driver: anytype, user_data: u64, cqe_res: i32, callback_ctx: anytype, comptime on_yield: anytype) void {
    const runtime = decodeState(user_data);
    const pipe_type = decodeType(user_data);

    if (pipe_type == TYPE_TIMEOUT) {
        handleTimeoutCompletion(driver, runtime, cqe_res, callback_ctx, on_yield);
        return;
    }

    if (pipe_type == TYPE_WAITID) {
        const co = runtime.coro_ref orelse return;
        tryReapChild(runtime);
        if (!runtime.pipe_state.child_exited and runtime.pipe_state.active) scheduleReapRetry(driver, runtime, co.index);
        if (runtime.pipe_state.allDone()) {
            const exit_status = runtime.pipe_state.exit_status;
            if (runtime.pipe_state.timeout_sec > 0) cancelTimeout(driver, runtime);
            runtime.pipe_state.reset();
            co.contWith(.{ .child_exited = exit_status });
            on_yield(callback_ctx, co, runtime);
        }
        return;
    }

    const ps = &runtime.pipe_state;
    if (!ps.active or ps.timed_out) return;

    const co = runtime.coro_ref orelse return;
    const ci = co.index;

    if (pipe_type == TYPE_STDOUT) {
        ps.stdout_pending = false;
        if (cqe_res <= 0) {
            ps.stdout_eof = true;
            co.contWith(.{ .pipe_data = .{ .fd = ps.stdout_fd, .buf = undefined, .len = 0, .eof = true } });
        } else {
            const n: usize = @intCast(cqe_res);
            co.contWith(.{ .pipe_data = .{ .fd = ps.stdout_fd, .buf = &runtime.pipe_stdout_buf, .len = n, .eof = false } });
        }
    } else if (pipe_type == TYPE_STDERR) {
        ps.stderr_pending = false;
        if (cqe_res <= 0) {
            ps.stderr_eof = true;
            co.contWith(.{ .pipe_data = .{ .fd = ps.stderr_fd, .buf = undefined, .len = 0, .eof = true } });
        } else {
            const n: usize = @intCast(cqe_res);
            co.contWith(.{ .pipe_data = .{ .fd = ps.stderr_fd, .buf = &runtime.pipe_stderr_buf, .len = n, .eof = false } });
        }
    }

    if (co.yield_val == .completed) {
        if (ps.timeout_sec > 0) cancelTimeout(driver, runtime);
        ps.reset();
        on_yield(callback_ctx, co, runtime);
        return;
    }

    tryReapChild(runtime);
    if (ps.stdout_eof and ps.stderr_eof and !ps.child_exited) scheduleReapRetry(driver, runtime, ci);

    if (ps.allDone()) {
        const exit_status = ps.exit_status;
        if (ps.timeout_sec > 0) cancelTimeout(driver, runtime);
        ps.reset();
        co.contWith(.{ .child_exited = exit_status });
        on_yield(callback_ctx, co, runtime);
    } else {
        submitPipeReads(driver, runtime, ci);
    }
}

pub fn tryReapChild(runtime: *RuntimeState) void {
    const ps = &runtime.pipe_state;
    if (ps.child_pid <= 0 or ps.child_exited) return;

    var status: u32 = 0;
    const ret: isize = @bitCast(linux.waitpid(ps.child_pid, &status, linux.W.NOHANG));
    if (ret == ps.child_pid) {
        ps.child_exited = true;
        ps.exit_status = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else -1;
    }
}

pub fn scheduleReapRetry(driver: anytype, runtime: *RuntimeState, coro_index: usize) void {
    const ps = &runtime.pipe_state;
    if (ps.child_pid <= 0 or ps.child_exited) return;

    runtime.reap_retry_spec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = driver.submitTimeout(encodeUserData(runtime, TYPE_WAITID), &runtime.reap_retry_spec, coro_index, TYPE_WAITID);
}

pub fn requestTermination(driver: anytype, runtime: *RuntimeState, coro_index: usize) void {
    const ps = &runtime.pipe_state;
    if (!ps.active or ps.child_pid <= 0 or ps.child_exited or ps.terminate_requested) return;

    ps.terminate_requested = true;
    _ = linux.kill(ps.child_pid, linux.SIG.TERM);
    tryReapChild(runtime);
    if (!ps.child_exited) scheduleReapRetry(driver, runtime, coro_index);
}

fn handleTimeoutCompletion(driver: anytype, runtime: *RuntimeState, cqe_res: i32, callback_ctx: anytype, comptime on_yield: anytype) void {
    const ps = &runtime.pipe_state;
    if (!ps.active) return;

    const ETIME: i32 = -@as(i32, @intCast(@intFromEnum(linux.E.TIME)));
    const ECANCELED: i32 = -@as(i32, @intCast(@intFromEnum(linux.E.CANCELED)));
    if (cqe_res == ECANCELED) return;
    if (cqe_res != ETIME and cqe_res != 0) return;

    if (ps.child_pid > 0 and !ps.child_exited) {
        const co = runtime.coro_ref orelse return;
        _ = linux.kill(ps.child_pid, 9);
        ps.timed_out = true;

        tryReapChild(runtime);
        if (!ps.child_exited) {
            scheduleReapRetry(driver, runtime, co.index);
            return;
        }

        ps.closePipes();
        ps.stdout_eof = true;
        ps.stderr_eof = true;

        if (ps.allDone()) {
            if (ps.timeout_sec > 0) cancelTimeout(driver, runtime);
            ps.reset();
            co.contWith(.child_timed_out);
            on_yield(callback_ctx, co, runtime);
        }
    }
}

fn handlePipeReadSubmitError(coro_index: usize, stream_name: []const u8, err: anyerror) void {
    std.log.err("failed to submit {s} pipe read: coro_id={d} err={s}", .{ stream_name, coro_index, @errorName(err) });
}

fn submitPipeReadWithRetry(ring: *linux.IoUring, user_data: u64, fd: i32, buffer: []u8, coro_index: usize, stream_name: []const u8) bool {
    _ = ring.read(user_data, @intCast(fd), .{ .buffer = buffer }, 0) catch |err| {
        handlePipeReadSubmitError(coro_index, stream_name, err);
        _ = ring.submit() catch |submit_err| {
            std.log.err("failed to flush io_uring before retrying {s} pipe read: coro_id={d} err={s}", .{ stream_name, coro_index, @errorName(submit_err) });
            return false;
        };

        _ = ring.read(user_data, @intCast(fd), .{ .buffer = buffer }, 0) catch |retry_err| {
            handlePipeReadSubmitError(coro_index, stream_name, retry_err);
            return false;
        };

        return true;
    };

    return true;
}

test "runtime handleYield schedules pipe reads and timeout" {
    const FakeDriver = struct {
        stdout_user_data: u64 = 0,
        stderr_user_data: u64 = 0,
        timeout_user_data: u64 = 0,
        timeout_pipe_type: u64 = 0,
        read_count: usize = 0,
        timeout_count: usize = 0,

        fn submitPipeRead(self: *@This(), user_data: u64, fd: i32, _: []u8, _: usize, _: []const u8) bool {
            if (self.read_count == 0) {
                std.debug.assert(fd == 11);
                self.stdout_user_data = user_data;
            } else {
                std.debug.assert(fd == 12);
                self.stderr_user_data = user_data;
            }
            self.read_count += 1;
            return true;
        }

        fn submitTimeout(self: *@This(), user_data: u64, _: *linux.kernel_timespec, _: usize, pipe_type: u64) bool {
            self.timeout_user_data = user_data;
            self.timeout_pipe_type = pipe_type;
            self.timeout_count += 1;
            return true;
        }

        fn cancelTimeout(_: *@This(), _: u64) void {}
    };

    var runtime = Runtime{};
    var driver = FakeDriver{};
    var co: coro.Coro = undefined;
    co.index = 9;
    co.yield_val = .{ .watch_pipes = .{
        .stdout_fd = 11,
        .stderr_fd = 12,
        .child_pid = 13,
        .timeout_sec = 5,
    } };

    const action = try runtime.handleYield(&driver, &co);
    try std.testing.expectEqual(YieldAction.pending, action);
    try std.testing.expectEqual(@as(usize, 2), driver.read_count);
    try std.testing.expectEqual(@as(usize, 1), driver.timeout_count);
    try std.testing.expect(runtime.state.coro_ref == &co);
    try std.testing.expectEqual(@as(i32, 13), runtime.state.pipe_state.child_pid);
    try std.testing.expect(runtime.owns(driver.stdout_user_data));
    try std.testing.expect(runtime.owns(driver.stderr_user_data));
    try std.testing.expect(runtime.owns(driver.timeout_user_data));
    try std.testing.expectEqual(TYPE_TIMEOUT, driver.timeout_pipe_type);
}

test "runtime handleYield reports completed coroutine" {
    var runtime = Runtime{};

    var co: coro.Coro = undefined;
    co.yield_val = .completed;

    const FakeDriver = struct {
        fn submitPipeRead(_: *@This(), _: u64, _: i32, _: []u8, _: usize, _: []const u8) bool {
            unreachable;
        }
        fn submitTimeout(_: *@This(), _: u64, _: *linux.kernel_timespec, _: usize, _: u64) bool {
            unreachable;
        }
        fn cancelTimeout(_: *@This(), _: u64) void {
            unreachable;
        }
    };

    var fake_driver = FakeDriver{};
    const action = try runtime.handleYield(&fake_driver, &co);
    try std.testing.expectEqual(YieldAction.completed, action);
}

test "runtime completion ignores unrelated user data" {
    const FakeDriver = struct {
        fn submitPipeRead(_: *@This(), _: u64, _: i32, _: []u8, _: usize, _: []const u8) bool {
            unreachable;
        }
        fn submitTimeout(_: *@This(), _: u64, _: *linux.kernel_timespec, _: usize, _: u64) bool {
            unreachable;
        }
        fn cancelTimeout(_: *@This(), _: u64) void {
            unreachable;
        }
    };

    const Callback = struct {
        fn onYield(hit: *bool, _: *coro.Coro, _: *RuntimeState) void {
            hit.* = true;
        }
    };

    var runtime = Runtime{};
    var fake_driver = FakeDriver{};
    var hit = false;

    runtime.handleCqe(&fake_driver, .{ .user_data = USER_DATA_FLAG | 0x5, .res = 0 }, &hit, Callback.onYield);
    try std.testing.expect(!hit);
}
