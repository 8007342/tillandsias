# socket-container-orchestration Specification

@trace spec:socket-container-orchestration

## Status

active

## Requirements

### Requirement: Socket-based orchestration uses explicit readiness

Containers launched for socket-facing services MUST expose deterministic socket paths, health checks, or readiness probes before callers depend on them.

#### Scenario: Socket service is not ready

- **WHEN** a caller attempts to use a service before its socket is available
- **THEN** orchestration MUST retry or report readiness failure
- **AND** it MUST NOT treat container creation as proof that the service is accepting requests

## Sources of Truth

- `cheatsheets/runtime/socket-container-orchestration.md` - Socket container orchestration
- `cheatsheets/runtime/unix-socket-ipc.md` - Unix socket IPC
- `cheatsheets/runtime/socket-container-health.md` - Socket health checks

