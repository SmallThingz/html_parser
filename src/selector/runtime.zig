const std = @import("std");
const ast = @import("ast.zig");
const tables = @import("../html/tables.zig");

pub const Error = error{
    InvalidSelector,
    OutOfMemory,
};

pub fn compileRuntimeImpl(alloc: std.mem.Allocator, source: []const u8) Error!ast.Selector {
    const owned_source = try alloc.dupe(u8, source);
    errdefer alloc.free(owned_source);

    var parser = Parser.init(owned_source, alloc);
    var sel = try parser.parse();
    sel.owns_source = true;
    return sel;
}

const Parser = struct {
    source: []const u8,
    i: usize,
    alloc: std.mem.Allocator,

    groups: std.ArrayList(ast.Group),
    compounds: std.ArrayList(ast.Compound),
    classes: std.ArrayList(ast.Range),
    attrs: std.ArrayList(ast.AttrSelector),
    pseudos: std.ArrayList(ast.Pseudo),
    not_items: std.ArrayList(ast.NotSimple),

    fn init(source: []const u8, alloc: std.mem.Allocator) Parser {
        return .{
            .source = source,
            .i = 0,
            .alloc = alloc,
            .groups = std.ArrayList(ast.Group).empty,
            .compounds = std.ArrayList(ast.Compound).empty,
            .classes = std.ArrayList(ast.Range).empty,
            .attrs = std.ArrayList(ast.AttrSelector).empty,
            .pseudos = std.ArrayList(ast.Pseudo).empty,
            .not_items = std.ArrayList(ast.NotSimple).empty,
        };
    }

    fn parse(self: *Parser) Error!ast.Selector {
        defer self.groups.deinit(self.alloc);
        defer self.compounds.deinit(self.alloc);
        defer self.classes.deinit(self.alloc);
        defer self.attrs.deinit(self.alloc);
        defer self.pseudos.deinit(self.alloc);
        defer self.not_items.deinit(self.alloc);

        self.skipWs();
        if (self.i >= self.source.len) return error.InvalidSelector;

        while (true) {
            const group_start: u32 = @intCast(self.compounds.items.len);
            try self.parseCompound(.none);

            while (true) {
                const saw_ws = self.skipWsRet();
                if (self.i >= self.source.len or self.peek() == ',') break;

                var combinator: ast.Combinator = if (saw_ws) .descendant else .none;
                combinator = switch (self.peek()) {
                    '>' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.child;
                    },
                    '+' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.adjacent;
                    },
                    '~' => blk: {
                        self.i += 1;
                        self.skipWs();
                        break :blk ast.Combinator.sibling;
                    },
                    else => combinator,
                };

                if (combinator == .none) return error.InvalidSelector;
                try self.parseCompound(combinator);
            }

            const group_end: u32 = @intCast(self.compounds.items.len);
            if (group_end == group_start) return error.InvalidSelector;
            try self.groups.append(self.alloc, .{
                .compound_start = group_start,
                .compound_len = group_end - group_start,
            });

            self.skipWs();
            if (self.i >= self.source.len) break;
            if (self.peek() != ',') return error.InvalidSelector;
            self.i += 1;
            self.skipWs();
            if (self.i >= self.source.len) return error.InvalidSelector;
        }

        const groups = try self.groups.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(groups);

        const compounds = try self.compounds.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(compounds);

        const classes = try self.classes.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(classes);

        const attrs = try self.attrs.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(attrs);

        const pseudos = try self.pseudos.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(pseudos);

        const not_items = try self.not_items.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(not_items);

        return .{
            .source = self.source,
            .groups = groups,
            .compounds = compounds,
            .classes = classes,
            .attrs = attrs,
            .pseudos = pseudos,
            .not_items = not_items,
        };
    }

    fn parseCompound(self: *Parser, combinator: ast.Combinator) Error!void {
        var out: ast.Compound = .{ .combinator = combinator };
        out.class_start = @intCast(self.classes.items.len);
        out.attr_start = @intCast(self.attrs.items.len);
        out.pseudo_start = @intCast(self.pseudos.items.len);
        out.not_start = @intCast(self.not_items.items.len);

        var consumed = false;

        if (self.i < self.source.len) {
            const c = self.peek();
            if (c == '*') {
                self.i += 1;
                consumed = true;
            } else if (tables.IdentStartTable[c]) {
                out.has_tag = 1;
                out.tag = self.parseIdent() orelse return error.InvalidSelector;
                consumed = true;
            }
        }

        while (self.i < self.source.len) {
            const c = self.peek();
            switch (c) {
                '#' => {
                    self.i += 1;
                    out.has_id = 1;
                    out.id = self.parseIdent() orelse return error.InvalidSelector;
                    consumed = true;
                },
                '.' => {
                    self.i += 1;
                    const class_name = self.parseIdent() orelse return error.InvalidSelector;
                    try self.classes.append(self.alloc, class_name);
                    consumed = true;
                },
                '[' => {
                    self.i += 1;
                    const attr = try self.parseAttrSelector();
                    try self.attrs.append(self.alloc, attr);
                    consumed = true;
                },
                ':' => {
                    self.i += 1;
                    try self.parsePseudo();
                    consumed = true;
                },
                else => break,
            }
        }

        if (!consumed) return error.InvalidSelector;

        out.class_len = @as(u32, @intCast(self.classes.items.len)) - out.class_start;
        out.attr_len = @as(u32, @intCast(self.attrs.items.len)) - out.attr_start;
        out.pseudo_len = @as(u32, @intCast(self.pseudos.items.len)) - out.pseudo_start;
        out.not_len = @as(u32, @intCast(self.not_items.items.len)) - out.not_start;

        try self.compounds.append(self.alloc, out);
    }

    fn parseAttrSelector(self: *Parser) Error!ast.AttrSelector {
        self.skipWs();
        const name = self.parseIdent() orelse return error.InvalidSelector;
        self.skipWs();

        if (!self.consumeIf('=')) {
            if (!self.consumeIf('^')) {
                if (!self.consumeIf('$')) {
                    if (!self.consumeIf('*')) {
                        if (!self.consumeIf('~')) {
                            if (!self.consumeIf('|')) {
                                if (!self.consumeIf(']')) return error.InvalidSelector;
                                return .{ .name = name, .op = .exists, .value = .{} };
                            }
                            if (!self.consumeIf('=')) return error.InvalidSelector;
                            const v = try self.parseAttrValueThenClose();
                            return .{ .name = name, .op = .dash_match, .value = v };
                        }
                        if (!self.consumeIf('=')) return error.InvalidSelector;
                        const v = try self.parseAttrValueThenClose();
                        return .{ .name = name, .op = .includes, .value = v };
                    }
                    if (!self.consumeIf('=')) return error.InvalidSelector;
                    const v = try self.parseAttrValueThenClose();
                    return .{ .name = name, .op = .contains, .value = v };
                }
                if (!self.consumeIf('=')) return error.InvalidSelector;
                const v = try self.parseAttrValueThenClose();
                return .{ .name = name, .op = .suffix, .value = v };
            }
            if (!self.consumeIf('=')) return error.InvalidSelector;
            const v = try self.parseAttrValueThenClose();
            return .{ .name = name, .op = .prefix, .value = v };
        }

        const v = try self.parseAttrValueThenClose();
        return .{ .name = name, .op = .eq, .value = v };
    }

    fn parseAttrValueThenClose(self: *Parser) Error!ast.Range {
        self.skipWs();
        const v = self.parseValueToken() orelse return error.InvalidSelector;
        self.skipWs();
        if (!self.consumeIf(']')) return error.InvalidSelector;
        return v;
    }

    fn parsePseudo(self: *Parser) Error!void {
        const name = self.parseIdent() orelse return error.InvalidSelector;
        const name_slice = name.slice(self.source);

        if (tables.eqlIgnoreCaseAscii(name_slice, "first-child")) {
            try self.pseudos.append(self.alloc, .{ .kind = .first_child });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "last-child")) {
            try self.pseudos.append(self.alloc, .{ .kind = .last_child });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "nth-child")) {
            self.skipWs();
            if (!self.consumeIf('(')) return error.InvalidSelector;
            self.skipWs();
            const arg = self.parseUntil(')') orelse return error.InvalidSelector;
            const nth = parseNthExpr(tables.trimAsciiWhitespace(arg.slice(self.source))) orelse return error.InvalidSelector;
            try self.pseudos.append(self.alloc, .{ .kind = .nth_child, .nth = nth });
            return;
        }

        if (tables.eqlIgnoreCaseAscii(name_slice, "not")) {
            self.skipWs();
            if (!self.consumeIf('(')) return error.InvalidSelector;
            self.skipWs();
            const item = try self.parseSimpleNot();
            self.skipWs();
            if (!self.consumeIf(')')) return error.InvalidSelector;
            try self.not_items.append(self.alloc, item);
            return;
        }

        return error.InvalidSelector;
    }

    fn parseSimpleNot(self: *Parser) Error!ast.NotSimple {
        if (self.i >= self.source.len) return error.InvalidSelector;

        if (self.peek() == '#') {
            self.i += 1;
            const id = self.parseIdent() orelse return error.InvalidSelector;
            return .{ .kind = .id, .text = id };
        }

        if (self.peek() == '.') {
            self.i += 1;
            const c = self.parseIdent() orelse return error.InvalidSelector;
            return .{ .kind = .class, .text = c };
        }

        if (self.peek() == '[') {
            self.i += 1;
            const attr = try self.parseAttrSelector();
            return .{ .kind = .attr, .attr = attr };
        }

        if (tables.IdentStartTable[self.peek()]) {
            const tag = self.parseIdent() orelse return error.InvalidSelector;
            return .{ .kind = .tag, .text = tag };
        }

        return error.InvalidSelector;
    }

    fn parseUntil(self: *Parser, terminator: u8) ?ast.Range {
        const start = self.i;
        while (self.i < self.source.len and self.source[self.i] != terminator) : (self.i += 1) {}
        if (self.i >= self.source.len or self.source[self.i] != terminator) return null;
        const out = ast.Range.from(start, self.i);
        self.i += 1;
        return out;
    }

    fn parseValueToken(self: *Parser) ?ast.Range {
        if (self.i >= self.source.len) return null;
        const c = self.peek();

        if (c == '\'' or c == '"') {
            self.i += 1;
            const start = self.i;
            while (self.i < self.source.len and self.source[self.i] != c) : (self.i += 1) {}
            if (self.i >= self.source.len) return null;
            const out = ast.Range.from(start, self.i);
            self.i += 1;
            return out;
        }

        const start = self.i;
        while (self.i < self.source.len) {
            const cur = self.source[self.i];
            if (cur == ']' or tables.WhitespaceTable[cur]) break;
            self.i += 1;
        }
        if (self.i == start) return null;
        return ast.Range.from(start, self.i);
    }

    fn parseIdent(self: *Parser) ?ast.Range {
        if (self.i >= self.source.len) return null;
        if (!tables.IdentStartTable[self.source[self.i]]) return null;
        const start = self.i;
        self.i += 1;
        while (self.i < self.source.len and isSelectorIdentChar(self.source[self.i])) : (self.i += 1) {}
        return ast.Range.from(start, self.i);
    }

    fn skipWs(self: *Parser) void {
        _ = self.skipWsRet();
    }

    fn skipWsRet(self: *Parser) bool {
        const start = self.i;
        while (self.i < self.source.len and tables.WhitespaceTable[self.source[self.i]]) : (self.i += 1) {}
        return self.i > start;
    }

    fn consumeIf(self: *Parser, c: u8) bool {
        if (self.i < self.source.len and self.source[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.i];
    }
};

fn isSelectorIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or
        c == '-';
}

fn parseNthExpr(expr: []const u8) ?ast.NthExpr {
    if (expr.len == 0) return null;
    if (tables.eqlIgnoreCaseAscii(expr, "odd")) return .{ .a = 2, .b = 1 };
    if (tables.eqlIgnoreCaseAscii(expr, "even")) return .{ .a = 2, .b = 0 };

    if (std.mem.indexOfScalar(u8, expr, 'n')) |n_pos| {
        const a_part = tables.trimAsciiWhitespace(expr[0..n_pos]);
        const b_part = tables.trimAsciiWhitespace(expr[n_pos + 1 ..]);

        const a: i32 = if (a_part.len == 0 or std.mem.eql(u8, a_part, "+"))
            1
        else if (std.mem.eql(u8, a_part, "-"))
            -1
        else
            std.fmt.parseInt(i32, a_part, 10) catch return null;

        const b: i32 = if (b_part.len == 0)
            0
        else
            std.fmt.parseInt(i32, b_part, 10) catch return null;

        return .{ .a = a, .b = b };
    }

    const only = std.fmt.parseInt(i32, expr, 10) catch return null;
    return .{ .a = 0, .b = only };
}

test "runtime selector parser covers all attribute operators" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div[a][b=v][c^=x][d$=y][e*=z][f~=m][g|=en]");
    defer sel.deinitRuntime(alloc);

    try std.testing.expectEqual(@as(usize, 1), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 1), sel.compounds.len);

    const comp = sel.compounds[0];
    try std.testing.expectEqual(@as(u32, 7), comp.attr_len);
    try std.testing.expect(sel.attrs[comp.attr_start + 0].op == .exists);
    try std.testing.expect(sel.attrs[comp.attr_start + 1].op == .eq);
    try std.testing.expect(sel.attrs[comp.attr_start + 2].op == .prefix);
    try std.testing.expect(sel.attrs[comp.attr_start + 3].op == .suffix);
    try std.testing.expect(sel.attrs[comp.attr_start + 4].op == .contains);
    try std.testing.expect(sel.attrs[comp.attr_start + 5].op == .includes);
    try std.testing.expect(sel.attrs[comp.attr_start + 6].op == .dash_match);
}

test "runtime selector parser tracks combinator chain and grouping" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "a b > c + d ~ e, #x");
    defer sel.deinitRuntime(alloc);

    try std.testing.expectEqual(@as(usize, 2), sel.groups.len);
    try std.testing.expectEqual(@as(usize, 6), sel.compounds.len);

    try std.testing.expect(sel.compounds[0].combinator == .none);
    try std.testing.expect(sel.compounds[1].combinator == .descendant);
    try std.testing.expect(sel.compounds[2].combinator == .child);
    try std.testing.expect(sel.compounds[3].combinator == .adjacent);
    try std.testing.expect(sel.compounds[4].combinator == .sibling);
    try std.testing.expect(sel.compounds[5].combinator == .none);
}

test "runtime selector parser rejects invalid selectors" {
    const alloc = std.testing.allocator;
    const invalid = [_][]const u8{
        "",
        ",",
        "div >",
        "div +",
        "div ~",
        "div,",
        "div:not()",
        "div:not(.a,.b)",
        "div:nth-child()",
        "div:nth-child(2n+)",
        "div:unknown",
        "[attr",
        "div[attr^]",
    };

    for (invalid) |source| {
        if (compileRuntimeImpl(alloc, source)) |sel| {
            var owned = sel;
            owned.deinitRuntime(alloc);
            return error.TestUnexpectedResult;
        } else |err| {
            try std.testing.expect(err == error.InvalidSelector);
        }
    }
}

test "runtime selector parse" {
    const alloc = std.testing.allocator;
    var sel = try compileRuntimeImpl(alloc, "div#id.cls[attr^=x]:first-child, span + a");
    defer sel.deinitRuntime(alloc);

    try std.testing.expect(sel.groups.len == 2);

    var sel2 = try compileRuntimeImpl(alloc, "div > span.k");
    defer sel2.deinitRuntime(alloc);
    try std.testing.expectEqual(@as(usize, 1), sel2.groups.len);
    try std.testing.expectEqual(@as(usize, 2), sel2.compounds.len);
    try std.testing.expect(sel2.compounds[1].combinator == .child);
}

test "runtime selector owns source bytes" {
    const alloc = std.testing.allocator;
    var buf = "span.x".*;

    var sel = try compileRuntimeImpl(alloc, &buf);
    defer sel.deinitRuntime(alloc);

    buf[0] = 'd';
    buf[1] = 'i';
    buf[2] = 'v';

    const cls = sel.classes[0].slice(sel.source);
    try std.testing.expectEqualStrings("x", cls);
    try std.testing.expectEqualStrings("span", sel.compounds[0].tag.slice(sel.source));
}
