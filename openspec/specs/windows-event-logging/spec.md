<!-- @trace spec:windows-event-logging -->

# windows-event-logging Specification

## Status

status: active
platform: windows-only
build-status: active (reactivated for the native Win32 tray, 2026-07-18)
derived-from: operator directive 2026-07-18 (relay ALL INFO/WARN/ERROR) +
  archive windows-etw-logging-completed-2026-04-27
last-updated: 2026-07-18

## Purpose

Defines Windows-specific diagnostic relay to the Windows Event Log. The
Tillandsias tray writes every INFO, WARN, and ERROR tracing event to the
Application Event Log where a power user can discover them in Event Viewer >
Windows Logs > Application > Source "Tillandsias" — including provisioning
failures on machines where the tray UI itself is failing (the 2026-07-18
field crash-loop had no discoverable diagnostics; this spec closes that gap).

**History**: first implemented under the Tauri wrapper (`src-tauri/`, removed
2026-05-05 in `9b4e845d`); that implementation's Win32 write path was a stub
that never called `ReportEventW`. Reactivated 2026-07-18 as a real
implementation in the native tray: `crates/tillandsias-windows-tray/src/eventlog.rs`.

## Requirements

### Requirement: Windows Event Log Integration

The Tillandsias tray binary MUST write selected tracing events to the Windows
Application Event Log via `RegisterEventSourceW`/`ReportEventW`. @trace spec:windows-event-logging

- **Platform**: Windows-only (whole-module `#![cfg(target_os = "windows")]` in `crates/tillandsias-windows-tray/src/eventlog.rs`; compiles to nothing elsewhere)
- **Layer integration**: MUST be part of the `tracing_subscriber` layer stack built in `notify_icon::init_tracing` (alongside the `tray.log` file layer), initialized in `main` BEFORE the singleton guard so startup refusals are relayed too
- **Registration is optional**: the relay MUST work without the HKLM source registration (see Graceful Degradation); when available, registration renders messages clean in Event Viewer
- **Registration method**: `scripts/install-windows.ps1` registers `New-EventLog -LogName Application -Source Tillandsias` best-effort — directly when the install shell is elevated, or piggybacked on the single Hyper-V group-add UAC prompt; never a second elevation prompt, never a hard requirement
- **Purge**: `install-windows.ps1 -Purge` removes the source registration best-effort (elevated shells only); already-written events are the record and stay

#### Scenario: Event source registration

- **WHEN** `install-windows.ps1` runs in an elevated shell, or its Hyper-V group-add UAC prompt is accepted
- **THEN** the source `Tillandsias` SHOULD be registered under `HKLM\SYSTEM\CurrentControlSet\Services\eventlog\Application\Tillandsias`
- **WHEN** registration is absent (standard per-user install, UAC declined)
- **THEN** the relay MUST still write events (rendered inside Event Viewer's "description not found" wrapper)
- **AND** installation and tray startup MUST proceed normally

### Requirement: Event Type Mapping

Tracing events MUST be mapped to Windows Event Log types by level. Operator
directive 2026-07-18: ALL INFO events relay — provisioning progress/failure
events flow to the UX at INFO and every one of them must be discoverable.
DEBUG/TRACE (including high-frequency download-progress refinements, which
the tray emits at DEBUG) stay out of the Event Log.

#### Mapping Rules

| Tracing Level | Event Type | Action |
|---------------|---|---|
| **ERROR** | `EVENTLOG_ERROR_TYPE` (1) | MUST be written |
| **WARN** | `EVENTLOG_WARNING_TYPE` (2) | MUST be written |
| **INFO** | `EVENTLOG_INFORMATION_TYPE` (4) | MUST be written |
| **DEBUG** | (skipped) | MUST NOT be written |
| **TRACE** | (skipped) | MUST NOT be written |

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

#### Scenario: Plain info event

- **WHEN** tray emits: `info!("Container started")` (no accountability field)
- **THEN** layer MUST write it as `EVENTLOG_INFORMATION_TYPE`
- **AND** it MUST also reach the file log (normal path)

#### Scenario: Provisioning phase transitions are relayed

- **WHEN** the provisioning pipeline reports a phase (e.g. "Downloading Fedora rootfs", "Starting VM") to the tray UX sink
- **THEN** the sink MUST mirror the phase into `tracing::info!`
- **AND** the phase MUST therefore appear in the Event Log, so a failed provision leaves a discoverable trail of how far it got
- **AND** sub-phase progress refinements (download % ticks) MUST be emitted at DEBUG and MUST NOT reach the Event Log

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

### Requirement: Graceful Degradation

A logging relay MUST never take the tray down or block its startup.

- **Unregistered source**: `RegisterEventSourceW` succeeds for unregistered sources; the layer MUST keep writing (Event Viewer renders the message inside its generic wrapper). Do NOT disable on missing registration.
- **Handle failure**: if `RegisterEventSourceW` fails, `eventlog::try_layer()` MUST return `None` — the subscriber stack comes up without the layer and file logging continues
- **Write failure**: a failed `ReportEventW` MUST be dropped silently (no recursion into tracing, no crash)

#### Scenario: Source handle unavailable

- **WHEN** `RegisterEventSourceW` fails at tray startup
- **THEN** `try_layer()` MUST return `None`
- **AND** the tray MUST start normally with file logging only

### Requirement: Layer Implementation

The Windows Event Log layer MUST be implemented as a `tracing_subscriber::Layer<S>` wrapping `RegisterEventSourceW`/`ReportEventW` (`windows` crate, features `Win32_System_EventLog` + `Win32_Security`).

**File**: `crates/tillandsias-windows-tray/src/eventlog.rs` (whole-module `#![cfg(target_os = "windows")]`)

#### Layer Characteristics

- **Name**: `WindowsEventLogLayer`
- **Generic over**: `S: Subscriber + for<'a> LookupSpan<'a>`
- **Methods**:
  - `on_new_span()` — MUST NOT be used (events only)
  - `on_event()` — MUST extract fields, format, write to Event Log
- **Integration**: MUST be added to subscriber stack via `.with(eventlog::try_layer())` (`Option<Layer>` — `None` degrades to file-only)
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
// notify_icon::init_tracing (called from main BEFORE the singleton guard)
tracing_subscriber::registry()
    .with(filter)                       // RUST_LOG, default info
    .with(fmt_layer)                    // tray.log file layer
    .with(crate::eventlog::try_layer()) // Event Log (None ⇒ file-only)
    .try_init();
```

### Requirement: Cross-Platform Cost

- **Conditional compilation**: `#![cfg(target_os = "windows")]` gates the whole module; other platforms MUST compile nothing (zero runtime cost)
- The `mod eventlog;` declaration in `main.rs` is unconditional; the gate lives inside the file

## Verification

Unit tests in `crates/tillandsias-windows-tray/src/eventlog.rs`:
- `level_mapping_relays_info_warn_error_only` — pins the mapping table
- `format_simple_message` / `format_accountability_metadata` / `format_plain_event_keeps_structured_fields` — pin message formatting
- `try_layer_obtains_source_handle` — layer comes up on any Windows host
- `eventlog_end_to_end_writes_to_application_log` (`#[ignore]`, opt-in: writes the real Application log) — full-stack emit → `Get-EventLog` readback. Run on Windows with `cargo test -p tillandsias-windows-tray -- --ignored eventlog`. Verified live 2026-07-18 on an unregistered-source host.

Power-user readback note: `Get-WinEvent -FilterHashtable @{ProviderName='Tillandsias'}` only matches REGISTERED providers; on unregistered (default per-user) installs use `Get-EventLog -LogName Application -Source Tillandsias` or filter by source in Event Viewer.

## Sources of Truth

- https://docs.microsoft.com/en-us/windows/win32/wes/about-windows-event-log — Windows Event Log architecture
- https://docs.microsoft.com/en-us/windows/win32/etw/about-event-tracing — Event Tracing for Windows (ETW)
- `cheatsheets/runtime/logging-levels.md` — Logging level semantics and accountability field definitions
- `cheatsheets/runtime/windows-event-viewer.md` — Event Viewer access and filtering (user-facing)

## Related Specifications

- `logging-accountability` — Accountability field semantics and usage across all platforms
- `cli-diagnostics` — Diagnostic log streams (Windows Event Log is one destination)
- `cross-platform` — Platform-specific build and feature gates
