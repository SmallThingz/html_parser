# Performance Guide

## Modes

- `strict` mode (`turbo_parse = false`): default semantics and eager parse behavior.
- `turbo` mode (`turbo_parse = true`): parse-throughput-oriented path that defers non-essential work.

Typical turbo configuration:

```zig
try doc.parse(&input, .{
    .turbo_parse = true,
    .eager_child_views = false,
    .eager_attr_empty_rewrite = false,
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

- Parse throughput is benchmarked against `strlen`, `lexbor`, `gumbo-modern`, `html5ever`, and parse-only `lol-html`.
- Query parse/match sections are measured on `htmlparser` only.
- For repeated runtime selector workloads, prefer `Selector.compileRuntime` + `query*Compiled` APIs.

## Methodology

- ReleaseFast builds.
- Fixed fixture set under `bench/fixtures/`.
- Iteration profiles: `quick` and `stable`.
- Create+destroy per parse iteration for parity.
