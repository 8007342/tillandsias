## Why

When users download and run the Tillandsias AppImage directly (`./Tillandsias.AppImage`), GNOME shows a generic blue gear icon in the taskbar and dock because there is no `.desktop` file or icon installed on the host. The `install.sh` script handles desktop integration for `--install` users, but AppImage users who simply download and run the binary never execute `install.sh` — they get no desktop integration at all.

This is a first-impression problem: the very first thing a user sees is a broken icon, undermining trust before they even interact with the app.

## What Changes

- **Self-installing desktop integration** — When the app detects it is running as an AppImage (via the `$APPIMAGE` environment variable set by the AppImage runtime), it writes desktop integration files to the user's XDG directories on first run
- **`.desktop` file** — Written to `~/.local/share/applications/tillandsias.desktop` with `Exec=` pointing to the actual AppImage path
- **Icon PNGs** — Written to `~/.local/share/icons/hicolor/{32x32,128x128,256x256}/apps/tillandsias.png` using icons already embedded in the binary via the SVG icon pipeline
- **Cache refresh** — Runs `update-desktop-database` and `gtk-update-icon-cache` to make the integration visible immediately
- **install.sh fix** — Adds missing 256x256 icon installation (currently only installs 32x32 and 128x128)

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `appimage-desktop-integration`: AppImage self-installs desktop integration files on first run so GNOME shows the correct tillandsia icon

## Impact

- **New files**: `src-tauri/src/desktop.rs` (new module)
- **Modified files**: `src-tauri/src/main.rs` (module declaration + call), `scripts/install.sh` (add 256x256 icon)
- **Runtime side-effects**: Writes files under `~/.local/share/` on first AppImage launch; runs `update-desktop-database` and `gtk-update-icon-cache`
