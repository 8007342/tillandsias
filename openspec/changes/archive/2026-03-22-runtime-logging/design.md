## Context

The `tracing` crate is already a workspace dependency. All crates already have `debug!`, `info!`, `warn!` calls. But the subscriber is only initialized in debug builds. We need to enable it in release builds too, with smart output routing.

## Goals / Non-Goals

**Goals:**
- Logs visible in terminal when launched from CLI
- Logs written to file when launched from tray/desktop
- `TILLANDSIAS_LOG` env var for module-level filtering
- Structured spans for container lifecycle (build/start/stop/destroy)
- Foundation for OpenTelemetry (tracing spans are OTel-compatible)

**Non-Goals:**
- OTel collector/exporter (future)
- Log rotation (ephemeral logs, user can delete anytime)
- Remote logging/metrics
- GUI log viewer

## Decisions

### D1: Dual output — terminal + file

Detect if stderr is a TTY (`atty::is(Stream::Stderr)` or `std::io::stderr().is_terminal()`). If yes, log to stderr (pretty format). Always also log to file at `~/.local/state/tillandsias/tillandsias.log`.

### D2: Log location

`~/.local/state/` is the XDG standard for ephemeral runtime state. Logs are safe to delete anytime. On macOS: `~/Library/Logs/tillandsias/`. On Windows: `%LOCALAPPDATA%/tillandsias/logs/`.

### D3: TILLANDSIAS_LOG env var

Uses `tracing_subscriber::EnvFilter`. Default: `tillandsias=info`. Overridable via `TILLANDSIAS_LOG=tillandsias=debug,tillandsias_podman=trace`.

### D4: Lifecycle spans

Every container operation gets a tracing span with structured fields:
- `container.name`, `container.project`, `container.genus`
- `image.tag`, `image.build_duration`
- `operation` (build/start/stop/destroy)
- Error details on failure
