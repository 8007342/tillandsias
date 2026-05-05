# Tillandsias Logging Levels and Configuration

**Use when**: Configuring log verbosity, enabling accountability windows, or troubleshooting application behavior.

## Provenance

- https://docs.rs/tracing/latest/tracing/#levels — Rust tracing levels specification
- https://docs.rs/tracing-subscriber/latest/tracing_subscriber/#filtering-spans-and-events — Tracing subscriber filtering
- **Last updated:** 2026-04-27

## Log Levels

Tillandsias uses the standard Rust tracing levels from most to least verbose:

| Level | Symbol | Use Case | Volume |
|-------|--------|----------|--------|
| **TRACE** | `T` | Low-level implementation details (algorithm flow, loop iterations) | Very high; avoid in production |
| **DEBUG** | `D` | Development diagnostics (variable values, function entry/exit) | High; useful for bug reproduction |
| **INFO** | `I` | General informational messages (container started, token retrieved) | Medium; production default |
| **WARN** | `W` | Potential issues that don't stop operations (missing optional file, deprecated API) | Low; always investigate |
| **ERROR** | `E` | Serious failures that stop operations (network error, auth failure) | Very low; critical |

## Default Logging Configuration

By default, Tillandsias logs at **INFO level** to:
- **File**: `~/.local/share/Tillandsias/tillandsias.log` (or Windows equivalent)
- **Stderr**: Only when running in a terminal

File logs never rotate; they grow monotonically. On startup, events are appended to the existing log file.

## Controlling Log Verbosity

### CLI Flag: `--log=module:level`

Enable specific log levels for individual modules (highest priority):

```bash
# Enable debug for the secrets module
tillandsias --log=secrets:debug

# Enable trace for handlers and podman, info for everything else
tillandsias --log=handlers:trace,podman:trace

# Multiple modules, different levels
tillandsias --log=secrets:warn,containers:debug,updates:info
```

Available modules:
- `secrets` — Secret retrieval, OAuth token management
- `containers` — Container lifecycle (launch, stop, destroy)
- `updates` — Update checking and installation
- `scanner` — Filesystem watching and project discovery
- `menu` — Tray menu interactions
- `events` — Container events and state machine transitions
- `proxy` — Proxy container setup and maintenance
- `enclave` — Enclave network configuration
- `git` — Git mirror service and auto-sync

### Environment Variables

If no `--log` flag is provided, Tillandsias checks:

1. **`TILLANDSIAS_LOG`** — Tillandsias-specific filter (same format as `--log`)
   ```bash
   export TILLANDSIAS_LOG=secrets:debug
   tillandsias
   ```

2. **`RUST_LOG`** — Standard Rust logging filter (lower priority)
   ```bash
   export RUST_LOG=tillandsias=debug
   tillandsias
   ```

3. **Default**: `tillandsias=info` (if neither variable is set)

### Accountability Windows

Accountability windows enable curated high-signal logging for sensitive operations:

```bash
# Log all secret management operations to stderr and file
tillandsias --log-secrets-management

# Log container lifecycle in detail
tillandsias --log-image-management

# Log update cycle (checking, downloading, installing)
tillandsias --log-update-cycle

# Log proxy container setup
tillandsias --log-proxy-management

# Log enclave network configuration
tillandsias --log-enclave-management

# Log git mirror service
tillandsias --log-git-management

# Combine multiple windows
tillandsias --log-secrets-management --log-update-cycle
```

## Output Destinations

### File Log

**Path**: `~/.local/share/Tillandsias/tillandsias.log` (Linux)
- `~/Library/Application Support/Tillandsias/tillandsias.log` (macOS)
- `%LOCALAPPDATA%\Tillandsias\tillandsias.log` (Windows)

**Format**: Compact single-line per event with deduplication:
```
2026-04-27T16:49:44Z  INFO secrets: GitHub token retrieved {container=tillandsias-myapp-aeranthos}
2026-04-27T16:49:45Z  INFO [secrets] Token cached for next 24 hours
  -> Prevents repeated OS keyring lookups
  @trace spec:native-secrets-store
```

**Retention**: Logs never rotate; they grow indefinitely. Manually delete if they exceed a few MB.

### Stderr (Terminal Only)

When running in a terminal, logs also stream to stderr with:
- ANSI color codes (errors red, warnings yellow, etc.)
- Same compact format as file logs
- Deduplication across both file and stderr

Closed terminal (broken pipe) does not crash the application.

### Windows Event Log

**Windows-only**: Errors, warnings, and accountability events also write to the Windows Event Log, visible in Event Viewer.

- **Application**: Application
- **Source**: Tillandsias
- **Path in UI**: Event Viewer > Windows Logs > Application > Filter by Source "Tillandsias"

See `cheatsheets/runtime/windows-event-viewer.md` for detailed Event Viewer instructions.

## Examples

### Troubleshoot container startup

```bash
# Debug container launch and podman events
tillandsias --log=containers:debug,events:debug
```

Then trigger a container launch (e.g., "Attach Here" in the tray) and watch the logs.

### Monitor secret operations

```bash
# Curated secrets log to stderr
tillandsias --log-secrets-management
```

Output shows token retrieval, keyring interactions, and safety notes.

### Production operation

```bash
# Default: info level, only errors and warnings visible
tillandsias
```

File log grows slowly with high-signal events. Check `~/.local/share/Tillandsias/tillandsias.log` only when debugging.

## Deduplication

Identical log messages within a 30-second window are suppressed and counted as "repeated N times (Xs)":

```
2026-04-27T16:49:44Z  WARN podman: Container timeout waiting for health check {timeout_ms=5000}
  ... repeated 3 times (15s)
```

This prevents log spam from polling loops or repeated failures. The suppressed count and elapsed time help detect systemic issues.

## Related Cheatsheets

- `runtime/windows-event-viewer.md` — Windows Event Log access and filtering
- `runtime/external-logs.md` — Locating and sharing logs for support

@trace spec:logging-accountability
