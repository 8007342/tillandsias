## Why

The tray app currently has debug-only tracing behind `#[cfg(debug_assertions)]`. In release builds, there's zero observability — container launches, stops, failures, scanner events all happen silently. Developers need structured logs to diagnose issues, and the foundation should support OpenTelemetry for future production telemetry.

## What Changes

- Enable `tracing` in release builds, not just debug
- When launched from terminal (`tillandsias`), attach log output to stderr so the terminal shows what's happening
- When launched from desktop/tray (no terminal), write logs to `~/.local/state/tillandsias/tillandsias.log` (ephemeral, safe to delete)
- Add structured log events for all container lifecycle operations (build, start, stop, destroy, error)
- Add modular log configuration via `TILLANDSIAS_LOG` env var (like `RUST_LOG`)
- Prepare OpenTelemetry-compatible span structure (tracing already supports this via `tracing-opentelemetry`, wire it later)

## Capabilities

### New Capabilities
- `runtime-logging`: Structured logging with tracing, file + terminal output, modular config

### Modified Capabilities
- `tray-app`: Initialize logging in both debug and release builds

## Impact

- New dependency: `tracing-appender` for file logging
- Modified: `src-tauri/src/main.rs` — logging init for release builds
- Modified: all handler/lifecycle code — add info/warn/error spans for container operations
- New: `~/.local/state/tillandsias/tillandsias.log` (ephemeral log file)
- Env var: `TILLANDSIAS_LOG=tillandsias=info,tillandsias_podman=debug`
