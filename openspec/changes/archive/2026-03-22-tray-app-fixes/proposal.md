## Why

The tray app runs but is non-functional: menu clicks do nothing (including Quit), projects aren't visible despite being detected by the scanner, and the menu never updates. Five bugs identified via code audit.

## What Changes

- **Fix 1**: Store TrayIcon handle in Tauri managed state so it persists and callbacks remain registered
- **Fix 2**: Rebuild tray menu on every state change by calling `tray_icon.set_menu()` in the on_state_change callback
- **Fix 3**: Wire menu event handler to correctly dispatch through the mpsc channel to the event loop
- **Fix 4**: Make Quit actually call `app.exit(0)` directly from the menu event handler as a fast path
- **Fix 5**: Detect all non-empty, non-hidden directories as projects (not just those with recognized manifest files) — every directory in ~/src is eligible for "Attach Here"

## Capabilities

### New Capabilities

### Modified Capabilities
- `tray-app`: Fix menu event dispatch, dynamic menu rebuild, TrayIcon lifecycle
- `filesystem-scanner`: Detect all directories as projects, not just those with manifest files

## Impact

- Modified files: src-tauri/src/main.rs, src-tauri/src/menu.rs, src-tauri/src/event_loop.rs
- Scanner detect.rs: all non-empty non-hidden dirs are valid projects
- No new dependencies
