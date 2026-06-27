# ZeroClaw Binary Not Installed to PATH

**Status:** `completed`
**Owner:** linux
**Date:** 2026-06-27
**Completed:** 2026-06-27

## Problem

ZeroClaw launch fails with:
```
error: project launch failed for 'java': failed to spawn tillandsias-zeroclaw: No such file or directory (os error 2)
```

`Command::new("tillandsias-zeroclaw")` in `tray/mod.rs:1627` looks up the
binary via `PATH`, but `tillandsias-zeroclaw` is never installed to
`~/.local/bin` or any other PATH location by the installer or `build.sh`.

## Fix Applied

Changed `launch_zeroclaw` in `tray/mod.rs` to resolve the binary as a sibling
of `std::env::current_exe()` first, falling back to PATH only if the sibling
is not found. This works for:
- Installed release: `~/.local/bin/tillandsias` + `~/.local/bin/tillandsias-zeroclaw`
- Dev builds: `target/debug/tillandsias` + `target/debug/tillandsias-zeroclaw`

The installer (`scripts/install.sh`) still needs to copy `tillandsias-zeroclaw`
alongside the main binary — see the follow-on work packet below.

## Follow-On Required

The release workflow and `scripts/install.sh` must:
1. Build `tillandsias-zeroclaw` in the release step
2. Bundle it in the release artifact tarball / GitHub release asset
3. Install it to `~/.local/bin/tillandsias-zeroclaw` alongside `tillandsias`

Until the release bundles the zeroclaw binary, it will only work in dev builds.
File as a separate release-packaging packet if needed.
