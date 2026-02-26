# API Reference

## `Document` Type Factory

Construct a document type from parse options:

- `const opts: ParseOptions = .{};`
- `const Document = opts.GetDocument();`

Lifecycle:

- `Document.init(allocator)`
- `doc.deinit()`
- `doc.clear()`
- `doc.parse(input: []u8, comptime opts: ParseOptions)`

Query entrypoints:

- `doc.queryOne(comptime selector)`
- `doc.queryAll(comptime selector)`
- `try doc.queryOneRuntime(selector)`
- `try doc.queryAllRuntime(selector)`
- `doc.queryOneCompiled(&selector)`
- `doc.queryAllCompiled(&selector)`

Helpers:

- `doc.html()`
- `doc.head()`
- `doc.body()`

## `Node`

Element/navigation:

- `tagName()`
- `parentNode()`
- `firstChild()`
- `lastChild()`
- `nextSibling()`
- `prevSibling()`
- `children()` (borrowed slice)

Content/attributes:

- `getAttributeValue(name)`
- `innerText(arena_allocator)`
- `innerTextWithOptions(arena_allocator, TextOptions)`

Scoped query entrypoints:

- `queryOne(comptime selector)`
- `queryAll(comptime selector)`
- `try queryOneRuntime(selector)`
- `try queryAllRuntime(selector)`
- `queryOneCompiled(&selector)`
- `queryAllCompiled(&selector)`

## `Selector`

- `Selector.compile(comptime source)`
- `try Selector.compileRuntime(allocator, source)`
- `selector.deinit(allocator)` (for runtime-owned selector storage)

## `ParseOptions`

- `eager_child_views: bool = true`
- `drop_whitespace_text_nodes: bool = false`

## `TextOptions`

- `normalize_whitespace: bool = true`

## Lifetime and Safety Notes

- Nodes borrow from their owning `Document`.
- Parsing is destructive over the input byte slice.
- Reparsing or clearing a document invalidates prior traversal/query assumptions.
