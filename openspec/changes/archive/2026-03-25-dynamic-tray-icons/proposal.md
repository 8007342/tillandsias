## Why

The tray icon is a static PNG set once at startup and never updated. This means users get no ambient feedback about what the application is doing. A build in progress, a broken podman installation, and an idle ready state all look identical. The icon is the only always-visible surface of the app — making it dynamic is the highest-leverage UX improvement possible without adding any new UI.

## What Changes

- **`TrayIconState` enum** — three states: `Base`, `Building`, `Decay`, added to `tillandsias-core`
- **`tray_icon_state` field on `TrayState`** — icon state is part of app state, derived from `has_podman` and active build count
- **Active build counter in `TrayState`** — incremented when a build starts, decremented on completion; drives `Base`↔`Building` transitions
- **Launch-time podman check** — on startup, verify podman is available before any other operation; enter Decay immediately if not
- **Launch-time forge image check** — if podman is available but `tillandsias-forge:latest` is absent, auto-build it using the existing build lock machinery
- **`tray.set_icon()` call on state change** — in the state change callback, compare old and new `tray_icon_state`; call `set_icon()` only when the value differs
- **Icon bytes from `svg-icon-pipeline`** — consumed via `tray_icon(state: TrayState) -> &'static [u8]` (provided by dependency)

## Capabilities

### New Capabilities

- `tray-icon-states`: Three-state main tray icon — Base (ready), Building (image build in progress), Decay (podman unavailable); state machine with defined transitions and terminal Decay state

### Modified Capabilities

- `tray-app`: Icon is no longer static; updates at runtime via `TrayIcon::set_icon()` when state transitions occur
- `app-lifecycle`: Launch sequence now includes a podman availability check and a forge image presence check before entering the idle loop; forge image is auto-built on first launch if missing

## Impact

- **Modified files**: `crates/tillandsias-core/src/state.rs` (new enum + fields), `src-tauri/src/main.rs` (set_icon call, launch checks), `src-tauri/src/handlers.rs` (build counter increment/decrement)
- **Dependency required**: `svg-icon-pipeline` must land first — provides `tray_icon(state: TrayState) -> &'static [u8]`
- **Menu behavior**: All menu items are disabled when `tray_icon_state == Decay`; a single disabled error item is shown explaining podman is not available
- **Non-recoverable Decay**: No automatic recovery from Decay state; user must fix their podman installation and restart the app
