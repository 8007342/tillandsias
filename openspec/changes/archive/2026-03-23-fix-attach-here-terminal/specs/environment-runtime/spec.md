## MODIFIED Requirements

### Requirement: Attach Here opens terminal with OpenCode
Clicking "Attach Here" SHALL open a terminal window with OpenCode running inside the container. The user MUST NOT need to run any manual commands.

#### Scenario: Tray Attach Here
- **WHEN** the user clicks "Attach Here" on a project in the tray menu
- **THEN** a terminal window opens with OpenCode running in an isolated container with the project mounted
