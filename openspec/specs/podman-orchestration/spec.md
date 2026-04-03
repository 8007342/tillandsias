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
Every container launched by Tillandsias SHALL include non-negotiable security flags that MUST NOT be weakened by configuration. Additional restrictions MAY be added.

#### Scenario: Default container launch
- **WHEN** a container is launched with default settings
- **THEN** the container runs with `--rm`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, and `--init` (for proper PID 1 signal handling and zombie reaping)

#### Scenario: Attempting to weaken security
- **WHEN** a per-project config attempts to disable cap-drop or no-new-privileges
- **THEN** the security flags remain enforced and the weakening configuration is ignored

#### Scenario: Strengthening security
- **WHEN** a per-project config adds `read_only = true` or `network = "none"`
- **THEN** the additional restrictions are applied on top of the non-negotiable defaults

### Requirement: FUSE file descriptor sanitization before container launch
All podman command constructors (`podman_cmd_sync()` and `podman_cmd()`) SHALL close inherited file descriptors >= 3 before exec'ing the podman binary, using a POSIX-standard `pre_exec` hook.

#### Scenario: AppImage FUSE FD inheritance
- **WHEN** tillandsias runs as an AppImage with squashfuse FUSE FDs open
- **THEN** podman/crun SHALL NOT receive those FDs AND container launch SHALL succeed without OCI permission errors

#### Scenario: Standard FD preservation
- **WHEN** podman is launched
- **THEN** stdin (0), stdout (1), and stderr (2) SHALL be preserved AND only FDs >= 3 SHALL be closed

#### Scenario: Non-AppImage environments
- **WHEN** tillandsias runs from a native binary (not AppImage)
- **THEN** FD sanitization SHALL still execute (defense in depth) AND SHALL NOT affect container operation

#### Scenario: Cross-platform safety
- **WHEN** building for macOS or Windows
- **THEN** the pre_exec FD cleanup SHALL be conditionally compiled (Linux only) AND SHALL NOT cause compilation errors on other platforms

#### Scenario: Seccomp close_range elimination
- **WHEN** podman/crun starts with a pre-sanitized FD table (only FDs 0-2 open)
- **THEN** crun SHALL NOT need to call `close_range()` for FD cleanup AND the default seccomp profile's syscall restrictions SHALL NOT cause container startup failures

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
Container volume mounts SHALL follow a secure, minimal strategy with configurable overrides for power users. Because `--security-opt=label=disable` is applied as a non-negotiable security default (disabling SELinux separation for the container), volume mounts do not require `:z` or `:Z` SELinux relabeling suffixes.

#### Scenario: Default mounts
- **WHEN** a container is launched for a project at `~/src/my-project`
- **THEN** the project directory is mounted read-write to the container's workspace path, and the shared cache directory (`~/.cache/tillandsias/`) is mounted for persistent caches

#### Scenario: Custom mounts
- **WHEN** a per-project config specifies additional mounts
- **THEN** the configured mounts are added alongside the defaults, with the specified access mode (ro/rw)

#### Scenario: Shared Nix cache
- **WHEN** multiple containers are running concurrently
- **THEN** all containers share the same Nix cache directory (`~/.cache/tillandsias/nix/`) enabling build artifact reuse across projects

#### Scenario: SELinux relabeling not required
- **WHEN** a volume is mounted into a container
- **THEN** no `:z` or `:Z` suffix is needed because `--security-opt=label=disable` disables SELinux confinement for the container process, making relabeling unnecessary

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

