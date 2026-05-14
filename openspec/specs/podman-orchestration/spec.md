<!-- @trace spec:podman-orchestration -->
## Status

active

## Requirements

### Requirement: Security-hardened container defaults
- **ID**: podman-orchestration.container.security-hardened-defaults@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.security-flags-immutable]
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
- **ID**: podman-orchestration.container.fuse-fd-sanitization@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.fd-table-minimal-before-exec]
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
- **ID**: podman-orchestration.network.rootless-backend@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.no-slirp-on-podman5]
Rootless containers SHALL use the platform-default networking backend. As of Podman 5.0+, the default rootless networking backend is pasta (not slirp4netns).

#### Scenario: Rootless container networking
- **WHEN** a rootless container is launched on a system with Podman 5.0+
- **THEN** networking uses the pasta backend by default, which provides improved performance over the legacy slirp4netns backend

#### Scenario: Legacy Podman networking
- **WHEN** a rootless container is launched on a system with Podman < 5.0
- **THEN** networking uses slirp4netns as the default backend

### Requirement: Volume mount strategy
- **ID**: podman-orchestration.mounts.secure-volume-strategy@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.mounts-respect-security-opts]
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
- **ID**: podman-orchestration.web.detached-launch-profile@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.web-detached-survives-click, podman-orchestration.invariant.hardening-flags-persist]

The orchestration layer SHALL provide a launch profile that runs web-mode containers detached (`-d`), without `-i`, `-t`, or `--rm`, so that the container survives its originating click. All other hardening flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, read-only root) remain applied.

#### Scenario: Detached flags set, TTY flags cleared
- **WHEN** `build_podman_args()` is called with a web-mode `ForgeProfile`
- **THEN** the resulting argv contains `-d`
- **AND** contains neither `-i` nor `-t` nor `--rm`
- **AND** still contains `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`

### Requirement: Deterministic forge-container name
- **ID**: podman-orchestration.container.deterministic-forge-name@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.forge-name-no-genus-suffix, podman-orchestration.invariant.no-forge-web-collision]

The orchestration layer SHALL name persistent OpenCode Web containers exactly `tillandsias-<project>-forge`, without a genus suffix, to make lookup and Stop actions deterministic. The `-forge` suffix is distinct from the existing `-web` suffix reserved for the static-httpd Serve Here feature and SHALL NOT collide with it.

#### Scenario: Name construction ignores genus
- **WHEN** a persistent OpenCode Web container is launched for project `my-app` with an allocated genus
- **THEN** the `--name` flag is `tillandsias-my-app-forge`
- **AND** the genus still appears in the `ContainerInfo` record for UI/iconography purposes
- **AND** the name never collides with a concurrently-running `tillandsias-my-app-web` static-httpd container

### Requirement: Launchers build argv directly
- **ID**: podman-orchestration.launch.direct-argv@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [podman-orchestration.invariant.launch-argv-no-shell-join]
Tillandsias launchers SHALL construct Podman argv directly and pass them to
`Command::new("podman")` or an equivalent terminal-emulator wrapper. They
MUST NOT build shell-escaped command strings for runtime container launch.

#### Scenario: Detached web launch uses argv
- **WHEN** the tray launches a persistent OpenCode Web container
- **THEN** the launch path SHALL pass a direct argv vector to Podman
- **AND** no `sh -lc` or equivalent shell string join SHALL be used for the runtime path

#### Scenario: Interactive launch uses argv
- **WHEN** the tray launches OpenCode, Claude, or Maintenance in a terminal
- **THEN** the terminal emulator SHALL receive `podman` plus argv directly
- **AND** the command SHALL not be re-parsed by a shell layer

## Invariants

### Invariant: Security flags are non-negotiable
- **ID**: podman-orchestration.invariant.security-flags-immutable
- **Expression**: `config.security_flags CONTAINS [--cap-drop=ALL, --security-opt=no-new-privileges, --userns=keep-id] && IMMUTABLE_BY_PROJECT_CONFIG`
- **Measurable**: true

### Invariant: FD table is minimal before exec()
- **ID**: podman-orchestration.invariant.fd-table-minimal-before-exec
- **Expression**: `pre_exec_hook() ENSURES FDs_0_to_2_open AND FDs >= 3_are_closed_before_podman_exec()`
- **Measurable**: true

### Invariant: Forge container name has no genus suffix
- **ID**: podman-orchestration.invariant.forge-name-no-genus-suffix
- **Expression**: `forge_container_name() == tillandsias-<project>-forge AND !contains(genus_suffix)`
- **Measurable**: true

### Invariant: No collision between forge and web container names
- **ID**: podman-orchestration.invariant.no-forge-web-collision
- **Expression**: `tillandsias-<project>-forge !== tillandsias-<project>-web`
- **Measurable**: true

### Invariant: Hardening flags persist in web mode
- **ID**: podman-orchestration.invariant.hardening-flags-persist
- **Expression**: `web_profile.build_podman_args() CONTAINS [--cap-drop=ALL, --security-opt=no-new-privileges, --userns=keep-id] && INDEPENDENT_OF_TTY_FLAGS`
- **Measurable**: true

### Invariant: Launch argv is not shell-joined
- **ID**: podman-orchestration.invariant.launch-argv-no-shell-join
- **Expression**: `runtime_launch_path USES argv_directly AND NOT shell_escaped_join_for_podman_run`
- **Measurable**: true

### Invariant: No slirp4netns on Podman 5.0+
- **ID**: podman-orchestration.invariant.no-slirp-on-podman5
- **Expression**: `podman_version >= 5.0 AND rootless_container => pasta_backend (NOT slirp4netns)`
- **Measurable**: true

### Invariant: Mounts respect security options
- **ID**: podman-orchestration.invariant.mounts-respect-security-opts
- **Expression**: `label=disable => no_selinux_relabel_suffixes_needed && mounts_inherit_container_security_context`
- **Measurable**: true

## Litmus Tests

## Litmus Chain

When iterating on podman orchestration, start with the exact failure boundary
and widen only as needed:

1. `./scripts/run-litmus-test.sh podman-path-availability`
1. `./scripts/run-litmus-test.sh podman-orchestration`
1. `./scripts/run-litmus-test.sh podman-container-spec`
1. `./scripts/run-litmus-test.sh podman-container-handle`
1. `./scripts/run-litmus-test.sh security-privacy-isolation`
1. `./build.sh --ci --strict --filter podman-container-spec:podman-container-handle:podman-orchestration:security-privacy-isolation`
1. `./build.sh --ci-full --install --strict --filter podman-container-spec:podman-container-handle:podman-orchestration:security-privacy-isolation:default-image`
1. `tillandsias --init --debug`

The following litmus tests validate podman-orchestration requirements:

- `litmus-podman-path-availability.yaml` — Verifies podman is installed on PATH before stack scripts run (Req: podman-orchestration.*)
- `litmus-enclave-isolation.yaml` — Validates enclave network and proxy wiring contract (Req: enclave-network.*)
- `litmus-fd-table-minimal.yaml` — Validates FD sanitization before container launch (Req: podman-orchestration.container.fuse-fd-sanitization@v1)
- `litmus-podman-container-spec-shape.yaml` — Validates the typed spec builder and immutable defaults (Reqs: podman-container-spec.*)
- `litmus-podman-container-handle-shape.yaml` — Validates the runtime handle snapshot shape (Reqs: podman-container-handle.*)
- `litmus-podman-web-launch-profile.yaml` — Validates detached web launch profile and secure mount strategy (Reqs: podman-orchestration.web.detached-launch-profile@v1, podman-orchestration.mounts.secure-volume-strategy@v1)
- `litmus-container-naming.yaml` — Validates deterministic forge-container naming (Req: podman-orchestration.container.deterministic-forge-name@v1)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/utils/podman-containers.md` — Podman Containers reference and patterns
- `openspec/specs/podman-container-spec/spec.md` — Typed container spec builder
- `openspec/specs/podman-container-handle/spec.md` — Container handle snapshot and identity

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-orchestration" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
