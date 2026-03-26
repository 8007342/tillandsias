## Why

Tillandsias currently supports three Linux distribution formats: .deb (via APT repository), .rpm (via COPR and direct download), and AppImage. Maintaining all three creates significant complexity:

- An entire APT repository infrastructure on GitHub Pages (GPG signing, package metadata, gh-pages branch)
- A COPR custom source pipeline (spec file, download script, repackaging)
- Fallback logic in the installer that tries deb/rpm first with sudo, then falls back to AppImage
- The install script must detect package managers, check sudo availability, handle immutable OS routing, and manage multiple error paths

Meanwhile, the AppImage path already works everywhere: no root required, no package manager dependency, auto-updates via the Tauri updater, and works on both mutable and immutable Linux distributions including Silverblue. It is the simplest, most universal option.

## What Changes

- **`scripts/install.sh`**: Remove deb/rpm/APT/COPR/dnf/dpkg logic. Linux path becomes: detect immutable OS (cosmetic message), download AppImage, install to ~/.local/bin/, desktop integration. No sudo needed.
- **`.github/workflows/release.yml`**: Remove deb/rpm from artifact collection. Remove the entire "Publish APT repository" job. Keep AppImage, its .sig, Cosign signing, and all macOS/Windows artifacts unchanged.
- **`build.sh`**: Change `BUNDLES="deb,rpm"` to `BUNDLES="none"` since AppImage is built via the separate `--appimage` path. Local `--release` produces the raw binary only, which is fine for dev.
- **`src-tauri/tauri.conf.json`**: Remove the `linux.deb` and `linux.rpm` configuration sections since those bundles are no longer produced.
- **`docs/UPDATING.md`**: Remove "Fedora (COPR)", "Fedora Silverblue (COPR)", and "Manual RPM / DEB" sections. AppImage auto-updates via the Tauri updater.
- **`packaging/`**: Delete the entire directory (tillandsias.spec, copr-custom-script.sh, COPR-SETUP.md). No longer needed.

## Capabilities

### Modified Capabilities
- `ci-release`: Linux build produces only AppImage; APT repo publishing removed
- `dev-build`: local `--release` skips deb/rpm bundles
- `update-system`: Linux users update exclusively through the Tauri auto-updater

### Removed Capabilities
- APT repository publishing (GitHub Pages)
- COPR repository integration
- Native .deb and .rpm package distribution

## Impact

- **Modified files**: `scripts/install.sh`, `.github/workflows/release.yml`, `build.sh`, `src-tauri/tauri.conf.json`, `docs/UPDATING.md`
- **Deleted files**: `packaging/tillandsias.spec`, `packaging/copr-custom-script.sh`, `packaging/COPR-SETUP.md`
- **Deleted directory**: `packaging/`
- **No new files**
- **macOS and Windows paths are completely unchanged**
