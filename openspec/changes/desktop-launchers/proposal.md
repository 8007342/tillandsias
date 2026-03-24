## Why

Tillandsias targets non-technical users who do not know what a "terminal" is. Today, launching the application requires opening a terminal emulator and running a binary by name, or double-clicking an unmarked executable in a file manager. Neither path is discoverable, and both feel alien to users who expect applications to appear in their operating system's app launcher alongside everything else they use.

Desktop integration is table-stakes for any application that claims to "just work." Without it, the entire zero-configuration promise collapses at the very first step: finding the application.

## What Changes

- **Linux**: Install a `.desktop` file at `~/.local/share/applications/tillandsias.desktop` so Tillandsias appears in GNOME Activities, KDE Application Launcher, and any XDG-compliant desktop environment. Copy icon PNGs to `~/.local/share/icons/hicolor/` at standard resolutions.
- **macOS**: Create a `.app` bundle so Tillandsias appears in Finder, Spotlight, and Launchpad. Place it in `/Applications/` (system-wide install) or `~/Applications/` (per-user install).
- **Windows**: Create a Start Menu shortcut via the installer so Tillandsias appears alongside other installed programs.
- **Optional autostart**: Support launching Tillandsias on login, disabled by default. Users who want the tray icon always present can enable this through a settings toggle or configuration file.
- **Install and uninstall scripts** handle desktop file creation, icon installation, and cleanup automatically. Users never touch these files manually.

## Capabilities

### New Capabilities
- `desktop-integration`: Platform-native launcher entries (Linux .desktop file, macOS .app bundle, Windows Start Menu shortcut), icon installation, and optional autostart-on-login support

### Modified Capabilities
- `tray-app`: Tray app spec gains a cross-reference to desktop-integration for launch expectations
- `app-lifecycle`: Lifecycle spec gains autostart-on-login as an optional startup trigger

## Impact

- **Linux**: Two new files installed per user (`~/.local/share/applications/tillandsias.desktop`, icons in `~/.local/share/icons/hicolor/`). Uninstall removes both.
- **macOS**: `.app` bundle placed in Applications directory. Uninstall removes the bundle.
- **Windows**: Start Menu shortcut created by installer. Uninstall removes the shortcut.
- **Tauri bundler**: Tauri already generates `.desktop` files and `.app` bundles during `cargo tauri build`. This change may leverage those outputs or provide standalone install/uninstall scripts for manual installations and development builds.
- **No runtime behavior change**: The application itself is unchanged. This is purely about discoverability and launch ergonomics.
