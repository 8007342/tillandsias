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
Environments SHALL be ephemeral — uncommitted changes are lost on stop. Committed changes persist through the git mirror to the host filesystem and remote (if configured).

@trace spec:environment-runtime, spec:forge-offline

#### Scenario: Environment stopped
- **WHEN** a forge container stops
- **THEN** uncommitted changes SHALL be lost
- **AND** committed changes SHALL exist in the git mirror

#### Scenario: Restart after stop
- **WHEN** a forge container is restarted for the same project
- **THEN** it SHALL clone fresh from the mirror (which has all committed work)

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
When the user triggers "Attach Here", the system SHALL ensure enclave, proxy, mirror, and git service are ready. The forge container SHALL clone from the git mirror. No project directory mount, no credential mounts.

@trace spec:environment-runtime, spec:forge-offline

#### Scenario: Attach Here launches isolated forge
- **WHEN** the user clicks "Attach Here"
- **THEN** the forge container SHALL be on enclave-only network
- **AND** code SHALL come from git mirror clone
- **AND** no credentials SHALL be mounted
- **AND** cache directory SHALL still be mounted for build performance

#### Scenario: First Attach Here (full initialization)
- **WHEN** the user clicks "Attach Here" for a new project
- **THEN** the system SHALL ensure enclave network, proxy, git mirror, and git service
- **AND** launch the forge container on the enclave network
- **AND** the forge entrypoint SHALL run `git clone git://git-service/<project>` into the ephemeral filesystem

#### Scenario: Subsequent Attach Here (services already running)
- **WHEN** the user clicks "Attach Here" and all services are running
- **THEN** the system SHALL launch the forge container directly
- **AND** the forge SHALL clone from the existing mirror (instant, local)

#### Scenario: Multiple containers for same project
- **WHEN** the user launches a second forge container for the same project
- **THEN** both containers SHALL have independent working trees
- **AND** both SHALL clone from the same git mirror
- **AND** the git service SHALL already be running (started by first container)

#### Scenario: Terminal shows OpenCode
- **WHEN** the forge-opencode profile is selected
- **THEN** the OpenCode agent SHALL start inside the container
- **AND** `HTTP_PROXY` and `HTTPS_PROXY` SHALL be set for package installations

### Requirement: Proxy environment variables in forge containers
All forge containers SHALL have `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` environment variables set. `NO_PROXY` SHALL include `localhost,127.0.0.1,git-service` to allow local and git-daemon traffic to bypass the proxy.

@trace spec:environment-runtime, spec:proxy-container

#### Scenario: Proxy env vars present in forge
- **WHEN** a forge container is launched
- **THEN** the environment SHALL include `HTTP_PROXY=http://proxy:3128`
- **AND** `HTTPS_PROXY=http://proxy:3128`
- **AND** `NO_PROXY=localhost,127.0.0.1,git-service`

#### Scenario: Proxy env vars absent in proxy container
- **WHEN** the proxy container is launched
- **THEN** it SHALL NOT have `HTTP_PROXY` or `HTTPS_PROXY` set (it IS the proxy)

### Requirement: Forge entrypoint clones from git mirror
The forge container entrypoint SHALL clone the project from the git mirror via `git clone git://git-service/<project>` into `/home/forge/src/<project>`. The `TILLANDSIAS_GIT_SERVICE` environment variable SHALL contain the git service hostname. Uncommitted changes are ephemeral -- lost when the container stops.

@trace spec:environment-runtime, spec:git-mirror-service

#### Scenario: Forge clones on startup
- **WHEN** a forge container starts
- **THEN** the entrypoint SHALL run `git clone git://git-service/$TILLANDSIAS_PROJECT /home/forge/src/$TILLANDSIAS_PROJECT`
- **AND** set the working directory to the cloned project

#### Scenario: Clone fails (git service not ready)
- **WHEN** the git clone fails (e.g., git service not yet listening)
- **THEN** the entrypoint SHALL retry up to 5 times with 1-second delays
- **AND** if all retries fail, print an error and drop to a shell

### Requirement: Ollama host env var in forge containers
All forge containers SHALL have `OLLAMA_HOST=http://inference:11434` set so that tools and agents can query local LLM models.

@trace spec:inference-container, spec:environment-runtime

#### Scenario: Forge has OLLAMA_HOST
- **WHEN** a forge container is launched
- **THEN** the environment SHALL include `OLLAMA_HOST=http://inference:11434`
