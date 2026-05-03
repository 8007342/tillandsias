<!-- @trace spec:layered-tools-overlay -->
# layered-tools-overlay Specification

## Status

status: active

## Purpose

Pre-built tools overlay that decouples AI coding tool lifecycle (OpenCode, Claude Code, OpenSpec) from the forge base image lifecycle. Tools are installed once into a host directory, mounted read-only into all forge containers, and updated in the background. Eliminates the 15-60 second per-launch install delay.
## Requirements
### Requirement: Capability is tombstoned

The `layered-tools-overlay` capability SHALL remain in the spec index
only as a tombstone. All operative requirements have been removed.
Any code or documentation that references this capability SHALL be
treated as legacy and migrated to `spec:default-image` (agent
hard-install) or `spec:opencode-web-session` (config overlay on
tmpfs).

#### Scenario: Tombstone visible to readers
- **WHEN** an engineer opens `openspec/specs/layered-tools-overlay/spec.md`
- **THEN** they SHALL see exactly one active requirement noting the
  tombstone
- **AND** they SHALL be pointed to the superseding specs


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Spec README contains `@tombstone` annotation with superseded spec reference
- Readers are directed to forge-hot-cold-split or other replacement specs
- No active requirements; spec is informational only (transition documentation)

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — Forge Hot Cold Split reference and patterns
- `cheatsheets/runtime/forge-container.md` — Forge Container reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:layered-tools-overlay" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
