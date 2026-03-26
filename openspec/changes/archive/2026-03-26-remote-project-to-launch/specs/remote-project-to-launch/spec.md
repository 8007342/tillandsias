## MODIFIED Requirements

### Requirement: Auto-launch after successful clone
After a remote project is successfully cloned, the application SHALL automatically launch the forge environment for that project without any additional user action.

#### Scenario: Clone completes successfully
- **WHEN** the user clicks a remote project and the clone completes without error
- **THEN** the forge is automatically launched for the cloned project
- **AND** the project appears in the tray with a blooming flower icon
- **AND** a terminal window opens for the project's forge environment

#### Scenario: Auto-launch fails gracefully
- **WHEN** the clone completes successfully but the auto-launch fails (e.g., forge image not built yet)
- **THEN** the clone is still reported as successful
- **AND** the failure is logged at the error level
- **AND** the tray menu shows the new project (so the user can attach manually)

#### Scenario: Scanner deduplication
- **WHEN** the scanner detects the newly cloned directory and emits a Discovered event
- **AND** the project was already pre-inserted during auto-launch
- **THEN** no duplicate project entry appears in the tray menu
