# zig-fiber

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.2-orange.svg)](https://ziglang.org/download/)

`zig-fiber` is a small stackful coroutine library for Zig focused on `x86_64-linux`.

The project currently consists of a few low-level pieces:
- A coroutine pool with manual context switching.
- Growable coroutine stacks implemented with guarded virtual-memory reservations.
- Cancellation primitives built around tokens, scopes, and groups.
- A Linux subprocess helper that captures stdout/stderr and cooperates with the coroutine runtime.
- A generic process runtime helper for driving command yields from an external event loop.

It is intentionally small and low-level. This is infrastructure code rather than a full async runtime.

## Features

- Stackful coroutines implemented with explicit context switching.
- Growable stacks backed by `mmap` and extended from a SIGSEGV handler.
- Cancellation support via `CancelToken`, `Scope`, and `Group`.
- A reusable `Pool` for acquiring and releasing coroutine instances.
- Linux command execution with stdout/stderr capture, timeouts, and cancellation hooks.
- Generic process scheduling helpers for io_uring-driven runtimes.
- Minimal dependency surface: just Zig and the OS.

## Ecosystem

`leap0` uses `zig-fiber` internally.

## Platform Support

This project currently supports `x86_64-linux` only.

That restriction is enforced in `build.zig` because the implementation depends on:
- Linux signal stack handling.
- Linux process and pipe syscalls.
- An `x86_64` assembly context switch routine.

## Installation

Add `zig-fiber` as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/stevenpassynkov/zig-fiber"
```

Then import the module in `build.zig`:

```zig
const zig_fiber_dep = b.dependency("zig_fiber", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zig-fiber", zig_fiber_dep.module("zig-fiber"));
```

## Usage

Public API is exported from `src/root.zig`:

```zig
const fiber = @import("zig-fiber");

pub const Options = fiber.Options;
pub const Pool = fiber.Pool;
pub const Coro = fiber.Coro;
pub const CancelToken = fiber.CancelToken;
pub const Scope = fiber.Scope;
pub const Group = fiber.Group;
pub const Command = fiber.Command;
pub const process = fiber.process;
```

Minimal fiber example:

```zig
const std = @import("std");
const fiber = @import("zig-fiber");

const Job = struct {
    value: usize = 0,

    fn run(co: *fiber.Coro) void {
        const job: *Job = @ptrCast(@alignCast(co.user_data.?));
        job.value = 41;
        _ = co.yield();
        job.value += 1;
    }
};

pub fn main() !void {
    var pool = fiber.Pool.init(.{});
    defer pool.deinit();

    var job = Job{};

    const co = pool.acquire() orelse return error.OutOfMemory;
    defer pool.release(co);

    co.user_data = &job;

    co.start(Job.run);
    std.debug.assert(job.value == 41);

    co.cont();
    std.debug.assert(job.value == 42);
}
```

This example shows the core model directly: `start` enters the fiber, `yield` suspends back to the caller, and `cont` resumes it.

The command API is built on top of the same coroutine machinery and exposes:
- Shell or argv-based command construction.
- Optional cwd and environment overrides.
- Optional timeout.
- Optional cancellation via `CancelToken` or `Scope`.
- Captured `stdout`, `stderr`, exit code, and timeout status.

The library also exports `fiber.process`, a generic Linux process runtime helper that can:
- Track stdout/stderr pipe reads.
- Track child process exit.
- Schedule timeout and reap-retry events.
- Resume the coroutine with `.pipe_data`, `.child_exited`, and `.child_timed_out`.

Command example with `fiber.process`:

```zig
const std = @import("std");
const fiber = @import("zig-fiber");

fn onProcessYield(_: void, co: *fiber.Coro, _: *fiber.process.RuntimeState) void {
    if (co.yield_val == .completed) {
        std.debug.print("command coroutine completed\n", .{});
    }
}

const Job = struct {
    output: ?fiber.Output = null,
    err: ?anyerror = null,
    runtime: fiber.process.RuntimeState = .{},

    fn run(co: *fiber.Coro) void {
        const job: *Job = @ptrCast(@alignCast(co.user_data.?));
        job.runtime.coro_ref = co;

        var cmd = fiber.Command.shell("echo hello from zig-fiber");
        job.output = cmd.run() catch |err| {
            job.err = err;
            return;
        };
    }
};

pub fn main() !void {
    var pool = fiber.Pool.init(.{});
    defer pool.deinit();

    var ring = try std.os.linux.IoUring.init(8, 0);
    defer ring.deinit();

    var job = Job{};
    const co = pool.acquire() orelse return error.OutOfMemory;
    defer pool.release(co);

    co.user_data = &job;
    co.start(Job.run);

    switch (co.yield_val) {
        .watch_pipes => |pipes| {
            fiber.process.beginWatch(&ring, &job.runtime, pipes, co.index);

            var cqes: [8]std.os.linux.io_uring_cqe = undefined;
            while (co.yield_val != .completed) {
                const count = try ring.copy_cqes(&cqes, 1);
                for (cqes[0..count]) |cqe| {
                    if (!fiber.process.isUserData(cqe.user_data)) continue;
                    fiber.process.handleCompletion(&ring, 0, cqe.user_data, cqe.res, {}, onProcessYield);
                }
                _ = try ring.submit();
            }

            if (job.err) |err| return err;
            const out = job.output orelse return error.MissingOutput;
            std.debug.assert(out.exit_code == 0);
            std.debug.assert(std.mem.eql(u8, out.stdout, "hello from zig-fiber\n"));
        },
        .completed => {},
        else => unreachable,
    }
}
```

`Command.run()` runs inside a `Coro` and yields process events back to the caller. `fiber.process` gives you the reusable Linux-side machinery for integrating command execution into your own event loop.

## Building

```bash
# Build the module
zig build

# Run tests on x86_64-linux
zig build test
```

On non-Linux hosts, the build intentionally fails with a clear message unless you cross-compile for `x86_64-linux`.

## Development Notes

The current repository is intentionally compact. Most of the implementation lives in:
- `src/coro/root.zig`
- `src/coro/stack.zig`
- `src/command.zig`
- `src/process_runtime.zig`

## License

This project is licensed under the [Apache License 2.0](LICENSE).
