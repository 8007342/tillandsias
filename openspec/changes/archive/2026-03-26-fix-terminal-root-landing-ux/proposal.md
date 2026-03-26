## Why

Root terminal welcome message shows "Project: unknown" and "Mount: /home/forge/src/unknown" because `TILLANDSIAS_PROJECT` env var is not passed to the root terminal container. The welcome script (`forge-welcome.sh`) defaults to "unknown" when the var is absent.

## What Changes

- Add `-e TILLANDSIAS_PROJECT='(all projects)'` to the root terminal podman run command in `handle_root_terminal()`

## Capabilities

### New Capabilities
### Modified Capabilities

## Impact

- **Modified file**: `src-tauri/src/handlers.rs` — one line added
