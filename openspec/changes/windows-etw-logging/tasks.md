## 1. Add Windows Event Log dependency

- [ ] 1.1 Add `tracing-layer-win-eventlog` to `src-tauri/Cargo.toml` under `[target.'cfg(windows)'.dependencies]`
- [ ] 1.2 Verify it compiles alongside existing `windows-sys` dependency (both must use compatible `windows-sys` versions)
- [ ] 1.3 Run `./build-windows.sh --check` to confirm cross-compilation still passes

## 2. Implement Event Log formatting layer

- [ ] 2.1 Create `src-tauri/src/windows_eventlog.rs` module with `#[cfg(target_os = "windows")]` gate
- [ ] 2.2 Implement a custom `tracing_subscriber::Layer` that:
  - Filters to only ERROR, WARN, and accountability-tagged INFO events
  - Extracts fields using the `EventFields` visitor pattern from `log_format.rs` (refactor `EventFields` to a shared location or re-implement)
  - Formats accountability events with `[category] message\nSafety: ...\n@trace spec:...`
  - Formats regular events with `target: message {key=val, ...}`
  - Writes to Windows Event Log via `ReportEvent` (through `tracing-layer-win-eventlog` or direct `windows-sys` calls)
- [ ] 2.3 Map tracing levels to Event Log types: ERROR -> `EVENTLOG_ERROR_TYPE`, WARN -> `EVENTLOG_WARNING_TYPE`, accountability INFO -> `EVENTLOG_INFORMATION_TYPE`
- [ ] 2.4 Add `try_init() -> Option<impl Layer>` function that returns `None` if event source registration fails

## 3. Integrate into logging::init()

- [ ] 3.1 In `src-tauri/src/logging.rs`, add `#[cfg(target_os = "windows")]` block that calls `windows_eventlog::try_init()`
- [ ] 3.2 Compose the optional layer into the subscriber stack: `.with(eventlog_layer)` where `eventlog_layer: Option<_>`
- [ ] 3.3 Verify that `None` (unregistered source) does not break the subscriber chain
- [ ] 3.4 Add the module declaration in `main.rs`: `#[cfg(target_os = "windows")] mod windows_eventlog;`

## 4. Add event source registration to NSIS installer

- [ ] 4.1 In `src-tauri/nsis/` or Tauri's NSIS config, add registry key creation for the "Tillandsias" event source during install:
  - Key: `HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\Tillandsias`
  - Value: `EventMessageFile` pointing to the application executable
- [ ] 4.2 Add registry key removal to the uninstaller section
- [ ] 4.3 Document the manual registration command for development: `New-EventLog -LogName Application -Source Tillandsias` (PowerShell as admin)

## 5. Add @trace annotations

- [ ] 5.1 Add `// @trace spec:windows-event-logging` to the new `windows_eventlog.rs` module
- [ ] 5.2 Add `// @trace spec:windows-event-logging` to the Windows-specific block in `logging.rs`
- [ ] 5.3 Update `// @trace spec:logging-accountability` in `logging.rs` to include `, spec:windows-event-logging`

## 6. Testing

- [ ] 6.1 Write unit tests for the Event Log message formatting (can run on any platform — test the formatting function, not the Windows API call)
- [ ] 6.2 Write a `#[cfg(target_os = "windows")]` integration test that:
  - Creates a subscriber with the Event Log layer
  - Emits test error/warn/info events
  - Verifies the layer does not panic (actual Event Log verification is manual)
- [ ] 6.3 Manual test on Windows: run Tillandsias, trigger an error (e.g., stop podman machine), check Event Viewer
- [ ] 6.4 Verify Linux/macOS builds are unaffected: `./build.sh --check` and `./build-osx.sh --check`

## 7. Documentation

- [ ] 7.1 Add a `docs/cheatsheets/windows-event-viewer.md` cheatsheet with:
  - How to find Tillandsias events in Event Viewer
  - How to filter by source "Tillandsias"
  - Manual event source registration for development
  - What each event level means
  - `@trace spec:windows-event-logging`
- [ ] 7.2 Update `docs/cheatsheets/logging-levels.md` to mention Event Viewer as a Windows-specific output surface

## 8. Verify cross-platform builds

- [ ] 8.1 Run `./build-windows.sh --check` — Windows cross-compilation passes
- [ ] 8.2 Run `./build.sh --test` — Linux tests pass, no Windows code compiled
- [ ] 8.3 Run `./build-osx.sh --check` — macOS compilation passes
- [ ] 8.4 Run `cargo clippy --workspace --target x86_64-pc-windows-msvc` (if available) — no warnings
