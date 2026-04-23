## ADDED Requirements

### Requirement: Seedlings submenu exposes OpenCode Web

The Seedlings submenu SHALL list three agent choices — "OpenCode Web", "OpenCode", and "Claude" — with "OpenCode Web" first and marked as the active choice when `AgentConfig::selected` is `OpenCodeWeb`.

#### Scenario: Default selection on fresh install
- **WHEN** the tray menu is built and no prior agent preference exists
- **THEN** "OpenCode Web" is rendered with the active-choice indicator
- **AND** clicking "OpenCode" or "Claude" updates the config and re-renders the menu with the new active choice

#### Scenario: Menu IDs remain stable
- **WHEN** the user picks "OpenCode Web" from the Seedlings submenu
- **THEN** the menu event carries the id `select-agent:opencode-web`
- **AND** `save_selected_agent()` persists `opencode-web` to `~/.config/tillandsias/config.toml`

### Requirement: Per-project Stop action for running web containers

The per-project submenu SHALL show a "Stop" item whenever a `tillandsias-<project>-forge` container is tracked as running, and hide it otherwise.

#### Scenario: Stop item appears only when a web container is active
- **WHEN** the tray menu is built for a project
- **THEN** the project's submenu shows "Stop" if and only if `TrayState::running` contains a `ContainerInfo` with `container_type = OpenCodeWeb` and `project_name == <project>`

#### Scenario: Clicking Stop dispatches the correct command
- **WHEN** the user clicks "Stop" for a project
- **THEN** the tray event loop receives a command identifying that specific project
- **AND** the handler stops the web container and updates the menu

### Requirement: Attach Here branches on selected agent

Clicking "Attach Here" SHALL dispatch to the web-session flow when `AgentConfig::selected` is `OpenCodeWeb`, and to the existing terminal flow otherwise.

#### Scenario: Web flow on default install
- **WHEN** `agent.selected = opencode-web` and the user clicks "Attach Here"
- **THEN** no terminal emulator is spawned
- **AND** a detached web container is started (if not already running)
- **AND** a `WebviewWindow` opens against the mapped host port

#### Scenario: Terminal flow preserved for opt-in users
- **WHEN** `agent.selected = opencode` or `claude` and the user clicks "Attach Here"
- **THEN** the existing terminal-based flow runs unchanged
