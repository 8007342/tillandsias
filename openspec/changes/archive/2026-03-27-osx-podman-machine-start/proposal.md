# Proposal: Auto-start podman machine at launch

## Why

On macOS and Windows, podman requires a Linux VM (`podman machine`) to function. Currently, if the VM is not running when Tillandsias launches, the app drops into decay state and the user must manually start the machine via CLI. This is a poor experience -- most users expect the app to "just work" when podman is installed.

## What changes

- Add `start_machine()` method to `PodmanClient` in `tillandsias-podman`
- In `main.rs` startup sequence, detect the "podman installed but machine not running" case and auto-start the machine before computing `podman_usable`
- On success, proceed normally (bloom state). On failure, fall back to decay state with a warning log.

## Capabilities

- Silent auto-start of the podman VM -- no user interaction required
- Graceful fallback -- if machine start fails, behavior is identical to current decay state
- Only runs on platforms that need a podman machine (macOS, Windows)

## Impact

- `crates/tillandsias-podman/src/client.rs` -- new `start_machine()` method
- `src-tauri/src/main.rs` -- auto-start logic before `podman_usable` computation
- App startup may take 10-30 seconds longer on first launch if machine needs starting
