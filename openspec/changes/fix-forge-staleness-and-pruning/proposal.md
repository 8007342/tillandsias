## Why

The forge image staleness check has three issues: (1) the hash file is unversioned (`.last-build-forge.sha256`) but image tags are versioned (`tillandsias-forge:v0.1.97`), so the hash carries over across version bumps creating false "up to date" results; (2) the tray path skips the build script entirely when `image_exists` returns true, never checking for source staleness; (3) old forge images accumulate and waste disk space; (4) a newer forge image from a future version (e.g., built by a newer binary before downgrade) is ignored in favor of rebuilding.

## What Changes

- Version the hash file: `.last-build-forge-v0.1.97.sha256` so each version has its own staleness state
- Always invoke the build script (it handles staleness internally via hash check) — don't short-circuit in tray handlers
- Prune all older forge images after a successful build (keep only the current version + latest)
- Detect newer forge images: if a forge image exists with a higher version than expected, use it and log a warning

## Capabilities

### Modified Capabilities

- `forge-staleness`: Hash file versioned, tray always checks staleness
- `forge-pruning`: Old images cleaned up after build
- `forge-forward-compat`: Newer images used with warning

## Impact

- `scripts/build-image.sh` — version the hash file name
- `src-tauri/src/handlers.rs` — always invoke build script, prune after build, detect newer images
- `src-tauri/src/init.rs` — same pruning logic
- `crates/tillandsias-podman/src/client.rs` — add method to list/prune forge images by version
