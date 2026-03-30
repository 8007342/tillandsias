## Context

The convergence chain (implementation → spec → ground truth) lacks backward traceability. An agent seeing a log error can't efficiently find which spec requirement backs the failing code path.

## Goals / Non-Goals

**Goals:**
- Backward traceability: log → code → spec → knowledge
- Drift detection: stale references surface at troubleshooting time
- Zero-cost at runtime (comments are free, tracing fields are near-free)
- CRDT semantics: gaps filled incrementally, never blocking

**Non-Goals:**
- Build gates on trace coverage
- Proc-macro or compile-time validation
- Traceability matrix files
- Per-line attribution

## Decisions

**`@trace` comment format** over proc-macro: Comments are grep-able, block-granular, work in both Rust and bash, require no tooling. Proc-macros add compile cost, only work on items, and get expanded away.

**Structured `spec` tracing field** over string prefix: Fields are parseable by any log tool. Comma-separated with simple primary spec overload: `spec = "podman-orchestration"` or `spec = "podman-orchestration, default-image"`.

**Regular comments (`//`)** over doc comments: Consistency across module-level and block-level. Doc comments only work on items, not arbitrary blocks.

**Bash scripts included**: Scripts are brittle and benefit most from traceability back to specs.

**Voluntary, not gated**: No archive check initially. Staleness reviewed every few releases. Frequency adjusted based on observed drift.

**80/20 annotation coverage**: Only the ~20% of code where architectural decisions live. Data types, tests, formatters, utilities — not annotated.

## Risks / Trade-offs

- [Risk] Annotations go stale → this IS the value: stale refs = visible drift signal
- [Risk] Over-annotation → mitigated by strict 80/20 rule, only non-obvious decisions
- [Trade-off] Manual maintenance vs automated → manual is simpler, automated adds tooling burden
