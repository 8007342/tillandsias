## 1. Core State Types

- [ ] 1.1 Add `WindowType` enum (`AttachHere`, `Maintenance`) to `tillandsias-core/src/state.rs`
- [ ] 1.2 Add `WindowInfo` struct (`project_path: PathBuf`, `genus: Option<TillandsiaGenus>`, `window_type: WindowType`, `created_at: Instant`) to `tillandsias-core/src/state.rs`
- [ ] 1.3 Add `open_windows: HashMap<String, WindowInfo>` field to `TrayState`
- [ ] 1.4 Add `compute_window_label(project_path: &Path, window_type: &WindowType, genus: Option<&TillandsiaGenus>) -> String` helper — produces `tillandsias-<slug>-<genus-slug>` or `tillandsias-<slug>-maintenance`

## 2. Focus Recovery — Attach Here

- [ ] 2.1 In `handle_attach_here`, compute the window label before any container or PTY work
- [ ] 2.2 Call `app.get_webview_window(&label)`; if `Some(window)` is returned, call `window.unminimize()` if minimized, then `window.set_focus()`, and return `Ok(())`
- [ ] 2.3 If no window exists, proceed with normal launch; add entry to `open_windows` when the Tauri window is created

## 3. Focus Recovery — Maintenance Terminal

- [ ] 3.1 In `handle_maintenance`, compute the maintenance label (`tillandsias-<slug>-maintenance`) before any work
- [ ] 3.2 Same focus-or-launch gate as task 2.2
- [ ] 3.3 If no window exists, proceed with launch; add entry to `open_windows` with `WindowType::Maintenance`

## 4. Destroyed Event Handler

- [ ] 4.1 In `main.rs`, register an `on_window_event` listener after app setup
- [ ] 4.2 On `WindowEvent::Destroyed`, look up the window label in `open_windows`
- [ ] 4.3 If found: remove entry, release genus if present, remove project from running container set, call `rebuild_menu()`
- [ ] 4.4 If not found (non-tracked window): no-op, return silently

## 5. Window Close → Container Cleanup

- [ ] 5.1 When the user closes the Tauri window (X button), the PTY manager receives the close signal via the `CloseRequested` window event
- [ ] 5.2 PTY manager sends SIGHUP to the podman child process
- [ ] 5.3 Verify containers are started with `--stop-timeout=10` and `--rm` so graceful stop and removal are automatic
- [ ] 5.4 After SIGHUP is sent, allow `WindowEvent::Destroyed` to handle all state cleanup (no duplicate cleanup in the close handler)

## 6. Menu Rendering

- [ ] 6.1 In `build_menu()`, for each project item, check whether an entry exists in `open_windows` for the project
- [ ] 6.2 Show 🌺 bloom icon for "Attach Here" only when: `open_windows` contains an AttachHere entry for the project AND the container is in the running set
- [ ] 6.3 Show 🌱 pup icon in all other cases (no window, or window exists but container not yet running)
- [ ] 6.4 Show 🌱 pup icon for Maintenance item when no maintenance window is open; show 🔧 (or distinct bloom variant) when a maintenance window is open

## 7. Verification

- [ ] 7.1 `cargo test -p tillandsias-core` passes with new types and fields
- [ ] 7.2 `cargo check --workspace` clean
- [ ] 7.3 Manual: click "Attach Here" → terminal opens, menu shows 🌺
- [ ] 7.4 Manual: click "Attach Here" again while terminal is open → existing window comes to front, no new window spawned, container count unchanged
- [ ] 7.5 Manual: type `exit` in terminal → window closes, menu reverts to 🌱, container removed (`podman ps` confirms)
- [ ] 7.6 Manual: close terminal window via X → menu reverts to 🌱, container removed
- [ ] 7.7 Manual: minimize terminal window, then click "Attach Here" → window unminimizes and comes to front
- [ ] 7.8 Manual: same focus recovery tests for Maintenance terminal
