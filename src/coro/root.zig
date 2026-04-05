const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const constants = @import("constants.zig");
const types = @import("types.zig");
const cancel = @import("cancel.zig");
const stack_mod = @import("stack.zig");
const page_buffer = @import("page_buffer.zig");

const ALT_STACK_SIZE = linux.SIGSTKSZ;

pub const Options = struct {
    stack_size: usize = constants.DEFAULT_STACK_SIZE,
    reserve_size: usize = constants.DEFAULT_STACK_RESERVE,
    grow_size: usize = constants.DEFAULT_STACK_GROW_SIZE,
};

pub const YieldValue = types.YieldValue;
pub const WatchPipes = types.WatchPipes;
pub const PipeData = types.PipeData;
pub const State = types.State;

pub const CancelError = cancel.CancelError;
pub const CancelToken = cancel.CancelToken;
pub const Scope = cancel.Scope;
pub const Group = cancel.Group;

const Context = types.Context;
const Stack = stack_mod.Stack;
const PageBuffer = page_buffer.PageBuffer;

pub const Coro = struct {
    pool: *Pool,
    ctx: Context = .{},
    caller_ctx: Context = .{},
    state: State = .idle,
    yield_val: YieldValue = .none,
    resume_val: YieldValue = .none,
    cancel_token: ?*CancelToken = null,
    user_data: ?*anyopaque = null,
    index: usize = 0,
    stdout_buf: PageBuffer = .{},
    stderr_buf: PageBuffer = .{},

    pub fn yield(self: *Coro) YieldValue {
        const prev = tls_current_coro;
        self.yield_val = .none;
        self.state = .suspended;
        tls_current_coro = null;
        defer tls_current_coro = prev;
        switchContext(&self.ctx, &self.caller_ctx);
        return self.resume_val;
    }

    pub fn yieldWith(self: *Coro, val: YieldValue) YieldValue {
        const prev = tls_current_coro;
        self.yield_val = val;
        self.state = .suspended;
        tls_current_coro = null;
        defer tls_current_coro = prev;
        switchContext(&self.ctx, &self.caller_ctx);
        return self.resume_val;
    }

    pub fn start(self: *Coro, func: *const fn (*Coro) void) void {
        const stack = self.pool.stackFor(self);
        const stack_top = @intFromPtr(stack.ptr) + stack.len;
        const aligned_top = stack_top & ~@as(usize, 0xF);
        const sp = aligned_top - 16;
        const stack_bytes: [*]u8 = @ptrFromInt(sp);

        @as(*align(1) u64, @ptrCast(stack_bytes)).* = @intFromPtr(&coroTrampoline);
        @as(*align(1) u64, @ptrCast(stack_bytes + 8)).* = 0;

        self.ctx = .{
            .rsp = sp,
            .rbx = 0,
            .rbp = 0,
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,
        };
        trampoline_coro = self;
        trampoline_func = func;
        self.state = .running;
        const prev = tls_current_coro;
        tls_current_coro = self;
        defer tls_current_coro = prev;
        switchContext(&self.caller_ctx, &self.ctx);
    }

    pub fn cont(self: *Coro) void {
        self.resume_val = .none;
        self.state = .running;
        const prev = tls_current_coro;
        tls_current_coro = self;
        defer tls_current_coro = prev;
        switchContext(&self.caller_ctx, &self.ctx);
    }

    pub fn contWith(self: *Coro, val: YieldValue) void {
        self.resume_val = val;
        self.state = .running;
        const prev = tls_current_coro;
        tls_current_coro = self;
        defer tls_current_coro = prev;
        switchContext(&self.caller_ctx, &self.ctx);
    }

    pub fn current() *Coro {
        return tls_current_coro orelse unreachable;
    }

    pub fn setCancelToken(self: *Coro, token: ?*CancelToken) void {
        self.cancel_token = token;
    }

    pub fn getCancelToken(self: *const Coro) ?*CancelToken {
        return self.cancel_token;
    }

    pub fn checkpoint(self: *Coro) CancelError!void {
        if (self.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }
    }

    pub fn yieldCancellable(self: *Coro) CancelError!YieldValue {
        const val = self.yield();
        try self.checkpoint();
        return val;
    }

    pub fn yieldWithCancellable(self: *Coro, val: YieldValue) CancelError!YieldValue {
        const out = self.yieldWith(val);
        try self.checkpoint();
        return out;
    }

    fn reset(self: *Coro) void {
        self.state = .idle;
        self.yield_val = .none;
        self.resume_val = .none;
        self.cancel_token = null;
        self.ctx = .{};
        self.caller_ctx = .{};
    }
};

const CoroNode = struct {
    all_next: ?*CoroNode = null,
    idle_next: ?*CoroNode = null,
    stack: Stack,
    coro: Coro,
};

pub const Pool = struct {
    options: Options = .{},
    all: ?*CoroNode = null,
    idle: ?*CoroNode = null,
    next_index: usize = 0,

    pub fn init(options: Options) Pool {
        return .{ .options = options };
    }

    pub fn acquire(self: *Pool) ?*Coro {
        ensureSegvHandlerInstalled() catch return null;

        if (self.idle) |node| {
            self.idle = node.idle_next;
            node.idle_next = null;
            node.coro.reset();
            node.coro.state = .running;
            return &node.coro;
        }

        const node = allocateNode() catch return null;

        node.stack = Stack.init(.{
            .stack_size = self.options.stack_size,
            .reserve_size = self.options.reserve_size,
            .grow_size = self.options.grow_size,
        }) catch {
            freeNode(node);
            return null;
        };

        node.coro = .{
            .pool = self,
            .index = self.next_index,
        };
        self.next_index += 1;

        node.all_next = self.all;
        self.all = node;

        node.coro.state = .running;
        return &node.coro;
    }

    pub fn release(self: *Pool, co: *Coro) void {
        co.reset();
        const node = nodeFromCoro(co);
        node.idle_next = self.idle;
        self.idle = node;
    }

    pub fn stackFor(self: *Pool, co: *Coro) []u8 {
        _ = self;
        return nodeFromCoro(co).stack.slice();
    }

    pub fn lookup(self: *Pool, index: usize) ?*Coro {
        var node = self.all;
        while (node) |n| : (node = n.all_next) {
            if (n.coro.index == index) return &n.coro;
        }
        return null;
    }

    pub fn resetAll(self: *Pool) void {
        var node = self.all;
        self.idle = null;
        while (node) |n| : (node = n.all_next) {
            n.coro.reset();
            n.idle_next = self.idle;
            self.idle = n;
        }
    }

    pub fn deinit(self: *Pool) void {
        var node = self.all;
        while (node) |n| {
            const next = n.all_next;
            n.coro.stdout_buf.deinit();
            n.coro.stderr_buf.deinit();
            n.stack.deinit();
            freeNode(n);
            node = next;
        }
        self.* = .{ .options = self.options };
    }
};

threadlocal var tls_current_coro: ?*Coro = null;

threadlocal var segv_handler_installed = false;
threadlocal var signal_stack: [ALT_STACK_SIZE]u8 align(16) = undefined;

fn coroTrampoline() void {
    const self = trampoline_coro orelse unreachable;
    const func = trampoline_func orelse unreachable;

    tls_current_coro = self;
    func(self);

    self.yield_val = .completed;
    self.state = .idle;
    const prev = tls_current_coro;
    tls_current_coro = null;
    defer tls_current_coro = prev;
    switchContext(&self.ctx, &self.caller_ctx);

    unreachable;
}

fn ensureSegvHandlerInstalled() !void {
    if (segv_handler_installed) return;

    var ss = linux.stack_t{
        .sp = &signal_stack,
        .flags = 0,
        .size = signal_stack.len,
    };
    try posix.sigaltstack(&ss, null);

    const act = linux.Sigaction{
        .handler = .{ .sigaction = segvHandler },
        .mask = posix.sigemptyset(),
        .flags = linux.SA.SIGINFO | linux.SA.ONSTACK | linux.SA.NODEFER,
    };
    posix.sigaction(linux.SIG.SEGV, &act, null);
    segv_handler_installed = true;
}

fn segvHandler(sig: i32, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    _ = sig;

    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    if (tls_current_coro) |co| {
        const stack = &nodeFromCoro(co).stack;
        if (stack.growForFault(.{
            .stack_size = co.pool.options.stack_size,
            .reserve_size = co.pool.options.reserve_size,
            .grow_size = co.pool.options.grow_size,
        }, fault_addr)) return;
    }

    const msg = "zig-fiber: unrecoverable SIGSEGV\n";
    _ = linux.write(2, msg, msg.len);
    linux.exit_group(127);
}

fn allocateNode() !*CoroNode {
    const mem = try posix.mmap(
        null,
        @sizeOf(CoroNode),
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    const ptr: *CoroNode = @ptrCast(mem.ptr);
    ptr.* = undefined;
    return ptr;
}

fn freeNode(node: *CoroNode) void {
    const mem: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(node)))[0..@sizeOf(CoroNode)];
    posix.munmap(mem);
}

fn nodeFromCoro(co: *Coro) *CoroNode {
    return @fieldParentPtr("coro", co);
}

threadlocal var trampoline_coro: ?*Coro = null;
threadlocal var trampoline_func: ?*const fn (*Coro) void = null;

extern fn switchContext(from: *Context, to: *const Context) void;

test "pool acquires and releases coroutines" {
    var pool = Pool.init(.{});
    defer pool.deinit();

    const co = pool.acquire() orelse return error.TestUnexpectedResult;
    try std.testing.expect(co.state == .running);
    pool.release(co);
    try std.testing.expect(co.state == .idle);
}

test "child scope inherits cancellation" {
    var parent = Scope.init();
    var child = parent.child();

    try std.testing.expect(!child.isCancelled());
    parent.cancel();
    try std.testing.expect(child.isCancelled());
}

test "group tickets track active work" {
    var group = Group.init();
    var t1 = group.begin();
    var t2 = group.begin();

    try std.testing.expect(!group.isIdle());
    t1.done();
    try std.testing.expect(!group.isIdle());
    t2.done();
    try std.testing.expect(group.isIdle());
}
