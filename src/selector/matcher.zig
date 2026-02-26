const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");
const tags = @import("../html/tags.zig");
const attr_inline = @import("../html/attr_inline.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);
const MaxProbeEntries: usize = 24;
const MaxCollectedAttrs: usize = 24;
const HashId: u32 = hashIgnoreCaseAscii("id");
const HashClass: u32 = hashIgnoreCaseAscii("class");
const EnableQueryAccel = true;
const EnableMultiAttrCollect = true;

pub fn queryOneIndex(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, scope_root: u32) ?u32 {
    var best: ?u32 = null;
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const idx = firstMatchForGroup(Doc, doc, selector, group, scope_root) orelse continue;
        if (best == null or idx < best.?) best = idx;
    }
    return best;
}

pub fn matchesSelectorAt(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, node_index: u32, scope_root: u32) bool {
    for (selector.groups) |group| {
        if (group.compound_len == 0) continue;
        const rightmost = group.compound_len - 1;
        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, node_index, scope_root)) return true;
    }
    return false;
}

fn matchGroupFromRight(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, group: ast.Group, rel_index: u32, node_index: u32, scope_root: u32) bool {
    const comp_abs: usize = @intCast(group.compound_start + rel_index);
    const comp = selector.compounds[comp_abs];

    if (!matchesCompound(Doc, doc, selector, comp, node_index)) return false;
    if (rel_index == 0) {
        if (comp.combinator == .none) return true;
        return matchesScopeAnchor(doc, comp.combinator, node_index, scope_root);
    }

    switch (comp.combinator) {
        .child => {
            const p = parentElement(doc, node_index) orelse return false;
            return matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, p, scope_root);
        },
        .descendant => {
            var p = parentElement(doc, node_index);
            while (p) |idx| {
                if (matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, idx, scope_root)) return true;
                p = parentElement(doc, idx);
            }
            return false;
        },
        .adjacent => {
            const prev = prevElementSibling(doc, node_index) orelse return false;
            return matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, prev, scope_root);
        },
        .sibling => {
            var prev = prevElementSibling(doc, node_index);
            while (prev) |idx| {
                if (matchGroupFromRight(Doc, doc, selector, group, rel_index - 1, idx, scope_root)) return true;
                prev = prevElementSibling(doc, idx);
            }
            return false;
        },
        .none => return false,
    }
}

fn firstMatchForGroup(comptime Doc: type, doc: *const Doc, selector: ast.Selector, group: ast.Group, scope_root: u32) ?u32 {
    const rightmost = group.compound_len - 1;
    const comp_abs: usize = @intCast(group.compound_start + rightmost);
    const comp = selector.compounds[comp_abs];

    if (EnableQueryAccel and @hasDecl(Doc, "queryAccelLookupId") and comp.has_id != 0) {
        const id = comp.id.slice(selector.source);
        var used = false;
        if (doc.queryAccelLookupId(id, &used)) |idx| {
            if (inScope(doc, idx, scope_root) and matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) {
                return idx;
            }
            return null;
        }
        if (used) return null;
    }

    if (EnableQueryAccel and @hasDecl(Doc, "queryAccelLookupTag") and comp.has_tag != 0 and comp.tag_hash != 0) {
        var used = false;
        if (doc.queryAccelLookupTag(@intCast(comp.tag_hash), &used)) |candidates| {
            if (scope_root != InvalidIndex) {
                const scope_end = doc.nodes.items[scope_root].subtree_end;
                for (candidates) |idx| {
                    if (idx <= scope_root) continue;
                    if (idx > scope_end) break;
                    if (matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) return idx;
                }
                return null;
            }
            for (candidates) |idx| {
                if (matchGroupFromRight(Doc, doc, selector, group, rightmost, idx, scope_root)) return idx;
            }
            return null;
        }
        if (used) return null;
    }

    const start: u32 = if (scope_root == InvalidIndex) 1 else scope_root + 1;
    const end_excl: u32 = if (scope_root == InvalidIndex)
        @as(u32, @intCast(doc.nodes.items.len))
    else
        doc.nodes.items[scope_root].subtree_end + 1;

    var i = start;
    while (i < end_excl and i < doc.nodes.items.len) : (i += 1) {
        const node = &doc.nodes.items[i];
        if (node.kind != .element) continue;
        if (matchGroupFromRight(Doc, doc, selector, group, rightmost, i, scope_root)) return i;
    }
    return null;
}

fn inScope(doc: anytype, idx: u32, scope_root: u32) bool {
    if (idx == InvalidIndex or idx >= doc.nodes.items.len) return false;
    if (scope_root == InvalidIndex) return idx > 0;
    return idx > scope_root and idx <= doc.nodes.items[scope_root].subtree_end;
}

fn matchesScopeAnchor(doc: anytype, combinator: ast.Combinator, node_index: u32, scope_root: u32) bool {
    if (combinator == .none) return true;

    const anchor: u32 = if (scope_root == InvalidIndex) 0 else scope_root;
    switch (combinator) {
        .child => {
            const p = doc.parentIndex(node_index);
            return p != InvalidIndex and p == anchor;
        },
        .descendant => {
            var p = doc.parentIndex(node_index);
            while (p != InvalidIndex) {
                if (p == anchor) return true;
                if (p == 0) break;
                p = doc.parentIndex(p);
            }
            return false;
        },
        .adjacent => {
            return prevElementSibling(doc, node_index) == anchor;
        },
        .sibling => {
            var prev = prevElementSibling(doc, node_index);
            while (prev) |idx| {
                if (idx == anchor) return true;
                prev = prevElementSibling(doc, idx);
            }
            return false;
        },
        .none => return true,
    }
}

fn matchesCompound(comptime Doc: type, noalias doc: *const Doc, selector: ast.Selector, comp: ast.Compound, node_index: u32) bool {
    const node = &doc.nodes.items[node_index];
    if (node.kind != .element) return false;
    // Per-node memo for attribute probes inside one compound match.
    // This preserves selector-order short-circuiting while avoiding repeated
    // full attribute traversals for the same name.
    var attr_probe: AttrProbe = .{};
    var collected_attrs: CollectedAttrs = .{};
    const use_collected = EnableMultiAttrCollect and prepareCollectedAttrs(selector, comp, &collected_attrs);
    const collected_ptr: ?*CollectedAttrs = if (use_collected) &collected_attrs else null;

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
        const value = attrValueByHashFrom(
            doc,
            node,
            &attr_probe,
            collected_ptr,
            "id",
            HashId,
        ) orelse return false;
        if (!std.mem.eql(u8, value, id)) return false;
    }

    if (comp.class_len != 0) {
        const class_attr = attrValueByHashFrom(
            doc,
            node,
            &attr_probe,
            collected_ptr,
            "class",
            HashClass,
        ) orelse return false;
        if (!hasAllClassesOnePass(selector, comp, class_attr)) return false;
    }

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        if (!matchesAttrSelector(doc, node, &attr_probe, collected_ptr, selector.source, attr_sel)) return false;
    }

    var pseudo_i: u32 = 0;
    while (pseudo_i < comp.pseudo_len) : (pseudo_i += 1) {
        const pseudo = selector.pseudos[comp.pseudo_start + pseudo_i];
        if (!matchesPseudo(doc, node_index, pseudo)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        if (matchesNotSimple(doc, node, &attr_probe, collected_ptr, selector.source, item)) return false;
    }

    return true;
}

fn matchesNotSimple(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    item: ast.NotSimple,
) bool {
    return switch (item.kind) {
        .tag => blk: {
            const tag = item.text.slice(selector_source);
            if (doc.input_was_normalized) break :blk std.mem.eql(u8, node.name.slice(doc.source), tag);
            break :blk tables.eqlIgnoreCaseAscii(node.name.slice(doc.source), tag);
        },
        .id => blk: {
            const id = item.text.slice(selector_source);
            const v = attrValueByHashFrom(doc, node, probe, collected, "id", HashId) orelse break :blk false;
            break :blk std.mem.eql(u8, v, id);
        },
        .class => hasClass(doc, node, probe, collected, item.text.slice(selector_source)),
        .attr => matchesAttrSelector(doc, node, probe, collected, selector_source, item.attr),
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

fn matchesAttrSelector(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    selector_source: []const u8,
    sel: ast.AttrSelector,
) bool {
    const name = sel.name.slice(selector_source);
    const name_hash = if (sel.name_hash != 0) sel.name_hash else hashIgnoreCaseAscii(name);
    const raw = attrValueByHashFrom(doc, node, probe, collected, name, name_hash) orelse return false;
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

fn hasClass(doc: anytype, node: anytype, noalias probe: *AttrProbe, collected: ?*CollectedAttrs, class_name: []const u8) bool {
    const class_attr = attrValueByHashFrom(doc, node, probe, collected, "class", HashClass) orelse return false;
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

fn attrValue(doc: anytype, node: anytype, noalias probe: *AttrProbe, name: []const u8) ?[]const u8 {
    return attrValueByHash(doc, node, probe, name, hashIgnoreCaseAscii(name));
}

fn attrValueByHashFrom(
    doc: anytype,
    node: anytype,
    noalias probe: *AttrProbe,
    collected: ?*CollectedAttrs,
    name: []const u8,
    name_hash: u32,
) ?[]const u8 {
    if (collected) |c| {
        if (findCollectedEntry(c, name, name_hash, doc.input_was_normalized)) |idx| {
            if (c.materialized or c.looked[idx]) return c.values[idx];

            if (c.request_count == 0) {
                const value = attrValueByHash(doc, node, probe, name, name_hash);
                c.values[idx] = value;
                c.looked[idx] = true;
                c.request_count = 1;
                return value;
            }

            attr_inline.collectSelectedValuesByHash(
                doc,
                node,
                c.names[0..c.count],
                c.name_hashes[0..c.count],
                c.values[0..c.count],
                doc.input_was_normalized,
            );
            c.materialized = true;
            var i: usize = 0;
            while (i < c.count) : (i += 1) c.looked[i] = true;
            return c.values[idx];
        }
    }
    return attrValueByHash(doc, node, probe, name, name_hash);
}

fn attrValueByHash(doc: anytype, node: anytype, noalias probe: *AttrProbe, name: []const u8, name_hash: u32) ?[]const u8 {
    if (findProbeEntry(probe, name, name_hash, doc.input_was_normalized)) |idx| {
        return probe.entries[idx].value;
    }

    if (!probe.overflow and probe.count < MaxProbeEntries) {
        const value = attr_inline.getAttrValue(doc, node, name);
        const idx = probe.count;
        probe.entries[idx] = .{
            .name = name,
            .name_hash = name_hash,
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
    value: ?[]const u8 = null,
};

const AttrProbe = struct {
    count: usize = 0,
    overflow: bool = false,
    entries: [MaxProbeEntries]AttrProbeEntry = [_]AttrProbeEntry{.{}} ** MaxProbeEntries,
};

const CollectedAttrs = struct {
    count: usize = 0,
    request_count: u8 = 0,
    materialized: bool = false,
    names: [MaxCollectedAttrs][]const u8 = [_][]const u8{""} ** MaxCollectedAttrs,
    name_hashes: [MaxCollectedAttrs]u32 = [_]u32{0} ** MaxCollectedAttrs,
    values: [MaxCollectedAttrs]?[]const u8 = [_]?[]const u8{null} ** MaxCollectedAttrs,
    looked: [MaxCollectedAttrs]bool = [_]bool{false} ** MaxCollectedAttrs,
};

fn prepareCollectedAttrs(selector: ast.Selector, comp: ast.Compound, out: *CollectedAttrs) bool {
    out.* = .{};

    if (comp.has_id != 0 and !pushCollectedName(out, "id", HashId)) return false;
    if (comp.class_len != 0 and !pushCollectedName(out, "class", HashClass)) return false;

    var attr_i: u32 = 0;
    while (attr_i < comp.attr_len) : (attr_i += 1) {
        const attr_sel = selector.attrs[comp.attr_start + attr_i];
        const name = attr_sel.name.slice(selector.source);
        const hash = if (attr_sel.name_hash != 0) attr_sel.name_hash else hashIgnoreCaseAscii(name);
        if (!pushCollectedName(out, name, hash)) return false;
    }

    var not_i: u32 = 0;
    while (not_i < comp.not_len) : (not_i += 1) {
        const item = selector.not_items[comp.not_start + not_i];
        switch (item.kind) {
            .id => if (!pushCollectedName(out, "id", HashId)) return false,
            .class => if (!pushCollectedName(out, "class", HashClass)) return false,
            .attr => {
                const name = item.attr.name.slice(selector.source);
                const hash = if (item.attr.name_hash != 0) item.attr.name_hash else hashIgnoreCaseAscii(name);
                if (!pushCollectedName(out, name, hash)) return false;
            },
            else => {},
        }
    }

    return out.count >= 2;
}

fn pushCollectedName(out: *CollectedAttrs, name: []const u8, name_hash: u32) bool {
    if (findCollectedEntry(out, name, name_hash, false) != null) return true;
    if (out.count >= MaxCollectedAttrs) return false;
    out.names[out.count] = name;
    out.name_hashes[out.count] = name_hash;
    out.values[out.count] = null;
    out.count += 1;
    return true;
}

fn findCollectedEntry(collected: *const CollectedAttrs, needle: []const u8, needle_hash: u32, input_was_normalized: bool) ?usize {
    var i: usize = 0;
    while (i < collected.count) : (i += 1) {
        if (collected.name_hashes[i] != needle_hash) continue;
        if (input_was_normalized) {
            if (std.mem.eql(u8, collected.names[i], needle)) return i;
            continue;
        }
        if (tables.eqlIgnoreCaseAscii(collected.names[i], needle)) return i;
    }
    return null;
}

fn findProbeEntry(noalias probe: *const AttrProbe, needle: []const u8, needle_hash: u32, input_was_normalized: bool) ?usize {
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
    const p = doc.parentIndex(node_index);
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
