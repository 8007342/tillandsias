## Context

The build-image.sh script has a hash-based staleness check that hashes source files and compares to a cached hash. The hash file name is `.last-build-forge.sha256` (unversioned), but the image tag is versioned (e.g., `tillandsias-forge:v0.1.97`). When the version bumps, the old hash file persists and can cause false "up to date" results if source files haven't changed between versions.

The tray handlers check `image_exists` and skip the build entirely if true. This means source staleness is never checked from the tray path — only the CLI path (`tillandsias .`) always invokes the build script.

## Goals / Non-Goals

**Goals:**
- Hash file versioned so each app version has independent staleness state
- Tray always invokes build script for staleness check (script handles fast-exit)
- Old forge images pruned after successful build
- Newer forge images detected and used (forward compatibility)

**Non-Goals:**
- Changing the Nix build pipeline
- Adding a UI for image management

## Decisions

**Version the hash file**: Append the image tag to the hash file name: `.last-build-forge-v0.1.97.sha256`. The build script already receives `--tag`, so it can derive the suffix.

**Always invoke build script from tray**: The build script's staleness check is fast (hash comparison + image exists). Removing the Rust-side `image_exists` short-circuit ensures staleness is always checked.

**Prune after build**: After a successful `build-image.sh` run, call `prune_old_forge_images()` which removes all `tillandsias-forge:v*` images except the current tag. This already exists as a function — just needs to be called consistently.

**Detect newer images**: Before building, list all `tillandsias-forge:v*` images, parse versions, and if any is newer than the expected tag, use that tag instead and warn. This handles the case where a newer binary built a newer image before the user downgraded.

## Risks / Trade-offs

- [Risk] Always invoking build script adds ~100ms to tray launch (hash computation). Mitigation: acceptable for correctness; the script exits fast when up to date.
