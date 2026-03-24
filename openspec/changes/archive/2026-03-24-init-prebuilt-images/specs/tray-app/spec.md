## ADDED Requirements

### Requirement: Tray waits for background init
The tray app SHALL detect an in-progress background init and wait for it instead of starting a duplicate build.

#### Scenario: Init running on tray startup
- **WHEN** the tray starts and the forge image is missing but a build lock is active
- **THEN** the tray shows "Preparing environment..." in the menu and waits for the build to complete

#### Scenario: Init completes while tray is waiting
- **WHEN** the background init finishes and the forge image becomes available
- **THEN** the tray menu updates normally with project actions enabled
