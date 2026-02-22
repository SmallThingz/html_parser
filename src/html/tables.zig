const std = @import("std");

pub fn makeClassTable(comptime predicate: fn (u8) bool) [256]bool {
    @setEvalBranchQuota(10_000);
    var table = [_]bool{false} ** 256;
    inline for (0..256) |i| {
        table[i] = predicate(@as(u8, @intCast(i)));
    }
    return table;
}

pub fn makeLowerTable() [256]u8 {
    @setEvalBranchQuota(10_000);
    var table: [256]u8 = undefined;
    inline for (0..256) |i| {
        const c: u8 = @intCast(i);
        table[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return table;
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '\x0c';
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':';
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

pub fn isTagNameChar(c: u8) bool {
    return isIdentChar(c);
}

pub const LowerTable = makeLowerTable();
pub const WhitespaceTable = makeClassTable(isWhitespace);
pub const IdentStartTable = makeClassTable(isIdentStart);
pub const IdentCharTable = makeClassTable(isIdentChar);
pub const TagNameCharTable = makeClassTable(isTagNameChar);

pub inline fn lower(c: u8) u8 {
    return LowerTable[c];
}

pub fn toLowerInPlace(bytes: []u8) void {
    for (bytes) |*c| c.* = lower(c.*);
}

pub fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

pub fn startsWithIgnoreCaseAscii(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    return eqlIgnoreCaseAscii(hay[0..needle.len], needle);
}

pub fn trimAsciiWhitespace(slice: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = slice.len;
    while (start < end and WhitespaceTable[slice[start]]) start += 1;
    while (end > start and WhitespaceTable[slice[end - 1]]) end -= 1;
    return slice[start..end];
}

test "lower table" {
    try std.testing.expect(lower('A') == 'a');
    try std.testing.expect(lower('z') == 'z');
}
