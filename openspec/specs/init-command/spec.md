# init-command Specification

## Purpose
The `tillandsias --init` command pre-builds all container images required by the application (proxy, forge, git, inference) so they are ready before the user opens the tray. Supports incremental builds with progress persistence and detailed debug output for troubleshooting.

## Sources of Truth
- `cheatsheets/runtime/podman.md` — Podman commands for image management and debugging
- `cheatsheets/runtime/wsl-on-windows.md` — WSL commands for Windows builds
- `docs/cross-platform-builds.md` — Cross-platform build strategy

## Requirements
### Requirement: Init CLI command
The application SHALL provide a `tillandsias --init` command that pre-builds all container images.

#### Scenario: First run
- **WHEN** `tillandsias --init` is run and no forge image exists
- **THEN** the forge image is built, progress is shown on stdout, and the command exits with code 0

#### Scenario: Images already exist
- **WHEN** `tillandsias --init` is run and the forge image already exists
- **THEN** the command prints "Images up to date" and exits immediately

#### Scenario: Build in progress
- **WHEN** `tillandsias --init` is run and another init process is already building
- **THEN** the command waits for the existing build to complete instead of starting a duplicate

#### Scenario: Help text
- **WHEN** `tillandsias --help` is run
- **THEN** the `--init` flag is listed with description "Pre-build container images"

### Requirement: Debug output with actionable commands
The application SHALL provide `--debug` flag with `tillandsias --init --debug` that outputs actual podman commands for troubleshooting.

#### Scenario: Debug output shows container IDs
- **WHEN** `tillandsias --init --debug` is run and a container build fails
- **THEN** the output SHALL include:
  - The container ID that failed
  - Copy/paste command: `podman logs <container_id>`
  - Copy/paste command: `podman run --rm <image_tag> tail -10 /var/log/<relevant>.log`
  - For forge: `podman run --rm tillandsias-forge:<tag> tail -10 /var/log/tillandsias/*.log`

#### Scenario: Debug output for each failed container
- **WHEN** multiple containers fail during `tillandsias --init --debug`
- **THEN** each failed container SHALL have its own section with:
  - Container ID
  - Image tag
  - `podman logs <id>` command
  - `podman run --rm <tag> tail -10 <log_path>` command
  - Last 10 lines of the relevant log file inside the container

### Requirement: Individual image builds
The application SHALL support building individual images in isolation for debugging and development.

#### Scenario: Build forge only
- **WHEN** `tillandsias --init --image forge` is run
- **THEN** only the forge image is built (tagged as tillandsias-forge:<version>)

#### Scenario: Build proxy only
- **WHEN** `tillandsias --init --image proxy` is run
- **THEN** only the proxy image is built (tagged as tillandsias-proxy:<version>)

#### Scenario: Build git only
- **WHEN** `tillandsias --init --image git` is run
- **THEN** only the git image is built (tagged as tillandsias-git:<version>)

#### Scenario: Build inference only
- **WHEN** `tillandsias --init --image inference` is run
- **THEN** only the inference image is built (tagged as tillandsias-inference:<version>)

### Requirement: Progress persistence
The application SHALL save progress to disk so interrupted builds can be resumed.

#### Scenario: Resume after interruption
- **WHEN** `tillandsias --init` is interrupted (Ctrl+C) after building proxy
- **THEN** re-running `tillandsias --init` skips proxy and continues with remaining images

#### Scenario: Progress saved on failure
- **WHEN** `tillandsias --init` fails on forge but succeeds on proxy
- **THEN** proxy is marked complete in progress file and forge is marked failed

### Requirement: Summary report
The application SHALL print a summary report at the end of `--init` with troubleshooting commands.

#### Scenario: Summary with failed images
- **WHEN** `tillandsias --init` completes with some failures
- **THEN** the summary SHALL include:
  - Total images attempted
  - Completed count
  - Failed count
  - Time elapsed
  - For each failed image: error message and troubleshooting commands
  - List of copy/paste commands to retry or force rebuild

