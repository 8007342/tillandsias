## Why

When a user clones a remote project, they are expressing intent to work on it immediately. Today, after a successful clone, the user must find the new project in the tray and click "Attach Here" manually. This is unnecessary friction — the clone is the signal that the user wants to start working.

The current experience leaves a gap: the directory exists on disk, the scanner will eventually pick it up, but nothing happens. The project appears silently in the tray menu with no indication that anything just happened. Users are left wondering if the clone worked.

Automatically launching the forge after a successful clone closes this gap. The project appears inline with a blooming flower immediately — clear visual feedback that the checkout worked and the environment is ready.

## What Changes

- After a successful `CloneProject`, `handle_clone_project` in `event_loop.rs` calls `handlers::handle_attach_here()` directly with the cloned project's path.
- The project is pre-inserted into `state.projects` before calling `handle_attach_here` so the handler can find it without waiting for the scanner.
- The scanner will still detect the directory via filesystem events and may emit a `Discovered` event — the dedup guard in `handle_scanner_event` ensures no duplicate entries.
- If `handle_attach_here` fails (e.g., forge image not built, container already running), the error is logged but clone is still considered successful.

## Capabilities

### Modified Capabilities
- `remote-projects`: After a successful clone, the forge is automatically launched for the new project

## Impact

- **Modified files**: `src-tauri/src/event_loop.rs` — `handle_clone_project` function signature gains `allocator` and `build_tx` parameters; auto-launch logic added after successful clone
- No new files required
- No new dependencies
- No changes to `handlers.rs` — `handle_attach_here` is reused as-is
