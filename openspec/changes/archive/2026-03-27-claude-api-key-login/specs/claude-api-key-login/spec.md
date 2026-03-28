# claude-api-key-login Specification

## Purpose

Provide secure storage and transparent injection of the Anthropic API key for Claude Code, using the OS native keyring for persistence and per-process environment isolation in containers to limit key exposure.

## Requirements

### Requirement: Store Claude API key in native keyring

The application SHALL store the Anthropic API key in the OS native secret service under service name `tillandsias` with key `claude-api-key`.

#### Scenario: Key stored after login prompt
- **WHEN** the user completes the Claude Login flow and enters a valid API key
- **THEN** the key is stored in the native keyring under `tillandsias/claude-api-key`

#### Scenario: Keyring unavailable
- **WHEN** the native keyring is not available (no D-Bus, headless, locked)
- **THEN** the application logs a warning and Claude Login fails gracefully
- **AND** no error is shown in the tray menu

### Requirement: Claude Login menu item

The Seedlings submenu SHALL contain a Claude Login item whose label reflects authentication state.

#### Scenario: No API key stored
- **WHEN** the Seedlings submenu is built and no Claude API key exists in the keyring
- **THEN** the menu shows a clickable item labeled with a key emoji and "Claude Login"

#### Scenario: API key already stored
- **WHEN** the Seedlings submenu is built and a Claude API key exists in the keyring
- **THEN** the menu shows a disabled item labeled with a lock emoji and "Claude (authenticated)"

### Requirement: Claude Login flow

When the user clicks Claude Login, the application SHALL open a terminal running an interactive prompt script.

#### Scenario: User enters valid key
- **WHEN** the user pastes a key starting with `sk-ant-` and the script writes it to a temp file
- **THEN** the tray app reads the temp file, stores the key in the keyring, and deletes the temp file

#### Scenario: User cancels or enters empty key
- **WHEN** the user closes the terminal without entering a key or enters an empty string
- **THEN** no key is stored and no error is raised

### Requirement: Inject API key into containers

The application SHALL inject `ANTHROPIC_API_KEY` as an environment variable in all container launches when the key is present in the keyring.

#### Scenario: Key present in keyring
- **WHEN** a container is launched (Attach Here, Maintenance, Root Terminal, CLI mode) and a Claude API key exists in the keyring
- **THEN** `-e ANTHROPIC_API_KEY=<key>` is added to the podman run arguments

#### Scenario: Key not present
- **WHEN** a container is launched and no Claude API key exists in the keyring
- **THEN** no `ANTHROPIC_API_KEY` env var is passed and the container starts without it

### Requirement: Per-process key isolation in entrypoint

The container entrypoint SHALL capture the API key, clear it from the global environment, and re-inject it only into the claude process.

#### Scenario: Claude agent selected
- **WHEN** `TILLANDSIAS_AGENT=claude` and `ANTHROPIC_API_KEY` is set
- **THEN** the entrypoint captures the key into a local variable, unsets the global env var, and passes it to the claude exec via `env ANTHROPIC_API_KEY=...`
- **AND** other processes in the container (bash, openspec, npm) do NOT see the key in their environment

#### Scenario: Non-claude agent
- **WHEN** `TILLANDSIAS_AGENT=opencode` and `ANTHROPIC_API_KEY` is set
- **THEN** the key is still captured and unset from the global environment
- **AND** the key is NOT injected into the opencode process

### Requirement: Deny /proc/*/environ in OpenCode config

The `opencode.json` deny list SHALL include `/proc/*/environ` to prevent AI agents from reading environment variables of other processes.

#### Scenario: Agent attempts to read process environment
- **WHEN** an AI agent tries to read `/proc/<pid>/environ`
- **THEN** the request is denied by the OpenCode permission system
