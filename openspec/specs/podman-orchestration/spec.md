## Purpose

Tillandsias launches every container via the podman CLI with a strict
non-negotiable hardening contract: read-only root filesystems where
possible, capability drops by default, no-new-privileges, label-disabled
SELinux, and userns mapping. This capability defines the orchestration
contract — how profiles are constructed, how launch arguments are emitted,
and which security flags MUST always be present.
## Requirements
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

### Requirement: Typed TmpfsMount with size_mb cap

`build_podman_args()` SHALL emit `--tmpfs=<path>:size=<N>m,mode=<oct>` for every
`TmpfsMount` in the profile, using the typed `TmpfsMount { path, size_mb, mode }`
struct rather than bare strings. The `if profile.read_only` gate that previously
suppressed tmpfs emission SHALL be removed — tmpfs mounts are emitted regardless
of root-FS mode.

> Delta: `tmpfs_mounts` in `ContainerProfile` changes from `Vec<&'static str>` (bare
> paths, no quota) to `Vec<TmpfsMount>` where each mount carries a `path`, a
> `size_mb` kernel-enforced cap, and an octal `mode`. The `if profile.read_only`
> gate that previously suppressed tmpfs emission is removed — tmpfs mounts are
> emitted regardless of root-FS mode.
`TmpfsMount` in the profile, where:
- `<path>` is the absolute container path
- `<N>` is `TmpfsMount.size_mb` in MiB
- `<oct>` is `TmpfsMount.mode` formatted as a 4-digit octal integer (e.g., `01777`)

The `mode=` field SHALL always be present. The `size=` field SHALL always be present
and SHALL be non-zero.

#### Scenario: TmpfsMount with size_mb cap emits size=<N>m in podman argv

- **WHEN** `build_podman_args()` processes a profile with `TmpfsMount { path: "/tmp", size_mb: 256, mode: 0o1777 }`
- **THEN** the resulting argv contains `--tmpfs=/tmp:size=256m,mode=01777`
- **AND** NOT `--tmpfs=/tmp` (bare path without size cap is forbidden)

#### Scenario: Service profiles (web, git, inference) carry 64 MB tmpfs caps on their existing mounts

- **WHEN** `build_podman_args()` processes the `web` or `git_service` profiles
- **THEN** every existing tmpfs mount is emitted with `size=64m`

---

### Requirement: --memory pairing whenever any tmpfs mount is present

When `tmpfs_mounts` is non-empty, `build_podman_args()` SHALL append both
`--memory=<ceiling>m` and `--memory-swap=<ceiling>m` where the ceiling is
`sum(tmpfs.size_mb) + 256` (256 MB working-set baseline). This ensures zero net
swap allocation from the container.

> Delta: when `tmpfs_mounts` is non-empty, `build_podman_args()` appends
> `--memory=<ceiling>m` and `--memory-swap=<ceiling>m` to cap the container's
> aggregate RAM consumption. The ceiling is `sum(tmpfs.size_mb) + 256` (256 MB
> working-set baseline).

`--memory-swap` SHALL equal `--memory` exactly, ensuring zero net swap allocation.
This is the "no swap escape from the RAM-only guarantee" rule.

#### Scenario: --memory and --memory-swap appended when tmpfs is non-empty

- **WHEN** a profile has one or more tmpfs mounts
- **THEN** the podman argv contains both `--memory=<N>m` and `--memory-swap=<N>m`
  where N = sum of all tmpfs size_mb caps + 256

#### Scenario: Profiles with no tmpfs mounts emit no --memory flag

- **WHEN** a profile has an empty `tmpfs_mounts` list
- **THEN** the podman argv does NOT contain `--memory` or `--memory-swap`
- **AND** host RAM is the only ceiling (existing behaviour preserved)

### Requirement: external_logs_role profile field

The `ContainerProfile` struct SHALL carry an `external_logs_role: Option<&'static str>` field. When `Some(role)`, the launcher SHALL bind-mount the host's per-role external-logs directory RW into the container at `/var/log/tillandsias/external/`.

#### Scenario: Producer profile declares its role
- **WHEN** a `ContainerProfile` has `external_logs_role: Some("git-service")` (or another role name)
- **THEN** the launcher SHALL resolve `MountSource::ExternalLogsProducer { role }` to `~/.local/state/tillandsias/external-logs/<role>/`
- **AND** create the directory if absent before `podman run`
- **AND** pass `-v <host_role_dir>:/var/log/tillandsias/external:rw,Z` to podman

#### Scenario: Default is None (no producer)
- **WHEN** a profile has `external_logs_role: None`
- **THEN** no `ExternalLogsProducer` mount is added to the podman args
- **AND** the profile's existing mounts are unaffected

### Requirement: external_logs_consumer profile field

The `ContainerProfile` struct SHALL carry an `external_logs_consumer: bool` field. When `true`, the launcher SHALL bind-mount the parent external-logs directory RO into the container at `/var/log/tillandsias/external/`, exposing every producer's curated logs to the consumer.

#### Scenario: Consumer profile receives RO parent mount
- **WHEN** a `ContainerProfile` has `external_logs_consumer: true`
- **THEN** the launcher SHALL resolve `MountSource::ExternalLogsConsumerRoot` to `~/.local/state/tillandsias/external-logs/`
- **AND** pass `-v <host_external_logs_dir>:/var/log/tillandsias/external:ro,Z` to podman

#### Scenario: Default is false (no consumer)
- **WHEN** a profile has `external_logs_consumer: false`
- **THEN** no `ExternalLogsConsumerRoot` mount is added

### Requirement: Reverse-breach refusal at launch

A `ContainerProfile` MUST NOT be both a producer (`external_logs_role: Some(_)`) AND a consumer (`external_logs_consumer: true`). The `validate()` method on `ContainerProfile` SHALL refuse such profiles, and `build_podman_args()` SHALL assert this invariant.

#### Scenario: Both fields set — refused
- **WHEN** a profile has BOTH `external_logs_role: Some(_)` AND `external_logs_consumer: true`
- **THEN** `ContainerProfile::validate()` SHALL return `Err` citing `spec:external-logs-layer`
- **AND** `build_podman_args()` SHALL assert this invariant via `debug_assert!` (panic in debug builds) and emit an accountability WARN in release builds

#### Scenario: Valid producer profiles
- **WHEN** a profile has `external_logs_role: Some(_)` AND `external_logs_consumer: false`
- **THEN** `ContainerProfile::validate()` returns `Ok(())`

#### Scenario: Valid consumer profiles
- **WHEN** a profile has `external_logs_role: None` AND `external_logs_consumer: true`
- **THEN** `ContainerProfile::validate()` returns `Ok(())`

