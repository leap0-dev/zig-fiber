const std = @import("std");
const coro = @import("coro.zig");
const linux = std.os.linux;

pub const Output = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    timed_out: bool,
};

pub const MAX_ENV = 64;
pub const MAX_ARGV = 32;

pub const Command = struct {
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    cwd_path: ?[]const u8 = null,
    env_list: ?[]const []const u8 = null,
    timeout_secs: u32 = 0,
    cancel_token: ?*coro.CancelToken = null,

    pub fn shell(command: []const u8) Command {
        return .{ .command = command };
    }

    pub fn argv(args: []const []const u8) Command {
        return .{ .args = args };
    }

    pub fn cwd(self: *Command, path: []const u8) *Command {
        self.cwd_path = path;
        return self;
    }

    pub fn env(self: *Command, values: []const []const u8) *Command {
        self.env_list = values;
        return self;
    }

    pub fn timeout(self: *Command, seconds: u32) *Command {
        self.timeout_secs = seconds;
        return self;
    }

    pub fn cancelToken(self: *Command, token: *coro.CancelToken) *Command {
        self.cancel_token = token;
        return self;
    }

    pub fn scope(self: *Command, value: *coro.Scope) *Command {
        self.cancel_token = value.token();
        return self;
    }

    pub fn run(self: Command) !Output {
        if (self.command == null and self.args == null) return error.InvalidCommand;
        if (self.args) |args| {
            if (args.len == 0) return error.InvalidCommand;
        }

        if (self.cancel_token) |token| {
            if (token.isCancelled()) return error.Cancelled;
        }

        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;
        if (self.command) |command| {
            if (command.len > cmd_buf.len - 1) return error.CommandTooLong;
            cmd_len = command.len;
            @memcpy(cmd_buf[0..cmd_len], command[0..cmd_len]);
            cmd_buf[cmd_len] = 0;
        }

        var argv_bufs: [MAX_ARGV][512]u8 = undefined;
        var argv_ptrs: [MAX_ARGV + 1]?[*:0]const u8 = undefined;
        var argv_count: usize = 0;
        if (self.args) |args| {
            if (args.len > MAX_ARGV) return error.TooManyArguments;
            for (args, 0..) |arg, i| {
                if (arg.len > argv_bufs[i].len - 1) return error.ArgumentTooLong;
                const len = arg.len;
                @memcpy(argv_bufs[i][0..len], arg[0..len]);
                argv_bufs[i][len] = 0;
                argv_ptrs[i] = @ptrCast(&argv_bufs[i]);
                argv_count += 1;
            }
            argv_ptrs[argv_count] = null;
        }

        var env_bufs: [MAX_ENV][512]u8 = undefined;
        var env_ptrs: [MAX_ENV + 1]?[*:0]const u8 = undefined;
        var env_count: usize = 0;
        if (self.env_list) |env_values| {
            if (env_values.len > MAX_ENV) return error.TooManyEnvironmentVariables;
            for (env_values, 0..) |entry, i| {
                if (entry.len > env_bufs[i].len - 1) return error.EnvironmentVariableTooLong;
                const len = entry.len;
                @memcpy(env_bufs[i][0..len], entry[0..len]);
                env_bufs[i][len] = 0;
                env_ptrs[i] = @ptrCast(&env_bufs[i]);
                env_count += 1;
            }
            env_ptrs[env_count] = null;
        }

        var cwd_buf: [512]u8 = undefined;
        var has_cwd = false;
        if (self.cwd_path) |d| {
            if (d.len > 0) {
                if (d.len > cwd_buf.len - 1) return error.CwdTooLong;
                const cwd_len = d.len;
                @memcpy(cwd_buf[0..cwd_len], d[0..cwd_len]);
                cwd_buf[cwd_len] = 0;
                has_cwd = true;
            }
        }

        const envp: [*:null]const ?[*:0]const u8 = if (env_count > 0)
            @ptrCast(&env_ptrs)
        else
            getDefaultEnvp();

        const stdout_pipe = createPipe() orelse return error.PipeCreationFailed;
        const stderr_pipe = createPipe() orelse {
            closeFd(stdout_pipe[0]);
            closeFd(stdout_pipe[1]);
            return error.PipeCreationFailed;
        };

        const pid: i32 = @intCast(@as(isize, @bitCast(linux.fork())));
        if (pid < 0) {
            closeFd(stdout_pipe[0]);
            closeFd(stdout_pipe[1]);
            closeFd(stderr_pipe[0]);
            closeFd(stderr_pipe[1]);
            return error.ForkFailed;
        }

        if (pid == 0) {
            closeFd(stdout_pipe[0]);
            closeFd(stderr_pipe[0]);

            const dup_stdout_rc = linux.dup2(stdout_pipe[1], 1);
            if (@as(isize, @bitCast(dup_stdout_rc)) < 0) {
                closeFd(stdout_pipe[1]);
                closeFd(stderr_pipe[1]);
                childExitErrno(dup_stdout_rc);
            }

            const dup_stderr_rc = linux.dup2(stderr_pipe[1], 2);
            if (@as(isize, @bitCast(dup_stderr_rc)) < 0) {
                closeFd(stdout_pipe[1]);
                closeFd(stderr_pipe[1]);
                closeFd(1);
                childExitErrno(dup_stderr_rc);
            }

            clearNonblockOrExit(1, stdout_pipe[1], stderr_pipe[1]);
            clearNonblockOrExit(2, stdout_pipe[1], stderr_pipe[1]);
            closeFd(stdout_pipe[1]);
            closeFd(stderr_pipe[1]);

            if (has_cwd) {
                const chdir_rc = linux.chdir(@ptrCast(&cwd_buf));
                if (@as(isize, @bitCast(chdir_rc)) < 0) {
                    childExitErrno(chdir_rc);
                }
            }

            if (self.args != null and argv_count > 0) {
                const execve_rc = linux.execve(argv_ptrs[0].?, @ptrCast(&argv_ptrs), envp);
                childExitErrno(execve_rc);
            } else {
                const shell_path: [*:0]const u8 = "/bin/sh";
                const shell_argv = [_]?[*:0]const u8{ shell_path, "-c", @ptrCast(&cmd_buf), null };
                const execve_rc = linux.execve(shell_path, @ptrCast(&shell_argv), envp);
                childExitErrno(execve_rc);
            }
        }

        closeFd(stdout_pipe[1]);
        closeFd(stderr_pipe[1]);

        var child_cleanup_needed = true;
        defer if (child_cleanup_needed) cancelRunningChild(pid, stdout_pipe[0], stderr_pipe[0]);

        const co = coro.Coro.current();
        const prev_token = co.getCancelToken();
        if (self.cancel_token != null) {
            co.setCancelToken(self.cancel_token);
        }
        defer co.setCancelToken(prev_token);

        _ = try co.yieldWithCancellable(.{ .watch_pipes = .{
            .stdout_fd = stdout_pipe[0],
            .stderr_fd = stderr_pipe[0],
            .child_pid = pid,
            .timeout_sec = self.timeout_secs,
        } });

        co.stdout_buf.reset();
        co.stderr_buf.reset();

        var exit_code: i32 = -1;
        var timed_out = false;
        var done = false;

        while (!done) {
            co.checkpoint() catch {
                return error.Cancelled;
            };

            switch (co.resume_val) {
                .pipe_data => |pd| {
                    if (pd.fd == stdout_pipe[0] and !pd.eof) {
                        try co.stdout_buf.append(pd.buf[0..pd.len]);
                    } else if (pd.fd == stderr_pipe[0] and !pd.eof) {
                        try co.stderr_buf.append(pd.buf[0..pd.len]);
                    }
                    _ = co.yieldCancellable() catch {
                        return error.Cancelled;
                    };
                },
                .child_exited => |code| {
                    exit_code = code;
                    done = true;
                },
                .child_timed_out => {
                    timed_out = true;
                    done = true;
                },
                .completed, .none, .watch_pipes => done = true,
            }
        }

        closeFd(stdout_pipe[0]);
        closeFd(stderr_pipe[0]);
        child_cleanup_needed = false;

        return .{
            .stdout = co.stdout_buf.bytes(),
            .stderr = co.stderr_buf.bytes(),
            .exit_code = exit_code,
            .timed_out = timed_out,
        };
    }
};

const builtin_envp = [_]?[*:0]const u8{
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/",
    "TERM=xterm-256color",
    null,
};

var env_once = std.once(initDefaultEnv);
var loaded_envp: [MAX_ENV + 1]?[*:0]const u8 = [_]?[*:0]const u8{null} ** (MAX_ENV + 1);
var loaded_env_storage: [MAX_ENV][512]u8 = undefined;
var loaded_env_count: usize = 0;

fn getDefaultEnvp() [*:null]const ?[*:0]const u8 {
    env_once.call();
    if (loaded_env_count > 0) {
        return @ptrCast(&loaded_envp);
    }
    return @ptrCast(&builtin_envp);
}

fn initDefaultEnv() void {
    loadEnvFile("/etc/environment");
    loaded_envp[loaded_env_count] = null;
}

fn unquoteEnvLine(line: []const u8, out: *[512]u8) usize {
    var eq: usize = 0;
    while (eq < line.len and line[eq] != '=') : (eq += 1) {}
    if (eq >= line.len) {
        const n = @min(line.len, out.len - 1);
        @memcpy(out[0..n], line[0..n]);
        return n;
    }

    const val_start = eq + 1;
    const val = line[val_start..];

    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        const prefix_len = val_start;
        if (prefix_len >= out.len) return 0;
        @memcpy(out[0..prefix_len], line[0..prefix_len]);

        const inner = val[1 .. val.len - 1];
        var dst: usize = prefix_len;
        var i: usize = 0;
        while (i < inner.len) {
            if (dst >= out.len - 1) break;
            if (i + 4 <= inner.len and
                inner[i] == '\'' and inner[i + 1] == '\\' and
                inner[i + 2] == '\'' and inner[i + 3] == '\'')
            {
                out[dst] = '\'';
                dst += 1;
                i += 4;
            } else {
                out[dst] = inner[i];
                dst += 1;
                i += 1;
            }
        }
        return dst;
    }

    const n = @min(line.len, out.len - 1);
    @memcpy(out[0..n], line[0..n]);
    return n;
}

fn loadEnvFile(path: [*:0]const u8) void {
    const fd_raw = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_raw)) < 0) return;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);

    var buf: [32768]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf[total..].ptr, buf.len - total);
        const n_isize: isize = @bitCast(n);
        if (n_isize <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    var has_path = false;
    var has_term = false;
    var has_home = false;

    var start: usize = 0;
    while (start < total and loaded_env_count < MAX_ENV) {
        var end = start;
        while (end < total and buf[end] != '\n') : (end += 1) {}
        const line = buf[start..end];
        start = end + 1;
        if (line.len == 0 or line[0] == '#') continue;

        const out_len = unquoteEnvLine(line, &loaded_env_storage[loaded_env_count]);
        if (out_len == 0) continue;
        loaded_env_storage[loaded_env_count][out_len] = 0;
        loaded_envp[loaded_env_count] = @ptrCast(&loaded_env_storage[loaded_env_count]);

        if (out_len >= 5 and std.mem.eql(u8, loaded_env_storage[loaded_env_count][0..5], "PATH=")) has_path = true;
        if (out_len >= 5 and std.mem.eql(u8, loaded_env_storage[loaded_env_count][0..5], "TERM=")) has_term = true;
        if (out_len >= 5 and std.mem.eql(u8, loaded_env_storage[loaded_env_count][0..5], "HOME=")) has_home = true;

        loaded_env_count += 1;
    }

    if (!has_path and loaded_env_count < MAX_ENV) {
        const path_val = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
        @memcpy(loaded_env_storage[loaded_env_count][0..path_val.len], path_val);
        loaded_env_storage[loaded_env_count][path_val.len] = 0;
        loaded_envp[loaded_env_count] = @ptrCast(&loaded_env_storage[loaded_env_count]);
        loaded_env_count += 1;
    }
    if (!has_term and loaded_env_count < MAX_ENV) {
        const term = "TERM=xterm-256color";
        @memcpy(loaded_env_storage[loaded_env_count][0..term.len], term);
        loaded_env_storage[loaded_env_count][term.len] = 0;
        loaded_envp[loaded_env_count] = @ptrCast(&loaded_env_storage[loaded_env_count]);
        loaded_env_count += 1;
    }
    if (!has_home and loaded_env_count < MAX_ENV) {
        const home = "HOME=/";
        @memcpy(loaded_env_storage[loaded_env_count][0..home.len], home);
        loaded_env_storage[loaded_env_count][home.len] = 0;
        loaded_envp[loaded_env_count] = @ptrCast(&loaded_env_storage[loaded_env_count]);
        loaded_env_count += 1;
    }
}

fn createPipe() ?[2]i32 {
    var fds: [2]i32 = undefined;
    const ret: isize = @bitCast(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }));
    if (ret == 0) return fds;
    return null;
}

fn clearNonblockOrExit(fd: i32, stdout_fd: i32, stderr_fd: i32) void {
    const nonblock_mask: i32 = @bitCast(linux.O{ .NONBLOCK = true });
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (@as(isize, @bitCast(flags_rc)) < 0) {
        closeFd(stdout_fd);
        closeFd(stderr_fd);
        closeFd(1);
        closeFd(2);
        childExitErrno(flags_rc);
    }

    const flags: i32 = @intCast(flags_rc);
    const set_flags_rc = linux.fcntl(fd, linux.F.SETFL, @intCast(flags & ~nonblock_mask));
    if (@as(isize, @bitCast(set_flags_rc)) < 0) {
        closeFd(stdout_fd);
        closeFd(stderr_fd);
        closeFd(1);
        closeFd(2);
        childExitErrno(set_flags_rc);
    }
}

fn childExitErrno(rc: usize) noreturn {
    const signed_rc: isize = @bitCast(rc);
    const errno_code: u8 = if (signed_rc < 0 and signed_rc > -4096)
        @intCast(@min(-signed_rc, @as(isize, 255)))
    else
        1;
    linux.exit(errno_code);
}

fn cancelRunningChild(pid: i32, stdout_fd: i32, stderr_fd: i32) void {
    closeFd(stdout_fd);
    closeFd(stderr_fd);

    if (pid > 0) {
        terminateChild(pid);
    }
}

fn terminateChild(pid: i32) void {
    _ = linux.kill(pid, linux.SIG.TERM);

    var status: u32 = 0;
    var attempts: usize = 50;
    while (attempts > 0) : (attempts -= 1) {
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid or rc < 0) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    _ = linux.kill(pid, linux.SIG.KILL);
    var retries: usize = 100;
    while (retries > 0) : (retries -= 1) {
        const rc: isize = @bitCast(linux.waitpid(pid, &status, linux.W.NOHANG));
        if (rc == pid or rc < 0) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn closeFd(fd: i32) void {
    if (fd >= 0) _ = linux.close(fd);
}

test "command validates input" {
    try std.testing.expectError(error.InvalidCommand, (Command{}).run());
}

test "command reports pre-cancelled token" {
    var token: coro.CancelToken = .{};
    token.cancel();

    var cmd = Command.shell("echo hi");
    _ = cmd.cancelToken(&token);
    try std.testing.expectError(error.Cancelled, cmd.run());
}

test "command reports pre-cancelled scope" {
    var scope = coro.Scope.init();
    scope.cancel();

    var cmd = Command.shell("echo hi");
    _ = cmd.scope(&scope);
    try std.testing.expectError(error.Cancelled, cmd.run());
}
