<!-- @trace spec:tray-cli-coexistence -->
# tray-cli-coexistence Specification

## Status

status: active

## Purpose

Contract for running the Tillandsias tray icon concurrently with CLI modes, detecting whether the host has a graphical session, and tolerating broken stdout/stderr without taking the process down.

## Requirements


### Requirement: Detect graphical session for tray-aware CLI

The system SHALL provide a `desktop_env::has_graphical_session() -> bool` helper used by every CLI mode entry point to decide whether to spawn the tray icon alongside the CLI behaviour.

#### Scenario: Linux with DISPLAY set
- **WHEN** the process is invoked on Linux and `$DISPLAY` is non-empty
- **THEN** `has_graphical_session()` returns `true`

#### Scenario: Linux with WAYLAND_DISPLAY set
- **WHEN** the process is invoked on Linux, `$DISPLAY` is unset, and `$WAYLAND_DISPLAY` is non-empty
- **THEN** `has_graphical_session()` returns `true`

#### Scenario: Headless Linux
- **WHEN** the process is invoked on Linux and neither `$DISPLAY` nor `$WAYLAND_DISPLAY` is set
- **THEN** `has_graphical_session()` returns `false`

#### Scenario: macOS and Windows default
- **WHEN** the process is invoked on macOS or Windows
- **THEN** `has_graphical_session()` returns `true` unless overridden

#### Scenario: TILLANDSIAS_NO_TRAY override
- **WHEN** the env var `TILLANDSIAS_NO_TRAY=1` is set on any platform
- **THEN** `has_graphical_session()` returns `false`

### Requirement: CLI modes spawn the tray when a graphical session is available

When a CLI subcommand starts and `has_graphical_session()` returns `true`, the system SHALL spawn a detached child process running the tray (no positional arguments) before continuing the CLI behaviour. The child SHALL detach from the parent's process group.

#### Scenario: --debug from a graphical terminal
- **WHEN** the user runs `tillandsias --debug` in a desktop session
- **THEN** a detached child running the tray is spawned
- **AND** the parent process continues to print log output to the terminal

#### Scenario: Path attach from a graphical terminal
- **WHEN** the user runs `tillandsias /path` in a desktop session
- **THEN** a detached child running the tray is spawned
- **AND** the parent process continues with the existing terminal-foreground attach flow

#### Scenario: Headless environment skips tray spawn
- **WHEN** the user runs `tillandsias --debug` or `tillandsias /path` and `has_graphical_session()` returns `false`
- **THEN** no tray child is spawned
- **AND** the CLI behaves exactly as it does today

#### Scenario: Tray already running
- **WHEN** the user runs `tillandsias /path` while a tray instance is already up
- **THEN** the spawned child fails the singleton guard and exits silently
- **AND** the CLI parent continues without surfacing an error to the user

### Requirement: Tray remains running after CLI session ends

When the CLI parent finishes its foreground work (OpenCode TUI exit, `--debug` interrupted, etc.), the tray child SHALL continue to run independently.

#### Scenario: OpenCode foreground exits
- **WHEN** the user quits OpenCode in a `tillandsias /path` session
- **THEN** the CLI parent exits with status 0
- **AND** the tray child remains running, visible in the system tray
- **AND** infrastructure containers (proxy, git-service, inference) remain running

### Requirement: Broken stdout/stderr does not terminate the process

The tracing/logging layer SHALL tolerate `BrokenPipe` / `EPIPE` errors on the stderr writer by silently dropping the offending write. The file appender SHALL continue to receive every event.

#### Scenario: User closes the terminal without sending a signal
- **WHEN** a Tillandsias process is writing logs to stderr and the host terminal is closed
- **THEN** subsequent stderr writes return `BrokenPipe` and are silently dropped
- **AND** the process does not panic or exit
- **AND** the file appender at `~/.local/state/tillandsias/tillandsias.log` continues to capture events

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — tray process isolation and lifecycle guarantees

Gating points:
- CLI detects graphical session correctly across Linux/macOS/Windows
- Tray spawns as detached child process when graphical session detected
- Tray remains running after CLI foreground completes
- Broken pipe errors on stderr do not crash the process

## Sources of Truth

- `cheatsheets/runtime/systemd-socket-activation.md` — Systemd Socket Activation reference and patterns
- `cheatsheets/languages/rust.md` — Rust reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-cli-coexistence" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
