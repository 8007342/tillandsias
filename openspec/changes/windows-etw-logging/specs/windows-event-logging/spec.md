# windows-event-logging Specification

## Purpose

Windows-specific tracing subscriber layer that surfaces errors, warnings, and accountability events in the Windows Application Event Log, making Tillandsias a well-behaved Windows application with standard diagnostic visibility.

## Requirements

### Requirement: Error and warning events appear in Windows Event Viewer

On Windows, all `ERROR` and `WARN` level tracing events SHALL be written to the Windows Application Event Log under the source name "Tillandsias".

#### Scenario: Error event in Event Viewer
- **WHEN** an error-level tracing event is emitted (e.g., container launch failure)
- **THEN** an entry SHALL appear in Event Viewer > Windows Logs > Application
- **AND** the Source column SHALL show "Tillandsias"
- **AND** the Level column SHALL show "Error"
- **AND** the message SHALL contain the event message and any structured fields

#### Scenario: Warning event in Event Viewer
- **WHEN** a warn-level tracing event is emitted (e.g., podman machine not running)
- **THEN** an entry SHALL appear in Event Viewer with Level "Warning"
- **AND** the Source column SHALL show "Tillandsias"

#### Scenario: Info events are NOT written to Event Log
- **WHEN** a regular (non-accountability) info-level tracing event is emitted
- **THEN** it SHALL NOT appear in the Windows Event Log
- **AND** it SHALL still appear in the file log and stderr as before

### Requirement: Accountability events appear in Windows Event Log

Accountability-tagged events (`accountability = true`) at INFO level or above SHALL be written to the Windows Event Log as informational entries.

#### Scenario: Secret management accountability event
- **WHEN** an accountability event is emitted with `category = "secrets"`
- **THEN** an Event Log entry SHALL appear with Level "Information"
- **AND** the message body SHALL include the category, safety note, and spec name
- **AND** the format SHALL be:
  ```
  [secrets] GitHub token retrieved from OS keyring
  Safety: Never written to disk, injected via bind mount
  @trace spec:native-secrets-store
  ```

#### Scenario: Container lifecycle accountability event
- **WHEN** an accountability event is emitted with `category = "containers"`
- **THEN** an Event Log entry SHALL appear with structured fields (container name, project, etc.)

#### Scenario: Spec trace preserved in Event Log
- **WHEN** an accountability event has a `spec` field
- **THEN** the Event Log message SHALL include `@trace spec:<name>` lines
- **AND** the GitHub search URL SHALL NOT be included (too verbose for Event Viewer)

### Requirement: Windows Event Log layer composes with existing layers

The Windows Event Log layer SHALL be added to the tracing subscriber stack without affecting existing file or stderr logging.

#### Scenario: Layer composition
- **WHEN** `logging::init()` is called on Windows
- **THEN** the subscriber stack SHALL include: filter + file_layer + stderr_layer + eventlog_layer
- **AND** all three output layers SHALL receive the same events (subject to their own filtering)

#### Scenario: Filter applies to all layers
- **WHEN** the user specifies `--log=secrets:debug`
- **THEN** the module filter SHALL apply to the Event Log layer as well
- **AND** only ERROR/WARN events and accountability events from the secrets module SHALL reach Event Log

### Requirement: Graceful degradation without event source registration

If the Windows Event Log source "Tillandsias" is not registered, the layer SHALL degrade gracefully.

#### Scenario: Unregistered event source
- **WHEN** the Event Log source "Tillandsias" is not registered in the Windows registry
- **THEN** the Event Log layer SHALL be silently disabled (returns `None`)
- **AND** a debug-level message SHALL be written to the file log noting the skip
- **AND** the application SHALL continue with file + stderr logging only
- **AND** no panic or user-visible error SHALL occur

#### Scenario: Registration via installer
- **WHEN** Tillandsias is installed via the NSIS installer
- **THEN** the installer SHALL register the "Tillandsias" event source in the registry
- **AND** the uninstaller SHALL remove the event source registration

### Requirement: No impact on non-Windows platforms

All Windows Event Log code SHALL be gated behind `#[cfg(target_os = "windows")]`.

#### Scenario: Linux build
- **WHEN** building on Linux (`cargo build --workspace`)
- **THEN** no Windows Event Log dependencies SHALL be compiled
- **AND** no Windows Event Log code SHALL be included in the binary

#### Scenario: macOS build
- **WHEN** building on macOS (`cargo build --workspace`)
- **THEN** no Windows Event Log dependencies SHALL be compiled

#### Scenario: Windows cross-build
- **WHEN** cross-building for Windows (`build-windows.sh --check`)
- **THEN** the Windows Event Log layer SHALL compile without errors

### Requirement: Event message formatting

Event Log messages SHALL use a human-readable format consistent with the file log format.

#### Scenario: Regular error event format
- **WHEN** a non-accountability error event is written to Event Log
- **THEN** the message SHALL be: `target: message {key=val, ...}`
- **AND** the target SHALL use the shortened form (e.g., `secrets` not `tillandsias_tray::secrets`)

#### Scenario: Accountability event format
- **WHEN** an accountability event is written to Event Log
- **THEN** the message SHALL include the category prefix, message, safety note, and spec traces
- **AND** the format SHALL match the file log accountability format minus timestamps and ANSI codes

### Requirement: Event Log filtering layer

A dedicated filter SHALL control which events reach the Event Log layer, independent of the main filter.

#### Scenario: Default Event Log filter
- **WHEN** no special configuration is provided
- **THEN** only ERROR, WARN, and accountability-tagged INFO events SHALL reach Event Log

#### Scenario: Non-accountability INFO excluded
- **WHEN** a regular INFO event like "Initial project scan complete" is emitted
- **THEN** it SHALL NOT appear in Event Log
- **AND** it SHALL still appear in file log
