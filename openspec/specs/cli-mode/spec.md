<!-- @trace spec:cli-mode -->
# cli-mode Specification

## Status

active

## Purpose
Define the interactive CLI contract for the shipped Tillandsias binary. The binary is a compiled runtime orchestrator: it may embed static assets and metadata, but it MUST NOT depend on repository shell scripts for user-facing runtime behavior.
## Requirements
### Requirement: CLI mode launches container from terminal
Running `tillandsias <path>` SHALL launch an interactive container for the project at the given path, with user-friendly terminal output.

#### Scenario: Launch with project path
- **WHEN** the user runs `tillandsias ~/src/my-project`
- **THEN** the image SHALL be checked/built, a container SHALL start with the project mounted, and the terminal SHALL pass through to the container

#### Scenario: No arguments starts tray mode
- **WHEN** the user runs `tillandsias` with no arguments
- **THEN** the system tray application SHALL start as before

#### Scenario: Help flag
- **WHEN** the user runs `tillandsias --help`
- **THEN** usage information SHALL be printed and the process SHALL exit

### Requirement: Runtime paths are compiled Rust
The user-facing runtime paths `--init`, `--status-check`, `--github-login`, and `--opencode` SHALL be implemented in compiled Rust and SHALL invoke Podman or other stable Unix tools directly. They SHALL NOT shell out to repository scripts during normal runtime operation.

#### Scenario: Init uses direct Podman orchestration
- **WHEN** the user runs `tillandsias --init`
- **THEN** the binary SHALL construct and execute Podman commands directly
- **AND** it SHALL use Containerfiles as the image recipe source
- **AND** it SHALL not call `scripts/build-image.sh`

#### Scenario: Status check uses direct runtime orchestration
- **WHEN** the user runs `tillandsias --status-check`
- **THEN** the binary SHALL orchestrate the enclave stack directly from Rust
- **AND** it SHALL use Podman commands plus the embedded health probe
- **AND** it SHALL not call `scripts/orchestrate-enclave.sh`

### Requirement: Image selection flag
The `--image` flag SHALL allow selecting which container image to use.

#### Scenario: Default image
- **WHEN** no `--image` flag is provided
- **THEN** the "forge" image for the running Tillandsias version SHALL be used

#### Scenario: Custom image name
- **WHEN** the user runs `tillandsias --image web ~/src/my-app`
- **THEN** the `tillandsias-web:v<VERSION>` image for the running Tillandsias version SHALL be used

### Requirement: Debug flag
The `--debug` flag SHALL enable verbose output showing podman commands and internal details.

#### Scenario: Normal mode
- **WHEN** no `--debug` flag is provided
- **THEN** output SHALL show clean user-friendly progress messages

#### Scenario: Debug mode
- **WHEN** `--debug` is provided
- **THEN** output SHALL include the full podman command line and additional diagnostic details

### Requirement: User-friendly output
CLI mode SHALL print formatted progress messages using println!, not raw tracing output.

#### Scenario: Image cached
- **WHEN** the image already exists locally
- **THEN** output SHALL show the image name and cached size

#### Scenario: Image needs building
- **WHEN** the image does not exist locally
- **THEN** output SHALL show a build progress message with estimated time

#### Scenario: Container started
- **WHEN** the container starts successfully
- **THEN** output SHALL show container name, port range, mount paths, and a Ctrl+C hint

#### Scenario: Container exits
- **WHEN** the container process exits
- **THEN** output SHALL show "Environment stopped."

### Requirement: Security flags are non-negotiable
CLI mode SHALL use the same security hardening flags as tray mode.

#### Scenario: Security flags present
- **WHEN** a container is launched via CLI
- **THEN** the podman command MUST include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--security-opt=label=disable`

### Requirement: CLI modes are tray-aware

`tillandsias --debug` and `tillandsias <path>` SHALL spawn the tray icon in addition to their CLI behaviour when `desktop_env::has_graphical_session()` returns `true`. Other CLI subcommands (`--init`, `--update`, `--clean`, `--stats`, `--uninstall`, `--version`, `--help`, `--github-login`) MUST retain their current single-purpose behaviour with no tray spawn.

#### Scenario: Debug mode spawns tray
- **WHEN** the user runs `tillandsias --debug` in a graphical session
- **THEN** the tray icon SHALL appear
- **AND** logs SHALL continue to print to the terminal

#### Scenario: Path attach spawns tray and runs foreground
- **WHEN** the user runs `tillandsias /some/path --opencode` in a graphical session
- **THEN** the tray icon SHALL appear
- **AND** the full enclave stack SHALL launch, including proxy, git mirror, and inference
- **AND** the OpenCode TUI SHALL run in the terminal foreground
- **AND** `--prompt <text>` MAY be provided as an optional initial session seed
- **AND** when the user exits OpenCode, the parent process SHALL return control to the shell with status 0
- **AND** the tray SHALL remain running

#### Scenario: Init / update / version do NOT spawn tray
- **WHEN** the user runs `tillandsias --init`, `--update`, `--version`, or any other one-shot CLI subcommand
- **THEN** no tray child SHALL be spawned
- **AND** the command SHALL exit as it does today

### Requirement: SIGINT triggers clean shutdown on every CLI path

Every CLI path that may have started enclave infrastructure MUST install a SIGINT handler that, on first Ctrl+C, calls `handlers::shutdown_all()`, prints a brief "stopping…" message, and exits with status 0. A second SIGINT during shutdown MAY fall through to default termination so the user can always force-quit.

#### Scenario: Ctrl+C during foreground attach
- **WHEN** the user hits Ctrl+C while `tillandsias /path` is in the foreground OpenCode TUI
- **THEN** SIGINT SHALL be caught
- **AND** `shutdown_all()` SHALL run to stop proxy, git-service, inference, and any tracked forge containers
- **AND** the process SHALL exit with status 0

#### Scenario: Ctrl+C during --debug
- **WHEN** the user hits Ctrl+C while `tillandsias --debug` is streaming logs
- **THEN** SIGINT SHALL be caught
- **AND** the process SHALL exit with status 0
- **AND** the tray child (if spawned) SHALL continue to run independently

#### Scenario: Second Ctrl+C forces exit
- **WHEN** the user hits Ctrl+C twice within a few seconds
- **THEN** the second SIGINT MAY NOT be handled by the cleanup path
- **AND** the process SHALL terminate immediately via the default signal action

## Sources of Truth

- `cheatsheets/runtime/cmd.md` — Cmd reference and patterns
- `cheatsheets/languages/bash.md` — Bash reference and patterns

## Litmus Chain

Smallest actionable boundary:
- `cargo test -p tillandsias-headless opencode_args_mount_workspace_and_prompt status_check_args_probe_proxy_git_and_inference_from_forge shutdown_poll_backoff_doubles_until_capped -- --exact`

Sibling tests:
- `cargo test -p tillandsias-headless podman_runtime_blocker_matches_known_health_failures -- --exact`
- `cargo test -p tillandsias-headless --lib`

Scoped follow-up:
```bash
./build.sh --ci-full --install --filter cli-mode --strict cli-mode
./build.sh --ci-full --install --strict-all
```

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:cli-mode-shape`

Gating points:
- CLI argument construction remains direct and deterministic
- The attach/status-check/shutdown seams stay testable in isolation
- Failure modes are falsifiable through unit-level command-shape checks

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cli-mode" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
