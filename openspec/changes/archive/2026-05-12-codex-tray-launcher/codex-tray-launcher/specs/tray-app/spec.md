# Tray App

@trace spec:tray-app, spec:agent-icon-representation

**Purpose**: System tray menu application (Tauri) for managing Tillandsias projects and launching containerized agents.

## MODIFIED Requirements

### Requirement: Menu button for Codex (NEW SCENARIO ADDED)

The tray menu SHALL display a 🏗 Codex button for each project, positioned after Claude and before Terminal in the action row. This addition extends the existing agent button framework.

#### Scenario: Codex button visible when authenticated
- **WHEN** user is authenticated and views a project's menu
- **THEN** the Codex button appears with label "🏗 Codex"
- **AND** the button is enabled if forge is available
- **AND** the button is positioned in the action row: OpenCode, OpenCode Web, Claude, Codex, Terminal, Serve

#### Scenario: Codex button disabled when forge unavailable
- **WHEN** forge image has not been built or is inaccessible
- **THEN** the Codex button appears but is disabled (grayed out)
- **AND** tooltip indicates "Forge unavailable"

#### Scenario: Codex button click triggers launch
- **WHEN** user clicks the Codex button
- **THEN** the tray invokes handlers::launch_codex_container() handler
- **AND** a progress chip labeled "🏗 Codex — <project>" appears in the tray
- **AND** tray icon transitions to 🔄 (working state) during launch

## Sources of Truth

- `cheatsheets/runtime/tray-minimal-ux.md` — Tray menu structure and action button layout
- `cheatsheets/runtime/tray-state-machine.md` — Tray icon state transitions and progress chip lifecycle
- `cheatsheets/runtime/menu-icon-emoji.md` — Icon emoji selection and user-facing consistency
