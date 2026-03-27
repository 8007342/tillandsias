## NEW Requirements

### Requirement: Agent selection menu
The Settings submenu SHALL contain a "Seedlings" submenu that lists available AI coding agents and allows the user to toggle between them.

#### Scenario: Default agent
- **WHEN** no agent selection has been made
- **THEN** OpenCode is the selected agent

#### Scenario: Seedlings submenu layout
- **WHEN** the user opens Settings > Seedlings
- **THEN** the submenu contains items for each agent, with a pin emoji prefix on the currently selected agent

#### Scenario: Selecting a different agent
- **WHEN** the user clicks an unselected agent in the Seedlings submenu
- **THEN** that agent becomes the selected agent, the config file is updated, and the menu is rebuilt with the pin on the new selection

### Requirement: Agent selection persistence
The selected agent SHALL be persisted in `~/.config/tillandsias/config.toml` under `[agent]` with the key `selected`.

#### Scenario: Config serialization
- **WHEN** the user selects Claude
- **THEN** the config file contains `[agent]\nselected = "claude"`

#### Scenario: Config deserialization
- **WHEN** Tillandsias starts with `selected = "claude"` in the config
- **THEN** the Seedlings submenu shows Claude as pinned and containers launch Claude Code

#### Scenario: Missing or invalid config
- **WHEN** the `[agent]` section is missing or `selected` is unrecognized
- **THEN** OpenCode is used as the default

### Requirement: Agent environment variable
All container launches (Attach Here, Maintenance, Root Terminal) SHALL pass `TILLANDSIAS_AGENT=<agent>` as an environment variable.

#### Scenario: OpenCode selected
- **WHEN** the selected agent is OpenCode
- **THEN** containers receive `-e TILLANDSIAS_AGENT=opencode`

#### Scenario: Claude selected
- **WHEN** the selected agent is Claude
- **THEN** containers receive `-e TILLANDSIAS_AGENT=claude`

### Requirement: Entrypoint agent branching
The container entrypoint SHALL read the `TILLANDSIAS_AGENT` environment variable and launch the corresponding agent.

#### Scenario: Claude agent launch
- **WHEN** `TILLANDSIAS_AGENT=claude` is set
- **THEN** the entrypoint installs Claude Code if not cached, then execs it
- **AND** falls back to bash if installation fails

#### Scenario: OpenCode agent launch (default)
- **WHEN** `TILLANDSIAS_AGENT` is unset or set to `opencode`
- **THEN** the entrypoint installs and execs OpenCode as before

### Requirement: Claude credential persistence
Claude Code credentials SHALL be persisted across container restarts via a bind mount.

#### Scenario: Claude secrets mount
- **WHEN** any container is launched
- **THEN** `~/.cache/tillandsias/secrets/claude/` is mounted at `/home/forge/.claude:rw`

### Requirement: Cross-agent credential isolation
Each agent SHALL be prevented from reading the other agent's credentials.

#### Scenario: OpenCode denied Claude paths
- **WHEN** OpenCode is running
- **THEN** `~/.claude` and `/home/forge/.claude` are in its permissions deny list

## MODIFIED Requirements

### Requirement: Settings submenu structure
The Settings submenu SHALL include the Seedlings submenu between the GitHub submenu and the version/credit footer.

#### Scenario: Full Settings layout
- **WHEN** the user opens Settings
- **THEN** the structure is: GitHub submenu, separator, Seedlings submenu, separator, version, credit
