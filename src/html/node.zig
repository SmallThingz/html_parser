const std = @import("std");
const tables = @import("tables.zig");
const entities = @import("entities.zig");
const attr_inline = @import("attr_inline.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);

pub const TextOptions = struct {
    normalize_whitespace: bool = true,
};

pub fn firstChild(comptime Node: type, self: Node) ?Node {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.first_child;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].next_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return self.doc.nodeAt(idx);
    }
    return null;
}

pub fn lastChild(comptime Node: type, self: Node) ?Node {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.last_child;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return self.doc.nodeAt(idx);
    }
    return null;
}

pub fn nextSibling(comptime Node: type, self: Node) ?Node {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.next_sibling;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].next_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return self.doc.nodeAt(idx);
    }
    return null;
}

pub fn prevSibling(comptime Node: type, self: Node) ?Node {
    const raw = &self.doc.nodes.items[self.index];
    var idx = raw.prev_sibling;
    while (idx != InvalidIndex) : (idx = self.doc.nodes.items[idx].prev_sibling) {
        const c = &self.doc.nodes.items[idx];
        if (c.kind == .element) return self.doc.nodeAt(idx);
    }
    return null;
}

pub fn parentNode(comptime Node: type, self: Node) ?Node {
    const raw = &self.doc.nodes.items[self.index];
    if (!self.doc.store_parent_pointers) return null;
    if (raw.parent == InvalidIndex or raw.parent == 0) return null;
    return self.doc.nodeAt(raw.parent);
}

pub fn children(comptime Node: type, self: Node) []const u32 {
    // Child views are built once and then borrowed on every call.
    self.doc.ensureChildViewsBuilt();
    const raw = &self.doc.nodes.items[self.index];
    const start: usize = @intCast(raw.child_view_start);
    const end: usize = @intCast(raw.child_view_start + raw.child_view_len);
    return self.doc.child_indexes.items[start..end];
}

pub fn getAttributeValue(comptime Node: type, self: Node, name: []const u8) ?[]const u8 {
    const raw = &self.doc.nodes.items[self.index];
    return attr_inline.getAttrValue(self.doc, raw, name);
}

pub fn innerText(comptime Node: type, self: Node, arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
    const doc = self.doc;
    const raw = &doc.nodes.items[self.index];

    if (raw.kind == .text) {
        const mut_node = &doc.nodes.items[self.index];
        _ = decodeTextNode(mut_node, doc);
        if (!opts.normalize_whitespace) return mut_node.text.slice(doc.source);
        return normalizeTextNodeInPlace(mut_node, doc);
    }

    var first_idx: u32 = InvalidIndex;
    var count: usize = 0;

    var idx = self.index + 1;
    while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
        const node = &doc.nodes.items[idx];
        if (node.kind != .text) continue;
        count += 1;
        _ = decodeTextNode(node, doc);
        if (count == 1) first_idx = idx;
    }

    if (count == 0) return "";
    if (count == 1) {
        // Single text-node result can stay fully borrowed/non-alloc.
        const only = &doc.nodes.items[first_idx];
        if (!opts.normalize_whitespace) return only.text.slice(doc.source);
        return normalizeTextNodeInPlace(only, doc);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena_alloc);

    if (!opts.normalize_whitespace) {
        idx = self.index + 1;
        while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try out.appendSlice(arena_alloc, node.text.slice(doc.source));
        }
    } else {
        var state: WhitespaceNormState = .{};
        idx = self.index + 1;
        while (idx <= raw.subtree_end and idx < doc.nodes.items.len) : (idx += 1) {
            const node = &doc.nodes.items[idx];
            if (node.kind != .text) continue;
            try appendNormalizedSegment(&out, arena_alloc, node.text.slice(doc.source), &state);
        }
    }

    if (out.items.len == 0) return "";
    return try out.toOwnedSlice(arena_alloc);
}

fn decodeTextNode(noalias node: anytype, doc: anytype) []const u8 {
    const text_mut = node.text.sliceMut(doc.source);
    const new_len = entities.decodeInPlaceIfEntity(text_mut);
    node.text.end = node.text.start + @as(u32, @intCast(new_len));
    return node.text.slice(doc.source);
}

fn normalizeTextNodeInPlace(noalias node: anytype, doc: anytype) []const u8 {
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

fn appendNormalizedSegment(noalias out: *std.ArrayList(u8), alloc: std.mem.Allocator, seg: []const u8, noalias state: *WhitespaceNormState) !void {
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
