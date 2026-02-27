# htmlparser

High-throughput, destructive HTML parser + CSS selector engine for Zig.

[![zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
[![mode](https://img.shields.io/badge/parse-mutable%20input%20%28destructive%29-critical)](./DOCUMENTATION.md#mode-guidance)

## Performance

Warning: performance numbers are not conformance claims. This parser is intentionally permissive; see [Conformance Status](./DOCUMENTATION.md#conformance-status).

- Benchmark workflow: [Performance and Benchmarks](./DOCUMENTATION.md#performance-and-benchmarks)
- Latest snapshot: [Latest Benchmark Snapshot](./DOCUMENTATION.md#latest-benchmark-snapshot)
- Raw benchmark outputs:
  - `bench/results/latest.md`
  - `bench/results/latest.json`

<!-- README_AUTO_SUMMARY:START -->

Source: `bench/results/latest.json` (`stable` profile).

### Parse Throughput (Average Across Fixtures)

| Parser | Avg Throughput (MB/s) | % of leader | Relative chart |
|---|---:|---:|---|
| `ours-fastest` | 1430.30 | 100.00% | `####################` |
| `ours-strictest` | 1387.91 | 97.04% | `###################` |
| `lol-html` | 1145.97 | 80.12% | `################` |
| `lexbor` | 262.85 | 18.38% | `####` |

### Conformance Snapshot

| Profile | nwmatcher | qwery_contextual | html5lib subset |
|---|---:|---:|---:|
| `strictest/fastest` | 20/20 (0 failed) | 54/54 (0 failed) | 539/600 (61 failed) |

Source: `bench/results/external_suite_report.json`
<!-- README_AUTO_SUMMARY:END -->

## Quick Start

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

## API Surface

- compile-time selectors: `queryOne`, `queryAll`
- runtime selectors: `queryOneRuntime`, `queryAllRuntime`
- cached runtime selectors: `queryOneCached`, `queryAllCached`
- diagnostics: `queryOneDebug`, `queryOneRuntimeDebug`
- instrumentation wrappers:
  - `parseWithHooks`
  - `queryOneRuntimeWithHooks`, `queryAllRuntimeWithHooks`
  - `queryOneCachedWithHooks`, `queryAllCachedWithHooks`
- text extraction:
  - `innerText`, `innerTextWithOptions`
  - `innerTextOwned`, `innerTextOwnedWithOptions`
  - ownership check: `doc.isOwned(slice)`

## Documentation

- Full manual: [Documentation](./DOCUMENTATION.md)
- API details: [Documentation#core-api](./DOCUMENTATION.md#core-api)
- Selector grammar: [Documentation#selector-support](./DOCUMENTATION.md#selector-support)
- Parse mode guidance: [Documentation#mode-guidance](./DOCUMENTATION.md#mode-guidance)
- Conformance: [Documentation#conformance-status](./DOCUMENTATION.md#conformance-status)
- Architecture: [Documentation#architecture](./DOCUMENTATION.md#architecture)
- Troubleshooting: [Documentation#troubleshooting](./DOCUMENTATION.md#troubleshooting)

## Build and Validation

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

## License

MIT. See [LICENSE](./LICENSE).
