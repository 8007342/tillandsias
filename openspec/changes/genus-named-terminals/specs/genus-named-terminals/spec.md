## NEW Requirements

### Requirement: Terminal containers use genus naming convention
Terminal (Maintenance) containers SHALL use the same `tillandsias-{project}-{genus}` naming convention as forge containers.

#### Scenario: Terminal container gets genus name
- **GIVEN** a user clicks Maintenance for project "my-app"
- **WHEN** the terminal container is created
- **THEN** it is named `tillandsias-my-app-{genus}` where `{genus}` is an allocated genus slug (e.g., `aeranthos`)

#### Scenario: Terminal container tracked in state
- **GIVEN** a maintenance terminal is launched for project "my-app"
- **WHEN** the container starts
- **THEN** it appears in `state.running` with `container_type == Maintenance`

#### Scenario: Multiple maintenance terminals per project
- **GIVEN** a maintenance terminal is already running for project "my-app" with genus Aeranthos
- **WHEN** the user clicks Maintenance again for the same project
- **THEN** a second terminal launches with a different genus (e.g., Ionantha) and both appear in Running Environments

### Requirement: ContainerType distinguishes forge from maintenance
Each `ContainerInfo` entry SHALL carry a `container_type` field indicating whether it is a Forge or Maintenance container.

#### Scenario: Forge container typed correctly
- **GIVEN** a user clicks Attach Here for project "my-app"
- **WHEN** the container is pre-registered in state
- **THEN** its `container_type` is `Forge`

#### Scenario: Maintenance container typed correctly
- **GIVEN** a user clicks Maintenance for project "my-app"
- **WHEN** the container is pre-registered in state
- **THEN** its `container_type` is `Maintenance`

#### Scenario: Discovered container defaults to Forge
- **GIVEN** a podman event arrives for an unknown `tillandsias-*` container
- **WHEN** the event loop discovers and registers it
- **THEN** its `container_type` defaults to `Forge`

### Requirement: Menu detects maintenance by container type
The project submenu SHALL detect running maintenance containers by checking `container_type == Maintenance` rather than matching a `-terminal` name suffix.

#### Scenario: Maintenance indicator shown when maintenance running
- **GIVEN** a container with `container_type == Maintenance` exists for project "my-app"
- **WHEN** the project submenu is built
- **THEN** the Maintenance menu item shows the running flower icon

#### Scenario: Maintenance indicator absent when only forge running
- **GIVEN** only a forge container (no maintenance) exists for project "my-app"
- **WHEN** the project submenu is built
- **THEN** the Maintenance menu item shows the idle pick icon

### Requirement: Podman events process terminal containers
Terminal containers SHALL be processed by the podman event handler through the standard genus-based name parsing.

#### Scenario: Terminal container stop event processed
- **GIVEN** a maintenance terminal `tillandsias-my-app-aeranthos` is running
- **WHEN** a podman Stopped event arrives for that container
- **THEN** the container is removed from `state.running` and its genus is released

## MODIFIED Requirements

### Requirement: Forge don't-relaunch guard unchanged
The Attach Here don't-relaunch guard SHALL continue to prevent duplicate forge environments for the same project, based on `assigned_genus`.

#### Scenario: Second Attach Here blocked
- **GIVEN** a forge container is running for project "my-app"
- **WHEN** the user clicks Attach Here for the same project
- **THEN** the action is blocked with a notification pointing to the existing window
