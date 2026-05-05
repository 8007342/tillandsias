<!-- @trace spec:overlay-mount-cache -->
# overlay-mount-cache Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-16-overlay-mount-cache/
annotation-count: 0
implementation-complete: false

## Purpose

Optimize launch-time mount path resolution by consulting the process-lifetime tools overlay snapshot before falling back to filesystem `exists()` checks. Removes the per-launch I/O overhead from container argument construction.

## Requirements

### Requirement: Fast-Path Snapshot Lookup in Mount Resolution

The mount source resolution for `MountSource::ToolsOverlay` MUST consult the cached overlay snapshot before performing an `exists()` syscall. @trace spec:overlay-mount-cache

#### Scenario: Normal launch with valid snapshot
- **WHEN** `resolve_mount_source()` is called with `MountSource::ToolsOverlay` during a launch
- **THEN** the function MUST query `crate::tools_overlay::cached_overlay_for(&forge_image_tag())` first
- **THEN** if the snapshot is valid and current, mount path resolution MUST return immediately without `exists()` call

#### Scenario: Snapshot invalidated by background rebuild
- **WHEN** a background overlay rebuild invalidates the process-lifetime snapshot mid-launch
- **THEN** the fast-path lookup MUST return `None`
- **THEN** the fallback `exists()` check SHOULD run (rare, acceptable slow path)

### Requirement: Integrated with Process-Lifetime Snapshot

The overlay mount cache MUST operate in tandem with the snapshot cache introduced in `tools-overlay-fast-reuse`.

#### Scenario: Snapshot guaranteed warm at mount resolution time
- **WHEN** `handle_attach_here` awaits `ensure_tools_overlay` (which populates the snapshot)
- **THEN** `build_podman_args` MUST be called
- **THEN** `resolve_mount_source` MUST be guaranteed to find a valid snapshot in `cached_overlay_for`

## Rationale

The snapshot cache from `tools-overlay-fast-reuse` is guaranteed to be hot at mount-resolution time because `ensure_tools_overlay` is awaited before `build_podman_args` is called. This allows the mount-path resolution to skip the unconditional `exists()` syscall on every launch. The fallback to `exists()` on snapshot miss handles the rare case of a background rebuild invalidating the cache mid-launch, making the slow path acceptable and invisible to the user.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Process-lifetime snapshot populated by `ensure_tools_overlay` before `build_podman_args`
- Mount resolution queries snapshot first (fast path, no I/O)
- If snapshot valid and current, mount path returned immediately
- If snapshot invalidated by background rebuild, fallback to `exists()` syscall (slow path)
- Fast path eliminates per-launch `exists()` syscall overhead
- Snapshot cache hit rate > 95% under normal operation

## Sources of Truth

- `cheatsheets/runtime/cache-architecture.md` — process-lifetime snapshot patterns
- `cheatsheets/build/podman-launch.md` — container argument construction and mount paths
