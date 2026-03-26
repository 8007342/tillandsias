## NEW Requirements

### Requirement: Top-level menu has at most 7 items
The tray menu top level SHALL contain at most 7 items (including separators), regardless of the number of discovered projects, running environments, or active builds.

#### Scenario: Many projects, no running containers
- **GIVEN** 10 projects are discovered in ~/src and no containers are running
- **WHEN** the tray menu is opened
- **THEN** the top level shows: `src/ — Attach Here`, `🛠️ Root`, separator, `Projects ▸`, separator, `Settings ▸`, `Tillandsias v{version} ▸` — exactly 7 items

#### Scenario: Projects and running containers
- **GIVEN** 5 projects are discovered and 2 containers are running
- **WHEN** the tray menu is opened
- **THEN** the top level shows: `src/ — Attach Here`, `🛠️ Root`, separator, `Projects ▸`, `Running ▸`, separator, `Settings ▸`, `Tillandsias v{version} ▸` — exactly 8 items (Running adds one slot only when active)

### Requirement: Projects submenu groups all project submenus
All per-project submenus SHALL be nested under a single "Projects" top-level submenu rather than appearing individually at the top level.

#### Scenario: Multiple projects
- **GIVEN** projects "alpha", "beta", "gamma" are detected
- **WHEN** the user opens the tray menu
- **THEN** a single "Projects" submenu entry appears at top level; expanding it reveals "alpha", "beta", "gamma" as individual submenus

#### Scenario: No projects detected
- **GIVEN** ~/src contains no projects
- **WHEN** the user opens the tray menu
- **THEN** the "Projects" submenu contains a single disabled item reading "No projects detected"

### Requirement: Running submenu conditionally present at top level
The "Running Environments" submenu SHALL appear at the top level only when at least one container is active.

#### Scenario: No running containers
- **GIVEN** no tillandsias containers are running
- **WHEN** the tray menu is opened
- **THEN** no "Running" or "No running environments" entry appears at the top level

#### Scenario: Container starts
- **GIVEN** a container starts running
- **WHEN** the tray menu is rebuilt
- **THEN** a "Running Environments" submenu appears at top level directly below "Projects"

#### Scenario: Last container stops
- **GIVEN** only one container is running and it stops
- **WHEN** the tray menu is rebuilt
- **THEN** the "Running Environments" entry disappears from the top level

### Requirement: Build chips nested inside Running or Activity submenu
Active build chips SHALL not appear at the top level of the tray menu.

#### Scenario: Build in progress with running containers
- **GIVEN** a container is running and an image build is active
- **WHEN** the user opens Running Environments
- **THEN** the build chip appears inside the Running Environments submenu below the container items

#### Scenario: Build in progress with no running containers
- **GIVEN** no containers are running but an image build is active
- **WHEN** the tray menu is opened
- **THEN** an "Activity" submenu appears at top level containing the build chip; no top-level build chip item exists

#### Scenario: No builds active
- **GIVEN** no image builds are active
- **WHEN** the tray menu is opened
- **THEN** no "Activity" submenu and no build chip items appear at the top level

### Requirement: About submenu groups version, credit, and Quit
Version, credit, and Quit SHALL be grouped under a single "Tillandsias v{version}" submenu at the bottom of the top level.

#### Scenario: About submenu structure
- **WHEN** the user expands the "Tillandsias v{version}" submenu
- **THEN** it contains: a disabled version item, a disabled "by Tlatoāni" item, a separator, and an enabled "Quit Tillandsias" item

#### Scenario: Version in submenu label matches version item
- **WHEN** the About submenu is built
- **THEN** the submenu label and the disabled version item inside both display the same full 4-part version string

## MODIFIED Requirements

### Requirement: Dynamic tray menu (updated)
The tray menu SHALL rebuild with a short top level (≤8 items including separators) that reflects discovered projects, running environments, and active builds through submenus.

#### Scenario: Menu shows discovered projects
- **WHEN** the scanner discovers projects in ~/src
- **THEN** the tray menu rebuilds and the Projects submenu contains each project's individual submenu

#### Scenario: Quit exits the application
- **WHEN** the user clicks Quit in the About submenu
- **THEN** the application exits immediately

#### Scenario: Menu events reach handlers
- **WHEN** the user clicks any menu item (at any nesting depth)
- **THEN** the corresponding handler is invoked with the correct item ID

### Requirement: Version and credit display (updated)
Version and credit SHALL be displayed inside the About submenu, not as inline items at the top level.

#### Scenario: Version accessible via About submenu
- **WHEN** the user opens the "Tillandsias v{version}" submenu
- **THEN** the version string is readable as a disabled item inside the submenu

#### Scenario: Credit accessible via About submenu
- **WHEN** the user opens the "Tillandsias v{version}" submenu
- **THEN** "by Tlatoāni" is readable as a disabled item inside the submenu
