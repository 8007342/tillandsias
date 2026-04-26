# appimage-builder-source-slim

## Why

The AppImage build script (`build.sh --install`) copies the entire workspace
into the Ubuntu builder container before invoking `cargo tauri build`. On
this developer's machine the copy step takes ~5 minutes, dominated by a
**47 GB `target/` directory** and a **1.5 GB `.git/` directory** that the
builder never reads — its own `target/` is built fresh from source inside
`/build/target/` (different glibc, different rustc, no overlap with the
host's incremental cache).

Source actually needed by the builder is **17 MB**. The current copy is
therefore **3000× larger than necessary** and runs on every build. With a
warm cargo cache, the wasteful `cp -r /src /build` step is the single
slowest part of the pipeline.

## What Changes

- `build.sh` replaces the unfiltered `cp -r /src /build` with a
  `tar … --exclude=… | tar -x` pipe that omits `target/`, `.git/`,
  `.nix-output/`, `.claude/`, `.opencode/`, `node_modules/`, and any
  `*.AppImage` artefact.
- The exclude list is sourced from a single declaration so the spec, the
  test, and the script agree.
- A new spec capability `appimage-build-pipeline` formalises the rule
  ("source copy MUST exclude artefact directories") and pins the maximum
  allowed copy size at **150 MB** (10× headroom over today's 17 MB) so
  drift is caught loudly.
- `tar` is a default-installed binary in `ubuntu:22.04`, so no extra
  package install is needed in the builder. `rsync` was considered but
  rejected because it isn't in the upstream image.

## Impact

- Affected specs: `appimage-build-pipeline` (new capability)
- Affected code: `build.sh`
- Wall-clock saving: ~5 min per build on this developer's machine; bigger
  on machines with even more cached artefacts
- Disk pressure: builder no longer writes 47 GB into its overlay layer per
  build, which previously also created kernel cache pressure
- Backwards compatibility: none affected — the omitted directories are
  build outputs / VCS metadata, never read by the builder
