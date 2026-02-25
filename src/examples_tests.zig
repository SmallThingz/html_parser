const std = @import("std");
const html = @import("root.zig");

test "example parity: basic parse and query" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}

test "example parity: runtime selectors" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div><a class='primary' href='/x'></a><a class='secondary' href='/y'></a></div>".*;
    try doc.parse(&input, .{});

    try std.testing.expect((try doc.queryOneRuntime("a.primary")) != null);

    var it = try doc.queryAllRuntime("a[href]");
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

test "example parity: cached selector" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    const input =
        "<div>" ++
        "<a id='a1' class='button nav' href='https://one'></a>" ++
        "<a id='a2' class='nav' href='https://two'></a>" ++
        "</div>";

    var buf = input.*;
    try doc.parse(&buf, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");
    const first = doc.queryOneCached(&sel) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", first.getAttributeValue("id").?);
}

test "example parity: navigation and children" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<main id='m'><h1 id='title'></h1><p id='intro'></p><p id='body'></p></main>".*;
    try doc.parse(&input, .{});

    const main = doc.queryOne("main#m") orelse return error.TestUnexpectedResult;
    const first = main.firstChild() orelse return error.TestUnexpectedResult;
    const last = main.lastChild() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("title", first.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("body", last.getAttributeValue("id").?);
    try std.testing.expectEqual(@as(usize, 3), main.children().len);
}

test "example parity: innerText options" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='x'> Hello\n  <span>world</span> &amp;\tteam </div>".*;
    try doc.parse(&input, .{});

    const node = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;

    var arena_norm = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_norm.deinit();
    const normalized = try node.innerText(arena_norm.allocator());
    try std.testing.expectEqualStrings("Hello world & team", normalized);

    var arena_raw = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_raw.deinit();
    const raw = try node.innerTextWithOptions(arena_raw.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, '\n') != null);
}

test "example parity: strict and turbo selectors agree" {
    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strict_doc = html.Document.init(std.testing.allocator);
    defer strict_doc.deinit();
    var strict_buf = fixture.*;
    try strict_doc.parse(&strict_buf, .{ .turbo_parse = false });

    var turbo_doc = html.Document.init(std.testing.allocator);
    defer turbo_doc.deinit();
    var turbo_buf = fixture.*;
    try turbo_doc.parse(&turbo_buf, .{ .turbo_parse = true, .eager_child_views = false, .eager_attr_empty_rewrite = false });

    var strict_it = strict_doc.queryAll("li.item");
    var strict_count: usize = 0;
    while (strict_it.next() != null) strict_count += 1;

    var turbo_it = turbo_doc.queryAll("li.item");
    var turbo_count: usize = 0;
    while (turbo_it.next() != null) turbo_count += 1;

    try std.testing.expectEqual(@as(usize, 2), strict_count);
    try std.testing.expectEqual(strict_count, turbo_count);
}
