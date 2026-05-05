# browser-daemon-tracking spec

## REQUIREMENTS

### REQ-1: Track browser containers in TrayState
**Given** a browser container (tillandsias-chromium:latest) is spawned via `chromium_launcher::spawn_chromium_window()`
**When** the container starts successfully  
**Then** it is added to `TrayState.running` with:
- `container_type: ContainerType::Browser`
- `port_range: (host_port, host_port)` — allocated from 17000-17999 range
- `project_name` set to the project name

**Rationale**: Consistent with forge/git/proxy tracking. Enables "Stop Project" cleanup and shutdown termination.

### REQ-2: Remove browser containers on "Stop Project"
**Given** a project has browser containers tracked in `TrayState.running`  
**When** the user clicks "Stop Project" or `MenuCommand::StopProject` fires  
**Then** all containers with `container_type: ContainerType::Browser` AND matching `project_name` are stopped via `podman stop`.

### REQ-3: Terminate browser containers on tray shutdown
**Given** the tray is exiting (SIGTERM/SIGINT)  
**When** `handlers::shutdown_all()` is called  
**Then** all containers with `container_type: ContainerType::Browser` are stopped.

**Trace**: @trace spec:browser-daemon-tracking  
**URL**: https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Abrowser-daemon-tracking&type=code
