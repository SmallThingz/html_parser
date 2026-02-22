const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");

pub const TagEnd = struct {
    gt_index: usize,
    attr_end: usize,
    self_close: bool,
};

pub inline fn findByte(hay: []const u8, start: usize, needle: u8) ?usize {
    return findByteDispatch(hay, start, needle);
}

pub fn findTagEndRespectQuotes(hay: []const u8, start: usize) ?TagEnd {
    var i = start;
    var quote: u8 = 0;
    while (i < hay.len) : (i += 1) {
        const ch = hay[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
            continue;
        }

        switch (ch) {
            '"', '\'' => quote = ch,
            '>' => {
                // Trim trailing ASCII whitespace before deciding whether this is
                // `.../>` or `...>`.
                var j = i;
                while (j > start and tables.WhitespaceTable[hay[j - 1]]) : (j -= 1) {}

                if (j > start and hay[j - 1] == '/') {
                    return .{
                        .gt_index = i,
                        .attr_end = j - 1,
                        .self_close = true,
                    };
                }

                return .{
                    .gt_index = i,
                    .attr_end = i,
                    .self_close = false,
                };
            },
            else => {},
        }
    }
    return null;
}

inline fn findByteDispatch(hay: []const u8, start: usize, needle: u8) ?usize {
    // Compile-time architecture dispatch keeps a single callsite shape while
    // selecting the fastest available vector width.
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        return findByteVec(32, hay, start, needle);
    }
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) {
        return findByteVec(16, hay, start, needle);
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        return findByteVec(16, hay, start, needle);
    }
    return std.mem.indexOfScalarPos(u8, hay, start, needle);
}

inline fn findByteVec(comptime lanes: comptime_int, hay: []const u8, start: usize, needle: u8) ?usize {
    const Vec = @Vector(lanes, u8);
    const needle_vec: Vec = @splat(needle);

    var i = start;
    while (i + lanes <= hay.len) : (i += lanes) {
        const chunk: [lanes]u8 = hay[i..][0..lanes].*;
        const vec: Vec = chunk;
        const mask = vec == needle_vec;
        if (@reduce(.Or, mask)) {
            var j: usize = 0;
            while (j < lanes) : (j += 1) {
                if (chunk[j] == needle) return i + j;
            }
        }
    }

    return std.mem.indexOfScalarPos(u8, hay, i, needle);
}

test "findByte helper matches scalar behavior" {
    const s = "abc<?d<!--x--><q";
    try std.testing.expectEqual(@as(?usize, 3), findByte(s, 0, '<'));
}

test "findTagEndRespectQuotes handles quoted > and self close" {
    const s = " x='1>2' y=z />";
    const out = findTagEndRespectQuotes(s, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(out.self_close);
    try std.testing.expectEqual(@as(usize, s.len - 1), out.gt_index);
}
