## Why

When Tillandsias starts and the forge image is absent or stale, the user can click "Attach Here" or "Maintenance" before the build finishes. Those actions fail silently or produce confusing errors because the forge image is not ready yet. Additionally, the build chip always shows "Building forge..." regardless of whether this is a first-time install or a routine update, which makes it harder for the user to understand what is happening.

## What Changes

- **Distinct build chip messages** — First-time build (no image): "Building Forge..." / Update build (image stale): "Building Updated Forge..."
- **Disable forge-dependent actions during build** — While the forge image is building, all actions that require the image (Attach Here, Maintenance, Root terminal, GitHub Login) are visually disabled so the user cannot trigger them prematurely
- **Start disabled, enable on ready** — On launch, if the forge image needs building, the menu starts with those actions disabled and re-enables them only once the build completes successfully

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Forge-dependent menu items are disabled while the forge image is unavailable or building

## Impact

- **Modified files**:
  - `crates/tillandsias-core/src/state.rs` — add `forge_available: bool` to `TrayState`
  - `src-tauri/src/main.rs` — set `forge_available`, choose build chip message based on image existence
  - `src-tauri/src/menu.rs` — disable forge-dependent items when `!state.forge_available`
