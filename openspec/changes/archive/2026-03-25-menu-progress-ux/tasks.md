## 1. Core State

- [ ] 1.1 Add `BuildStatus` enum to `tillandsias-core/src/state.rs`: `InProgress`, `Completed`, `Failed(String)`
- [ ] 1.2 Add `BuildProgress` struct: `image_name: String`, `status: BuildStatus`, `started_at: Instant`, `completed_at: Option<Instant>`
- [ ] 1.3 Add `active_builds: Vec<BuildProgress>` field to `TrayState`; initialise as empty in `TrayState::new()`

## 2. Event Loop Integration

- [ ] 2.1 On build-started event: push `BuildProgress { status: InProgress, .. }` into `state.active_builds`, call `on_state_change`
- [ ] 2.2 On build-completed event: find matching entry, set `status = Completed`, set `completed_at = Some(Instant::now())`, call `on_state_change`
- [ ] 2.3 On build-failed event: find matching entry, set `status = Failed(reason)`, call `on_state_change`
- [ ] 2.4 Add prune step before each `on_state_change` call: remove entries where `status == Completed` and `completed_at.elapsed() > 10s`; if any were removed, the rebuild triggered by the original event handles the clean state (no extra rebuild needed)
- [ ] 2.5 Schedule the 10s fadeout: after setting `completed_at`, spawn a one-shot `tokio::time::sleep(10s)` task that sends a no-op state-change trigger so the prune step fires and removes the completed item

## 3. Menu Rendering

- [ ] 3.1 In `rebuild_menu()`, after the "No running environments" / running section, iterate `state.active_builds` and render each as a disabled `MenuItemBuilder` item
- [ ] 3.2 `InProgress` label: `"⏳ Building {image_name}..."`
- [ ] 3.3 `Completed` label: `"✅ {image_name} ready"`
- [ ] 3.4 `Failed` label: `"❌ {image_name} build failed"`
- [ ] 3.5 All build-progress items use `enabled(false)`
- [ ] 3.6 Rename "Ground" entry in project submenu builder: change emoji from `\u{1F331}` to `\u{1F527}` (🔧) and label from `Ground` to `Maintenance`

## 4. Maintenance Container Progress

- [ ] 4.1 Reuse `BuildProgress` / `active_builds` for maintenance container setup: image_name = `"Maintenance"`
- [ ] 4.2 On maintenance-container setup started: push `InProgress` entry; label renders as `"🔧 Setting up Maintenance..."` — override label in render step when `image_name == "Maintenance"` and status is `InProgress`
- [ ] 4.3 Completed and Failed follow the same pattern as image builds

## 5. Verification

- [ ] 5.1 `cargo check --workspace` passes
- [ ] 5.2 `cargo test --workspace` passes
- [ ] 5.3 Manual: trigger a build, confirm menu shows `⏳` chip while in progress
- [ ] 5.4 Manual: on completion, confirm chip changes to `✅`, then disappears after ~10 seconds with no flicker
- [ ] 5.5 Manual: on failure, confirm `❌` chip persists and is removed only when next build attempt begins
- [ ] 5.6 Manual: confirm project submenu shows `🔧 Maintenance` (not `🌱 Ground`)
- [ ] 5.7 Manual: confirm `MenuCommand::Terminal` and `terminal:<path>` ID still route correctly after rename
