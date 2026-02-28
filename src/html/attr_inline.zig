const std = @import("std");
const tables = @import("tables.zig");
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");

const RawKind = enum {
    empty,
    quoted,
    naked,
};

const RawValue = struct {
    kind: RawKind,
    start: usize,
    end: usize,
    next_start: usize,
};

const LookupKind = enum(u8) {
    generic,
    id,
    class,
    href,
};

const FnvOffset: u32 = 2166136261;
const FnvPrime: u32 = 16777619;

// Attribute traversal and value materialization are intentionally in-place.
// Wire states after name parsing:
// - `name=...` raw value, lazily materialized on first read
// - `name\0...` parsed value (with marker layout handled by parseParsedValue)
// - `name` + delimiter/end -> boolean/name-only attribute
/// Returns attribute value by name from in-place attribute bytes, decoding lazily.
pub fn getAttrValue(noalias doc_ptr: anytype, node: anytype, name: []const u8) ?[]const u8 {
    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    const lookup_kind = classifyLookupName(name);
    const lookup_hash = if (lookup_kind == .generic) hashIgnoreCaseAscii(name) else 0;

    var i: usize = node.attr_bytes.start;
    const end: usize = node.attr_bytes.end;
    if (i >= end) return null;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) return null;

        const c = source[i];
        if (c == '>' or c == '/') return null;

        const name_start = i;
        var attr_name_hash: u32 = FnvOffset;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {
            if (lookup_kind == .generic) {
                attr_name_hash = hashIgnoreCaseAsciiUpdate(attr_name_hash, source[i]);
            }
        }
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_end = i;
        const attr_name = source[name_start..name_end];
        const is_target = matchesLookupNameHashed(attr_name, attr_name_hash, name, lookup_kind, lookup_hash);

        if (i >= end) {
            if (is_target) return "";
            return null;
        }

        const delim = source[i];
        if (delim == '=') {
            const raw = parseRawValue(source, end, i);
            if (is_target) {
                return materializeRawValue(source, end, i, raw);
            }
            i = raw.next_start;
            continue;
        }

        if (delim == 0) {
            const parsed = parseParsedValue(source, end, i);
            if (is_target) return parsed.value;
            i = parsed.next_start;
            continue;
        }

        if (is_target) return "";

        if (delim == '>' or delim == '/') return null;

        if (tables.WhitespaceTable[delim]) {
            i += 1;
            continue;
        }

        i += 1;
    }

    return null;
}

/// One-pass multi-attribute collector used by matcher hot paths.
pub fn collectSelectedValues(noalias doc_ptr: anytype, node: anytype, selected_names: []const []const u8, out_values: []?[]const u8) void {
    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len) return;

    var i: usize = node.attr_bytes.start;
    const end: usize = node.attr_bytes.end;
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) break;

        const c = source[i];
        if (c == '>' or c == '/') break;

        const name_start = i;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {}
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_slice = source[name_start..i];
        const selected_idx = firstUnresolvedMatch(selected_names, out_values, name_slice);

        if (i >= end) {
            if (selected_idx) |idx| {
                out_values[idx] = "";
                remaining -= 1;
            }
            break;
        }

        const delim = source[i];
        if (delim == '=') {
            const eq_index = i;
            const raw = parseRawValue(source, end, eq_index);
            if (selected_idx) |idx| {
                out_values[idx] = materializeRawValue(source, end, eq_index, raw);
                const parsed = parseParsedValue(source, end, eq_index);
                i = parsed.next_start;
                remaining -= 1;
                if (remaining == 0) return;
            } else {
                i = raw.next_start;
            }
            continue;
        }

        if (delim == 0) {
            const parsed = parseParsedValue(source, end, i);
            i = parsed.next_start;
            if (selected_idx) |idx| {
                out_values[idx] = parsed.value;
                remaining -= 1;
                if (remaining == 0) return;
            }
            continue;
        }

        if (selected_idx) |idx| {
            out_values[idx] = "";
            remaining -= 1;
            if (remaining == 0) return;
        }

        if (delim == '>' or delim == '/') break;
        if (tables.WhitespaceTable[delim]) {
            i += 1;
            continue;
        }
        i += 1;
    }
}

/// Hash-assisted multi-attribute collector variant for selector matching.
pub fn collectSelectedValuesByHash(
    noalias doc_ptr: anytype,
    node: anytype,
    selected_names: []const []const u8,
    selected_hashes: []const u32,
    out_values: []?[]const u8,
) void {
    const mut_doc = @constCast(doc_ptr);
    const source: []u8 = mut_doc.source;
    if (selected_names.len == 0) return;
    if (selected_names.len != out_values.len or selected_names.len != selected_hashes.len) return;

    var i: usize = node.attr_bytes.start;
    const end: usize = node.attr_bytes.end;
    var remaining: usize = 0;
    for (out_values) |v| {
        if (v == null) remaining += 1;
    }
    if (remaining == 0) return;

    while (i < end) {
        while (i < end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        if (i >= end) break;

        const c = source[i];
        if (c == '>' or c == '/') break;

        const name_start = i;
        var name_hash: u32 = FnvOffset;
        while (i < end and tables.IdentCharTable[source[i]]) : (i += 1) {
            name_hash = hashIgnoreCaseAsciiUpdate(name_hash, source[i]);
        }
        if (i == name_start) {
            i += 1;
            continue;
        }

        const name_slice = source[name_start..i];
        const selected_idx = firstUnresolvedMatchByHash(
            selected_names,
            selected_hashes,
            out_values,
            name_slice,
            name_hash,
        );

        if (i >= end) {
            if (selected_idx) |idx| {
                out_values[idx] = "";
                remaining -= 1;
            }
            break;
        }

        const delim = source[i];
        if (delim == '=') {
            const eq_index = i;
            const raw = parseRawValue(source, end, eq_index);
            if (selected_idx) |idx| {
                out_values[idx] = materializeRawValue(source, end, eq_index, raw);
                const parsed = parseParsedValue(source, end, eq_index);
                i = parsed.next_start;
                remaining -= 1;
                if (remaining == 0) return;
            } else {
                i = raw.next_start;
            }
            continue;
        }

        if (delim == 0) {
            const parsed = parseParsedValue(source, end, i);
            i = parsed.next_start;
            if (selected_idx) |idx| {
                out_values[idx] = parsed.value;
                remaining -= 1;
                if (remaining == 0) return;
            }
            continue;
        }

        if (selected_idx) |idx| {
            out_values[idx] = "";
            remaining -= 1;
            if (remaining == 0) return;
        }

        if (delim == '>' or delim == '/') break;
        if (tables.WhitespaceTable[delim]) {
            i += 1;
            continue;
        }
        i += 1;
    }
}

const ParsedValue = struct {
    value: []const u8,
    next_start: usize,
};

fn parseParsedValue(source: []u8, span_end: usize, name_end: usize) ParsedValue {
    // Parsed layout can be:
    // - name\0\0value\0...
    // - name\0value\0...
    if (name_end + 1 >= span_end) return .{ .value = "", .next_start = span_end };

    const marker = source[name_end + 1];
    var value_start: usize = if (marker == 0) name_end + 2 else name_end + 1;
    if (value_start > span_end) value_start = span_end;

    const value_end = findValueEnd(source, value_start, span_end);
    const next = nextAfterValue(source, value_end, span_end);
    return .{ .value = source[value_start..value_end], .next_start = next };
}

fn parseRawValue(source: []u8, span_end: usize, eq_index: usize) RawValue {
    var i = eq_index + 1;
    while (i < span_end and tables.WhitespaceTable[source[i]]) : (i += 1) {}

    if (i >= span_end) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    const c = source[i];
    if (c == '>' or c == '/') {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = i };
    }

    if (c == '\'' or c == '"') {
        const q = c;
        const j = scanner.findByte(source, i + 1, q) orelse span_end;
        const next_start = if (j < span_end) j + 1 else span_end;
        return .{ .kind = .quoted, .start = i + 1, .end = j, .next_start = next_start };
    }

    var j = i;
    while (j < span_end) : (j += 1) {
        const b = source[j];
        if (b == '>' or b == '/' or tables.WhitespaceTable[b]) break;
    }

    if (j == i) {
        return .{ .kind = .empty, .start = i, .end = i, .next_start = j };
    }

    return .{ .kind = .naked, .start = i, .end = j, .next_start = j };
}

fn materializeRawValue(source: []u8, span_end: usize, eq_index: usize, raw: RawValue) []const u8 {
    if (raw.kind == .empty) {
        // Canonical rewrite for explicit empty assignment: `a=` -> `a `.
        source[eq_index] = ' ';
        return "";
    }

    var decoded_len: usize = raw.end - raw.start;
    decoded_len = entities.decodeInPlaceIfEntity(source[raw.start..raw.end]);

    if (raw.kind == .quoted) {
        // Quoted values use a double-NUL marker so traversal can distinguish
        // this family and preserve skip metadata correctness after shifts.
        source[eq_index] = 0;
        if (eq_index + 1 < span_end) source[eq_index + 1] = 0;

        const dst = @min(eq_index + 2, span_end);
        if (decoded_len != 0 and dst != raw.start and dst + decoded_len <= span_end) {
            std.mem.copyForwards(u8, source[dst .. dst + decoded_len], source[raw.start .. raw.start + decoded_len]);
        }

        const term = @min(dst + decoded_len, span_end);
        if (term < span_end) {
            source[term] = 0;
            patchGap(source, span_end, term, raw.next_start);
        }
        return source[dst..term];
    }

    source[eq_index] = 0;

    const dst = @min(eq_index + 1, span_end);
    if (decoded_len != 0 and dst != raw.start and dst + decoded_len <= span_end) {
        std.mem.copyForwards(u8, source[dst .. dst + decoded_len], source[raw.start .. raw.start + decoded_len]);
    }

    const term = @min(dst + decoded_len, span_end);
    if (term < span_end) {
        source[term] = 0;
        patchGap(source, span_end, term, raw.next_start);
    }

    return source[dst..term];
}

fn findValueEnd(source: []const u8, value_start: usize, span_end: usize) usize {
    var i = value_start;
    while (i < span_end and source[i] != 0) : (i += 1) {}
    return i;
}

fn nextAfterValue(source: []const u8, value_end: usize, span_end: usize) usize {
    if (value_end >= span_end) return span_end;
    var i = value_end + 1;
    if (i >= span_end) return span_end;

    if (source[i] == 0) {
        if (i + 1 >= span_end) return span_end;

        const len_byte = source[i + 1];
        if (len_byte == 0xff) {
            if (i + 6 > span_end) return span_end;
            const skip = std.mem.readInt(u32, source[i + 2 .. i + 6][0..4], nativeEndian());
            const next = i + 6 + @as(usize, @intCast(skip));
            return @min(next, span_end);
        }

        const next = i + 2 + @as(usize, len_byte);
        return @min(next, span_end);
    }

    if (tables.WhitespaceTable[source[i]]) {
        while (i < span_end and tables.WhitespaceTable[source[i]]) : (i += 1) {}
        return i;
    }

    return i;
}

fn patchGap(source: []u8, span_end: usize, value_end: usize, raw_next_start: usize) void {
    // Any removed bytes are encoded as:
    // - single-space for tiny gaps
    // - short skip metadata: 0x00, len
    // - extended skip metadata: 0x00, 0xFF, u32 len
    // This keeps traversal O(n) without reparsing shifted tails.
    if (value_end + 1 >= span_end) return;

    const next_start = @min(raw_next_start, span_end);
    if (next_start <= value_end + 1) return;

    const gap_start = value_end + 1;
    const gap_len = next_start - gap_start;
    if (gap_len == 0) return;

    if (gap_len == 1) {
        source[gap_start] = ' ';
        return;
    }

    if (gap_len <= 256) {
        source[gap_start] = 0;
        source[gap_start + 1] = @intCast(gap_len - 2);
        return;
    }

    if (gap_len >= 6) {
        source[gap_start] = 0;
        source[gap_start + 1] = 0xff;
        const skip: u32 = @intCast(gap_len - 6);
        std.mem.writeInt(u32, source[gap_start + 2 .. gap_start + 6][0..4], skip, nativeEndian());
        return;
    }

    source[gap_start] = ' ';
}

fn nativeEndian() std.builtin.Endian {
    return @import("builtin").cpu.arch.endian();
}

fn firstUnresolvedMatch(selected_names: []const []const u8, out_values: []const ?[]const u8, name: []const u8) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (matchesLookupName(name, selected_names[idx], .generic, hashIgnoreCaseAscii(selected_names[idx]))) return idx;
    }
    return null;
}

fn firstUnresolvedMatchByHash(
    selected_names: []const []const u8,
    selected_hashes: []const u32,
    out_values: []const ?[]const u8,
    name: []const u8,
    name_hash: u32,
) ?usize {
    var idx: usize = 0;
    while (idx < selected_names.len) : (idx += 1) {
        if (out_values[idx] != null) continue;
        if (selected_hashes[idx] != name_hash) continue;
        if (matchesLookupNameHashed(name, name_hash, selected_names[idx], .generic, selected_hashes[idx])) return idx;
    }
    return null;
}

fn matchesLookupName(attr_name: []const u8, lookup: []const u8, lookup_kind: LookupKind, lookup_hash: u32) bool {
    const attr_hash = if (lookup_kind == .generic) hashIgnoreCaseAscii(attr_name) else 0;
    return matchesLookupNameHashed(attr_name, attr_hash, lookup, lookup_kind, lookup_hash);
}

fn matchesLookupNameHashed(attr_name: []const u8, attr_hash: u32, lookup: []const u8, lookup_kind: LookupKind, lookup_hash: u32) bool {
    switch (lookup_kind) {
        .id => return isExactAsciiWord(attr_name, "id"),
        .class => return isExactAsciiWord(attr_name, "class"),
        .href => return isExactAsciiWord(attr_name, "href"),
        .generic => {},
    }

    if (attr_name.len != lookup.len) return false;
    if (attr_name.len != 0 and toLowerAscii(attr_name[0]) != toLowerAscii(lookup[0])) return false;
    if (attr_hash != lookup_hash) return false;
    return tables.eqlIgnoreCaseAscii(attr_name, lookup);
}

fn classifyLookupName(lookup: []const u8) LookupKind {
    if (isExactAsciiWord(lookup, "id")) return .id;
    if (isExactAsciiWord(lookup, "class")) return .class;
    if (isExactAsciiWord(lookup, "href")) return .href;
    return .generic;
}

fn hashIgnoreCaseAscii(bytes: []const u8) u32 {
    var h: u32 = FnvOffset;
    for (bytes) |c| {
        h = hashIgnoreCaseAsciiUpdate(h, c);
    }
    return h;
}

inline fn hashIgnoreCaseAsciiUpdate(h: u32, c: u8) u32 {
    return (h ^ @as(u32, tables.lower(c))) *% FnvPrime;
}

fn isExactAsciiWord(value: []const u8, comptime lower: []const u8) bool {
    if (value.len != lower.len) return false;
    var i: usize = 0;
    while (i < lower.len) : (i += 1) {
        if (toLowerAscii(value[i]) != lower[i]) return false;
    }
    return true;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}
