# Conformance Notes

`htmlparser` prioritizes permissive parsing and throughput over strict browser-perfect parity.

Conformance command:

```bash
zig build conformance
# or
zig build tools -- run-external-suites --mode both
```

Report artifact:

- `bench/results/external_suite_report.json`

Current tracked suites:

- Selector suites: `nwmatcher`, `qwery_contextual`
- Parser suite: html5lib tree-construction compatibility subset

Latest maintained score target in this repository:

- Selector: `nwmatcher 20/20`, `qwery_contextual 54/54`
- Parser subset: `539/600`

Interpretation:

- Selector coverage is strong for the implemented feature set.
- Parser subset includes known divergences due to permissive, performance-first behavior.
