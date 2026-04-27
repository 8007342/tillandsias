## Why

A forge container that launches sibling service containers (e.g. a postgres
+ nginx pair to test the production stack the agent is editing) currently has
**no observability over those siblings**. The existing per-container
`/var/log/tillandsias/` mount is single-tier and per-container — sibling
forges cannot read each other's logs, and there is no boundary between
"internal noise" (Caddy access log, full debug stream) and "the curated slice
the forge needs to reason about its dependencies".

The user's principle, verbatim:

> Containers shall each have internal logs and external logs, internal reveal
> broken state and are queryable via custom podman tail -f, but external logs
> are a set of hand-curated loggers and output log dirs that will be RW mounted
> at service containers, and RO at the forge and maintenance containers.

This change introduces the **EXTERNAL** tier: a hand-curated, manifest-declared
set of log files per producer, mounted RW at the producer and RO (via the
parent directory) at every consumer in the same enclave. The existing
per-container mount becomes the **INTERNAL** tier and is locked into its
current behaviour (RW at owner, never visible to siblings). Together the two
tiers let agents reason about the externally-observable behaviour of their
sibling production stack without drowning in raw debug noise — and they
**enforce architectural correctness** by making "what a service writes
externally" a versioned contract: the auditor refuses to publish files
that aren't in the producer's `external-logs.yaml` manifest.

The closest existing analogue is `git-service`'s `git-push.log`, written by
`images/git/post-receive-hook.sh` to the per-container `/var/log/tillandsias/`
mount. Today no other container can read it. Under this change it migrates
to `~/.local/state/tillandsias/external-logs/git-service/git-push.log` and
becomes the canonical example of a curated external log: every forge in the
enclave can see it RO without seeing anything else git-service emits.

## What Changes

- **NEW** `MountSource::ExternalLogsProducer { role: &'static str }` —
  resolves to `~/.local/state/tillandsias/external-logs/<role>/`,
  bind-mounted RW at `/var/log/tillandsias/external/` inside the producer.
  The launcher creates the host directory if missing.
- **NEW** `MountSource::ExternalLogsConsumerRoot` — resolves to
  `~/.local/state/tillandsias/external-logs/`, bind-mounted RO at
  `/var/log/tillandsias/external/` inside any container with
  `external_logs_consumer: true`. Consumers see one subdir per producer role.
- **NEW** Two declarative fields on `ContainerProfile`:
  `external_logs_role: Option<&'static str>` and
  `external_logs_consumer: bool`. They are mutually exclusive at audit time;
  any profile that sets BOTH is rejected at launch.
- **NEW** Per-image manifest at `/etc/tillandsias/external-logs.yaml` —
  COPY'd in by the producer's Containerfile. Lists every file the producer
  is permitted to publish externally. Format: YAML with `role`, `files[]`
  (each `name`, `purpose`, `format: text|jsonl`, `rotate_at_mb`, `written_by`).
- **NEW** Auditor sidecar in the tray that ticks every 60 s per running
  producer: (a) diffs on-disk files against the manifest (unlisted files
  surface a yellow chip with `[external-logs] LEAK: ...`); (b) enforces the
  per-file 10 MB cap with truncate-to-tail rotation; (c) growth-rate alarm
  at > 1 MB/min sustained for 5 min.
- **NEW** `tillandsias-logs` CLI baked into the forge + terminal images at
  `/usr/local/bin/tillandsias-logs`, providing `ls`, `tail <role> <file>`,
  and `combine` (interleave the consumer's own internal log + every external
  log in the enclave, sorted by mtime).
- **NEW** `TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external` env var
  exported by `images/default/lib-common.sh` for any tool that wants the
  path without going through the CLI.
- **NEW** `cheatsheets/runtime/external-logs.md` — agent-facing how-to
  with provenance + accountability examples.
- **MIGRATED** `git-service`'s `git-push.log`: producer role
  `Some("git-service")`. On first launch after this change, a one-shot
  in `handlers.rs::ensure_external_logs_dir` moves
  `~/.local/state/tillandsias/containers/git/logs/git-push.log` to the new
  external location and leaves a `MIGRATED.txt` stub behind so a curious
  operator following the old path is told where it went.
- **MODIFIED** `container_profile.rs` profile constructors: every service
  profile (`router`, `proxy`, `inference`, `git_service`, `web`) gains a
  producer role; every forge / terminal profile gains
  `external_logs_consumer: true`. `web`'s role is templated by project
  (`web-<project>`) so multiple project web containers don't collide.
- **MODIFIED** `runtime-logging` spec: extended with a new Requirement
  family ("External-tier logging") that pins the directory layout, mount
  modes, manifest format, auditor invariants, and migration of `git-push.log`.
- **MODIFIED** `forge-paths-ephemeral-vs-persistent.md` cheatsheet: adds
  `external-logs/` as a fifth row in the persistent-paths table with
  category "External logs (curated)".

## Capabilities

### New Capabilities
- `external-logs-layer`: producer-RW / consumer-RO curated log mounts,
  per-image manifest, auditor enforcement, host-side directory layout,
  forge-side `tillandsias-logs` CLI.

### Modified Capabilities
- `runtime-logging`: gains the EXTERNAL tier alongside the existing
  internal-tier file logging. The internal tier's invariants are tightened
  to make "no sibling-readable view of internal logs" an explicit
  requirement (currently true by accident of the per-container mount path).
- `podman-orchestration`: gains `external_logs_role` and
  `external_logs_consumer` profile fields and the corresponding launcher
  argument resolution. Asserts the auditor refuses to launch any profile
  setting both.

## Impact

- **Core** (`crates/tillandsias-core/src/`):
  - `container_profile.rs` — two new `MountSource` variants and the two new
    `ContainerProfile` fields.
  - `config.rs` — new `external_logs_dir()` and `external_logs_role_dir(role)`
    helpers alongside the existing `log_dir` and `container_log_dir`.
- **Tray** (`src-tauri/src/`):
  - `launch.rs::resolve_mount_source` — handle the two new variants;
    create directories on demand (mirrors the existing `ContainerLogs`
    branch).
  - `handlers.rs` — add `ensure_external_logs_dir` (one-shot migration of
    `git-push.log`) called once at tray startup; add the auditor task
    `external_logs_audit_tick` scheduled every 60 s while any producer is
    running.
- **Images** (`images/`):
  - `git/external-logs.yaml` (NEW) — canonical example.
  - `proxy/external-logs.yaml` (NEW) — Squid `access.log` (curated subset).
  - `router/external-logs.yaml` (NEW) — Caddy `access.log`.
  - `inference/external-logs.yaml` (NEW) — `model-load.log`.
  - `default/Containerfile` — install `tillandsias-logs` and add
    `ENV TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external`.
- **Cheatsheets**: new `runtime/external-logs.md`; updated
  `runtime/forge-paths-ephemeral-vs-persistent.md`.
- **Tests**: profile uniqueness/conflict checks, mount-resolution unit tests,
  auditor unit tests for the three failure modes.
- **Performance**: < 5 ms launch overhead; ~10 ms auditor tick per producer
  at 60 s cadence — well below noise.
- **Security**: tightens the architecture (publishes a contract for producer
  log surface). No new attack surface — both directories live inside the
  user's `~/.local/state/tillandsias/`. Consumer mount RO; compromised forge
  can READ external logs but CANNOT write into a sibling's external dir.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — host-side
  path taxonomy this change extends.
- `cheatsheets/runtime/forge-container.md` — runtime contract referenced by
  consumer-side wiring.
- `docs/cheatsheets/logging-levels.md` — accountability log format the
  auditor's `[external-logs]` chip messages follow.
- `docs/strategy/external-logs-observability-plan.md` — strategy memo this
  proposal materialises.
- `openspec/specs/runtime-logging/spec.md` — modified by this change.
- `openspec/specs/podman-orchestration/spec.md` — modified by this change.
- `docs/strategy/forge-hot-cold-split-plan.md` — sibling planning document;
  external-logs are explicitly COLD path (disk-backed, never tmpfs).

## Open Questions (resolve in design.md before /opsx:apply)

- **Auditor cadence**: 60 s tick is the strawman. Could be event-driven
  (inotify on each producer dir) but inotify across podman bind mounts is
  fragile — design.md picks polling for v1.
- **`web-<project>` role naming**: when a single host runs multiple projects
  with their own web containers, role names must not collide. Strawman:
  `web-<project_name>`. Design.md formalises the naming rule.
- **Manifest discovery without `podman cp`**: cheaper to bind-mount the
  manifest into a host-readable path? Strawman keeps `podman cp` for v1
  (no extra mount, ≤4 KB file).
- **Cross-enclave isolation**: today every forge sees every producer in
  *its* enclave. If a future feature lets two enclaves coexist, the
  consumer-root mount must be scoped per enclave. Out of scope for v1.
