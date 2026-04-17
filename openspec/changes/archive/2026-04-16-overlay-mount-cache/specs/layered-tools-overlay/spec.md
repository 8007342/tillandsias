# Delta: layered-tools-overlay (mount-path consults snapshot)

## ADDED Requirements

### Requirement: Mount-path resolution consults the process-lifetime snapshot

The system SHALL consult the process-lifetime overlay snapshot in `MountSource::ToolsOverlay` mount-path resolution. When the snapshot is populated and the forge image tag matches, the launch path SHALL skip the `exists()` syscall entirely. When the snapshot is missed (cleared / not yet populated / forge tag mismatch), the launch path SHALL fall back to the original `exists()` check so behavior remains correct on the cold path.

@trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse, spec:overlay-mount-cache

#### Scenario: Warm-launch mount construction hits the snapshot
- **WHEN** `ensure_tools_overlay` has populated the snapshot for the current forge tag
- **AND** `handle_attach_here` calls `build_podman_args` which calls `resolve_mount_source(MountSource::ToolsOverlay, ctx)`
- **THEN** `resolve_mount_source` SHALL return the snapshot's `current_path` without invoking `exists()`

#### Scenario: Snapshot miss falls back to exists()
- **WHEN** the snapshot is cleared (e.g., a background rebuild invalidated it mid-launch)
- **AND** the launch path resolves a `MountSource::ToolsOverlay` mount
- **THEN** `resolve_mount_source` SHALL fall back to the original `ctx.cache_dir/tools-overlay/current` path with an `exists()` check
- **AND** SHALL return `None` (skipping the mount) only if the path does not exist on disk
