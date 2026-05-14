<!-- @trace spec:direct-podman-calls -->
# direct-podman-calls Specification (Deprecated)

## Status

obsolete
superseded_by: podman-container-spec + podman-container-handle + podman-orchestration

## Purpose

Historical tombstone for the earlier direct-shell-launch runtime model. The
current runtime shape is the typed Podman layer (`podman-container-spec`,
`podman-container-handle`, and `podman-orchestration`). This tombstone is kept
for traceability only and should not receive new behavior.

## Tombstone

- Retired behavior: direct runtime dependency on repository shell scripts for
  container orchestration
- Replacement: [`podman-container-spec`](../podman-container-spec/spec.md),
  [`podman-container-handle`](../podman-container-handle/spec.md), and
  [`podman-orchestration`](../podman-orchestration/spec.md)
- Current contract: compiled Rust owns runtime orchestration; Containerfiles
  remain the image recipe source of truth

## Archived Notes

- The host-side GitHub login and image build helpers now live behind the typed
  Podman layer and the runtime wrappers in Rust.
- Repository scripts remain as manual developer tooling, not the runtime
  execution path.
- New code should trace to the typed Podman specs instead of this tombstone.

## Sources of Truth

- `openspec/specs/podman-container-spec/spec.md`
- `openspec/specs/podman-container-handle/spec.md`
- `openspec/specs/podman-orchestration/spec.md`
- `cheatsheets/runtime/podman.md`
- `cheatsheets/runtime/testing-best-practices.md`

## Litmus Tests

No active litmus bindings remain. The historical behavior is covered by the
typed Podman layer and its litmuses.

## Observability

Annotations referencing this tombstoned spec may still exist in historical
traces, but new code should trace to `podman-container-spec`,
`podman-container-handle`, or `podman-orchestration`.
