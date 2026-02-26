# htmlparser

High-throughput, destructive HTML parser + CSS selector engine for Zig.

[![zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![mode](https://img.shields.io/badge/parse-mutable%20input%20%28destructive%29-critical)](#design-contract)

`htmlparser` is built for pipelines where the HTML input is mutable (`[]u8`), throughput matters, and “best-effort DOM” is acceptable.

## Why This Exists

Typical HTML parsers optimize for browser-like behavior, strict correctness, or safety-by-copy. This library optimizes for:

- minimal overhead when you can reuse and mutate the input buffer
- high query throughput (selectors + navigation)
- permissive recovery on imperfect HTML

## Highlights

- **Destructive parse:** parses from mutable input (`[]u8`) and may rewrite bytes in-place.
- **DOM + selectors:** parse once, then query fast with selector APIs and node navigation.
- **Selector flavors:**
  - compile-time selectors: `queryOne`, `queryAll`
  - runtime selectors: `queryOneRuntime`, `queryAllRuntime`
  - precompiled runtime selectors: `queryOneCompiled`, `queryAllCompiled`
- **Navigation:** `parentNode`, `firstChild`, `lastChild`, `nextSibling`, `prevSibling`, `children` (element-only).
- **In-place attributes:** attribute values are materialized/decoded lazily and cached in-place.
- **Configurable parse work:** parent pointers, input normalization, deferred attribute parsing, eager/lazy child views.

Target Zig version: `0.15.2`.

## Installation

As a local dependency (path-based):

```bash
zig fetch --save path:.
```

Then import in Zig code:

```zig
const html = @import("htmlparser");
```

## Quick Start (Test-Backed)

This snippet matches `examples/basic_parse_query.zig`.

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

## Query APIs

### Compile-time selectors

Compile the selector at comptime, match at runtime:

```zig
const node = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
```

### Runtime selectors

Parse the selector at runtime (useful for user input):

```zig
const node = (try doc.queryOneRuntime("a[href^=https]")) orelse return;
```

### Precompiled runtime selectors

Compile once (runtime), run many queries:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https]");
const node = doc.queryOneCompiled(&sel);
```

## Parse Option Recipes

Two bundles are used by the benchmark harness and conformance runner:

### Strictest (does the most work)

- parent pointers on
- input normalization on (lowercases tag/attr names)
- parse-time text normalization on
- eager child views on
- eager empty-attribute rewrite on (`a=` canonicalization)
- deferred attribute parsing off

### Fastest (does the least work)

- parent pointers off initially
- input normalization off
- parse-time text normalization off
- eager child views off (child views are built lazily if `children()` is called)
- eager empty-attribute rewrite off (rewrite happens lazily if/when a value is materialized)
- deferred attribute parsing on

**Important:** query semantics are mode-invariant. If a selector requires ancestry (for example `A B`, `A > B`, `:nth-child(...)`), parent pointers are materialized lazily on first such query, even if they were disabled during parse.

## Selector Support (v1)

Supported (intentionally limited scope):

- element/tag selectors, universal (`*`)
- `#id`, `.class`
- attribute selectors: `[a] [a=v] [a^=v] [a$=v] [a*=v] [a~=v] [a|=v]`
- combinators: descendant, child (`>`), adjacent (`+`), sibling (`~`)
- grouping: comma-separated selectors
- pseudo-classes: `:first-child`, `:last-child`, `:nth-child(An+B)` (includes `odd`/`even`)
- `:not(...)` (simple selectors only)

See `docs/selectors.md` for the exact grammar and constraints.

## Design Contract

- Input is mutable and destructively parsed (the buffer may be rewritten during parse and lazy decode).
- Node handles are valid while the owning `Document` is alive and not reparsed/cleared.
- `queryAllRuntime` iterators are invalidated by newer `queryAllRuntime` calls on the same document.
- `innerText` may allocate when concatenation is required.
- Permissive parsing is a goal; strict browser parity is not.

## Build and Validation

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

## Benchmarking

Runs the benchmark suite and produces Markdown/JSON output in `bench/results/`:

```bash
zig build bench-compare
```

The benchmark harness includes a “fastest vs lol-html” parse-throughput gate in the `stable` profile. See `bench/README.md` for details.

## Conformance

Runs known-good external selector and parser suites (both `strictest` and `fastest` modes):

```bash
zig build conformance
```

See `docs/conformance.md` for what’s covered and what’s intentionally out of scope.

## Documentation

See `docs/README.md`.

## License

MIT. See `LICENSE`.
