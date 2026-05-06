<!-- @trace spec:browser-daemon-tracking -->

# browser-daemon-tracking Specification

## Status

active

## Purpose

Browser containers (Chromium isolation) are tracked in TrayState alongside forge, git, and proxy containers. This enables consistent lifecycle management: "Stop Project" terminates all containers, and tray shutdown cleans up browser resources. Tracked browser containers are visible in the tray state graph for debugging and observability.

## Requirements

### Requirement: Track browser containers in TrayState

Browser containers spawned via `chromium_launcher::spawn_chromium_window()` are added to `TrayState.running` with type `ContainerType::Browser`.

#### Scenario: Browser container added on startup
- **WHEN** a versioned browser container starts successfully
- **THEN** it is added to `TrayState.running` with:
  - `container_type: ContainerType::Browser`
  - `port_range: (host_port, host_port)` allocated from 17000-17999 range
  - `project_name` set to the project name
- **RATIONALE**: Consistent with forge/git/proxy tracking. Enables "Stop Project" cleanup and shutdown termination.

### Requirement: Remove browser containers on "Stop Project"

When "Stop Project" is triggered, all browser containers for that project are stopped.

#### Scenario: Stop Project terminates browsers
- **WHEN** a project has browser containers tracked in `TrayState.running`
- **AND** the user clicks "Stop Project" or `MenuCommand::StopProject` fires
- **THEN** all containers with `container_type: ContainerType::Browser` AND matching `project_name` are stopped via `podman stop`

### Requirement: Terminate browser containers on tray shutdown

On tray exit, all browser containers are cleaned up.

#### Scenario: Tray shutdown kills browsers
- **WHEN** the tray is exiting (SIGTERM/SIGINT)
- **AND** `handlers::shutdown_all()` is called
- **THEN** all containers with `container_type: ContainerType::Browser` are stopped

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — integration test required for S2→S3 progression

Gating points:
- Browser container appears in `TrayState.running` after spawn
- Container has correct `ContainerType::Browser` and matching `project_name`
- "Stop Project" terminates browser containers without affecting forge
- Tray shutdown cleans up all browser containers (verified via `podman ps`)

## Observability

Annotations referencing this spec:
```bash
grep -rn "@trace spec:browser-daemon-tracking" src-tauri/ scripts/ crates/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "browser-daemon-tracking"` on browser lifecycle events
- `browser_added = true` when container added to state
- `browser_removed = true` when container removed
- `container_type = "browser"` in container tracking events

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — container spawning and cleanup patterns
- `cheatsheets/runtime/event-driven-monitoring.md` — state tracking and event emission
