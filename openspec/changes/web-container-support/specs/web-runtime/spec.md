## ADDED Requirements

### Requirement: Users can serve static files from the tray menu
A "Serve Here" action SHALL be available in each project's tray submenu, launching a minimal web container.

#### Scenario: Serve Here from tray
- **WHEN** the user clicks "Serve Here" on a project
- **THEN** Tillandsias launches a `tillandsias-web` container, mounts the detected document root at `/var/www:ro`, and displays the URL in the terminal

#### Scenario: Serve Here with document root detection
- **WHEN** the user clicks "Serve Here" on a project with a `dist/` subdirectory
- **THEN** the `dist/` directory is mounted as the document root, not the project root

#### Scenario: Serve Here with explicit config
- **WHEN** the project config specifies `web.document_root = "output/"`
- **THEN** the `output/` directory is mounted as the document root, overriding auto-detection

### Requirement: Users can serve static files from the CLI
A `tillandsias --web <path>` command SHALL launch a web container in CLI mode.

#### Scenario: CLI web launch
- **WHEN** the user runs `tillandsias --web ./my-project`
- **THEN** a web container launches with the detected document root and the URL is printed to stdout

### Requirement: Web containers have zero access to secrets
The web container SHALL not receive any credentials, tokens, API keys, or configuration mounts.

#### Scenario: No secrets in web container
- **WHEN** a web container is running
- **THEN** the only mount is the document root at `/var/www:ro` — no gh credentials, no git config, no Claude directory, no API keys, no cache directory

### Requirement: Web containers bind to localhost only
The web container SHALL only be accessible from the local machine.

#### Scenario: No external access
- **WHEN** a web container is running on port 8080
- **THEN** the port mapping binds to `127.0.0.1:8080` (localhost only), not `0.0.0.0:8080`

### Requirement: Only one web container per project
The system SHALL prevent launching duplicate web containers for the same project.

#### Scenario: Duplicate prevention
- **WHEN** the user clicks "Serve Here" and a web container for the same project is already running
- **THEN** a notification is shown ("Already serving — open http://localhost:<port>") and no new container is created

### Requirement: Web container uses distinct visual indicator
Web containers SHALL use a chain link emoji in the tray menu to distinguish them from forge and maintenance containers.

#### Scenario: Tray menu display
- **WHEN** a web container is running for "my-project"
- **THEN** the tray menu shows it as "🔗 my-project" (distinct from plant emojis for forge and tool emojis for maintenance)
