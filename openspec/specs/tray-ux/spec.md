<!-- @trace spec:tray-ux -->
# tray-ux Specification

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
- `<~/src> Attach Here` (uses first watch path from config, gated on `forge_available`)
- `<Cloud> Remote Projects >` if GitHub authenticated AND remote repos exist
- `<Key> GitHub login` if NOT authenticated (gated on `forge_available`)

#### Scenario: With GitHub auth and local projects
- **WHEN** `forge_available = true` AND GitHub credentials exist AND remote projects exist
- **THEN** the menu shows "Attach Here" item and "Cloud >" submenu with remote projects

#### Scenario: Without GitHub auth
- **WHEN** `forge_available = true` AND no GitHub credentials exist
- **THEN** the menu shows "Attach Here" item and "GitHub login" item (no Cloud)

#### Scenario: No local projects
- **WHEN** `forge_available = true` AND no local projects exist
- **THEN** the menu still shows "Attach Here" with watch path
- **AND** shows "Cloud >" submenu if authenticated

### Requirement: Project click launches OpenCode Web
When clicking on a project in the tray menu:
1. If remote project not cloned locally, clone it first
2. Launch OpenCode Web container for the project
3. Once container is healthy, launch a safe browser window inside `tillandsias-chromium-core` container

#### Scenario: Click local project
- **WHEN** user clicks a local project
- **THEN** OpenCode Web container is launched for that project
- **AND** once healthy, a safe browser window opens via `tillandsias-chromium-core` container

#### Scenario: Click remote project (not cloned)
- **WHEN** user clicks a remote project that isn't cloned locally
- **THEN** the project is cloned to local machine first
- **AND** then OpenCode Web container is launched

#### Scenario: Browser launches in chromium container
- **WHEN** OpenCode Web container is healthy
- **THEN** the browser window is launched using `tillandsias-browser-tool` 
- **AND** the browser runs inside `tillandsias-chromium-core` container for isolation
- **AND** communicates with OpenCode Web via the tray socket mount

### Requirement: Stale container cleanup
The system SHALL clean up stale Tillandsias containers on startup:
- Remove any containers with `tillandsias-*` pattern that are not currently tracked
- Allow new containers to regenerate accordingly

#### Scenario: Startup cleanup
- **WHEN** Tillandsias starts
- **THEN** all stopped/orphaned `tillandsias-*` containers are removed
- **AND** only actively tracked containers remain
