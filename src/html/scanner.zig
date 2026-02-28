const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");

/// Result of scanning to a tag end while respecting quoted attributes.
pub const TagEnd = struct {
    gt_index: usize,
    attr_end: usize,
    self_close: bool,
};

/// Finds `needle` byte in `hay` from `start`, using SIMD where available.
pub inline fn findByte(hay: []const u8, start: usize, needle: u8) ?usize {
    // return findByteDispatch(hay, start, needle);
    return @call(.always_inline, indexOfScalarPos, .{hay, start, needle});
}

/// Scans from `start` to next `>` while skipping quoted `>` inside attributes.
pub fn findTagEndRespectQuotes(hay: []const u8, _start: usize) ?TagEnd {
    var start = _start;
    var end = findAny3Dispatch(hay, start) orelse {@branchHint(.cold); return null;};
    blk: switch (hay[end]) {
        '>' => return finalizeTagEnd(hay, start, end),
        '\'', '"' => |q| {
            start = 1 + end;
            start = 1 + (findByte(hay, start, q) orelse {@branchHint(.cold); return null;});
            end = findAny3Dispatch(hay, start) orelse {@branchHint(.cold); return null;};
            continue :blk hay[end];
        },
        else => unreachable,
    }
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

inline fn findAny3Dispatch(hay:[]const u8, start: usize) ?usize {
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
        return findAny3Vec(32, hay, start);
    }
    if (comptime builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) {
        return findAny3Vec(16, hay, start);
    }
    if (comptime builtin.cpu.arch == .aarch64) {
        return findAny3Vec(16, hay, start);
    }
    return findAny3Scalar(hay, start);
}

inline fn findAny3Scalar(hay:[]const u8, start: usize) ?usize {
    const a = '>';
    const b = '"';
    const c = '\'';
    for (hay[start..], start..) |ch, i| {
        if (ch == a or ch == b or ch == c) return i;
    }
    return null;
}

inline fn findAny3Vec(comptime lanes: comptime_int, hay: []const u8, start: usize) ?usize {
    const a = '>';
    const b = '"';
    const c = '\'';
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
            for (hay[i..], i..) |ch, j| {
                if (ch == a or ch == b or ch == c) return j;
            }
            unreachable;
        } else {
            @branchHint(.likely);
        }
    }
    return findAny3Scalar(hay, i);
}


inline fn indexOfScalarPos(slice: []const u8, start_index: usize, value: u8) ?usize {
    if (start_index >= slice.len) return null;

    var i: usize = start_index;
    if (!@inComptime()) {
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            // For Intel Nehalem (2009) and AMD Bulldozer (2012) or later, unaligned loads on aligned data result
            // in the same execution as aligned loads. We ignore older arch's here and don't bother pre-aligning.
            //
            // Use `std.simd.suggestVectorLength(T)` to get the same alignment as used in this function
            // however this usually isn't necessary unless your arch has a performance penalty due to this.
            //
            // This may differ for other arch's. Arm for example costs a cycle when loading across a cache
            // line so explicit alignment prologues may be worth exploration.

            // Unrolling here is ~10% improvement. We can then do one bounds check every 2 blocks
            // instead of one which adds up.
            const Block = @Vector(block_len, u8);
            if (i + 2 * block_len < slice.len) {
                const mask: Block = @splat(value);
                while (true) {
                    inline for (0..2) |_| {
                        const block: Block = slice[i..][0..block_len].*;
                        const matches = block == mask;
                        if (@reduce(.Or, matches)) {
                            return i + std.simd.firstTrue(matches).?;
                        }
                        i += block_len;
                    }
                    if (i + 2 * block_len >= slice.len) break;
                }
            }

            // {block_len, block_len / 2} check
            inline for (0..2) |j| {
                const block_x_len = block_len / (1 << j);
                comptime if (block_x_len < 4) break;

                const BlockX = @Vector(block_x_len, u8);
                if (i + block_x_len < slice.len) {
                    const mask: BlockX = @splat(value);
                    const block: BlockX = slice[i..][0..block_x_len].*;
                    const matches = block == mask;
                    if (@reduce(.Or, matches)) {
                        return i + std.simd.firstTrue(matches).?;
                    }
                    i += block_x_len;
                }
            }
        }
    }

    for (slice[i..], i..) |c, j| {
        if (c == value) return j;
    }
    return null;
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
