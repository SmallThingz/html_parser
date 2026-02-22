# Benchmark Suite

This directory benchmarks `htmlparser` against other high-performance HTML parsers:

- `lexbor` (C, HTML5 parser)
- `gumbo-modern` (maintained Gumbo fork, C, HTML5 parser)
- `html5ever` (Rust, browser-grade HTML5 parser)

It also benchmarks `htmlparser` query parsing throughput (runtime selector compile path).

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

## Run

```bash
./bench/run_benchmarks.py
```

Or run the full setup + comparison from Zig build:

```bash
zig build bench-compare
```

Results are written to:

- `bench/results/latest.json`
- `bench/results/latest.md`
