## 1. Core State Changes

- [ ] 1.1 Add `TrayIconState` enum (`Base`, `Building`, `Decay`) to `tillandsias-core/src/state.rs`
- [ ] 1.2 Add `tray_icon_state: TrayIconState` field to `TrayState`
- [ ] 1.3 Add `active_builds: u32` field to `TrayState`
- [ ] 1.4 Add derived method: `fn compute_icon_state(&self) -> TrayIconState` — returns `Decay` if `!has_podman`, `Building` if `active_builds > 0`, else `Base`

## 2. Launch Sequence

- [ ] 2.1 On startup, run podman availability check (`podman version`) before entering the event loop
- [ ] 2.2 If podman check fails: set `tray_icon_state = Decay`, set `has_podman = false`, disable all menu items, display error item, stop further initialization
- [ ] 2.3 If podman check passes: check whether `tillandsias-forge:latest` image exists (`podman image exists tillandsias-forge:latest`)
- [ ] 2.4 If forge image is absent: auto-trigger `run_build_image_script("forge")` with build lock, increment `active_builds`, set icon to `Building`
- [ ] 2.5 If forge image is present: set `tray_icon_state = Base`, proceed normally
- [ ] 2.6 Web image is NOT checked or built on launch — build on-demand only

## 3. Build Count Tracking

- [ ] 3.1 In `handlers.rs`, increment `active_builds` when any image build starts
- [ ] 3.2 Decrement `active_builds` (never below 0) when a build completes or fails
- [ ] 3.3 After each change to `active_builds`, recompute and update `tray_icon_state`

## 4. Icon Updates

- [ ] 4.1 In the state change callback, compare `old_state.tray_icon_state` with `new_state.tray_icon_state`
- [ ] 4.2 If changed, call `tray.set_icon(tray_icon(new_state.tray_icon_state))`
- [ ] 4.3 Replace the static `include_bytes!` icon in `main.rs` with the initial call to `tray_icon(TrayIconState::Base)`

## 5. Menu: Decay State

- [ ] 5.1 When `tray_icon_state == Decay`, render all project/action menu items as disabled
- [ ] 5.2 Show a single disabled informational item at the top of the menu (e.g., "Podman is not available")
- [ ] 5.3 Quit item remains enabled in Decay state

## 6. Verification

- [ ] 6.1 `cargo test -p tillandsias-core` passes with new fields and enum
- [ ] 6.2 `cargo check --workspace` clean
- [ ] 6.3 Manual: launch without podman in PATH — Decay icon appears, menu items disabled
- [ ] 6.4 Manual: launch with podman but no forge image — Building icon during build, Base icon after
- [ ] 6.5 Manual: launch with podman and forge image already present — Base icon from startup
