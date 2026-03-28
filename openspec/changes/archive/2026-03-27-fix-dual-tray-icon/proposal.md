## Why

On Windows and macOS, two tray icons appear: a white static one (from tauri.conf.json `trayIcon` config) and a colorful tillandsia one (from programmatic `TrayIconBuilder` in main.rs). Only the programmatic one is clickable. The static one is a non-functional duplicate.

## What Changes

- Remove the `trayIcon` section from `tauri.conf.json` — the app already creates its own fully interactive tray icon via `TrayIconBuilder` with dynamic state (Base/Building/Decay), menu callbacks, and tooltip

## Capabilities

### Modified Capabilities
- `tray-icon`: Single interactive tray icon instead of duplicate static + interactive

## Impact

- Modified: `src-tauri/tauri.conf.json` (remove `trayIcon` section)
- No code changes — the programmatic icon creation in main.rs is the correct path
