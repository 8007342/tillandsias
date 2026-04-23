# Logging Levels

## Overview

Tillandsias uses a structured logging system built on the `tracing` crate. Log output is always written to a file. When running in a terminal, it is also pretty-printed to stderr. Six user-facing module names map to Rust tracing targets; five log levels control verbosity per module. Accountability windows (`--log-secrets-management`, etc.) add a separate curated stderr layer that shows the "what and why" of sensitive operations in plain language.

## How It Works

### Configuration priority (highest to lowest)

```
1. --log=module:level;...   CLI flag
2. TILLANDSIAS_LOG          environment variable
3. RUST_LOG                 environment variable
4. tillandsias=info         built-in default
```

When `--log` is present, it takes full precedence over all environment variables for the modules it mentions. Modules not mentioned in `--log` keep the default (`info`).

Source: `src-tauri/src/logging.rs`
@trace spec:logging-accountability

### The nine modules

| Module | What it covers | Rust tracing targets |
|--------|---------------|----------------------|
| `secrets` | Keyring access, token file writes, cleanup | `tillandsias_tray::secrets`, `tillandsias_tray::launch` |
| `containers` | Container start/stop/destroy, podman command args | `tillandsias_tray::handlers`, `tillandsias_tray::launch`, `tillandsias_podman` |
| `updates` | Version check, download, apply, restart | `tillandsias_tray::updater`, `tillandsias_tray::update_cli`, `tillandsias_tray::update_log` |
| `scanner` | Filesystem watcher events, project discovery | `tillandsias_scanner` |
| `menu` | Tray menu builds, item rendering | `tillandsias_tray::menu`, `tillandsias_tray::event_loop` |
| `events` | Main event loop dispatch, podman container events | `tillandsias_tray::event_loop`, `tillandsias_podman::events` |
| `proxy` | Proxy container start/stop, health-check restart | `tillandsias_tray::handlers`, `tillandsias_tray::proxy` |
| `enclave` | Enclave network create/remove, shutdown lifecycle | `tillandsias_tray::handlers`, `tillandsias_tray::enclave` |
| `git` | Git mirror create, git service start/stop, push | `tillandsias_tray::handlers`, `tillandsias_tray::git` |

Source: `src-tauri/src/logging.rs` (`module_to_targets` function)
Source: `src-tauri/src/cli.rs` (`VALID_MODULES` constant)

### The five log levels

| Level | Shows | When to use |
|-------|-------|-------------|
| `off` | Nothing | Silence a noisy module entirely |
| `error` | Failures that impact user-visible behavior | Baseline for production issues |
| `warn` | Recoverable problems (fallback triggered, retry) | Understanding degraded state |
| `info` | Normal operational events (default) | Understanding what happened |
| `debug` | Detailed internal state, decision points | Debugging unexpected behavior |
| `trace` | Everything, including spec URLs via `@trace` annotations | Deep investigation, audit |

`trace` is the most verbose level. Every log event at this level includes spec references (e.g., `@trace spec:native-secrets-store`) that link to the OpenSpec design documents governing that behavior.

### Accountability windows

Accountability windows are a separate layer on top of the normal log levels. They intercept events tagged with `accountability = true` in the source code and render them in a curated, human-readable format to stderr. They activate specific modules at `info` level if those modules are not already set higher via `--log`.

| Flag | Module activated | What it shows |
|------|-----------------|---------------|
| `--log-secrets-management` | `secrets` | Token writes, keyring access, cleanup, refresh |
| `--log-image-management` | `containers` | Forge image build, pull, staleness detection (future) |
| `--log-update-cycle` | `updates` | Version check, download, verify, apply, restart (future) |
| `--log-proxy` | `proxy` | Proxy container start, stop, health-check restart |
| `--log-enclave` | `enclave` | Enclave network create, remove, shutdown lifecycle |
| `--log-git` | `git` | Git mirror create, git service start/stop, push operations |

Accountability output format:
```
[secrets] v0.1.97.76 | GitHub token retrieved from OS keyring
  -> Never written to disk, injected via GIT_ASKPASS
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Anative-secrets-store&type=code
```

Each line contains: `[category]`, the 4-part version, the event message, an optional safety note (what protection applies), and an optional `@trace` URL linking to the spec governing this behavior.

Source: `src-tauri/src/accountability.rs`

### How `--log` and `--log-*` combine

`--log` and `--log-*` flags are fully composable. They can be used together in any combination:

```
# Accountability window for secrets, plus trace-level detail for containers
tillandsias --log-secrets-management --log=containers:trace /path/to/project

# All modules at debug level
tillandsias --log=secrets:debug;containers:debug;updates:debug;scanner:debug;menu:debug;events:debug

# Silence scanner, trace secrets
tillandsias --log=scanner:off;secrets:trace
```

When `--log=secrets:trace` is combined with `--log-secrets-management`, the accountability layer shows the formatted summary and the trace layer shows the raw detailed events. Both are active simultaneously.

### Where log files live

The log file is always written, regardless of terminal mode.

| Platform | Log file path |
|----------|--------------|
| Linux | `~/.local/state/tillandsias/tillandsias.log` |
| macOS | `~/Library/Logs/tillandsias/tillandsias.log` |
| Windows | `%LOCALAPPDATA%\tillandsias\logs\tillandsias.log` |

The log file uses non-blocking writes via `tracing-appender`. The `WorkerGuard` returned by `logging::init()` must be held for the application's lifetime to ensure the file is flushed on shutdown.

Source: `crates/tillandsias-core/src/config.rs` (`log_dir` function)

## CLI Commands

```bash
# Watch secret lifecycle events (most common debugging command)
tillandsias --log-secrets-management

# Watch secret events with full trace detail (includes spec links)
tillandsias --log=secrets:trace --log-secrets-management

# Trace all container operations for a specific project attach
tillandsias --log=containers:trace /path/to/project

# Debug the filesystem scanner (why isn't my project showing up?)
tillandsias --log=scanner:debug

# Trace the event loop (all menu clicks, container state transitions)
tillandsias --log=menu:trace;events:trace

# Override via environment variable (useful for systemd or launchd service files)
TILLANDSIAS_LOG="tillandsias_tray=debug" tillandsias

# RUST_LOG works as a fallback (standard Rust logging)
RUST_LOG="tillandsias_tray::secrets=trace" tillandsias

# Follow the log file in real time
tail -f ~/.local/state/tillandsias/tillandsias.log          # Linux
tail -f ~/Library/Logs/tillandsias/tillandsias.log          # macOS
```

### Common debugging scenarios

| Problem | Recommended command |
|---------|---------------------|
| Git push fails inside container | `tillandsias --log-secrets-management /path/to/project` |
| Container doesn't start | `tillandsias --log=containers:debug /path/to/project` |
| Project not appearing in tray menu | `tillandsias --log=scanner:debug` |
| Tray menu items wrong / missing | `tillandsias --log=menu:debug` |
| Self-update failed | `tillandsias --log-update-cycle --update` |
| Proxy not caching / offline failures | `tillandsias --log-proxy /path/to/project` |
| Enclave network issues | `tillandsias --log-enclave /path/to/project` |
| Git mirror clone or push fails | `tillandsias --log-git /path/to/project` |
| Full enclave audit | `tillandsias --log-enclave --log-proxy --log-git /path/to/project` |
| Need everything for a bug report | `tillandsias --log=secrets:debug;containers:debug;events:debug;menu:debug` |

## Failure Modes

| Scenario | Symptom | Recovery |
|----------|---------|----------|
| Unknown module name in `--log=` | Warning to stderr: "Unknown log module: X. Valid modules: ..."; module is skipped | Check spelling against the six valid names |
| Invalid level name in `--log=` | Error to stderr: "Invalid log level: X"; module falls back to `info` | Check spelling against the five valid levels |
| Missing `:` in `--log=` pair | Warning to stderr: "Invalid log pair (expected module:level)"; pair is skipped | Use `module:level` format |
| Log directory creation fails | Error to stderr: "Failed to create log directory"; log file silently absent | Check permissions on `~/.local/state/`; create directory manually |
| `--log-*` flag used non-interactively | Accountability layer is suppressed (stderr is not a TTY) | Pipe through `cat` or redirect stderr to a file to see output |

## Security Model

Log files do not contain tokens, keys, or passwords. The logging system is designed so that:

- Accountability events show *what operation occurred* and *which spec governs it*, but never the token value itself.
- `trace`-level logs may include file paths (e.g., `token file written to /run/user/.../github_token`) but not file contents.
- The `safety` field in accountability output describes what protection applies (e.g., "Token stored in OS keyring, not written to disk").

If sharing a log file for support, no scrubbing is required for credentials. File paths and container names will be present.

**Known limitation:** If a third-party crate logs a secret at `error` or `warn` level (unusual but possible), it would appear in the log file. The Tillandsias codebase itself does not log secret values.

## Related

**Specs:**
- `openspec/changes/logging-accountability-framework/` — accountability layer design
- `openspec/changes/logging-cheatsheets/` — this cheatsheet system

**Source files:**
- `src-tauri/src/logging.rs` — subscriber initialization, `module_to_targets`, filter construction
- `src-tauri/src/accountability.rs` — `AccountabilityLayer` implementation, spec URL generation
- `src-tauri/src/cli.rs` — `VALID_MODULES`, `VALID_LEVELS`, `parse_log_flags`, CLI help text

**Cheatsheets:**
- `docs/cheatsheets/secrets-management.md` — secrets subsystem detail
- `docs/cheatsheets/token-rotation.md` — token refresh task detail
