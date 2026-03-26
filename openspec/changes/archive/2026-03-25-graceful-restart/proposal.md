## Why

When the tray app crashes or is restarted, the user's development environments keep running inside their containers — but the tray menu shows nothing. Every project appears idle. The user must manually inspect state or wait for a podman event to trigger.

This is jarring: the flower icons disappear, the "Blooming" status is lost, and "Stop" actions are unavailable until podman emits an event. The app looks broken even though the containers are healthy.

## What Changes

- **On startup**, after confirming podman is available, query `podman ps` to discover containers with the `tillandsias-` prefix that are already running.
- **Parse each container name** to recover the project name and genus (the container name encodes both via the established `tillandsias-<project>-<genus>` convention).
- **Restore `state.running`** with `ContainerInfo` entries for each discovered running container, so the menu immediately shows the correct flower icons and lifecycle states.
- **Seed the `GenusAllocator`** from discovered containers so subsequent "Attach Here" actions assign non-conflicting genera.

## Capabilities

### Modified Capabilities
- `tray-app`: startup now queries existing containers and restores tray state before entering the event loop

## Impact

- **Modified files**: `src-tauri/src/main.rs` (filter to running-only, rebuild before menu), `src-tauri/src/event_loop.rs` (seed allocator from pre-populated state)
- **No new files**
- **No schema changes** — container names already encode all required state; no persistent storage needed
