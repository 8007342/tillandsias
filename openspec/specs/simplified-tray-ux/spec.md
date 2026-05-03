<!-- @trace spec:simplified-tray-ux -->
# simplified-tray-ux Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-25-simplified-tray-ux/
annotation-count: 12

## Purpose

Replace the accreted, multi-submenu tray design with a minimal, static menu structure that mirrors the user's mental model: launch a project, optionally drop into a terminal, quit. Eliminates per-project action duplication, visible menu flicker, and the "Seedlings" agent-picker submenu (converged on OpenCode Web as the sole runtime). Pre-builds all menu items on startup and toggles `enabled` state on transitions rather than rebuilding the entire tree.

## Requirements

### Requirement: Five-Stage Static Menu Structure

The tray SHALL pre-build a single menu tree on startup with all items created upfront. State transitions ONLY toggle the `enabled` property on individual items, never rebuild the tree. The project list is the sole exception (rebuild only when the project set changes, detected via set comparison, not polling).

Menu stages and their contents:

| Stage | Menu items (top → bottom) |
|-------|---------------------------|
| **Booting** | `Building [image names]` / divider / version (disabled) / `— by Tlatoāni` (disabled) / Quit |
| **Ready** | `Ready` (2-sec transient) / divider / version (disabled) / `— by Tlatoāni` (disabled) / Quit |
| **NoAuth** | `Sign in to GitHub` / divider / version (disabled) / `— by Tlatoāni` (disabled) / Quit |
| **Authed** | `Projects ▸` / divider / version (disabled) / `— by Tlatoāni` (disabled) / Quit |
| **NetIssue** | `Sign in to GitHub` / `(GitHub unreachable, using cached)` / `Projects ▸` / divider / version (disabled) / `— by Tlatoāni` (disabled) / Quit |

The version line (e.g., `v0.1.168.224`) and the signature `— by Tlatoāni` appear in every stage, both disabled (visual signature only, never clickable), immediately above `Quit Tillandsias`.

#### Scenario: Cold start with image build required
- **WHEN** tray starts and images are missing
- **THEN** menu shows "Building [image names]" for several minutes (first time) or seconds (subsequent)
- **AND** user can see which subsystems are building (deterministic emoji order)
- **AND** menu does not flicker

#### Scenario: State transition from Booting to Authed
- **WHEN** all images finish building
- **THEN** the "Building" item is replaced by "Ready" (2-sec transient)
- **AND** "Ready" fades to "Projects ▸"
- **AND** no menu rebuild, only `enabled` toggle

### Requirement: Projects Submenu

When the user has authenticated to GitHub, a `Projects ▸` submenu appears with the following structure:

```
Projects ▸
├── [ ] Include remote        (toggle; default off)
├── ──────────────────────
├── <local-project-1>      ▸  ├── Launch
├── <local-project-2>      ▸  ├── Maintenance terminal
├── ...                       └── ──────────────────
├── ──────────────────── (visible only when "Include remote" is on)
├── <remote-project-1>    ▸
├── <remote-project-2>    ▸
└── ...
```

- Local projects (from `~/.tillandsias/watch/`) are listed alphabetically
- Remote projects (from GitHub) appear under a divider when `Include remote` is enabled
- Each project has exactly two actions: **Launch** and **Maintenance terminal**
- The `Include remote` toggle persists across restarts

#### Scenario: User launches a project
- **WHEN** user clicks "Launch" for a local project
- **THEN** a single forge container `tillandsias-<project>-<genus>` starts (or reuses existing)
- **AND** Chromium opens a window pointing to `<project>.opencode.localhost:8080`
- **AND** subsequent "Launch" clicks open additional browser windows (same container)

#### Scenario: User opens a maintenance terminal
- **WHEN** user clicks "Maintenance terminal"
- **THEN** a host terminal opens with `podman exec -it tillandsias-<project>-<genus> /bin/bash`
- **AND** multiple terminals can be open against the same container
- **AND** the user can run any tool already in the forge

### Requirement: Single Container Per Project

- There is at most ONE forge container (`tillandsias-<project>-<genus>`) per project per tray process
- Container lifetime: created on first "Launch", persists until tray Quit
- Multiple browser windows can connect to the same container (OpenCode Web supports concurrent conversations in the same process)
- Multiple maintenance terminals can exec into the same container
- Container teardown happens on tray Quit (after `shutdown_all`)

#### Scenario: User launches and then attaches another window
- **WHEN** user clicks "Launch", then later clicks "Launch" again
- **THEN** the same container continues running
- **AND** a second browser window opens against the existing session

### Requirement: CLI Behavior Unchanged

Command-line invocation (`tillandsias <path>`) SHALL preserve current defaults:

- Default action: drop into an interactive shell (via `entrypoint-terminal.sh`)
- `tillandsias <path> --opencode` flag still forces OpenCode TUI
- This is intentionally different from tray default (tray launches OpenCode Web in browser)

## Sources of Truth

- Project memory: `feedback_tray_first_ux` — tray-first architecture, zero maintenance
