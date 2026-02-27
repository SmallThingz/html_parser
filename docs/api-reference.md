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
- `doc.queryOneCached(&selector)`
- `doc.queryAllCached(&selector)`
- `doc.queryOneDebug(comptime selector, report)`
- `try doc.queryOneRuntimeDebug(selector, report)`

Helpers:

- `doc.html()`
- `doc.head()`
- `doc.body()`
- `doc.isOwned(slice)` (true when `slice` points into document source bytes)

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
- `innerTextOwned(arena_allocator)` (always allocates; never decodes in-place)
- `innerTextOwnedWithOptions(arena_allocator, TextOptions)`
- `children()` returns borrowed `[]const u32` child indexes

Scoped query entrypoints:

- `queryOne(comptime selector)`
- `queryAll(comptime selector)`
- `try queryOneRuntime(selector)`
- `try queryAllRuntime(selector)`
- `queryOneCached(&selector)`
- `queryAllCached(&selector)`
- `queryOneDebug(comptime selector, report)`
- `try queryOneRuntimeDebug(selector, report)`

## `Selector`

- `Selector.compile(comptime source)`
- `try Selector.compileRuntime(allocator, source)`
- `selector.deinit(allocator)` (for runtime-owned selector storage)

## `ParseOptions`

- `eager_child_views: bool = true`
- `drop_whitespace_text_nodes: bool = false`

## `TextOptions`

- `normalize_whitespace: bool = true`

## Debug/Instrumentation Types

- `QueryDebugReport` and related debug enums (`DebugFailureKind`, `NearMiss`)
- Wrapper helpers:
  - `parseWithHooks(doc, input, opts, hooks)`
  - `queryOneRuntimeWithHooks(doc, selector, hooks)`
  - `queryOneCachedWithHooks(doc, selector, hooks)`
  - `queryAllRuntimeWithHooks(doc, selector, hooks)`
  - `queryAllCachedWithHooks(doc, selector, hooks)`

## Lifetime and Safety Notes

- Nodes borrow from their owning `Document`.
- Parsing is destructive over the input byte slice.
- Reparsing or clearing a document invalidates prior traversal/query assumptions.
