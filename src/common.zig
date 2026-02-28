const std = @import("std");

pub inline fn appendAlloc(comptime T: type, noalias list: *std.ArrayListUnmanaged(T), alloc: std.mem.Allocator, value: T) !void {
    const len = list.items.len;
    if (len == list.capacity) {
        @branchHint(.unlikely);
        list.ensureTotalCapacityPrecise(alloc, len + len / 2 + @as(comptime_int, @max(1, std.atomic.cache_line / @sizeOf(T)))) catch |e| {
            @branchHint(.cold);
            return e;
        };
    }

    list.appendAssumeCapacity(value);
}
