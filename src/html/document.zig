const std = @import("std");
const tables = @import("tables.zig");
const runtime_selector = @import("../selector/runtime.zig");
const ast = @import("../selector/ast.zig");
const matcher = @import("../selector/matcher.zig");
const parser = @import("parser.zig");
const node_api = @import("node.zig");
const tags = @import("tags.zig");

pub const InvalidIndex: u32 = std.math.maxInt(u32);

pub const ParseOptions = struct {
    store_parent_pointers: bool = true,
    normalize_input: bool = true,
    normalize_text_on_parse: bool = false,
    eager_child_views: bool = true,
    eager_attr_empty_rewrite: bool = true,
    turbo_parse: bool = false,
    permissive_recovery: bool = true,
};

pub const TextOptions = node_api.TextOptions;

pub const NodeType = enum(u2) {
    document,
    element,
    text,
};

pub const Span = struct {
    start: u32 = 0,
    end: u32 = 0,

    pub fn len(self: @This()) u32 {
        return self.end - self.start;
    }

    pub fn slice(self: @This(), source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn sliceMut(self: @This(), source: []u8) []u8 {
        return source[self.start..self.end];
    }
};

pub const Node = struct {
    doc: *Document,
    index: u32,
    kind: NodeType,

    name: Span = .{},
    tag_hash: tags.TagHashValue = 0,
    text: Span = .{},

    open_start: u32 = 0,
    open_end: u32 = 0,
    close_start: u32 = 0,
    close_end: u32 = 0,

    // In-place attribute byte range inside the opening tag.
    attr_bytes_start: u32 = 0,
    attr_bytes_end: u32 = 0,

    first_child: u32 = InvalidIndex,
    last_child: u32 = InvalidIndex,
    prev_sibling: u32 = InvalidIndex,
    next_sibling: u32 = InvalidIndex,
    parent: u32 = InvalidIndex,

    child_view_start: u32 = 0,
    child_view_len: u32 = 0,

    subtree_end: u32 = 0,

    pub fn tagName(self: *const @This()) []const u8 {
        return self.name.slice(self.doc.source);
    }

    pub fn innerText(self: *const @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
        return node_api.innerText(@This(), self, arena_alloc, .{});
    }

    pub fn innerTextWithOptions(self: *const @This(), arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
        return node_api.innerText(@This(), self, arena_alloc, opts);
    }

    pub fn getAttributeValue(self: *const @This(), name: []const u8) ?[]const u8 {
        return node_api.getAttributeValue(@This(), self, name);
    }

    pub fn firstChild(self: *const @This()) ?*const @This() {
        return node_api.firstChild(@This(), self);
    }

    pub fn lastChild(self: *const @This()) ?*const @This() {
        return node_api.lastChild(@This(), self);
    }

    pub fn nextSibling(self: *const @This()) ?*const @This() {
        return node_api.nextSibling(@This(), self);
    }

    pub fn prevSibling(self: *const @This()) ?*const @This() {
        return node_api.prevSibling(@This(), self);
    }

    pub fn parentNode(self: *const @This()) ?*const @This() {
        return node_api.parentNode(@This(), self);
    }

    pub fn children(self: *const @This()) []const *const @This() {
        return node_api.children(@This(), self);
    }

    pub fn queryOne(self: *const @This(), comptime selector: []const u8) ?*const @This() {
        const sel = comptime ast.Selector.compile(selector);
        return self.queryOneCompiled(&sel);
    }

    pub fn queryOneCompiled(self: *const @This(), sel: *const ast.Selector) ?*const @This() {
        return matcher.queryOne(Document, @This(), self.doc, sel.*, self.index);
    }

    pub fn queryOneRuntime(self: *const @This(), selector: []const u8) runtime_selector.Error!?*const @This() {
        return self.doc.queryOneRuntimeFrom(selector, self.index);
    }

    pub fn queryAll(self: *const @This(), comptime selector: []const u8) QueryIter {
        const sel = comptime ast.Selector.compile(selector);
        return self.queryAllCompiled(&sel);
    }

    pub fn queryAllCompiled(self: *const @This(), sel: *const ast.Selector) QueryIter {
        return .{ .doc = self.doc, .selector = sel.*, .scope_root = self.index, .next_index = self.index + 1 };
    }

    pub fn queryAllRuntime(self: *const @This(), selector: []const u8) runtime_selector.Error!QueryIter {
        return self.doc.queryAllRuntimeFrom(selector, self.index);
    }
};

pub const QueryIter = struct {
    doc: *const Document,
    selector: ast.Selector,
    scope_root: u32 = InvalidIndex,
    next_index: u32 = 1,
    runtime_generation: u64 = 0,

    pub fn next(self: *QueryIter) ?*const Node {
        if (self.runtime_generation != 0 and self.runtime_generation != self.doc.query_all_generation) {
            return null;
        }

        while (self.next_index < self.doc.nodes.items.len) : (self.next_index += 1) {
            const idx = self.next_index;

            if (self.scope_root != InvalidIndex) {
                const root = &self.doc.nodes.items[self.scope_root];
                if (idx <= self.scope_root or idx > root.subtree_end) continue;
            }

            const node = &self.doc.nodes.items[idx];
            if (node.kind != .element) continue;

            if (matcher.matchesSelectorAt(Document, self.doc, self.selector, idx)) {
                self.next_index += 1;
                return node;
            }
        }
        return null;
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    source: []u8 = &[_]u8{},
    store_parent_pointers: bool = true,
    child_views_ready: bool = false,
    input_was_normalized: bool = true,

    nodes: std.ArrayListUnmanaged(Node) = .{},
    child_ptrs: std.ArrayListUnmanaged(*const Node) = .{},
    parse_stack: std.ArrayListUnmanaged(u32) = .{},

    query_one_arena: std.heap.ArenaAllocator,
    query_all_arena: std.heap.ArenaAllocator,
    query_all_generation: u64 = 1,
    query_one_cached_selector: []const u8 = "",
    query_one_cached_compiled: ?ast.Selector = null,
    query_one_cache_valid: bool = false,
    query_all_cached_selector: []const u8 = "",
    query_all_cached_compiled: ?ast.Selector = null,
    query_all_cache_valid: bool = false,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .query_one_arena = std.heap.ArenaAllocator.init(allocator),
            .query_all_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Document) void {
        self.nodes.deinit(self.allocator);
        self.child_ptrs.deinit(self.allocator);
        self.parse_stack.deinit(self.allocator);
        self.query_one_arena.deinit();
        self.query_all_arena.deinit();
    }

    pub fn clear(self: *Document) void {
        self.nodes.clearRetainingCapacity();
        self.child_ptrs.clearRetainingCapacity();
        self.parse_stack.clearRetainingCapacity();
        self.child_views_ready = false;
        _ = self.query_one_arena.reset(.retain_capacity);
        _ = self.query_all_arena.reset(.retain_capacity);
        self.invalidateRuntimeSelectorCaches();
        self.query_all_generation +%= 1;
        if (self.query_all_generation == 0) self.query_all_generation = 1;
    }

    pub fn parse(self: *Document, input: []u8, comptime opts: ParseOptions) !void {
        self.clear();
        self.source = input;
        self.store_parent_pointers = opts.store_parent_pointers;
        self.input_was_normalized = opts.normalize_input;
        try parser.parseInto(Document, self, input, opts);
        if (opts.eager_child_views) {
            try self.buildChildViews();
        }
    }

    pub fn queryOne(self: *const Document, comptime selector: []const u8) ?*const Node {
        const sel = comptime ast.Selector.compile(selector);
        return self.queryOneCompiled(&sel);
    }

    pub fn queryOneCompiled(self: *const Document, sel: *const ast.Selector) ?*const Node {
        return matcher.queryOne(Document, Node, self, sel.*, InvalidIndex);
    }

    pub fn queryOneRuntime(self: *const Document, selector: []const u8) runtime_selector.Error!?*const Node {
        return self.queryOneRuntimeFrom(selector, InvalidIndex);
    }

    fn queryOneRuntimeFrom(self: *const Document, selector: []const u8, scope_root: u32) runtime_selector.Error!?*const Node {
        const mut_self: *Document = @constCast(self);
        const sel = try mut_self.getOrCompileQueryOneSelector(selector);
        if (scope_root == InvalidIndex) return self.queryOneCompiled(&sel);
        return matcher.queryOne(Document, Node, self, sel, scope_root);
    }

    pub fn queryAll(self: *const Document, comptime selector: []const u8) QueryIter {
        const sel = comptime ast.Selector.compile(selector);
        return self.queryAllCompiled(&sel);
    }

    pub fn queryAllCompiled(self: *const Document, sel: *const ast.Selector) QueryIter {
        return .{ .doc = self, .selector = sel.*, .scope_root = InvalidIndex, .next_index = 1 };
    }

    pub fn queryAllRuntime(self: *const Document, selector: []const u8) runtime_selector.Error!QueryIter {
        return self.queryAllRuntimeFrom(selector, InvalidIndex);
    }

    fn queryAllRuntimeFrom(self: *const Document, selector: []const u8, scope_root: u32) runtime_selector.Error!QueryIter {
        const mut_self: *Document = @constCast(self);
        mut_self.query_all_generation +%= 1;
        if (mut_self.query_all_generation == 0) mut_self.query_all_generation = 1;

        const sel = try mut_self.getOrCompileQueryAllSelector(selector);
        var out = if (scope_root == InvalidIndex)
            self.queryAllCompiled(&sel)
        else
            QueryIter{
                .doc = self,
                .selector = sel,
                .scope_root = scope_root,
                .next_index = scope_root + 1,
            };
        out.runtime_generation = mut_self.query_all_generation;
        return out;
    }

    pub fn html(self: *const Document) ?*const Node {
        return self.findFirstTag("html");
    }

    pub fn head(self: *const Document) ?*const Node {
        return self.findFirstTag("head");
    }

    pub fn body(self: *const Document) ?*const Node {
        return self.findFirstTag("body");
    }

    pub fn findFirstTag(self: *const Document, name: []const u8) ?*const Node {
        var i: usize = 1;
        while (i < self.nodes.items.len) : (i += 1) {
            const n = &self.nodes.items[i];
            if (n.kind != .element) continue;
            if (self.input_was_normalized) {
                if (std.mem.eql(u8, n.name.slice(self.source), name)) return n;
            } else if (tables.eqlIgnoreCaseAscii(n.name.slice(self.source), name)) return n;
        }
        return null;
    }

    pub fn nodeAt(self: *const Document, idx: u32) ?*const Node {
        if (idx == InvalidIndex or idx >= self.nodes.items.len) return null;
        return &self.nodes.items[idx];
    }

    fn invalidateRuntimeSelectorCaches(self: *Document) void {
        self.query_one_cache_valid = false;
        self.query_one_cached_selector = "";
        self.query_one_cached_compiled = null;
        self.query_all_cache_valid = false;
        self.query_all_cached_selector = "";
        self.query_all_cached_compiled = null;
    }

    fn getOrCompileQueryOneSelector(self: *Document, selector: []const u8) runtime_selector.Error!ast.Selector {
        if (self.query_one_cache_valid and std.mem.eql(u8, self.query_one_cached_selector, selector)) {
            return self.query_one_cached_compiled.?;
        }

        _ = self.query_one_arena.reset(.retain_capacity);
        const sel = try ast.Selector.compileRuntime(self.query_one_arena.allocator(), selector);
        self.query_one_cached_selector = sel.source;
        self.query_one_cached_compiled = sel;
        self.query_one_cache_valid = true;
        return sel;
    }

    fn getOrCompileQueryAllSelector(self: *Document, selector: []const u8) runtime_selector.Error!ast.Selector {
        if (self.query_all_cache_valid and std.mem.eql(u8, self.query_all_cached_selector, selector)) {
            return self.query_all_cached_compiled.?;
        }

        _ = self.query_all_arena.reset(.retain_capacity);
        const sel = try ast.Selector.compileRuntime(self.query_all_arena.allocator(), selector);
        self.query_all_cached_selector = sel.source;
        self.query_all_cached_compiled = sel;
        self.query_all_cache_valid = true;
        return sel;
    }

    pub fn ensureChildViewsBuilt(self: *Document) void {
        if (self.child_views_ready) return;
        self.buildChildViews() catch @panic("out of memory building child views");
    }

    fn buildChildViews(self: *Document) !void {
        const alloc = self.allocator;
        self.child_ptrs.clearRetainingCapacity();
        const child_ptr_count = if (self.nodes.items.len > 0) self.nodes.items.len - 1 else 0;
        try self.child_ptrs.ensureTotalCapacity(alloc, child_ptr_count);

        var i: u32 = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            var n = &self.nodes.items[i];
            n.child_view_start = @intCast(self.child_ptrs.items.len);
            n.child_view_len = 0;

            var child = n.first_child;
            while (child != InvalidIndex) {
                self.child_ptrs.appendAssumeCapacity(&self.nodes.items[child]);
                n.child_view_len += 1;
                child = self.nodes.items[child].next_sibling;
            }
        }

        self.child_views_ready = true;
    }
};

fn assertNodeTypeLayouts() void {
    _ = @sizeOf(Node);
}

fn expectIterIds(iter: *QueryIter, expected_ids: []const []const u8) !void {
    var i: usize = 0;
    while (iter.next()) |node| {
        if (i >= expected_ids.len) return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[i], id);
        i += 1;
    }
    try std.testing.expectEqual(expected_ids.len, i);
}

fn expectDocQueryComptime(doc: *const Document, comptime selector: []const u8, expected_ids: []const []const u8) !void {
    var it = doc.queryAll(selector);
    try expectIterIds(&it, expected_ids);

    const first = doc.queryOne(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectDocQueryRuntime(doc: *const Document, selector: []const u8, expected_ids: []const []const u8) !void {
    var it = try doc.queryAllRuntime(selector);
    try expectIterIds(&it, expected_ids);

    const first = try doc.queryOneRuntime(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectNodeQueryComptime(scope: *const Node, comptime selector: []const u8, expected_ids: []const []const u8) !void {
    var it = scope.queryAll(selector);
    try expectIterIds(&it, expected_ids);

    const first = scope.queryOne(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

fn expectNodeQueryRuntime(scope: *const Node, selector: []const u8, expected_ids: []const []const u8) !void {
    var it = try scope.queryAllRuntime(selector);
    try expectIterIds(&it, expected_ids);

    const first = try scope.queryOneRuntime(selector);
    if (expected_ids.len == 0) {
        try std.testing.expect(first == null);
    } else {
        const node = first orelse return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_ids[0], id);
    }
}

const selector_fixture_html =
    "<html><body><div id='root'>" ++
    "<ul id='list'>" ++
    "<li id='li1' class='item a' data-k='v' data-prefix='prelude' data-suffix='trail-end' data-sub='in-middle' data-words='alpha beta gamma' lang='en-US'><span id='name1' class='name'>one</span></li>" ++
    "<li id='li2' class='item b' data-k='v2' data-prefix='presto' data-suffix='mid-end' data-sub='middle' data-words='beta delta' lang='en'><span id='name2' class='name'>two</span></li>" ++
    "<li id='li3' class='item c skip' data-k='x' data-prefix='nop' data-suffix='tail' data-sub='zzz' data-words='omega' lang='fr'><span id='name3' class='name'>three</span></li>" ++
    "</ul>" ++
    "<div id='sibs'>" ++
    "<a id='a1' class='link'></a>" ++
    "<a id='a2' class='link hot'></a>" ++
    "<span id='after_a2' class='marker'></span>" ++
    "<a id='a3' class='link'></a>" ++
    "</div>" ++
    "</div></body></html>";

test "document parse + query basics" {
    assertNodeTypeLayouts();

    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<html><head><title>A</title></head><body><div id='x' class='a b'>ok</div><p>n</p></body></html>".*;
    try doc.parse(&html, .{});

    const one = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", one.tagName());

    var it = doc.queryAll("body > *");
    try std.testing.expect(it.next() != null);
}

test "runtime queryAll iterator is stable across queryOneRuntime calls" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='x'></span></div>".*;
    try doc.parse(&html, .{});

    var it = try doc.queryAllRuntime("span.x");

    // This uses a different arena and must not invalidate `it`.
    _ = try doc.queryOneRuntime("div");

    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "runtime queryAll iterator is invalidated by a newer runtime queryAll call" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div><span class='x'></span><span class='y'></span></div>".*;
    try doc.parse(&html, .{});

    var old_it = try doc.queryAllRuntime("span.x");
    var new_it = try doc.queryAllRuntime("span.y");

    try std.testing.expect(old_it.next() == null);
    try std.testing.expect(new_it.next() != null);
    try std.testing.expect(new_it.next() == null);
}

test "raw text element metadata remains valid after child append growth" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>const x = 1;</script><div>ok</div>".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.close_start > script.open_end);
    try std.testing.expect(script.subtree_end > script.index);

    const text_node = doc.nodes.items[script.index + 1];
    try std.testing.expect(text_node.kind == .text);
    try std.testing.expectEqualStrings("const x = 1;", text_node.text.slice(doc.source));

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;
    try std.testing.expect(div.index > script.subtree_end);
}

test "query results matrix (comptime selectors)" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html, .{});

    try expectDocQueryComptime(&doc, "li", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "#li2", &.{"li2"});
    try expectDocQueryComptime(&doc, ".item", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "li, .item", &.{ "li1", "li2", "li3" });

    try expectDocQueryComptime(&doc, "[data-k]", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "[data-k=v]", &.{"li1"});
    try expectDocQueryComptime(&doc, "[data-prefix^=pre]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-suffix$=end]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-sub*=middle]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[data-words~=beta]", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "[lang|=en]", &.{ "li1", "li2" });

    try expectDocQueryComptime(&doc, "ul > li", &.{ "li1", "li2", "li3" });
    try expectDocQueryComptime(&doc, "ul li > span.name", &.{ "name1", "name2", "name3" });
    try expectDocQueryComptime(&doc, "li + li", &.{ "li2", "li3" });
    try expectDocQueryComptime(&doc, "li ~ li", &.{ "li2", "li3" });
    try expectDocQueryComptime(&doc, "a.link + span.marker", &.{"after_a2"});
    try expectDocQueryComptime(&doc, "a.hot ~ a.link", &.{"a3"});

    try expectDocQueryComptime(&doc, "li:first-child", &.{"li1"});
    try expectDocQueryComptime(&doc, "li:last-child", &.{"li3"});
    try expectDocQueryComptime(&doc, "li:nth-child(2)", &.{"li2"});
    try expectDocQueryComptime(&doc, "li:nth-child(2n+1)", &.{ "li1", "li3" });
    try expectDocQueryComptime(&doc, "li:not(.skip)", &.{ "li1", "li2" });
    try expectDocQueryComptime(&doc, "li:not([data-k=x])", &.{ "li1", "li2" });

    try expectDocQueryComptime(&doc, "li#li1, li#li3", &.{ "li1", "li3" });
    try expectDocQueryComptime(&doc, ".does-not-exist", &.{});
}

test "query results matrix (runtime selectors)" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html, .{});

    try expectDocQueryRuntime(&doc, "li", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "#li2", &.{"li2"});
    try expectDocQueryRuntime(&doc, ".item", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "li, .item", &.{ "li1", "li2", "li3" });

    try expectDocQueryRuntime(&doc, "[data-k]", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "[data-k=v]", &.{"li1"});
    try expectDocQueryRuntime(&doc, "[data-prefix^=pre]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-suffix$=end]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-sub*=middle]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[data-words~=beta]", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "[lang|=en]", &.{ "li1", "li2" });

    try expectDocQueryRuntime(&doc, "ul > li", &.{ "li1", "li2", "li3" });
    try expectDocQueryRuntime(&doc, "ul li > span.name", &.{ "name1", "name2", "name3" });
    try expectDocQueryRuntime(&doc, "li + li", &.{ "li2", "li3" });
    try expectDocQueryRuntime(&doc, "li ~ li", &.{ "li2", "li3" });
    try expectDocQueryRuntime(&doc, "a.link + span.marker", &.{"after_a2"});
    try expectDocQueryRuntime(&doc, "a.hot ~ a.link", &.{"a3"});

    try expectDocQueryRuntime(&doc, "li:first-child", &.{"li1"});
    try expectDocQueryRuntime(&doc, "li:last-child", &.{"li3"});
    try expectDocQueryRuntime(&doc, "li:nth-child(2)", &.{"li2"});
    try expectDocQueryRuntime(&doc, "li:nth-child(2n+1)", &.{ "li1", "li3" });
    try expectDocQueryRuntime(&doc, "li:not(.skip)", &.{ "li1", "li2" });
    try expectDocQueryRuntime(&doc, "li:not([data-k=x])", &.{ "li1", "li2" });

    try expectDocQueryRuntime(&doc, "li#li1, li#li3", &.{ "li1", "li3" });
    try expectDocQueryRuntime(&doc, ".does-not-exist", &.{});
}

test "node-scoped queries return complete descendants only" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html, .{});

    const list = doc.queryOne("#list") orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(list, "li", &.{ "li1", "li2", "li3" });
    try expectNodeQueryComptime(list, "span.name", &.{ "name1", "name2", "name3" });
    try expectNodeQueryRuntime(list, "li:not(.skip)", &.{ "li1", "li2" });

    const sibs = doc.queryOne("#sibs") orelse return error.TestUnexpectedResult;
    try expectNodeQueryComptime(sibs, "a.link", &.{ "a1", "a2", "a3" });
    try expectNodeQueryRuntime(sibs, "a + span.marker", &.{"after_a2"});
    try expectNodeQueryRuntime(sibs, "li", &.{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "a.link");
    var it = sibs.queryAllCompiled(&sel);
    try expectIterIds(&it, &.{ "a1", "a2", "a3" });
    const first = sibs.queryOneCompiled(&sel) orelse return error.TestUnexpectedResult;
    const id = first.getAttributeValue("id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", id);
}

test "innerText normalizes whitespace by default" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("alpha beta gamma", text);
}

test "innerText can return non-normalized text" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha \n\t beta   gamma  </div>".*;
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("  alpha \n\t beta   gamma  ", text);
}

test "innerText normalization is applied across text-node boundaries" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>A <b></b>   B</div>".*;
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("A B", text);
}

test "parse-time text normalization is off by default and query-time normalization still works" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node.kind == .text);
    try std.testing.expectEqualStrings("  alpha  &amp;   beta  ", text_node.text.slice(doc.source));

    const raw = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("  alpha  &   beta  ", raw);

    const normalized = try node.innerText(arena.allocator());
    try std.testing.expectEqualStrings("alpha & beta", normalized);
}

test "parse-time text normalization option normalizes text nodes during parse" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var html = "<div id='x'>  alpha  &amp;   beta  </div>".*;
    try doc.parse(&html, .{ .normalize_text_on_parse = true });

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const text_node = doc.nodes.items[node.index + 1];
    try std.testing.expect(text_node.kind == .text);
    try std.testing.expectEqualStrings("alpha & beta", text_node.text.slice(doc.source));

    const raw = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expectEqualStrings("alpha & beta", raw);
}

test "inplace attribute parser rewrites explicit empty assignment to name-only" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' b a=   ></div>".*;
    try doc.parse(&html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const a = node.getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const b = node.getAttributeValue("b") orelse return error.TestUnexpectedResult;
    const c = node.getAttributeValue("c");
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(usize, 0), b.len);
    try std.testing.expect(c == null);

    try std.testing.expect(doc.queryOne("div[a]") != null);
    try std.testing.expect(doc.queryOne("div[b]") != null);
    try std.testing.expect(doc.queryOne("div[c]") == null);
}

test "inplace attr lazy parse updates state markers and supports selector-triggered parsing" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' q='&amp;z' n=a&amp;b></div>".*;
    try doc.parse(&html, .{});

    const by_selector = try doc.queryOneRuntime("div[q='&z'][n='a&b']");
    try std.testing.expect(by_selector != null);

    const node = by_selector orelse return error.TestUnexpectedResult;
    const q = node.getAttributeValue("q") orelse return error.TestUnexpectedResult;
    const n = node.getAttributeValue("n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("&z", q);
    try std.testing.expectEqualStrings("a&b", n);

    const span = doc.source[node.attr_bytes_start..node.attr_bytes_end];
    const q_marker = [_]u8{ 'q', 0, 0 };
    const q_pos = std.mem.indexOf(u8, span, &q_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(q_pos < span.len);

    const n_marker = [_]u8{ 'n', 0 };
    const n_pos = std.mem.indexOf(u8, span, &n_marker) orelse return error.TestUnexpectedResult;
    try std.testing.expect(n_pos + 2 <= span.len);
    try std.testing.expect(span[n_pos + 1] == 0);
    try std.testing.expect(span[n_pos + 2] != 0);
}

test "attribute matching short-circuits and does not parse later attrs on early failure" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' href='/local' class='button'></div>".*;
    try doc.parse(&html, .{});

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sel = try ast.Selector.compileRuntime(arena.allocator(), "div[href^=https][class*=button]");
    try std.testing.expect(doc.queryOneCompiled(&sel) == null);
    try std.testing.expect((try doc.queryOneRuntime("div[href^=https][class*=button]")) == null);

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const span = doc.source[node.attr_bytes_start..node.attr_bytes_end];
    const class_pos = std.mem.indexOf(u8, span, "class") orelse return error.TestUnexpectedResult;
    const marker_pos = class_pos + "class".len;
    try std.testing.expect(marker_pos < span.len);
    try std.testing.expectEqual(@as(u8, '='), span[marker_pos]);
}

test "inplace extended skip metadata preserves traversal for following attributes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(alloc);
    try builder.appendSlice(alloc, "<div id='x' a='");
    var i: usize = 0;
    while (i < 320) : (i += 1) {
        try builder.appendSlice(alloc, "&amp;");
    }
    try builder.appendSlice(alloc, "' b='ok'></div>");

    const html = try builder.toOwnedSlice(alloc);
    defer alloc.free(html);

    try doc.parse(html, .{});

    const node = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    const a = node.getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 320), a.len);
    for (a) |c| try std.testing.expect(c == '&');

    const b = node.getAttributeValue("b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ok", b);
}

test "compiled selector APIs are equivalent to runtime string wrappers" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = selector_fixture_html.*;
    try doc.parse(&html, .{});

    const cases = [_]struct { selector: []const u8, expected: []const []const u8 }{
        .{ .selector = "li", .expected = &.{ "li1", "li2", "li3" } },
        .{ .selector = "[data-k=v]", .expected = &.{"li1"} },
        .{ .selector = "[data-prefix^=pre]", .expected = &.{ "li1", "li2" } },
        .{ .selector = "li:not([data-k=x])", .expected = &.{ "li1", "li2" } },
        .{ .selector = "ul li > span.name", .expected = &.{ "name1", "name2", "name3" } },
        .{ .selector = "a.hot ~ a.link", .expected = &.{"a3"} },
        .{ .selector = "a[href^=https][class*=button]:not(.missing)", .expected = &.{} },
        .{ .selector = "a[href^=https][class*=nav]:not(.missing)", .expected = &.{} },
    };

    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const sel = try ast.Selector.compileRuntime(arena.allocator(), case.selector);
        try expectDocQueryRuntime(&doc, case.selector, case.expected);

        var it = doc.queryAllCompiled(&sel);
        try expectIterIds(&it, case.expected);
        const first = doc.queryOneCompiled(&sel);
        if (case.expected.len == 0) {
            try std.testing.expect(first == null);
        } else {
            const node = first orelse return error.TestUnexpectedResult;
            const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(case.expected[0], id);
        }
    }
}

test "runtime query selector caches are invalidated on parse and clear" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div class='x'></div>".*;
    try doc.parse(&html_a, .{});

    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);
    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);

    var html_b = "<section class='x'></section>".*;
    try doc.parse(&html_b, .{});
    try std.testing.expect((try doc.queryOneRuntime("div.x")) == null);

    doc.clear();
    var html_c = "<div class='x'></div>".*;
    try doc.parse(&html_c, .{});
    try std.testing.expect((try doc.queryOneRuntime("div.x")) != null);
}

test "raw-text close handles mixed-case end tag and embedded < bytes" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>if (a < b) { x = \"<tag>\"; }</ScRiPt   ><div id='after'></div>".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    const after = doc.queryOne("div#after") orelse return error.TestUnexpectedResult;
    try std.testing.expect(script.close_end <= after.open_start);
}

test "raw-text unterminated tail keeps element open to end of input" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>const a = 1; <div>still script".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(html.len)), script.close_start);
    try std.testing.expectEqual(@as(u32, @intCast(html.len)), script.close_end);
}

test "optional-close p/li/td-th/dt-dd/head-body preserve expected query semantics" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = ("<html><head><title>x</title><body>" ++
        "<p id='p1'>a<div id='d1'></div>" ++
        "<ul><li id='li1'>x<li id='li2'>y</ul>" ++
        "<dl><dt id='dt1'>a<dd id='dd1'>b<dt id='dt2'>c</dl>" ++
        "<table><tr><td id='td1'>1<th id='th1'>2<td id='td2'>3</tr></table>" ++
        "</body></html>").*;
    try doc.parse(&html, .{});

    try std.testing.expect(doc.queryOne("#p1 + #d1") != null);
    try std.testing.expect(doc.queryOne("#li1 + #li2") != null);
    try std.testing.expect(doc.queryOne("#dt1 + #dd1") != null);
    try std.testing.expect(doc.queryOne("#dd1 + #dt2") != null);
    try std.testing.expect(doc.queryOne("#td1 + #th1") != null);
    try std.testing.expect(doc.queryOne("#th1 + #td2") != null);
    try std.testing.expect(doc.queryOne("head + body") != null);
}

test "attr fast-path names are equivalent to generic lookup semantics" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<a id='x' class='btn primary' href='https://example.com' data-k='v'></a>".*;
    try doc.parse(&html, .{});

    const a = doc.queryOne("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", a.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("btn primary", a.getAttributeValue("class").?);
    try std.testing.expectEqualStrings("https://example.com", a.getAttributeValue("href").?);
    try std.testing.expectEqualStrings("v", a.getAttributeValue("data-k").?);

    try std.testing.expect(a.getAttributeValue("missing") == null);
}

test "normalize_input keeps mixed-case tags and attrs queryable via lowercase selectors" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<DiV ID='x' ClAsS='A b' DaTa-K='v'><SpAn id='y'></SpAn></DiV>".*;
    try doc.parse(&html, .{ .normalize_input = true });

    try std.testing.expect(doc.queryOne("div#x[data-k=v]") != null);
    try std.testing.expect((try doc.queryOneRuntime("div > span#y")) != null);

    const div = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A b", div.getAttributeValue("class").?);
}

test "multiple class predicates in one compound match correctly" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x' class='alpha beta gamma'></div><div id='y' class='alpha beta'></div>".*;
    try doc.parse(&html, .{});

    try expectDocQueryComptime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.gamma", &.{"x"});
    try expectDocQueryRuntime(&doc, "div.alpha.beta.delta", &.{});
}

test "turbo parse mode preserves selector/query behavior for representative input" {
    const alloc = std.testing.allocator;

    var strict_doc = Document.init(alloc);
    defer strict_doc.deinit();
    var turbo_doc = Document.init(alloc);
    defer turbo_doc.deinit();

    var strict_html = ("<html><body>" ++
        "<div id='x' class='alpha beta' data-k='v' data-q='1>2'>x</div>" ++
        "<img id='im' src='a.png' />" ++
        "<a id='a1' href='https://example.com' class='nav button'>ok</a>" ++
        "<p id='p1'>a<span id='s1'>b</span></p>" ++
        "<div id='e' a= ></div>" ++
        "</body></html>").*;
    var turbo_html = strict_html;

    try strict_doc.parse(&strict_html, .{});
    try turbo_doc.parse(&turbo_html, .{
        .eager_child_views = false,
        .eager_attr_empty_rewrite = false,
        .turbo_parse = true,
    });

    const selectors = [_][]const u8{
        "div#x[data-k=v]",
        "img#im",
        "a[href^=https][class*=button]:not(.missing)",
        "p#p1 > span#s1",
        "div[a]",
    };

    for (selectors) |sel| {
        const a = try strict_doc.queryOneRuntime(sel);
        const b = try turbo_doc.queryOneRuntime(sel);
        try std.testing.expect((a == null) == (b == null));
    }

    const strict_empty = (strict_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const turbo_empty = (turbo_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(strict_empty, turbo_empty);
}

test "turbo scanner handles quoted > and self-closing tails" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='a' data-q='x>y' data-n=abc></div><img id='i' src='x' /><br id='b'>".*;
    try doc.parse(&html, .{
        .eager_child_views = false,
        .eager_attr_empty_rewrite = false,
        .turbo_parse = true,
    });

    try std.testing.expect(doc.queryOne("div#a[data-q='x>y']") != null);
    try std.testing.expect(doc.queryOne("img#i[src='x']") != null);
    try std.testing.expect(doc.queryOne("br#b") != null);
}

test "children() lazily builds child views when eager child views are disabled" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span></div>".*;
    try doc.parse(&html, .{ .eager_child_views = false });
    try std.testing.expect(!doc.child_views_ready);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    const before_len = doc.child_ptrs.items.len;
    const kids = root.children();
    try std.testing.expectEqual(@as(usize, 2), kids.len);
    try std.testing.expect(doc.child_views_ready);
    try std.testing.expect(doc.child_ptrs.items.len >= before_len);
    const after_first = doc.child_ptrs.items.len;

    const again = root.children();
    try std.testing.expectEqual(@as(usize, 2), again.len);
    try std.testing.expectEqual(after_first, doc.child_ptrs.items.len);
}
