# runtime-logging — EXTERNAL-tier delta

@trace spec:runtime-logging, spec:external-logs-layer

This delta extends `openspec/specs/runtime-logging/spec.md` with a new Requirement family for the EXTERNAL log tier. All existing runtime-logging requirements remain unchanged.

## ADDED Requirements

### Requirement: External-tier logging

Tillandsias SHALL distinguish two log tiers per container: INTERNAL (existing per-container `ContainerLogs` mount, RW at owner, never visible to siblings) and EXTERNAL (hand-curated files declared in the producer's `external-logs.yaml` manifest, RO-visible to every consumer in the enclave). The two-tier model enforces a contract: what a service publishes externally is its versioned API for cross-container observability.

#### Scenario: INTERNAL vs EXTERNAL distinction
- **WHEN** a container emits log output
- **THEN** its per-container `ContainerLogs` mount SHALL be classified as the INTERNAL tier: full debug stream, RW at owner, NOT readable by siblings
- **AND** any file a producer writes to `/var/log/tillandsias/external/` SHALL be classified as the EXTERNAL tier: hand-curated, declared in the producer's manifest, RO at consumers

#### Scenario: INTERNAL isolation is an explicit invariant
- **WHEN** a sibling forge or maintenance container is running
- **THEN** it SHALL NOT receive a mount of any other container's `ContainerLogs` directory
- **AND** this property is now an explicit, enumerable requirement (previously true by accident of per-container mount naming; now locked by spec)

#### Scenario: External-log retention across container stop
- **WHEN** a producer container stops
- **THEN** its external-log files in `~/.local/state/tillandsias/external-logs/<role>/` SHALL persist on the host
- **AND** NOT be deleted or rotated by container lifecycle events

#### Scenario: External-log rotation discipline
- **WHEN** an external-log file exceeds its `rotate_at_mb` cap (default 10 MB)
- **THEN** the tray auditor rotates it in place (truncate to newest 50% of bytes)
- **AND** no `.1`/`.2` rotation files are created (flat layout for `tail -f` consumers)
- **AND** rotation is logged at INFO+accountability level

#### Scenario: Content-type restriction
- **WHEN** a producer declares a file in its manifest
- **THEN** `format` SHALL be `text` or `jsonl` only
- **AND** binary formats are NOT permitted
- **AND** agents reading external logs SHALL be able to `grep` or `jq` them without a deserialiser dep

## Sources of Truth

- `cheatsheets/runtime/external-logs.md` — agent-facing how-to
- `openspec/changes/external-logs-layer/specs/external-logs-layer/spec.md` — primary capability spec
- `docs/strategy/external-logs-observability-plan.md` — strategy memo
