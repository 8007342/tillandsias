<!-- @trace spec:tray-app -->
## Status

status: active

## MODIFIED Requirements

### Requirement: First-launch readiness feedback

The tray application SHALL provide clear visual feedback during first-launch setup and SHALL NOT silently fail when infrastructure is unavailable.

#### Scenario: Forge image not yet built
- **WHEN** the tray starts and the forge image is absent
- **THEN** a "Setting up..." build chip appears in the tray menu
- **AND** all forge-dependent menu items (Attach Here, Maintenance, Root) are disabled
- **AND** the build chip transitions to "ready" or "failed" when the build completes

#### Scenario: Infrastructure setup failure
- **WHEN** `ensure_infrastructure_ready` fails at startup
- **THEN** a desktop notification informs the user of the issue
- **AND** the tray continues operating in degraded mode (forge builds bypass proxy cache)

#### Scenario: Attach Here called before forge ready
- **WHEN** `handle_attach_here` is invoked while `forge_available` is false
- **THEN** a desktop notification tells the user to wait
- **AND** the handler returns early without attempting a build
- **AND** no silent failure occurs

### Requirement: Cross-platform tray behavior
The tray application SHALL function correctly on Linux, macOS, and Windows using Tauri v2's native tray support.

#### Scenario: Linux tray
- **WHEN** the application runs on Linux
- **THEN** the tray icon integrates with the desktop environment via DBus StatusNotifierItem (libayatana-appindicator)

#### Scenario: macOS tray
- **WHEN** the application runs on macOS
- **THEN** the tray icon appears in the macOS menu bar as a native NSStatusItem

#### Scenario: Windows tray
- **WHEN** the application runs on Windows
- **THEN** the tray icon appears in the Windows system tray notification area


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

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-app" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
