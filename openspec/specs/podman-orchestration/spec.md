## MODIFIED Requirements

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

#### Scenario: Seccomp profile compatibility
- **WHEN** a container is launched with the default seccomp profile
- **THEN** the application is aware that the default profile blocks approximately 130 syscalls, and that some restrictive profiles may block `close_range()` which crun uses for file descriptor cleanup. If container startup fails with seccomp errors, the logs should indicate seccomp as a possible cause.

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
