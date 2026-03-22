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

