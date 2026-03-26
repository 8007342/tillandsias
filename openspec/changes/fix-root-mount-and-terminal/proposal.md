## Why

The root-level "Attach Here" and root terminal (top of tray menu, scoped to the entire `~/src/` watch path) have two bugs:

1. **Double-nested mount**: The root "Attach Here" reuses `handle_attach_here()`, which mounts `project_path` at `/home/forge/src/<project_name>`. When the watch path IS `~/src/`, `project_name` resolves to `"src"`, producing `~/src/ -> /home/forge/src/src/` instead of `~/src/ -> /home/forge/src/`.

2. **Bare bash instead of fish**: `handle_root_terminal()` uses `--entrypoint bash` while the per-project `handle_terminal()` uses `--entrypoint fish`. The forge image ships with fish and a welcome banner that only appears under fish. Root terminal users get a bare bash prompt with no welcome.

Both bugs exist because the root handlers were written separately from the per-project handlers with different mount/entrypoint logic.

## What Changes

- **Fix root mount in `handle_attach_here()`** -- detect when the project path IS the watch root (not a project inside it) and mount it directly at `/home/forge/src/` instead of `/home/forge/src/src/`
- **Fix root terminal entrypoint** -- change `--entrypoint bash` to `--entrypoint fish` in `handle_root_terminal()` so fish + welcome banner work correctly

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Root "Attach Here" mounts the watch path correctly at `/home/forge/src/`
- `tray-app`: Root terminal opens fish with the standard forge welcome banner

## Impact

- **Modified files**: `src-tauri/src/handlers.rs` (two targeted fixes in `build_run_args` and `handle_root_terminal`)
- No new dependencies, no config changes, no new files
