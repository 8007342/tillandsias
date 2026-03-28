# fix-forge-image-persistence

**Status**: Proposed
**Type**: Bug fix
**Severity**: High (user-facing, causes ~50s delay on every launch)

## Problem

On macOS, the forge container image (`tillandsias-forge:v<version>`) is rebuilt on
every app launch even though it was built on the previous launch and should persist
inside the podman machine VM.

## Root Cause

See `proposal.md` for detailed analysis. Two contributing factors identified:

1. **Race condition**: `podman machine start` returns before the API socket is
   fully ready. The subsequent `podman image exists` call fails because podman
   cannot communicate with the VM yet, returning false and triggering an
   unnecessary rebuild.

2. **Staleness hash lost**: The build script's staleness hash file is written
   inside the embedded temp directory (`$TMPDIR/tillandsias-embedded/image-sources/.nix-output/`),
   which is deleted by `cleanup_image_sources()` after every build. This means
   `build-image.sh` can never short-circuit via its own staleness check.

## Files

- `proposal.md` -- Detailed investigation and proposed fix
- `tasks.md` -- Implementation checklist
