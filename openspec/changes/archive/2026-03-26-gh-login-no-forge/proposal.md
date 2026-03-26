## Why

When a user clicks "GitHub Login" from the tray on a fresh installation, the forge image has not been built yet. The `gh-auth-login.sh` script is extracted from the binary and run directly in a terminal — but it fails immediately:

```
[gh-auth] Forge image not found: tillandsias-forge:latest
[gh-auth] Cannot find build-image.sh. Run: ./build.sh --install
```

The script searches for `build-image.sh` in `$SCRIPT_DIR/scripts/` and `~/.local/share/tillandsias/scripts/`. Neither exists at runtime because the embedded script has no knowledge of the binary's internal build pipeline. The user is stuck with no path forward.

This is a first-run blocker: GitHub Login is the first thing a user does, and it fails before the forge image is ever built.

## What Changes

- `handle_github_login()` in `handlers.rs` gains a `build_tx` parameter (matching `handle_attach_here`)
- Before extracting and running `gh-auth-login.sh`, the handler checks whether the forge image exists
- If the image is missing, it builds it first using the existing `run_build_image_script("forge")` with build lock, emitting `BuildProgressEvent::Started/Completed/Failed` chips exactly like Attach Here does
- Only after the image is confirmed present does the handler open the terminal with `gh-auth-login.sh`
- `event_loop.rs` is updated to pass `build_tx.clone()` to `handle_github_login`

The `gh-auth-login.sh` script itself is unchanged — the image-present check in the script becomes a no-op because the handler guarantees the image exists before the script runs.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `gh-auth-script`: GitHub Login now works on first run without a pre-built forge image

## Impact

- **Modified files**: `src-tauri/src/handlers.rs`, `src-tauri/src/event_loop.rs`
- **Unchanged**: `gh-auth-login.sh` — script logic untouched, just its failure path becomes unreachable
- No user-visible change on subsequent runs (image already present, build step skipped)
- On first run: user sees "Building environment..." chip in tray before the login terminal opens
