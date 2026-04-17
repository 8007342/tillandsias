# Delta: layered-tools-overlay (fast-reuse cache)

## ADDED Requirements

### Requirement: Tools overlay path is cached for the tray process lifetime

The system SHALL cache the resolved tools-overlay path and the forge image tag it was built against in a process-lifetime in-memory snapshot. Subsequent launches SHALL consult the snapshot first and SHALL NOT perform filesystem syscalls (`exists()`, symlink resolution), manifest JSON deserialization, or proxy health checks if the snapshot is valid for the current forge image tag.

@trace spec:layered-tools-overlay, spec:tools-overlay-fast-reuse

#### Scenario: Warm-launch overlay lookup hits the cache
- **WHEN** the tray process has previously populated the overlay snapshot
- **AND** the user clicks "Attach Here" while the snapshot's `forge_tag` matches the current `forge_image_tag()`
- **THEN** the launch path SHALL retrieve the overlay path from the cache without any filesystem syscall, manifest read, or proxy health check
- **AND** the lookup SHALL complete in under 1 ms

#### Scenario: Forge image upgrade invalidates the snapshot
- **WHEN** the forge image is rebuilt (e.g., via update flow) and the tag changes
- **AND** the user clicks "Attach Here"
- **THEN** the cached snapshot's `forge_tag` mismatches the current tag
- **AND** the system SHALL fall through to the slow path (manifest read + symlink resolve)
- **AND** SHALL repopulate the cache with the new snapshot once the overlay is verified

#### Scenario: Background update task refreshes the cache
- **WHEN** the background update task (`spawn_background_update`) successfully rebuilds the overlay to a new version
- **THEN** it SHALL invalidate the snapshot (`*OVERLAY_SNAPSHOT.write() = None`)
- **AND** the next launch SHALL repopulate the cache from the freshly-built overlay

#### Scenario: Tray startup pre-populates the cache
- **WHEN** the tray process starts
- **THEN** it SHALL eagerly populate the overlay snapshot before entering the event loop
- **AND** SHALL emit a single `info!` log line with `spec = "layered-tools-overlay, tools-overlay-fast-reuse"` and the resolved overlay path
- **AND** the first user-initiated "Attach Here" SHALL benefit from the cached snapshot
