# Design — external-logs-layer

## Context

Tillandsias forge containers today live in an enclave with sibling service
containers (`git-service`, `proxy`, `inference`, `router`, optional `web`,
plus user-launched test siblings). Each container writes to its own
per-container log directory (`MountSource::ContainerLogs` →
`~/.local/state/tillandsias/containers/<container>/logs/`, RW at
`/var/log/tillandsias/` in-container). No container can read another's
log directory; the only cross-container observability path is `podman
logs -f` from the **host**, never from a sibling.

This is the right default for noise isolation. It is the wrong default for
*deliberate* cross-container observability: a forge testing a postgres
sibling needs the slow-query log; a forge debugging a routing issue needs
the Caddy access log. Today the only way to get them is to leave the forge
and `tail -f` from the host — defeating the whole "agent reasons inside
the enclave" pattern.

The fix is **two tiers**, with the existing single tier rebadged as
INTERNAL and a new EXTERNAL tier added on top:

- INTERNAL is what we have. Per-container, RW at owner, NEVER visible to
  siblings. Carries every byte stdout/stderr emits and any debug-grade
  files the entrypoint chooses to write into `/var/log/tillandsias/`.
  The host-side directory is already rotated at 10 MB by
  `handlers.rs::rotate_container_logs`.
- EXTERNAL is new. A *hand-curated* set of files declared in the producer
  image's `external-logs.yaml` manifest. RW at the producer at
  `/var/log/tillandsias/external/`; RO (via the parent directory) at every
  consumer in the same enclave at the same path. The consumer browses by
  role-named subdirectory.

The closest existing analogue is the git-service `git-push.log`, written
by `images/git/post-receive-hook.sh` to the producer's per-container
`/var/log/tillandsias/`. Today no consumer can read it; this change
migrates it to the canonical EXTERNAL location and makes it the seed
example.

## Goals / Non-Goals

**Goals:**

- Every service container in the enclave SHALL be able to publish a curated
  set of log files visible to every consumer container in the same enclave,
  while keeping its internal noise per-container.
- The set of files a producer publishes SHALL be declared in a manifest
  (`/etc/tillandsias/external-logs.yaml`) baked into its image. Unlisted
  files SHALL surface as a tray-side accountability alarm
  (`[external-logs] LEAK: ...`).
- A consumer (forge / maintenance terminal) SHALL be able to discover every
  available external log via `tillandsias-logs ls` and tail any of them via
  `tillandsias-logs tail <role> <file>`.
- INTERNAL logs SHALL remain unreadable from any sibling container — this
  is locked as an explicit invariant of the new spec.
- The git-service `git-push.log` SHALL migrate to the EXTERNAL tier with no
  entrypoint code change (mount-shadow only).
- External-log files SHALL persist across container stop (the audit value
  of historical lines outweighs the disk cost; rotation bounds it).

**Non-Goals:**

- Encrypting external-log contents. They are by definition curated for
  cross-container reading; encryption would defeat the purpose.
- Cross-host external-log sharing. Producers and consumers must live in the
  same enclave on the same host.
- Replacing the INTERNAL tier. Internal stays exactly as-is; the change is
  purely additive.
- Real-time push (websocket, SSE) of external-log lines to consumers.
  `tail -f` over a bind-mounted file is sufficient and free.
- Schema-validated structured logs (postcard, Cap'n Proto). External logs
  are TEXT or JSON-lines for human / agent grep-ability. Other formats out
  of scope.
- Per-line redaction. Producer curation discipline is the sole guarantee;
  a redaction layer would invite "publish everything, rely on the filter"
  anti-pattern.

## Decisions

### Decision 1 (Q1) — Disk layout: sibling top-level `external-logs/`

**Choice**: External logs live at
`~/.local/state/tillandsias/external-logs/<role>/<file>` (per producer
role), parallel to the existing
`~/.local/state/tillandsias/containers/<container>/logs/<file>` (per
INTERNAL container).

**Why**: A producer's external-log identity is its **role**
(`git-service`, `postgres-myproject`, `nginx-myproject`), not its ephemeral
container name. A long-lived service goes through many container instances
(image upgrade, restart, replace); the external log dir must outlive any
single container. Putting it as a child of `containers/<container>/` would
tie the audit trail to a vanished container's lifecycle.

**Rejected alternative — symlinks to per-container dirs**: adds a layer for
every bind mount to traverse, breaks subtly under podman machine VMs
(gvproxy + the macOS / Windows Linux VM resolve symlinks oddly), and
`secrets-management` already prefers real paths over symlinks for analogous
reasons.

### Decision 2 (Q2) — Manifest format: YAML at `/etc/tillandsias/external-logs.yaml`

**Choice**: Each producer image bakes a `external-logs.yaml` at
`/etc/tillandsias/external-logs.yaml`. YAML schema:

```yaml
role: <string>            # MUST match the role declared in the profile
files:
  - name: <string>        # filename relative to the role's external dir
    purpose: <string>     # one paragraph; CONSUMERS read this to know intent
    format: text | jsonl  # v1 only allows these two
    rotate_at_mb: <int>   # default 10
    written_by: <string>  # describe which entrypoint code emits it
```

**Why YAML**: human-friendly, project already ships `serde_yaml` as
transitive dep, agents reading the manifest get readable diffs in PRs.
Comments matter for `purpose` (multi-line, explanatory).

**Why no JSON**: `purpose` benefits from multi-line authorial freedom.

**Why no postcard / binary**: parsed at most once per auditor tick (60 s);
throughput is irrelevant; human readability is everything.

### Decision 3 (Q3) — Mount choreography: parent-dir RO at consumer, role-dir RW at producer

**Choice**:

- Producer: bind-mount `~/.local/state/tillandsias/external-logs/<role>/`
  RW at `/var/log/tillandsias/external/`. The producer's existing
  `/var/log/tillandsias/git-push.log` (etc.) writes into this mount; no
  in-container code changes.
- Consumer: bind-mount the **parent**
  `~/.local/state/tillandsias/external-logs/` RO at
  `/var/log/tillandsias/external/`. The consumer's `ls` shows one
  subdirectory per role.

**Why parent-dir for the consumer**: avoids re-mounting the consumer when
a new producer comes up later (a long-running forge can pick up its
newly-launched postgres sibling without restart), keeps the podman arg
list flat, means an empty enclave still mounts a valid (empty) directory.

**Why role-dir for the producer**: producer can ONLY see its own role's
files at `/var/log/tillandsias/external/`. It cannot reach into a sibling
producer's external dir even by accident. A compromised producer cannot
scribble on another producer's log.

**Rejected alternative — per-role mount on consumer**: would force
re-launch of every consumer when a new sibling producer comes up. Bad
ergonomics; no security gain (the auditor enforces role uniqueness at
producer-launch time anyway).

### Decision 4 (Q4) — Auto-include all enclave producers in every consumer

**Choice**: A consumer auto-mounts the parent `external-logs/` RO, which
means it sees every producer that's currently active. The consumer
profile's `external_logs_consumer: true` flag is binary — no per-role
allowlist.

**Why**: The user's principle is "the forge has access to the state of its
dependencies"; the dependencies are the enclave siblings. An opt-in
allowlist would force the project author to enumerate them twice (once in
compose / launch wiring, once in the consumer manifest). The auditor
already rejects role collisions at producer-launch time, so accidental
cross-project visibility is bounded by enclave membership.

**Rejected alternative — per-consumer allowlist**: doubles the config
surface. Doesn't add real isolation (every member of the enclave is by
definition trusted to read every other member's external log).

### Decision 5 (Q5) — Persist across container stop

**Choice**: External-log files persist across container stop. They are
cleaned ONLY by:

1. Per-file rotation: when a file exceeds `rotate_at_mb` (default 10 MB,
   manifest-overridable), the auditor truncates the oldest 50% of bytes in
   place. No `.1`, `.2` rotation files (keeps the layout flat for `tail -f`
   consumers).
2. Manual `tillandsias-logs prune <role>` from the **host** (NOT from
   inside any container — keeps the consumer-RO invariant intact).
3. Uninstall: the uninstaller prints the path and asks before deleting
   `~/.local/state/tillandsias/external-logs/`.

**Why persist**: the audit trail is the entire point. A `git-push.log`
that vanishes when the git-service container restarts loses the forensic
trail of "did this commit make it to GitHub". The 10 MB cap bounds disk;
the user's own pruning bounds time.

**Rejected alternative — clean on container stop**: lost audit outweighs
disk savings. Rotation already bounds growth.

### Decision 6 (Q6) — Auditor: 60 s polling tick, tray-side, blocking refusal

**Choice**: A tray-side task ticks every 60 s for each running producer.
On each tick:

1. `podman cp <container>:/etc/tillandsias/external-logs.yaml -` to read
   the manifest.
2. `ls ~/.local/state/tillandsias/external-logs/<role>/` to list on-disk
   files.
3. **Manifest-match check**: any on-disk file not in the manifest → emit
   `[external-logs] LEAK: <role> wrote <file> (not in manifest)` at WARN
   level with `accountability = true`, and turn the tray's external-logs
   chip yellow.
4. **Size cap**: any file > `rotate_at_mb` MB → truncate the oldest 50%
   of bytes. INFO-level accountability event.
5. **Growth-rate check**: per-file growth tracked across the last five
   ticks (5 minutes); > 1 MB/min sustained → WARN-level
   `[external-logs] WARN: <role> <file> growing <X> MB/min`.
6. **Reverse-breach check** (once at producer launch, not every tick):
   refuse to launch any profile that sets BOTH
   `external_logs_role: Some(_)` AND `external_logs_consumer: true`. This
   is a profile-construction bug, not a runtime condition.

**Why polling**: inotify across podman bind mounts is unreliable on podman
machine VMs (filesystem events don't always cross the gvproxy boundary);
polling is portable and the 60 s cadence is well below the noise floor.

**Why 60 s**: matches the existing tray-side health-check tick cadence.
The user-visible alarm (yellow chip) is acceptable to be up to 60 s late;
the rotation cap is sized so 60 s of unbounded growth (10 MB / min × 60 s
= 10 MB worst case) cannot exceed the rotation threshold from a clean
start.

### Decision 7 (Q7) — Operator UX: `tillandsias-logs combine` + accountability chip

**Choice**: An operator debugging a project does NOT need a unified "see
everything" command immediately — they have:

- `podman logs -f <container>` — internal stream, host-side, exactly as
  before.
- `tail -f ~/.local/state/tillandsias/external-logs/<role>/<file>` —
  external slice, host-side.
- `tillandsias-logs combine` (inside any consumer) — interleaves the
  consumer's own internal log + every external log in the enclave, sorted
  by mtime. Implementation: a thin shell script for v1 that `tail -f`s
  each file and prepends `[role/file]` to each line.
- Tray status chip — a new "External Logs" chip turns yellow on manifest
  leak / growth-rate alarm; clicking it opens the offending log in the
  host's default text viewer.

**Why this split**: the host-side stream + the in-container CLI cover the
two distinct mental models (operator with full access vs. agent inside the
enclave). Forcing a single unified command would require either privileged
access from the agent or surfacing the host's `podman logs` output back
into the enclave — both increase attack surface for marginal UX gain.

### Decision 8 (Q8) — Content type: text or JSON-lines only

**Choice**: External-log files are either plain text (`format: text`) or
newline-delimited JSON (`format: jsonl`). No binary structured formats.

**Why text/jsonl only**: external logs are a HUMAN/agent-readable
contract. Binary formats (postcard, Cap'n Proto, protobuf) would require
shipping a deserialiser into every consumer image and coupling the
consumer to the producer's schema crate. Plain text and JSON-lines are
universally `grep`-friendly, `jq`-friendly, and free of dependency drift.

**Why ban plain JSON (single document)**: not stream-parseable. A
half-written JSON document is invalid; a half-written JSON-lines file just
has a trailing partial line that downstream readers can discard.

**Note**: this is a deliberate departure from the project's on-the-wire
postcard convention (per `feedback_design_philosophy`). External logs are
not on-the-wire data; they are a published read-only contract. The two
domains have different optimisation targets.

## Risks / Trade-offs

- **Producer can write outside the manifest before the auditor catches it**
  (up to 60 s gap). Acceptable: the alarm fires within one tick; the file
  is left in place for forensic value; the producer's next-image build is
  expected to either remove the write or extend the manifest.
- **Auto-include means a forge sees an unrelated sibling's external log
  if the user accidentally runs both in the same enclave**. Mitigated by
  the role uniqueness check (two `git-service` producers in one enclave:
  launcher refuses the second). Cross-project leak is bounded by enclave
  membership, which the user controls.
- **Disk growth from never-cleaned external dirs**. Bounded per-file by
  rotation; user-controlled across files via `tillandsias-logs prune`.
  Documented in the spec under "Retention".
- **`web-<project>` role naming relies on project name uniqueness**. A
  user with two projects named identically would collide. The enclave
  already disambiguates by project path, but the role name doesn't.
  Documented as a known limitation; v2 may switch to a hash-derived suffix.
- **Manifest read via `podman cp` per tick** is a podman fork per 60 s per
  producer. With ≤6 producers per host the cost is negligible (< 0.1%
  CPU). If the count grows, switch to a host-bind-mount of the manifest
  file (rejected for v1 — extra mount for a 4 KB file is the wrong
  trade-off today).
- **No real-time push**: agents must `tail -f` to see new lines.
  Acceptable — `tail -f` is universal and works across the bind mount with
  no extra plumbing.
- **JSON-lines without a schema** means a consumer's `jq` invocation could
  break if the producer changes a field name. The manifest's `purpose`
  field is the human-language schema; producers SHOULD bump a `version`
  field inside the JSON and document the change in the producer's release
  notes. Out-of-band coordination, by design.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` —
  external-logs adds a fifth row to the persistent-paths table; category
  "External logs (curated)".
- `cheatsheets/runtime/external-logs.md` (NEW, this change) — agent-facing
  how-to with full Provenance.
- `cheatsheets/runtime/forge-container.md` — runtime contract; references
  the new env var and CLI.
- `crates/tillandsias-core/src/container_profile.rs` — defines the
  `external_logs_role` and `external_logs_consumer` fields and the two
  new `MountSource` variants.
- `crates/tillandsias-core/src/config.rs` — `external_logs_dir()` and
  `external_logs_role_dir(role)` helpers, alongside the existing `log_dir`
  / `container_log_dir`.
- `src-tauri/src/launch.rs` — resolves the new MountSource variants to
  host paths; mirrors the existing `ContainerLogs` branch.
- `src-tauri/src/handlers.rs` — `ensure_external_logs_dir` (one-shot
  migration of `git-push.log`) and `external_logs_audit_tick` (60 s
  auditor task).
- `images/git/external-logs.yaml` (NEW) — canonical example.
- `images/default/lib-common.sh` — exports
  `TILLANDSIAS_EXTERNAL_LOGS=/var/log/tillandsias/external`.
- `openspec/specs/runtime-logging/spec.md` — extended with the
  EXTERNAL-tier Requirement family.
- `openspec/specs/podman-orchestration/spec.md` — extended with the two
  new profile fields and the reverse-breach refusal at launch.
- `openspec/changes/opencode-web-session-otp/design.md` — methodology
  precedent for "producer profile declares an opt-in capability; tray
  launcher resolves it" (the structural pattern this change follows for
  `external_logs_consumers`).
- `docs/strategy/forge-hot-cold-split-plan.md` — confirms external logs
  are COLD path (disk-backed; never tmpfs).
- `docs/strategy/external-logs-observability-plan.md` — strategy memo
  this design implements.
