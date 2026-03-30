## Why

The tray icon currently uses 3 states (`Base`, `Building`, `Decay`) that map to Ionantha `bud.svg`, `bloom.svg`, and `dried.svg`. This mapping is incomplete and semantically wrong: the "base" state uses a bud icon (which suggests something new and growing), while it should represent a healthy, mature plant at rest. The 4 SVG lifecycle stages per genus (pup, bud, bloom, dried) map perfectly to the app's lifecycle, but only 3 are used and the names do not reflect the plant metaphor.

Additionally, there is no "startup" state. The app launches directly into `Base`, so the user sees a mature plant icon before initialization is complete. There is also no visual feedback when a build completes — the icon goes straight from `Building` back to `Base` with no "something finished" moment.

## What Changes

- **Expand `TrayIconState`** from 3 variants to 5, using plant lifecycle names that match the SVG assets:
  - `Pup` (new) — app initializing, checking podman/forge — maps to `pup.svg`
  - `Mature` (was `Base`) — at rest, everything healthy — maps to `bud.svg` (the mature rosette)
  - `Building` (unchanged) — image/container build in progress — maps to `bloom.svg`
  - `Blooming` (new) — build just completed, awaiting user acknowledgment — maps to `bloom.svg`
  - `Dried` (was `Decay`) — unrecoverable error (podman missing) — maps to `dried.svg`

- **Add `Pup` tray icon** — rendered from `ionantha/pup.svg` at build time alongside the other 4 tray variants

- **Update startup sequence** — app launches in `Pup` state, transitions to `Mature` when forge is confirmed available, or to `Dried` if podman is missing

- **Blooming-to-Mature transition** — when the user opens the tray menu while in `Blooming` state, the icon transitions to `Mature` (acknowledgment)

- **Update `compute_icon_state()`** — returns `Blooming` when builds have recently completed (within the fadeout window) and no builds are in progress

## Capabilities

### New Capabilities
- `tray-icon-lifecycle`: Full plant lifecycle mapping to tray icon — 5 states covering startup, idle, activity, completion, and error

### Modified Capabilities
- `tray-app`: Tray icon now starts in `Pup` state and uses plant lifecycle names throughout
- `icon-pipeline`: Build-time tray icon rendering expanded from 3 to 5 variants

## Impact

- **Modified files**: `crates/tillandsias-core/src/genus.rs` (rename + add variants), `crates/tillandsias-core/build.rs` (5 tray icon variants), `crates/tillandsias-core/src/icons.rs` (tests updated), `crates/tillandsias-core/src/state.rs` (`compute_icon_state` + `TrayState::new`), `src-tauri/src/main.rs` (startup sequence, menu event handler), `src-tauri/src/event_loop.rs` (no direct changes — uses `compute_icon_state`), `src-tauri/src/menu.rs` (`Decay` -> `Dried` references)
- **No new files**: All changes are to existing modules
- **No changed SVG assets**: Uses existing `pup.svg`, `bud.svg`, `bloom.svg`, `dried.svg`
