## Context

`terminal-in-tauri` gives Tillandsias owned Tauri windows with embedded PTY terminals. The question this change answers is: what happens to state, menus, and containers over the full lifetime of one of those windows — from first click through to cleanup.

## Goals / Non-Goals

**Goals:**
- Define the canonical window label scheme and its use as a lookup key
- Specify the focus recovery algorithm for both AttachHere and Maintenance terminals
- Define the state machine from IDLE through RUNNING to cleanup
- Specify the two cleanup paths (PTY EOF and user closes window)
- Define how `TrayState` tracks open windows and how menu rendering consumes that state

**Non-Goals:**
- PTY implementation internals (owned by `terminal-in-tauri`)
- Container orchestration details (owned by `environment-runtime`)
- Multi-window layouts or tabbed terminals
- Crash recovery or session restore after app restart

## Decisions

### D1: Window label is the single source of identity

Window label format:
- AttachHere: `tillandsias-<project-slug>-<genus-slug>` (e.g., `tillandsias-my-app-aeranthos`)
- Maintenance: `tillandsias-<project-slug>-maintenance`

`project-slug` is the project directory basename, lowercased, with non-alphanumeric characters replaced by hyphens. The label is stable for the lifetime of the window and is the key used in `open_windows`, genus allocation, container naming, and `app.get_webview_window()` lookups.

### D2: Focus recovery is a gate, not a fallback

`handle_attach_here` and `handle_maintenance` check for an existing window as the *first* operation, before any container or PTY work. If the window exists, the function calls `set_focus()` (preceded by `unminimize()` if the window reports minimized state) and returns immediately. No new container is started. No new PTY is spawned. This is not a "try to reuse" heuristic — it is a hard gate that protects the user's session.

### D3: `open_windows` in TrayState, keyed by window label

`TrayState` gains an `open_windows: HashMap<String, WindowInfo>` field. `WindowInfo` holds: `project_path: PathBuf`, `genus: Option<TillandsiaGenus>`, `window_type: WindowType`, `created_at: Instant`. The map is the authoritative record of what the app has open. Menu rendering and focus recovery both read from this map.

### D4: `WindowEvent::Destroyed` is the single cleanup trigger

All cleanup — removing from `open_windows`, releasing genus, updating container state, rebuilding the menu — happens in a single `on_window_event(WindowEvent::Destroyed)` handler registered in `main.rs`. Both cleanup paths (PTY EOF causing window close, and user clicking X causing SIGHUP then window close) converge on this handler. There is no separate cleanup logic per path.

### D5: Window close → SIGHUP, not SIGKILL

When the user closes the window, the PTY manager sends SIGHUP to the podman process. podman propagates the hangup to the container's init process, which initiates a graceful shutdown. The container was started with `--stop-timeout=10`, so if the container does not exit within 10 seconds, podman sends SIGKILL. The container was started with `--rm`, so it is removed automatically on exit. Tillandsias does not call `podman stop` or `podman rm` explicitly — the SIGHUP path handles it.

### D6: Bloom requires both window open AND container running

The menu shows 🌺 bloom for a project only when two conditions are both true: an entry exists in `open_windows` for the project, AND the container is in the running set in `TrayState`. A window that exists but whose container has already exited (transition period between PTY EOF and `Destroyed` firing) shows neither state — the menu re-renders on `Destroyed` to settle on 🌱 pup. This prevents a brief ghost-bloom while the window is in the process of closing.

## State Machine

```
IDLE (🌱 pup)
  │ User clicks "Attach Here"
  │ → window label computed
  │ → app.get_webview_window(label) returns None
  ▼
CREATING (🌱 bud)
  │ Tauri window created
  │ PTY spawning, container starting
  │ Entry added to open_windows
  │ Container appears in running set
  ▼
RUNNING (🌺 bloom)
  │
  ├─[A] User clicks "Attach Here" again
  │     → app.get_webview_window(label) returns Some
  │     → unminimize() if needed, set_focus()
  │     → return early, no new window
  │     (stays in RUNNING)
  │
  ├─[B] Container exits (user types "exit", OOM, crash)
  │     → PTY receives EOF
  │     → terminal frontend closes Tauri window
  │     → WindowEvent::Destroyed fires
  │     → open_windows entry removed
  │     → container removed from running set
  │     → genus released
  │     → menu rebuilt
  │     ▼ IDLE (🌱)
  │
  ├─[C] User closes window (clicks X)
  │     → PTY manager receives close signal
  │     → SIGHUP sent to podman process
  │     → container stops gracefully (--stop-timeout=10)
  │     → container removed (--rm)
  │     → WindowEvent::Destroyed fires
  │     → same cleanup as [B]
  │     ▼ IDLE (🌱)
  │
  └─[D] App quits (user selects Quit from tray)
        → all Tauri windows receive close signal
        → all PTY managers send SIGHUP
        → all containers stop and are removed
        → app exits
        ▼ (app gone)
```

## Focus Recovery Flow

```
handle_attach_here(project_path):
  label = compute_label(project_path)        # "tillandsias-<slug>-<genus>"

  if let Some(window) = app.get_webview_window(&label):
    if window.is_minimized():
      window.unminimize()
    window.set_focus()
    return Ok(())                            # DONE — no new window

  # Normal launch path follows...
  genus = allocate_genus()
  open_windows.insert(label, WindowInfo { ... })
  create_window_and_pty(label, project_path, genus)
```

The same pattern applies to `handle_maintenance`, with label `tillandsias-<slug>-maintenance` and `WindowType::Maintenance`.

## Cleanup Flow

```
on_window_event(label, WindowEvent::Destroyed):
  if let Some(info) = open_windows.remove(&label):
    if let Some(genus) = info.genus:
      release_genus(genus)
    remove_from_running_containers(info.project_path)
    rebuild_menu()
```

This handler is registered once in `main.rs` after app setup. The handler is label-aware: it only acts on labels that exist in `open_windows`, so Tauri system windows (if any) are ignored silently.
