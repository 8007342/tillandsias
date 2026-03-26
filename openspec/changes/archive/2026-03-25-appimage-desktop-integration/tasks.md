## 1. Desktop Integration Module

- [ ] 1.1 Create `src-tauri/src/desktop.rs` with `ensure_desktop_integration()` function
- [ ] 1.2 Detect AppImage via `std::env::var("APPIMAGE")`
- [ ] 1.3 Write `.desktop` file to `~/.local/share/applications/tillandsias.desktop`
- [ ] 1.4 Write icon PNGs (32x32, 128x128, 256x256) to hicolor icon theme directories
- [ ] 1.5 Run `update-desktop-database` and `gtk-update-icon-cache`
- [ ] 1.6 Staleness check: only write if `.desktop` missing or `Exec=` path changed

## 2. Main Integration

- [ ] 2.1 Add `mod desktop;` to `main.rs`
- [ ] 2.2 Call `desktop::ensure_desktop_integration()` after CLI parsing, before tray setup

## 3. install.sh Fix

- [ ] 3.1 Add 256x256 icon installation to the icon loop in `scripts/install.sh`

## 4. Verification

- [ ] 4.1 `./build.sh --check` passes
