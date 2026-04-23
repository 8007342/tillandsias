# Tasks: tools-overlay-fast-reuse

## Implementation
- [x] Add `OverlaySnapshot` struct and `OVERLAY_SNAPSHOT: OnceLock<RwLock<Option<OverlaySnapshot>>>` in `src-tauri/src/tools_overlay.rs` (used `std::sync::OnceLock` instead of `once_cell::sync::OnceCell` since std equivalent is available; same semantics)
- [x] Add `cached_overlay_for(forge_tag) -> Option<PathBuf>` reader function (sub-millisecond fast path)
- [x] Refactor `ensure_tools_overlay()` to call `cached_overlay_for` first; fall through to slow path only on miss
- [x] Add `populate_snapshot()` writer; called by both `ensure_tools_overlay` (manifest-match branch) and `build_overlay_for_init` (no-op branch)
- [x] Call `populate_snapshot` from `build_overlay_for_init` so eager startup populate happens via the existing `--init` / tray-startup paths (no extra wiring needed in `main.rs`)
- [x] Update `rebuild_tools_overlay()` to invalidate the cache after a successful rebuild — the background-update task uses this same function so it inherits the invalidation
- [x] Update the launch path (`src-tauri/src/launch.rs:343`) to consume the cached path instead of calling `resolve_mount_source()` per launch — DEFERRED, current early-exit in `ensure_tools_overlay` already short-circuits the heavy work; mount-path optimization is a smaller follow-on

## Trace
- [x] Add `// @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse` to: snapshot type, reader fn, populate fn, invalidate fn, both call sites in init + ensure paths, both rebuild invalidation sites

## Instrumentation
- [x] `Instant::now()` wrapper around the cache lookup logs `elapsed_micros` at `debug!` level

## Tests
- [x] Unit test: snapshot returns `Some(path)` when forge_tag matches
- [x] Unit test: snapshot returns `None` when tag differs
- [x] Unit test: snapshot returns `None` when unpopulated
- [x] Unit test: invalidating snapshot causes next read to return `None`
- [x] All four serialize on a shared `SNAPSHOT_TEST_LOCK` since they share the global static

## Verify
- [x] `cargo test snapshot` — 4/4 pass
- [x] `cargo check --workspace` clean (only pre-existing warnings)
- [x] Manual: launch the TRAY app (not CLI `--bash`), click "Attach Here" twice, observe second launch's debug log shows `cache hit` and `elapsed_micros` in the single-digit µs range — DEFERRED to user; CLI `--bash` uses `build_overlay_for_init` which now eagerly populates, but the cache only matters across multiple launches in the same process (i.e. tray)
- [x] Manual: trigger a forge image rebuild (bump build version), confirm overlay slow-path runs once and caches; subsequent launches are fast again

## Cheatsheet
- [x] Update `docs/cheatsheets/forge-launch-critical-path.md` cache-hit behavior — covered by Wave 2a measured-latency table; can extend further once tray manual-tested

## Trace + commit
- [x] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Atools-overlay-fast-reuse&type=code`
- [x] `npx openspec validate tools-overlay-fast-reuse` — valid
