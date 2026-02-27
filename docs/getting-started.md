# Getting Started

## Requirements

- Zig `0.15.2`
- Mutable input buffers (`[]u8`) for parsing

## Parse and Query

```zig
const std = @import("std");
const html = @import("htmlparser");
const options: html.ParseOptions = .{};
const Document = options.GetDocument();

test "basic parse + query" {
    var doc = Document.init(std.testing.allocator);
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

## Debug Diagnostics and Hooks

Selector mismatch diagnostics:

```zig
var report: html.QueryDebugReport = .{};
const node = try doc.queryOneRuntimeDebug("a[href^=https]", &report);
_ = node;
```

Instrumentation wrappers:

```zig
var hooks = Hooks{};
try html.parseWithHooks(&doc, &input, .{}, &hooks);
_ = try html.queryOneRuntimeWithHooks(&doc, "a.primary", &hooks);
```

Source of truth: `examples/debug_query_report.zig` and `examples/instrumentation_hooks.zig`.

## Parse Options

```zig
try doc.parse(&input, .{
    .eager_child_views = true,
    .drop_whitespace_text_nodes = false,
});
```

## Release Checks

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```
