# Selector Reference

## Supported Selector Features

Simple selectors:

- Tag: `div`
- Universal: `*`
- ID: `#main`
- Class: `.item`

Attribute selectors:

- `[a]`
- `[a=v]`
- `[a^=v]`
- `[a$=v]`
- `[a*=v]`
- `[a~=v]`
- `[a|=v]`

Combinators:

- Descendant: `a b`
- Child: `a > b`
- Adjacent sibling: `a + b`
- General sibling: `a ~ b`

Grouping:

- `a, b, c`

Pseudo classes:

- `:first-child`
- `:last-child`
- `:nth-child(An+B)`
- `:not(...)` (simple selector payload)

`nth-child` parser supports common shorthand forms:

- `odd`
- `even`
- `3n+1`
- `+3n-2`
- `-n+6`

## Compilation Modes

Compile-time (invalid selectors fail compilation):

```zig
const first = doc.queryOne("div#app > a.nav");
var it = doc.queryAll("ul#menu li.item");
_ = .{ first, it };
```

Runtime (invalid selectors return `error.InvalidSelector`):

```zig
const one = try doc.queryOneRuntime("div#app > a.nav");
var all = try doc.queryAllRuntime("ul#menu li.item");
_ = .{ one, all };
```

Cached runtime selectors:

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https]");
const n = doc.queryOneCached(&sel);
_ = n;
```

## Current Non-Goals

- Full browser CSS selector parity is not guaranteed.
- This engine targets high-throughput server-side use cases with pragmatic semantics.
