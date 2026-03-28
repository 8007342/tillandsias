# Fix macOS OS Detection

## Why

When launching a forge environment on macOS, the welcome message shows "Unknown OS" because `detect_host_os()` only reads `/etc/os-release`, which does not exist on macOS. This produces a confusing `TILLANDSIAS_HOST_OS='Unknown OS'` env var passed to the forge.

## What Changes

- `crates/tillandsias-core/src/config.rs` — `detect_host_os()` gains a macOS-specific branch that runs `sw_vers -productVersion` to get the version number and returns "macOS <version>" (e.g., "macOS 15.4").
- The macOS check uses `cfg!(target_os = "macos")` and is evaluated before the Linux `/etc/os-release` path.

## Capabilities

- Forge welcome message correctly displays "macOS <version>" on macOS hosts.
- Linux detection remains unchanged.
- Falls back to "Unknown OS" only when neither macOS nor `/etc/os-release` applies.

## Impact

- Single function change in `tillandsias-core`.
- No API changes. No new dependencies.
- All downstream callers (`handlers.rs`, `runner.rs`) benefit automatically.
