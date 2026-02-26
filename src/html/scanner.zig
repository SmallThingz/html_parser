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
    const first = findAny3Dispatch(hay, start, '>', '"', '\'') orelse return null;
    const first_ch = hay[first];
    if (first_ch == '>') return finalizeTagEnd(hay, start, first);

    var quote = first_ch;
    var i = first + 1;
    while (i < hay.len) {
        const q_pos = findByteDispatch(hay, i, quote) orelse return null;
        i = q_pos + 1;

        const pos = findAny3Dispatch(hay, i, '>', '"', '\'') orelse return null;
        const ch = hay[pos];
        if (ch == '>') return finalizeTagEnd(hay, start, pos);
        quote = ch;
        i = pos + 1;
    }
    return null;
}

inline fn finalizeTagEnd(hay: []const u8, start: usize, gt_index: usize) TagEnd {
    // Trim trailing ASCII whitespace before deciding whether this is
    // `.../>` or `...>`.
    if (gt_index > start) {
        const prev = hay[gt_index - 1];
        if (prev == '/') {
            return .{
                .gt_index = gt_index,
                .attr_end = gt_index - 1,
                .self_close = true,
            };
        }
        if (!tables.WhitespaceTable[prev]) {
            return .{
                .gt_index = gt_index,
                .attr_end = gt_index,
                .self_close = false,
            };
        }
    }

    var j = gt_index;
    while (j > start and tables.WhitespaceTable[hay[j - 1]]) : (j -= 1) {}

    if (j > start and hay[j - 1] == '/') {
        return .{
            .gt_index = gt_index,
            .attr_end = j - 1,
            .self_close = true,
        };
    }

    return .{
        .gt_index = gt_index,
        .attr_end = gt_index,
        .self_close = false,
    };
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
    return findAny3Scalar(hay, start, a, b, c);
}

inline fn findAny3Scalar(hay: []const u8, start: usize, a: u8, b: u8, c: u8) ?usize {
    var i = start;
    while (i < hay.len) : (i += 1) {
        const ch = hay[i];
        if (ch == a or ch == b or ch == c) return i;
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
    return findAny3Scalar(hay, i, a, b, c);
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
