## NEW Requirements

### Requirement: Auto-initialize OpenSpec on first launch

The container entrypoint SHALL run `openspec init` for the project directory on first launch so that OpenCode's OpenSpec commands work immediately.

#### Scenario: First launch — no openspec directory
- **GIVEN** a project directory with no `openspec/` subdirectory
- **AND** the OpenSpec binary is installed and executable
- **WHEN** the container entrypoint runs
- **THEN** `openspec init --tools opencode` is executed non-interactively in the project directory
- **AND** an `openspec/` directory is created

#### Scenario: Subsequent launch — already initialized
- **GIVEN** a project directory that already contains an `openspec/` subdirectory
- **WHEN** the container entrypoint runs
- **THEN** `openspec init` is NOT executed (idempotent)

#### Scenario: OpenSpec binary not available
- **GIVEN** the OpenSpec npm install was deferred or failed
- **WHEN** the container entrypoint runs
- **THEN** the init step is skipped silently
- **AND** OpenCode still launches normally

#### Scenario: Init failure
- **GIVEN** `openspec init` fails for any reason
- **WHEN** the container entrypoint runs
- **THEN** a warning is printed
- **AND** the entrypoint continues to launch OpenCode (fail-open)
