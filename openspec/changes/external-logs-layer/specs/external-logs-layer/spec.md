# external-logs-layer Specification

@trace spec:external-logs-layer

## Purpose

Defines the two-tier log observability model for the Tillandsias enclave:

- **INTERNAL tier**: per-container, RW at owner, never visible to siblings (existing behaviour, now explicit).
- **EXTERNAL tier**: hand-curated files declared in a per-producer `external-logs.yaml` manifest. Mounted RW at the producer and RO (via the parent directory) at every consumer in the same enclave.

This layer enforces an architectural contract: what a service writes externally is part of its versioned public interface, enforced by a tray-side auditor.

## Requirements

### Requirement: Two-tier observability model

#### Scenario: INTERNAL tier — per-container isolation
- **WHEN** a container is launched
- **THEN** its per-container log directory (`MountSource::ContainerLogs`) is mounted RW at `/var/log/tillandsias/` ONLY for that container
- **AND** no sibling container SHALL receive a mount of another container's `ContainerLogs` directory
- **AND** this invariant is an explicit, locked requirement of the runtime-logging capability

#### Scenario: EXTERNAL tier — curated cross-container view
- **WHEN** a producer container is launched
- **THEN** `~/.local/state/tillandsias/external-logs/<role>/` is bind-mounted RW at `/var/log/tillandsias/external/` inside the producer
- **AND** consumer containers receive a RO bind-mount of `~/.local/state/tillandsias/external-logs/` at `/var/log/tillandsias/external/`
- **AND** consumers see one subdirectory per active producer role

### Requirement: Producer mount + manifest contract

#### Scenario: Producer writes only to declared files
- **WHEN** a producer container writes files to `/var/log/tillandsias/external/`
- **THEN** every file SHALL be listed in `/etc/tillandsias/external-logs.yaml` baked into the producer image
- **AND** any file NOT listed in the manifest SHALL trigger a `[external-logs] LEAK: <role> wrote <file> (not in manifest)` WARN+accountability event from the tray auditor within 60 s

#### Scenario: Manifest format
- **WHEN** a producer image is built
- **THEN** it SHALL include `/etc/tillandsias/external-logs.yaml` with schema: `role` (string) + `files[]` (each with `name`, `purpose`, `format: text|jsonl`, `rotate_at_mb`, `written_by`)
- **AND** `format` SHALL be restricted to `text` or `jsonl` — binary formats are not permitted
- **AND** `role` in the manifest SHALL match the profile's `external_logs_role` field exactly

#### Scenario: Host directory creation
- **WHEN** a producer container is launched
- **THEN** the launcher SHALL create `~/.local/state/tillandsias/external-logs/<role>/` if it does not exist before the `podman run` invocation
- **AND** the directory SHALL be disk-backed (NEVER tmpfs) per `forge-hot-cold-split` spec

### Requirement: Consumer mount

#### Scenario: Forge and terminal containers receive RO parent mount
- **WHEN** a container with `external_logs_consumer: true` is launched
- **THEN** `~/.local/state/tillandsias/external-logs/` is bind-mounted RO at `/var/log/tillandsias/external/`
- **AND** the consumer sees one subdirectory per producer role currently active on the host

#### Scenario: No consumer restart required for new producers
- **WHEN** a new producer is launched after a consumer is already running
- **THEN** the consumer SHALL see the new producer's role directory without restart (parent-dir RO mount semantics)

### Requirement: Auditor invariants

#### Scenario: Manifest match check — LEAK alarm
- **WHEN** the tray auditor runs its 60 s tick
- **THEN** for each running producer it SHALL read the manifest via `podman cp <container>:/etc/tillandsias/external-logs.yaml -`
- **AND** for each file found on disk in the role directory that is NOT in the manifest's `files[].name` set, emit:
  - `[external-logs] LEAK: <role> wrote <file> (not in manifest)` at WARN level with `accountability = true`, `category = "external-logs"`, `spec = "external-logs-layer"`

#### Scenario: Size cap — truncate to tail
- **WHEN** a file in `external-logs/<role>/` exceeds `rotate_at_mb` megabytes (default 10 MB per file)
- **THEN** the auditor SHALL truncate the file in place, keeping the newest 50% of bytes
- **AND** emit an INFO+accountability event documenting the original and new size
- **AND** NOT create `.1`/`.2` rotation files — `tail -f` consumers keep reading the same path

#### Scenario: Growth-rate alarm
- **WHEN** a file in `external-logs/<role>/` grows > 1 MB/min sustained for 5 consecutive 60 s ticks (5 min window)
- **THEN** the auditor SHALL emit a WARN+accountability event:
  `[external-logs] WARN: <role> <file> growing <X> MB/min`

#### Scenario: Auditor cadence
- **WHEN** the tray is running
- **THEN** the auditor SHALL tick every 60 s alongside the existing proxy health-check interval
- **AND** growth-rate history SHALL be maintained in a `HashMap<(role, file), VecDeque<(Instant, u64)>>` local to the event loop across ticks

### Requirement: Reverse-breach refusal

#### Scenario: Profile validation at launch time
- **WHEN** a container profile has BOTH `external_logs_role: Some(_)` AND `external_logs_consumer: true` set
- **THEN** `ContainerProfile::validate()` SHALL return `Err` with a message citing `spec:external-logs-layer`
- **AND** `build_podman_args()` SHALL assert this invariant and emit an `accountability = true` WARN if violated

### Requirement: Migration of git-push.log

#### Scenario: One-shot migration at tray startup
- **WHEN** the tray starts and `~/.local/state/tillandsias/containers/tillandsias-git/logs/git-push.log` exists
- **AND** `~/.local/state/tillandsias/external-logs/git-service/git-push.log` does NOT yet exist
- **THEN** `handlers::ensure_external_logs_dir()` SHALL rename the file to the new location atomically
- **AND** leave a `MIGRATED.txt` stub at the old directory with the new path inside
- **AND** this function SHALL be idempotent (subsequent calls are no-ops)

#### Scenario: Post-migration write path
- **WHEN** the git-service container runs post-migration
- **THEN** `post-receive-hook.sh` writes to `/var/log/tillandsias/git-push.log` inside the container
- **AND** the bind-mount shadows this to `~/.local/state/tillandsias/external-logs/git-service/git-push.log` on the host
- **AND** NO entrypoint code change is required in the git-service image

## REMOVED Requirements

None — this is a new capability. The external-logs layer is purely additive; the INTERNAL tier's existing invariants are unchanged.

## Sources of Truth

- `cheatsheets/runtime/external-logs.md` — agent-facing how-to with full Provenance
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — host-side path taxonomy; external-logs/ is the fifth row (Disk, NEVER tmpfs)
- `images/git/external-logs.yaml` — canonical manifest example
- `images/proxy/external-logs.yaml` — proxy role manifest
- `images/router/external-logs.yaml` — router role manifest
- `images/inference/external-logs.yaml` — inference role manifest
- `docs/strategy/external-logs-observability-plan.md` — strategy memo this spec implements
- `openspec/changes/external-logs-layer/design.md` — design decisions (especially the mount choreography choices)
