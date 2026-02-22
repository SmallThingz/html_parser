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

pub inline fn findEither2(hay: []const u8, start: usize, a: u8, b: u8) ?usize {
    return findEither2Dispatch(hay, start, a, b);
}

pub inline fn findAny3(hay: []const u8, start: usize, a: u8, b: u8, c: u8) ?usize {
    return findAny3Dispatch(hay, start, a, b, c);
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

inline fn findEither2Dispatch(hay: []const u8, start: usize, a: u8, b: u8) ?usize {
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        return findEither2Vec(32, hay, start, a, b);
    }
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) {
        return findEither2Vec(16, hay, start, a, b);
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        return findEither2Vec(16, hay, start, a, b);
    }

    const ia = std.mem.indexOfScalarPos(u8, hay, start, a);
    const ib = std.mem.indexOfScalarPos(u8, hay, start, b);
    if (ia == null) return ib;
    if (ib == null) return ia;
    return @min(ia.?, ib.?);
}

inline fn findAny3Dispatch(hay: []const u8, start: usize, a: u8, b: u8, c: u8) ?usize {
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        return findAny3Vec(32, hay, start, a, b, c);
    }
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) {
        return findAny3Vec(16, hay, start, a, b, c);
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        return findAny3Vec(16, hay, start, a, b, c);
    }

    const iab = findEither2Dispatch(hay, start, a, b);
    const ic = std.mem.indexOfScalarPos(u8, hay, start, c);
    if (iab == null) return ic;
    if (ic == null) return iab;
    return @min(iab.?, ic.?);
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

inline fn findEither2Vec(comptime lanes: comptime_int, hay: []const u8, start: usize, a: u8, b: u8) ?usize {
    const Vec = @Vector(lanes, u8);
    const a_vec: Vec = @splat(a);
    const b_vec: Vec = @splat(b);

    var i = start;
    while (i + lanes <= hay.len) : (i += lanes) {
        const chunk: [lanes]u8 = hay[i..][0..lanes].*;
        const vec: Vec = chunk;
        const mask = (vec == a_vec) | (vec == b_vec);
        if (@reduce(.Or, mask)) {
            var j: usize = 0;
            while (j < lanes) : (j += 1) {
                const ch = chunk[j];
                if (ch == a or ch == b) return i + j;
            }
        }
    }

    while (i < hay.len) : (i += 1) {
        const ch = hay[i];
        if (ch == a or ch == b) return i;
    }
    return null;
}

inline fn findAny3Vec(comptime lanes: comptime_int, hay: []const u8, start: usize, a: u8, b: u8, c: u8) ?usize {
    const Vec = @Vector(lanes, u8);
    const a_vec: Vec = @splat(a);
    const b_vec: Vec = @splat(b);
    const c_vec: Vec = @splat(c);

    var i = start;
    while (i + lanes <= hay.len) : (i += lanes) {
        const chunk: [lanes]u8 = hay[i..][0..lanes].*;
        const vec: Vec = chunk;
        const mask = (vec == a_vec) | (vec == b_vec) | (vec == c_vec);
        if (@reduce(.Or, mask)) {
            var j: usize = 0;
            while (j < lanes) : (j += 1) {
                const ch = chunk[j];
                if (ch == a or ch == b or ch == c) return i + j;
            }
        }
    }

    while (i < hay.len) : (i += 1) {
        const ch = hay[i];
        if (ch == a or ch == b or ch == c) return i;
    }
    return null;
}

test "find helpers match scalar behavior" {
    const s = "abc<?d<!--x--><q";
    try std.testing.expectEqual(@as(?usize, 3), findByte(s, 0, '<'));
    try std.testing.expectEqual(@as(?usize, 4), findEither2(s, 0, '?', 'd'));
    try std.testing.expectEqual(@as(?usize, 3), findAny3(s, 0, '?', '!', '<'));
}

test "findTagEndRespectQuotes handles quoted > and self close" {
    const s = " x='1>2' y=z />";
    const out = findTagEndRespectQuotes(s, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(out.self_close);
    try std.testing.expectEqual(@as(usize, s.len - 1), out.gt_index);
}
