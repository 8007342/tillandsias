## MODIFIED Requirements

### Requirement: Entrypoint launches OpenCode with graceful fallback
The container entrypoint SHALL launch OpenCode as the foreground process and fall back to an interactive bash shell if OpenCode fails to start.

#### Scenario: OpenCode launches successfully
- **WHEN** the container starts and OpenCode is available and its config is valid
- **THEN** OpenCode runs as the foreground process

#### Scenario: OpenCode fails to start
- **WHEN** OpenCode exits with a non-zero status (e.g., bad config, missing agent, runtime error)
- **THEN** the entrypoint prints a diagnostic message and falls back to an interactive bash shell

#### Scenario: OpenCode not found
- **WHEN** the `opencode` binary is not in PATH
- **THEN** the entrypoint prints a diagnostic message and falls back to an interactive bash shell

#### Scenario: OpenCode config contains only tools and permissions
- **WHEN** the container image is built with the default `opencode.json`
- **THEN** the config does NOT reference any specific provider or model, allowing OpenCode to use its built-in defaults
