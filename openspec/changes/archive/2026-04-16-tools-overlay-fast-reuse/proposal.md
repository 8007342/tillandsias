# Change: tools-overlay-fast-reuse

## Why

Once the tools overlay is built (~234 MB containing claude/opencode/openspec), every "Attach Here" still pays a non-trivial overhead to *check* it before mounting:

1. `overlay_path.exists()` syscall (`launch.rs:343`) on every container
2. `manifest.json` read + JSON deserialization on every check (`tools_overlay.rs:187-189`)
3. `manifest.forge_image == current_tag` string comparison
4. Synchronous `is_proxy_healthy()` `podman exec` call before any mount path resolves (`tools_overlay.rs:284`)
5. No app-startup-time cache; every launch redoes the work

Each item is small in isolation — together they add 100–500 ms to a launch that already does a lot of work, and they sit directly in the latency budget for the <2 s warm-launch target.

The overlay never changes between launches in the warm case (same forge image tag, same source files). We can compute the answer once at app startup and cache it for the lifetime of the tray process. Background updates already exist (24-hour rebuild check) and will refresh the cache when they run.

## What Changes

- Introduce a per-process cached `OverlaySnapshot` in `tools_overlay.rs`:
  - `current_path: PathBuf` — the resolved `~/.cache/tillandsias/tools-overlay/current` symlink target
  - `forge_tag: String` — the forge image tag this overlay was built against
  - `built_at: SystemTime` — for diagnostics
  - `valid_for_tag: String` — tag the snapshot is valid for; if `forge_image_tag()` differs, invalidate
- Compute the snapshot once at app init (or lazily on first call) behind an `OnceCell`/`tokio::sync::OnceCell`.
- `ensure_tools_overlay()` returns immediately if the snapshot is valid for the current forge tag — no syscalls, no manifest JSON read.
- `is_proxy_healthy()` is removed from the critical path of overlay use. It is still called before *building* a new overlay (where its output drives the proxy-cert mount logic). Mount-only paths skip the health check; if the proxy is unhealthy, the entrypoint inside the forge container will discover it and degrade gracefully — exactly the same as today.
- The launch path uses the cached snapshot's `current_path` instead of calling `resolve_mount_source()` per launch.
- Background update task (`tools_overlay::spawn_background_update`) invalidates the cache after a successful rebuild so the next launch picks up the new overlay version.
- Add a single startup log line: `info!(spec = "layered-tools-overlay, tools-overlay-fast-reuse", path = %snapshot.current_path.display(), forge_tag = %snapshot.forge_tag, "overlay snapshot cached")`.
- Add an instrumentation timer around the snapshot lookup so we can confirm warm-launch overlay-overhead is sub-millisecond after the change.

## Capabilities

### Modified Capabilities
- `layered-tools-overlay`: warm-launch reuse skips manifest re-read and proxy health check; uses a process-lifetime snapshot.

### New Capabilities
None — pure performance/architecture improvement.
