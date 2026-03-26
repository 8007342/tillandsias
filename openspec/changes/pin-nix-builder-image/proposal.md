## Why

The `nixos/nix:latest` tag can change at any time. A breaking Nix release could silently break the forge image build for all users. Since we already pin Nix inputs via `flake.lock`, pinning the builder image version completes the reproducibility picture.

The "56 years ago" creation date is intentional (Nix sets timestamps to epoch for reproducibility) and NOT a problem.

## What Changes

- Pin `docker.io/nixos/nix:latest` to `docker.io/nixos/nix:2.34.4` in `scripts/build-image.sh`
- Add a comment explaining why it's pinned and how to update

## Capabilities

### New Capabilities

### Modified Capabilities

## Impact

- **Modified file**: `scripts/build-image.sh` — one line change
- **Risk**: if 2.34.4 is eventually removed from Docker Hub, the build will fail with a clear "image not found" error (easily fixed by bumping the pin)
