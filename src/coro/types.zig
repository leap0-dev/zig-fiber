pub const YieldValue = union(enum) {
    watch_pipes: WatchPipes,
    completed,
    pipe_data: PipeData,
    child_exited: i32,
    child_timed_out,
    none,
};

pub const WatchPipes = struct {
    stdout_fd: i32 = -1,
    stderr_fd: i32 = -1,
    child_pid: i32 = -1,
    timeout_sec: u32 = 0,
};

pub const PipeData = struct {
    fd: i32,
    buf: [*]const u8,
    len: usize,
    eof: bool,
};

pub const Context = extern struct {
    rsp: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

pub const State = enum {
    idle,
    ready,
    running,
    suspended,
};
