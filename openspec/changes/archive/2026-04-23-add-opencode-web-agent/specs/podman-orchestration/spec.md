## ADDED Requirements

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
