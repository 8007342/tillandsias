<!-- @trace spec:overlay-mount-cache -->
# overlay-mount-cache Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-overlay-mount-cache/
annotation-count: 0
implementation-complete: false

## Purpose

Optimize launch-time mount path resolution by consulting the process-lifetime tools overlay snapshot before falling back to filesystem `exists()` checks. Removes the per-launch I/O overhead from container argument construction.

## Requirements

### Requirement: Fast-Path Snapshot Lookup in Mount Resolution

The mount source resolution for `MountSource::ToolsOverlay` SHALL consult the cached overlay snapshot before performing an `exists()` syscall.

#### Scenario: Normal launch with valid snapshot
- **WHEN** `resolve_mount_source()` is called with `MountSource::ToolsOverlay` during a launch
- **THEN** the function queries `crate::tools_overlay::cached_overlay_for(&forge_image_tag())` first
- **THEN** if the snapshot is valid and current, mount path resolution returns immediately without `exists()` call

#### Scenario: Snapshot invalidated by background rebuild
- **WHEN** a background overlay rebuild invalidates the process-lifetime snapshot mid-launch
- **THEN** the fast-path lookup returns `None`
- **THEN** the fallback `exists()` check runs (rare, acceptable slow path)

### Requirement: Integrated with Process-Lifetime Snapshot

The overlay mount cache SHALL operate in tandem with the snapshot cache introduced in `tools-overlay-fast-reuse`.

#### Scenario: Snapshot guaranteed warm at mount resolution time
- **WHEN** `handle_attach_here` awaits `ensure_tools_overlay` (which populates the snapshot)
- **THEN** `build_podman_args` is called
- **THEN** `resolve_mount_source` is guaranteed to find a valid snapshot in `cached_overlay_for`

## Rationale

The snapshot cache from `tools-overlay-fast-reuse` is guaranteed to be hot at mount-resolution time because `ensure_tools_overlay` is awaited before `build_podman_args` is called. This allows the mount-path resolution to skip the unconditional `exists()` syscall on every launch. The fallback to `exists()` on snapshot miss handles the rare case of a background rebuild invalidating the cache mid-launch, making the slow path acceptable and invisible to the user.

## Sources of Truth

- `docs/cheatsheets/runtime/cache-architecture.md` — process-lifetime snapshot patterns
- `docs/cheatsheets/build/podman-launch.md` — container argument construction and mount paths
