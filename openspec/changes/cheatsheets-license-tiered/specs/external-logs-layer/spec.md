# external-logs-layer — cheatsheets-license-tiered delta

@trace spec:external-logs-layer, spec:cheatsheets-license-tiered

This delta extends `openspec/specs/external-logs-layer/spec.md` with the relaxation needed for the new `cheatsheet-telemetry` producer role: a `ContainerProfile` MAY now be both a producer AND a consumer, because the role-scoped RW mount sits strictly under the parent RO mount and cannot shadow it. All other external-logs-layer requirements remain unchanged.

## MODIFIED Requirements

### Requirement: Reverse-breach refusal

A `ContainerProfile` MAY be both a producer (`external_logs_role: Some(_)`) AND a consumer (`external_logs_consumer: true`) — this dual role is the load-bearing case for `cheatsheet-telemetry`: forge containers consume every other role's logs RO at `/var/log/tillandsias/external/` AND produce their own `cheatsheet-telemetry/lookups.jsonl`. The launcher SHALL compose the two mounts so the parent RO mount lands first and the role-scoped RW mount overlays the producer's own subdirectory; the producer's mount sits strictly UNDER the consumer's parent path, so there is no path collision and no leakage across roles. `ContainerProfile::validate()` SHALL accept dual-role profiles; `build_podman_args()` SHALL emit both mounts in the order described above.

#### Scenario: Profile validation accepts dual-role profile
- **WHEN** a container profile has BOTH `external_logs_role: Some("cheatsheet-telemetry")` AND `external_logs_consumer: true` set
- **THEN** `ContainerProfile::validate()` SHALL return `Ok(())`
- **AND** the launcher SHALL emit the consumer's parent RO mount of `~/.local/state/tillandsias/external-logs/` at `/var/log/tillandsias/external/` (RO)
- **AND** the launcher SHALL emit the producer's role-scoped RW mount of `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` at `/var/log/tillandsias/external/cheatsheet-telemetry/` (RW), overlaying the consumer mount only at the producer's own role subdirectory

#### Scenario: Producer-only and consumer-only profiles still validate
- **WHEN** a profile has `external_logs_role: Some(_)` AND `external_logs_consumer: false` (producer-only)
- **THEN** `ContainerProfile::validate()` SHALL return `Ok(())` and only the producer mount SHALL be emitted
- **WHEN** a profile has `external_logs_role: None` AND `external_logs_consumer: true` (consumer-only)
- **THEN** `ContainerProfile::validate()` SHALL return `Ok(())` and only the consumer parent RO mount SHALL be emitted

#### Scenario: Neither set — no external-logs mounts
- **WHEN** a profile has `external_logs_role: None` AND `external_logs_consumer: false`
- **THEN** `ContainerProfile::validate()` SHALL return `Ok(())`
- **AND** no external-logs mounts SHALL appear in the podman argv

## Sources of Truth

- `cheatsheets/runtime/external-logs.md` — agent-facing reference; the Auditor invariants table notes the relaxation for the dual-role case
- `crates/tillandsias-core/src/container_profile.rs` — validate() implementation that accepts dual-role profiles
- `src-tauri/src/launch.rs` — mount composition (parent RO + role-scoped RW overlay)
- `images/default/external-logs.yaml` — cheatsheet-telemetry producer manifest
- `openspec/changes/cheatsheets-license-tiered/specs/cheatsheets-license-tiered/spec.md` — the cheatsheet-telemetry producer requirement that motivates this relaxation
