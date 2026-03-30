## ADDED Requirements

### Requirement: Each entrypoint follows a fixed lifecycle
Every per-type entrypoint SHALL follow the lifecycle: source common -> install/update -> find project -> configure -> banner -> launch.

#### Scenario: Forge entrypoint lifecycle
- **WHEN** a forge entrypoint starts
- **THEN** it executes in order: (1) source common library, (2) install/update agent, (3) install/update OpenSpec, (4) find project directory, (5) run OpenSpec init if needed, (6) print banner, (7) exec agent

#### Scenario: Terminal entrypoint lifecycle
- **WHEN** the terminal entrypoint starts
- **THEN** it executes in order: (1) source common library, (2) find project directory, (3) print welcome banner, (4) exec fish

#### Scenario: Failure at install step
- **WHEN** agent installation fails in a forge entrypoint
- **THEN** the entrypoint prints a diagnostic message identifying the failure and falls back to `exec bash` instead of silently failing

#### Scenario: Failure at launch step
- **WHEN** the agent binary exists but fails to start
- **THEN** the entrypoint prints a diagnostic message and falls back to `exec bash`

### Requirement: Secret isolation per container type
Each container type SHALL only receive the secrets and credentials it needs.

#### Scenario: OpenCode forge does not see Claude secrets
- **WHEN** an OpenCode forge container is running
- **THEN** the `~/.claude` directory is NOT mounted and `ANTHROPIC_API_KEY` is NOT in the environment

#### Scenario: Terminal does not see agent secrets
- **WHEN** a maintenance terminal is running
- **THEN** neither `~/.claude` nor `ANTHROPIC_API_KEY` is present, and no agent-specific cache directories are mounted

#### Scenario: Web container sees no secrets
- **WHEN** a web container is running
- **THEN** no credentials, tokens, API keys, or config directories are mounted — only the static files directory
