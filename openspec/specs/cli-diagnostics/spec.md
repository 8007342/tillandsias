<!-- @tombstone superseded:runtime-diagnostics+runtime-diagnostics-stream+logging-accountability -->
<!-- @trace spec:cli-diagnostics -->
# cli-diagnostics Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This specification documents the retired Tauri-era `--diagnostics` live-tail
flow. That design mixed log streaming, container discovery, and debugging
output into a single CLI command and is no longer part of the current
architecture.

The live replacements are:

- `runtime-diagnostics` for structured failure capture and ephemeral stderr handling
- `runtime-diagnostics-stream` for session-scoped live diagnostic streaming
- `logging-accountability` for curated module-level and account-level logging

There is no backwards-compatibility commitment.

## Historical Context

The old diagnostics mode tailed `podman logs` directly from the CLI and
attempted to multiplex shared infrastructure and project containers into one
terminal stream. That path is preserved only for history.

## Replacement References

- `openspec/specs/runtime-diagnostics/spec.md`
- `openspec/specs/runtime-diagnostics-stream/spec.md`
- `openspec/specs/logging-accountability/spec.md`
