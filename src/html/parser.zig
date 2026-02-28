const std = @import("std");
const tables = @import("tables.zig");
const tags = @import("tags.zig");
const scanner = @import("scanner.zig");

const InvalidIndex: u32 = std.math.maxInt(u32);
const EnableIncrementalTagHash = true;

/// Parses mutable HTML bytes into `doc` using permissive, in-place tree construction.
pub fn parseInto(comptime Doc: type, noalias doc: *Doc, input: []u8, comptime opts: anytype) !void {
    var p = Parser(Doc, opts){
        .doc = doc,
        .input = input,
        .i = 0,
    };
    try p.parse();
}

fn Parser(comptime Doc: type, comptime opts: anytype) type {
    return struct {
        doc: *Doc,
        input: []u8,
        i: usize,

        const Self = @This();

        fn parse(noalias self: *Self) !void {
            try self.reserveCapacities();

            _ = try self.pushNode(.{
                .kind = .document,
                .subtree_end = 0,
            });
            try self.pushStack(0);

            try self.parseLoop(comptime opts.drop_whitespace_text_nodes);
            self.finishOpenElements();
        }

        fn parseLoop(noalias self: *Self, comptime drop_ws_text: bool) !void {
            while (self.i < self.input.len) {
                if (self.input[self.i] != '<') {
                    if (comptime drop_ws_text) {
                        try self.parseTextDropWhitespace();
                    } else {
                        try self.parseTextKeepWhitespace();
                    }
                    continue;
                }

                if (self.i + 1 >= self.input.len) {
                    @branchHint(.cold);
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
                            @branchHint(.unlikely);
                            self.skipBangNode();
                        }
                    },
                    else => try self.parseOpeningTag(),
                }
            }
        }

        fn finishOpenElements(noalias self: *Self) void {
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
            var estimated_nodes = @max(@as(usize, 16), (input_len / 12) + 8);
            var estimated_stack = @max(@as(usize, 8), (input_len / 256) + 8);

            if (opts.drop_whitespace_text_nodes) {
                estimated_nodes = @max(@as(usize, 32), (input_len / 6) + 32);
                estimated_stack = @max(@as(usize, 16), (input_len / 192) + 16);
            }

            try self.doc.nodes.ensureTotalCapacity(alloc, estimated_nodes);
            try self.doc.parse_stack.ensureTotalCapacity(alloc, estimated_stack);
        }

        inline fn parseTextKeepWhitespace(noalias self: *Self) !void {
            const start = self.i;
            self.i = scanner.findByte(self.input, self.i, '<') orelse self.input.len;
            if (self.i == start) return;

            const parent_idx = self.currentParent();
            const node_idx = try self.appendNode(.text, parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.text = .{ .start = @intCast(start), .end = @intCast(self.i) };
            node.subtree_end = node_idx;
        }

        inline fn parseTextDropWhitespace(noalias self: *Self) !void {
            const start = self.i;
            self.i = scanner.findByte(self.input, self.i, '<') orelse self.input.len;
            if (self.i == start) return;

            const text = self.input[start..self.i];
            if (tables.WhitespaceTable[text[0]] and
                tables.WhitespaceTable[text[text.len - 1]] and
                isAllAsciiWhitespace(text))
            {
                return;
            }

            const parent_idx = self.currentParent();
            const node_idx = try self.appendNode(.text, parent_idx);
            var node = &self.doc.nodes.items[node_idx];
            node.text = .{ .start = @intCast(start), .end = @intCast(self.i) };
            node.subtree_end = node_idx;
        }

        fn parseOpeningTag(noalias self: *Self) !void {
            self.i += 1; // <
            self.skipWs();

            const name_start = self.i;
            var tag_hash_acc = tags.TagHash.init();
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (EnableIncrementalTagHash) tag_hash_acc.update(self.input[self.i]);
            }
            if (self.i == name_start) {
                @branchHint(.cold);
                // malformed tag, consume one byte and move on
                self.i = @min(self.i + 1, self.input.len);
                return;
            }

            const tag_name = self.input[name_start..self.i];
            const tag_name_hash = if (EnableIncrementalTagHash) tag_hash_acc.value() else tags.hashBytes(tag_name);

            if (self.doc.parse_stack.items.len > 1 and tags.mayTriggerImplicitCloseHash(tag_name, tag_name_hash)) {
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

            if (self.i < self.input.len and self.input[self.i] == '>') {
                attr_bytes_end = self.i;
                self.i += 1;
            } else if (self.i + 1 < self.input.len and self.input[self.i] == '/' and self.input[self.i + 1] == '>') {
                explicit_self_close = true;
                attr_bytes_end = self.i;
                self.i += 2;
            } else if (scanner.findTagEndRespectQuotes(self.input, self.i)) |tag_end| {
                explicit_self_close = tag_end.self_close;
                attr_bytes_end = tag_end.attr_end;
                self.i = tag_end.gt_index + 1;
            } else {
                @branchHint(.cold);
                attr_bytes_end = self.input.len;
                self.i = self.input.len;
            }

            if (self.i == self.input.len and attr_bytes_end < self.i) {
                attr_bytes_end = self.i;
            }

            node.attr_bytes.end = @intCast(attr_bytes_end);

            const self_close = explicit_self_close or
                (tag_name.len <= 6 and tags.isVoidTagHash(tag_name, tag_name_hash));

            if (!self_close and tag_name.len >= 5 and tag_name.len <= 6 and tags.isRawTextTagHash(tag_name, tag_name_hash)) {
                const content_start = self.i;
                if (self.findRawTextClose(tag_name, self.i)) |close| {
                    if (close.content_end > content_start) {
                        const text_idx = try self.appendNode(.text, node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.text = .{ .start = @intCast(content_start), .end = @intCast(close.content_end) };
                        text_node.subtree_end = text_idx;
                    }

                    node = &self.doc.nodes.items[node_idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                    self.i = close.close_end;
                    return;
                } else {
                    @branchHint(.cold);
                    if (self.input.len > content_start) {
                        const text_idx = try self.appendNode(.text, node_idx);
                        var text_node = &self.doc.nodes.items[text_idx];
                        text_node.text = .{ .start = @intCast(content_start), .end = @intCast(self.input.len) };
                        text_node.subtree_end = text_idx;
                    }
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

            try self.pushStack(node_idx);
        }

        fn parseClosingTag(noalias self: *Self) void {
            self.i += 2; // </
            self.skipWs();

            const name_start = self.i;
            var close_hash_acc = tags.TagHash.init();
            while (self.i < self.input.len and tables.TagNameCharTable[self.input[self.i]]) : (self.i += 1) {
                if (EnableIncrementalTagHash) close_hash_acc.update(self.input[self.i]);
            }
            const name_end = self.i;
            const close_name = self.input[name_start..name_end];
            const close_hash = if (EnableIncrementalTagHash) close_hash_acc.value() else tags.hashBytes(close_name);

            self.i = scanner.findByte(self.input, self.i, '>') orelse self.input.len;
            if (self.i < self.input.len) self.i += 1;

            if (close_name.len == 0) {
                @branchHint(.cold);
                return;
            }

            if (self.doc.parse_stack.items.len > 1) {
                const top_idx = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                const top = &self.doc.nodes.items[top_idx];
                if (top.tag_hash == close_hash and top.name.len() == close_name.len) {
                    const top_name = top.name.slice(self.input);
                    const matches_top = std.mem.eql(u8, top_name, close_name) or tables.eqlIgnoreCaseAscii(top_name, close_name);
                    if (matches_top) {
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
                if (n.name.len() != close_name.len) continue;
                const open_name = n.name.slice(self.input);
                const matches = std.mem.eql(u8, open_name, close_name) or tables.eqlIgnoreCaseAscii(open_name, close_name);
                if (!matches) continue;
                found = s;
                break;
            }

            if (found) |pos| {
                while (self.doc.parse_stack.items.len > pos) {
                    const idx = self.doc.parse_stack.pop().?;
                    var node = &self.doc.nodes.items[idx];
                    node.subtree_end = @intCast(self.doc.nodes.items.len - 1);
                }
            } else {
                @branchHint(.unlikely);
            }
        }

        inline fn applyImplicitClosures(noalias self: *Self, new_tag: []const u8, new_tag_hash: tags.TagHashValue) void {
            while (self.doc.parse_stack.items.len > 1) {
                const top_idx = self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
                const top = &self.doc.nodes.items[top_idx];
                if (!tags.isImplicitCloseSourceHash(top.tag_hash)) break;
                if (!tags.shouldImplicitlyCloseHash(top.name.slice(self.input), top.tag_hash, new_tag, new_tag_hash)) break;

                _ = self.doc.parse_stack.pop();
                var n = &self.doc.nodes.items[top_idx];
                n.subtree_end = @intCast(self.doc.nodes.items.len - 1);
            }
        }

        fn appendNode(noalias self: *Self, kind: anytype, parent_idx: u32) !u32 {
            const idx: u32 = @intCast(self.doc.nodes.items.len);
            const build_links = parent_idx != InvalidIndex and kind == .element;

            const node: @TypeOf(self.doc.nodes.items[0]) = .{
                .kind = kind,
                .subtree_end = idx,
            };

            _ = try self.pushNode(node);

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

        fn pushNode(noalias self: *Self, node: @TypeOf(self.doc.nodes.items[0])) !u32 {
            const len = self.doc.nodes.items.len;
            if (len == self.doc.nodes.capacity) {
                var target = len +| (len >> 1) + 16;
                if (target <= len) target = len + 1;
                try self.doc.nodes.ensureTotalCapacity(self.doc.allocator, target);
            }
            self.doc.nodes.appendAssumeCapacity(node);
            return @intCast(len);
        }

        fn pushStack(noalias self: *Self, idx: u32) !void {
            const len = self.doc.parse_stack.items.len;
            if (len == self.doc.parse_stack.capacity) {
                var target = len +| (len >> 1) + 16;
                if (target <= len) target = len + 1;
                try self.doc.parse_stack.ensureTotalCapacity(self.doc.allocator, target);
            }
            self.doc.parse_stack.appendAssumeCapacity(idx);
        }

        inline fn currentParent(noalias self: *Self) u32 {
            if (self.doc.parse_stack.items.len == 0) return InvalidIndex;
            return self.doc.parse_stack.items[self.doc.parse_stack.items.len - 1];
        }

        fn skipComment(noalias self: *Self) void {
            self.i += 4;
            var j = self.i;
            while (j + 2 < self.input.len) {
                const dash = scanner.findByte(self.input, j, '-') orelse {
                    @branchHint(.cold);
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
                    @branchHint(.cold);
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

        inline fn skipWs(noalias self: *Self) void {
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

        inline fn isAllAsciiWhitespace(bytes: []const u8) bool {
            for (bytes) |c| {
                if (!tables.WhitespaceTable[c]) return false;
            }
            return true;
        }
    };
}
