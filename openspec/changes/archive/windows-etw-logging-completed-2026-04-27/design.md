## Context

Tillandsias is a system tray application — on Windows, it hides its console window via `FreeConsole()` when launched without CLI arguments. This means errors during normal tray operation are invisible to the user. The only diagnostic path today is manually locating `%LOCALAPPDATA%\Tillandsias\tillandsias.log`.

Windows provides two standard mechanisms for application event reporting:

1. **Windows Event Log (legacy)** — The `ReportEvent` API writes entries to Event Viewer under Application log. Requires an event source registered in the registry. Simple, visible in Event Viewer by default.

2. **Event Tracing for Windows (ETW)** — A high-performance tracing framework. Providers emit structured events; consumers (like Event Viewer, WPA, or custom tools) subscribe to them. Events are manifest-free with TraceLogging. Near-zero overhead when no consumer is listening.

The `tracing` crate ecosystem has integration crates for both approaches:
- `tracing-etw` (by Microsoft) — A `tracing_subscriber::Layer` that emits events as ETW TraceLogging events. Maintained, zero-alloc hot path, supports keywords and levels. Events appear in ETW consumers but NOT in Event Viewer's Application log by default (requires a custom ETW consumer or channel configuration).
- `tracing-layer-win-eventlog` — A `tracing_subscriber::Layer` that writes to the Windows Event Log via `ReportEvent`. Events appear directly in Event Viewer > Application. Requires event source registration (PowerShell or registry).

## Goals / Non-Goals

**Goals:**
- Surface errors and warnings in Windows Event Viewer without requiring users to find log files
- Preserve accountability metadata (`category`, `safety`, `spec`) in event data
- Keep zero overhead on Linux/macOS builds via `#[cfg(target_os = "windows")]`
- Compose cleanly with existing file + stderr layers in `logging::init()`
- Start with error/warn level events; expand to info-level accountability events later

**Non-Goals:**
- Replacing file-based logging (Event Log is supplementary, not primary)
- Writing debug/trace level events to Event Log (too noisy for production)
- Supporting ETW real-time session consumers (Event Viewer is the target surface)
- Custom ETW manifest or WMI integration
- Linux systemd journal integration (separate future work)

## Decisions

### D1: Use `tracing-layer-win-eventlog` for Phase 1, evaluate `tracing-etw` for Phase 2

**Rationale:** The primary goal is visibility in Event Viewer. `tracing-layer-win-eventlog` writes directly to the Application log — events are immediately visible where Windows users look. `tracing-etw` emits ETW TraceLogging events that require a custom consumer or ETW session to view, which defeats the "just open Event Viewer" goal.

Phase 2 can add a `tracing-etw` layer in parallel for advanced diagnostics (WPA, PerfView) if needed. The two approaches are not mutually exclusive.

**Trade-off:** `tracing-layer-win-eventlog` uses the older `ReportEvent` API which has slightly higher per-event overhead than ETW. This is acceptable because we only log errors/warnings (low volume).

### D2: Event source name is "Tillandsias"

The Windows Event Log source name is `"Tillandsias"`. This appears in Event Viewer's "Source" column. Registration happens via:
- NSIS installer script (adds registry key during install), OR
- First-run self-registration via `RegisterEventSource` (requires elevation on some systems), OR
- Documented PowerShell one-liner for development: `New-EventLog -LogName Application -Source Tillandsias`

The installer path is preferred for production. Self-registration is a fallback. If registration fails, the layer is silently skipped (no crash).

### D3: Only error and warn levels go to Event Log

Event Log entries are visible to all users and persist across reboots. Writing info-level events would pollute the Application log. The filter is:
- `ERROR` → Event Log entry with `EVENTLOG_ERROR_TYPE`
- `WARN` → Event Log entry with `EVENTLOG_WARNING_TYPE`
- Accountability events at `INFO` level with `accountability = true` → Event Log entry with `EVENTLOG_INFORMATION_TYPE` (these are high-signal, low-volume)
- All other INFO/DEBUG/TRACE → not sent to Event Log

### D4: Accountability metadata is included in event message body

Since the Windows Event Log API accepts a string message (not structured fields), accountability metadata is formatted into the message body:

```
GitHub token retrieved from OS keyring
Category: secrets
Safety: Never written to disk, injected via bind mount
@trace spec:native-secrets-store
```

This preserves the accountability audit trail in Event Viewer entries. The `spec` field value is included but without the GitHub URL (too noisy for Event Viewer).

### D5: Layer is composed in logging::init() behind cfg(windows)

The ETW layer slots into the existing `tracing_subscriber::registry()` chain:

```rust
tracing_subscriber::registry()
    .with(filter)
    .with(file_layer)
    .with(stderr_layer)
    .with(windows_event_log_layer)  // #[cfg(target_os = "windows")]
    .init();
```

The layer is `Option<EventLogLayer>` so it can be `None` if registration fails. The `tracing_subscriber` `Option<Layer>` impl handles this transparently.

### D6: Graceful degradation if event source is not registered

If the event source `"Tillandsias"` is not registered in the Windows Event Log registry, the layer initialization logs a debug-level warning to the file log and returns `None`. The application continues with file + stderr logging only. No panic, no user-visible error.

### D7: Custom formatting layer wraps the eventlog layer

Rather than using `tracing-layer-win-eventlog` directly (which formats events in its own way), we write a thin custom `Layer` impl that:
1. Extracts fields using the same `EventFields` visitor from `log_format.rs`
2. Formats accountability events with category/safety/spec metadata
3. Formats regular events with the compact target + message format
4. Delegates to the Windows Event Log API for the actual write

This ensures Event Log entries have the same structure as file log entries, and accountability metadata is preserved.

## Alternatives Considered

### A1: tracing-etw only
Rejected for Phase 1. ETW events don't appear in Event Viewer's Application log by default. Users would need to set up an ETW session or use PerfView/WPA. This defeats the goal of "just open Event Viewer."

### A2: Direct windows-sys ReportEvent calls without a tracing layer
Rejected. Would require manually hooking into every error/warn log site. The tracing layer approach is composable and automatic.

### A3: Write to a Windows-specific log file that Event Viewer can monitor
Rejected. This is not how Windows event reporting works. Event Viewer reads from the Event Log service, not arbitrary files.

## Crate Evaluation

| Crate | Version | Approach | Event Viewer visible | Maintenance | Notes |
|-------|---------|----------|---------------------|-------------|-------|
| `tracing-etw` | 0.3.x | ETW TraceLogging | No (needs ETW consumer) | Microsoft-maintained | Best for perf diagnostics |
| `tracing-layer-win-eventlog` | 0.1.x | ReportEvent API | Yes (Application log) | Community | Simple, fits our goal |
| `eventlog` | 0.3.x | log-compatible | Yes | Community | Not tracing-compatible |
| `win_etw_tracing` | 0.1.x | ETW via tracing | No | Microsoft | Superseded by tracing-etw |
