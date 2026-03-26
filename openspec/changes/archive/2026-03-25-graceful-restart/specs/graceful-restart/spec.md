# graceful-restart Specification

## Purpose
On application startup, Tillandsias SHALL discover containers from a previous session that are still running and restore the tray menu state to accurately reflect those environments, so users see correct flower icons and lifecycle states immediately without waiting for a new podman event.

## Requirements

### Requirement: Discover running containers on startup
After confirming podman is available and before the initial project scan, the application SHALL query `podman ps` for all containers whose names begin with `tillandsias-`.

#### Scenario: No prior containers running
- **WHEN** the app starts and no `tillandsias-` containers exist
- **THEN** `state.running` remains empty and the menu shows "No running environments"

#### Scenario: One container running from prior session
- **WHEN** the app starts and `podman ps` lists `tillandsias-my-app-aeranthos` in state `running`
- **THEN** `state.running` contains one `ContainerInfo` with `project_name = "my-app"`, `genus = Aeranthos`, `state = Running`
- **AND** the tray menu shows `my-app` with a Bloom icon under "Running Environments" on the first menu rebuild

#### Scenario: Multiple containers across multiple projects
- **WHEN** the app starts and `podman ps` lists containers for two different projects
- **THEN** `state.running` contains one `ContainerInfo` per running container
- **AND** each project submenu shows the correct flower icon

### Requirement: Exclude stopped containers
The application SHALL NOT restore containers that are not in `running` or `created`/`configured` state.

#### Scenario: Stopped container from prior session
- **WHEN** `podman ps -a` includes a `tillandsias-` container with state `exited`
- **THEN** that container is NOT added to `state.running`
- **AND** the corresponding project submenu shows the idle state ("Attach Here" without flower prefix)

#### Scenario: Mixed running and stopped containers
- **WHEN** `podman ps -a` returns two containers — one `running`, one `exited`
- **THEN** only the running container appears in `state.running`

### Requirement: Container name encodes full identity
The application SHALL derive project name and genus exclusively from the container name using the `tillandsias-<project>-<genus>` pattern. No external lookup or persistent storage is required.

#### Scenario: Hyphenated project name
- **WHEN** a container named `tillandsias-my-cool-app-xerographica` is discovered
- **THEN** `parse_container_name` returns `project_name = "my-cool-app"`, `genus = Xerographica`

#### Scenario: Hyphenated genus (Caput-Medusae)
- **WHEN** a container named `tillandsias-myproject-caput-medusae` is discovered
- **THEN** `parse_container_name` returns `project_name = "myproject"`, `genus = CaputMedusae`

#### Scenario: Terminal container ignored
- **WHEN** a container named `tillandsias-myproject-terminal` is running
- **THEN** `parse_container_name` returns `None` (terminal is not a genus slug)
- **AND** the container is silently skipped during discovery

### Requirement: GenusAllocator seeded from discovered containers
After startup discovery, the `GenusAllocator` SHALL be pre-populated with all discovered `(project_name, genus)` pairs so that subsequent "Attach Here" actions allocate non-conflicting genera.

#### Scenario: Attach Here on project with existing running container
- **GIVEN** `tillandsias-my-app-aeranthos` was discovered on startup
- **WHEN** the user clicks "Attach Here" for `my-app`
- **THEN** the allocator assigns a genus other than `Aeranthos` for the new container

#### Scenario: Stop removes genus from allocator
- **GIVEN** an Aeranthos container was seeded into the allocator
- **WHEN** that container stops and is removed from `state.running`
- **THEN** `allocator.release("my-app", Aeranthos)` is called
- **AND** Aeranthos becomes available for future allocation

### Requirement: Discovery errors are non-fatal
If the `podman ps` query fails during startup, the application SHALL log a warning and continue with an empty `state.running` rather than crashing.

#### Scenario: podman ps command fails
- **WHEN** `client.list_containers("tillandsias-")` returns an error
- **THEN** a warning is logged with the error message
- **AND** the app continues starting up normally
- **AND** the menu shows "No running environments"
