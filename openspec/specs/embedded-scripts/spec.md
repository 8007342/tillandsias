<!-- @trace spec:embedded-scripts -->
# embedded-scripts Specification

## Status

obsolete
superseded_by: podman-container-spec + podman-container-handle + podman-orchestration

## Purpose
Historical tombstone for the retired script-embedding model. The shipped Tillandsias binary no longer extracts or executes repository shell scripts at runtime. Static assets such as icons, version metadata, and Containerfile-adjacent build inputs may still be embedded where needed, but executable runtime behavior is owned by compiled Rust and direct CLI calls.

## Tombstone

This spec is retained to document the removed behavior and to prevent it from being accidentally revived.

- Retired behavior: embedding executable shell scripts in the binary and extracting them to temp at runtime
- Replacement: [`podman-container-spec`](../podman-container-spec/spec.md), [`podman-container-handle`](../podman-container-handle/spec.md), and [`podman-orchestration`](../podman-orchestration/spec.md)
- Current contract: compiled Rust owns runtime orchestration; Containerfiles remain the image recipe source of truth

## Archived Notes

- The old temp-extraction flow is intentionally gone.
- `build-image.sh` and similar scripts remain repository-level developer tools only.
- Any future runtime work that needs a temporary file must justify that file as non-executable runtime data, not a shell wrapper.

## Sources of Truth

- `cheatsheets/runtime/podman.md`
- `openspec/specs/podman-container-spec/spec.md`
- `openspec/specs/podman-container-handle/spec.md`
- `openspec/specs/podman-orchestration/spec.md`
- `openspec/specs/init-command/spec.md`
- `openspec/specs/cli-mode/spec.md`

## Observability

Annotations referencing this retired spec may still exist in historical traces, but new code should not add them.
