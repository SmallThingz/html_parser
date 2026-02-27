# htmlparser Manual

This is the single source of truth for library usage, behavior contracts, performance workflow, and implementation notes.

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Core API](#core-api)
- [Selector Support](#selector-support)
- [Mode Guidance](#mode-guidance)
- [Performance and Benchmarks](#performance-and-benchmarks)
- [Conformance Status](#conformance-status)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Requirements

- Zig `0.15.2`
- Mutable input buffers (`[]u8`) for parsing

## Quick Start

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

Canonical examples live in `examples/` and are verified by `zig build examples-check`

## Core API

### `Document` factory and lifecycle

- `const opts: ParseOptions = .{};`
- `const Document = opts.GetDocument();`
- `Document.init(allocator)`
- `doc.deinit()`
- `doc.clear()`
- `doc.parse(input: []u8, comptime opts: ParseOptions)`

### Query APIs

- Compile-time selectors:
  - `doc.queryOne(comptime selector)`
  - `doc.queryAll(comptime selector)`
- Runtime selectors:
  - `try doc.queryOneRuntime(selector)`
  - `try doc.queryAllRuntime(selector)`
- Cached runtime selectors:
  - `doc.queryOneCached(&selector)`
  - `doc.queryAllCached(&selector)`
  - selector created via `try Selector.compileRuntime(allocator, source)`
- Diagnostics:
  - `doc.queryOneDebug(comptime selector, report)`
  - `try doc.queryOneRuntimeDebug(selector, report)`

### Node APIs

- Navigation:
  - `tagName()`
  - `parentNode()`
  - `firstChild()`
  - `lastChild()`
  - `nextSibling()`
  - `prevSibling()`
  - `children()` (borrowed `[]const u32` index view)
- Text:
  - `innerText(allocator)` (may return borrowed or allocated)
  - `innerTextWithOptions(allocator, TextOptions)`
  - `innerTextOwned(allocator)` (always allocated)
  - `innerTextOwnedWithOptions(allocator, TextOptions)`
- Attributes:
  - `getAttributeValue(name)`
- Scoped queries:
  - same query family as `Document` (`queryOne/queryAll`, runtime, cached, debug)

### Additional helpers

- `doc.html()`, `doc.head()`, `doc.body()`
- `doc.isOwned(slice)` to check whether a returned slice points into document source bytes

### Options

- `ParseOptions`
  - `eager_child_views: bool = true`
  - `drop_whitespace_text_nodes: bool = false`
- `TextOptions`
  - `normalize_whitespace: bool = true`

### Instrumentation wrappers

- `parseWithHooks(doc, input, opts, hooks)`
- `queryOneRuntimeWithHooks(doc, selector, hooks)`
- `queryOneCachedWithHooks(doc, selector, hooks)`
- `queryAllRuntimeWithHooks(doc, selector, hooks)`
- `queryAllCachedWithHooks(doc, selector, hooks)`

## Selector Support

Supported selectors:

- tag selectors and universal `*`
- `#id`, `.class`
- attributes:
  - `[a]`, `[a=v]`, `[a^=v]`, `[a$=v]`, `[a*=v]`, `[a~=v]`, `[a|=v]`
- combinators:
  - descendant (`a b`)
  - child (`a > b`)
  - adjacent sibling (`a + b`)
  - general sibling (`a ~ b`)
- grouping: `a, b, c`
- pseudo-classes:
  - `:first-child`
  - `:last-child`
  - `:nth-child(An+B)` with `odd/even` and forms like `3n+1`, `+3n-2`, `-n+6`
  - `:not(...)` (simple selector payload)

Compilation modes:

- comptime selectors fail at compile time when invalid
- runtime selectors return `error.InvalidSelector`

## Mode Guidance

`htmlparser` is permissive by design. Choose parse options per site behavior:

| Mode | Parse Options | Best For | Tradeoffs |
|---|---|---|---|
| `strictest` | `.eager_child_views = true`, `.drop_whitespace_text_nodes = false` | Maximum traversal predictability and text fidelity | More parse-time work |
| `fastest` | `.eager_child_views = false`, `.drop_whitespace_text_nodes = true` | Throughput-first scraping | Whitespace-only text nodes dropped; child views built lazily |

Fallback playbook:

1. Start with `fastest` for bulk workloads.
2. Switch problematic domains to `strictest` if text/navigation assumptions fail.
3. Use `queryOneRuntimeDebug` and inspect `QueryDebugReport` before changing selectors.

## Performance and Benchmarks

Run benchmarks:

```bash
zig build bench-compare
zig build tools -- run-benchmarks --profile quick
zig build tools -- run-benchmarks --profile stable
```

Artifacts:

- `bench/results/latest.md`
- `bench/results/latest.json`

Notes:

- parse comparisons include `strlen`, `lexbor`, and parse-only `lol-html`
- query parse/match/cached sections benchmark `htmlparser`
- repeated runtime selector workloads should use cached selectors

## Conformance Status

Run conformance suites:

```bash
zig build conformance
# or
zig build tools -- run-external-suites --mode both
```

Report artifact: `bench/results/external_suite_report.json`

Tracked suites:

- selector suites: `nwmatcher`, `qwery_contextual`
- parser suite: html5lib tree-construction compatibility subset

## Architecture

Core modules:

- `src/html/parser.zig`: permissive parse pipeline
- `src/html/scanner.zig`: byte-scanning hot-path helpers
- `src/html/tags.zig`: tag metadata and hash dispatch
- `src/html/attr_inline.zig`: in-place attribute traversal/lazy materialization
- `src/html/entities.zig`: entity decode utilities
- `src/selector/runtime.zig`, `src/selector/compile_time.zig`: selector parsing
- `src/selector/matcher.zig`: selector matching/combinator traversal

Data model highlights:

- `Document` owns source bytes and node/index storage
- nodes are contiguous and linked by indexes for traversal
- attributes are traversed directly from source spans (no heap attr objects)

## Troubleshooting

### Query returns nothing

- validate selector syntax (`queryOneRuntime` returns `error.InvalidSelector`)
- check query scope (`Document` vs scoped `Node`)
- use `queryOneRuntimeDebug` + `QueryDebugReport` for near-miss reasons

### Unexpected `innerText`

- default `innerText` normalizes whitespace
- use `innerTextWithOptions(..., .{ .normalize_whitespace = false })` for raw spacing
- use `innerTextOwned(...)` when you always require allocated output
- use `doc.isOwned(slice)` to check borrowed vs allocated

### Runtime iterator invalidation

`queryAllRuntime` iterators are invalidated by newer `queryAllRuntime` calls on the same `Document`.

### Input buffer changed

Expected behavior: parsing and lazy decode paths mutate source bytes in place.
