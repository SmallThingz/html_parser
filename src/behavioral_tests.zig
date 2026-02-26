const std = @import("std");
const html = @import("root.zig");

test "document helpers find html/head/body on full documents and return null for fragments" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var full = "<!doctype html><html><head><title>x</title></head><body><h1 id='t'>T</h1></body></html>".*;
    try doc.parse(&full, .{});

    try std.testing.expect(doc.html() != null);
    try std.testing.expect(doc.head() != null);
    try std.testing.expect(doc.body() != null);

    var fragment = "<section id='frag'><p>ok</p></section>".*;
    try doc.parse(&fragment, .{});
    try std.testing.expect(doc.html() == null);
    try std.testing.expect(doc.head() == null);
    try std.testing.expect(doc.body() == null);
}

test "parent pointers can be disabled without breaking other navigation" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='root'><span id='child'></span></div>".*;
    try doc.parse(&input, .{ .store_parent_pointers = false });

    const child = doc.queryOne("span#child") orelse return error.TestUnexpectedResult;
    try std.testing.expect(child.parentNode() == null);

    const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
    try std.testing.expect(root.firstChild() != null);
    try std.testing.expect(root.children().len == 1);
}

test "queries that need ancestry lazily materialize parent pointers" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='a'><span id='b'><em id='c'></em></span></div>".*;
    try doc.parse(&input, .{ .store_parent_pointers = false });
    try std.testing.expect(!doc.store_parent_pointers);

    try std.testing.expect(doc.queryOne("#a #c") != null);
    try std.testing.expect(doc.store_parent_pointers);
}

test "attr-only queries do not force parent pointer materialization" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='a' class='x'></div>".*;
    try doc.parse(&input, .{ .store_parent_pointers = false });
    try std.testing.expect(!doc.store_parent_pointers);

    try std.testing.expect(doc.queryOne("div#a[class=x]") != null);
    try std.testing.expect(!doc.store_parent_pointers);
}

test "queryAll yields matches in document preorder" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    const input =
        "<div id='a'>" ++
        "<section id='b'><span id='c'></span></section>" ++
        "<p id='d'></p>" ++
        "</div>";
    var buf = input.*;
    try doc.parse(&buf, .{});

    var it = doc.queryAll("*[id]");
    const expected = [_][]const u8{ "a", "b", "c", "d" };
    var idx: usize = 0;
    while (it.next()) |node| {
        if (idx >= expected.len) return error.TestUnexpectedResult;
        const id = node.getAttributeValue("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected[idx], id);
        idx += 1;
    }
    try std.testing.expectEqual(expected.len, idx);
}

test "element navigation skips text nodes for sibling/child helpers" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='r'>hello<span id='s1'></span>world<b id='b1'></b><i id='i1'></i></div>".*;
    try doc.parse(&input, .{});

    const root = doc.queryOne("div#r") orelse return error.TestUnexpectedResult;
    const first = root.firstChild() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("s1", first.getAttributeValue("id").?);

    const next = first.nextSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b1", next.getAttributeValue("id").?);

    const last = root.lastChild() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("i1", last.getAttributeValue("id").?);

    const prev = last.prevSibling() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("b1", prev.getAttributeValue("id").?);
}

test "parser remains permissive on malformed nesting" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='a'><span id='b'></div><p id='c'>tail".*;
    try doc.parse(&input, .{});

    try std.testing.expect(doc.queryOne("#a") != null);
    try std.testing.expect(doc.queryOne("#b") != null);
    try std.testing.expect(doc.queryOne("#c") != null);
}
