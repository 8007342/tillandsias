## ADDED Requirements
### Requirement: GitHub Login menu item
The tray SHALL show "GitHub Login" when no gh credentials exist.
#### Scenario: No credentials
- **WHEN** the tray menu is opened and no gh hosts.yml exists
- **THEN** "GitHub Login" appears in the menu
### Requirement: Terminal menu item
Each project SHALL have a "Terminal" action that opens bash in a forge container.
#### Scenario: Click Terminal
- **WHEN** the user clicks Terminal on a project
- **THEN** a terminal opens with bash in a forge container with the project mounted
