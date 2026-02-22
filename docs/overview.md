# Overview

`htmlparser` is a mutable-input HTML parser with a selector engine optimized for low-overhead querying.

## Core Model

- Parsing consumes `[]u8` and may rewrite bytes in place.
- Parsed nodes are stored in contiguous arrays.
- Public query/navigation returns `*const Node` pointers that are stable after parse completion.
- Attribute values are parsed lazily from the source bytes.

## Allocation Strategy

Hot paths are non-alloc by default:

- Parse and selector matching are allocation-minimized.
- `queryOne`, `queryAll`, and navigation APIs avoid per-query allocations.
- `children()` returns a borrowed precomputed slice.

Allocations may happen in these cases:

- `innerText(...)` when concatenating multiple text nodes.
- runtime selector compilation (`queryOneRuntime` / `queryAllRuntime`) on cache misses.

## Parsing Modes

`ParseOptions`:

- `store_parent_pointers`:
  - if `false`, `parentNode()` returns `null`.
- `normalize_input`:
  - lowercases tag/attribute names in-place.
- `normalize_text_on_parse`:
  - normalizes text nodes during parse.
- `eager_child_views`:
  - builds child-view slices during parse; otherwise built lazily.
- `eager_attr_empty_rewrite`:
  - rewrites explicit empty assignments (`a=`) during parse.
- `turbo_parse`:
  - benchmark-oriented mode that skips expensive parse work where possible.
- `permissive_recovery`:
  - keeps best-effort parsing behavior on malformed input.

## Selector Compilation Modes

- `queryOne("...")` / `queryAll("...")`:
  - compile-time selector parsing for comptime strings.
- `Selector.compileRuntime(alloc, "...")` + compiled queries:
  - one-time runtime compile + repeated execution.
- `queryOneRuntime("...")` / `queryAllRuntime("...")`:
  - convenience runtime wrappers with internal one-entry selector caching.
