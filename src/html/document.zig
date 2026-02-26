const std = @import("std");
const tables = @import("tables.zig");
const attr_inline = @import("attr_inline.zig");
const runtime_selector = @import("../selector/runtime.zig");
const ast = @import("../selector/ast.zig");
const matcher = @import("../selector/matcher.zig");
const parser = @import("parser.zig");
const node_api = @import("node.zig");
const tags = @import("tags.zig");

pub const InvalidIndex: u32 = std.math.maxInt(u32);
const QueryAccelMinBudgetBytes: usize = 4096;
const QueryAccelBudgetDivisor: usize = 20; // 5%

const IndexSpan = struct {
    start: u32 = 0,
    len: u32 = 0,
};

const TagIndexEntry = struct {
    tag_hash: tags.TagHashValue,
    span: IndexSpan,
};

pub const NodeType = enum(u2) {
    document,
    element,
    text,
};

pub const ParseOptions = struct {
    // Precompute `children()` slices during parse.
    eager_child_views: bool = true,
    // In fastest-mode style runs, whitespace-only text nodes can be dropped.
    drop_whitespace_text_nodes: bool = false,

    pub fn GetNodeRaw(_: @This()) type {
        return struct {
            kind: NodeType,

            name: Span = .{},
            tag_hash: tags.TagHashValue = 0,
            text: Span = .{},

            // In-place attribute byte range inside the opening tag.
            attr_bytes: Span = .{},

            first_child: u32 = InvalidIndex,
            last_child: u32 = InvalidIndex,
            prev_sibling: u32 = InvalidIndex,
            next_sibling: u32 = InvalidIndex,
            parent: void = {},

            subtree_end: u32 = 0,
        };
    }

    pub fn GetNode(options: @This()) type {
        return struct {
            const DocType = options.GetDocument();
            const QueryIterType = options.QueryIter();

            doc: *DocType,
            index: u32,

            pub fn raw(self: @This()) *const options.GetNodeRaw() {
                return &self.doc.nodes.items[self.index];
            }

            pub fn tagName(self: @This()) []const u8 {
                return self.raw().name.slice(self.doc.source);
            }

            pub fn innerText(self: @This(), arena_alloc: std.mem.Allocator) ![]const u8 {
                return node_api.innerText(self, arena_alloc, .{});
            }

            pub fn innerTextWithOptions(self: @This(), arena_alloc: std.mem.Allocator, opts: TextOptions) ![]const u8 {
                return node_api.innerText(self, arena_alloc, opts);
            }

            pub fn getAttributeValue(self: @This(), name: []const u8) ?[]const u8 {
                return node_api.getAttributeValue(self, name);
            }

            pub fn firstChild(self: @This()) ?@This() {
                return node_api.firstChild(self);
            }

            pub fn lastChild(self: @This()) ?@This() {
                return node_api.lastChild(self);
            }

            pub fn nextSibling(self: @This()) ?@This() {
                return node_api.nextSibling(self);
            }

            pub fn prevSibling(self: @This()) ?@This() {
                return node_api.prevSibling(self);
            }

            pub fn parentNode(self: @This()) ?@This() {
                return node_api.parentNode(self);
            }

            pub fn children(self: @This()) []const u32 {
                return node_api.children(self);
            }

            pub fn queryOne(self: @This(), comptime selector: []const u8) ?@This() {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryOneCompiled(&sel);
            }

            pub fn queryOneCompiled(self: @This(), sel: *const ast.Selector) ?@This() {
                self.doc.ensureQueryPrereqs(sel.*);
                const idx = matcher.queryOneIndex(DocType, self.doc, sel.*, self.index) orelse return null;
                return self.doc.nodeAt(idx);
            }

            pub fn queryOneRuntime(self: @This(), selector: []const u8) runtime_selector.Error!?@This() {
                return self.doc.queryOneRuntimeFrom(selector, self.index);
            }

            pub fn queryAll(self: @This(), comptime selector: []const u8) QueryIterType {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryAllCompiled(&sel);
            }

            pub fn queryAllCompiled(self: @This(), sel: *const ast.Selector) QueryIterType {
                self.doc.ensureQueryPrereqs(sel.*);
                return .{ .doc = self.doc, .selector = sel.*, .scope_root = self.index, .next_index = self.index + 1 };
            }

            pub fn queryAllRuntime(self: @This(), selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.doc.queryAllRuntimeFrom(selector, self.index);
            }
        };
    }

    pub fn QueryIter(options: @This()) type {
        return struct {
            const DocType = options.GetDocument();
            const NodeTypeWrapper = options.GetNode();

            doc: *DocType,
            selector: ast.Selector,
            scope_root: u32 = InvalidIndex,
            next_index: u32 = 1,
            runtime_generation: u64 = 0,

            pub fn next(noalias self: *@This()) ?NodeTypeWrapper {
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

                    if (matcher.matchesSelectorAt(DocType, self.doc, self.selector, idx, self.scope_root)) {
                        self.next_index += 1;
                        return self.doc.nodeAt(idx);
                    }
                }
                return null;
            }
        };
    }

    pub fn GetDocument(options: @This()) type {
        return struct {
            const DocSelf = @This();
            const RawNodeType = options.GetNodeRaw();
            const NodeTypeWrapper = options.GetNode();
            const QueryIterType = options.QueryIter();

            allocator: std.mem.Allocator,
            source: []u8 = &[_]u8{},
            child_views_ready: bool = false,

            nodes: std.ArrayListUnmanaged(RawNodeType) = .{},
            child_indexes: std.ArrayListUnmanaged(u32) = .{},
            child_view_starts: std.ArrayListUnmanaged(u32) = .{},
            child_view_lens: std.ArrayListUnmanaged(u32) = .{},
            parent_indexes: std.ArrayListUnmanaged(u32) = .{},
            parent_indexes_ready: bool = false,
            parse_stack: std.ArrayListUnmanaged(u32) = .{},

            query_one_arena: ?std.heap.ArenaAllocator = null,
            query_all_arena: ?std.heap.ArenaAllocator = null,
            query_all_generation: u64 = 1,
            // One-entry selector caches avoid recompiling hot repeated runtime selectors.
            query_one_cached_selector: []const u8 = "",
            query_one_cached_compiled: ?ast.Selector = null,
            query_one_cache_valid: bool = false,
            query_all_cached_selector: []const u8 = "",
            query_all_cached_compiled: ?ast.Selector = null,
            query_all_cache_valid: bool = false,

            query_accel_budget_bytes: usize = 0,
            query_accel_used_bytes: usize = 0,
            query_accel_budget_exhausted: bool = false,
            query_accel_id_built: bool = false,
            query_accel_id_disabled: bool = false,
            query_accel_tag_disabled: bool = false,
            query_accel_id_map: std.AutoHashMapUnmanaged(u64, u32) = .{},
            query_accel_tag_entries: std.ArrayListUnmanaged(TagIndexEntry) = .{},
            query_accel_tag_nodes: std.ArrayListUnmanaged(u32) = .{},

            pub fn init(allocator: std.mem.Allocator) DocSelf {
                return .{
                    .allocator = allocator,
                };
            }

            pub fn deinit(noalias self: *DocSelf) void {
                self.nodes.deinit(self.allocator);
                self.child_indexes.deinit(self.allocator);
                self.child_view_starts.deinit(self.allocator);
                self.child_view_lens.deinit(self.allocator);
                self.parent_indexes.deinit(self.allocator);
                self.parse_stack.deinit(self.allocator);
                self.query_accel_id_map.deinit(self.allocator);
                self.query_accel_tag_entries.deinit(self.allocator);
                self.query_accel_tag_nodes.deinit(self.allocator);
                if (self.query_one_arena) |*arena| arena.deinit();
                if (self.query_all_arena) |*arena| arena.deinit();
            }

            pub fn clear(noalias self: *DocSelf) void {
                self.nodes.clearRetainingCapacity();
                self.child_indexes.clearRetainingCapacity();
                self.child_view_starts.clearRetainingCapacity();
                self.child_view_lens.clearRetainingCapacity();
                self.parent_indexes.clearRetainingCapacity();
                self.parent_indexes_ready = false;
                self.parse_stack.clearRetainingCapacity();
                self.child_views_ready = false;
                if (self.query_one_arena) |*arena| _ = arena.reset(.retain_capacity);
                if (self.query_all_arena) |*arena| _ = arena.reset(.retain_capacity);
                self.invalidateRuntimeSelectorCaches();
                self.resetQueryAccel();
                self.query_all_generation +%= 1;
                if (self.query_all_generation == 0) self.query_all_generation = 1;
            }

            pub fn parse(noalias self: *DocSelf, input: []u8, comptime opts: ParseOptions) !void {
                self.clear();
                self.source = input;
                self.query_accel_budget_bytes = @max(input.len / QueryAccelBudgetDivisor, QueryAccelMinBudgetBytes);
                try parser.parseInto(DocSelf, self, input, opts);
                if (opts.eager_child_views) {
                    try self.buildChildViews();
                }
            }

            pub fn queryOne(self: *const DocSelf, comptime selector: []const u8) ?NodeTypeWrapper {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryOneCompiled(&sel);
            }

            pub fn queryOneCompiled(self: *const DocSelf, sel: *const ast.Selector) ?NodeTypeWrapper {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel.*);
                const idx = matcher.queryOneIndex(DocSelf, self, sel.*, InvalidIndex) orelse return null;
                return self.nodeAt(idx);
            }

            pub fn queryOneRuntime(self: *const DocSelf, selector: []const u8) runtime_selector.Error!?NodeTypeWrapper {
                return self.queryOneRuntimeFrom(selector, InvalidIndex);
            }

            fn queryOneRuntimeFrom(self: *const DocSelf, selector: []const u8, scope_root: u32) runtime_selector.Error!?NodeTypeWrapper {
                const mut_self: *DocSelf = @constCast(self);
                const sel = try mut_self.getOrCompileQueryOneSelector(selector);
                mut_self.ensureQueryPrereqs(sel);
                if (scope_root == InvalidIndex) return self.queryOneCompiled(&sel);
                const idx = matcher.queryOneIndex(DocSelf, self, sel, scope_root) orelse return null;
                return self.nodeAt(idx);
            }

            pub fn queryAll(self: *const DocSelf, comptime selector: []const u8) QueryIterType {
                const sel = comptime ast.Selector.compile(selector);
                return self.queryAllCompiled(&sel);
            }

            pub fn queryAllCompiled(self: *const DocSelf, sel: *const ast.Selector) QueryIterType {
                const mut_self: *DocSelf = @constCast(self);
                mut_self.ensureQueryPrereqs(sel.*);
                return .{ .doc = @constCast(self), .selector = sel.*, .scope_root = InvalidIndex, .next_index = 1 };
            }

            pub fn queryAllRuntime(self: *const DocSelf, selector: []const u8) runtime_selector.Error!QueryIterType {
                return self.queryAllRuntimeFrom(selector, InvalidIndex);
            }

            fn queryAllRuntimeFrom(self: *const DocSelf, selector: []const u8, scope_root: u32) runtime_selector.Error!QueryIterType {
                const mut_self: *DocSelf = @constCast(self);
                // Runtime query-all iterators are invalidated when a newer runtime
                // query-all is created, to avoid holding stale compiled selector state.
                mut_self.query_all_generation +%= 1;
                if (mut_self.query_all_generation == 0) mut_self.query_all_generation = 1;

                const sel = try mut_self.getOrCompileQueryAllSelector(selector);
                mut_self.ensureQueryPrereqs(sel);
                var out = if (scope_root == InvalidIndex)
                    self.queryAllCompiled(&sel)
                else
                    QueryIterType{
                        .doc = @constCast(self),
                        .selector = sel,
                        .scope_root = scope_root,
                        .next_index = scope_root + 1,
                    };
                out.runtime_generation = mut_self.query_all_generation;
                return out;
            }

            fn ensureQueryPrereqs(noalias self: *DocSelf, selector: ast.Selector) void {
                if (selector.requires_parent) self.ensureParentIndexesBuilt();
            }

            pub fn parentIndex(self: *const DocSelf, idx: u32) u32 {
                if (!self.parent_indexes_ready or idx >= self.parent_indexes.items.len) return InvalidIndex;
                return self.parent_indexes.items[idx];
            }

            pub fn ensureParentIndexesBuilt(noalias self: *DocSelf) void {
                if (self.parent_indexes_ready) return;
                self.buildParentIndexes() catch @panic("out of memory building parent indexes");
            }

            fn buildParentIndexes(noalias self: *DocSelf) !void {
                const alloc = self.allocator;
                const node_count = self.nodes.items.len;
                self.parent_indexes.clearRetainingCapacity();
                try self.parent_indexes.ensureTotalCapacity(alloc, node_count);
                self.parent_indexes.items.len = node_count;
                @memset(self.parent_indexes.items, InvalidIndex);

                var parent_idx: u32 = 0;
                while (parent_idx < node_count) : (parent_idx += 1) {
                    var child = self.nodes.items[parent_idx].first_child;
                    while (child != InvalidIndex) : (child = self.nodes.items[child].next_sibling) {
                        self.parent_indexes.items[child] = parent_idx;
                    }
                }
                self.parent_indexes_ready = true;
            }

            pub fn html(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("html");
            }

            pub fn head(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("head");
            }

            pub fn body(self: *const DocSelf) ?NodeTypeWrapper {
                return self.findFirstTag("body");
            }

            pub fn findFirstTag(self: *const DocSelf, name: []const u8) ?NodeTypeWrapper {
                var i: usize = 1;
                while (i < self.nodes.items.len) : (i += 1) {
                    const n = &self.nodes.items[i];
                    if (n.kind != .element) continue;
                    if (tables.eqlIgnoreCaseAscii(n.name.slice(self.source), name)) return self.nodeAt(@intCast(i));
                }
                return null;
            }

            pub fn nodeAt(self: *const DocSelf, idx: u32) ?NodeTypeWrapper {
                if (idx == InvalidIndex or idx >= self.nodes.items.len) return null;
                return .{
                    .doc = @constCast(self),
                    .index = idx,
                };
            }

            fn invalidateRuntimeSelectorCaches(noalias self: *DocSelf) void {
                self.query_one_cache_valid = false;
                self.query_one_cached_selector = "";
                self.query_one_cached_compiled = null;
                self.query_all_cache_valid = false;
                self.query_all_cached_selector = "";
                self.query_all_cached_compiled = null;
            }

            fn getOrCompileQueryOneSelector(noalias self: *DocSelf, selector: []const u8) runtime_selector.Error!ast.Selector {
                if (self.query_one_cache_valid and std.mem.eql(u8, self.query_one_cached_selector, selector)) {
                    return self.query_one_cached_compiled.?;
                }

                const arena = self.ensureQueryOneArena();
                _ = arena.reset(.retain_capacity);
                const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
                self.query_one_cached_selector = sel.source;
                self.query_one_cached_compiled = sel;
                self.query_one_cache_valid = true;
                return sel;
            }

            fn getOrCompileQueryAllSelector(noalias self: *DocSelf, selector: []const u8) runtime_selector.Error!ast.Selector {
                if (self.query_all_cache_valid and std.mem.eql(u8, self.query_all_cached_selector, selector)) {
                    return self.query_all_cached_compiled.?;
                }

                const arena = self.ensureQueryAllArena();
                _ = arena.reset(.retain_capacity);
                const sel = try ast.Selector.compileRuntime(arena.allocator(), selector);
                self.query_all_cached_selector = sel.source;
                self.query_all_cached_compiled = sel;
                self.query_all_cache_valid = true;
                return sel;
            }

            fn ensureQueryOneArena(noalias self: *DocSelf) *std.heap.ArenaAllocator {
                if (self.query_one_arena == null) {
                    self.query_one_arena = std.heap.ArenaAllocator.init(self.allocator);
                }
                return &self.query_one_arena.?;
            }

            fn ensureQueryAllArena(noalias self: *DocSelf) *std.heap.ArenaAllocator {
                if (self.query_all_arena == null) {
                    self.query_all_arena = std.heap.ArenaAllocator.init(self.allocator);
                }
                return &self.query_all_arena.?;
            }

            fn resetQueryAccel(self: *DocSelf) void {
                self.query_accel_used_bytes = 0;
                self.query_accel_budget_exhausted = false;
                self.query_accel_id_built = false;
                self.query_accel_id_disabled = false;
                self.query_accel_tag_disabled = false;
                self.query_accel_id_map.clearRetainingCapacity();
                self.query_accel_tag_entries.clearRetainingCapacity();
                self.query_accel_tag_nodes.clearRetainingCapacity();
            }

            fn queryAccelReserve(self: *DocSelf, bytes: usize) bool {
                if (self.query_accel_budget_exhausted) return false;
                const remaining = self.query_accel_budget_bytes -| self.query_accel_used_bytes;
                if (bytes > remaining) {
                    self.query_accel_budget_exhausted = true;
                    return false;
                }
                self.query_accel_used_bytes += bytes;
                return true;
            }

            fn ensureIdIndex(self: *DocSelf) bool {
                if (self.query_accel_id_built) return true;
                if (self.query_accel_id_disabled or self.query_accel_budget_exhausted) return false;

                self.query_accel_id_map.clearRetainingCapacity();

                var idx: u32 = 1;
                while (idx < self.nodes.items.len) : (idx += 1) {
                    const node = &self.nodes.items[idx];
                    if (node.kind != .element) continue;

                    const id = attr_inline.getAttrValue(self, node, "id") orelse continue;
                    if (id.len == 0) continue;
                    const id_hash = hashIdValue(id);

                    const gop = self.query_accel_id_map.getOrPut(self.allocator, id_hash) catch {
                        self.query_accel_id_disabled = true;
                        self.query_accel_id_map.clearRetainingCapacity();
                        return false;
                    };

                    if (gop.found_existing) {
                        const existing_idx = gop.value_ptr.*;
                        const existing_node = &self.nodes.items[existing_idx];
                        const existing_id = attr_inline.getAttrValue(self, existing_node, "id") orelse "";
                        // Hash collision on different ids would break index correctness.
                        // Disable this accel path and fall back to exact scan semantics.
                        if (!std.mem.eql(u8, existing_id, id)) {
                            self.query_accel_id_disabled = true;
                            self.query_accel_id_map.clearRetainingCapacity();
                            return false;
                        }
                        continue;
                    }

                    if (!self.queryAccelReserve(@sizeOf(u64) + @sizeOf(u32) + 16)) {
                        _ = self.query_accel_id_map.remove(id_hash);
                        self.query_accel_id_disabled = true;
                        self.query_accel_id_map.clearRetainingCapacity();
                        return false;
                    }

                    gop.value_ptr.* = idx;
                }

                self.query_accel_id_built = true;
                return true;
            }

            fn ensureTagIndex(self: *DocSelf, tag_hash: tags.TagHashValue) ?IndexSpan {
                if (tag_hash == std.math.maxInt(tags.TagHashValue)) return null;
                if (self.query_accel_tag_disabled or self.query_accel_budget_exhausted) return null;
                for (self.query_accel_tag_entries.items) |entry| {
                    if (entry.tag_hash == tag_hash) return entry.span;
                }

                var count: usize = 0;
                for (self.nodes.items[1..]) |node| {
                    if (node.kind == .element and node.tag_hash == tag_hash) count += 1;
                }

                const reserve_bytes = count * @sizeOf(u32) + @sizeOf(TagIndexEntry);
                if (!self.queryAccelReserve(reserve_bytes)) {
                    self.query_accel_tag_disabled = true;
                    return null;
                }

                const start: usize = self.query_accel_tag_nodes.items.len;
                self.query_accel_tag_nodes.ensureTotalCapacity(self.allocator, start + count) catch {
                    self.query_accel_tag_disabled = true;
                    return null;
                };

                var idx: u32 = 1;
                while (idx < self.nodes.items.len) : (idx += 1) {
                    const node = &self.nodes.items[idx];
                    if (node.kind == .element and node.tag_hash == tag_hash) {
                        self.query_accel_tag_nodes.appendAssumeCapacity(idx);
                    }
                }

                const span: IndexSpan = .{
                    .start = @intCast(start),
                    .len = @intCast(self.query_accel_tag_nodes.items.len - start),
                };
                self.query_accel_tag_entries.append(self.allocator, .{
                    .tag_hash = tag_hash,
                    .span = span,
                }) catch {
                    self.query_accel_tag_disabled = true;
                    return null;
                };
                return span;
            }

            pub fn queryAccelLookupId(self: *const DocSelf, id: []const u8, used_index: *bool) ?u32 {
                const mut_self: *DocSelf = @constCast(self);
                if (!mut_self.ensureIdIndex()) {
                    used_index.* = false;
                    return null;
                }
                const id_hash = hashIdValue(id);
                const idx = mut_self.query_accel_id_map.get(id_hash) orelse {
                    used_index.* = true;
                    return null;
                };
                const node = &mut_self.nodes.items[idx];
                const current_id = attr_inline.getAttrValue(mut_self, node, "id") orelse {
                    used_index.* = true;
                    return null;
                };
                if (std.mem.eql(u8, current_id, id)) {
                    used_index.* = true;
                    return idx;
                }

                // Collision or stale key materialization: permanently disable the id
                // index for this document and let caller use the scan fallback.
                mut_self.query_accel_id_disabled = true;
                mut_self.query_accel_id_built = false;
                mut_self.query_accel_id_map.clearRetainingCapacity();
                used_index.* = false;
                return null;
            }

            pub fn queryAccelLookupTag(self: *const DocSelf, tag_hash: tags.TagHashValue, used_index: *bool) ?[]const u32 {
                const mut_self: *DocSelf = @constCast(self);
                const span = mut_self.ensureTagIndex(tag_hash) orelse {
                    used_index.* = false;
                    return null;
                };
                used_index.* = true;
                const start: usize = @intCast(span.start);
                const end: usize = start + @as(usize, @intCast(span.len));
                return mut_self.query_accel_tag_nodes.items[start..end];
            }

            pub fn ensureChildViewsBuilt(noalias self: *DocSelf) void {
                if (self.child_views_ready) return;
                // Allocation failure here indicates an unrecoverable internal state for
                // callers expecting non-fallible navigation APIs.
                self.buildChildViews() catch @panic("out of memory building child views");
            }

            pub fn childViewStart(self: *const DocSelf, idx: u32) u32 {
                return self.child_view_starts.items[idx];
            }

            pub fn childViewLen(self: *const DocSelf, idx: u32) u32 {
                return self.child_view_lens.items[idx];
            }

            fn buildChildViews(noalias self: *DocSelf) !void {
                const node_count = self.nodes.items.len;
                const alloc = self.allocator;

                self.child_view_starts.clearRetainingCapacity();
                self.child_view_lens.clearRetainingCapacity();
                try self.child_view_starts.ensureTotalCapacity(alloc, node_count);
                try self.child_view_lens.ensureTotalCapacity(alloc, node_count);
                self.child_view_starts.items.len = node_count;
                self.child_view_lens.items.len = node_count;
                self.child_indexes.clearRetainingCapacity();
                const child_count = if (node_count > 0) node_count - 1 else 0;
                try self.child_indexes.ensureTotalCapacity(alloc, child_count);
                self.child_indexes.items.len = 0;

                var i: u32 = 0;
                while (i < node_count) : (i += 1) {
                    self.child_view_starts.items[i] = @intCast(self.child_indexes.items.len);
                    self.child_view_lens.items[i] = 0;

                    var child = self.nodes.items[i].first_child;
                    while (child != InvalidIndex) {
                        self.child_indexes.appendAssumeCapacity(child);
                        self.child_view_lens.items[i] += 1;
                        child = self.nodes.items[child].next_sibling;
                    }
                }

                self.child_views_ready = true;
            }
        };
    }
};

pub const TextOptions = node_api.TextOptions;

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

const DefaultTypeOptions: ParseOptions = .{};
const NodeRaw = DefaultTypeOptions.GetNodeRaw();
const Node = DefaultTypeOptions.GetNode();
const QueryIter = DefaultTypeOptions.QueryIter();
const Document = DefaultTypeOptions.GetDocument();

fn hashIdValue(id: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id);
}

fn assertNodeTypeLayouts() void {
    _ = @sizeOf(NodeRaw);
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

fn expectNodeQueryComptime(scope: Node, comptime selector: []const u8, expected_ids: []const []const u8) !void {
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

fn expectNodeQueryRuntime(scope: Node, selector: []const u8, expected_ids: []const []const u8) !void {
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

fn parseViaMove(alloc: std.mem.Allocator, input: []u8) !Document {
    var doc = Document.init(alloc);
    try doc.parse(input, .{});
    return doc;
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
    try std.testing.expect(script.raw().subtree_end > script.index);

    const text_node = doc.nodes.items[script.index + 1];
    try std.testing.expect(text_node.kind == .text);
    try std.testing.expectEqualStrings("const x = 1;", text_node.text.slice(doc.source));

    const div = doc.queryOne("div") orelse return error.TestUnexpectedResult;
    try std.testing.expect(div.index > script.raw().subtree_end);
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

test "inplace attribute parser treats explicit empty assignment as name-only" {
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

    const span = doc.source[node.raw().attr_bytes.start..node.raw().attr_bytes.end];
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
    const span = doc.source[node.raw().attr_bytes.start..node.raw().attr_bytes.end];
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
    try std.testing.expect(script.raw().subtree_end < after.index);
}

test "raw-text unterminated tail keeps element open to end of input" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<script>const a = 1; <div>still script".*;
    try doc.parse(&html, .{});

    const script = doc.queryOne("script") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, @intCast(doc.nodes.items.len - 1)), script.raw().subtree_end);
    try std.testing.expect((doc.queryOne("div")) == null);
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

test "mixed-case tags and attrs are queryable via lowercase selectors" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<DiV ID='x' ClAsS='A b' DaTa-K='v'><SpAn id='y'></SpAn></DiV>".*;
    try doc.parse(&html, .{});

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

test "runtime selector supports nth-child shorthand variants" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='pseudos'><div></div><div></div><div></div><div></div><a></a><div></div><div></div></div>".*;
    try doc.parse(&html, .{});

    const comptime_one = doc.queryOne("#pseudos :nth-child(odd)");
    const runtime_one = try doc.queryOneRuntime("#pseudos :nth-child(odd)");
    try std.testing.expect((comptime_one == null) == (runtime_one == null));
    if (comptime_one) |a| {
        try std.testing.expectEqual(a.index, runtime_one.?.index);
    }

    var c_odd: usize = 0;
    var it_odd = try doc.queryAllRuntime("#pseudos :nth-child(odd)");
    while (it_odd.next()) |_| c_odd += 1;
    try std.testing.expectEqual(@as(usize, 4), c_odd);

    var c_plus: usize = 0;
    var it_plus = try doc.queryAllRuntime("#pseudos :nth-child(3n+1)");
    while (it_plus.next()) |_| c_plus += 1;
    try std.testing.expectEqual(@as(usize, 3), c_plus);

    var c_signed: usize = 0;
    var it_signed = try doc.queryAllRuntime("#pseudos :nth-child(+3n-2)");
    while (it_signed.next()) |_| c_signed += 1;
    try std.testing.expectEqual(@as(usize, 3), c_signed);

    var c_neg_a: usize = 0;
    var it_neg_a = try doc.queryAllRuntime("#pseudos :nth-child(-n+6)");
    while (it_neg_a.next()) |_| c_neg_a += 1;
    try std.testing.expectEqual(@as(usize, 6), c_neg_a);

    var c_neg_b: usize = 0;
    var it_neg_b = try doc.queryAllRuntime("#pseudos :nth-child(-n+5)");
    while (it_neg_b.next()) |_| c_neg_b += 1;
    try std.testing.expectEqual(@as(usize, 5), c_neg_b);
}

test "leading child combinator works in node-scoped queries" {
    const alloc = std.testing.allocator;

    var frag_doc = Document.init(alloc);
    defer frag_doc.deinit();
    var frag_html =
        "<root><div class='d i v'><p id='oooo'><em></em><em id='emem'></em></p></div><p id='sep'><div class='a'><span></span></div></p></root>".*;
    try frag_doc.parse(&frag_html, .{});
    const frag_root = frag_doc.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_em = try frag_root.queryAllRuntime("> div p em");
    var em_count: usize = 0;
    while (it_em.next()) |_| em_count += 1;
    try std.testing.expectEqual(@as(usize, 2), em_count);

    var it_oooo = try frag_root.queryAllRuntime("> div #oooo");
    var oooo_count: usize = 0;
    while (it_oooo.next()) |_| oooo_count += 1;
    try std.testing.expectEqual(@as(usize, 1), oooo_count);

    var doc_ctx = Document.init(alloc);
    defer doc_ctx.deinit();
    var doc_html =
        "<root><div id='hsoob'><div class='a b'><div class='d e sib' id='booshTest'><p><span id='spanny'></span></p></div><em class='sib'></em><span class='h i a sib'></span></div><p class='odd'></p></div><div id='lonelyHsoob'></div></root>".*;
    try doc_ctx.parse(&doc_html, .{});
    const ctx_root = doc_ctx.queryOne("root") orelse return error.TestUnexpectedResult;

    var it_hsoob = try ctx_root.queryAllRuntime("> #hsoob");
    var hsoob_count: usize = 0;
    while (it_hsoob.next()) |_| hsoob_count += 1;
    try std.testing.expectEqual(@as(usize, 1), hsoob_count);
}

test "attribute parsing preserves selector/query behavior for representative input" {
    const alloc = std.testing.allocator;

    var eager_doc = Document.init(alloc);
    defer eager_doc.deinit();
    var deferred_doc = Document.init(alloc);
    defer deferred_doc.deinit();

    var eager_html = ("<html><body>" ++
        "<div id='x' class='alpha beta' data-k='v' data-q='1>2'>x</div>" ++
        "<img id='im' src='a.png' />" ++
        "<a id='a1' href='https://example.com' class='nav button'>ok</a>" ++
        "<p id='p1'>a<span id='s1'>b</span></p>" ++
        "<div id='e' a= ></div>" ++
        "</body></html>").*;
    var deferred_html = eager_html;

    try eager_doc.parse(&eager_html, .{});
    try deferred_doc.parse(&deferred_html, .{
        .eager_child_views = false,
    });

    const selectors = [_][]const u8{
        "div#x[data-k=v]",
        "img#im",
        "a[href^=https][class*=button]:not(.missing)",
        "p#p1 > span#s1",
        "div[a]",
    };

    for (selectors) |sel| {
        const a = try eager_doc.queryOneRuntime(sel);
        const b = try deferred_doc.queryOneRuntime(sel);
        try std.testing.expect((a == null) == (b == null));
    }

    const eager_empty = (eager_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    const deferred_empty = (deferred_doc.queryOne("#e") orelse return error.TestUnexpectedResult).getAttributeValue("a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(eager_empty, deferred_empty);
}

test "attribute scanner handles quoted > and self-closing tails" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='a' data-q='x>y' data-n=abc></div><img id='i' src='x' /><br id='b'>".*;
    try doc.parse(&html, .{
        .eager_child_views = false,
    });

    try std.testing.expect(doc.queryOne("div#a[data-q='x>y']") != null);
    try std.testing.expect(doc.queryOne("img#i[src='x']") != null);
    try std.testing.expect(doc.queryOne("br#b") != null);
}

test "attribute parsing still builds the DOM" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='x'><span id='y'></span></div>".*;
    try doc.parse(&html, .{
        .eager_child_views = false,
    });

    // Document node plus parsed element nodes must exist.
    try std.testing.expect(doc.nodes.items.len > 1);
    try std.testing.expect(doc.queryOne("#x") != null);
    try std.testing.expect(doc.queryOne("#y") != null);
}

test "children() lazily builds child views when eager child views are disabled" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html = "<div id='root'><span id='a'></span><span id='b'></span></div>".*;
    try doc.parse(&html, .{ .eager_child_views = false });
    try std.testing.expect(!doc.child_views_ready);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    const before_len = doc.child_indexes.items.len;
    const kids = root.children();
    try std.testing.expectEqual(@as(usize, 2), kids.len);
    try std.testing.expect(doc.child_views_ready);
    try std.testing.expect(doc.child_indexes.items.len >= before_len);
    const after_first = doc.child_indexes.items.len;

    const again = root.children();
    try std.testing.expectEqual(@as(usize, 2), again.len);
    try std.testing.expectEqual(after_first, doc.child_indexes.items.len);
}

test "moved document keeps node-scoped queries and navigation valid" {
    const alloc = std.testing.allocator;
    var html = "<root><div id='a'><span id='b'></span></div></root>".*;
    var doc = try parseViaMove(alloc, &html);
    defer doc.deinit();

    const a = doc.queryOne("#a") orelse return error.TestUnexpectedResult;
    const b = a.queryOne("span#b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("span", b.tagName());
    try std.testing.expectEqual(@as(u32, a.index), b.parentNode().?.index);
}

test "query accel id/tag indexes match selector results" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html =
        "<div id='root'><a id='x' href='https://example' class='nav button'></a><span id='y'></span><a id='z' href='/local' class='nav'></a></div>".*;
    try doc.parse(&html, .{});

    const x = doc.queryOne("#x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(tags.hashBytes("a"), x.raw().tag_hash);

    var used_id = false;
    const id_idx = doc.queryAccelLookupId("x", &used_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(used_id);
    try std.testing.expectEqual(x.index, id_idx);

    var used_tag = false;
    const a_hash = tags.hashBytes("a");
    const tag_candidates = doc.queryAccelLookupTag(a_hash, &used_tag) orelse return error.TestUnexpectedResult;
    try std.testing.expect(used_tag);
    try std.testing.expectEqual(@as(usize, 2), tag_candidates.len);
    try std.testing.expectEqual(x.index, tag_candidates[0]);
    try std.testing.expectEqualStrings("a", doc.nodes.items[tag_candidates[1]].name.slice(doc.source));

    const sel_hit = doc.queryOne("a[href^=https][class*=button]") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(x.index, sel_hit.index);

    const x_node = doc.nodeAt(id_idx) orelse return error.TestUnexpectedResult;
    _ = x_node.getAttributeValue("class") orelse return error.TestUnexpectedResult;
    used_id = false;
    const id_idx_after = doc.queryAccelLookupId("x", &used_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(used_id);
    try std.testing.expectEqual(id_idx, id_idx_after);
}

test "query accel state is invalidated by parse and clear" {
    const alloc = std.testing.allocator;
    var doc = Document.init(alloc);
    defer doc.deinit();

    var html_a = "<div><a id='x'></a><a id='y'></a></div>".*;
    try doc.parse(&html_a, .{});

    var used_id = false;
    _ = doc.queryAccelLookupId("x", &used_id);
    try std.testing.expect(used_id);

    var used_tag = false;
    _ = doc.queryAccelLookupTag(tags.hashBytes("a"), &used_tag);
    try std.testing.expect(used_tag);
    try std.testing.expect(doc.query_accel_id_built);
    try std.testing.expect(doc.query_accel_tag_nodes.items.len != 0);

    var html_b = "<main><p id='z'></p></main>".*;
    try doc.parse(&html_b, .{});
    try std.testing.expect(!doc.query_accel_id_built);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_entries.items.len);

    used_id = false;
    try std.testing.expect(doc.queryAccelLookupId("x", &used_id) == null);
    try std.testing.expect(used_id);

    doc.clear();
    try std.testing.expect(!doc.query_accel_id_built);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), doc.query_accel_tag_entries.items.len);
}
