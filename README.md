# htmlparser

A high-throughput, destructive, non-alloc-first HTML parser and selector engine written in Zig.

## Status

This library is tuned for speed and permissive parsing behavior. It is ready for integration in systems where:

- input can be mutable (`[]u8`) and may be rewritten in place,
- browser-perfect HTML5 behavior is not required,
- query/navigation hot paths should avoid allocations.

Target Zig version: `0.15.2`.

## Key Features

- Document and fragment parsing.
- CSS-like selector queries:
  - `queryOne` / `queryAll` (compile-time selector strings),
  - `queryOneRuntime` / `queryAllRuntime` (runtime selector strings),
  - `queryOneCompiled` / `queryAllCompiled` (precompiled selectors).
- Element navigation:
  - `parentNode`, `firstChild`, `lastChild`, `nextSibling`, `prevSibling`, `children`.
- In-place attribute engine:
  - lazy parse/decode of attribute values,
  - no attribute-object allocation in the query hot path.
- `innerText` with configurable whitespace normalization.
- Optional turbo parsing mode for benchmark-oriented throughput.

## Quick Start

```zig
const std = @import("std");
const html = @import("htmlparser");

test "quick start" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}
```

## Documentation

- `/home/a/projects/zig/htmlparser/docs/overview.md`
- `/home/a/projects/zig/htmlparser/docs/usage.md`
- `/home/a/projects/zig/htmlparser/docs/selectors.md`
- `/home/a/projects/zig/htmlparser/docs/performance.md`

## Running Tests

```bash
zig test /home/a/projects/zig/htmlparser/src/root.zig
```

or:

```bash
zig build test
```

## Benchmarking

```bash
zig build bench-compare
```

This runs parse/query benchmark suites and writes reports under `bench/results/`.
