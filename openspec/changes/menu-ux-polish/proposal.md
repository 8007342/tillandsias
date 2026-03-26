## Why

The project submenu has several rough UX edges: "Attach Here" shows no plant emoji when idle, remains clickable when the container is already running, the Maintenance icon is a generic wrench instead of a garden tool, the per-project container listing duplicates information already conveyed by the "Attach Here" / "Blooming" state, and the project label in the top-level menu uses a parenthesized counter instead of emoji iconography. These small details accumulate into a tray menu that doesn't feel cohesive with the plant lifecycle metaphor.

## What Changes

- **Attach Here idle state** — Add seedling emoji prefix (`🌱 Attach Here`) when no container is running
- **Attach Here running state** — Change to `🌺 Blooming` (genus flower + "Blooming") and disable the item so users can't click it again
- **Maintenance icon** — Replace wrench (`🔧`) with pick (`⛏️`) for a garden-tool feel
- **Remove per-project container listing** — The separator and per-container "Starting/Running" items below Maintenance are redundant now that Attach Here reflects lifecycle state directly
- **Project label emoji** — Replace `"project (1)"` counter with emoji indicators: genus flower when attach is running, pick when only maintenance is running, both when both are running, seedling when idle

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-menu`: Project submenus use plant lifecycle emoji consistently; redundant container listings removed; Attach Here reflects running state with disabled click guard

## Impact

- **New files**: none
- **Modified files**: `src-tauri/src/menu.rs` (project submenu builder, project label, maintenance label, build chip label)
