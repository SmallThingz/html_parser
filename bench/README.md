# Benchmark Suite

This directory benchmarks `htmlparser` against other high-performance HTML parsers:

- `strlen` baseline (C) for raw string scan comparison
- `lexbor` (C, HTML5 parser)
- `gumbo-modern` (maintained Gumbo fork, C, HTML5 parser)
- `html5ever` (Rust, browser-grade HTML5 parser)
- `lol-html` (Rust, streaming rewriter/parser; parse-only comparison in this suite)

It also benchmarks `htmlparser` query parsing throughput (runtime selector compile path).
Query sections remain `htmlparser`-only; external parser comparisons are parse throughput only.

Default fixture set includes:
- `rust-lang.html`
- `wiki-html.html`
- `mdn-html.html`
- `w3-html52.html`
- `hn.html`

## Setup

```bash
./bench/setup_parsers.sh
./bench/setup_fixtures.sh
```

`setup_fixtures.sh` now caches downloads: existing non-empty fixture files are reused.
To force refresh all fixture downloads:

```bash
./bench/setup_fixtures.sh --refresh
# or
FORCE_REFRESH=1 ./bench/setup_fixtures.sh
```

## Run

```bash
./bench/run_benchmarks.py
# default profile is quick
./bench/run_benchmarks.py --profile quick
# low-noise acceptance profile
./bench/run_benchmarks.py --profile stable
# write baseline for current profile (used by gate checks)
./bench/run_benchmarks.py --profile stable --write-baseline
# compare against explicit baseline file
./bench/run_benchmarks.py --profile stable --baseline bench/results/baseline_stable.json
```

Or run the full setup + comparison from Zig build:

```bash
zig build bench-compare
```

Results are written to:

- `bench/results/latest.json`
- `bench/results/latest.md`
