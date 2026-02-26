# Architecture

## High-Level Components

- `src/html/parser.zig`: permissive HTML parse pipeline.
- `src/html/scanner.zig`: byte-scanning primitives and hot-loop helpers.
- `src/html/tags.zig`: tag metadata and hash-based dispatch helpers.
- `src/html/attr_inline.zig`: in-place attribute traversal and lazy value materialization.
- `src/html/entities.zig`: in-place HTML entity decode utilities.
- `src/selector/runtime.zig` and `src/selector/compile_time.zig`: selector parsers.
- `src/selector/matcher.zig`: selector matching and combinator traversal.

## Data Model

- `Document` owns source bytes, nodes, runtime selector caches, and child pointer storage.
- Nodes are contiguous in parse order and linked by index for parent/sibling/child navigation.
- Attributes are not represented as heap objects; they are traversed directly from input byte ranges.

## Query Execution Model

- Comptime selectors compile at compile time.
- Runtime selectors compile once and are cached per query API path.
- Matching is short-circuit oriented on hot paths.

## Parse Behavior Model

- Parser is permissive and attempts recovery for malformed markup.
- Raw-text elements and optional-close behavior use table/tag-aware logic.
- Parse options can defer attribute parsing and child-view materialization when needed.
