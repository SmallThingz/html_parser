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

## Runtime vs Compiled Selectors

Use runtime convenience calls when selector strings are dynamic:

```zig
const one = try doc.queryOneRuntime("a.primary");
var it = try doc.queryAllRuntime("a[href]");
```

Use compiled selectors for repeated execution:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https][class~=button]");
const node = doc.queryOneCompiled(&sel);
_ = node;
```

Source of truth: `examples/runtime_selector.zig` and `examples/compiled_selector.zig`.

## Parse Options

```zig
try doc.parse(&input, .{
    .store_parent_pointers = true,
    .normalize_input = true,
    .normalize_text_on_parse = false,
    .eager_child_views = true,
    .eager_attr_empty_rewrite = true,
    .defer_attribute_parsing = false,
});
```

## Release Checks

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```
