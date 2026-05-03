<!-- @trace spec:tray-ux -->
# tray-ux Specification

## Status

status: active

## Purpose
Define the minimalistic tray UX flow for Tillandsias, showing only essential elements at each stage of the application lifecycle.

## Requirements

### Requirement: First-launch minimal tray
At launch, the tray SHALL show only four elements:
1. `<☐ Verifying environment ...` (dynamic status icon + text)
2. Divider
3. `Tillandsias vX.Y.Z` (version + attribution, disabled)
4. `Quit Tillandsias` (always visible and enabled)

#### Scenario: Initial state
- **WHEN** Tillandsias starts for the first time
- **THEN** only the four elements above are visible in the tray menu
- **AND** no Projects, Cloud, or GitHub login items are shown
- **AND** the status item shows "☐ Verifying environment..." initially

### Requirement: Dynamic environment verification status
The first element SHALL change dynamically as containers are initialized:
- Initial: `☐ Verifying environment ...`
- During builds: Shows icons (🌐=proxy, 🔧=forge, 🪞=git, 🧠=inference, 🌐=chromium) + "Building Network + Forge + Mirror..."
- Final success: `✅ Environment OK` (when `forge_available = true`)
- Final failure: `🌹 Unhealthy environment` (when `TrayIconState::Dried`)

#### Scenario: Initial state
- **WHEN** Tillandsias starts for the first time
- **THEN** the status shows `☐ Verifying environment...`

#### Scenario: Build in progress
- **WHEN** one or more images are building (`active_builds` not empty)
- **THEN** the status shows icons for each building component + "Building Network + Mirror + ..."

#### Scenario: All images built successfully
- **WHEN** all enclave images are built and `forge_available = true`
- **THEN** the status shows `✅ Environment OK`

#### Scenario: Build failure
- **WHEN** any enclave image fails to build (`TrayIconState::Dried`)
- **THEN** the status shows `🌹 Unhealthy environment`

### Requirement: Post-initialization menu items
Once `forge_available = true`, the UX SHALL show at the top level:
- `<Root Terminal>` (opens terminal at watch path)
- `<Cloud> Remote Projects >` if GitHub authenticated AND remote repos exist
- `<Key> GitHub login` if NOT authenticated (gated on `forge_available`)
- Per-project submenus with 4 action buttons (see below)

#### Scenario: With GitHub auth and local projects
- **WHEN** `forge_available = true` AND GitHub credentials exist AND remote projects exist
- **THEN** the menu shows root terminal, Cloud > submenu, and project submenus with action buttons

#### Scenario: Without GitHub auth
- **WHEN** `forge_available = true` AND no GitHub credentials exist
- **THEN** the menu shows root terminal, GitHub login item, and project submenus

#### Scenario: No local projects
- **WHEN** `forge_available = true` AND no local projects exist
- **THEN** the Projects submenu shows "No projects detected"
- **AND** Cloud > submenu is shown if authenticated

### Requirement: Per-project action buttons
Each project submenu SHALL display 4 explicit action buttons:
1. `💻 OpenCode` — Opens terminal-based IDE
2. `🌐 OpenCode Web` — Opens web-based IDE via browser isolation
3. `👽 Claude` — Opens Claude AI assistant
4. `🔧 Maintenance` — Opens terminal access to the project

All actions are gated on `forge_available`. When a container is running for an action,
the project label shows status emojis (🔧 for maintenance, 🌸 for forge, 🔗 for web server).

#### Scenario: Click OpenCode action
- **WHEN** user clicks 💻 OpenCode button
- **THEN** a terminal-based IDE container is launched for that project
- **AND** a terminal window opens showing the development environment

#### Scenario: Click OpenCode Web action
- **WHEN** user clicks 🌐 OpenCode Web button
- **THEN** an OpenCode Web container is launched for the project
- **AND** once healthy, a safe browser window opens via `tillandsias-chromium-core` container
- **AND** the browser communicates with OpenCode Web via the project's enclave network

#### Scenario: Click Claude action
- **WHEN** user clicks 👽 Claude button
- **THEN** a Claude AI assistant container is launched for that project
- **AND** a terminal window opens with Claude interface

#### Scenario: Click Maintenance action
- **WHEN** user clicks 🔧 Maintenance button
- **THEN** a terminal container is launched for that project
- **AND** a terminal window opens for manual maintenance tasks

#### Scenario: Remote project cloning
- **WHEN** user clicks any action for a remote project not cloned locally
- **THEN** the project is cloned to local machine first (shows progress in menu chip)
- **AND** then the action container is launched

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — Container state machine and lifecycle management for Tillandsias containers
- `cheatsheets/utils/podman-logging.md` — Log inspection techniques for debugging container issues

### Requirement: Stale container cleanup
The system SHALL clean up stale Tillandsias containers on startup:
- Remove any containers with `tillandsias-*` pattern that are not currently tracked
- Allow new containers to regenerate accordingly

#### Scenario: Startup cleanup
- **WHEN** Tillandsias starts
- **THEN** all stopped/orphaned `tillandsias-*` containers are removed
- **AND** only actively tracked containers remain

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-ux" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
