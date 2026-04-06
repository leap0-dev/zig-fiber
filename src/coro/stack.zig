const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const GUARD_PAGES: usize = 1;

pub const Options = struct {
    stack_size: usize,
    reserve_size: usize,
    grow_size: usize,
};

pub const Stack = struct {
    mapping: []align(std.heap.page_size_min) u8,
    committed_start: usize,

    pub fn init(options: Options) !Stack {
        const page_size = std.heap.pageSize();
        const guard_size = GUARD_PAGES * page_size;
        const reserve_size = alignToPage(options.reserve_size, page_size);
        const initial_size = alignToPage(options.stack_size, page_size);

        if (reserve_size <= guard_size) return error.InvalidStackConfig;
        if (initial_size == 0 or initial_size >= reserve_size - guard_size) return error.InvalidStackConfig;

        const mapping = try posix.mmap(
            null,
            reserve_size,
            posix.PROT.NONE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer posix.munmap(mapping);

        const committed_start = reserve_size - initial_size;
        const committed: []align(std.heap.page_size_min) u8 = @alignCast(mapping[committed_start..]);
        try posix.mprotect(committed, posix.PROT.READ | posix.PROT.WRITE);

        return .{
            .mapping = mapping,
            .committed_start = committed_start,
        };
    }

    pub fn deinit(self: *Stack) void {
        posix.munmap(self.mapping);
    }

    pub fn slice(self: *const Stack) []u8 {
        return self.mapping[self.committed_start..];
    }

    pub fn growForFault(self: *Stack, options: Options, fault_addr: usize) bool {
        const base = @intFromPtr(self.mapping.ptr);
        const page_size = std.heap.pageSize();
        const lowest_growable = base + (GUARD_PAGES * page_size);
        const committed_base = base + self.committed_start;
        const top = base + self.mapping.len;

        if (fault_addr < lowest_growable or fault_addr >= committed_base) return false;
        if (fault_addr >= top) return false;

        const grow_size = alignToPage(options.grow_size, page_size);
        const fault_offset = fault_addr - base;
        const fault_page = alignDownToPage(fault_offset, page_size);
        const needed = self.committed_start - fault_page;
        const min_start = GUARD_PAGES * page_size;
        const max_growth = self.committed_start - min_start;
        const growth = @min(@max(grow_size, alignToPage(needed, page_size)), max_growth);
        const new_start = @max(min_start, self.committed_start - growth);

        if (new_start >= self.committed_start) return false;

        const rc = linux.mprotect(self.mapping.ptr + new_start, self.committed_start - new_start, posix.PROT.READ | posix.PROT.WRITE);
        if (linux.E.init(rc) != .SUCCESS) return false;

        self.committed_start = new_start;
        return true;
    }
};

fn alignToPage(value: usize, page_size: usize) usize {
    if (value == 0) return 0;
    return std.mem.alignForward(usize, value, page_size);
}

fn alignDownToPage(value: usize, page_size: usize) usize {
    return value & ~@as(usize, page_size - 1);
}
