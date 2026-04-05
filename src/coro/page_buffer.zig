const std = @import("std");
const posix = std.posix;

pub const PageBuffer = struct {
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    len: usize = 0,

    pub fn reset(self: *PageBuffer) void {
        self.len = 0;
    }

    pub fn bytes(self: *const PageBuffer) []const u8 {
        const mapping = self.mapping orelse return "";
        return mapping[0..self.len];
    }

    pub fn append(self: *PageBuffer, data: []const u8) !void {
        const new_len = try std.math.add(usize, self.len, data.len);
        try self.ensureCapacity(new_len);
        const mapping = self.mapping orelse return error.OutOfMemory;
        @memcpy(mapping[self.len..][0..data.len], data);
        self.len = new_len;
    }

    pub fn deinit(self: *PageBuffer) void {
        if (self.mapping) |mapping| posix.munmap(mapping);
        self.* = .{};
    }

    fn ensureCapacity(self: *PageBuffer, min_capacity: usize) !void {
        if (self.mapping) |mapping| {
            if (mapping.len >= min_capacity) return;

            var new_cap = mapping.len;
            while (new_cap < min_capacity) {
                new_cap = std.math.mul(usize, new_cap, 2) catch return error.OutOfMemory;
            }
            new_cap = try alignToPage(new_cap);

            const next = try posix.mmap(
                null,
                new_cap,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );
            @memcpy(next[0..self.len], mapping[0..self.len]);
            posix.munmap(mapping);
            self.mapping = next;
            return;
        }

        const initial = try alignToPage(@max(min_capacity, std.heap.page_size_min));
        self.mapping = try posix.mmap(
            null,
            initial,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
    }
};

fn alignToPage(value: usize) !usize {
    const page_size = std.heap.page_size_min;
    const aligned = try std.math.add(usize, value, page_size - 1);
    return aligned & ~@as(usize, page_size - 1);
}
