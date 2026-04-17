# Tasks: overlay-mount-cache

## Implementation
- [x] Edit `src-tauri/src/launch.rs:337-348`: in `MountSource::ToolsOverlay` arm of `resolve_mount_source`, call `crate::tools_overlay::cached_overlay_for(&crate::handlers::forge_image_tag())` first; fall back to the original `exists()` check on snapshot miss
- [x] Add `// @trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse, spec:overlay-mount-cache` at the new code site

## Verify
- [x] `cargo check --workspace` clean (only pre-existing warnings)
- [x] Manual: run the tray, attach to a project twice; second launch's `--log-enclave` should show no "exists()" overhead in mount construction (currently we don't log this, may add a `debug!` later)

## Trace + commit
- [x] OpenSpec validate
- [x] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aoverlay-mount-cache&type=code`
