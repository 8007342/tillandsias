## ADDED Requirements

### Requirement: Root terminal menu item
The tray menu SHALL include a `🛠️ Root` item positioned immediately below the `~/src/ — Attach Here` entry and above the first separator.

#### Scenario: Root terminal click
- **GIVEN** Tillandsias is running with the forge image available
- **WHEN** the user clicks `🛠️ Root` in the tray menu
- **THEN** a bash terminal opens inside the forge container with the working directory set to the root `~/src/` mount

#### Scenario: Root terminal title
- **WHEN** the root terminal window opens
- **THEN** the window title is `🛠️ Root`

### Requirement: Reserved emoji
The `🛠️` emoji (U+1F6E0+FE0F) SHALL NOT appear in the `TOOL_EMOJIS` pool used by per-project Maintenance terminals.

#### Scenario: Tool pool does not contain reserved emoji
- **WHEN** the `TOOL_EMOJIS` constant is inspected
- **THEN** `\u{1F6E0}\u{FE0F}` is absent from the slice

### Requirement: Menu item identity
The root terminal menu item SHALL use a stable, generation-suffixed ID derived from the string `"root-terminal"`.

#### Scenario: Menu ID format
- **WHEN** the menu is built
- **THEN** the root terminal item ID matches the pattern `root-terminal#<generation>`
