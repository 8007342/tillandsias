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
