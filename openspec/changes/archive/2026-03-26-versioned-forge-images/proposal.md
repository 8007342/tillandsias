## Why

The forge image is tagged `tillandsias-forge:latest`. When the app auto-updates to a new version with a different entrypoint or config, the old image is reused because the staleness detection hash file lives in a temp dir that does not persist across restarts. Users get stale containers with old entrypoints, causing silent breakage that is difficult to diagnose.

## What Changes

- **Dynamic image tag**: Replace the static `FORGE_IMAGE_TAG` constant with a `forge_image_tag()` function that derives the tag from `CARGO_PKG_VERSION` at compile time (e.g., `tillandsias-forge:v0.1.72`)
- **build-image.sh `--tag` flag**: Accept an optional `--tag <tag>` argument so the Rust code can request a specific versioned tag; falls back to `:latest` for manual/dev use
- **Old version pruning**: After a successful versioned build, remove older `tillandsias-forge:v*` images to reclaim disk space
- **Launch-time check simplified**: Check for the exact versioned tag. If absent, build it. Detect whether ANY `tillandsias-forge:v*` image exists to distinguish "first time" from "update" for user-facing messaging
- **All call sites updated**: Every reference to the old constant replaced with the `forge_image_tag()` function call

## Capabilities

### New Capabilities
- `versioned-forge-images`: Forge images are tagged with the app's semver version, ensuring version-locked containers and automatic rebuilds on app update

### Modified Capabilities
- `forge-image-build`: build-image.sh accepts `--tag` for caller-specified tags
- `forge-image-check`: Launch-time check uses versioned tag; distinguishes first-time from update builds
- `old-image-pruning`: Stale versioned images are pruned after successful builds

## Impact

- **New files**: None
- **Modified files**:
  - `src-tauri/src/handlers.rs` -- `FORGE_IMAGE_TAG` constant replaced with `forge_image_tag()` function; all usages updated; pruning logic added to `run_build_image_script`
  - `src-tauri/src/main.rs` -- launch-time image check uses `forge_image_tag()`; "Building Forge" vs "Building Updated Forge" messaging
  - `src-tauri/src/init.rs` -- `FORGE_IMAGE` constant replaced with `forge_image_tag()` call
  - `src-tauri/src/runner.rs` -- `image_tag()` function uses versioned tag for forge images
  - `src-tauri/src/github.rs` -- imports updated from constant to function
  - `scripts/build-image.sh` -- accepts `--tag <tag>` argument, uses it for image tagging
