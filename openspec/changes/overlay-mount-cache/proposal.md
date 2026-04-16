# Change: overlay-mount-cache

## Why

`tools-overlay-fast-reuse` (shipped previous commit) added a process-lifetime snapshot cache for the overlay path lookup in `ensure_tools_overlay()`. The remaining per-launch work happens in `src-tauri/src/launch.rs:337-348` inside `resolve_mount_source()`, which still does an `exists()` syscall on every `MountSource::ToolsOverlay` mount construction. Every "Attach Here" goes through `build_podman_args` (the function that calls `resolve_mount_source`) so this fires once per launch.

The snapshot cache is guaranteed to be hot at this point: `handle_attach_here` awaits `ensure_tools_overlay` (which populates the snapshot) BEFORE calling `build_podman_args` (which reads from `resolve_mount_source`). So the mount-path resolution can consult the snapshot first and only fall back to `exists()` on snapshot miss (which only happens if a background rebuild invalidated the snapshot mid-launch — an acceptable rare-case slow path).

## What Changes

- In `src-tauri/src/launch.rs:337-348`, replace the unconditional `exists()` check inside the `MountSource::ToolsOverlay` arm with a fast-path lookup against `crate::tools_overlay::cached_overlay_for(&forge_image_tag())`. Fall back to the original `exists()` check on snapshot miss.
- Add `// @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse, spec:overlay-mount-cache` at the new code site.
- No new types, no new public API. The existing `cached_overlay_for` is already `pub(crate)` and reachable from `launch.rs`.

## Capabilities

### Modified Capabilities
- `layered-tools-overlay`: launch-time mount construction consults the process-lifetime snapshot before falling back to `exists()`.

### New Capabilities
None — incremental refinement of `tools-overlay-fast-reuse`.
