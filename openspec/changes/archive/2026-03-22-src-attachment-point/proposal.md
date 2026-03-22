## Why

Users need a way to start working even before any projects exist. The `~/src` directory itself should always appear as an "Attach Here" point — this is where users create new projects, clone repos, and start from scratch. Without this, a fresh install shows an empty menu with no actionable entry.

## What Changes

- Always show `~/src/` as a top-level "Attach Here" entry in the tray menu, regardless of whether projects exist inside it
- This entry launches a forge environment mounted at `~/src/` — the user can then create/clone projects from inside OpenCode

## Capabilities

### Modified Capabilities
- `tray-app`: Always show src/ as an attachment point at the top of the project list

## Impact

- Modified: `src-tauri/src/menu.rs` — add permanent src/ entry
- Modified: `src-tauri/src/main.rs` — handle attach for src/ root
- No new dependencies
