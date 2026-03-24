## ADDED Requirements

### Requirement: Attach Here lifecycle emoji
Each "Attach Here" menu item SHALL display a lifecycle emoji prefix reflecting whether a container is running for that project.

#### Scenario: No container running for project
- **WHEN** the tray menu is built and no tillandsias container is running for a scanned project
- **THEN** the "Attach Here" item for that project is prefixed with 🌱

#### Scenario: Container running for project
- **WHEN** the tray menu is built and a tillandsias container is in the Running state for a scanned project
- **THEN** the "Attach Here" item for that project is prefixed with 🌺

#### Scenario: Container stops
- **WHEN** a running container for a project stops or is destroyed
- **THEN** the menu is rebuilt and the "Attach Here" item reverts to the 🌱 prefix

### Requirement: GitHub Login delegates to script
The tray GitHub Login handler SHALL open a terminal running `gh-auth-login.sh` instead of an inline bash script.

#### Scenario: User clicks GitHub Login in tray
- **WHEN** the user clicks GitHub Login in the Settings submenu
- **THEN** a terminal opens running `gh-auth-login.sh` from the installed data directory
