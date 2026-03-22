## ADDED Requirements

### Requirement: Fedora Minimal base image with dev tools
The default container image SHALL be based on Fedora Minimal and include OpenCode, OpenSpec CLI, Nix, and essential development tools.

#### Scenario: Image contains OpenCode
- **WHEN** the container starts
- **THEN** `opencode` is available in PATH and executable

#### Scenario: Image contains OpenSpec
- **WHEN** the container starts
- **THEN** `openspec` is available in PATH (installed or deferred to first run)

#### Scenario: Image contains Nix
- **WHEN** the container starts
- **THEN** `nix` is available for reproducible builds with flakes enabled

#### Scenario: Image contains git and GitHub CLI
- **WHEN** the container starts
- **THEN** `git` and `gh` are available in PATH

### Requirement: Non-root user with UID 1000
The container SHALL run as user `forge` (UID 1000) to match host user UID via `--userns=keep-id`.

#### Scenario: Volume permissions
- **WHEN** the container mounts a host directory
- **THEN** files created inside the container are owned by the host user (UID 1000)

### Requirement: Entrypoint launches OpenCode
The container entrypoint SHALL bootstrap the environment and launch OpenCode as the foreground process.

#### Scenario: First run bootstrap
- **WHEN** the container starts for the first time
- **THEN** cache directories are created, OpenSpec is installed if deferred, and OpenCode launches

#### Scenario: Subsequent runs
- **WHEN** the container starts with existing cache
- **THEN** bootstrap is skipped and OpenCode launches immediately
