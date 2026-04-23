# cli-mode Specification

## Purpose
TBD - created by archiving change cli-mode. Update Purpose after archive.
## Requirements
### Requirement: CLI mode launches container from terminal
Running `tillandsias <path>` SHALL launch an interactive container for the project at the given path, with user-friendly terminal output.

#### Scenario: Launch with project path
- **WHEN** the user runs `tillandsias ~/src/my-project`
- **THEN** the image is checked/built, a container starts with the project mounted, and the terminal passes through to the container

#### Scenario: No arguments starts tray mode
- **WHEN** the user runs `tillandsias` with no arguments
- **THEN** the system tray application starts as before

#### Scenario: Help flag
- **WHEN** the user runs `tillandsias --help`
- **THEN** usage information is printed and the process exits

### Requirement: Image selection flag
The `--image` flag SHALL allow selecting which container image to use.

#### Scenario: Default image
- **WHEN** no `--image` flag is provided
- **THEN** the "forge" image (`tillandsias-forge:latest`) is used

#### Scenario: Custom image name
- **WHEN** the user runs `tillandsias --image web ~/src/my-app`
- **THEN** the `tillandsias-web:latest` image is used

### Requirement: Debug flag
The `--debug` flag SHALL enable verbose output showing podman commands and internal details.

#### Scenario: Normal mode
- **WHEN** no `--debug` flag is provided
- **THEN** output shows clean user-friendly progress messages

#### Scenario: Debug mode
- **WHEN** `--debug` is provided
- **THEN** output includes the full podman command line and additional diagnostic details

### Requirement: User-friendly output
CLI mode SHALL print formatted progress messages using println!, not raw tracing output.

#### Scenario: Image cached
- **WHEN** the image already exists locally
- **THEN** output shows the image name and cached size

#### Scenario: Image needs building
- **WHEN** the image does not exist locally
- **THEN** output shows a build progress message with estimated time

#### Scenario: Container started
- **WHEN** the container starts successfully
- **THEN** output shows container name, port range, mount paths, and a Ctrl+C hint

#### Scenario: Container exits
- **WHEN** the container process exits
- **THEN** output shows "Environment stopped."

### Requirement: Security flags are non-negotiable
CLI mode SHALL use the same security hardening flags as tray mode.

#### Scenario: Security flags present
- **WHEN** a container is launched via CLI
- **THEN** the podman command includes `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--security-opt=label=disable`



### Requirement: CLI modes are tray-aware

`tillandsias --debug` and `tillandsias <path>` SHALL spawn the tray icon in addition to their CLI behaviour when `desktop_env::has_graphical_session()` returns `true`. Other CLI subcommands (`--init`, `--update`, `--clean`, `--stats`, `--uninstall`, `--version`, `--help`, `--github-login`) SHALL retain their current single-purpose behaviour with no tray spawn.

#### Scenario: Debug mode spawns tray
- **WHEN** the user runs `tillandsias --debug` in a graphical session
- **THEN** the tray icon appears
- **AND** logs continue to print to the terminal

#### Scenario: Path attach spawns tray and runs foreground
- **WHEN** the user runs `tillandsias /some/path` in a graphical session
- **THEN** the tray icon appears
- **AND** the OpenCode TUI runs in the terminal foreground
- **AND** when the user exits OpenCode, the parent process returns control to the shell with status 0
- **AND** the tray remains running

#### Scenario: Init / update / version do NOT spawn tray
- **WHEN** the user runs `tillandsias --init`, `--update`, `--version`, or any other one-shot CLI subcommand
- **THEN** no tray child is spawned
- **AND** the command exits as it does today

### Requirement: SIGINT triggers clean shutdown on every CLI path

Every CLI path that may have started enclave infrastructure SHALL install a SIGINT handler that, on first Ctrl+C, calls `handlers::shutdown_all()`, prints a brief "stopping…" message, and exits with status 0. A second SIGINT during shutdown SHALL fall through to default termination so the user can always force-quit.

#### Scenario: Ctrl+C during foreground attach
- **WHEN** the user hits Ctrl+C while `tillandsias /path` is in the foreground OpenCode TUI
- **THEN** SIGINT is caught
- **AND** `shutdown_all()` runs to stop proxy, git-service, inference, and any tracked forge containers
- **AND** the process exits with status 0

#### Scenario: Ctrl+C during --debug
- **WHEN** the user hits Ctrl+C while `tillandsias --debug` is streaming logs
- **THEN** SIGINT is caught
- **AND** the process exits with status 0
- **AND** the tray child (if spawned) continues to run independently

#### Scenario: Second Ctrl+C forces exit
- **WHEN** the user hits Ctrl+C twice within a few seconds
- **THEN** the second SIGINT is not handled by the cleanup path
- **AND** the process terminates immediately via the default signal action
