## Why

AppImages can only be built in CI (GitHub Actions on Ubuntu with FUSE). Local development on Fedora Silverblue cannot produce AppImages because Tauri's linuxdeploy bundler requires FUSE, which is unavailable inside the toolbox. Developers need to push to CI and wait for a full release just to test an AppImage locally.

## What Changes

- Add `--appimage` flag to `build.sh` that produces a local AppImage under `target/release/bundle/appimage/`
- Bypass Tauri's linuxdeploy by manually assembling an AppDir from the release build output
- Use a static `appimagetool` binary (no FUSE required) to pack the AppDir into an AppImage
- Download `appimagetool` on first use, cache in `~/.cache/tillandsias/`

## Capabilities

### New Capabilities
- `local-appimage-build`: Build a functional AppImage locally without FUSE, using a post-build AppDir assembly step

### Modified Capabilities

## Impact

- **Modified file**: `build.sh` — add `--appimage` flag handling
- **New dependency**: `appimagetool` (static binary, downloaded and cached on first use)
- **Output**: `target/release/bundle/appimage/Tillandsias-linux-x86_64.AppImage`
- **Existing flags unaffected**: `--release` continues to produce deb/rpm only
