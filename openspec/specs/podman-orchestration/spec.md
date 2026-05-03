<!-- @trace spec:podman-orchestration -->
## Status

status: active

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


### Requirement: Detached web-mode launch profile

The orchestration layer SHALL provide a launch profile that runs web-mode containers detached (`-d`), without `-i`, `-t`, or `--rm`, so that the container survives its originating click. All other hardening flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, read-only root) remain applied.

#### Scenario: Detached flags set, TTY flags cleared
- **WHEN** `build_podman_args()` is called with a web-mode `ForgeProfile`
- **THEN** the resulting argv contains `-d`
- **AND** contains neither `-i` nor `-t` nor `--rm`
- **AND** still contains `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`

### Requirement: Loopback-bound single-port publish for web mode

The orchestration layer SHALL publish exactly one container port to exactly one host port bound to `127.0.0.1` when the profile is web-mode.

#### Scenario: Publish arg is loopback-scoped
- **WHEN** web-mode launch arg assembly runs with allocated host port `P`
- **THEN** the arg list contains `-p 127.0.0.1:<P>:4096`
- **AND** no bare `<P>:4096` form appears
- **AND** no `0.0.0.0` or `::` binding appears

### Requirement: Deterministic forge-container name

The orchestration layer SHALL name persistent OpenCode Web containers exactly `tillandsias-<project>-forge`, without a genus suffix, to make lookup and Stop actions deterministic. The `-forge` suffix is distinct from the existing `-web` suffix reserved for the static-httpd Serve Here feature and SHALL NOT collide with it.

#### Scenario: Name construction ignores genus
- **WHEN** a persistent OpenCode Web container is launched for project `my-app` with an allocated genus
- **THEN** the `--name` flag is `tillandsias-my-app-forge`
- **AND** the genus still appears in the `ContainerInfo` record for UI/iconography purposes
- **AND** the name never collides with a concurrently-running `tillandsias-my-app-web` static-httpd container

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/utils/podman-containers.md` — Podman Containers reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-orchestration" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
