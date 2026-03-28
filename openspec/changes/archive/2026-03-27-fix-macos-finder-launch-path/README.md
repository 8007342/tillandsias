# fix-macos-finder-launch-path

**Type:** Bug fix
**Status:** In progress
**Created:** 2026-03-27

## Summary

macOS apps launched from Finder/Launchpad do not inherit the shell PATH.
This means `podman` (installed via Homebrew at `/opt/homebrew/bin/`) is not
found when `build-image.sh` runs from the tray app, causing forge image
builds to fail silently.

MacPorts users are unaffected because MacPorts writes to `/etc/paths.d/`,
which macOS reads for all processes. Homebrew relies on shell profile
(`~/.zshrc`) additions only.

## Root Cause

`build-image.sh` calls bare `podman` commands. When the Finder-launched
tray app spawns this script, PATH is typically just
`/usr/bin:/bin:/usr/sbin:/sbin` -- missing `/opt/homebrew/bin`.

## Fix

1. Augment PATH at the top of `build-image.sh` with common macOS tool
   locations (`/opt/homebrew/bin`, `/opt/local/bin`, `/usr/local/bin`).
2. Pass the resolved podman absolute path from Rust (`find_podman_path()`)
   as `PODMAN_PATH` env var when spawning `build-image.sh` from handlers.rs
   and runner.rs.
3. In `build-image.sh`, use `$PODMAN_PATH` when set, falling back to bare
   `podman` (PATH lookup).
