## NEW Requirements

### Requirement: Emoji families are strictly separated

Flower emojis SHALL only appear on Forge/AI containers. Tool emojis SHALL only appear on Maintenance containers. No cross-contamination.

#### Scenario: Forge container uses flower
- **GIVEN** an Attach Here container is launched
- **THEN** its display emoji is a flower from the genus flower pool

#### Scenario: Maintenance container uses tool
- **GIVEN** a Maintenance container is launched
- **THEN** its display emoji is a tool from the tool emoji pool
- **AND** the tool emoji is NOT a flower

### Requirement: Tool emoji pool with rotation

A pool of 16+ tool emojis SHALL exist. Each Maintenance container gets a unique tool from the pool, rotating per project.

#### Scenario: Multiple terminals get unique tools
- **GIVEN** a project "tetris" with no running terminals
- **WHEN** the user launches three Maintenance terminals
- **THEN** each gets a different tool emoji (e.g., 🔧, 🪛, 🔩)

### Requirement: Window title matches menu emoji

The emoji in the terminal window title SHALL be identical to the emoji shown in the project's menu suffix for that container.

#### Scenario: Maintenance window title
- **GIVEN** a Maintenance container allocated tool 🔧
- **THEN** the terminal window title is "🔧 project-name"
- **AND** the project menu label shows "project-name ... 🔧"

#### Scenario: Forge window title
- **GIVEN** a Forge container with genus Aeranthos (🌸)
- **THEN** the terminal window title is "🌸 project-name"
- **AND** the project menu label shows "project-name ... 🌸"

### Requirement: Project labels use suffix layout

Emojis SHALL appear AFTER the project name in menu labels. Tools appear before flowers.

#### Scenario: Project with forge and two terminals
- **GIVEN** project "tetris" with Forge (🌸) and two Maintenance (🔧, 🪛) containers
- **THEN** the menu label reads: `tetris  🔧🪛🌸`

#### Scenario: Idle project
- **GIVEN** a project with no running containers
- **THEN** the menu label is the plain project name with no emojis

### Requirement: Emoji stored on ContainerInfo

Each ContainerInfo SHALL store a `display_emoji` field set at creation time. This is the single source of truth for both menu rendering and window titles.
