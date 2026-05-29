---
tags: [tray, ux, menu, tillandsias]
languages: []
since: 2026-05-03
last_verified: 2026-05-06
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
- **Last updated:** 2026-05-06

## Menu Structure

The tray menu presents a minimal set of actions:
- **Status chip** — current setup or readiness state
- **Seedlings** — agent selector for `OpenCode Web`, `OpenCode`, and `Claude`
- **Per-project submenu** — `Attach Here`, `Maintenance`, and conditional `Stop`
- **Initialize images** — build or refresh infrastructure images
- **Root Terminal** — open a terminal in the repo root
- **GitHub Login** — authenticate the GitHub CLI inside the git container
- **Version** — display the current Tillandsias version
- **Quit Tillandsias** — exit the tray process

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
- `spec:tray-icon-lifecycle` - icon state mapping
- `spec:tray-progress-and-icon-states` - visual state representation
- `cheatsheets/runtime/statusnotifier-tray.md` - D-Bus tray protocol contract

## See Also

- `cheatsheets/runtime/tray-state-machine.md` — state transitions
- `cheatsheets/runtime/container-lifecycle.md` — container states
