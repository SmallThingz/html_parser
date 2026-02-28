# 🚀 htmlparser

High-throughput, destructive HTML parser + CSS selector engine for Zig.

[![zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
[![mode](https://img.shields.io/badge/parse-mutable%20input%20%28destructive%29-critical)](./DOCUMENTATION.md#mode-guidance)

## ⚠️ Conformance Warning

Performance numbers are **not** conformance claims. The parser is intentionally permissive and currently does not fully match browser-grade tree-construction behavior.

- Conformance details: [Documentation#conformance-status](./DOCUMENTATION.md#conformance-status)
- Benchmark methodology: [Documentation#performance-and-benchmarks](./DOCUMENTATION.md#performance-and-benchmarks)
- Raw outputs: `bench/results/latest.md`, `bench/results/latest.json`

## 🏁 Performance

<!-- README_AUTO_SUMMARY:START -->

Source: `bench/results/latest.json` (`stable` profile).

### Parse Throughput (Average Across Fixtures)

```text
ours-fastest   │████████████████████│ 1430.30 MB/s (100.00%)
ours-strictest │███████████████████░│ 1387.91 MB/s (97.04%)
lol-html       │████████████████░░░░│ 1145.97 MB/s (80.12%)
lexbor         │████░░░░░░░░░░░░░░░░│ 262.85 MB/s (18.38%)
```

### Conformance Snapshot

| Profile | nwmatcher | qwery_contextual | html5lib subset | WHATWG HTML parsing | WPT HTML parsing |
|---|---:|---:|---:|---:|---:|
| `strictest/fastest` | 20/20 (0 failed) | 54/54 (0 failed) | 539/600 (61 failed) | 432/500 (68 failed) | 432/500 (68 failed) |

Source: `bench/results/external_suite_report.json`
<!-- README_AUTO_SUMMARY:END -->

## ⚡ Features

- 🔎 CSS selector queries: comptime, runtime, and cached runtime selectors.
- 🧭 DOM navigation: parent, siblings, first/last child, and children iteration.
- 🧪 Debug tooling: selector mismatch diagnostics and instrumentation wrappers.
- 🧰 Parse profiles: `strictest` and `fastest` option bundles for benchmarks/workloads.
- 🧵 Mutable-input parser model optimized for throughput.

## 🚀 Quick Start

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

## 📚 Documentation

- Full manual: [Documentation](./DOCUMENTATION.md)
- API details: [Documentation#core-api](./DOCUMENTATION.md#core-api)
- Selector grammar: [Documentation#selector-support](./DOCUMENTATION.md#selector-support)
- Parse mode guidance: [Documentation#mode-guidance](./DOCUMENTATION.md#mode-guidance)
- Conformance: [Documentation#conformance-status](./DOCUMENTATION.md#conformance-status)
- Architecture: [Documentation#architecture](./DOCUMENTATION.md#architecture)
- Troubleshooting: [Documentation#troubleshooting](./DOCUMENTATION.md#troubleshooting)

## 🧪 Build and Validation

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

## 📜 License

MIT. See [LICENSE](./LICENSE).
