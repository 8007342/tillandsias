# External logs observability layer — strategy

@trace spec:external-logs-layer (NEW capability — to be created)
@trace spec:podman-orchestration, spec:runtime-logging

**Status**: Planned (Opus design 2026-04-26). Wrapped in OpenSpec change
`external-logs-layer` (this document is the strategy memo; the proposal +
design + tasks live under `openspec/changes/external-logs-layer/`).

## Why a two-tier model

A forge container today can launch sibling service containers (postgres, nginx,
redis) to test the production code it is editing. The forge needs to *reason*
about those siblings — "did the request reach nginx?", "is postgres rejecting
the new schema?" — without drowning in raw debug noise and without breaking
sibling isolation. The user's principle, verbatim:

> Containers shall each have internal logs and external logs, internal reveal
> broken state and are queryable via custom podman tail -f, but external logs
> are a set of hand-curated loggers and output log dirs that will be RW mounted
> at service containers, and RO at the forge and maintenance containers.

The layer enforces architectural correctness: **what a service writes to its
external log is part of its public contract**. A service that vomits its
internal state into the external log is misbehaving as visibly as a service
that exposes a private port.

## The two tiers

| Tier      | What it is                                          | Mount mode at producer | Mount mode at consumer | Queryable via            |
|-----------|-----------------------------------------------------|------------------------|------------------------|--------------------------|
| INTERNAL  | Everything to stdout/stderr + the existing `/var/log/tillandsias/` per-container dir (disk-backed, rotated at 10 MB) | RW (own dir)           | NOT MOUNTED            | `podman logs -f <container>` and host-side `tail -f ~/.local/state/tillandsias/containers/<container>/logs/*` |
| EXTERNAL  | A hand-curated set of files declared in `external-logs.yaml` per service image | RW at `/var/log/tillandsias/external/` | RO at `/var/log/tillandsias/external/<service>/` | `tail -f` inside the consumer; `tillandsias-logs combine` from the host |

**Internal already exists** — `MountSource::ContainerLogs` in
`container_profile.rs` resolves to `container_log_dir(container_name)` which
gives `~/.local/state/tillandsias/containers/<container>/logs/`, and
`rotate_container_logs` in `handlers.rs` already enforces the cap. The new
work is the EXTERNAL tier: a separate mount class, a manifest discipline, and
the tray-side wiring that puts the producer's RW mount and the consumer's RO
mounts into agreement.

## Disk layout (host side)

```
~/.local/state/tillandsias/
├── containers/<container>/logs/         # INTERNAL (existing, rotated 10 MB)
└── external-logs/                       # EXTERNAL (NEW — this change)
    ├── git-service/
    │   └── git-push.log                 # migrated from internal dir on first run
    ├── postgres-myproject/
    │   ├── slow-query.log
    │   └── connections.log
    └── nginx-myproject/
        └── access.log
```

External-log identity is the **service role** (`git-service`,
`postgres-myproject`), not the ephemeral container name — a long-lived
service goes through many container instances. A sibling top-level
`external-logs/` (NOT a subdir of `containers/`) makes the directory
addressable across container restarts.

## Mount choreography

- **Producer**: `external_logs_role: Some("git-service")`. Launcher creates
  `~/.local/state/tillandsias/external-logs/git-service/` if absent; bind-mounts
  it RW at `/var/log/tillandsias/external/`.
- **Consumer (forge / maintenance)**: `external_logs_consumer: true`. Launcher
  bind-mounts the **parent** `external-logs/` dir RO at
  `/var/log/tillandsias/external/`. Sees one subdir per producer role.
- **Why parent-dir RO**: a long-running forge picks up new sibling producers
  without restart; flat podman arg list; empty enclave still mounts a valid
  (empty) directory.

## Enforcing the boundary

Tray-side auditor task ticks every 60 s per running producer:

1. **Manifest match**: every file in `external-logs/<role>/` is listed in the
   image's `external-logs.yaml`. Unlisted → tray chip yellow with
   `[external-logs] LEAK: <role> wrote <file> (not in manifest)`.
2. **Size cap per file**: 10 MB hard cap, rotation by truncate-to-tail.
3. **Growth-rate alarm**: > 1 MB/min sustained for 5 min → yellow chip.
4. **No reverse breach**: any profile setting BOTH `external_logs_role` AND
   `external_logs_consumer: true` refused at launch time.

## Forge-side consumption UX

```sh
$ tillandsias-logs ls
git-service           : git-push.log (4.2K, 12 lines, last write 2s ago)
postgres-myproject    : slow-query.log (1.1K, 3 lines, 4m ago)
                        connections.log (812B, 11 lines, 1m ago)
nginx-myproject       : access.log (87K, 1240 lines, <1s ago)

$ tillandsias-logs tail nginx-myproject access.log
[2026-04-26T10:13:01Z] GET /api/users 200 14ms
...

$ tillandsias-logs combine        # interleave INTERNAL (forge's own) + EXTERNAL (siblings)
```

Env var `TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external` exported
by `lib-common.sh` for tools that want the path without going through the CLI.

## Manifest format (per producer image)

`images/git/external-logs.yaml`:

```yaml
# @trace spec:external-logs-layer
role: git-service
files:
  - name: git-push.log
    purpose: |
      One line per push attempt to GitHub from the bare mirror, success or
      failure with exit code summary. CONSUMERS may parse the log to learn
      which forge commits successfully reached origin.
    format: text
    rotate_at_mb: 10
    written_by: post-receive hook + entrypoint retry loop
```

YAML over JSON because `purpose` benefits from multi-line. Format: `text` or
`jsonl` only — banning binary formats keeps logs grep-friendly without a
deserialiser dependency.

## Wiring per profile (mounts table delta)

| Profile           | `external_logs_role`     | `external_logs_consumer` | INTERNAL mount (existing) |
|-------------------|--------------------------|--------------------------|---------------------------|
| forge_opencode    | None                     | true                     | RW (own dir)              |
| forge_claude      | None                     | true                     | RW (own dir)              |
| terminal          | None                     | true                     | RW (own dir)              |
| git_service       | `Some("git-service")`    | false                    | RW (own dir)              |
| proxy             | `Some("proxy")`          | false                    | RW (own dir)              |
| inference         | `Some("inference")`      | false                    | RW (own dir)              |
| router            | `Some("router")`         | false                    | RW (own dir)              |
| web               | `Some("web-<project>")`  | false                    | RW (own dir)              |

`forge_opencode_web` ships v1 as `None / true` (consumer only); becomes
producer in v1.5.

## Retention + cleanup

External logs persist across container stop. Rotation by truncate-to-tail at
10 MB. Manual `tillandsias-logs prune <role>` from the host. Uninstaller
prompts before deleting `~/.local/state/tillandsias/external-logs/`.

## Relationship to the existing internal log dir

`git-push.log` migrates: one-shot `handlers.rs::ensure_external_logs_dir`
moves `~/.local/state/tillandsias/containers/git/logs/git-push.log` to
`~/.local/state/tillandsias/external-logs/git-service/`, leaves a
`MIGRATED.txt` stub. `post-receive-hook.sh` continues writing to
`/var/log/tillandsias/git-push.log` from inside the container — but that
path is now shadowed by the EXTERNAL bind mount, not the INTERNAL one. Zero
entrypoint code change.

## Trade-offs locked

- **Auto-include all enclave producers** (vs. opt-in per-role): the value
  prop is "forge reasons about ALL its dependencies"; opt-in doubles
  config surface for no isolation gain.
- **Plain-text + JSON-lines only**: human/agent reading is the hot path;
  binary couples to a schema crate.
- **Bind-mount parent RO at consumer**: simpler, faster, supports new
  producers without consumer restart.
- **Persist external logs across container stop**: rotation cap bounds disk;
  forensic value of the audit trail is the whole point.
- **No secret-redaction filter**: producer curation discipline is the only
  guarantee; a filter would invite "publish everything" anti-pattern.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — adds
  `external-logs/` as a fifth row in the persistent-paths table.
- `cheatsheets/runtime/external-logs.md` (NEW) — agent-facing how-to.
- `crates/tillandsias-core/src/container_profile.rs` — adds
  `external_logs_role: Option<&'static str>` and
  `external_logs_consumer: bool` per profile.
- `src-tauri/src/launch.rs::resolve_mount_source` — adds
  `MountSource::ExternalLogsProducer { role }` and
  `MountSource::ExternalLogsConsumerRoot`.
- `crates/tillandsias-core/src/config.rs` — `external_logs_dir()` helper.
- `images/git/external-logs.yaml` (NEW) — manifest reference.
- `openspec/specs/runtime-logging/spec.md` — extended.
- `openspec/specs/podman-orchestration/spec.md` — extended.
- `docs/strategy/forge-hot-cold-split-plan.md` — confirms COLD path.

## Implementation sequencing

1. **Core model first**: `MountSource` variants + `ContainerProfile` fields
   with defaults preserving current behaviour. Launcher resolution. Tests.
2. **`git-service` migration**: flip role to `Some("git-service")`, ship
   one-shot `ensure_external_logs_dir` migration. Smallest verifiable
   producer.
3. **Forge consumer wiring**: flip three forge profiles + `terminal_profile`
   to `external_logs_consumer: true`. Ship `tillandsias-logs` script.
4. **Manifest + auditor**: ship `external-logs.yaml` for git, then auditor
   task. Tray chip last.
5. **Cheatsheet + cross-image manifests**: write
   `cheatsheets/runtime/external-logs.md`; ship manifests for proxy /
   inference / router / web.
