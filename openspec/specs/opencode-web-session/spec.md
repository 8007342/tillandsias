<!-- @trace spec:opencode-web-session -->
# opencode-web-session Specification

## Purpose

How Tillandsias runs a persistent OpenCode Web server per project, maps it to a local-only host port, and renders it in an embedded Tauri webview — including multi-session reattach semantics and shutdown guarantees.

## Requirements

### Requirement: OpenCode Web is the default session agent

The system SHALL treat `SelectedAgent::OpenCodeWeb` as the default value of `AgentConfig::selected` when no explicit choice is present in the user's configuration.

#### Scenario: Fresh install with no config file
- **WHEN** Tillandsias launches for the first time and `~/.config/tillandsias/config.toml` does not exist
- **THEN** the effective `agent.selected` value is `opencode-web`
- **AND** the Seedlings submenu shows "OpenCode Web" as the checked entry

#### Scenario: Existing install with explicit agent choice
- **WHEN** `~/.config/tillandsias/config.toml` already contains `[agent] selected = "opencode"` or `"claude"`
- **THEN** the existing choice is preserved
- **AND** the default flip does not override it

### Requirement: Per-project persistent web container

The system SHALL run at most one web-mode container per project at a time, named exactly `tillandsias-<project>-forge`, launched detached and kept alive until explicit Stop or Tillandsias shutdown.

#### Scenario: First attach creates the container
- **WHEN** the user clicks "Attach Here" on a project and no `tillandsias-<project>-forge` container is running
- **THEN** Tillandsias starts a detached podman container with that name running `opencode serve --hostname 0.0.0.0 --port 4096`
- **AND** records it in `TrayState::running` with `container_type = OpenCodeWeb`

#### Scenario: Re-attach while container already running
- **WHEN** the user clicks "Attach Here" on a project whose `tillandsias-<project>-forge` container is already running
- **THEN** no new container is created
- **AND** a new webview window is opened against the existing host port

#### Scenario: Container survives webview close
- **WHEN** the user closes a webview window for an active web container
- **THEN** the container remains running
- **AND** the tray menu still offers "Stop" for that project

### Requirement: Host port bound to 127.0.0.1 only

The system MUST publish the forge container's port 4096 to the host by binding explicitly to the loopback interface `127.0.0.1`. Binding to `0.0.0.0`, `::`, or any non-loopback interface is forbidden for web-mode containers.

#### Scenario: Port publish arg begins with 127.0.0.1
- **WHEN** Tillandsias constructs the `podman run` command for a web-mode container
- **THEN** the `-p` (or `--publish`) argument begins with `"127.0.0.1:"` before the host port
- **AND** never uses a bare `"<port>:<port>"` or `"0.0.0.0:"` form

#### Scenario: External LAN cannot reach the server
- **WHEN** a remote host on the same LAN attempts to connect to the Tillandsias host on the allocated web port
- **THEN** the connection is refused at the socket layer

### Requirement: Unique host port per concurrent web container

The system SHALL allocate a unique, unused TCP host port for each running web container, drawn from an ephemeral high range, and record it in `ContainerInfo.port_range` as a degenerate `(p, p)` pair.

#### Scenario: Two projects running simultaneously
- **WHEN** two different projects have web containers running at the same time
- **THEN** each has a distinct host port
- **AND** neither binding collides with ports already in use on the host

### Requirement: WebviewWindow launch contract

The system SHALL open a Tauri `WebviewWindow` pointing at `http://127.0.0.1:<host_port>/` for each "Attach Here" click in web mode. Windows MUST have unique labels and a title identifying the project and allocated genus.

#### Scenario: Single webview opens
- **WHEN** the web container is ready (HTTP server responding on the host port)
- **THEN** a `WebviewWindow` opens at the mapped URL
- **AND** the window title contains the project name and genus

#### Scenario: Multiple webviews for one project
- **WHEN** the user clicks "Attach Here" three times on the same project
- **THEN** three independent `WebviewWindow` instances exist
- **AND** all three point at the same `http://127.0.0.1:<host_port>/` URL
- **AND** each has a distinct `WebviewWindow::label`

### Requirement: Stop tears down the web container

The system SHALL expose a per-project "Stop" tray menu action that stops the web container, removes it from `TrayState::running`, and releases its host port. Any open webview windows attached to that container MUST also be closed.

#### Scenario: User clicks Stop
- **WHEN** the user selects "Stop" for a project with a running web container
- **THEN** the container is stopped and removed
- **AND** all webview windows labeled `web-<project>-*` are closed
- **AND** the allocated host port is returned to the pool

### Requirement: Shutdown stops all web containers and closes all webviews

The system SHALL stop every running web-mode container and close every open webview window as part of `shutdown_all()`.

#### Scenario: Tillandsias quits with active web session
- **WHEN** the user quits Tillandsias with at least one web container running
- **THEN** all web containers are stopped as part of the shutdown sequence
- **AND** no `tillandsias-*-forge` container remains in `podman ps`
- **AND** all `WebviewWindow` instances are closed before the process exits


### Requirement: OpenCode Web defaults to dark theme

The forge image SHALL ship a config-overlay file `tui.json` that sets the OpenCode UI theme to a built-in dark theme (`tokyonight`). Project-specific overrides via the user's own `~/.config/opencode/tui.json` (mounted from the project workspace) SHALL continue to win over the overlay default.

#### Scenario: Fresh attach uses dark theme
- **WHEN** a user attaches to a project with no project-level OpenCode theme override
- **THEN** OpenCode reads `theme: "tokyonight"` from `~/.config/opencode/tui.json`
- **AND** the rendered TUI/web UI uses the tokyonight dark palette

#### Scenario: Project override wins
- **WHEN** the project workspace contains a `~/.config/opencode/tui.json` (mounted in)
- **THEN** that file overrides the overlay default
- **AND** the user's chosen theme is rendered

### Requirement: Webview close does not terminate the tray

Closing a `WebviewWindow` whose label starts with `web-` SHALL close only that window. The tray icon, scanner, event loop, and all running containers SHALL remain alive.

#### Scenario: Single webview close
- **WHEN** the user closes a single `web-*` webview window
- **THEN** that window is destroyed
- **AND** the Tauri runtime does NOT emit `RunEvent::ExitRequested`
- **AND** the tray icon remains visible and responsive
- **AND** the underlying `tillandsias-<project>-forge` container keeps running

#### Scenario: Last webview close (no other windows)
- **WHEN** the user closes the only open webview window with no others present
- **THEN** the window is destroyed
- **AND** the Tauri runtime does NOT exit
- **AND** the tray icon and infrastructure persist
