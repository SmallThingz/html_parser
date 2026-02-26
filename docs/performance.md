# Performance Guide

## Modes

- `ours-strictest`: benchmark profile that enables the most parse-time work.
- `ours-fastest`: benchmark profile that enables the least parse-time work.

Typical fastest configuration:

```zig
try doc.parse(&input, .{
    .eager_child_views = false,
    .drop_whitespace_text_nodes = true,
});
```

## Benchmark Commands

```bash
zig build bench-compare
zig build tools -- run-benchmarks --profile quick
zig build tools -- run-benchmarks --profile stable
```

Output artifacts:

- `bench/results/latest.md`
- `bench/results/latest.json`

## Throughput Notes

- Parse throughput is benchmarked against `strlen`, `lexbor`, and parse-only `lol-html`.
- Query parse/match sections are measured on `htmlparser` only.
- For repeated runtime selector workloads, prefer `Selector.compileRuntime` + `query*Compiled` APIs.

## Methodology

- ReleaseFast builds.
- Fixed fixture set under `bench/fixtures/`.
- Iteration profiles: `quick` and `stable`.
- Create+destroy per parse iteration for parity.
