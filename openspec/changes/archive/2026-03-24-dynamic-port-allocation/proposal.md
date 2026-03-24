## Why

Stale containers (from unclean terminal closures) hold port ranges. The current allocator only checks in-memory state, not actual podman containers, so new containers collide with ports held by orphans. The 100-port ranges (3000-3099, 3100-3199) are wasteful — most environments need only a handful of ports. Smaller ranges with real podman-backed conflict detection would let many more environments coexist.

## What Changes

- **Shrink port ranges from 100 to 20** — base range becomes 3000-3019, each new environment shifts by 20
- **Check actual podman containers for port conflicts** — query `podman ps --format` for port mappings, not just in-memory state
- **Clean stale containers before allocation** — detect and remove orphaned tillandsias containers whose ports conflict
- **Fix hardcoded 3100-3199 in handle_terminal** — use the allocator instead

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `podman-orchestration`: Port allocator queries live containers, smaller ranges, stale cleanup

## Impact

- **Modified files**: `crates/tillandsias-podman/src/launch.rs` (allocator), `src-tauri/src/handlers.rs` (use allocator for terminal, stale cleanup), `src-tauri/src/runner.rs` (smaller default range)
- **Default port range**: `3000-3019` (was `3000-3099`)
