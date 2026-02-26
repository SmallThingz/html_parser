# Malformed HTML Guidance

This parser is permissive by design. For unreliable web HTML, choose parse options based on what your pipeline needs to optimize.

## Mode Matrix

| Mode | Parse Options | Best For | Tradeoffs |
|---|---|---|---|
| `strictest` | `.eager_child_views = true`, `.drop_whitespace_text_nodes = false` | Maximum traversal predictability and content fidelity | Higher parse-time work and memory traffic |
| `fastest` | `.eager_child_views = false`, `.drop_whitespace_text_nodes = true` | Throughput-first extraction and selector-heavy scraping | Whitespace-only text nodes are dropped; child views materialize lazily on first `children()` |

## Practical Fallback Playbook

1. Start in `fastest` for bulk scraping.
2. If a target site shows unstable text extraction or navigation assumptions, switch that site to `strictest`.
3. Keep selectors robust:
4. Prefer anchored selectors (`#id`, stable attrs) over deep sibling chains.
5. Avoid dependence on whitespace-only text nodes.
6. Use `queryOneRuntimeDebug` to inspect non-match reasons before changing selectors.

## Example

```zig
try doc.parse(&input, .{
    .eager_child_views = false,
    .drop_whitespace_text_nodes = true,
});

var report: html.QueryDebugReport = .{};
const node = try doc.queryOneRuntimeDebug("article .title > a", &report);
if (node == null) {
    // Inspect report.near_misses and report.visited_elements
}
```
