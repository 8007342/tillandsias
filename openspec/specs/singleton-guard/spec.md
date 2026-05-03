<!-- @trace spec:singleton-guard -->
# singleton-guard Specification

## Status

status: active

## Purpose
TBD - created by archiving change singleton-instance. Update Purpose after archive.
## Requirements
### Requirement: Single instance enforcement
The application SHALL ensure only one tray-mode instance runs per user session. CLI attach mode is not affected.

#### Scenario: First launch
- **WHEN** tillandsias starts in tray mode and no lock file exists
- **THEN** a lock file is created with the current PID and the application starts normally

#### Scenario: Second launch with live instance
- **WHEN** tillandsias starts in tray mode and a lock file exists with a PID belonging to a running tillandsias process
- **THEN** the new instance exits immediately with exit code 0 and a log message indicating an existing instance is running

#### Scenario: Launch after crash (stale lock)
- **WHEN** tillandsias starts in tray mode and a lock file exists but the PID does not correspond to a running tillandsias process
- **THEN** the stale lock file is replaced with the current PID and the application starts normally

#### Scenario: CLI attach mode unaffected
- **WHEN** tillandsias starts in CLI attach mode (e.g., `tillandsias attach <project>`)
- **THEN** no singleton check is performed and the command runs regardless of other instances

### Requirement: Lock file location
The lock file SHALL be placed in a platform-appropriate runtime directory.

#### Scenario: Linux with XDG_RUNTIME_DIR
- **WHEN** the app starts on Linux and `$XDG_RUNTIME_DIR` is set
- **THEN** the lock file is created at `$XDG_RUNTIME_DIR/tillandsias.lock`

#### Scenario: Linux without XDG_RUNTIME_DIR
- **WHEN** the app starts on Linux and `$XDG_RUNTIME_DIR` is not set
- **THEN** the lock file is created at `/tmp/tillandsias-<uid>.lock`

#### Scenario: macOS
- **WHEN** the app starts on macOS
- **THEN** the lock file is created at `$TMPDIR/tillandsias.lock`

#### Scenario: Windows
- **WHEN** the app starts on Windows
- **THEN** the lock file is created at `%TEMP%\tillandsias.lock`

### Requirement: Lock file cleanup on exit
The lock file SHALL be removed when the application exits gracefully.

#### Scenario: Normal shutdown
- **WHEN** the application receives a shutdown signal (SIGTERM, SIGINT, or tray Quit action)
- **THEN** the lock file is removed before the process exits

#### Scenario: Crash
- **WHEN** the application crashes or is killed with SIGKILL
- **THEN** the lock file remains but is detected as stale on next launch

### Requirement: Stale lock detection
The singleton check SHALL verify that the PID in the lock file belongs to an active tillandsias process, not just any process.

#### Scenario: PID alive and is tillandsias
- **WHEN** the lock file contains PID 12345 and process 12345 is a running tillandsias-tray process
- **THEN** the lock is considered valid and the new instance exits

#### Scenario: PID alive but different process (recycled PID)
- **WHEN** the lock file contains PID 12345 and process 12345 exists but is NOT tillandsias-tray
- **THEN** the lock is considered stale and the new instance takes over

#### Scenario: PID does not exist
- **WHEN** the lock file contains PID 12345 and no process with PID 12345 exists
- **THEN** the lock is considered stale and the new instance takes over


## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Singleton enforcement is ephemeral; guards are cleaned on process exit
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:singleton-guard" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
