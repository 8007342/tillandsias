# Proposal: Fix macOS Finder Launch PATH Issue

## Problem

When Tillandsias is launched from Finder/Launchpad on macOS, the forge image
build fails because `podman` is not in PATH. Finder-launched apps get a
minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) that does not include
Homebrew (`/opt/homebrew/bin`) or other common tool locations.

The Rust code already handles this correctly via `find_podman_path()` which
checks absolute paths. However, `build-image.sh` uses bare `podman` commands
throughout.

## Approach

### Layer 1: PATH augmentation in build-image.sh

Add a PATH augmentation block near the top of `build-image.sh` that appends
common macOS tool directories. This is guarded by `[[ "$(uname -s)" == "Darwin" ]]`
so Linux builds are unaffected.

### Layer 2: PODMAN_PATH environment variable

The Rust code in `handlers.rs` and `runner.rs` that spawns `build-image.sh`
will pass `PODMAN_PATH=<absolute-path>` as an environment variable. The
script will use this when available, providing a guaranteed correct path
from the Rust binary's own podman discovery logic.

### Layer 3: Script-level podman resolution

`build-image.sh` will define a `PODMAN` variable at the top: use
`$PODMAN_PATH` if set, otherwise check known absolute paths, otherwise
fall back to bare `podman`.

## Constraints

- Must work for both Homebrew (`/opt/homebrew/bin`) and MacPorts (`/opt/local/bin`)
- Must NOT change Linux behavior
- Minimal changes -- no refactoring
