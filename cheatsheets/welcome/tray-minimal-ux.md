---
tags: [tray, ux, menu, tillandsias]
languages: []
since: 2026-05-03
last_verified: 2026-05-03
sources:
  - internal
authority: internal
status: draft
tier: bundled
---

# Tray Minimal UX

@trace spec:tray-minimal-ux, spec:simplified-tray-ux

**Use when**: Understanding the tray menu structure and user interactions in the Tillandsias minimal UX design.

## Provenance

- Internal UX documentation
- **Last updated:** 2026-05-03

## Menu Structure

The tray menu presents a minimal set of actions:
- **Attach Here** — launch development environment for selected project
- **OpenCode** — open web IDE for project
- **OpenCode Web** — open isolated browser session for project
- **Terminal** — open terminal in project environment
- **Serve Here** — launch HTTP server for project
- **Stop/Destroy** — manage running containers
- **Quit** — exit tray

## Key Principles

- **Minimal**: only essential actions visible
- **Project-centric**: all actions are project-scoped
- **Non-blocking**: actions execute asynchronously
- **Visible feedback**: progress chips show build state

## Visual Feedback

Build progress and container state are communicated via:
- **Tray icon**: visual indicator of system state (idle, working, error)
- **Progress chips**: compact indicators of active builds and states
- **Menu items**: disabled when not applicable to current state

## Related Specs

- `spec:tray-app` - main tray orchestration
- `spec:simplified-tray-ux` - simplified menu design
- `spec:tray-progress-and-icon-states` - visual state representation

## See Also

- `cheatsheets/runtime/tray-state-machine.md` — state transitions
- `cheatsheets/runtime/container-lifecycle.md` — container states
