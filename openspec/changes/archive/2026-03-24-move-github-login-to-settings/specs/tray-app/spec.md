## ADDED Requirements

### Requirement: Settings submenu
The tray menu SHALL include a Settings submenu that contains configuration and setup actions.

#### Scenario: Settings submenu with GitHub Login needed
- **WHEN** the tray menu is built and GitHub credentials are missing
- **THEN** the Settings submenu contains a "GitHub Login" item

#### Scenario: Settings submenu with all configured
- **WHEN** the tray menu is built and GitHub credentials are present
- **THEN** the Settings submenu contains a disabled "All set" placeholder item

#### Scenario: GitHub Login not at top level
- **WHEN** the tray menu is displayed
- **THEN** no "GitHub Login" item appears at the top level of the menu

#### Scenario: Menu item action unchanged
- **WHEN** the user clicks "GitHub Login" inside the Settings submenu
- **THEN** the same GitHub authentication flow runs as before (interactive container with `gh auth login`)
