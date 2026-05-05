---
tags: [tray, state-machine, ux, tillandsias]
languages: []
since: 2026-05-03
last_verified: 2026-05-03
sources:
  - internal
authority: internal
status: draft
tier: bundled
---

# Tray State Machine

@trace spec:tray-app, spec:tray-progress-and-icon-states

**Use when**: Understanding how the tray icon and menu state transitions in response to container lifecycle and build events.

## Provenance

- Internal architecture documentation
- **Last updated:** 2026-05-03

## State Transitions

The tray maintains a state machine that tracks:
- Project discovery (filesystem scanner)
- Container lifecycle (podman events)
- Build progress (concurrent build events)
- Icon state (visual representation of overall system state)

State transitions are driven by multiplexed event sources:
- Scanner: project discovered/updated/removed
- Podman: container state changes (created, running, exited, removed)
- Menu: user actions (attach, stop, destroy)
- Build progress: image/maintenance build state
- GitHub health: connectivity check success/failure

## Key Properties

- **Event-driven**: no polling — state transitions driven by events only
- **Monotonic**: never rollback state (only forward transitions)
- **Idempotent**: same event applied twice = same result
- **Convergent**: duplicate events don't cause inconsistency

## Related Specs

- `spec:tray-app` - main tray orchestration
- `spec:podman-orchestration` - container lifecycle
- `spec:tray-minimal-ux` - minimal menu UX

## See Also

- `cheatsheets/runtime/container-lifecycle.md` — container state model
- `cheatsheets/runtime/enclave-startup-sequencing.md` — enclave orchestration
