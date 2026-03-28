## Why

When podman is unavailable (not installed, or machine not running on macOS/Windows), the podman events listener enters a tight ~1s retry loop that spams logs, wastes CPU, and on Windows makes the tray icon flicker so fast users can't click "Quit" and must kill via Task Manager. Three root causes:

1. **Events stream starts unconditionally** — even when startup detected `has_podman = false`
2. **Reconnect check is wrong** — `backoff_inspect()` tests `podman events --help` which succeeds even when the podman machine isn't running, so it returns immediately and the outer loop restarts `stream_events()` which fails instantly → 1s cycle
3. **Missing macOS path** — `find_podman_path()` doesn't check `/opt/local/bin/podman` (MacPorts) or `/opt/homebrew/bin/podman` (Homebrew on Apple Silicon)

## What Changes

- Don't start podman events stream when podman is unavailable
- Fix `backoff_inspect()` reconnect check to verify podman is actually usable (not just that the binary exists)
- Add proper exponential backoff in the outer `stream()` loop itself
- Add `/opt/homebrew/bin/podman` and `/opt/local/bin/podman` to path detection
- Cap max backoff at a reasonable ceiling and log at reduced frequency

## Capabilities

### Modified Capabilities
- `podman-events`: Resilient event streaming with proper exponential backoff when podman is unavailable
- `podman-detection`: Extended path detection for macOS package managers

## Impact

- Modified: `crates/tillandsias-podman/src/events.rs` (backoff in outer loop, better reconnect check)
- Modified: `crates/tillandsias-podman/src/lib.rs` (add macOS paths)
- Modified: `src-tauri/src/main.rs` (skip events stream when no podman)
- No new files
