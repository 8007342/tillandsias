## ADDED Requirements

### Requirement: Built-in profiles for all container types
The application SHALL provide built-in `ContainerProfile` definitions for forge-opencode, forge-claude, terminal, and web container types.

#### Scenario: Forge-OpenCode profile
- **WHEN** an OpenCode forge container is launched
- **THEN** the profile specifies: entrypoint `entrypoint-forge-opencode.sh`, mounts for project(rw) and cache(rw), secrets for gh(ro) and git(rw), env vars for PROJECT, HOST_OS, AGENT, GIT_CONFIG_GLOBAL — and does NOT include Claude secrets

#### Scenario: Forge-Claude profile
- **WHEN** a Claude forge container is launched
- **THEN** the profile specifies: entrypoint `entrypoint-forge-claude.sh`, mounts for project(rw) and cache(rw), secrets for gh(ro), git(rw), and claude_dir(rw), env vars including ANTHROPIC_API_KEY

#### Scenario: Terminal profile
- **WHEN** a maintenance terminal is launched
- **THEN** the profile specifies: entrypoint `entrypoint-terminal.sh`, mounts for project(rw) and cache(rw), secrets for gh(ro) and git(rw), no agent secrets, no API keys

#### Scenario: Web profile
- **WHEN** a web container is launched
- **THEN** the profile specifies: entrypoint `/entrypoint.sh`, image `tillandsias-web`, mount for document_root(ro), no secrets, no env vars, port 8080

### Requirement: Single build_podman_args function replaces all duplicated launch logic
All container launch paths (tray Attach Here, tray Maintenance, tray Root Terminal, CLI mode) SHALL call the same `build_podman_args()` function with the appropriate profile and context.

#### Scenario: Tray and CLI produce identical args for same inputs
- **WHEN** a Claude forge container is launched from the tray with the same project and config as a CLI launch
- **THEN** the podman run arguments are identical (same security flags, same mounts, same env vars)

#### Scenario: No format string launch commands
- **WHEN** any container is launched from any code path
- **THEN** the podman arguments are constructed via `Vec<String>` push operations on a profile, never via `format!()` string interpolation of raw podman flags

### Requirement: Per-project config can extend profiles
A project's `.tillandsias/config.toml` SHALL be able to add custom mounts and env vars to any built-in profile.

#### Scenario: Custom mount added via project config
- **WHEN** a project config specifies `[[mounts]]` with `host = "/data/models"`, `container = "/models"`, `mode = "ro"`
- **THEN** the custom mount is appended to the profile's built-in mounts

#### Scenario: Custom mounts cannot override security
- **WHEN** a project config specifies custom mounts
- **THEN** the non-negotiable security flags are still present and cannot be removed
