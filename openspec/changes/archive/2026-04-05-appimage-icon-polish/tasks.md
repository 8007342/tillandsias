## 1. Icon Improvements

- [x] 1.1 Verify icon.png (256x256) has proper transparency and is high quality
- [x] 1.2 Add AppStream metadata file for software center integration
- [x] 1.3 Desktop-template.desktop Icon={{icon}} is correct — Tauri fills with binary name

## 2. Tauri AppImage Configuration

- [x] 2.1 Verified: Tauri bundler automatically copies icon to AppDir root (.DirIcon + <name>.png)
- [x] 2.2 Verified: linuxdeploy.rs copies largest icon to AppDir/.DirIcon and <productName>.png
- [x] 2.3 Note: GNOME Nautilus does NOT read AppImage embedded icons — this is a GNOME limitation, not a bug

## 3. Verification

- [x] 3.1 cargo check passes
- [ ] 3.2 Build release, download AppImage, verify icon when desktop-integrated
