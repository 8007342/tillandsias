## Context

Tillandsias is a system tray application built with Tauri v2. It already has icon assets at multiple resolutions (`src-tauri/icons/`) and Tauri's bundler already generates platform-specific artifacts (`.deb` with `.desktop` files, `.dmg` with `.app` bundles, `.msi`/`.nsis` installers). However, these bundler outputs are only relevant for release builds distributed as packages. Development builds, manual installations from release binaries, and portable installations all lack desktop integration.

This change ensures Tillandsias has desktop integration regardless of how it was installed: via package, via release binary download, or via development build.

## Goals / Non-Goals

**Goals:**
- Tillandsias appears in the system app launcher on all three platforms after installation
- The tillandsia icon is displayed at correct resolution in the launcher, taskbar, and dock
- Install and uninstall scripts handle desktop file management automatically
- Optional autostart on login, disabled by default
- Works for both packaged installs (deb/rpm/dmg/msi) and manual binary installs

**Non-Goals:**
- File type associations (Tillandsias does not open files)
- Protocol handlers (no `tillandsias://` URI scheme)
- Desktop notifications (separate concern, already handled by Tauri)
- Dock/taskbar pinning (user preference, not automatable)

## Decisions

### D1: Linux .desktop file at XDG user path

**Choice:** Install to `~/.local/share/applications/tillandsias.desktop` for per-user installs. System packages (deb/rpm) install to `/usr/share/applications/` via the Tauri bundler.

The `.desktop` file:
```ini
[Desktop Entry]
Name=Tillandsias
Comment=Local development environments that just work
Exec=tillandsias-tray
Icon=tillandsias-tray
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=tillandsias-tray
```

**Key fields:**
- `Terminal=false` -- tray app, no terminal needed
- `Categories=Development;` -- appears in the Development category in app launchers
- `StartupWMClass=tillandsias-tray` -- allows the desktop environment to associate windows with the correct app icon

**Icons** are installed to `~/.local/share/icons/hicolor/` at 32x32, 128x128, and 256x256 resolutions (matching the existing PNGs in `src-tauri/icons/`). After copying, `gtk-update-icon-cache` is run if available to refresh the icon theme cache.

**Why per-user over system-wide for manual installs:** No root/sudo required. The XDG Base Directory Specification guarantees `~/.local/share/applications/` is searched by compliant desktop environments. Users installing from a downloaded binary should never need elevated privileges.

### D2: macOS .app bundle

**Choice:** Create a minimal `.app` bundle for manual installs. Tauri's bundler already handles this for release builds, but a standalone script creates the bundle for development and portable installs.

Structure:
```
Tillandsias.app/
  Contents/
    Info.plist
    MacOS/
      tillandsias-tray    (symlink or copy of the binary)
    Resources/
      tillandsias.icns    (icon in Apple format)
```

Placed in `~/Applications/` for per-user installs or `/Applications/` when installed via `.dmg`.

**Why not rely solely on Tauri bundler:** The bundler output is a `.dmg` for distribution. Users who build from source or download a standalone binary need a way to get an app icon in Spotlight and Launchpad without going through the full bundle pipeline.

### D3: Windows Start Menu shortcut

**Choice:** The NSIS/MSI installer (produced by Tauri bundler) creates the Start Menu shortcut automatically. For manual installs, a PowerShell script creates a shortcut at `$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk`.

**Why PowerShell over batch:** PowerShell has native COM object support for creating `.lnk` shortcuts. No external dependencies needed.

### D4: Autostart on login (optional, off by default)

**Choice:** Each platform has a standard mechanism for autostart:

| Platform | Mechanism | Path |
|----------|-----------|------|
| Linux | XDG autostart `.desktop` file | `~/.config/autostart/tillandsias.desktop` |
| macOS | Launch Agent plist | `~/Library/LaunchAgents/com.tillandsias.tray.plist` |
| Windows | Registry key or Startup folder | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |

Autostart is controlled by:
1. A toggle in `~/.config/tillandsias/config.toml`: `autostart = false` (default)
2. Future: a "Start on Login" toggle in the tray menu's Settings

When enabled, the install script creates the autostart entry. When disabled, the uninstall script (or settings toggle) removes it.

**Why off by default:** Users should consciously choose persistent background processes. Silently adding autostart entries is hostile UX, especially for a tray-only application that has no visible window to explain why it launched.

### D5: Icon assets

**Choice:** Reuse the existing tillandsia tray icon PNGs from `src-tauri/icons/`:

| File | Resolution | Use |
|------|-----------|-----|
| `32x32.png` | 32x32 | Small icon (taskbar, small launcher grids) |
| `128x128.png` | 128x128 | Medium icon (launcher, Spotlight) |
| `icon.png` | 256x256+ | Large icon (high-DPI displays, app info) |
| `tray-icon.png` | Varies | System tray specifically |

For macOS, the install script converts PNGs to `.icns` format using `iconutil` or `sips` (both ship with macOS).

**Why not SVG for launchers:** The XDG icon theme spec supports SVG, but not all desktop environments render SVG icons reliably at all sizes. PNGs at standard resolutions are universally supported.

## Risks / Trade-offs

**[Linux DE fragmentation]** -- While XDG `.desktop` files are standard, some desktop environments (older XFCE, tiling WMs) may not scan `~/.local/share/applications/` or may require manual cache refresh. Mitigation: run `update-desktop-database` if available; document manual steps for niche environments.

**[macOS Gatekeeper]** -- Unsigned `.app` bundles from manual install will trigger Gatekeeper warnings. Mitigation: release builds should be signed (tracked separately in cosign-signing). Document the right-click > Open workaround for development builds.

**[Icon cache staleness]** -- On Linux, icon changes may not appear immediately without cache refresh. Mitigation: the install script runs `gtk-update-icon-cache` and `update-desktop-database` post-install.

**[Autostart cleanup on uninstall]** -- If the user enables autostart and then deletes the binary without running uninstall, the autostart entry will point to a missing executable. Mitigation: autostart entries should use absolute paths; desktop environments handle missing executables gracefully (silent failure on login).

## Open Questions

- Should the install script be a standalone `install.sh` / `install.ps1` at the repo root, or integrated into an existing build/release workflow?
- Should the `.desktop` file template be generated at build time (with the correct `Exec=` path baked in) or at install time (with path detection)?
