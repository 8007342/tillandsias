---
tags: [logging, tracing, runtime, observability, rust]
languages: [bash, rust]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://docs.rs/tracing/latest/tracing/#levels
  - https://docs.rs/tracing-subscriber/latest/tracing_subscriber/#filtering-spans-and-events
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Tillandsias Logging Levels and Configuration

**Use when**: Configuring log verbosity, enabling accountability windows, or troubleshooting application behavior.

## Provenance

- https://docs.rs/tracing/latest/tracing/#levels — Rust tracing levels specification
- https://docs.rs/tracing-subscriber/latest/tracing_subscriber/#filtering-spans-and-events — Tracing subscriber filtering
- **Last updated:** 2026-04-27

## Upstream takeaways

- `TRACE` is the most verbose level and `ERROR` is the least verbose in the standard tracing hierarchy.
- `tracing-subscriber` uses `Layer` and `Filter` composition for runtime filtering.
- `EnvFilter` is the conventional way to express environment-driven filter strings such as `RUST_LOG`.
- Log filtering should be explicit and composable rather than ad hoc.

## See also

- `openspec/specs/logging-accountability/spec.md`
- `openspec/specs/runtime-logging/spec.md`

@trace spec:logging-accountability
