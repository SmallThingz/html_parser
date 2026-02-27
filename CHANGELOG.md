# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Compatibility

- Impact: Breaking
- Migration: Required
- Downstream scope: Medium

### Added

- Initial OSS release documentation set.
- Canonical executable examples under `examples/`.
- `docs-check`, `examples-check`, and `ship-check` build/tooling steps.
- MIT license and contributor/security policy docs.

### Changed

- Removed legacy `queryOneCompiled`/`queryAllCompiled` naming from public API and docs.
- Renamed precompiled-selector query API to `queryOneCached`/`queryAllCached`.
- Renamed instrumentation wrappers to `queryOneCachedWithHooks`/`queryAllCachedWithHooks`.
- Renamed benchmark command/sections from `query-compiled` to `query-cached`.
