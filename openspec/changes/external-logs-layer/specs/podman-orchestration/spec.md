# podman-orchestration — external-logs-layer delta

@trace spec:podman-orchestration, spec:external-logs-layer

This delta extends `openspec/specs/podman-orchestration/spec.md` with two new profile fields and the corresponding launcher argument resolution. All existing podman-orchestration requirements remain unchanged.

## NEW Requirement: external_logs_role profile field

### Scenario: Producer profile declares its role
- **WHEN** a `ContainerProfile` has `external_logs_role: Some("git-service")` (or another role name)
- **THEN** the launcher SHALL resolve `MountSource::ExternalLogsProducer { role }` to `~/.local/state/tillandsias/external-logs/<role>/`
- **AND** create the directory if absent before `podman run`
- **AND** pass `-v <host_role_dir>:/var/log/tillandsias/external:rw,Z` to podman

### Scenario: Default is None (no producer)
- **WHEN** a profile has `external_logs_role: None`
- **THEN** no `ExternalLogsProducer` mount is added to the podman args
- **AND** the profile's existing mounts are unaffected

## NEW Requirement: external_logs_consumer profile field

### Scenario: Consumer profile receives RO parent mount
- **WHEN** a `ContainerProfile` has `external_logs_consumer: true`
- **THEN** the launcher SHALL resolve `MountSource::ExternalLogsConsumerRoot` to `~/.local/state/tillandsias/external-logs/`
- **AND** pass `-v <host_external_logs_dir>:/var/log/tillandsias/external:ro,Z` to podman

### Scenario: Default is false (no consumer)
- **WHEN** a profile has `external_logs_consumer: false`
- **THEN** no `ExternalLogsConsumerRoot` mount is added

## NEW Requirement: Reverse-breach refusal at launch

### Scenario: Both fields set — refused
- **WHEN** a profile has BOTH `external_logs_role: Some(_)` AND `external_logs_consumer: true`
- **THEN** `ContainerProfile::validate()` SHALL return `Err` citing `spec:external-logs-layer`
- **AND** `build_podman_args()` SHALL assert this invariant via `debug_assert!` (panic in debug builds) and emit an accountability WARN in release builds
- **AND** no container with this profile configuration SHALL be considered correctly launched

### Scenario: Valid producer profiles
- **WHEN** a profile has `external_logs_role: Some(_)` AND `external_logs_consumer: false`
- **THEN** `ContainerProfile::validate()` returns `Ok(())`

### Scenario: Valid consumer profiles
- **WHEN** a profile has `external_logs_role: None` AND `external_logs_consumer: true`
- **THEN** `ContainerProfile::validate()` returns `Ok(())`

## Profile assignments (as of this change)

| Profile | `external_logs_role` | `external_logs_consumer` |
|---|---|---|
| `forge_opencode` | None | true |
| `forge_claude` | None | true |
| `forge_opencode_web` | None | true |
| `terminal` | None | true |
| `git_service` | `Some("git-service")` | false |
| `proxy` | `Some("proxy")` | false |
| `router` | `Some("router")` | false |
| `inference` | `Some("inference")` | false |
| `web` | None | false |

`web` remains unwired (not yet a producer) for v1.

## Sources of Truth

- `crates/tillandsias-core/src/container_profile.rs` — profile field declarations + `validate()` method
- `src-tauri/src/launch.rs::build_podman_args` — mount resolution
- `crates/tillandsias-core/src/config.rs::external_logs_dir` / `external_logs_role_dir` — path helpers
- `openspec/changes/external-logs-layer/specs/external-logs-layer/spec.md` — primary capability spec
