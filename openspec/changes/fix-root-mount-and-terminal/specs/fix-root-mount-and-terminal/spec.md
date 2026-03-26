## FIXED Requirements

### Requirement: Root watch path mount target
When the root "Attach Here" action is invoked for the watch path itself (e.g., `~/src/`), the volume mount SHALL target `/home/forge/src/` directly.

#### Scenario: Root attach mounts correctly
- **GIVEN** the user clicks "Attach Here" on the root `src/` menu entry
- **WHEN** the container starts
- **THEN** the host `~/src/` directory is mounted at `/home/forge/src/` inside the container
- **AND** all project subdirectories are visible at `/home/forge/src/<project>/`

#### Scenario: Per-project attach is unchanged
- **GIVEN** the user clicks "Attach Here" on a specific project (e.g., `tillandsias`)
- **WHEN** the container starts
- **THEN** the host `~/src/tillandsias/` directory is mounted at `/home/forge/src/tillandsias/` inside the container

### Requirement: Root terminal uses fish entrypoint
The root terminal (🛠️ Root) SHALL use the same fish shell entrypoint as per-project maintenance terminals.

#### Scenario: Root terminal opens fish
- **GIVEN** the user clicks "🛠️ Root" in the tray menu
- **WHEN** the terminal opens
- **THEN** the shell is fish (not bash)
- **AND** the forge welcome banner is displayed
