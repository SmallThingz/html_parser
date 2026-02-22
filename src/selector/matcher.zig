const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);

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

    if (comp.has_tag != 0) {
        const tag = comp.tag.slice(selector.source);
        if (!tables.eqlIgnoreCaseAscii(node.name.slice(doc.source), tag)) return false;
    }

    if (comp.has_id != 0) {
        const id = comp.id.slice(selector.source);
        const value = getAttrValue(doc, node, "id") orelse return false;
        if (!std.mem.eql(u8, value, id)) return false;
    }

    var class_i: u32 = 0;
    while (class_i < comp.class_len) : (class_i += 1) {
        const cls = selector.classes[comp.class_start + class_i].slice(selector.source);
        if (!hasClass(doc, node, cls)) return false;
    }

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matchesAttrSelector(doc, node, selector.source, attr_sel)) return false;
    }

    var pseudo_i: u32 = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matchesPseudo(doc, node_index, pseudo)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(doc: anytype, node: anytype, selector_source: []const u8, item: ast.NotSimple) bool {
    return switch (item.kind) {
        .tag => tables.eqlIgnoreCaseAscii(node.name.slice(doc.source), item.text.slice(selector_source)),
        .id => blk: {
            const id = item.text.slice(selector_source);
            const v = getAttrValue(doc, node, "id") orelse break :blk false;
            break :blk std.mem.eql(u8, v, id);
        },
        .class => hasClass(doc, node, item.text.slice(selector_source)),
        .attr => matchesAttrSelector(doc, node, selector_source, item.attr),
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

fn matchesAttrSelector(doc: anytype, node: anytype, selector_source: []const u8, sel: ast.AttrSelector) bool {
    const name = sel.name.slice(selector_source);
    const raw = getAttrValue(doc, node, name) orelse return false;
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
    var it = std.mem.tokenizeScalar(u8, value, ' ');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, token)) return true;
    }
    return false;
}

fn hasClass(doc: anytype, node: anytype, class_name: []const u8) bool {
    const class_attr = getAttrValue(doc, node, "class") orelse return false;
    return tokenIncludes(class_attr, class_name);
}

fn getAttrValue(doc: anytype, node: anytype, name: []const u8) ?[]const u8 {
    var i: u32 = node.attr_start;
    const end = node.attr_start + node.attr_len;
    while (i < end) : (i += 1) {
        const attr = doc.attrs.items[i];
        if (tables.eqlIgnoreCaseAscii(attr.name.slice(doc.source), name)) {
            return attr.value.slice(doc.source);
        }
    }
    return null;
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
