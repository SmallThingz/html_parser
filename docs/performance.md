# Performance and Benchmarking

## What Is Optimized

- Parse hot loops use table-driven character classes and scanner jump primitives.
- Attribute matching uses an in-place lazy attribute state machine.
- Compile-time selectors remove runtime parse overhead for static queries.
- Runtime query wrappers include one-entry selector caches for repeated selectors.

## Running Benchmarks

### Full comparison

```bash
zig build bench-compare
```

### Manual benchmark executable

```bash
zig build bench -- parse
zig build bench -- query-match
```

## Bench Output

Benchmark reports are written to:

- `bench/results/latest.md`
- `bench/results/latest.json`

The parse table may include streaming parsers (for example `lol-html`) as parse-only comparators.

## Practical Tuning

- For lowest latency query loops, precompile selectors once and call `queryOneCompiled` / `queryAllCompiled`.
- For max parse throughput experiments, set `turbo_parse = true`.
- If your workflow calls `children()` heavily, `eager_child_views = true` avoids first-call lazy build cost.
