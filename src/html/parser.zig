const std = @import("std");
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const entities = @import("entities.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);

pub fn parseInto(comptime Doc: type, doc: *Doc, input: []u8, comptime opts: anytype) !void {
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

        fn parse(self: *Self) !void {
            const alloc = self.doc.allocator;

            try self.doc.nodes.append(alloc, .{
                .doc = self.doc,
                .index = 0,
                .kind = .document,
                .subtree_end = 0,
            });
            try self.doc.parse_stack.append(alloc, 0);

            while (self.i < self.input.len) {
                if (self.input[self.i] == '<') {
                    if (self.startsWith("<!--")) {
                        self.skipComment();
                    } else if (self.startsWith("</")) {
                        self.parseClosingTag();
                    } else if (self.startsWith("<!")) {
                        self.skipBangNode();
                    } else if (self.startsWith("<?")) {
                        self.skipPi();
                    } else {
                        try self.parseOpeningTag();
                    }
                } else {
                    try self.parseText();
                }
            }

            const end: u32 = @intCast(self.input.len);
            while (self.doc.parse_stack.items.len > 1) {
                const idx = self.doc.parse_stack.pop().?;
                var node = &self.doc.nodes.items[idx];
                node.close_start = end;
                node.close_end = end;
                node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
            self.doc.nodes.items[0].subtree_end = @intCast(self.doc.nodes.items.len - 1);
            self.doc.parse_stack.clearRetainingCapacity();
        }

        fn parseText(self: *Self) !void {
            const start = self.i;
            while (self.i < self.input.len and self.input[self.i] != '<') : (self.i += 1) {}
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

        fn parseOpeningTag(self: *Self) !void {
            const open_start = self.i;
            self.i += 1; // <
            self.skipWs();

            const name_start = self.i;
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {}
            if (self.i == name_start) {
                // malformed tag, consume one byte and move on
                self.i = @min(self.i + 1, self.input.len);
                return;
            }

            if (self.opts.normalize_input) tables.toLowerInPlace(self.input[name_start..self.i]);
            const tag_name = self.input[name_start..self.i];

            self.applyImplicitClosures(tag_name, @intCast(open_start));

            const parent_idx = self.currentParent();
            const node_idx = try self.appendNode(.element, parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.name = .{ .start = @intCast(name_start), .end = @intCast(self.i) };
            node.open_start = @intCast(open_start);

            node.attr_bytes_start = @intCast(self.i);
            node.attr_bytes_end = @intCast(self.i);
            node.attr_start = @intCast(self.doc.attrs.items.len);

            var explicit_self_close = false;
            var attr_bytes_end: usize = self.i;

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

                try self.parseAttribute(node_idx);
            }

            if (self.i == self.input.len and attr_bytes_end < self.i) {
                attr_bytes_end = self.i;
            }

            node.open_end = @intCast(self.i);
            node.attr_bytes_end = @intCast(attr_bytes_end);
            node.attr_len = @as(u32, @intCast(self.doc.attrs.items.len)) - node.attr_start;

            const self_close = explicit_self_close or tags.isVoidTag(tag_name);

            if (!self_close and tags.isRawTextTag(tag_name)) {
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
                    node.close_start = @intCast(close.close_start);
                    node.close_end = @intCast(close.close_end);
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
                    node.close_start = @intCast(self.input.len);
                    node.close_end = @intCast(self.input.len);
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = self.input.len;
                    return;
                }
            }

            if (self_close) {
                node.close_start = @intCast(self.i);
                node.close_end = @intCast(self.i);
                node.subtree_end = node_idx;
                return;
            }

            try self.doc.parse_stack.append(self.doc.allocator, node_idx);
        }

        fn parseAttribute(self: *Self, node_index: u32) !void {
            const name_start = self.i;
            while (self.i < self.input.len and tables.IdentCharTable[self.input[self.i]]) : (self.i += 1) {}
            if (self.i == name_start) {
                self.i += 1;
                return;
            }
            const name_end = self.i;

            if (self.opts.normalize_input) tables.toLowerInPlace(self.input[name_start..name_end]);

            var eq_index: u32 = InvalidIndex;
            var value_start = self.i;
            var value_end = self.i;

            self.skipWs();
            if (self.i < self.input.len and self.input[self.i] == '=') {
                eq_index = @intCast(self.i);
                self.i += 1;
                self.skipWs();

                if (self.i >= self.input.len or self.input[self.i] == '>' or (self.input[self.i] == '/' and self.i + 1 < self.input.len and self.input[self.i + 1] == '>')) {
                    // Canonical rewrite for explicit empty assignment: `a=` -> `a `.
                    self.input[@as(usize, eq_index)] = ' ';
                } else if (self.i < self.input.len and (self.input[self.i] == '\'' or self.input[self.i] == '"')) {
                    const q = self.input[self.i];
                    self.i += 1;
                    value_start = self.i;
                    while (self.i < self.input.len and self.input[self.i] != q) : (self.i += 1) {}
                    value_end = self.i;
                    if (self.i < self.input.len and self.input[self.i] == q) self.i += 1;
                } else {
                    value_start = self.i;
                    while (self.i < self.input.len) {
                        const c = self.input[self.i];
                        if (c == '>' or c == '/' or tables.WhitespaceTable[c]) break;
                        self.i += 1;
                    }
                    value_end = self.i;
                }
            }

            if (self.opts.attr_storage_mode == .legacy) {
                const alloc = self.doc.allocator;
                try self.doc.attrs.append(alloc, .{
                    .node_index = node_index,
                    .name = .{ .start = @intCast(name_start), .end = @intCast(name_end) },
                    .value = .{ .start = @intCast(value_start), .end = @intCast(value_end) },
                    .eq_index = eq_index,
                });
            }
        }

        fn parseClosingTag(self: *Self) void {
            const close_start = self.i;
            self.i += 2; // </
            self.skipWs();

            const name_start = self.i;
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {}
            const name_end = self.i;
            if (name_end > name_start and self.opts.normalize_input) tables.toLowerInPlace(self.input[name_start..name_end]);
            const close_name = self.input[name_start..name_end];

            while (self.i < self.input.len and self.input[self.i] != '>') : (self.i += 1) {}
            if (self.i < self.input.len and self.input[self.i] == '>') self.i += 1;
            const close_end: u32 = @intCast(self.i);

            if (close_name.len == 0) return;

            var found: ?usize = null;
            var s = self.doc.parse_stack.items.len;
            while (s > 1) {
                s -= 1;
                const idx = self.doc.parse_stack.items[s];
                const n = &self.doc.nodes.items[idx];
                if (tables.eqlIgnoreCaseAscii(n.name.slice(self.input), close_name)) {
                    found = s;
                    break;
                }
            }

            if (found) |pos| {
                while (self.doc.parse_stack.items.len > pos) {
                    const idx = self.doc.parse_stack.pop().?;
                    var node = &self.doc.nodes.items[idx];
                    node.close_start = @intCast(close_start);
                    node.close_end = close_end;
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                }
            }
        }

        fn applyImplicitClosures(self: *Self, new_tag: []const u8, close_pos: u32) void {
            while (self.doc.parse_stack.items.len > 1) {
                const top_idx = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                const top = &self.doc.nodes.items[top_idx];
                if (!tags.shouldImplicitlyClose(top.name.slice(self.input), new_tag)) break;

                _ = self.doc.parse_stack.pop();
                var n = &self.doc.nodes.items[top_idx];
                n.close_start = close_pos;
                n.close_end = close_pos;
                n.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
        }

        fn appendNode(self: *Self, kind: anytype, parent_idx: u32) !u32 {
            const alloc = self.doc.allocator;
            const idx: u32 = @intCast(self.doc.nodes.items.len);

            var node: @TypeOf(self.doc.nodes.items[0]) = .{
                .doc = self.doc,
                .index = idx,
                .kind = kind,
                .open_start = @intCast(self.i),
                .open_end = @intCast(self.i),
                .close_start = @intCast(self.i),
                .close_end = @intCast(self.i),
                .subtree_end = idx,
            };

            if (parent_idx != InvalidIndex) node.parent = parent_idx;

            try self.doc.nodes.append(alloc, node);

            if (parent_idx != InvalidIndex) {
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

        fn currentParent(self: *Self) u32 {
            if (self.doc.parse_stack.items.len == 0) return InvalidIndex;
            return self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
        }

        fn skipComment(self: *Self) void {
            self.i += 4;
            while (self.i + 2 < self.input.len) : (self.i += 1) {
                if (self.input[self.i] == '-' and self.input[self.i + 1] == '-' and self.input[self.i + 2] == '>') {
                    self.i += 3;
                    return;
                }
            }
            self.i = self.input.len;
        }

        fn skipBangNode(self: *Self) void {
            self.i += 2;
            while (self.i < self.input.len and self.input[self.i] != '>') : (self.i += 1) {}
            if (self.i < self.input.len) self.i += 1;
        }

        fn skipPi(self: *Self) void {
            self.i += 2;
            while (self.i + 1 < self.input.len) : (self.i += 1) {
                if (self.input[self.i] == '?' and self.input[self.i + 1] == '>') {
                    self.i += 2;
                    return;
                }
            }
            self.i = self.input.len;
        }

        fn startsWith(self: *Self, pattern: []const u8) bool {
            if (self.i + pattern.len > self.input.len) return false;
            return std.mem.eql(u8, self.input[self.i .. self.i + pattern.len], pattern);
        }

        fn skipWs(self: *Self) void {
            while (self.i < self.input.len and tables.WhitespaceTable[self.input[self.i]]) : (self.i += 1) {}
        }

        fn findRawTextClose(self: *Self, tag_name: []const u8, start: usize) ?struct { content_end: usize, close_start: usize, close_end: usize } {
            var j = start;
            while (j + 3 < self.input.len) : (j += 1) {
                if (self.input[j] != '<' or self.input[j + 1] != '/') continue;

                var k = j + 2;
                const name_start = k;
                while (k < self.input.len and tables.TagNameCharTable[self.input[k]]) : (k += 1) {}
                if (k == name_start) continue;

                if (!tables.eqlIgnoreCaseAscii(self.input[name_start..k], tag_name)) continue;

                while (k < self.input.len and tables.WhitespaceTable[self.input[k]]) : (k += 1) {}
                if (k >= self.input.len or self.input[k] != '>') continue;

                return .{ .content_end = j, .close_start = j, .close_end = k + 1 };
            }
            return null;
        }

        fn normalizeTextNodeInPlace(input: []u8, text_span: anytype) void {
            const text_mut = text_span.sliceMut(input);
            if (entities.containsEntity(text_mut)) {
                const decoded_len = entities.decodeInPlace(text_mut);
                text_span.end = text_span.start + @as(u32, @intCast(decoded_len));
            }

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
    };
}
