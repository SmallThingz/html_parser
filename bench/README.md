# Benchmark Suite

This directory benchmarks `htmlparser` against other high-performance HTML parsers:

- `strlen` baseline (C) for raw string scan comparison
- `lexbor` (C, HTML5 parser)
- `lol-html` (Rust, streaming rewriter/parser; parse-only comparison in this suite)

It also benchmarks `htmlparser` query parsing throughput (runtime selector compile path).
Query sections remain `htmlparser`-only; external parser comparisons are parse throughput only.
`query-parse` is mode-independent and is measured once (`ours`) to avoid duplicate compatibility rows.

`htmlparser` parse results are reported in two internal benchmark modes:

- `ours-strictest`: most-work parse option bundle
- `ours-fastest`: least-work parse option bundle (lazy child views + whitespace text-node dropping)

Default fixture set includes:
- `rust-lang.html`
- `wiki-html.html`
- `mdn-html.html`
- `w3-html52.html`
- `hn.html`

## Setup

```bash
zig build tools -- setup-parsers
zig build tools -- setup-fixtures
```

Fixture setup caches downloads: existing non-empty files are reused.
To force refresh all fixture downloads:

```bash
zig build tools -- setup-fixtures --refresh
```

## Run

```bash
zig build tools -- run-benchmarks
# default profile is quick
zig build tools -- run-benchmarks --profile quick
# low-noise acceptance profile
zig build tools -- run-benchmarks --profile stable
# optionally write a baseline snapshot file for manual comparisons
zig build tools -- run-benchmarks --profile stable --write-baseline
# refresh DOCUMENTATION + README benchmark summary from existing latest.json/report files
zig build tools -- sync-docs-bench
```

Or run the full setup + comparison from Zig build:

```bash
zig build bench-compare
```

Results are written to:

- `bench/results/latest.json`
- `bench/results/latest.md`

`run-benchmarks` also updates:
- `DOCUMENTATION.md` benchmark snapshot block from `bench/results/latest.json`
- `README.md` auto-summary block from `bench/results/latest.json` and `bench/results/external_suite_report.json` (if present)

The benchmark output also includes a hard gate table:

- `PASS/FAIL: ours-fastest > lol-html` per fixture
