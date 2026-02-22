const std = @import("std");

pub fn containsEntity(slice: []const u8) bool {
    return std.mem.indexOfScalar(u8, slice, '&') != null;
}

pub fn decodeInPlace(slice: []u8) usize {
    var r: usize = 0;
    var w: usize = 0;

    while (r < slice.len) {
        if (slice[r] != '&') {
            slice[w] = slice[r];
            r += 1;
            w += 1;
            continue;
        }

        const maybe = decodeEntity(slice[r..]);
        if (maybe) |decoded| {
            @memcpy(slice[w .. w + decoded.bytes.len], decoded.bytes);
            r += decoded.consumed;
            w += decoded.bytes.len;
        } else {
            slice[w] = slice[r];
            r += 1;
            w += 1;
        }
    }

    return w;
}

const Decoded = struct {
    consumed: usize,
    bytes: [4]u8,
    len: usize,
};

fn decodeEntity(rem: []const u8) ?struct { consumed: usize, bytes: []const u8 } {
    if (rem.len < 4 or rem[0] != '&') return null;

    if (std.mem.startsWith(u8, rem, "&amp;")) return .{ .consumed = 5, .bytes = "&" };
    if (std.mem.startsWith(u8, rem, "&lt;")) return .{ .consumed = 4, .bytes = "<" };
    if (std.mem.startsWith(u8, rem, "&gt;")) return .{ .consumed = 4, .bytes = ">" };
    if (std.mem.startsWith(u8, rem, "&quot;")) return .{ .consumed = 6, .bytes = "\"" };
    if (std.mem.startsWith(u8, rem, "&apos;")) return .{ .consumed = 6, .bytes = "'" };

    if (rem.len >= 4 and rem[1] == '#') {
        if (parseNumeric(rem)) |n| {
            return .{ .consumed = n.consumed, .bytes = n.bytes[0..n.len] };
        }
    }

    return null;
}

fn parseNumeric(rem: []const u8) ?struct { consumed: usize, bytes: [4]u8, len: usize } {
    if (rem.len < 4 or rem[0] != '&' or rem[1] != '#') return null;

    var i: usize = 2;
    var base: u32 = 10;
    if (i < rem.len and (rem[i] == 'x' or rem[i] == 'X')) {
        base = 16;
        i += 1;
    }

    const start = i;
    var value: u32 = 0;
    while (i < rem.len and rem[i] != ';') : (i += 1) {
        const c = rem[i];
        const digit: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => if (base == 16) 10 + (c - 'a') else return null,
            'A'...'F' => if (base == 16) 10 + (c - 'A') else return null,
            else => return null,
        };
        value = value * base + digit;
        if (value > 0x10FFFF) return null;
    }

    if (i == start or i >= rem.len or rem[i] != ';') return null;

    var out: [4]u8 = undefined;
    const codepoint: u21 = @intCast(value);
    const len = std.unicode.utf8Encode(codepoint, &out) catch return null;
    return .{ .consumed = i + 1, .bytes = out, .len = len };
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
}
