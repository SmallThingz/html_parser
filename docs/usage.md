# Usage Guide

## 1) Parse a Document

```zig
const std = @import("std");
const html = @import("htmlparser");

test "parse document" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<html><body><h1 id='t'>Hi &amp; there</h1></body></html>".*;
    try doc.parse(&input, .{});

    const h1 = doc.queryOne("h1#t") orelse return error.TestUnexpectedResult;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const text = try h1.innerText(arena.allocator());
    try std.testing.expectEqualStrings("Hi & there", text);
}
```

## 2) Compile Selectors Once

Use this pattern for high-throughput repeated queries.

```zig
const std = @import("std");
const html = @import("htmlparser");

test "compiled selector" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var src = "<div><a id='x' href='https://e' class='nav button'></a></div>".*;
    try doc.parse(&src, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");
    const node = doc.queryOneCompiled(&sel) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("x", node.getAttributeValue("id").?);
}
```

## 3) Runtime Selector APIs

```zig
const one = try doc.queryOneRuntime("div.card > a.primary");
var it = try doc.queryAllRuntime("ul#menu li.item");
while (it.next()) |node| {
    _ = node;
}
```

`queryAllRuntime` iterators are invalidated by creating a newer runtime `queryAllRuntime` iterator on the same document.

## 4) Navigation APIs

```zig
const root = doc.queryOne("div#root") orelse return error.TestUnexpectedResult;
const first = root.firstChild();
const last = root.lastChild();
const siblings = root.children(); // borrowed slice
_ = .{ first, last, siblings };
```

## 5) `innerText` Options

Default behavior normalizes whitespace.

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const normalized = try node.innerText(arena.allocator());
const raw = try node.innerTextWithOptions(arena.allocator(), .{ .normalize_whitespace = false });
_ = .{ normalized, raw };
```

## 6) Parse Options

```zig
try doc.parse(&input, .{
    .store_parent_pointers = true,
    .normalize_input = true,
    .normalize_text_on_parse = false,
    .eager_child_views = true,
    .eager_attr_empty_rewrite = true,
    .turbo_parse = false,
    .permissive_recovery = true,
});
```

## Notes

- Input is mutated in-place; do not treat the original bytes as immutable after parsing.
- Keep `Document` alive while using returned `*const Node` pointers.
- `Document.clear()`/`parse()` invalidate assumptions about previous runtime selector caches.
