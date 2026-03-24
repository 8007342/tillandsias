## MODIFIED Requirements

### Requirement: Settings submenu
The tray menu SHALL include a Settings submenu that contains configuration, setup actions, and remote project management.

#### Scenario: GitHub Login label when not authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are missing
- **THEN** the submenu contains an item labeled "GitHub Login"

#### Scenario: GitHub Login label when authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are present
- **THEN** the submenu contains an item labeled "GitHub Login Refresh"

#### Scenario: Remote Projects submenu present
- **WHEN** the Settings submenu is built and GitHub credentials are present
- **THEN** a "Remote Projects" submenu appears below the GitHub Login Refresh item

#### Scenario: Remote Projects hidden when not authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are missing
- **THEN** no "Remote Projects" submenu appears
