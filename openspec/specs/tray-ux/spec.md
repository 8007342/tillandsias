<!-- @trace spec:tray-ux -->
# tray-ux Specification

## Status

status: active

## Purpose
Define the minimalistic tray UX flow for Tillandsias, showing only essential elements at each stage of the application lifecycle.

## Requirements

### Requirement: First-launch minimal tray
At launch, the tray MUST show only four elements: @trace spec:tray-ux
1. `<☐ Verifying environment ...` (dynamic status icon + text)
2. Divider
3. `Tillandsias vX.Y.Z` (version + attribution, disabled)
4. `Quit Tillandsias` (always visible and enabled)

#### Scenario: Initial state
- **WHEN** Tillandsias starts for the first time
- **THEN** only the four elements above MUST be visible in the tray menu
- **AND** no Projects, Cloud, or GitHub login items SHOULD be shown
- **AND** the status item MUST show "☐ Verifying environment..." initially

### Requirement: Dynamic environment verification status
The first element MUST change dynamically as containers are initialized:
- Initial: `☐ Verifying environment ...`
- During builds: Shows icons (🌐=proxy, 🔧=forge, 🪞=git, 🧠=inference, 🌐=chromium) + "Building Network + Forge + Mirror..."
- Final success: `✅ Environment OK` (when `forge_available = true`)
- Final failure: `🌹 Unhealthy environment` (when `TrayIconState::Dried`)

#### Scenario: Initial state
- **WHEN** Tillandsias starts for the first time
- **THEN** the status MUST show `☐ Verifying environment...`

#### Scenario: Build in progress
- **WHEN** one or more images are building (`active_builds` not empty)
- **THEN** the status MUST show icons for each building component + "Building Network + Mirror + ..."

#### Scenario: All images built successfully
- **WHEN** all enclave images are built and `forge_available = true`
- **THEN** the status shows `✅ Environment OK`

#### Scenario: Build failure
- **WHEN** any enclave image fails to build (`TrayIconState::Dried`)
- **THEN** the status shows `🌹 Unhealthy environment`

### Requirement: Post-initialization menu items
Once `forge_available = true`, the UX MUST show at the top level:
- `<Root Terminal>` (opens terminal at watch path)
- `<Cloud> Remote Projects >` if GitHub authenticated AND remote repos exist
- `<Key> GitHub login` if NOT authenticated (gated on `forge_available`)
- Per-project submenus with 4 action buttons (see below)

#### Scenario: With GitHub auth and local projects
- **WHEN** `forge_available = true` AND GitHub credentials exist AND remote projects exist
- **THEN** the menu MUST show root terminal, Cloud > submenu, and project submenus with action buttons

#### Scenario: Without GitHub auth
- **WHEN** `forge_available = true` AND no GitHub credentials exist
- **THEN** the menu MUST show root terminal, GitHub login item, and project submenus

#### Scenario: No local projects
- **WHEN** `forge_available = true` AND no local projects exist
- **THEN** the Projects submenu MUST show "No projects detected"
- **AND** Cloud > submenu SHOULD be shown if authenticated

### Requirement: Per-project action buttons
Each project submenu MUST display 4 explicit action buttons:
1. `💻 OpenCode` — Opens terminal-based IDE
2. `🌐 OpenCode Web` — Opens web-based IDE via browser isolation
3. `👽 Claude` — Opens Claude AI assistant
4. `🔧 Maintenance` — Opens terminal access to the project

All actions MUST be gated on `forge_available`. When a container is running for an action,
the project label SHOULD show status emojis (🔧 for maintenance, 🌸 for forge, 🔗 for web server).

#### Scenario: Click OpenCode action
- **WHEN** user clicks 💻 OpenCode button
- **THEN** a terminal-based IDE container MUST be launched for that project
- **AND** a terminal window MUST open showing the development environment

#### Scenario: Click OpenCode Web action
- **WHEN** user clicks 🌐 OpenCode Web button
- **THEN** an OpenCode Web container MUST be launched for the project
- **AND** once healthy, a safe browser window MUST open via the browser isolation launcher
- **AND** the browser MUST communicate with OpenCode Web through the project-local host route

#### Scenario: Click Claude action
- **WHEN** user clicks 👽 Claude button
- **THEN** a Claude AI assistant container MUST be launched for that project
- **AND** a terminal window MUST open with Claude interface

#### Scenario: Click Maintenance action
- **WHEN** user clicks 🔧 Maintenance button
- **THEN** a terminal container MUST be launched for that project
- **AND** a terminal window MUST open for manual maintenance tasks

#### Scenario: Remote project cloning
- **WHEN** user clicks any action for a remote project not cloned locally
- **THEN** the project MUST be cloned to local machine first (shows progress in menu chip)
- **AND** then the action container MUST be launched

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:tray-menu-lifecycle` — menu composition at each lifecycle stage, container action launch and failure collapse

Gating points:
- Tray starts with exactly 4 menu items (status, divider, version, quit)
- Menu expands to 6-7 items (root terminal, cloud, projects) after forge available
- Status dynamically updates as containers initialize: "Verifying..." → "Building..." → "OK"
- Status shows "Unhealthy environment" immediately on any container failure
- Project submenu shows 4 action buttons (OpenCode, Web, Claude, Maintenance) when forge available
- Remote projects cloned before container launch
- Stale containers cleaned on startup; only tracked containers remain

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — Container state machine and lifecycle management for Tillandsias containers
- `cheatsheets/utils/podman-logging.md` — Log inspection techniques for debugging container issues

### Requirement: Stale container cleanup
The system MUST clean up stale Tillandsias containers on startup:
- MUST remove any containers with `tillandsias-*` pattern that are not currently tracked
- MAY allow new containers to regenerate accordingly

#### Scenario: Startup cleanup
- **WHEN** Tillandsias starts
- **THEN** all stopped/orphaned `tillandsias-*` containers MUST be removed
- **AND** only actively tracked containers MUST remain

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-ux" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
