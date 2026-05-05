<!-- @trace spec:windows-event-logging -->

# windows-event-logging Specification

## Status

status: suspended
platform: windows-only
build-status: builds disabled (Windows builds suspended as of 2026-05-02)
annotation-count: 17
derived-from: code annotations only (no archive)
last-updated: 2026-05-02

## Purpose

Defines Windows-specific accountability logging via ETW (Event Tracing for Windows) integration with the Windows Event Log. When enabled (Windows platform only), Tillandsias writes ERROR, WARN, and accountability INFO events to the Application Event Log where they are visible in Windows Event Viewer under Event Viewer > Windows Logs > Application > Source "Tillandsias".

**Current Status**: Implementation exists in code but is suspended due to Windows build suspension (2026-05-02). Architecture and integration points are preserved for future reactivation.

## Requirements

### Requirement: Windows Event Log Integration (Suspended)

When Windows builds are re-enabled, the Tillandsias tray binary MUST write selected tracing events to the Windows Event Log via ETW. @trace spec:windows-event-logging

**Note**: This requirement is currently SUSPENDED. The implementation in `src-tauri/src/windows_eventlog.rs` exists but is NOT active. See `build.rs` and `logging.rs` for conditional compilation guards.

- **Platform**: Windows-only (conditional compilation: `#[cfg(target_os = "windows")]`)
- **Registry**: Event source "Tillandsias" MUST be registered in Windows registry under `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\eventlog\Application\Tillandsias`
- **Registration method**: Installer (NSIS) or manual PowerShell: `New-EventLog -LogName Application -Source Tillandsias`
- **Layer integration**: MUST be part of `tracing_subscriber::Layer` stack (same as file logging, stderr)

#### Scenario: Event source registration

- **WHEN** NSIS installer runs on Windows
- **THEN** MUST create registry key `HKEY_LOCAL_MACHINE\...\Tillandsias`
- **AND** MUST set `EventMessageFile` to Tillandsias binary path
- **AND** MUST set `TypesSupported` to 7 (error | warning | information)

- **WHEN** registry key does NOT exist and user starts Tillandsias
- **THEN** Windows Event Log layer MUST silently return `None` (disabled)
- **AND** MUST emit DEBUG log: "Windows Event Log source not registered"
- **AND** application MUST continue normally (no crash)

### Requirement: Event Type Mapping

Tracing events MUST be mapped to Windows Event Log types based on level and accountability.

#### Mapping Rules

| Tracing Level | Accountability | Event Type | Action |
|---------------|---|---|---|
| **ERROR** | any | `EVENTLOG_ERROR_TYPE` (1) | MUST be written |
| **WARN** | any | `EVENTLOG_WARNING_TYPE` (2) | MUST be written |
| **INFO** | true | `EVENTLOG_INFORMATION_TYPE` (4) | MUST be written (sensitive) |
| **INFO** | false | (skipped) | MUST NOT be written |
| **DEBUG** | any | (skipped) | MUST NOT be written |
| **TRACE** | any | (skipped) | MUST NOT be written |

#### Scenario: Error event

- **WHEN** tray emits: `error!(accountability = true, spec = "secrets", "GitHub token fetch failed")`
- **THEN** Windows Event Log layer MUST detect ERROR level
- **AND** MUST write to Event Log type `EVENTLOG_ERROR_TYPE`
- **AND** event MUST appear in Event Viewer

#### Scenario: Accountability info event

- **WHEN** tray emits: `info!(accountability = true, category = "secrets", safety = "...", "Token cached")`
- **THEN** Window Event Log layer MUST detect INFO + accountability = true
- **AND** MUST write to Event Log type `EVENTLOG_INFORMATION_TYPE`
- **AND** event MUST include metadata (see next requirement)

#### Scenario: Non-accountability info event

- **WHEN** tray emits: `info!("Container started")`
- **THEN** layer MUST detect INFO without accountability
- **AND** event MUST be SKIPPED (not written to Event Log)
- **AND** SHOULD still be written to file log and stderr (normal path)

### Requirement: Metadata Preservation in Event Log

Accountability events written to Windows Event Log MUST include structured metadata fields.

#### Metadata Fields

For accountability events, the Event Log message body MUST include:

```text
[Base message from tracing event]

Category: [category field if present]
Safety: [safety field if present]
@trace spec:[spec field if present]
```

#### Message Format Example

```
GitHub token retrieved from OS keyring
Category: secrets
Safety: Never written to disk, injected via bind mount
@trace spec:native-secrets-store
```

#### Scenario: Accountability event metadata

- **WHEN** tray emits event with fields:
  - message: "GitHub token retrieved"
  - accountability: true
  - category: "secrets"
  - safety: "Never written to disk"
  - spec: "native-secrets-store"
- **THEN** Event Log layer MUST format as above
- **AND** MUST write full message to Event Viewer

### Requirement: Graceful Degradation on Missing Registry

If the Windows Event Log source is not registered, the layer MUST silently degrade without crashing.

- **Registration check**: MUST attempt to open registry path on first write
- **If not found**: MUST return `None` (layer disabled for this session)
- **Logging**: MUST emit single DEBUG log: `"Windows Event Log source 'Tillandsias' not registered; skipping"`
- **No retry**: MUST NOT attempt to create registry key or re-check in subsequent events
- **No crash**: Application MUST continue normally

#### Scenario: Registry key missing on first event

- **WHEN** user starts Tillandsias without prior registry registration
- **AND** first tracing event occurs (e.g., startup INFO)
- **THEN** layer MUST attempt registry lookup
- **AND** lookup MUST fail
- **AND** MUST emit single DEBUG log (per session)
- **AND** subsequent events MUST skip Event Log entirely
- **AND** application MUST continue with file + stderr logging only

### Requirement: Logging and Observability

The Windows Event Log layer MUST emit DEBUG logs for registration status on startup.

- **Condition 1**: Registry key found
  - DEBUG log: MUST be `"Windows Event Log source registered"`
- **Condition 2**: Registry key NOT found
  - DEBUG log: MUST be `"Windows Event Log source 'Tillandsias' not registered; skipping"`
- **Level**: DEBUG (verbose, for troubleshooting)
- **Frequency**: MUST be once per session (not on every event)

#### Log Examples

```
DEBUG logging: Windows Event Log source registered
  @trace spec:windows-event-logging
```

```
DEBUG logging: Windows Event Log source 'Tillandsias' not registered; skipping
  Install via: New-EventLog -LogName Application -Source Tillandsias
  @trace spec:windows-event-logging
```

### Requirement: Layer Implementation (Suspended)

The Windows Event Log layer MUST be implemented as a `tracing_subscriber::Layer<S>` that wraps the ETW API.

**File**: `src-tauri/src/windows_eventlog.rs` (currently conditional on `#[cfg(target_os = "windows")]`)

#### Layer Characteristics

- **Name**: `WindowsEventLogLayer`
- **Generic over**: `S: Subscriber + for<'a> LookupSpan<'a>`
- **Methods**:
  - `on_new_span()` — MUST NOT be used (events only)
  - `on_event()` — MUST extract fields, format, write to Event Log
- **Integration**: MUST be added to subscriber stack via `.with(WindowsEventLogLayer::new())`
- **Thread-safe**: MUST be safe for concurrent event emission (uses Win32 APIs)

#### Event Field Extraction

The layer MUST implement `tracing::field::Visit` to extract fields:
- `message` — base event message
- `accountability` (bool) — sensitivity flag
- `category` (str) — operation category
- `safety` (str) — safety note
- `spec` (str) — spec reference
- `other` — all other fields (MUST be discarded for accountability events)

#### Scenario: Layer in subscriber stack

```rust
// (Suspended, shown for reference)
tracing_subscriber::registry()
    .with(fmt_layer)               // File + stderr
    .with(WindowsEventLogLayer::new())  // Event Log (Windows only)
    .init();
```

### Requirement: Suspension Mechanics

When Windows builds are suspended, the following MUST apply:

- **Conditional compilation**: `#[cfg(target_os = "windows")]` MUST gate all Windows Event Log code
- **Build flag**: `scripts/build-windows.sh` and `build.rs` MUST NOT attempt to compile Windows Event Log layer
- **No-op on non-Windows**: Other platforms MUST compile nothing; zero runtime cost
- **Reactivation**: When Windows builds resume, rebuild binary with same code (no changes needed unless Windows APIs changed)

#### Reactivation Checklist (for future)

When Windows builds are re-enabled:
1. MUST verify `src-tauri/src/windows_eventlog.rs` compiles (Windows SDK requirements)
2. MUST confirm `build.rs` includes Windows Event Log layer in subscriber stack
3. MUST test registry key creation via NSIS installer
4. MUST verify Event Viewer shows accountability events correctly
5. MUST test graceful degradation when registry key missing

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — event source registration, level/accountability mapping, metadata preservation

Gating points (when Windows builds resume):
- Event source "Tillandsias" registered in Windows registry via NSIS or PowerShell
- ERROR events always written to Event Log; WARN events always written
- INFO events written only if accountability = true; DEBUG/TRACE skipped
- Accountability event metadata includes category, safety, @trace spec annotations
- Layer implements tracing::field::Visit for field extraction
- Graceful degradation when registry key missing; no crash, only DEBUG log
- Conditional compilation gates Windows Event Log code; zero cost on other platforms
- Reactivation checklist preserved for future Windows build resumption

## Sources of Truth

- https://docs.microsoft.com/en-us/windows/win32/wes/about-windows-event-log — Windows Event Log architecture
- https://docs.microsoft.com/en-us/windows/win32/etw/about-event-tracing — Event Tracing for Windows (ETW)
- `cheatsheets/runtime/logging-levels.md` — Logging level semantics and accountability field definitions
- `cheatsheets/runtime/windows-event-viewer.md` — Event Viewer access and filtering (user-facing)

## Related Specifications

- `logging-accountability` — Accountability field semantics and usage across all platforms
- `cli-diagnostics` — Diagnostic log streams (Windows Event Log is one destination)
- `cross-platform` — Platform-specific build and feature gates
