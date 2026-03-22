## ADDED Requirements

### Requirement: Permanent src/ attachment point
The tray menu SHALL always display the watch path root (~/src/) as a top-level "Attach Here" entry, regardless of whether any projects exist.

#### Scenario: Empty src directory
- **WHEN** ~/src/ contains no projects
- **THEN** the menu shows "~/src/ — Attach Here" as the only actionable entry

#### Scenario: Projects exist alongside src entry
- **WHEN** ~/src/ contains projects
- **THEN** the menu shows "~/src/ — Attach Here" at the top, followed by individual project submenus
