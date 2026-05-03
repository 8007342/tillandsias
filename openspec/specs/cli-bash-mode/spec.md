<!-- @trace spec:cli-bash-mode -->
# cli-bash-mode Specification

## Status

status: active

## Purpose
TBD - created by archiving change iconography-gh-auth-bash-mode. Update Purpose after archive.
## Requirements
### Requirement: Bash troubleshooting mode
The CLI SHALL accept a `--bash` flag that overrides the container entrypoint with `/bin/bash` for troubleshooting.

#### Scenario: Attach with bash
- **WHEN** `tillandsias ../project/ --bash` is run
- **THEN** a container starts for the project with `/bin/bash` as the entrypoint instead of the default

#### Scenario: Bash mode with other flags
- **WHEN** `tillandsias ../project/ --bash --debug` is run
- **THEN** the container starts with `/bin/bash` and debug output is shown

#### Scenario: Help includes bash flag
- **WHEN** `tillandsias --help` is run
- **THEN** the `--bash` flag is listed with a description like "Drop into bash shell for troubleshooting"

### Requirement: --bash launches fish with welcome
The `--bash` CLI flag SHALL launch fish (not bash) with the welcome message.

#### Scenario: CLI bash mode shows welcome
- **WHEN** `tillandsias ../project/ --bash` is run
- **THEN** fish starts with the welcome message, landing in the project directory

#### Scenario: Host OS passed to container
- **WHEN** the container starts
- **THEN** the host OS info is available via `TILLANDSIAS_HOST_OS` environment variable for the welcome script to display


## Sources of Truth

- `cheatsheets/languages/bash.md` — Bash reference and patterns
- `cheatsheets/runtime/cmd.md` — Cmd reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Bash mode launches without persistence; environment and history are session-only
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:cli-bash-mode" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
