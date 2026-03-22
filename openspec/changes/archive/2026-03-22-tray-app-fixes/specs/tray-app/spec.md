## MODIFIED Requirements

### Requirement: Dynamic tray menu
The tray menu SHALL rebuild and display updated content whenever the application state changes.

#### Scenario: Menu shows discovered projects
- **WHEN** the scanner discovers projects in ~/src
- **THEN** the tray menu rebuilds to show each project with its available actions

#### Scenario: Quit exits the application
- **WHEN** the user clicks Quit in the tray menu
- **THEN** the application exits immediately

#### Scenario: Menu events reach handlers
- **WHEN** the user clicks any menu item
- **THEN** the corresponding handler is invoked
