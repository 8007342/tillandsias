## Context

Code audit found 5 bugs preventing the tray app from functioning. The scanner works correctly but its results never reach the UI. Menu events fire but never reach the event loop.

## Goals / Non-Goals

**Goals:**
- Quit works
- Projects show in menu
- Menu updates dynamically when projects change
- All directories in ~/src visible (not just those with manifests)

**Non-Goals:**
- Container launching (separate concern, fix menu first)
- Icon state transitions (needs working menu first)

## Decisions

### D1: TrayIcon stored in Tauri app state

Store the TrayIcon handle via `app.manage()` so it persists for the app lifetime. The on_state_change callback retrieves it to call `set_menu()`.

### D2: Quit fast-path

Quit calls `std::process::exit(0)` directly from the menu event handler — no channel round-trip needed. This guarantees it works even if the event loop is broken.

### D3: All directories are projects

Any non-empty, non-hidden directory under the watch path is a project. Unknown type gets "Attach Here" action. Manifest detection is for enrichment (showing type), not gating.

### D4: Menu rebuild on state change

The on_state_change callback rebuilds the full menu and calls `tray.set_menu(&new_menu)`. This is <1ms for tens of items.
