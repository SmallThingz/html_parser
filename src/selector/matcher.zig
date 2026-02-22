const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr_inline = @import("../html/attr_inline.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);
const MaxProbeEntries: usize = 24;
const HashId: u32 = hashIgnoreCaseAscii("id");
const HashClass: u32 = hashIgnoreCaseAscii("class");

pub fn queryOne(comptime Doc: type, comptime NodeT: type, doc: *const Doc, selector: ast.Selector, scope_root: u32) ?*const NodeT {
    const start: u32 = if (scope_root == InvalidIndex) 1 else scope_root + 1;
    const end_excl: u32 = if (scope_root == InvalidIndex)
        @as(u32, @intCast(doc.nodes.items.len))
    else
        doc.nodes.items[scope_root].subtree_end + 1;

    var i = start;
    while (i < end_excl and i < doc.nodes.items.len) : (i += 1) {
        const node: *const NodeT = &doc.nodes.items[i];
        if (node.kind != .element) continue;
        if (matchesSelectorAt(Doc, doc, selector, i)) return node;
    }

    return null;
}

pub fn matchesSelectorAt(comptime Doc: type, doc: *const Doc, selector: ast.Selector, node_index: u32) bool {
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const rightmost = group.compound_len - 1;
        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, node_index)) return true;
    }
    return false;
}

fn matchGroupFromRight(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, rel_index: u32, node_index: u32) bool {
    const comp_abs: usize = @intCast(group.compound_start + rel_index);
    const comp = selector.compounds[comp_abs];

    if (!matchesCompound(Doc, doc, selector, comp, node_index)) return false;
    if (rel_index == 0) return true;

    switch (comp.combinator) {
        .child => {
            const p = parentElement(doc, node_index) orelse return false;
            return matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, p);
        },
        .descendant => {
            var p = parentElement(doc, node_index);
            while (p) |idx| {
                if (matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, idx)) return true;
                p = parentElement(doc, idx);
            }
            return false;
        },
        .adjacent => {
            const prev = prevElementSibling(doc, node_index) orelse return false;
            return matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, prev);
        },
        .sibling => {
            var prev = prevElementSibling(doc, node_index);
            while (prev) |idx| {
                if (matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, idx)) return true;
                prev = prevElementSibling(doc, idx);
            }
            return false;
        },
        .none => return false,
    }
}

fn matchesCompound(comptime Doc: type, doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: u32) bool {
    const node = &doc.nodes.items[node_index];
    if (node.kind != .element) return false;
    // Per-node memo for attribute probes inside one compound match.
    // This preserves selector-order short-circuiting while avoiding repeated
    // full attribute traversals for the same name.
    var attr_probe: AttrProbe = .{};

    if (comp.has_tag != 0) {
        const tag = comp.tag.slice(selector.source);
        const tag_hash: tags.TagHashValue = if (comp.tag_hash != 0) @intCast(comp.tag_hash) else tags.hashBytes(tag);
        if (node.tag_hash != tag_hash) return false;
        if (doc.input_was_normalized) {
            if (!std.mem.eql(u8, node.name.slice(doc.source), tag)) return false;
        } else if (!tables.eqlIgnoreCaseAscii(node.name.slice(doc.source), tag)) return false;
    }

    if (comp.has_id != 0) {
        const id = comp.id.slice(selector.source);
        const value = attrValueByHash(doc, node, &attr_probe, "id", HashId) orelse return false;
        if (!std.mem.eql(u8, value, id)) return false;
    }

    if (comp.class_len != 0) {
        const class_attr = attrValueByHash(doc, node, &attr_probe, "class", HashClass) orelse return false;
        if (!hasAllClassesOnePass(selector, comp, class_attr)) return false;
    }

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matchesAttrSelector(doc, node, &attr_probe, selector.source, attr_sel)) return false;
    }

    var pseudo_i: u32 = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matchesPseudo(doc, node_index, pseudo)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, &attr_probe, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(doc: anytype, node: anytype, probe: *AttrProbe, selector_source: []const u8, item: ast.NotSimple) bool {
    return switch (item.kind) {
        .tag => blk: {
            const tag = item.text.slice(selector_source);
            if (doc.input_was_normalized) break :blk std.mem.eql(u8, node.name.slice(doc.source), tag);
            break :blk tables.eqlIgnoreCaseAscii(node.name.slice(doc.source), tag);
        },
        .id => blk: {
            const id = item.text.slice(selector_source);
            const v = attrValueByHash(doc, node, probe, "id", HashId) orelse break :blk false;
            break :blk std.mem.eql(u8, v, id);
        },
        .class => hasClass(doc, node, probe, item.text.slice(selector_source)),
        .attr => matchesAttrSelector(doc, node, probe, selector_source, item.attr),
    };
}

fn matchesPseudo(doc: anytype, node_index: u32, pseudo: ast.Pseudo) bool {
    return switch (pseudo.kind) {
        .first_child => prevElementSibling(doc, node_index) == null,
        .last_child => nextElementSibling(doc, node_index) == null,
        .nth_child => blk: {
            const p = parentElement(doc, node_index) orelse break :blk false;
            var position: usize = 0;
            var child = doc.nodes.items[p].first_child;
            while (child != InvalidIndex) : (child = doc.nodes.items[child].next_sibling) {
                if (doc.nodes.items[child].kind != .element) continue;
                position += 1;
                if (child == node_index) break;
            }
            if (position == 0) break :blk false;
            break :blk pseudo.nth.matches(position);
        },
    };
}

fn matchesAttrSelector(doc: anytype, node: anytype, probe: *AttrProbe, selector_source: []const u8, sel: ast.AttrSelector) bool {
    const name = sel.name.slice(selector_source);
    const name_hash = if (sel.name_hash != 0) sel.name_hash else hashIgnoreCaseAscii(name);
    const raw = attrValueByHash(doc, node, probe, name, name_hash) orelse return false;
    const value = sel.value.slice(selector_source);

    return switch (sel.op) {
        .exists => true,
        .eq => std.mem.eql(u8, raw, value),
        .prefix => std.mem.startsWith(u8, raw, value),
        .suffix => std.mem.endsWith(u8, raw, value),
        .contains => std.mem.indexOf(u8, raw, value) != null,
        .includes => tokenIncludes(raw, value),
        .dash_match => std.mem.eql(u8, raw, value) or (raw.len > value.len and std.mem.startsWith(u8, raw, value) and raw[value.len] == '-'),
    };
}

fn tokenIncludes(value: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;

    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and value[i] == ' ') : (i += 1) {}
        if (i >= value.len) return false;

        const start = i;
        while (i < value.len and value[i] != ' ') : (i += 1) {}
        if (std.mem.eql(u8, value[start..i], token)) return true;
    }
    return false;
}

fn hasClass(doc: anytype, node: anytype, probe: *AttrProbe, class_name: []const u8) bool {
    const class_attr = attrValueByHash(doc, node, probe, "class", HashClass) orelse return false;
    return tokenIncludes(class_attr, class_name);
}

fn hasAllClassesOnePass(selector: ast.Selector, comp: ast.Compound, class_attr: []const u8) bool {
    const class_count = comp.class_len;
    if (class_count == 0) return true;
    if (class_count > 63) {
        var i: u32 = 0;
        while (i < class_count) : (i += 1) {
            const cls = selector.classes[comp.class_start + i].slice(selector.source);
            if (!tokenIncludes(class_attr, cls)) return false;
        }
        return true;
    }

    const target_mask: u64 = (@as(u64, 1) << @as(u6, @intCast(class_count))) - 1;
    var found_mask: u64 = 0;
    var i: usize = 0;
    while (i < class_attr.len) {
        while (i < class_attr.len and class_attr[i] == ' ') : (i += 1) {}
        if (i >= class_attr.len) break;
        const tok_start = i;
        while (i < class_attr.len and class_attr[i] != ' ') : (i += 1) {}
        const tok = class_attr[tok_start..i];

        var j: u32 = 0;
        while (j < class_count) : (j += 1) {
            const bit_shift: u6 = @intCast(j);
            const bit: u64 = @as(u64, 1) << bit_shift;
            if ((found_mask & bit) != 0) continue;
            const cls = selector.classes[comp.class_start + j].slice(selector.source);
            if (std.mem.eql(u8, tok, cls)) {
                found_mask |= bit;
                if (found_mask == target_mask) return true;
                break;
            }
        }
    }
    return found_mask == target_mask;
}

fn attrValue(doc: anytype, node: anytype, probe: *AttrProbe, name: []const u8) ?[]const u8 {
    return attrValueByHash(doc, node, probe, name, hashIgnoreCaseAscii(name));
}

fn attrValueByHash(doc: anytype, node: anytype, probe: *AttrProbe, name: []const u8, name_hash: u32) ?[]const u8 {
    if (findProbeEntry(probe, name, name_hash, doc.input_was_normalized)) |idx| {
        var entry = &probe.entries[idx];
        if (!entry.resolved) {
            entry.value = attr_inline.getAttrValue(doc, node, name);
            entry.resolved = true;
        }
        return entry.value;
    }

    if (!probe.overflow and probe.count < MaxProbeEntries) {
        const value = attr_inline.getAttrValue(doc, node, name);
        const idx = probe.count;
        probe.entries[idx] = .{
            .name = name,
            .name_hash = name_hash,
            .resolved = true,
            .value = value,
        };
        probe.count += 1;
        return value;
    }

    probe.overflow = true;
    // Fallback for very large compounds still stays allocation-free; we simply
    // bypass memoization once the fixed probe budget is exhausted.
    return attr_inline.getAttrValue(doc, node, name);
}

const AttrProbeEntry = struct {
    name: []const u8 = "",
    name_hash: u32 = 0,
    resolved: bool = false,
    value: ?[]const u8 = null,
};

const AttrProbe = struct {
    count: usize = 0,
    overflow: bool = false,
    entries: [MaxProbeEntries]AttrProbeEntry = [_]AttrProbeEntry{.{}} ** MaxProbeEntries,
};

fn findProbeEntry(probe: *const AttrProbe, needle: []const u8, needle_hash: u32, input_was_normalized: bool) ?usize {
    var i: usize = 0;
    while (i < probe.count) : (i += 1) {
        const entry = probe.entries[i];
        if (entry.name_hash != needle_hash) continue;
        if (input_was_normalized) {
            if (std.mem.eql(u8, entry.name, needle)) return i;
            continue;
        }
        if (tables.eqlIgnoreCaseAscii(entry.name, needle)) return i;
    }
    return null;
}

fn hashIgnoreCaseAscii(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |c| {
        h = (h ^ @as(u32, tables.lower(c))) *% 16777619;
    }
    return h;
}

fn parentElement(doc: anytype, node_index: u32) ?u32 {
    const p = doc.nodes.items[node_index].parent;
    if (p == InvalidIndex or p == 0) return null;
    return p;
}

fn prevElementSibling(doc: anytype, node_index: u32) ?u32 {
    var prev = doc.nodes.items[node_index].prev_sibling;
    while (prev != InvalidIndex) : (prev = doc.nodes.items[prev].prev_sibling) {
        if (doc.nodes.items[prev].kind == .element) return prev;
    }
    return null;
}

fn nextElementSibling(doc: anytype, node_index: u32) ?u32 {
    var next = doc.nodes.items[node_index].next_sibling;
    while (next != InvalidIndex) : (next = doc.nodes.items[next].next_sibling) {
        if (doc.nodes.items[next].kind == .element) return next;
    }
    return null;
}
