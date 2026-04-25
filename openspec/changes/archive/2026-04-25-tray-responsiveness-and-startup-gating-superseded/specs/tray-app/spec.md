## ADDED Requirements

### Requirement: Event loop never blocks on IO

The tray event loop thread SHALL NOT execute any blocking IO operation (subprocess wait, network fetch, filesystem scan of large trees, container build, container probe, keyring call, `git` invocation, or similar). Every long-running operation MUST be spawned as a task via `tokio::spawn` with a cancel token, returning completion and progress through `mpsc` channels consumed by the event loop's `tokio::select!`.

#### Scenario: Long-running overlay build does not freeze the UI
- **WHEN** the tray kicks off `build-tools-overlay.sh` (which spawns a podman container that may run for tens of seconds)
- **THEN** the event loop continues to accept `MenuCommand::*` messages
- **AND** the tray icon remains clickable
- **AND** `MenuCommand::Quit` dispatched during the build completes within 5 seconds
- **AND** the overlay build's spawn task is aborted via its cancel token on Quit

#### Scenario: No `std::process::Command::output()` on the event loop thread
- **WHEN** auditing `src-tauri/src/event_loop.rs` and `src-tauri/src/handlers.rs` helpers called from it
- **THEN** any subprocess invocation uses `tokio::process::Command` awaited from a spawned task, not `std::process::Command::output()` from the event loop
- **AND** any `tokio::process::Command::output()` that runs longer than 5s has a `tokio::time::timeout` wrapper

### Requirement: Quit is always serviceable within 5 seconds

The tray SHALL guarantee that `MenuCommand::Quit` transitions the tray to `shutdown_all()` within 5 seconds of dispatch, regardless of what other work is in flight.

Implementation: the event loop's `tokio::select!` uses `biased;` so the `menu_rx` branch is polled before every other branch; spawned IO tasks hold cancel tokens the Quit handler aborts before entering `shutdown_all`.

#### Scenario: Quit during forge image build
- **WHEN** the user clicks tray Quit while the forge image build is 30% complete
- **THEN** the in-flight build task is aborted
- **AND** `shutdown_all` starts within 5 seconds of the click
- **AND** containers are stopped, network removed
- **AND** the process exits within the usual `shutdown_all` budget

#### Scenario: Quit with no work in flight
- **WHEN** the tray is idle (no images building, no attach in progress) and the user clicks Quit
- **THEN** `shutdown_all` starts within 1 second
- **AND** exits within 5 seconds

### Requirement: Stale containers are swept on startup before UI interaction

Before the event loop opens for user input, the tray SHALL scan for any `tillandsias-*` container and remove it if it was not started by this tray process. This covers:

- A previous tray crashed mid-build leaving an overlay-builder container running.
- A previous tray crashed mid-attach leaving a forge / git-service container running.
- Stale containers from an older tray version that the current binary doesn't manage.

The scan + force-removal MUST be spawned off the event loop (stays non-blocking UI) but MUST complete before any menu command capable of spawning a new container is enabled (e.g. Attach Here).

#### Scenario: Crash recovery on startup
- **WHEN** the tray starts and `podman ps --filter name=tillandsias-` returns containers older than the tray's PID start time
- **THEN** every such container is `podman rm -f`'d
- **AND** the enclave network is `podman network rm -f`'d
- **AND** a fresh network is created when the first Attach Here runs
- **AND** the user never sees a menu that points at dead containers

### Requirement: UI gating follows a four-stage natural progression

The tray menu SHALL render every control at all times but enable them in four stages, advancing left-to-right as prerequisites are satisfied. Each stage unlocks the next; none skip ahead.

1. **Exit + Language** — ALWAYS enabled. Invariants even under total subsystem failure.
2. **Forge image build progress** — enabled once the tools overlay has extracted / is building. Shows per-image build progress chip.
3. **GitHub login** — enabled only after all four infrastructure images (forge, proxy, inference, git) are ready AND the OS keyring is reachable.
4. **Remote projects + local projects + Attach Here** — enabled only after a live GitHub credential check succeeds (see capability `github-credential-health`).

Disabled items render with the same label + a tooltip stating what is pending (e.g. "waiting for forge image build (45%)"). No disabled item is silently missing — presence tells the user the feature exists.

#### Scenario: Fresh install menu state
- **WHEN** Tillandsias launches on a host that has never run it
- **THEN** the menu shows: Exit (enabled), Language (enabled), plus dimmed entries for each subsequent stage with tooltips
- **AND** image-build progress chips appear as each of forge / proxy / inference / git begins
- **AND** GitHub login unlocks only when all four chips report complete
- **AND** project lists unlock only after the GitHub credential probe passes

#### Scenario: Keyring unreachable
- **WHEN** the OS keyring daemon is not responding
- **THEN** GitHub login is disabled with tooltip "waiting for OS keyring"
- **AND** Quit + Language remain enabled
- **AND** the tray does not spin while retrying — a single attempt per user interaction
