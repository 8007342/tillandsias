<!-- @trace spec:install-progress -->
## Status

status: active

## ADDED Requirements

### Requirement: Spinner during tool installation
The system SHALL display an animated terminal spinner while installing tools (npm install for openspec, claude-code; curl for opencode). The spinner MUST show a localized status message describing what is being installed.

#### Scenario: npm install with spinner
- **WHEN** the entrypoint runs `npm install -g` for openspec or claude-code
- **THEN** a spinner animation displays on stderr with the localized installing message (e.g., "Installing OpenSpec...")
- **THEN** on success, the spinner is replaced with the localized success message
- **THEN** on failure, the spinner is cleared and the error output is shown

#### Scenario: curl install with spinner
- **WHEN** the entrypoint runs the opencode curl installer
- **THEN** a spinner animation displays on stderr with the localized installing message
- **THEN** on completion, the spinner is replaced with the result message

#### Scenario: Non-TTY environment
- **WHEN** stderr is not a terminal (piped or redirected)
- **THEN** the system SHALL print a single status line instead of animating a spinner

### Requirement: Spinner cleanup on exit
The system SHALL kill any running spinner background process when the entrypoint exits, including on signals (SIGINT, SIGTERM).

#### Scenario: Ctrl+C during install
- **WHEN** the user sends SIGINT during an npm install with an active spinner
- **THEN** the spinner process is terminated and the terminal cursor is restored

### Requirement: Spinner helper in lib-common.sh
The system SHALL provide a reusable `spin` function in `lib-common.sh` that accepts a message string and a command to run, displays the spinner during execution, and returns the command's exit code.

#### Scenario: spin function interface
- **WHEN** an entrypoint calls `spin "$L_INSTALLING_OPENSPEC" npm install -g ...`
- **THEN** the spinner displays the message while npm runs
- **THEN** the function returns npm's exit code

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:install-progress" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
