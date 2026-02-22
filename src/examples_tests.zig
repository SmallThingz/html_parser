const std = @import("std");
const html = @import("root.zig");

fn exampleBasicParseAndQuery() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    const input =
        "<html><body>" ++
        "<main id='app'>" ++
        "<a id='docs' class='nav button' href='https://example.com/docs'>Docs</a>" ++
        "<a id='blog' class='nav' href='/blog'>Blog</a>" ++
        "</main>" ++
        "</body></html>";

    var buf = input.*;
    try doc.parse(&buf, .{});

    const one = doc.queryOne("a#docs.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://example.com/docs", one.getAttributeValue("href").?);

    var it = doc.queryAll("main#app > a.nav");
    const first = it.next() orelse return error.TestUnexpectedResult;
    const second = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("docs", first.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("blog", second.getAttributeValue("id").?);
}

fn exampleCompiledSelectorReuse() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    const input =
        "<div>" ++
        "<a id='a1' class='button nav' href='https://one'></a>" ++
        "<a id='a2' class='nav' href='https://two'></a>" ++
        "<a id='a3' class='button nav' href='http://three'></a>" ++
        "</div>";

    var buf = input.*;
    try doc.parse(&buf, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const selector = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");

    const first = doc.queryOneCompiled(&selector) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", first.getAttributeValue("id").?);

    var it = doc.queryAllCompiled(&selector);
    const matched = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("a1", matched.getAttributeValue("id").?);
    try std.testing.expect(it.next() == null);
}

fn exampleInnerTextNormalization() !void {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='x'> Hello\n  <span>world</span> &amp;\tteam </div>".*;
    try doc.parse(&input, .{});

    const div = doc.queryOne("div#x") orelse return error.TestUnexpectedResult;

    var arena_default = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_default.deinit();
    const normalized = try div.innerText(arena_default.allocator());
    try std.testing.expectEqualStrings("Hello world & team", normalized);

    var arena_raw = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_raw.deinit();
    const raw = try div.innerTextWithOptions(arena_raw.allocator(), .{ .normalize_whitespace = false });
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, '\n') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, raw, '&') != null);
}

test "README example: basic parse and selector queries" {
    try exampleBasicParseAndQuery();
}

test "README example: runtime compiled selector reuse" {
    try exampleCompiledSelectorReuse();
}

test "README example: innerText whitespace options" {
    try exampleInnerTextNormalization();
}
