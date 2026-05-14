# download-telemetry Specification (Tombstone)

## Status

deprecated

## Tombstone

This umbrella spec was archived into narrower owners and is kept only for historical
traceability.

The live obligations now live in:

- `host-chromium-on-demand` for browser download and cache behavior
- `runtime-logging` for structured event emission and log observability
- `external-logs-layer` for host-side log aggregation and retention behavior
- `ephemeral-lifecycle` for no-persistent-state runtime rules
- `secrets-management` for redaction and sensitive payload handling

There is no backwards-compatibility commitment here. The old `download-telemetry`
contract is intentionally retired.


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Litmus Tests

None. This spec is deprecated and kept only for traceability of the old umbrella.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:download-telemetry" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
