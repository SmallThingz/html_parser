# Troubleshooting

## Query Returns Nothing

Checklist:

- Verify selector syntax (`queryOneRuntime` can surface `error.InvalidSelector`).
- Confirm `normalize_input` setting matches selector casing expectations.
- Confirm you are querying the expected scope (`Document` vs `Node` scoped queries).

## Missing or Unexpected `innerText`

- `innerText` normalizes whitespace by default.
- Use `innerTextWithOptions(..., .{ .normalize_whitespace = false })` for raw spacing.

## Runtime Query Iterator Stops Early

`queryAllRuntime` iterators are invalidated by newer `queryAllRuntime` iterators on the same document.

## Parent Navigation Returns `null`

`parentNode()` requires parse option `store_parent_pointers = true`.

## Input Buffer Looks Modified

This is expected. Parsing and lazy attr/entity decode mutate the source buffer in place.

## Example Drift Policy

All user-facing snippets must be backed by code under `examples/` and verified via:

```bash
zig build examples-check
```
