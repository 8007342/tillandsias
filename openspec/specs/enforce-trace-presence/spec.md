<!-- @tombstone superseded:spec-traceability+methodology-accountability -->
# enforce-trace-presence Specification (Tombstone)

## Status

deprecated

## Tombstone

This umbrella spec was retired after traceability policy was distilled into the
broader `spec-traceability` and `methodology-accountability` layers.

The live validator remains `scripts/validate-traces.sh`, which is now a
developer/CI helper rather than a standalone active contract here. The current
trace coverage and drift checks span `crates/`, `scripts/`, `images/`, and
`methodology/`, not the old `src-tauri/src` framing.

The remaining useful obligations are:

- traceability graph modeling and litmus-chain references in `spec-traceability`
- methodology provenance, unknown-event intake, and proximity reporting in
  `methodology-accountability`
- the validator script implementation in `scripts/validate-traces.sh`

There is no backwards-compatibility commitment for the retired Phase 2 umbrella.

## Replacement References

- `openspec/specs/spec-traceability/spec.md`
- `openspec/specs/methodology-accountability/spec.md`
- `scripts/validate-traces.sh`

## Sources of Truth

- `cheatsheets/build/validation-ci.md` — CI validation patterns and exit codes
- `cheatsheets/languages/rust.md` — Rust visibility and declaration conventions

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:enforce-trace-presence" scripts crates images methodology --include="*.rs" --include="*.sh"
```
