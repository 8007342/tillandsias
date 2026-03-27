## ADDED Requirements

### Requirement: Forge availability gate
The tray menu SHALL disable all forge-dependent actions whenever the forge image is not available (absent, building, or failed to build).

#### Scenario: Launch with no forge image
- **GIVEN** the application starts
- **AND** no forge image exists in the local container registry
- **WHEN** the initial menu is built
- **THEN** "Attach Here" (top-level and per-project), "🛠️ Root", "Maintenance", and "GitHub Login" are disabled
- **AND** the build chip shows "⏳ Building Forge..."
- **AND** "Quit Tillandsias" remains enabled

#### Scenario: Launch with stale forge image
- **GIVEN** the application starts
- **AND** a forge image exists but its content hash does not match the current build scripts
- **WHEN** the rebuild is triggered
- **THEN** forge-dependent actions are disabled
- **AND** the build chip shows "⏳ Building Updated Forge..."
- **AND** "Quit Tillandsias" remains enabled

#### Scenario: Forge build completes
- **GIVEN** a forge build was in progress
- **WHEN** the build finishes successfully
- **THEN** `forge_available` is set to `true`
- **AND** the menu is rebuilt
- **AND** all previously disabled forge-dependent actions become enabled

#### Scenario: Forge image already present at launch
- **GIVEN** the application starts
- **AND** the forge image is present and up to date
- **WHEN** the initial menu is built
- **THEN** all actions are enabled immediately without any disabled state

### Requirement: Distinct build chip messages
The build chip label SHALL communicate whether this is a first-time installation or a routine update.

#### Scenario: First-time build chip label
- **GIVEN** no forge image exists
- **WHEN** the auto-build begins
- **THEN** the menu chip shows "⏳ Building Forge..."

#### Scenario: Update build chip label
- **GIVEN** a forge image exists but is stale
- **WHEN** the rebuild begins
- **THEN** the menu chip shows "⏳ Building Updated Forge..."

## UNCHANGED Requirements

### Requirement: Quit always accessible
"Quit Tillandsias" SHALL remain enabled regardless of forge availability or build state.

### Requirement: Settings always accessible
The Settings submenu SHALL remain enabled regardless of forge availability, because it does not require a running container.
