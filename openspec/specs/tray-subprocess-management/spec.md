# tray-subprocess-management Specification

@trace spec:tray-subprocess-management

## Status

active

## Requirements

### Requirement: Tray-owned subprocesses are tracked and cleaned up

The tray MUST track subprocesses it launches, capture failure status, and clean them up during shutdown or project teardown.

#### Scenario: Subprocess exits unexpectedly

- **WHEN** a tray-owned subprocess exits with failure
- **THEN** the tray MUST record the failure for diagnostics
- **AND** it MUST not leave menu state claiming the process is still healthy

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - Tray state transitions
- `cheatsheets/runtime/container-lifecycle.md` - Process/container cleanup patterns
- `cheatsheets/runtime/linux-user-session-podman.md` - User-session process context

