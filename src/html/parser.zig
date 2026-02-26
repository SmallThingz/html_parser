const std = @import("std");
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);
const EnableIncrementalTagHash = true;
const EnableTextNormalizeFastPath = true;

pub fn parseInto(comptime Doc: type, noalias doc: *Doc, input: []u8, comptime opts: anytype) !void {
    const OptType = @TypeOf(opts);
    var p = Parser(Doc, OptType){
        .doc = doc,
        .input = input,
        .i = 0,
        .opts = opts,
    };
    try p.parse();
}

fn Parser(comptime Doc: type, comptime OptType: type) type {
    return struct {
        doc: *Doc,
        input: []u8,
        i: usize,
        opts: OptType,

        const Self = @This();

        fn parse(noalias self: *Self) !void {
            const alloc = self.doc.allocator;
            try self.reserveCapacities();

            try self.doc.nodes.append(alloc, .{
                .kind = .document,
                .subtree_end = 0,
            });
            try self.doc.parse_stack.append(alloc, 0);

            while (self.i < self.input.len) {
                if (self.input[self.i] != '<') {
                    try self.parseText();
                    continue;
                }

                if (self.i + 1 >= self.input.len) {
                    self.i += 1;
                    continue;
                }

                switch (self.input[self.i + 1]) {
                    '/' => self.parseClosingTag(),
                    '?' => self.skipPi(),
                    '!' => {
                        if (self.i + 3 < self.input.len and self.input[self.i + 2] == '-' and self.input[self.i + 3] == '-') {
                            self.skipComment();
                        } else {
                            self.skipBangNode();
                        }
                    },
                    else => try self.parseOpeningTag(),
                }
            }

            while (self.doc.parse_stack.items.len > 1) {
                const idx = self.doc.parse_stack.pop().?;
                var node = &self.doc.nodes.items[idx];
                node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
            self.doc.nodes.items[0].subtree_end = @intCast(self.doc.nodes.items.len - 1);
            self.doc.parse_stack.clearRetainingCapacity();
        }

        fn reserveCapacities(noalias self: *Self) !void {
            const alloc = self.doc.allocator;
            const input_len = self.input.len;
            const estimated_nodes = @max(@as(usize, 16), (input_len / 12) + 8);
            const estimated_stack = @max(@as(usize, 8), (input_len / 256) + 8);

            try self.doc.nodes.ensureTotalCapacity(alloc, estimated_nodes);
            try self.doc.parse_stack.ensureTotalCapacity(alloc, estimated_stack);
        }

        fn parseText(noalias self: *Self) !void {
            const start = self.i;
            self.i = scanner.findByte(self.input, self.i, '<') orelse self.input.len;
            if (self.i == start) return;

            const parent_idx = self.currentParent();
            const node_idx = try self.appendNode(.text, parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.text = .{ .start = @intCast(start), .end = @intCast(self.i) };

            if (self.opts.normalize_text_on_parse) {
                normalizeTextNodeInPlace(self.input, &node.text);
            }

            node.subtree_end = node_idx;
        }

        fn parseOpeningTag(noalias self: *Self) !void {
            self.i += 1; // <
            self.skipWs();

            const name_start = self.i;
            var saw_upper = false;
            var tag_hash_acc = tags.TagHash.init();
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                const c = self.input[self.i];
                if (c >= 'A' and c <= 'Z') saw_upper = true;
                if (EnableIncrementalTagHash) tag_hash_acc.update(c);
            }
            if (self.i == name_start) {
                // malformed tag, consume one byte and move on
                self.i = @min(self.i + 1, self.input.len);
                return;
            }

            if (self.opts.normalize_input and saw_upper) tables.toLowerInPlace(self.input[name_start..self.i]);
            const tag_name = self.input[name_start..self.i];
            const tag_name_hash = if (EnableIncrementalTagHash) tag_hash_acc.value() else tags.hashBytes(tag_name);

            if (tags.mayTriggerImplicitCloseHash(tag_name, tag_name_hash)) {
                self.applyImplicitClosures(tag_name, tag_name_hash);
            }

            const parent_idx = self.currentParent();
            const node_idx = try self.appendNode(.element, parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.name = .{ .start = @intCast(name_start), .end = @intCast(self.i) };
            node.tag_hash = tag_name_hash;

            node.attr_bytes.start = @intCast(self.i);
            node.attr_bytes.end = @intCast(self.i);

            var explicit_self_close = false;
            var attr_bytes_end: usize = self.i;

            if (self.opts.defer_attribute_parsing) {
                // Fast path: scan to tag end while honoring quotes so `>` inside
                // attribute values does not terminate the tag early.
                if (scanner.findTagEndRespectQuotes(self.input, self.i)) |tag_end| {
                    explicit_self_close = tag_end.self_close;
                    attr_bytes_end = tag_end.attr_end;
                    self.i = tag_end.gt_index + 1;
                } else {
                    attr_bytes_end = self.input.len;
                    self.i = self.input.len;
                }
            } else {
                if (self.i < self.input.len and self.input[self.i] == '>') {
                    self.i += 1;
                    attr_bytes_end = self.i - 1;
                } else if (self.i + 1 < self.input.len and self.input[self.i] == '/' and self.input[self.i + 1] == '>') {
                    explicit_self_close = true;
                    attr_bytes_end = self.i;
                    self.i += 2;
                } else {
                    while (self.i < self.input.len) {
                        self.skipWs();
                        if (self.i >= self.input.len) break;

                        const c = self.input[self.i];
                        if (c == '>') {
                            attr_bytes_end = self.i;
                            self.i += 1;
                            break;
                        }

                        if (c == '/' and self.i + 1 < self.input.len and self.input[self.i + 1] == '>') {
                            explicit_self_close = true;
                            attr_bytes_end = self.i;
                            self.i += 2;
                            break;
                        }

                        try self.parseAttribute();
                    }
                }
            }

            if (self.i == self.input.len and attr_bytes_end < self.i) {
                attr_bytes_end = self.i;
            }

            node.attr_bytes.end = @intCast(attr_bytes_end);

            const self_close = explicit_self_close or tags.isVoidTagHash(tag_name, tag_name_hash);

            if (!self_close and tags.isRawTextTagHash(tag_name, tag_name_hash)) {
                // Raw-text elements are consumed as plain text until an explicit
                // matching close tag candidate is found.
                const content_start = self.i;
                if (self.findRawTextClose(tag_name, self.i)) |close| {
                    if (close.content_end > content_start) {
                        const text_idx = try self.appendNode(.text, node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.text = .{ .start = @intCast(content_start), .end = @intCast(close.content_end) };
                        text_node.subtree_end = text_idx;
                    }

                    // appendNode() above may grow `nodes`; reacquire element pointer.
                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = close.close_end;
                    return;
                } else {
                    if (self.input.len > content_start) {
                        const text_idx = try self.appendNode(.text, node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.text = .{ .start = @intCast(content_start), .end = @intCast(self.input.len) };
                        text_node.subtree_end = text_idx;
                    }
                    // appendNode() above may grow `nodes`; reacquire element pointer.
                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = self.input.len;
                    return;
                }
            }

            if (self_close) {
                node.subtree_end = node_idx;
                return;
            }

            try self.doc.parse_stack.append(self.doc.allocator, node_idx);
        }

        fn parseAttribute(noalias self: *Self) !void {
            const name_start = self.i;
            var saw_upper = false;
            while (self.i < self.input.len and tables.IdentCharTable[self.input[self.i]]) : (self.i += 1) {
                const c = self.input[self.i];
                if (c >= 'A' and c <= 'Z') saw_upper = true;
            }
            if (self.i == name_start) {
                self.i += 1;
                return;
            }

            if (self.opts.normalize_input and saw_upper) tables.toLowerInPlace(self.input[name_start..self.i]);

            if (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) self.skipWs();
            if (self.i < self.input.len and self.input[self.i] == '=') {
                const eq_index: usize = self.i;
                self.i += 1;
                if (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) self.skipWs();

                if (self.i >= self.input.len or self.input[self.i] == '>' or (self.input[self.i] == '/' and self.i + 1 < self.input.len and self.input[self.i + 1] == '>')) {
                    // Canonical rewrite for explicit empty assignment: `a=` -> `a `.
                    if (self.opts.eager_attr_empty_rewrite) self.input[eq_index] = ' ';
                } else if (self.i < self.input.len and (self.input[self.i] == '\'' or self.input[self.i] == '"')) {
                    const q = self.input[self.i];
                    const q_start = self.i + 1;
                    self.i = scanner.findByte(self.input, q_start, q) orelse self.input.len;
                    if (self.i < self.input.len and self.input[self.i] == q) self.i += 1;
                } else {
                    while (self.i < self.input.len) {
                        const c = self.input[self.i];
                        if (c == '>' or c == '/' or tables.WhitespaceTable[c]) break;
                        self.i += 1;
                    }
                }
            }
        }

        fn parseClosingTag(noalias self: *Self) void {
            self.i += 2; // </
            self.skipWs();

            const name_start = self.i;
            var saw_upper = false;
            var close_hash_acc = tags.TagHash.init();
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                const c = self.input[self.i];
                if (c >= 'A' and c <= 'Z') saw_upper = true;
                if (EnableIncrementalTagHash) close_hash_acc.update(c);
            }
            const name_end = self.i;
            if (name_end > name_start and self.opts.normalize_input and saw_upper) tables.toLowerInPlace(self.input[name_start..name_end]);
            const close_name = self.input[name_start..name_end];
            const close_hash = if (EnableIncrementalTagHash) close_hash_acc.value() else tags.hashBytes(close_name);

            self.i = scanner.findByte(self.input, self.i, '>') orelse self.input.len;
            if (self.i < self.input.len) self.i += 1;

            if (close_name.len == 0) return;

            if (self.doc.parse_stack.items.len > 1) {
                const top_idx = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                const top = &self.doc.nodes.items[top_idx];
                const hash_mismatch = top.tag_hash != close_hash;
                if (!hash_mismatch) {
                    const top_name = top.name.slice(self.input);
                    if (!std.mem.eql(u8, top_name, close_name) and !tables.eqlIgnoreCaseAscii(top_name, close_name)) {
                        // fall through to stack walk
                    } else {
                        _ = self.doc.parse_stack.pop();
                        var node = &self.doc.nodes.items[top_idx];
                        node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                        return;
                    }
                }
            }

            var found: ?usize = null;
            var s = self.doc.parse_stack.items.len;
            while (s > 1) {
                s -= 1;
                const idx = self.doc.parse_stack.items[s];
                const n = &self.doc.nodes.items[idx];
                if (n.tag_hash != close_hash) continue;
                const open_name = n.name.slice(self.input);
                if (!std.mem.eql(u8, open_name, close_name) and !tables.eqlIgnoreCaseAscii(open_name, close_name)) {
                    continue;
                }
                found = s;
                break;
            }

            if (found) |pos| {
                while (self.doc.parse_stack.items.len > pos) {
                    const idx = self.doc.parse_stack.pop().?;
                    var node = &self.doc.nodes.items[idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                }
            }
        }

        fn applyImplicitClosures(noalias self: *Self, new_tag: []const u8, new_tag_hash: tags.TagHashValue) void {
            while (self.doc.parse_stack.items.len > 1) {
                const top_idx = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                const top = &self.doc.nodes.items[top_idx];
                if (!tags.shouldImplicitlyCloseHash(top.name.slice(self.input), top.tag_hash, new_tag, new_tag_hash)) break;

                _ = self.doc.parse_stack.pop();
                var n = &self.doc.nodes.items[top_idx];
                n.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
        }

        fn appendNode(noalias self: *Self, kind: anytype, parent_idx: u32) !u32 {
            const alloc = self.doc.allocator;
            const idx: u32 = @intCast(self.doc.nodes.items.len);
            const build_links = parent_idx != InvalidIndex;

            var node: @TypeOf(self.doc.nodes.items[0]) = .{
                .kind = kind,
                .subtree_end = idx,
            };

            if (parent_idx != InvalidIndex and self.doc.store_parent_pointers) node.parent = parent_idx;

            try self.doc.nodes.append(alloc, node);

            if (build_links) {
                var p = &self.doc.nodes.items[parent_idx];
                if (p.first_child == InvalidIndex) {
                    p.first_child = idx;
                    p.last_child = idx;
                } else {
                    const prev = p.last_child;
                    self.doc.nodes.items[prev].next_sibling = idx;
                    self.doc.nodes.items[idx].prev_sibling = prev;
                    p.last_child = idx;
                }
            }

            return idx;
        }

        fn currentParent(noalias self: *Self) u32 {
            if (self.doc.parse_stack.items.len == 0) return InvalidIndex;
            return self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
        }

        fn skipComment(noalias self: *Self) void {
            self.i += 4;
            var j = self.i;
            while (j + 2 < self.input.len) {
                const dash = scanner.findByte(self.input, j, '-') orelse {
                    self.i = self.input.len;
                    return;
                };
                if (dash + 2 < self.input.len and self.input[dash + 1] == '-' and self.input[dash + 2] == '>') {
                    self.i = dash + 3;
                    return;
                }
                j = dash + 1;
            }
            self.i = self.input.len;
        }

        fn skipBangNode(noalias self: *Self) void {
            self.i += 2;
            self.i = scanner.findByte(self.input, self.i, '>') orelse self.input.len;
            if (self.i < self.input.len) self.i += 1;
        }

        fn skipPi(noalias self: *Self) void {
            self.i += 2;
            var j = self.i;
            while (j + 1 < self.input.len) {
                const q = scanner.findByte(self.input, j, '?') orelse {
                    self.i = self.input.len;
                    return;
                };
                if (q + 1 < self.input.len and self.input[q + 1] == '>') {
                    self.i = q + 2;
                    return;
                }
                j = q + 1;
            }
            self.i = self.input.len;
        }

        fn skipWs(noalias self: *Self) void {
            while (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) : (self.i += 1) {}
        }

        fn findRawTextClose(noalias self: *Self, tag_name: []const u8, start: usize) ?struct { content_end: usize, close_end: usize } {
            var j = scanner.findByte(self.input, start, '<') orelse return null;
            const tag_len = tag_name.len;
            if (tag_len == 0) return null;
            const first = tables.lower(tag_name[0]);
            while (j + 3 < self.input.len) {
                if (self.input[j + 1] != '/') {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }
                if (j + 2 >= self.input.len or tables.lower(self.input[j + 2]) != first) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                var k = j + 2;
                const name_start = k;
                while (k < self.input.len and tables.TagNameCharTable[self.input[k]]) : (k += 1) {}
                if (k == name_start) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                if (k - name_start != tag_len) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }
                if (!tables.eqlIgnoreCaseAscii(self.input[name_start..k], tag_name)) {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                while (k < self.input.len and tables.WhitespaceTable[self.input[k]]) : (k += 1) {}
                if (k >= self.input.len or self.input[k] != '>') {
                    j = scanner.findByte(self.input, j + 1, '<') orelse return null;
                    continue;
                }

                return .{
                    .content_end = j,
                    .close_end = k + 1,
                };
            }
            return null;
        }

        fn normalizeTextNodeInPlace(input: []u8, text_span: anytype) void {
            const text_mut = text_span.sliceMut(input);
            if (EnableTextNormalizeFastPath and !textNeedsNormalization(text_mut)) return;
            const decoded_len = entities.decodeInPlaceIfEntity(text_mut);
            text_span.end = text_span.start + @as(u32, @intCast(decoded_len));

            const norm_slice = text_span.sliceMut(input);
            const new_len = normalizeWhitespaceInPlace(norm_slice);
            text_span.end = text_span.start + @as(u32, @intCast(new_len));
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

        fn textNeedsNormalization(bytes: []const u8) bool {
            if (bytes.len == 0) return false;

            var prev_ws = false;
            var i: usize = 0;
            while (i < bytes.len) : (i += 1) {
                const c = bytes[i];
                if (c == '&') return true;

                const ws = tables.WhitespaceTable[c];
                if (!ws) {
                    prev_ws = false;
                    continue;
                }

                if (i == 0 or i + 1 == bytes.len) return true;
                if (c != ' ') return true;
                if (prev_ws) return true;
                prev_ws = true;
            }
            return false;
        }
    };
}
