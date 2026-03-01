const std = @import("std");
const html = @import("htmlparser");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

test "example parity: basic parse and query" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}

test "example parity: runtime selectors" {
    var doc = Document.init(std.testing.allocator);
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
    var doc = Document.init(std.testing.allocator);
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
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<main id='m'><h1 id='title'></h1><p id='intro'></p><p id='body'></p></main>".*;
    try doc.parse(&input, .{});

    const main = doc.queryOne("main#m") orelse return error.TestUnexpectedResult;
    const first = main.firstChild() orelse return error.TestUnexpectedResult;
    const last = main.lastChild() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("title", first.getAttributeValue("id").?);
    try std.testing.expectEqualStrings("body", last.getAttributeValue("id").?);
    var children = main.children();
    var child_indexes: std.ArrayListUnmanaged(u32) = .{};
    defer child_indexes.deinit(std.testing.allocator);
    try children.collect(std.testing.allocator, &child_indexes);
    try std.testing.expectEqual(@as(usize, 3), child_indexes.items.len);
    const first_via_index = main.doc.nodeAt(child_indexes.items[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("title", first_via_index.getAttributeValue("id").?);
}

test "example parity: innerText options" {
    var doc = Document.init(std.testing.allocator);
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

    var arena_owned = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_owned.deinit();
    const owned = try node.innerTextOwned(arena_owned.allocator());
    try std.testing.expectEqualStrings("Hello world & team", owned);
    try std.testing.expect(!doc.isOwned(owned));
}

test "example parity: strictest and fastest selectors agree" {
    const fixture =
        "<html><body>" ++
        "<ul><li class='item'>A</li><li class='item'>B</li></ul>" ++
        "</body></html>";

    var strictest_doc = Document.init(std.testing.allocator);
    defer strictest_doc.deinit();
    var strictest_buf = fixture.*;
    try strictest_doc.parse(&strictest_buf, .{
        .drop_whitespace_text_nodes = false,
    });

    var fastest_doc = Document.init(std.testing.allocator);
    defer fastest_doc.deinit();
    var fastest_buf = fixture.*;
    try fastest_doc.parse(&fastest_buf, .{
        .drop_whitespace_text_nodes = true,
    });

    var strictest_it = strictest_doc.queryAll("li.item");
    var strictest_count: usize = 0;
    while (strictest_it.next() != null) strictest_count += 1;

    var fastest_it = fastest_doc.queryAll("li.item");
    var fastest_count: usize = 0;
    while (fastest_it.next() != null) fastest_count += 1;

    try std.testing.expectEqual(@as(usize, 2), strictest_count);
    try std.testing.expectEqual(strictest_count, fastest_count);
}

test "example parity: debug query report" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div><a id='one' class='nav'></a><a id='two'></a></div>".*;
    try doc.parse(&input, .{});

    var report: html.QueryDebugReport = .{};
    const node = try doc.queryOneRuntimeDebug("a[href^=https]", &report);
    try std.testing.expect(node == null);
    try std.testing.expect(report.visited_elements > 0);
    try std.testing.expect(report.near_miss_len > 0);
    try std.testing.expect(report.near_misses[0].reason.kind != .none);
}

test "example parity: instrumentation hooks" {
    const Hooks = struct {
        parse_start_calls: usize = 0,
        parse_end_calls: usize = 0,
        query_start_calls: usize = 0,
        query_end_calls: usize = 0,

        pub fn onParseStart(self: *@This(), _: usize) void {
            self.parse_start_calls += 1;
        }
        pub fn onParseEnd(self: *@This(), _: html.ParseInstrumentationStats) void {
            self.parse_end_calls += 1;
        }
        pub fn onQueryStart(self: *@This(), _: html.QueryInstrumentationKind, _: usize) void {
            self.query_start_calls += 1;
        }
        pub fn onQueryEnd(self: *@This(), _: html.QueryInstrumentationStats) void {
            self.query_end_calls += 1;
        }
    };

    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
    var hooks: Hooks = .{};

    var input = "<div><span id='x'></span></div>".*;
    try html.parseWithHooks(&doc, &input, .{}, &hooks);
    _ = try html.queryOneRuntimeWithHooks(&doc, "span#x", &hooks);

    try std.testing.expectEqual(@as(usize, 1), hooks.parse_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.parse_end_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.query_start_calls);
    try std.testing.expectEqual(@as(usize, 1), hooks.query_end_calls);
}
