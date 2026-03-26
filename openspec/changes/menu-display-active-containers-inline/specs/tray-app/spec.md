## MODIFIED Requirements

### Requirement: Active projects appear inline at the top level
Projects with at least one running container SHALL appear as direct top-level menu entries (not nested inside any submenu), positioned between the first separator and the Projects submenu.

#### Scenario: One project running
- **GIVEN** one project has running containers
- **WHEN** the tray menu is built
- **THEN** that project's submenu appears inline at the top level
- **AND** the Projects submenu contains only the remaining inactive projects

#### Scenario: Multiple projects running
- **GIVEN** two or more projects have running containers
- **WHEN** the tray menu is built
- **THEN** all active projects appear inline at the top level, each as its own submenu entry
- **AND** the Projects submenu contains only inactive projects

#### Scenario: No projects running
- **GIVEN** no projects have running containers
- **WHEN** the tray menu is built
- **THEN** no inline project entries appear at the top level
- **AND** the Projects submenu contains all discovered projects

#### Scenario: All projects running
- **GIVEN** every discovered project has running containers
- **WHEN** the tray menu is built
- **THEN** all projects appear inline at the top level
- **AND** the Projects submenu is omitted from the menu entirely

### Requirement: Projects submenu shows only inactive projects
The "Projects" submenu SHALL contain only projects that have no running containers.

#### Scenario: Inactive projects only
- **WHEN** the tray menu is built with a mix of active and inactive projects
- **THEN** the Projects submenu contains exactly the inactive projects
- **AND** active projects are not duplicated inside the Projects submenu

#### Scenario: No projects detected
- **WHEN** no projects have been discovered by the scanner
- **THEN** the Projects submenu shows a single disabled "No projects detected" item

### Requirement: Running Environments submenu removed
There SHALL be no "Running Environments" submenu in the tray menu.

#### Scenario: Containers are running
- **WHEN** one or more containers are running
- **THEN** the menu does NOT contain a "Running Environments" submenu
- **AND** the running state is conveyed through the inline active project entries

### Requirement: Build chips appear inline
Active build progress chips (⏳ building, ✅ ready, ❌ failed) SHALL appear as disabled inline items in the top-level menu, not inside a submenu.

#### Scenario: Build in progress
- **WHEN** an image build is active
- **THEN** the build chip appears as a disabled inline top-level item
- **AND** there is no "Activity" submenu

#### Scenario: Build chip placement
- **WHEN** build chips and active project entries both exist
- **THEN** build chips appear below the active project inline entries
