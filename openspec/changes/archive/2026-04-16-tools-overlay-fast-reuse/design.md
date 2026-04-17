# Design: tools-overlay-fast-reuse

## Cache shape

```rust
// @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse
struct OverlaySnapshot {
    current_path: PathBuf,    // resolved symlink target, e.g. ~/.cache/tillandsias/tools-overlay/v3
    forge_tag: String,        // tag the overlay was built against
    built_at: SystemTime,
}

static OVERLAY_SNAPSHOT: OnceCell<RwLock<Option<OverlaySnapshot>>> = OnceCell::new();
```

`RwLock<Option<...>>` so the background update task can invalidate (`= None`) cheaply, and the read path takes only a read lock.

## Lookup logic

```rust
pub fn cached_overlay_for(current_forge_tag: &str) -> Option<PathBuf> {
    let cell = OVERLAY_SNAPSHOT.get()?;
    let guard = cell.read().ok()?;
    let snap = guard.as_ref()?;
    if snap.forge_tag == current_forge_tag {
        Some(snap.current_path.clone())
    } else {
        None  // stale — caller falls through to slow path
    }
}
```

Slow path: resolve symlink → read manifest → compare `forge_image` → if good, populate cache and return. If forge-tag mismatch, trigger a (background, blocking-build-protected) rebuild as today.

## When the cache populates

Two options, pick the one that doesn't surprise:

1. **Lazy** — first call to `ensure_tools_overlay()` populates. Pros: no startup-cost; cons: the first launch in a session pays the slow path.
2. **Eager at app init** — call `ensure_tools_overlay_snapshot()` from `main.rs` startup, between tray creation and event-loop entry. Pros: every launch is fast; cons: small extra startup cost (which is invisible to users since the tray is already idle).

Recommendation: eager. Startup is already milliseconds-level; baking the overlay check in keeps every "Attach Here" maximally fast.

## When the cache invalidates

- Forge image tag changes between snapshots (compared on every read).
- Background update task in `tools_overlay::spawn_background_update` rebuilds the overlay → it explicitly clears the cache (`*OVERLAY_SNAPSHOT.get().unwrap().write() = None`) so the next read recomputes.
- Manual cache reset (debug-only): a CLI flag `--reset-overlay-cache` could clear it. Out of scope for this change.

## Proxy health check decoupling

Today `build_tools_overlay_versioned()` calls `is_proxy_healthy()` and feeds the result into the build container env (`CA_CHAIN_PATH`). Reading the code (tools_overlay.rs:284), the call sits in the **build** path, not the **mount** path. The mount path (used at launch time) does not use proxy info — the overlay is read-only and the entrypoint sets up the proxy connection itself. So decoupling is clean: leave `is_proxy_healthy()` exactly where it is; the snapshot path simply doesn't touch it.

If audit shows the mount path *does* call `is_proxy_healthy()` somewhere subtle, defer that check to the spawned background update task and document the shift in the cheatsheet.

## Background update interaction

`spawn_background_update()` runs every 24 h via a stamp file. After a successful rebuild it currently swaps the `current` symlink. With this change it must also `*OVERLAY_SNAPSHOT.get().unwrap().write().unwrap() = None;` so the next `ensure_tools_overlay()` call repopulates from the new symlink target.

## Out of scope

- Changing how the overlay is *built*. We only optimize the *reuse* path.
- Changing the on-disk layout of `~/.cache/tillandsias/tools-overlay/` (manifest format, symlink scheme, etc.).
- Async-loading the snapshot from a different thread. The lookup is already sub-millisecond once cached; the change is in startup populate logic.
