# podman-orchestration Specification

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: Async podman CLI execution
All podman operations SHALL be executed via `tokio::process::Command` as non-blocking async operations. The application MUST NOT use synchronous process calls for any container operation.

#### Scenario: Container start
- **WHEN** a container start is requested
- **THEN** the podman command is spawned asynchronously and the tray remains responsive during execution

#### Scenario: Podman not installed
- **WHEN** the application attempts a podman operation and podman is not found in PATH
- **THEN** a clear, non-technical message is displayed: "Tillandsias needs Podman to run apps" with a link to installation instructions

### Requirement: Event-driven container status
Container state changes SHALL be detected via `podman events --format json` as a long-running subprocess feeding the event loop. The application MUST NOT poll for container status.

#### Scenario: Container started externally
- **WHEN** a tillandsias-managed container is started outside the tray app (e.g., via CLI)
- **THEN** the tray detects the state change via podman events and updates the menu

#### Scenario: Container stopped
- **WHEN** a running container stops (gracefully or crashes)
- **THEN** the tray detects the stop event and removes the app from the Running section

#### Scenario: Podman events unavailable
- **WHEN** podman events are not available (e.g., Podman Machine limitations on macOS/Windows)
- **THEN** the application falls back to exponential backoff status checks starting at 1 second, backing off to a maximum of 30 seconds, and MUST NOT degrade to fixed-interval polling

### Requirement: Security-hardened container defaults
Every Tillandsias-managed container SHALL be launched with non-negotiable security flags that cannot be overridden by profiles, config, or any external source. The flags SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, and `--stop-timeout=10`. Additionally, all containers SHALL be attached to the `tillandsias-enclave` internal network. The proxy container SHALL additionally be attached to the default bridge network. Forge containers SHALL additionally have zero credential mounts and enclave-only networking.

@trace spec:podman-orchestration, spec:enclave-network, spec:forge-offline

#### Scenario: Default container launch
- **WHEN** a container is launched by Tillandsias
- **THEN** the command SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, `--stop-timeout=10`
- **AND** the command SHALL include `--network=tillandsias-enclave`

#### Scenario: Proxy container launch
- **WHEN** the proxy container is launched
- **THEN** it SHALL include all non-negotiable security flags
- **AND** it SHALL include `--network=tillandsias-enclave,bridge` for dual-homed access

#### Scenario: Forge container security posture
- **WHEN** a forge container is launched
- **THEN** it SHALL have `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`
- **AND** `--network=tillandsias-enclave` (no bridge)
- **AND** no `-v` mounts for tokens, gh config, git config, or project directory
- **AND** only cache mount and custom mounts (if configured)

#### Scenario: Attempting to weaken security
- **WHEN** a profile or config attempts to override security flags
- **THEN** the hardcoded flags SHALL take precedence and the override SHALL be ignored

#### Scenario: Seccomp profile compatibility
- **WHEN** a container is launched with the default seccomp profile
- **THEN** the application is aware that the default profile blocks approximately 130 syscalls, and that some restrictive profiles may block `close_range()` which crun uses for file descriptor cleanup. If container startup fails with seccomp errors, the logs should indicate seccomp as a possible cause.

### Requirement: GPU passthrough detection
The application SHALL automatically detect GPU devices and pass them through to containers when available, silently falling back to CPU-only when no GPU is present.

#### Scenario: NVIDIA GPU present on Linux
- **WHEN** NVIDIA device files exist (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`)
- **THEN** the container is launched with `--device=` flags for each detected device

#### Scenario: AMD ROCm GPU present on Linux
- **WHEN** AMD ROCm device files exist (`/dev/kfd`, `/dev/dri/renderD128`)
- **THEN** the container is launched with `--device=` flags for each detected device

#### Scenario: No GPU or non-Linux platform
- **WHEN** no GPU devices are detected or the platform is macOS/Windows
- **THEN** the container launches without GPU flags and no error or warning is shown

### Requirement: Multiple concurrent containers with tillandsia namespacing
The application SHALL support running multiple containers simultaneously, namespaced as `tillandsias-<project>-<genus>` where the genus is assigned from the curated tillandsia pool.

#### Scenario: Two projects running
- **WHEN** the user starts environments for `project-a` and `project-b`
- **THEN** two containers run simultaneously named `tillandsias-project-a-aeranthos` and `tillandsias-project-b-ionantha` (genera assigned from pool)

#### Scenario: Second environment for same project
- **WHEN** a power user launches a second concurrent environment for `project-a` that already has `tillandsias-project-a-aeranthos` running
- **THEN** a new container is created as `tillandsias-project-a-xerographica` with a different genus from the pool

#### Scenario: Average user single environment
- **WHEN** an average user clicks "Attach Here" on a project that already has a running environment
- **THEN** they are informed the environment is already running (single environment is the default experience)

#### Scenario: Container name discovery
- **WHEN** the application starts and existing tillandsias containers are running
- **THEN** the containers are discovered by the `tillandsias-` prefix and their genus is parsed from the name suffix

### Requirement: Cross-platform Podman Machine awareness
On macOS and Windows, the application SHALL detect whether Podman Machine is available and running before attempting container operations.

#### Scenario: Podman Machine running
- **WHEN** the user triggers a container operation on macOS/Windows and Podman Machine is running
- **THEN** the operation proceeds normally through the Podman Machine VM layer

#### Scenario: Podman Machine not running
- **WHEN** the user triggers a container operation on macOS/Windows and Podman Machine is not running
- **THEN** the tray displays a clear message guiding the user to start Podman Machine, without attempting to auto-start or auto-install

### Requirement: Rootless networking backend
Rootless containers SHALL use the platform-default networking backend. As of Podman 5.0+, the default rootless networking backend is pasta (not slirp4netns).

#### Scenario: Rootless container networking
- **WHEN** a rootless container is launched on a system with Podman 5.0+
- **THEN** networking uses the pasta backend by default, which provides improved performance over the legacy slirp4netns backend

#### Scenario: Legacy Podman networking
- **WHEN** a rootless container is launched on a system with Podman < 5.0
- **THEN** networking uses slirp4netns as the default backend

### Requirement: Volume mount strategy
Forge containers SHALL mount only the cache directory. Project code comes from git clone. Secrets come from nowhere (forge has none). Git identity comes from environment variables. The proxy container SHALL additionally mount a persistent cache volume for squid's disk cache. Because `--security-opt=label=disable` is applied, volume mounts do not require `:z` or `:Z` SELinux relabeling suffixes.

@trace spec:podman-orchestration, spec:forge-offline

#### Scenario: Forge mounts (enclave architecture)
- **WHEN** a forge container is launched
- **THEN** the only profile mount SHALL be the cache directory at `/home/forge/.cache/tillandsias:rw`
- **AND** no project directory mount SHALL be present
- **AND** no gh config or git config mounts SHALL be present

#### Scenario: Proxy cache mount
- **WHEN** the proxy container is launched
- **THEN** the proxy cache directory SHALL be mounted at `/var/spool/squid:rw`
- **AND** the host path SHALL be `~/.cache/tillandsias/proxy-cache/`

#### Scenario: Custom mounts
- **WHEN** a project config defines additional mounts
- **THEN** they SHALL be appended after the profile mounts

#### Scenario: Shared Nix cache
- **WHEN** the nix builder toolbox is used
- **THEN** the nix store cache SHALL be mounted at the nix store location inside the container

#### Scenario: SELinux relabeling not required
- **WHEN** containers run with `--userns=keep-id`
- **THEN** SELinux relabeling (`:Z` suffix) SHALL NOT be used because `--security-opt=label=disable` is already applied

### Requirement: Image build and cache
The podman client SHALL support building container images from a Containerfile and caching them in the local image store.

#### Scenario: Build image
- **WHEN** `build_image` is called with a Containerfile path and image name
- **THEN** `podman build` runs asynchronously and the built image is available locally

#### Scenario: Image cache hit
- **WHEN** `image_exists` returns true for the target image name
- **THEN** the build step is skipped entirely

### Requirement: Load nix-built image tarballs
The podman client SHALL support loading OCI image tarballs produced by Nix builds.

#### Scenario: Load tarball
- **WHEN** a Nix build produces a tarball
- **THEN** `podman load` imports it and the image is available locally

### Requirement: Port range allocation
The port allocator SHALL assign 20-port ranges and check actual podman container port usage before allocating.

#### Scenario: Default port range
- **WHEN** the first environment is created with default config
- **THEN** it receives port range 3000-3019

#### Scenario: Second environment
- **WHEN** a second environment is created while the first holds 3000-3019
- **THEN** it receives port range 3020-3039

#### Scenario: Orphaned container detected
- **WHEN** a tillandsias container exists in podman but not in app state, holding ports 3000-3019
- **THEN** the allocator detects the conflict via `podman ps` and shifts to the next available range

### Requirement: Stale container cleanup before allocation
The system SHALL attempt to remove orphaned tillandsias containers before allocating ports.

#### Scenario: Stale container removed
- **WHEN** a tillandsias container exists in podman but not in app state
- **THEN** `podman rm -f` is called on it before port allocation proceeds

#### Scenario: Non-tillandsias containers unaffected
- **WHEN** other containers (toolboxes, etc.) hold ports
- **THEN** they are not touched by the cleanup

### Requirement: Terminal uses allocated ports
The Terminal (Ground) handler SHALL use the port allocator instead of hardcoded port ranges.

#### Scenario: Terminal port allocation
- **WHEN** the user opens a Terminal for a project
- **THEN** ports are allocated via the same allocator as Attach Here, avoiding conflicts with other running environments

### Requirement: Git service container managed per-project
The system SHALL manage one git service container per project with the name `tillandsias-git-<project>`. The container SHALL be attached to the enclave network with the network alias `git-service`. The mirror volume SHALL be bind-mounted from `~/.cache/tillandsias/mirrors/<project>/`.

@trace spec:podman-orchestration, spec:git-mirror-service

#### Scenario: Git service container started
- **WHEN** a git service container is started for project "myapp"
- **THEN** the container name SHALL be `tillandsias-git-myapp`
- **AND** it SHALL be on network `tillandsias-enclave` with alias `git-service`
- **AND** the mirror SHALL be mounted at `/srv/git/<project>`

#### Scenario: Git service container stopped
- **WHEN** the last forge container for "myapp" stops
- **THEN** `tillandsias-git-myapp` SHALL be stopped

### Requirement: Inference container managed as shared service
The system SHALL manage the inference container (`tillandsias-inference`) as a shared service on the enclave network with network alias `inference`. The model cache volume SHALL be bind-mounted from the host.

@trace spec:inference-container, spec:podman-orchestration

#### Scenario: Inference container started
- **WHEN** the inference container is started
- **THEN** it SHALL be on `tillandsias-enclave` network with alias `inference`
- **AND** the models volume SHALL be mounted at `/home/ollama/.ollama/models/`
- **AND** `HTTP_PROXY` and `HTTPS_PROXY` SHALL be set for model downloads
