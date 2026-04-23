## ADDED Requirements

### Requirement: Webview close is not an exit signal

The Tauri runtime event handler SHALL filter `RunEvent::WindowEvent { event: CloseRequested, .. }` for windows whose label starts with `web-` and SHALL NOT propagate that close to `RunEvent::ExitRequested`. Only the tray's `MenuCommand::Quit` action and OS-initiated termination signals SHALL trigger `shutdown_all()`.

#### Scenario: Webview close stays scoped
- **WHEN** the runtime receives `WindowEvent::CloseRequested` for a `web-*` label
- **THEN** the runtime closes that single window
- **AND** does not emit `RunEvent::ExitRequested`
- **AND** does not invoke `shutdown_all()`

#### Scenario: Tray quit still triggers shutdown
- **WHEN** the user clicks "Quit" from the tray menu
- **THEN** `MenuCommand::Quit` is dispatched
- **AND** `shutdown_all()` runs
- **AND** the runtime emits `RunEvent::ExitRequested`
- **AND** the process exits cleanly
