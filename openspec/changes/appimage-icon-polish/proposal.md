## Why

The AppImage shows a generic blue gear icon in file managers instead of our tillandsia. While the tray icon is now properly embedded (v0.1.37), the AppImage file itself and its desktop integration need polish to show the correct icon everywhere.

## What Changes

- **AppImage icon integration** — Ensure Tauri's bundler embeds the icon at the correct AppDir paths (`.DirIcon`, root `<name>.png`, and `usr/share/icons/`)
- **Larger icon** — Add a 512x512 icon for high-DPI displays and AppImage thumbnailing
- **AppStream metadata** — Add `appdata.xml` for AppImage center/software center integration
- **Desktop template** — Ensure `Icon=` resolves correctly in AppImage context

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Icon displayed correctly in AppImage file managers and desktop integration

## Impact

- **New files**: `src-tauri/icons/512x512.png` (if we generate one), `src-tauri/appdata.xml`
- **Modified files**: `src-tauri/tauri.conf.json` (icon list), `src-tauri/desktop-template.desktop` (if needed)
