## CHANGED Requirements

### Requirement: Attach Here reflects container lifecycle

The "Attach Here" menu item in each project submenu SHALL visually reflect whether the project's attach container is running.

#### Scenario: Idle (no container running)
- **GIVEN** `project.assigned_genus` is `None`
- **THEN** the menu item label is `"🌱 Attach Here"`
- **AND** the item is enabled (clickable)

#### Scenario: Running (attach container active)
- **GIVEN** `project.assigned_genus` is `Some(genus)`
- **THEN** the menu item label is `"{genus.flower()} Blooming"`
- **AND** the item is disabled (not clickable)

#### Scenario: Container exits
- **GIVEN** `project.assigned_genus` transitions from `Some` to `None`
- **THEN** the menu item reverts to `"🌱 Attach Here"` and is enabled

### Requirement: Maintenance uses garden-tool icon

The Maintenance menu item and build chip SHALL use the pick emoji (`⛏️`, U+26CF+FE0F) instead of wrench (`🔧`, U+1F527).

#### Scenario: Idle maintenance
- **WHEN** no maintenance container is running for the project
- **THEN** the label is `"⛏️ Maintenance"`

#### Scenario: Maintenance build in progress
- **WHEN** a maintenance build is in progress
- **THEN** the build chip label is `"⛏️ Setting up Maintenance..."`

### Requirement: No per-project container listing

The per-project submenu SHALL NOT display individual container items with lifecycle labels below the Maintenance item.

#### Scenario: Containers running
- **GIVEN** one or more containers are running for a project
- **THEN** only "Attach Here" (or "Blooming") and "Maintenance" items appear in the submenu
- **AND** no separator or per-container lifecycle items are shown

### Requirement: Project label uses emoji indicators

The top-level project menu label SHALL use emoji prefixes instead of parenthesized container counts.

#### Scenario: Nothing running
- **THEN** label is `"🌱 {project.name}"`

#### Scenario: Attach container running
- **GIVEN** `project.assigned_genus` is `Some(genus)`
- **THEN** label starts with the genus flower emoji (e.g., `"🌺 my-project"`)

#### Scenario: Only maintenance running
- **GIVEN** maintenance container is running but attach container is not
- **THEN** label is `"⛏️ {project.name}"`

#### Scenario: Both running
- **GIVEN** both attach and maintenance containers are running
- **THEN** label is `"{genus.flower()}⛏️ {project.name}"`
