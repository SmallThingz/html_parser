const std = @import("std");
const tables = @import("tables.zig");
const entities = @import("entities.zig");
const attr_inline = @import("attr_inline.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);

pub const TextOptions = struct {
    normalize_whitespace: bool = true,
};

pub fn firstChild(comptime Node: type, self: *const Node) ?*const Node {
    var idx = self.first_child;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].next_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return c;
    }
    return null;
}

pub fn lastChild(comptime Node: type, self: *const Node) ?*const Node {
    var idx = self.last_child;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return c;
    }
    return null;
}

pub fn nextSibling(comptime Node: type, self: *const Node) ?*const Node {
    var idx = self.next_sibling;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].next_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return c;
    }
    return null;
}

pub fn prevSibling(comptime Node: type, self: *const Node) ?*const Node {
    var idx = self.prev_sibling;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return c;
    }
    return null;
}

pub fn parentNode(comptime Node: type, self: *const Node) ?*const Node {
    if (!self.doc.store_parent_pointers) return null;
    if (self.parent == InvalidIndex or self.parent == 0) return null;
    return &self.doc.nodes.items[self.parent];
}

pub fn children(comptime Node: type, self: *const Node) []const *const Node {
    const start: usize = @intCast(self.child_view_start);
    const end: usize = @intCast(self.child_view_start + self.child_view_len);
    return self.doc.child_ptrs.items[start..end];
}

pub fn getAttributeValue(comptime Node: type, self: *const Node, name: []const u8) ?[]const u8 {
    if (self.doc.attr_storage_mode == .inplace) {
        return attr_inline.getAttrValue(self.doc, self, name);
    }

    const doc = @constCast(self.doc);

    var i: u32 = self.attr_start;
    const end = self.attr_start + self.attr_len;
    while (i < end) : (i += 1) {
        const attr = &doc.attrs.items[i];
        if (!tables.eqlIgnoreCaseAscii(attr.name.slice(doc.source), name)) continue;

        if (attr.eq_index != InvalidIndex and doc.source[attr.eq_index] != 0) {
            doc.source[attr.eq_index] = 0;
            const value_mut = attr.value.sliceMut(doc.source);
            if (entities.containsEntity(value_mut)) {
                const new_len = entities.decodeInPlace(value_mut);
                attr.value.end = attr.value.start + @as(u32, @intCast(new_len));
            }
        }

        return attr.value.slice(doc.source);
    }

    return null;
}

pub fn innerText(comptime Node: type, self: *const Node, arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
    const doc = @constCast(self.doc);

    if (self.kind == .text) {
        const mut_node = &doc.nodes.items[self.index];
        _ = decodeTextNode(mut_node, doc);
        if (!opts.normalize_whitespace) return mut_node.text.slice(doc.source);
        return normalizeTextNodeInPlace(mut_node, doc);
    }

    var first_idx: u32 = InvalidIndex;
    var count: usize = 0;

    var idx = self.index + 1;
    while (idx <= self.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
        const node = &doc.nodes.items[idx];
        if (node.kind != .text) continue;
        count += 1;
        _ = decodeTextNode(node, doc);
        if (count == 1) first_idx = idx;
    }

    if (count == 0) return "";
    if (count == 1) {
        const only = &doc.nodes.items[first_idx];
        if (!opts.normalize_whitespace) return only.text.slice(doc.source);
        return normalizeTextNodeInPlace(only, doc);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena_alloc);

    if (!opts.normalize_whitespace) {
        idx = self.index + 1;
        while (idx <= self.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try out.appendSlice(arena_alloc, node.text.slice(doc.source));
        }
    } else {
        var state: WhitespaceNormState = .{};
        idx = self.index + 1;
        while (idx <= self.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try appendNormalizedSegment(&out, arena_alloc, node.text.slice(doc.source), &state);
        }
    }

    if (out.items.len == 0) return "";
    return try out.toOwnedSlice(arena_alloc);
}

fn decodeTextNode(node: anytype, doc: anytype) []const u8 {
    const text_mut = node.text.sliceMut(doc.source);
    if (entities.containsEntity(text_mut)) {
        const new_len = entities.decodeInPlace(text_mut);
        node.text.end = node.text.start + @as(u32, @intCast(new_len));
    }
    return node.text.slice(doc.source);
}

fn normalizeTextNodeInPlace(node: anytype, doc: anytype) []const u8 {
    const text_mut = node.text.sliceMut(doc.source);
    const new_len = normalizeWhitespaceInPlace(text_mut);
    node.text.end = node.text.start + @as(u32, @intCast(new_len));
    return node.text.slice(doc.source);
}

fn normalizeWhitespaceInPlace(bytes: []u8) usize {
    var r: usize = 0;
    var w: usize = 0;
    var pending_space = false;
    var wrote_any = false;

    while (r < bytes.len) : (r += 1) {
        const c = bytes[r];
        if (tables.WhitespaceTable[c]) {
            pending_space = true;
            continue;
        }

        if (pending_space and wrote_any) {
            bytes[w] = ' ';
            w += 1;
        }
        bytes[w] = c;
        w += 1;
        pending_space = false;
        wrote_any = true;
    }

    return w;
}

const WhitespaceNormState = struct {
    pending_space: bool = false,
    wrote_any: bool = false,
};

fn appendNormalizedSegment(out: *std.ArrayList(u8), alloc: std.mem.Allocator, seg: []const u8, state: *WhitespaceNormState) !void {
    for (seg) |c| {
        if (tables.WhitespaceTable[c]) {
            state.pending_space = true;
            continue;
        }

        if (state.pending_space and state.wrote_any) {
            try out.append(alloc, ' ');
        }
        try out.append(alloc, c);
        state.pending_space = false;
        state.wrote_any = true;
    }
}
