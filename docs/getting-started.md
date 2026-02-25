# Getting Started

## Requirements

- Zig `0.15.2`
- Mutable input buffers (`[]u8`) for parsing

## Parse and Query

```zig
const std = @import("std");
const html = @import("htmlparser");

test "basic parse + query" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}
```

Source of truth: `examples/basic_parse_query.zig`.

## Runtime vs Cached Selectors

Use runtime convenience calls when selector strings are dynamic:

```zig
const one = try doc.queryOneRuntime("a.primary");
var it = try doc.queryAllRuntime("a[href]");
```

Use cached selectors for repeated execution:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");
const node = doc.queryOneCached(&sel);
_ = node;
```

Source of truth: `examples/runtime_selector.zig` and `examples/cached_selector.zig`.

## Parse Options

```zig
try doc.parse(&input, .{
    .store_parent_pointers = true,
    .normalize_input = true,
    .normalize_text_on_parse = false,
    .eager_child_views = true,
    .eager_attr_empty_rewrite = true,
    .turbo_parse = false,
});
```

## Release Checks

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```
