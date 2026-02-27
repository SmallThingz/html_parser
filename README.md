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
- **Text extraction modes:** `innerText` prefers borrowed/in-place paths; `innerTextOwned` always returns allocated output.
- **Configurable parse work:** eager/lazy child views and optional whitespace-text dropping.
- **Opt-in diagnostics:** `queryOneDebug` / `queryOneRuntimeDebug` expose near-miss reasons without changing hot-path APIs.
- **Opt-in instrumentation:** compile-time hook wrappers for parse/query timing and node-count stats.

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

### Debug query diagnostics

```zig
var report: html.QueryDebugReport = .{};
const node = try doc.queryOneRuntimeDebug("a[href^=https]", &report);
if (node == null) {
    // Inspect report.visited_elements and report.near_misses
}
```

### Instrumentation hooks

```zig
var hooks = Hooks{};
try html.parseWithHooks(&doc, &input, .{}, &hooks);
_ = try html.queryOneRuntimeWithHooks(&doc, "a.primary", &hooks);
```

Reference examples:
- `examples/debug_query_report.zig`
- `examples/instrumentation_hooks.zig`

## Parse Option Recipes

Two bundles are used by the benchmark harness and conformance runner:

### Strictest (does the most work)

- eager child views on
- keep whitespace-only text nodes

### Fastest (does the least work)

- eager child views off (child views are built lazily if `children()` is called)
- drop whitespace-only text nodes during parse

`children()` returns a borrowed `[]const u32` index slice into the document's node array.

See `docs/malformed-html-guidance.md` for a mode matrix and fallback workflow on malformed pages.

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
- `innerTextOwned` always allocates and does not decode text in-place.
- `doc.isOwned(slice)` reports whether a slice points into the document source buffer.
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

`run-benchmarks` now auto-refreshes the snapshot block below from `bench/results/latest.json`.

The benchmark harness includes a “fastest vs lol-html” parse-throughput gate in the `stable` profile. See `bench/README.md` for details.

### Latest Benchmark Snapshot

<!-- BENCHMARK_SNAPSHOT:START -->

Source: `bench/results/latest.json` (`stable` profile).

#### Parse Throughput Comparison (MB/s)

| Fixture | ours-fastest | ours-strictest | lol-html | lexbor |
|---|---:|---:|---:|---:|
| `rust-lang.html` | 2082.45 | 1982.18 | 1496.85 | 340.35 |
| `wiki-html.html` | 1289.89 | 1120.64 | 1216.45 | 273.68 |
| `mdn-html.html` | 2676.82 | 2528.35 | 1853.95 | 410.77 |
| `w3-html52.html` | 973.60 | 884.27 | 747.58 | 199.74 |
| `hn.html` | 1429.47 | 1280.50 | 864.01 | 225.05 |

#### Query Match Throughput (ours)

| Case | strictest ops/s | strictest ns/op | fastest ops/s | fastest ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 145652845.18 | 6.87 | 145812129.82 | 6.86 |
| `attr-heavy-nav` | 143301582.48 | 6.98 | 144100316.88 | 6.94 |

#### Cached Query Throughput (ours)

| Case | strictest ops/s | strictest ns/op | fastest ops/s | fastest ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 214695936.88 | 4.66 | 212517267.03 | 4.71 |
| `attr-heavy-nav` | 211891791.10 | 4.72 | 203910597.44 | 4.90 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 19273218.49 | 51.89 |
| `complex` | 6549192.38 | 152.69 |
| `grouped` | 7544814.12 | 132.54 |

For full per-parser, per-fixture tables and gate output:
- `bench/results/latest.md`
- `bench/results/latest.json`
<!-- BENCHMARK_SNAPSHOT:END -->

## Conformance

Runs known-good external selector and parser suites (both `strictest` and `fastest` modes):

```bash
zig build conformance
```

See `docs/conformance.md` for what’s covered and what’s intentionally out of scope.

## Migration Notes

- `CHANGELOG.md` now includes compatibility labels in `Unreleased`:
  - `Impact: Breaking|Non-breaking`
  - `Migration: Required|Not required`
  - `Downstream scope: Small|Medium|Large`

## Documentation

See `docs/README.md`.

## License

MIT. See `LICENSE`.
