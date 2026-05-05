## Why

Tillandsias's forge container today runs every read off the host's
overlayfs storage driver (`~/.local/share/containers/storage/`). That
includes paths the agent reads dozens of times per prompt — `/opt/cheatsheets/`,
`/home/forge/src/<project>/` — alongside paths the agent writes once and
reads at most once (build artefacts, downloaded archives, log noise). The
kernel page cache helps but is evictable under RSS pressure; a fresh
container or a host with active disk I/O takes a measurable cold-cache
hit on every cheatsheet lookup and every project source read.

The user's directive (verbatim):

> The running forge, which checks out the code on launch, should do so
> into a RAMDISK DRIVE, that is, for the lifetime of the forge, its
> source code shall live 100% in RAM. We should very clearly label and
> track these folders, make sure that they're only SOURCE and PROMPT
> files (we'll include ALL CHEATSHEETS, KNOWLEDGE, BEST PRACTICES,
> METHODOLOGY, OPENSPEC SETTINGS) entirely on RAM. Since this is an
> expensive resource we have to make sure that temporary ephemeral
> artifacts are written to filesystem backed overlay. ... HOT PATH
> files include the entirety of KNOWLEDGE and CHEATSHEETS, METHODOLOGY,
> FORGE, MCP DEFINITIONS and MCP SCRIPTS. Things that are "maybe a hot
> path" are a HARD NO on the hot path, this is an extremely expensive
> overlay and should be extremely finely curated, it's currently
> reserved for SOURCE CODE and KNOWLEDGE.

This change splits the forge container's filesystem into two backing
stores:

- **HOT PATH (tmpfs / RAM)** — extremely finely curated. Cheatsheets,
  the project's source-tree clone, the methodology / OpenSpec settings
  visible to the agent inside the project. Per-mount size caps; total
  RAM budget per forge enforced at launch with pre-flight `MemAvailable`
  check; no swap escape.
- **COLD PATH (disk-backed overlay)** — everything else. Build
  artefacts (`target/`, `node_modules/`, `.gradle`), package-manager
  caches (`~/.cache/cargo/registry/`), downloaded blobs, container
  upper-layer writes for non-curated paths.

Agents see one unified tree. The split is transparent. The principle is
"maybe a hot path = HARD NO" — every addition to HOT must be justified
against the RAM cost.

## What Changes

- **NEW** `TmpfsMount` struct in
  `crates/tillandsias-core/src/container_profile.rs` carrying `path`,
  `size_mb`, `mode`. Replaces today's `Vec<&'static str>` (untyped path
  list with no per-mount cap).
- **NEW** sized tmpfs emission in `src-tauri/src/launch.rs::build_podman_args`:
  `--tmpfs=<path>:size=<N>m,mode=<oct>` for every entry. Drops the existing
  `if profile.read_only` gate so tmpfs mounts emit regardless of root-FS
  mode. When a profile has any tmpfs mount, also adds `--memory=<N>m` and
  `--memory-swap=<same>` to prevent swap escape from the RAM-only
  guarantee.
- **NEW** `/opt/cheatsheets/` becomes tmpfs (8 MB cap; ~636 KB populated).
  Image's COPY target renames to `/opt/cheatsheets-image/` (RO image lower
  layer, baked at build time). Forge entrypoint's
  `populate_hot_paths()` runs `cp -a /opt/cheatsheets-image/. /opt/cheatsheets/`
  AFTER tmpfs is mounted. ENV `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets`
  unchanged (transparency).
- **NEW** `/home/forge/src/` becomes tmpfs sized per-launch from the host
  bare git mirror's pack size × 4 inflation factor, clamped to
  `[256, 4096]` MB (configurable via `forge.hot_path_max_mb` and
  `forge.hot_path_inflation`). The forge entrypoint's existing `git clone`
  destination is unchanged; the mount-shadow does the work.
- **NEW** `src-tauri/src/preflight.rs::check_host_ram(required_mb) ->
  Result<(), PreflightError>`. Reads `/proc/meminfo` (Linux) /
  `host_statistics64` (macOS, via existing `sysinfo` dep) /
  `GlobalMemoryStatusEx` (Windows). Returns `Err` if `MemAvailable <
  required * 1.25`. Called from every forge launch site BEFORE
  invoking podman.
- **NEW** Tray notification on launch refusal: "Project source on RAM:
  required <X>MB exceeds the configured limit (<Y>MB). Either commit &
  prune unreachable refs in the mirror, or raise forge.hot_path_max_mb in
  ~/.config/tillandsias/config.toml."
- **NEW** `/tmp` capped at 256 MB (today implicit-tmpfs uncapped; agent
  mistake `dd if=/dev/urandom of=/tmp/x` could OOM the host); `/run/user/1000`
  formalised at 64 MB.
- **NEW** Welcome banner adds a `RAM` line listing tmpfs paths + caps,
  read at runtime from `findmnt -t tmpfs`.
- **NEW** `cheatsheets/runtime/forge-hot-cold-split.md` — agent-facing
  documentation of the principle, canonical hot list, failure modes,
  verification commands.
- **MODIFIED** `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`
  — fifth column "Backing store: RAM | Disk | Image"; new "Hot vs Cold"
  section.
- **MODIFIED** `forge-cache-dual` capability spec: amend "Ephemeral" row
  with explicit caps for `/tmp` and `/run/user/1000`.
- **MODIFIED** `default-image` capability spec: tmpfs-backing for
  `/opt/cheatsheets/`; image-baked canonical at `/opt/cheatsheets-image/`.
- **MODIFIED** `agent-cheatsheets` capability spec: scenario that
  `/opt/cheatsheets/` SHALL be tmpfs at runtime; `tillandsias-inventory
  --json` can still introspect the image-version of the cheatsheets via
  the `-image/` path.
- **MODIFIED** `podman-orchestration` capability spec: tmpfs MAY carry a
  size cap; SHALL emit `size=<N>m`; SHALL pair with `--memory` ceiling
  when any tmpfs is present.

## Capabilities

### New Capabilities

- `forge-hot-cold-split`: the principle of HOT (tmpfs, finely curated,
  RAM-only) vs COLD (disk-backed); per-mount caps; total RAM budget
  enforcement; pre-flight `MemAvailable` check; rejection behavior on
  insufficient host RAM; canonical hot list.

### Modified Capabilities

- `forge-cache-dual`: explicit cap on `/tmp` (256 MB) and `/run/user/1000`
  (64 MB).
- `default-image`: `/opt/cheatsheets/` tmpfs-backed at runtime;
  `/opt/cheatsheets-image/` is the image-baked canonical lower-layer
  copy.
- `agent-cheatsheets`: `/opt/cheatsheets/` is the tmpfs view (RW for
  agent scratch edits within container lifetime); `/opt/cheatsheets-image/`
  is the immutable image-baked copy (RO via lower layer).
- `podman-orchestration`: profile tmpfs entries gain a typed
  `TmpfsMount { path, size_mb, mode }` shape; `--memory=<N>m
  --memory-swap=<same>` emitted whenever any tmpfs is present.

## Impact

- **Core** (`crates/tillandsias-core/src/container_profile.rs`): new
  `TmpfsMount` struct; all 7 profile constructors updated.
- **Launcher** (`src-tauri/src/launch.rs`): drops `if profile.read_only`
  gate; emits sized tmpfs flags; emits `--memory` ceiling.
- **Preflight** (`src-tauri/src/preflight.rs`, NEW): host-RAM measurement
  per platform.
- **Handlers** (`src-tauri/src/handlers.rs`): every forge `LaunchContext`
  call site computes the per-launch hot budget from the bare git mirror;
  preflight check before podman; tray notification on refusal.
- **Image** (`images/default/Containerfile`): rename COPY target from
  `/opt/cheatsheets` to `/opt/cheatsheets-image`. `images/default/lib-common.sh`
  adds `populate_hot_paths()` called from every entrypoint.
- **Welcome** (`images/default/forge-welcome.sh`): RAM-mounts annotation.
- **Config** (`crates/tillandsias-core/src/config.rs`): `forge.hot_path_max_mb`
  (default 4096), `forge.hot_path_inflation` (default 4).
- **Cheatsheets**: NEW `cheatsheets/runtime/forge-hot-cold-split.md`;
  amend `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`.
- **Tests**: profile tmpfs cap presence, --memory pairing, preflight
  refusal under low RAM, hot budget computation.
- **Performance**: ~100 ms entrypoint overhead (one-time `cp` of cheatsheets
  to tmpfs); per-prompt agent reads from RAM (no page-cache eviction
  hazard).
- **Resource budget**: ~1.4 GB committed RAM at peak per forge, ~600 MB
  resident at idle (tmpfs is sparse). On 8 GB hosts the tray's pre-flight
  check refuses to launch a forge that would breach `MemAvailable * 1.25`
  with a friendly message.

## Sources of Truth

- `docs/strategy/forge-hot-cold-split-plan.md` — Opus design memo this
  proposal materialises.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — current
  four-category persistence model; this change adds a fifth backing-store
  axis.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — single-entry-point
  principle for the shared cache; HOT path coexists with this on a
  separate axis.
- `cheatsheets/runtime/forge-container.md` — overall runtime contract
  this change updates with the new backing-store annotations.
- `openspec/specs/default-image/spec.md` — modified by this change.
- `openspec/specs/forge-cache-dual/spec.md` — modified by this change.
- `openspec/specs/agent-cheatsheets/spec.md` — modified by this change.
- `openspec/specs/podman-orchestration/spec.md` — modified by this change.
- `docs/strategy/external-logs-observability-plan.md` — sibling planning
  document; external-logs are explicitly COLD path (disk-backed; never
  tmpfs).

## Open Questions (resolve in design.md before /opsx:apply)

- **Cargo registry index** (~50 MB, read-often, write-rarely): hybrid
  (tmpfs for index, disk for `target/`)? Strawman: keep all of
  `~/.cache/tillandsias-project/` on disk for simplicity; revisit if
  traces show repeated sub-100 ms registry-read storms.
- **MCP scripts in `/usr/local/bin/`**: tiny + read-once-per-prompt;
  borderline. Strawman: leave in image lower layers (kernel page cache
  is enough for read-once paths).
- **macOS / Windows port**: works on podman machine because the Linux
  VM honors `--tmpfs`. The host RAM cost is borne via the VM's
  allocation. Defer cross-platform UX (e.g., "raise podman-machine VM
  RAM" notification) to a follow-up.
