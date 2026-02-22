# Selector Reference

## Supported (v1)

- Tag: `div`
- ID: `#main`
- Class: `.item`
- Attribute selectors:
  - `[a]`
  - `[a=v]`
  - `[a^=v]`
  - `[a$=v]`
  - `[a*=v]`
  - `[a~=v]`
  - `[a|=v]`
- Combinators:
  - descendant: `a b`
  - child: `a > b`
  - adjacent sibling: `a + b`
  - general sibling: `a ~ b`
- Grouping: `a, b, c`
- Pseudo-classes:
  - `:first-child`
  - `:last-child`
  - `:nth-child(An+B)`
  - `:not(...)` (simple selector only)

## Compile-Time Selectors

```zig
const first = doc.queryOne("div#app > a.nav");
var all = doc.queryAll("ul#menu li.item");
```

Invalid compile-time selectors fail at compile time.

## Runtime Selectors

```zig
const node = try doc.queryOneRuntime("div#app > a.nav");
var it = try doc.queryAllRuntime("ul#menu li.item");
```

Invalid runtime selectors return `error.InvalidSelector`.

## Compiled Runtime Selectors

```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();

const sel = try html.Selector.compileRuntime(arena.allocator(), "a[href^=https]");
const n = doc.queryOneCompiled(&sel);
_ = n;
```

Use this for high-frequency repeated queries.
