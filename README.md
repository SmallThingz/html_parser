# htmlparser

`htmlparser` is a high-throughput, destructive HTML parser and selector engine written in Zig.

It is designed for systems where input can be mutable (`[]u8`) and parsing can be permissive.

Target Zig version: `0.15.2`.

## Key Properties

- Mutable, in-place parsing (`[]u8` input is rewritten during parse and lazy decode paths).
- Fast selector queries:
  - compile-time selectors (`queryOne`, `queryAll`),
  - runtime selectors (`queryOneRuntime`, `queryAllRuntime`),
  - precompiled runtime selectors (`queryOneCompiled`, `queryAllCompiled`).
- Element navigation APIs:
  - `parentNode`, `firstChild`, `lastChild`, `nextSibling`, `prevSibling`, `children`.
- In-place attribute state machine with lazy parse/decode.
- Parse options allow eager vs deferred attribute parsing and optional parent pointers.

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

test "basic parse + query" {
    var doc = html.Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}
```

## API Surface Summary

| Type/API | Purpose |
|---|---|
| `Document` | Parse owner, node storage, query entrypoint. |
| `Node` | Borrowed handle for navigation, attributes, text extraction, scoped queries. |
| `Selector` | Compiled selector representation (`compile` / `compileRuntime`). |
| `ParseOptions` | Parse behavior knobs (normalization, parent pointers, deferred attr parsing, eager views). |
| `TextOptions` | Text extraction options (`normalize_whitespace`). |

## Operational Caveats

- Input is mutable and destructively parsed.
- `*const Node` pointers are valid while the owning `Document` is alive and not reparsed/cleared.
- `queryAllRuntime` iterators are invalidated by newer `queryAllRuntime` calls on the same document.
- `innerText` may allocate when concatenation is required.

## Build and Validation

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

## Benchmarking and Conformance

```bash
zig build bench-compare
zig build conformance
```

## Documentation

See `docs/README.md`.

## License

MIT. See `LICENSE`.
