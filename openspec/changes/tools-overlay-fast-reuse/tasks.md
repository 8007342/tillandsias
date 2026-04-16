# Tasks: tools-overlay-fast-reuse

## Implementation
- [ ] Add `OverlaySnapshot` struct and `OVERLAY_SNAPSHOT: OnceCell<RwLock<Option<OverlaySnapshot>>>` in `src-tauri/src/tools_overlay.rs`
- [ ] Add `cached_overlay_for(current_forge_tag) -> Option<PathBuf>` reader function (sub-millisecond fast path)
- [ ] Refactor `ensure_tools_overlay()` to call `cached_overlay_for` first; fall through to slow path only on miss
- [ ] Add `populate_overlay_snapshot()` that does the slow-path work and writes the cache
- [ ] Call `populate_overlay_snapshot()` from app startup (in `src-tauri/src/main.rs`, between tray creation and event-loop entry); log a single info line with the resolved path + forge_tag
- [ ] Update `spawn_background_update()` to invalidate the cache after a successful rebuild
- [ ] Update the launch path (`src-tauri/src/launch.rs:343`) to consume the cached path instead of calling `resolve_mount_source()` per launch when the cache is hit

## Trace
- [ ] Add `// @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse` to: snapshot type, reader fn, populate fn, startup call, background-task invalidate

## Instrumentation
- [ ] Add `Instant::now()` wrapper around the cache lookup; log elapsed_micros at `debug!` level (so we can verify <1ms in production logs)

## Tests
- [ ] Unit test: snapshot returns `Some(path)` when forge_tag matches, `None` when it differs
- [ ] Unit test: invalidating snapshot causes next read to return `None`
- [ ] Integration test (debug build): after `populate_overlay_snapshot()`, `cached_overlay_for(forge_tag)` returns the same path on a second call without touching disk

## Verify
- [ ] Manual: launch the tray, click "Attach Here" twice, observe second launch's debug log shows cache-hit microsecond-level overlay lookup
- [ ] Manual: trigger a forge image rebuild (bump build version), confirm overlay slow-path runs once and caches; subsequent launches are fast again

## Cheatsheet
- [ ] Update `docs/cheatsheets/forge-launch-critical-path.md` to document the snapshot cache behavior and invalidation rules

## Trace + commit
- [ ] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Atools-overlay-fast-reuse&type=code`
- [ ] `npx openspec validate tools-overlay-fast-reuse`
