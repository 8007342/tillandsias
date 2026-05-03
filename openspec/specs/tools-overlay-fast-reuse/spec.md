<!-- @trace spec:tools-overlay-fast-reuse -->
# tools-overlay-fast-reuse Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-tools-overlay-fast-reuse/
annotation-count: 0
implementation-complete: false

## Purpose

Eliminate the 100–500 ms per-launch overhead from tools overlay checking by caching the overlay snapshot once at application startup. The overlay never changes between launches in the warm case (same forge image tag, same source files), so recomputing the answer every launch wastes I/O and CPU.

## Requirements

### Requirement: Process-Lifetime Overlay Snapshot Cache

An `OverlaySnapshot` MUST be computed once at application startup (or lazily on first call) and cached for the lifetime of the tray process.

#### Snapshot Contents

The `OverlaySnapshot` MUST contain:
- `current_path: PathBuf` — the resolved `~/.cache/tillandsias/tools-overlay/current` symlink target
- `forge_tag: String` — the forge image tag this overlay was built against
- `built_at: SystemTime` — for diagnostics
- `valid_for_tag: String` — the tag the snapshot is valid for; invalidate if `forge_image_tag()` differs

#### Scenario: Application startup with cold snapshot
- **WHEN** the tray application starts
- **THEN** the overlay snapshot is computed (either eagerly or lazily on first access)
- **THEN** the result is cached in a process-lifetime `OnceCell` or similar

#### Scenario: Forge image tag has not changed
- **WHEN** a user launches a forge container
- **WHEN** `forge_image_tag()` equals the snapshot's `valid_for_tag`
- **THEN** `ensure_tools_overlay()` returns immediately from the cached snapshot
- **THEN** no syscalls, no manifest JSON read, sub-millisecond latency

#### Scenario: Forge image tag has changed
- **WHEN** `forge_image_tag()` differs from the snapshot's `valid_for_tag`
- **THEN** the snapshot is invalidated
- **THEN** a new snapshot is computed and cached

### Requirement: Proxy Health Check No Longer in Critical Path

The `is_proxy_healthy()` synchronous `podman exec` call that was in the critical path of overlay use SHALL be removed from that path.

#### Scenario: Mount-only overlay use
- **WHEN** overlay is being mounted for use (not rebuilt)
- **THEN** `is_proxy_healthy()` is NOT called
- **THEN** if the proxy is unhealthy, the forge entrypoint discovers it and degrades gracefully at runtime

#### Scenario: Overlay rebuild path (unaffected)
- **WHEN** a new overlay is being built
- **THEN** `is_proxy_healthy()` is still called (its output drives proxy-cert mount logic)

### Requirement: Background Update Task Invalidates Cache

The background overlay update task SHALL invalidate the process-lifetime snapshot after a successful rebuild.

#### Scenario: Background rebuild completes
- **WHEN** `tools_overlay::spawn_background_update` rebuilds the overlay
- **WHEN** the rebuild succeeds
- **THEN** the snapshot cache is invalidated
- **THEN** the next launch picks up the new overlay version

### Requirement: Observability

A startup log line MUST be emitted when the snapshot is cached.

#### Log Content

The log event MUST include:
- `spec = "layered-tools-overlay, tools-overlay-fast-reuse"`
- `path = <snapshot.current_path>`
- `forge_tag = <snapshot.forge_tag>`
- Message: `"overlay snapshot cached"`

An instrumentation timer MUST be added around the snapshot lookup so warm-launch overlay overhead can be confirmed sub-millisecond after the change.

## Rationale

The overlay checking is performed on every launch and involves multiple I/O operations (exists() syscall, manifest.json read, JSON deserialization, version comparison). Since the overlay is stable across launches (same forge image tag, same source files), computing the answer once at app startup and caching it for the tray process lifetime eliminates redundant work and meets the <2 second warm-launch latency target.

## Sources of Truth

- `docs/cheatsheets/runtime/cache-architecture.md` — process-lifetime caching patterns
- `docs/cheatsheets/runtime/logging-levels.md` — instrumentation and observability
