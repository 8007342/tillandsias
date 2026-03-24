## Why

First-time users hit a multi-minute wait when they click "Attach Here" because the forge image needs to build (Nix download + podman load). This kills the "just works" promise. A `tillandsias init` command that pre-builds images in the background — triggered automatically by the installer — means images are ready before the user ever opens the tray.

Additionally, if the app launches while `init` is still building, it should detect the in-progress build and wait for it instead of starting a duplicate.

## What Changes

- **`tillandsias init` CLI command** — builds the forge image (and any other images) in the foreground with progress output. Idempotent (skips if already built).
- **Installer integration** — `install.sh` runs `tillandsias init &` as a background task after installing the binary, so images build while the user reads the "Run: tillandsias" message.
- **Build lock detection** — before starting an image build, check for a lock file (`$XDG_RUNTIME_DIR/tillandsias/build-forge.lock`). If present and the PID is alive, wait for the existing build instead of starting a new one.
- **Tray app awareness** — on startup, if the forge image doesn't exist, check if an init build is running and show "Building environment..." in the tray instead of blocking.

## Capabilities

### New Capabilities
- `init-command`: CLI `tillandsias init` that pre-builds all container images
- `build-lock`: Lock file coordination to prevent duplicate builds

### Modified Capabilities
- `dev-build`: `build.sh --install` mentions `tillandsias init` in post-install message
- `tray-app`: Tray shows build status if init is running on startup

## Impact

- **Modified files**: `src-tauri/src/cli.rs` (new `init` mode), `src-tauri/src/main.rs` (dispatch init), `src-tauri/src/handlers.rs` (build lock check), `src-tauri/src/runner.rs` (build lock check), `scripts/install.sh` (background init)
- **New file**: `src-tauri/src/init.rs` (init command implementation with build lock)
