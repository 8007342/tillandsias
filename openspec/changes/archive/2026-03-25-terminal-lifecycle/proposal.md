## Why

After `terminal-in-tauri` lands, terminals run inside Tauri webview windows that Tillandsias owns. The tray menu has no way to know whether a window is open, so "Attach Here" always launches a new terminal — destroying the user's existing session (open editor, uncommitted history, running processes). There is also no cleanup path: if the user closes the window directly, the container keeps running silently in the background.

This change wires together Tauri window events, container state, and menu rendering so the tray stays truthful about what is running and never clobbers the user's work.

## What Changes

- **`open_windows` map in `TrayState`** — tracks every open terminal window by label; each entry holds project path, optional genus, window type (AttachHere or Maintenance), and creation timestamp
- **Focus recovery in `handle_attach_here`** — before spawning anything, check `app.get_webview_window(label)`; if the window exists, call `set_focus()` (and `unminimize()` if needed) and return early
- **Focus recovery in `handle_maintenance`** — same check for maintenance terminal windows (`tillandsias-<project>-maintenance` label)
- **`on_window_event(WindowEvent::Destroyed)` handler** — removes window from `open_windows`, releases genus allocation, updates container state, rebuilds the tray menu
- **PTY EOF → window close** — when the PTY child process exits, the terminal frontend closes the Tauri window; `Destroyed` fires and triggers cleanup
- **Window close → container cleanup** — when the user clicks X, the PTY manager sends SIGHUP to the podman process; container stops with `--stop-timeout=10` and is removed via `--rm`
- **Menu rendering reads window state** — `build_menu()` checks `open_windows` to decide between pup icon (🌱) and bloom icon (🌺) per project; bloom only shown when a window is open AND the container is running

## Capabilities

### New Capabilities

- `terminal-lifecycle`: End-to-end window tracking — open windows are registered in state, menu reflects window presence, windows are focused instead of relaunched, and closed windows trigger container cleanup

### Modified Capabilities

- `environment-runtime`: `handle_attach_here` and `handle_maintenance` now check for an existing window before creating one; relaunch is replaced by focus recovery
- `tray-app`: Menu items for a project show 🌺 bloom when a terminal window is open and running, 🌱 pup when no window is open; state is derived from `open_windows` + container state rather than container state alone

## Impact

- **Modified files**: `crates/tillandsias-core/src/state.rs` (new `WindowInfo`, `WindowType`, `open_windows` field), `src-tauri/src/main.rs` (register `on_window_event` handler), `src-tauri/src/handlers.rs` (focus recovery logic, cleanup on destroy), `src-tauri/src/menu.rs` (bloom vs pup per project)
- **Dependency required**: `terminal-in-tauri` must land first — provides Tauri-owned webview windows with PTY integration and the `WindowEvent::Destroyed` path
- **No new user-facing concepts**: users see focus recovery as natural behavior ("clicking the tray item brings my window back")
- **Container cleanup is guaranteed**: every code path that opens a window has a matching cleanup path — PTY EOF, user closes window, or app quits
