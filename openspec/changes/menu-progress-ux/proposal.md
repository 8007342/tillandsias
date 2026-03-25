## Why

The tray menu gives no feedback during image builds or container creation — the user sees a static menu with no indication that work is in progress. On Linux/libappindicator, periodic menu rebuilds to animate a spinner or show elapsed time would cause visible flicker if the user has the menu open. The tray icon (from the dynamic-tray-icons change) provides continuous motion, but the menu itself needs supplementary text status at key transitions.

Additionally, "Ground" (the bash terminal option) is unclear — "Maintenance" is more descriptive and matches the wrench-based tool metaphor.

## What Changes

- **Build progress chips** — Disabled (non-clickable) menu items appear at state transitions: build started, build completed (10s fadeout), build failed (persists until next attempt). No timers, no polling — zero flicker.
- **Maintenance progress chip** — Same pattern when the maintenance container is being set up on first launch.
- **State pruning in event loop** — Before each menu rebuild triggered by a state transition, completed builds older than 10 seconds are removed from `active_builds`. Removal itself triggers one final rebuild.
- **"Ground" → "Maintenance" rename** — Display label and emoji change only (`🌱 Ground` → `🔧 Maintenance`). `MenuCommand::Terminal` and the `terminal:<path>` ID format are unchanged.

## Capabilities

### New Capabilities

- `build-progress-display`: Tray menu reflects image build and maintenance container setup status at state transitions.

### Modified Capabilities

- `tray-app`: Project submenu "Ground" item renamed to "Maintenance" with wrench emoji.

## Impact

- **Modified files**:
  - `crates/tillandsias-core/src/state.rs` — add `BuildProgress`, `BuildStatus`, `active_builds: Vec<BuildProgress>` to `TrayState`
  - `src-tauri/src/menu.rs` — render `active_builds` as disabled items; rename "Ground" → "Maintenance"
  - `src-tauri/src/event_loop.rs` — update `active_builds` on build events; prune completed builds >10s before each rebuild
- **New files**: none
