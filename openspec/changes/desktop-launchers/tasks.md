## 1. Linux Desktop Integration

- [ ] 1.1 Create `.desktop` file template at `assets/tillandsias.desktop` with `Name=Tillandsias`, `Comment=Local development environments that just work`, `Exec=tillandsias-tray`, `Icon=tillandsias-tray`, `Terminal=false`, `Type=Application`, `Categories=Development;`, `StartupWMClass=tillandsias-tray`
- [ ] 1.2 Write install script logic to copy `.desktop` file to `~/.local/share/applications/tillandsias.desktop`, substituting the correct `Exec=` path based on the installed binary location
- [ ] 1.3 Write install script logic to copy icon PNGs from `src-tauri/icons/` to `~/.local/share/icons/hicolor/{32x32,128x128,256x256}/apps/tillandsias-tray.png`
- [ ] 1.4 Run `gtk-update-icon-cache ~/.local/share/icons/hicolor/` and `update-desktop-database ~/.local/share/applications/` post-install if commands are available
- [ ] 1.5 Write uninstall script logic to remove the `.desktop` file, icon files at all resolutions, and refresh caches

## 2. macOS Desktop Integration

- [ ] 2.1 Create `.app` bundle directory structure template: `Tillandsias.app/Contents/{MacOS,Resources}/` with `Info.plist`
- [ ] 2.2 Write `Info.plist` template with `CFBundleName=Tillandsias`, `CFBundleIdentifier=com.tillandsias.tray`, `CFBundleIconFile=tillandsias.icns`, `LSUIElement=true` (agent app, no dock icon)
- [ ] 2.3 Write install script logic to convert PNGs to `.icns` using `iconutil` or `sips`, place binary in `Contents/MacOS/`, and copy bundle to `~/Applications/`
- [ ] 2.4 Write uninstall script logic to remove `~/Applications/Tillandsias.app`

## 3. Windows Desktop Integration

- [ ] 3.1 Write PowerShell install script to create Start Menu shortcut at `$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk` using COM WScript.Shell object
- [ ] 3.2 Ensure NSIS/MSI installer configuration (Tauri bundler) creates Start Menu shortcut with the tillandsia icon
- [ ] 3.3 Write PowerShell uninstall script to remove the Start Menu shortcut

## 4. Autostart on Login

- [ ] 4.1 Add `autostart = false` default to the global config template at `~/.config/tillandsias/config.toml`
- [ ] 4.2 Implement Linux autostart: create/remove `~/.config/autostart/tillandsias.desktop` based on config setting
- [ ] 4.3 Implement macOS autostart: create/remove `~/Library/LaunchAgents/com.tillandsias.tray.plist` based on config setting
- [ ] 4.4 Implement Windows autostart: create/remove `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\Tillandsias` registry entry based on config setting
- [ ] 4.5 Ensure uninstall scripts remove autostart entries on all platforms regardless of current config setting

## 5. Install and Uninstall Scripts

- [ ] 5.1 Create `scripts/install.sh` handling Linux and macOS desktop integration (detect platform, run appropriate steps)
- [ ] 5.2 Create `scripts/install.ps1` handling Windows desktop integration (Start Menu shortcut, optional autostart)
- [ ] 5.3 Create `scripts/uninstall.sh` handling Linux and macOS cleanup (desktop files, icons, autostart entries, cache refresh)
- [ ] 5.4 Create `scripts/uninstall.ps1` handling Windows cleanup (Start Menu shortcut, autostart registry entry)
- [ ] 5.5 Ensure all scripts are idempotent: repeated runs do not produce errors or duplicate entries
- [ ] 5.6 Test install/uninstall cycle on each platform: verify launcher entry appears, launches tray app correctly, and is fully removed on uninstall
