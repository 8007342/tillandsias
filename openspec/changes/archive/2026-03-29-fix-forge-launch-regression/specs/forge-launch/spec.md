## MODIFIED Requirements

### Requirement: Claude Code launches with API key access
The forge entrypoint SHALL inject the captured `ANTHROPIC_API_KEY` into Claude Code's process environment at exec time, after scrubbing it from the entrypoint's own environment.

#### Scenario: Claude Code authenticates on launch
- **WHEN** a Claude forge container starts with `ANTHROPIC_API_KEY` set
- **THEN** Claude Code receives the API key via `exec env ANTHROPIC_API_KEY=... claude` and can authenticate with the Anthropic API

#### Scenario: Claude Code launches without API key
- **WHEN** a Claude forge container starts without `ANTHROPIC_API_KEY` set
- **THEN** Claude Code launches normally and prompts the user to authenticate via OAuth or other methods

### Requirement: Agent installation shows diagnostic output
The forge entrypoint SHALL display installation progress and errors to the user, not suppress them.

#### Scenario: Claude Code install fails
- **WHEN** `npm install @anthropic-ai/claude-code` fails (network, permissions, etc.)
- **THEN** the error output from npm is visible in the terminal and the entrypoint prints a clear message explaining the failure before falling back to bash

#### Scenario: OpenCode install fails
- **WHEN** the OpenCode binary download fails
- **THEN** the error output from curl is visible in the terminal and the entrypoint prints a clear message before falling back to bash

### Requirement: Agent binary is verified after installation
The forge entrypoint SHALL verify that the installed binary actually runs before attempting to launch it as the primary process.

#### Scenario: Corrupt binary detected
- **WHEN** an agent binary is installed but `<binary> --version` returns a non-zero exit code
- **THEN** the entrypoint prints a diagnostic message and falls back to bash, not to a silent failure

### Requirement: Agent updates are checked periodically
The forge entrypoint SHALL check for newer versions of the selected agent on each launch, rate-limited to once per 24 hours.

#### Scenario: Update available
- **WHEN** a newer version of Claude Code is available and the last check was more than 24 hours ago
- **THEN** the entrypoint updates to the newer version before launching

#### Scenario: Update check skipped (recent)
- **WHEN** the last update check was less than 24 hours ago
- **THEN** the entrypoint skips the check and launches immediately

#### Scenario: Update check fails (offline)
- **WHEN** the update check cannot reach the network
- **THEN** the entrypoint continues with the existing installed version without error
