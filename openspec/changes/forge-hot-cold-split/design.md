# Design — forge-hot-cold-split

## Context

The full design rationale + 8 hard-question resolutions + 6-chunk
implementation plan + per-mount budget tables + failure-mode catalogue
live in **`docs/strategy/forge-hot-cold-split-plan.md`** (Opus, 2026-04-26).
That document is the canonical reference for this change. This file is
the OpenSpec-format design summary.

## Goals / Non-Goals

**Goals**:
- Split the forge container's filesystem into HOT (tmpfs/RAM, finely
  curated) and COLD (disk-backed overlay).
- Agents see one unified tree — split is transparent (zero env-var
  changes; same paths).
- Per-mount RAM caps enforced at podman launch.
- Total per-forge RAM budget enforced via pre-flight `MemAvailable` check;
  fail fast with friendly tray message on insufficient host RAM.
- No swap escape (`--memory-swap=<same as --memory>`).
- HOT path is finely curated: cheatsheets + project source code only.
  "Maybe a hot path" = HARD NO.

**Non-Goals**:
- Spill-to-overlay when HOT runs out (defeats the principle).
- Per-process RAM accounting inside the forge.
- Cross-platform UX for podman-machine VMs (handled in a follow-up).
- Hybrid splits (e.g., cargo registry index on tmpfs, target/ on disk).

## Decisions

The eight hard design questions are resolved in
`docs/strategy/forge-hot-cold-split-plan.md` §"Resolution to the eight
hard design questions". Summary:

1. **Mount strategy** = podman `--tmpfs <path>:size=<N>m,mode=...`
   (kernel-enforced, portable across podman-machine VMs).
2. **Canonical HOT list** = `/opt/cheatsheets/` (8 MB cap) +
   `/home/forge/src/<project>/` (per-launch dynamic, 256-4096 MB
   clamped). Image-baked entrypoint helpers + MCP scripts STAY in image
   lower layers (read-once-per-container-start; kernel page cache
   suffices).
3. **COLD** = per-project caches (`target/`, `node_modules/`, `.gradle`,
   `.m2`, registry caches), `/nix/store` (RO), logs, container
   overlayfs upper-dir for everything else.
4. **Project-source overflow** = hard cap → fail to launch with friendly
   message. Pre-flight: `MemAvailable < required * 1.25` → refuse.
5. **Cheatsheets baked vs tmpfs** = COPY at entrypoint from
   `/opt/cheatsheets-image/` (image lower layer, RO) → `/opt/cheatsheets/`
   (tmpfs). Image-baked alone is NOT RAM-equivalent (page cache evicts).
6. **Persistence across forge restarts** = source restoration via
   re-clone from git mirror. "Uncommitted work is lost on stop" becomes
   literally true at byte level.
7. **Memory budget** = per-mount caps `/opt/cheatsheets` 8 MB,
   `/home/forge/src` 256-4096 MB dynamic, `/tmp` 256 MB,
   `/run/user/1000` 64 MB. Floor ~1.4 GB committed at peak; ~600 MB
   resident at idle (tmpfs is sparse).
8. **Agent transparency** = zero env-var change. `/home/forge/src/<project>/`
   and `/opt/cheatsheets/` stay byte-identical paths; only backing-store
   identity changes. Internal env `TILLANDSIAS_HOT_PATH_MB` for the
   entrypoint preflight only.

## Six-chunk implementation plan

Per the strategy memo §"Chunked implementation plan". Independently
committable:

1. **Sized tmpfs profile model** — replace `Vec<&'static str>` with
   `Vec<TmpfsMount>`; emit `--tmpfs=<path>:size=<N>m`. Add `--memory` +
   `--memory-swap` pairing when any tmpfs present. Drop the
   `if profile.read_only` gate.
2. **Cheatsheets onto a hot mount** — rename image COPY to
   `/opt/cheatsheets-image/` (RO lower layer). New `populate_hot_paths()`
   in `lib-common.sh`. Forge + maintenance profiles add 8 MB tmpfs at
   `/opt/cheatsheets`.
3. **Pre-flight RAM measurement + per-launch project-source budget** —
   new `preflight.rs::check_host_ram`. `compute_hot_budget` reads bare
   git mirror's `count-objects -v -H | grep size-pack` × 4 inflation,
   clamps `[256, 4096]`. `--tmpfs=/home/forge/src:size=<budget>m`.
   New capability spec: `forge-hot-cold-split`.
4. **Cap `/tmp` and formalise `/run/user/1000`** — explicit 256 MB / 64 MB
   tmpfs caps. Bounds the worst case for an agent's accidental
   `dd if=/dev/urandom of=/tmp/x`.
5. **Welcome banner + path-taxonomy cheatsheet** — `forge-welcome.sh`
   gains `RAM` line. `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`
   adds fifth column. New `cheatsheets/runtime/forge-hot-cold-split.md`.
6. **Tray pre-flight surface + observability** — wraps every forge
   `start_*` site with the preflight check. Tray notification on refusal.
   Structured `accountability` log with `host_mem_available_mb`,
   `budget_mb`, `decision`. Config keys `forge.hot_path_max_mb` (4096),
   `forge.hot_path_inflation` (4).

## Risks / Trade-offs

- **Per-launch RAM cost**: ~1.4 GB committed at peak per forge. On 8 GB
  hosts the tray's pre-flight check refuses to launch a forge that would
  breach `MemAvailable * 1.25` with a friendly message. Acceptable.
- **No swap escape**: `--memory-swap=<same as --memory>` disables swap
  for the container. Honest RAM accounting; no silent thrash.
- **Project source loss on restart**: source restored by re-clone from
  the git mirror. Acceptable; "uncommitted work is lost on stop" was
  already documented.
- **Hard cap on overflow**: refuses to launch when project source >
  budget. Acceptable; the user's `forge.hot_path_max_mb` config can
  raise the ceiling, and the friendly message tells them how.
- **macOS / Windows VM cost**: works on podman machine; the host RAM
  cost is borne via the VM's allocation. Cross-platform UX deferred.

## Sources of Truth

- `docs/strategy/forge-hot-cold-split-plan.md` — full design memo.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — current
  four-category persistence model; this change adds backing-store axis.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — single-entry-point
  for shared cache; HOT path coexists on a separate axis.
- `crates/tillandsias-core/src/container_profile.rs` — profile shape
  modified by chunk 1.
- `src-tauri/src/launch.rs` — emission logic modified by chunk 1.
- `src-tauri/src/preflight.rs` (NEW, chunk 3) — `check_host_ram`.
- `images/default/Containerfile` — COPY target rename (chunk 2).
- `images/default/lib-common.sh` — `populate_hot_paths()` (chunk 2).
- `openspec/specs/default-image/spec.md` — modified.
- `openspec/specs/forge-cache-dual/spec.md` — modified.
- `openspec/specs/agent-cheatsheets/spec.md` — modified.
- `openspec/specs/podman-orchestration/spec.md` — modified.
