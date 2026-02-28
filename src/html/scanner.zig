const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");

/// Result of scanning to a tag end while respecting quoted attributes.
pub const TagEnd = struct {
    gt_index: usize,
    attr_end: usize,
};

/// Finds `needle` byte in `hay` from `start`, using SIMD where available.
pub inline fn findByte(hay: []const u8, start: usize, needle: u8) ?usize {
    // return findByteDispatch(hay, start, needle);
    return @call(.always_inline, indexOfScalarPos, .{ hay, start, needle });
}

/// Scans from `start` to next `>` while skipping quoted `>` inside attributes.
pub fn findTagEndRespectQuotes(hay: []const u8, _start: usize) ?TagEnd {
    var start = _start;
    var end = findAny3Dispatch(hay, start) orelse {
        @branchHint(.cold);
        return null;
    };
    blk: switch (hay[end]) {
        '>' => return .{
            .gt_index = end,
            .attr_end = end,
        },
        '\'', '"' => |q| {
            start = 1 + end;
            start = 1 + (findByte(hay, start, q) orelse {
                @branchHint(.cold);
                return null;
            });
            end = findAny3Dispatch(hay, start) orelse {
                @branchHint(.cold);
                return null;
            };
            continue :blk hay[end];
        },
        else => unreachable,
    }
}

/// Scans from `start` (right after an opening `<svg...>` tag) to the matching
/// closing `</svg>`, counting nested `<svg>` blocks and ignoring `<svg` text
/// inside quoted attributes.
pub fn findSvgSubtreeEnd(hay: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < hay.len) {
        const lt = findByte(hay, i, '<') orelse return null;
        if (lt + 1 >= hay.len) return null;

        const next = hay[lt + 1];
        if (next == '!') {
            if (lt + 3 < hay.len and hay[lt + 2] == '-' and hay[lt + 3] == '-') {
                var j = lt + 4;
                var found_close = false;
                while (j + 2 < hay.len) {
                    const dash = findByte(hay, j, '-') orelse return null;
                    if (dash + 2 < hay.len and hay[dash + 1] == '-' and hay[dash + 2] == '>') {
                        i = dash + 3;
                        found_close = true;
                        break;
                    }
                    j = dash + 1;
                }
                if (!found_close) return null;
                continue;
            }
            const gt = findByte(hay, lt + 2, '>') orelse return null;
            i = gt + 1;
            continue;
        }

        if (next == '?') {
            const gt = findByte(hay, lt + 2, '>') orelse return null;
            i = gt + 1;
            continue;
        }

        if (next == '/') {
            var j = lt + 2;
            while (j < hay.len and tables.WhitespaceTable[hay[j]]) : (j += 1) {}
            const name_start = j;
            while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
            const gt = findByte(hay, j, '>') orelse return null;
            if (isSvgTagName(hay[name_start..j])) {
                depth -= 1;
                if (depth == 0) return gt + 1;
            }
            i = gt + 1;
            continue;
        }

        var j = lt + 1;
        while (j < hay.len and tables.WhitespaceTable[hay[j]]) : (j += 1) {}
        const name_start = j;
        while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
        if (j == name_start) {
            i = lt + 1;
            continue;
        }

        const tag_end = findTagEndRespectQuotes(hay, j) orelse return null;
        if (isSvgTagName(hay[name_start..j])) depth += 1;
        i = tag_end.gt_index + 1;
    }
    return null;
}

inline fn isSvgTagName(name: []const u8) bool {
    return name.len == 3 and
        tables.lower(name[0]) == 's' and
        tables.lower(name[1]) == 'v' and
        tables.lower(name[2]) == 'g';
}

inline fn findAny3Dispatch(hay: []const u8, start: usize) ?usize {
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

inline fn findAny3Scalar(hay: []const u8, start: usize) ?usize {
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

test "findTagEndRespectQuotes handles quoted >" {
    const s = " x='1>2' y=z />";
    const out = findTagEndRespectQuotes(s, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, s.len - 1), out.gt_index);
    try std.testing.expectEqual(@as(usize, s.len - 1), out.attr_end);
}

test "findSvgSubtreeEnd handles nested svg and quoted attribute bait" {
    const s = "<svg id='outer'><g data-k=\"x<svg y='z'>q\"><svg id='inner'><rect/></svg></g></svg><p id='after'></p>";
    const open_gt = findByte(s, 0, '>') orelse return error.TestUnexpectedResult;
    const out = findSvgSubtreeEnd(s, open_gt + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<p id='after'></p>", s[out..]);
}

test "findSvgSubtreeEnd returns null when subtree is unterminated" {
    const s = "<svg><g><path></g>";
    const open_gt = findByte(s, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(findSvgSubtreeEnd(s, open_gt + 1) == null);
}
