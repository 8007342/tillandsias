<!-- @trace spec:tray-app -->
## Status

active

## Requirements

### Requirement: First-launch readiness feedback
- **ID**: tray-app.ux.first-launch-feedback@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-app.invariant.setup-state-visible, tray-app.invariant.no-silent-failures]

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
- **ID**: tray-app.platform.cross-platform-native-tray@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-app.invariant.linux-dbus-appindicator, tray-app.invariant.macos-nsstatusitem, tray-app.invariant.windows-systray]
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
- **ID**: tray-app.menu.seedlings-agent-selection@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-app.invariant.seedlings-submenu-three-agents, tray-app.invariant.opencode-web-default, tray-app.invariant.menu-ids-stable]

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
- **ID**: tray-app.menu.per-project-stop-action@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-app.invariant.stop-item-appears-only-when-web-running, tray-app.invariant.stop-dispatches-correct-project]

The per-project submenu SHALL show a "Stop" item whenever a `tillandsias-<project>-forge` container is tracked as running, and hide it otherwise.

#### Scenario: Stop item appears only when a web container is active
- **WHEN** the tray menu is built for a project
- **THEN** the project's submenu shows "Stop" if and only if `TrayState::running` contains a `ContainerInfo` with `container_type = OpenCodeWeb` and `project_name == <project>`

#### Scenario: Clicking Stop dispatches the correct command
- **WHEN** the user clicks "Stop" for a project
- **THEN** the tray event loop receives a command identifying that specific project
- **AND** the handler stops the web container and updates the menu

### Requirement: Attach Here branches on selected agent
- **ID**: tray-app.action.attach-here-agent-branching@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-app.invariant.web-flow-on-opencode-web, tray-app.invariant.terminal-flow-preserved]

Clicking "Attach Here" SHALL dispatch to the web-session flow when `AgentConfig::selected` is `OpenCodeWeb`, and to the existing terminal flow otherwise.

#### Scenario: Web flow on default install
- **WHEN** `agent.selected = opencode-web` and the user clicks "Attach Here"
- **THEN** no terminal emulator is spawned
- **AND** a detached web container is started (if not already running)
- **AND** a `WebviewWindow` opens against the mapped host port

#### Scenario: Terminal flow preserved for opt-in users
- **WHEN** `agent.selected = opencode` or `claude` and the user clicks "Attach Here"
- **THEN** the existing terminal-based flow runs unchanged

## Invariants

### Invariant: Setup state is visible
- **ID**: tray-app.invariant.setup-state-visible
- **Expression**: `forge_not_ready => "Setting up..." chip appears && forge_menu_items_disabled`
- **Measurable**: true

### Invariant: No silent failures
- **ID**: tray-app.invariant.no-silent-failures
- **Expression**: `infrastructure_failure => desktop_notification_shown && app_continues_degraded`
- **Measurable**: true

### Invariant: Linux uses DBus AppIndicator
- **ID**: tray-app.invariant.linux-dbus-appindicator
- **Expression**: `platform == linux => tray_icon_uses DBus_StatusNotifierItem`
- **Measurable**: true

### Invariant: macOS uses NSStatusItem
- **ID**: tray-app.invariant.macos-nsstatusitem
- **Expression**: `platform == macos => tray_icon_is NSStatusItem && appears_in_menubar`
- **Measurable**: true

### Invariant: Windows uses system tray
- **ID**: tray-app.invariant.windows-systray
- **Expression**: `platform == windows => tray_icon_in_notification_area`
- **Measurable**: true

### Invariant: Seedlings submenu has three agents
- **ID**: tray-app.invariant.seedlings-submenu-three-agents
- **Expression**: `seedlings_submenu CONTAINS ["OpenCode Web", "OpenCode", "Claude"]`
- **Measurable**: true

### Invariant: OpenCode Web is default
- **ID**: tray-app.invariant.opencode-web-default
- **Expression**: `fresh_install => agent.selected == opencode-web && active_choice_indicator_shown`
- **Measurable**: true

### Invariant: Menu IDs remain stable
- **ID**: tray-app.invariant.menu-ids-stable
- **Expression**: `seedlings_opencode_web_menu_id == "select-agent:opencode-web" && persists_to_config`
- **Measurable**: true

### Invariant: Stop item appears only when web running
- **ID**: tray-app.invariant.stop-item-appears-only-when-web-running
- **Expression**: `project_submenu.stop_item APPEARS_IFF contains(running, container_type=OpenCodeWeb, project_name=<project>)`
- **Measurable**: true

### Invariant: Stop dispatches correct project
- **ID**: tray-app.invariant.stop-dispatches-correct-project
- **Expression**: `click_stop => handler_receives_event_identifying_specific_project && stops_correct_container`
- **Measurable**: true

### Invariant: Web flow on OpenCode Web
- **ID**: tray-app.invariant.web-flow-on-opencode-web
- **Expression**: `agent.selected == opencode-web AND click_attach_here => web_flow_runs && NO_terminal`
- **Measurable**: true

### Invariant: Terminal flow preserved
- **ID**: tray-app.invariant.terminal-flow-preserved
- **Expression**: `agent.selected IN [opencode, claude] AND click_attach_here => existing_terminal_flow_unchanged`
- **Measurable**: true

## Litmus Tests

The following litmus tests validate tray-app requirements:

- `litmus-first-launch-feedback.yaml` — Validates setup state visibility and error handling (Req: tray-app.ux.first-launch-feedback@v1)
- `litmus-cross-platform-tray.yaml` — Validates platform-appropriate native tray integration (Req: tray-app.platform.cross-platform-native-tray@v1)
- `litmus-agent-selection-menu.yaml` — Validates Seedlings submenu and agent switching (Req: tray-app.menu.seedlings-agent-selection@v1, tray-app.action.attach-here-agent-branching@v1)
- `litmus-web-container-stop.yaml` — Validates per-project Stop action (Req: tray-app.menu.per-project-stop-action@v1)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/runtime/systemd-socket-activation.md` — Systemd Socket Activation reference and patterns
- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-app" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
