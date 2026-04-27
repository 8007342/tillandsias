# podman-orchestration — external-logs-layer delta

@trace spec:podman-orchestration, spec:external-logs-layer

This delta extends `openspec/specs/podman-orchestration/spec.md` with two new profile fields and the corresponding launcher argument resolution. All existing podman-orchestration requirements remain unchanged.

## ADDED Requirements

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

## Sources of Truth

- `crates/tillandsias-core/src/container_profile.rs` — profile field declarations + `validate()` method
- `src-tauri/src/launch.rs::build_podman_args` — mount resolution
- `crates/tillandsias-core/src/config.rs::external_logs_dir` / `external_logs_role_dir` — path helpers
- `openspec/changes/external-logs-layer/specs/external-logs-layer/spec.md` — primary capability spec
