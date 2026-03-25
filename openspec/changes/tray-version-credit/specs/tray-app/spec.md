## ADDED Requirements

### Requirement: Version and credit display
The tray menu SHALL display the current version number and author credit as non-clickable items near the bottom of the menu.

#### Scenario: Version shown
- **WHEN** the tray menu is displayed
- **THEN** a disabled item reading "Tillandsias v{version}" appears before the Quit item, where {version} is the Cargo package version

#### Scenario: Credit shown
- **WHEN** the tray menu is displayed
- **THEN** a disabled item reading "by Tlatoāni" appears between the version line and the Quit item
