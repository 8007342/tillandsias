## ADDED Requirements

### Requirement: ExitRequested discriminates on code

The Tauri `RunEvent::ExitRequested` handler SHALL branch on the `code` field. When
`code.is_none()` (Tauri auto-exit triggered by the last window closing) the handler
SHALL call `api.prevent_exit()` and return without running any cleanup. When
`code.is_some()` (explicit exit via `app.exit(n)`) the handler SHALL release the
singleton guard, signal shutdown, and allow Tauri to exit. The handler SHALL NOT call
`shutdown_all()` on either branch — cleanup runs in the event loop's `MenuCommand::Quit`
arm exactly once per process lifetime.

#### Scenario: Auto-exit from last window close is prevented
- **WHEN** the user closes the last `web-*` webview window and Tauri emits
  `RunEvent::ExitRequested { code: None }`
- **THEN** the handler calls `api.prevent_exit()`
- **AND** the Tauri event loop continues running
- **AND** the tray icon and its callbacks remain active

#### Scenario: Explicit exit after shutdown_all
- **WHEN** the event loop's Quit arm calls `app_handle.exit(0)` after
  `shutdown_all()` has returned
- **THEN** Tauri emits `RunEvent::ExitRequested { code: Some(0) }`
- **AND** the handler releases the singleton guard
- **AND** the handler does NOT run `shutdown_all()` again
- **AND** the process exits with status 0

### Requirement: Tray Quit dispatches MenuCommand::Quit (no direct process exit)

The tray menu's Quit item SHALL dispatch `MenuCommand::Quit` through the existing
menu channel. The tray menu callback SHALL NOT call `std::process::exit`, nor otherwise
terminate the process synchronously without routing through the event loop.

#### Scenario: Quit from tray menu routes through event loop
- **WHEN** the user selects "Quit" from the tray menu
- **THEN** the menu callback sends `MenuCommand::Quit` on `menu_tx`
- **AND** the event loop's Quit arm runs `handlers::shutdown_all(&state).await`
- **AND** the event loop calls `app_handle.exit(0)`
- **AND** the `RunEvent::ExitRequested` handler finalizes as in the "Explicit exit"
  scenario above

#### Scenario: No direct process::exit in the menu callback
- **WHEN** auditing the tray menu's on_menu_event closure
- **THEN** no branch calls `std::process::exit`
- **AND** the Quit branch sends `MenuCommand::Quit` and returns

### Requirement: Event loop owns the sole shutdown_all invocation

Exactly one code path per process lifetime SHALL invoke
`handlers::shutdown_all(&state).await`: the `MenuCommand::Quit` arm of the main event
loop. Other paths (signal handlers, webview close, auto-exit) SHALL NOT run
`shutdown_all()` directly.

#### Scenario: Ctrl+C / SIGINT in tray mode
- **WHEN** the process receives SIGINT while the tray is running
- **THEN** the signal handler routes to `MenuCommand::Quit` (or equivalent) so the event
  loop owns cleanup
- **AND** `shutdown_all()` runs exactly once
- **AND** no container is left in `podman ps` after process exit

#### Scenario: Webview close does not run shutdown_all
- **WHEN** the user closes a `web-*` webview window
- **THEN** `shutdown_all()` is NOT invoked
- **AND** every running container keeps running
- **AND** the enclave network remains attached

### Requirement: shutdown_all removes containers AND destroys the enclave network

`shutdown_all()` SHALL not only stop every tillandsias container but also
remove them (`podman rm`) before attempting to destroy the enclave network.
`cleanup_enclave_network()` SHALL use `podman network rm -f` so any residual
attached container (e.g. an exited forge that the remove step missed) is
force-disconnected rather than blocking network teardown. After
`shutdown_all()` returns, `podman ps -a --filter name=tillandsias-` MUST be
empty and `podman network exists tillandsias-enclave` MUST be false.

#### Scenario: Stop + remove, then destroy network
- **WHEN** `shutdown_all()` iterates `state.running`
- **THEN** each container is stopped (SIGTERM with 10s grace, then SIGKILL)
- **AND** each container is removed from podman's records
- **AND** the enclave network is destroyed with `network rm -f`
- **AND** after completion, `podman ps -a --filter name=tillandsias-`
  returns no results
- **AND** `podman network ls | grep tillandsias-enclave` returns no results

#### Scenario: Exited container from a prior crash is swept
- **WHEN** a previous tillandsias session crashed leaving a container in
  `exited` state still attached to `tillandsias-enclave`
- **AND** a fresh tray process starts and then quits via the tray menu
- **THEN** the orphan sweep in `shutdown_all()` removes the exited container
- **AND** the enclave network is destroyed cleanly on the same quit cycle
- **AND** the next tray launch creates a fresh network, no "previous session
  leftovers" warnings
