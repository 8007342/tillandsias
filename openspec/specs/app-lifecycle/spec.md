# app-lifecycle Specification

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: User-facing app semantics
All container operations SHALL be presented to the user as "app" actions. The words "container", "pod", "image", or "runtime" MUST NOT appear in any user-facing text.

#### Scenario: Starting an app
- **WHEN** the user initiates a start action
- **THEN** the tray shows "Starting..." followed by the app name, never "Starting container..."

#### Scenario: Stopping an app
- **WHEN** the user initiates a stop action
- **THEN** the tray shows the app transitioning to stopped state without container terminology

#### Scenario: Error messages
- **WHEN** a container operation fails
- **THEN** the error message uses plain language (e.g., "Could not start. Is Podman running?") without exposing container internals

### Requirement: Running environment tracking with lifecycle iconography
The application SHALL maintain an in-memory registry of all running environments, updated by events from the podman orchestration layer. Each environment's tillandsia icon SHALL reflect its lifecycle state.

#### Scenario: Environment booting
- **WHEN** a container is being created and starting up
- **THEN** the environment appears in the tray with its assigned tillandsia genus icon in bud state (small green plant, no bloom)

#### Scenario: Environment healthy
- **WHEN** a container enters running state and is responsive
- **THEN** the tillandsia icon transitions to full bloom state (colorful flower)

#### Scenario: Environment stopping
- **WHEN** a container is in the process of stopping
- **THEN** the tillandsia icon transitions to dried bloom state (faded/brown flower)

#### Scenario: Environment rebuilding
- **WHEN** a container is being rebuilt or spawning a new process
- **THEN** the tillandsia icon shows pup state (small plant growing from parent)

#### Scenario: Environment stopped externally
- **WHEN** a tillandsias-managed container is stopped outside the tray app
- **THEN** the environment is removed from the running section via event detection and the tray icon state updates accordingly

#### Scenario: Environment crash
- **WHEN** a container exits unexpectedly
- **THEN** the environment is removed from the running section and the tray icon state updates accordingly

### Requirement: Graceful stop
Stopping an app SHALL send SIGTERM to the container, allow a grace period, then force-kill if necessary.

#### Scenario: Clean stop
- **WHEN** the user clicks Stop on a running app
- **THEN** the container receives SIGTERM and is given up to 10 seconds to shut down gracefully before SIGKILL

#### Scenario: Unresponsive stop
- **WHEN** a container does not stop within the grace period
- **THEN** the container is force-killed and removed, and the user is not burdened with technical details

### Requirement: Destroy with safety hold
Destroying an app (removing its cache and persistent data) SHALL require a deliberate hold action to prevent accidental data loss.

#### Scenario: Destroy action
- **WHEN** the user initiates a Destroy action on a stopped app
- **THEN** the action triggers a 5-second server-side delay before executing (safety hold)

#### Scenario: Destroy while running
- **WHEN** the user initiates a Destroy action on a running app
- **THEN** the app is first stopped gracefully, then the destroy proceeds after the 5-second hold

#### Scenario: Destroy effect
- **WHEN** a destroy completes
- **THEN** the container is removed, project-specific cache data is deleted, but the project source directory in `~/src` is never touched

### Requirement: Tray status display
Running apps SHALL be displayed in the tray with visual indicators and available actions.

#### Scenario: Single running app
- **WHEN** one app is running
- **THEN** the Running section shows the app name with a bloom indicator and Stop/Destroy actions

#### Scenario: Multiple running apps
- **WHEN** multiple apps are running
- **THEN** each app is listed separately in the Running section, each with independent Stop/Destroy actions

#### Scenario: Container operation timeout
- **WHEN** a container start operation exceeds 60 seconds
- **THEN** the operation is terminated and the user is informed that the environment could not be prepared

#### Scenario: Exponential backoff on event monitoring
- **WHEN** container event monitoring detects a connection issue
- **THEN** reconnection attempts use exponential backoff starting at 1 second, doubling to a maximum of 30 seconds, and MUST NOT degrade to fixed-interval polling

### Requirement: shutdown_all terminates web containers and closes webviews

`shutdown_all()` SHALL, as part of the existing quit sequence, stop every running `tillandsias-<project>-forge` container tracked in `TrayState::running` and close every `WebviewWindow` whose label begins with `web-`.

#### Scenario: No web containers survive app exit
- **WHEN** the user quits Tillandsias while one or more web containers are running
- **THEN** `shutdown_all()` stops each one via the existing launcher stop path
- **AND** no matching container remains in `podman ps` when the process exits
- **AND** all open web `WebviewWindow` instances are closed before the final exit

### Requirement: Orphan web containers are swept on shutdown

The orphan-sweep step of `shutdown_all()` SHALL match containers whose names follow `tillandsias-*-forge` (in addition to existing match patterns), so that web containers left behind by a prior crashed session are cleaned up.

#### Scenario: Crashed previous session leaves a stale web container
- **WHEN** `shutdown_all()` runs and the orphan sweep discovers a `tillandsias-<project>-forge` container not in `TrayState::running`
- **THEN** the sweep stops and removes it with the same logic used for other tillandsias orphans

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

