# environment-runtime Specification

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Configuration-driven image selection
The container image used for environments SHALL be configurable at global and per-project levels, defaulting to the Macuahuitl forge image.

#### Scenario: Default image
- **WHEN** no image is configured globally or per-project
- **THEN** the environment uses `ghcr.io/8007342/macuahuitl:latest`

#### Scenario: Global image override
- **WHEN** the global config specifies `image = "custom-forge:latest"`
- **THEN** all projects without per-project overrides use the custom image

#### Scenario: Per-project image override
- **WHEN** a project's `.tillandsias/config.toml` specifies `image = "my-special-image:v2"`
- **THEN** that project uses the specified image, regardless of the global setting

### Requirement: Attach Here action
The "Attach Here" menu action SHALL launch a configured container environment for the selected project, assign a tillandsia genus for visual identification, mount the project directory, and start development tooling inside the container.

#### Scenario: First attach to project
- **WHEN** the user clicks "Attach Here" on a project with no running environment
- **THEN** a new container is created as `tillandsias-<project>-<genus>` with the configured image, the project directory mounted, caches shared, a tillandsia genus assigned with its icon shown in both the project tree and running section, and the container's entrypoint starts development tooling (OpenCode with curated settings by default)

#### Scenario: Attach to already-running environment (average user)
- **WHEN** an average user clicks "Attach Here" on a project that already has a running container
- **THEN** the application notifies the user that an environment is already running for this project

#### Scenario: Container image not available locally
- **WHEN** the configured image is not present locally
- **THEN** the application attempts to pull the image, showing a non-technical progress indication in the tray ("Preparing environment...")

### Requirement: Ephemeral by design
Every environment container SHALL be ephemeral — created on demand and destroyed after use. No container state beyond mounted volumes SHALL persist.

#### Scenario: Environment stopped
- **WHEN** an environment container is stopped
- **THEN** the container rootfs is destroyed (via `--rm` flag) and only the mounted project directory and cache volumes persist

#### Scenario: Restart after stop
- **WHEN** the user starts an environment for a project that was previously stopped
- **THEN** a fresh container is created from the configured image with no state carried over from the previous run

### Requirement: Idempotent environment creation
Starting an environment for the same project with the same configuration SHALL always produce the same result regardless of how many times it has been done before.

#### Scenario: Repeated attach cycles
- **WHEN** the user attaches, stops, and re-attaches to the same project 10 times
- **THEN** each attach produces an identical environment with the same tools, same mounts, and same behavior

### Requirement: Port range allocation
Each environment SHALL be allocated a configurable port range mapped from the container to the host, with support for non-overlapping ranges across concurrent environments.

#### Scenario: Default port range
- **WHEN** an environment is launched with default configuration
- **THEN** ports 3000-3019 are mapped from the container to the host

#### Scenario: Multiple concurrent environments
- **WHEN** two environments are running with default port ranges
- **THEN** the second environment receives a non-overlapping port range (e.g., 3020-3039) to avoid conflicts

#### Scenario: Custom port range
- **WHEN** a per-project config specifies `port_range = "8080-8089"`
- **THEN** the specified range is used for that project's environment

### Requirement: Global and per-project configuration
The configuration system SHALL support a two-level hierarchy: global defaults at a platform-specific path and per-project overrides at `<project>/.tillandsias/config.toml`.

#### Scenario: Global config only
- **WHEN** a global config exists but no per-project config exists
- **THEN** the global settings are used

#### Scenario: Per-project override
- **WHEN** both global and per-project configs exist with overlapping keys
- **THEN** the per-project values take precedence over global values

#### Scenario: No config files exist
- **WHEN** neither global nor per-project config exists
- **THEN** built-in defaults are used (forge image, default port range, default security flags)

#### Scenario: Platform-specific config paths
- **WHEN** the application runs on macOS
- **THEN** the global config is located at `~/Library/Application Support/tillandsias/config.toml`

#### Scenario: Platform-specific config paths (Windows)
- **WHEN** the application runs on Windows
- **THEN** the global config is located at `%APPDATA%\tillandsias\config.toml`

#### Scenario: Platform-specific config paths (Linux)
- **WHEN** the application runs on Linux
- **THEN** the global config is located at `~/.config/tillandsias/config.toml`

### Requirement: Attach Here launches container and opens terminal
The "Attach Here" action SHALL build the default image if needed, start a container, and open a terminal window with OpenCode running inside.

#### Scenario: First Attach Here (image not built)
- **WHEN** the user clicks "Attach Here" and no `tillandsias-forge:latest` image exists
- **THEN** the image is built from the bundled Containerfile, then the container starts and a terminal opens

#### Scenario: Subsequent Attach Here (image cached)
- **WHEN** the user clicks "Attach Here" and the image already exists
- **THEN** the container starts immediately and a terminal opens within 5 seconds

#### Scenario: Terminal shows OpenCode
- **WHEN** the terminal opens after Attach Here
- **THEN** OpenCode is running in the terminal, ready to accept input, with the project directory mounted

