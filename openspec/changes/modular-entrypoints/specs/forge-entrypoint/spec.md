## ADDED Requirements

### Requirement: Each container type has its own entrypoint script
The forge image SHALL contain per-type entrypoint scripts that each handle exactly one container type's lifecycle.

#### Scenario: Claude forge container starts
- **WHEN** a Claude forge container is launched
- **THEN** the entrypoint `entrypoint-forge-claude.sh` runs, which installs/updates Claude Code, configures OpenSpec, and launches Claude Code as the foreground process

#### Scenario: OpenCode forge container starts
- **WHEN** an OpenCode forge container is launched
- **THEN** the entrypoint `entrypoint-forge-opencode.sh` runs, which installs/updates OpenCode, configures OpenSpec, and launches OpenCode as the foreground process

#### Scenario: Maintenance terminal starts
- **WHEN** a maintenance terminal container is launched
- **THEN** the entrypoint `entrypoint-terminal.sh` runs, which sets up the shell environment (gh auth, PATH, welcome banner) and launches fish as the foreground process

#### Scenario: Web container starts
- **WHEN** a web container is launched
- **THEN** the existing `entrypoint.sh` in the web image runs httpd (no change needed)

### Requirement: Shared setup is factored into a sourceable library
All per-type entrypoints SHALL source a common library for shared setup steps.

#### Scenario: Consistent base setup across container types
- **WHEN** any container type starts
- **THEN** the umask is set to 0022, signal traps are installed, secrets directories are created, `gh auth setup-git` is run, and shell configs are deployed from `/etc/skel/`

#### Scenario: Library is not independently executable
- **WHEN** `entrypoint-common.sh` is invoked directly
- **THEN** it performs setup but does not launch any process (no `exec` statement)

### Requirement: Backward compatibility with cached images
The legacy `tillandsias-entrypoint.sh` SHALL remain in the image as a redirect that dispatches to the correct per-type entrypoint based on `TILLANDSIAS_AGENT`.

#### Scenario: Old Rust binary launches new image
- **WHEN** a Rust binary that does not set `--entrypoint` launches a container with the new image
- **THEN** the default OCI entrypoint (`tillandsias-entrypoint.sh`) dispatches to the correct per-type script based on the `TILLANDSIAS_AGENT` env var

## MODIFIED Requirements

### Requirement: Rust launch code selects the correct entrypoint
The Rust code SHALL set the `--entrypoint` podman flag based on the container type and selected agent.

#### Scenario: Tray Attach Here with Claude
- **WHEN** the user clicks "Attach Here" and Claude is the selected agent
- **THEN** the podman run command includes `--entrypoint /usr/local/bin/entrypoint-forge-claude.sh`

#### Scenario: Tray Maintenance terminal
- **WHEN** the user clicks "Maintenance" for a project
- **THEN** the podman run command includes `--entrypoint /usr/local/bin/entrypoint-terminal.sh` (not `--entrypoint fish`)

#### Scenario: CLI bash mode
- **WHEN** the user runs `tillandsias --bash <path>`
- **THEN** the podman run command includes `--entrypoint /usr/local/bin/entrypoint-terminal.sh`
