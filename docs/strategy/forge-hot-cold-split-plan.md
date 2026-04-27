# Forge hot/cold filesystem split — implementation plan

@trace spec:forge-hot-cold-split (NEW capability — to be created)

**Status**: Planned (Opus design 2026-04-26). Implementation deferred until queued items
clear; not yet wrapped in an OpenSpec change.

## Principle (user's words, verbatim)

- HOT PATH = RAM-only tmpfs. EXTREMELY EXPENSIVE resource, EXTREMELY FINELY CURATED.
- "Maybe a hot path" = HARD NO. Default decision is COLD.
- HOT MUST include: ALL agent-readable knowledge — every cheatsheet, every methodology
  doc, OpenSpec settings, MCP definitions, MCP scripts, AND the project source code that
  the agent reads/re-reads multiple times per prompt.
- COLD MUST include: build artefacts, binary outputs, executable downloads, any "write
  once, read once" file. Anything that is NOT going to be read multiple times by agents.

## Pre-flight findings (what the repo already has)

1. Tmpfs plumbing already exists in `src-tauri/src/launch.rs:71-76` — but `tmpfs_mounts:
   Vec<&'static str>` is bare paths with no size cap (default = 50% of host RAM per
   `tmpfs(5)`), and only the read-only service profiles emit them. Forge profiles set
   `tmpfs_mounts: vec![]` because `read_only: false`.
2. Forge containers have a writable root layer = overlayfs on the host's storage driver
   (`~/.local/share/containers/storage/`, on disk). So `/opt/cheatsheets/`, baked at
   build time, is **disk-backed via overlayfs upper-dir**, not RAM.
3. Project source already comes from a git clone (not a host bind-mount) per
   `entrypoint-forge-*.sh`: `CLONE_DIR="/home/forge/src/${TILLANDSIAS_PROJECT}"`.
   Tombstoned `MountSource::ProjectDir` for forge profiles. Putting the clone target on
   tmpfs is purely an entrypoint change — no host bind-mount conflict.
4. No existing `--memory` cap on forge containers. Host RAM is the only ceiling.
5. `tmpfs_mounts` must become `Vec<TmpfsMount { path, size_mb, mode }>` (additive
   struct change). The `if profile.read_only` gate must drop: tmpfs mounts get emitted
   regardless of root-FS mode.

## Six-chunk plan

### Chunk 1 — sized tmpfs support in the profile model
- `crates/tillandsias-core/src/container_profile.rs`: replace `Vec<&'static str>` with
  `Vec<TmpfsMount>`. Update all 7 profile constructors. Existing `web` and `git_service`
  mounts gain `size_mb: 64`.
- `src-tauri/src/launch.rs`: drop the `if profile.read_only` gate. Emit
  `--tmpfs=<path>:size=<N>m,mode=<oct>` for every entry. Add `--memory=<floor+budget>m`
  and `--memory-swap=<same>` when `tmpfs_mounts` is non-empty.
- Spec: additive requirement in `podman-orchestration` saying tmpfs MAY carry a size
  cap and SHALL emit `size=<N>m`.

### Chunk 2 — cheatsheets onto a hot mount via image-baked staging
- `images/default/Containerfile`: rename COPY target `/opt/cheatsheets` →
  `/opt/cheatsheets-image` (RO image lower layer).
- `images/default/lib-common.sh`: add idempotent `populate_hot_paths()` that does
  `cp -a /opt/cheatsheets-image/. /opt/cheatsheets/ 2>/dev/null || true`. Call at top
  of every forge entrypoint AFTER tmpfs mount, BEFORE agent-visible work.
- Profile change: forge + maintenance profiles add `TmpfsMount { path:
  "/opt/cheatsheets", size_mb: 8, mode: 0o755 }`.
- `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` unchanged (transparency).
- Spec: amend `agent-cheatsheets`: scenario that `/opt/cheatsheets/` SHALL be tmpfs at
  runtime; image-baked canonical at `/opt/cheatsheets-image/`.
- Cost: +8MB committed cap; ~636KB actually populated; ~100ms entrypoint overhead.

### Chunk 3 — pre-flight RAM measurement + per-launch project-source budget
- `src-tauri/src/launch.rs`: extend `LaunchContext` with `hot_path_budget_mb: u32`. New
  helper `compute_hot_budget(project_name, cache_dir)` that runs `git -C <mirror>
  count-objects -v -H | grep size-pack`, multiplies by 4 (configurable
  `forge.hot_path_inflation`), clamps to `[256, 4096]`. Call from every forge
  `LaunchContext` site (handlers.rs:277, 884, 2009, 3334, 3698, 4537, 4818;
  runner.rs:555).
- `build_podman_args()`: when profile is forge-shaped, append
  `--tmpfs=/home/forge/src:size=<budget>m,mode=0755`.
- New `src-tauri/src/preflight.rs`: `check_host_ram(required_mb) -> Result<(),
  PreflightError>` reads `/proc/meminfo` (Linux) / `host_statistics64` (macOS) /
  `GlobalMemoryStatusEx` (Windows). Returns `Err` if `MemAvailable < required * 1.25`.
- Tray notification on rejection: `"Project source on RAM: required <X>MB exceeds the
  configured limit (<Y>MB). Either commit & prune unreachable refs in the mirror, or
  raise forge.hot_path_max_mb in ~/.config/tillandsias/config.toml."`
- Hard cap on overflow → fail to launch (no spill-to-overlay).
- Spec: NEW capability `forge-hot-cold-split`. Requirements: pre-flight RAM check,
  per-launch budget, rejection behavior, per-mount caps, canonical hot list.
- Cost: per-launch typical 1GB; floor ~1.4GB committed at peak.

### Chunk 4 — cap `/tmp` and formalise `/run/user/1000`
- Forge profiles add `TmpfsMount { path: "/tmp", size_mb: 256, mode: 0o1777 }` and
  `TmpfsMount { path: "/run/user/1000", size_mb: 64, mode: 0o0700 }`.
- Spec: amend `forge-cache-dual` "Ephemeral" row with the cap.
- Cost: +320MB committed (already de facto allocated; net change is bounding worst case).

### Chunk 5 — welcome banner + path-taxonomy cheatsheet
- `images/default/forge-welcome.sh`: add `RAM` line listing tmpfs paths + caps (read at
  runtime from `findmnt -t tmpfs`).
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`: add fifth column
  ("Backing store: RAM | Disk | Image"). New section "Hot vs Cold".
- New `cheatsheets/runtime/forge-hot-cold-split.md` (≤200 lines, with Provenance).

### Chunk 6 — tray pre-flight surface + observability
- `src-tauri/src/handlers.rs`: every `start_forge` / `handle_attach_web` /
  `handle_maintenance_terminal` site wraps the `build_podman_args` call with the
  preflight check. On `Err`, emit tray notification + return Err.
- Structured log on every attempt: `accountability = true, category = "forge-launch",
  spec = "forge-hot-cold-split"` with `host_mem_available_mb`, `budget_mb`, `decision`.
- `crates/tillandsias-core/src/config.rs`: add `forge.hot_path_max_mb` (default 4096),
  `forge.hot_path_inflation` (default 4).

## Hard design questions — resolved

1. **Mount strategy**: podman `--tmpfs <path>:size=<N>m,mode=...` (kernel-enforced cap;
   `df` inside container shows real size). Rejected ramfs (no quota) + host bind-mount
   tmpfs (couples lifetime). On macOS/Windows podman machine, `--tmpfs` is honored
   inside the Linux VM.
2. **Canonical HOT list**: `/opt/cheatsheets/` + `/home/forge/src/<project>/`. Scope
   the hot mount NARROWLY: entrypoint helpers + MCP scripts stay in image lower layers
   (read once per container start, not per prompt — kernel page cache covers them).
3. **COLD**: per-project caches (`target/`, `node_modules/`, `.gradle`, `.m2`,
   registries), `/nix/store` (RO), logs, container overlayfs upper-dir for everything
   else. Cargo registry index NOT split (gain marginal vs added complexity).
4. **Project-source overflow**: hard cap → fail to launch with friendly message. No
   spill-to-overlay (defeats the principle). Pre-flight reads `MemAvailable`; refuse
   if `< budget × 1.25`.
5. **Cheatsheets baked vs tmpfs**: image-baked is NOT RAM-equivalent (page cache can
   evict). COPY at entrypoint from `/opt/cheatsheets-image/` → `/opt/cheatsheets/`
   (tmpfs).
6. **Persistence across restarts**: source restoration = re-clone from git mirror.
   "Uncommitted work is lost on stop" becomes literally true at the byte level.
7. **Memory budget**: per-mount caps:
   - `/opt/cheatsheets`: 8MB (~13× current)
   - `/home/forge/src`: per-launch dynamic, default 1024MB, max 4096MB
   - `/tmp`: 256MB
   - `/run/user/1000`: 64MB
   - Floor: ~1.4GB committed at peak; ~600MB resident at idle (tmpfs is sparse).
   - `--memory-swap=0` (no swap escape from the RAM-only guarantee).
8. **Agent transparency**: zero env-var change. `/home/forge/src/<project>/` and
   `/opt/cheatsheets/` stay byte-identical paths; only the backing-store identity
   changes. New internal env `TILLANDSIAS_HOT_PATH_MB=<budget>` for the entrypoint
   pre-flight (agents have no reason to read it).

## Open questions (flagged, not decided)

- **Maintenance container**: yes, same hot mounts (already covered in chunk 2/3).
- **Service containers** (router/proxy/git/inference): NO. They don't read source.
- **macOS / Windows**: works as-is on podman machine (Linux VM honors `--tmpfs`). Host
  RAM cost via VM allocation. Defer cross-platform UX (e.g., "raise podman-machine VM
  RAM") to a follow-up.

## Critical files for implementation

- `crates/tillandsias-core/src/container_profile.rs`
- `src-tauri/src/launch.rs`
- `images/default/Containerfile`
- `images/default/lib-common.sh`
- `src-tauri/src/handlers.rs`
- (NEW) `src-tauri/src/preflight.rs`
- (NEW) `cheatsheets/runtime/forge-hot-cold-split.md`
- (NEW) `openspec/changes/forge-hot-cold-split/{proposal,design,tasks}.md` + spec delta
