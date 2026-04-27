## ADDED Requirements

### Requirement: shutdown_all verifies post-sweep state and escalates stragglers

After the existing graceful-stop and orphan-sweep phases of `shutdown_all` complete, the application SHALL run a verification phase that polls `podman ps --filter name=tillandsias-` until it returns zero rows or a 5-second budget elapses. Any container still listed at the end of the budget SHALL be escalated through `podman kill --signal=KILL` followed by `podman rm -f`. Any container that survives that escalation SHALL trigger a last-resort SIGTERM to its `conmon` process (matched by the substring pattern `conmon.*--name tillandsias-` against the process command line). The verification phase SHALL run synchronously, blocking `shutdown_all` from returning until either zero stragglers remain or the budget is exhausted.

#### Scenario: Clean shutdown — zero stragglers
- **WHEN** the user clicks `Quit Tillandsias` and every existing graceful stop succeeds
- **THEN** the verification phase polls `podman ps --filter name=tillandsias-` once, sees zero rows, and returns within the first 200 ms tick
- **AND** an `accountability = true, category = "enclave"` log line records `verify_shutdown_clean: zero stragglers`

#### Scenario: One container survived graceful stop — SIGKILL escalation
- **WHEN** the verification phase finds one `tillandsias-*` container still running after the existing sweep
- **THEN** the application invokes `podman kill --signal=KILL <name>` (NOT default-signal), waits 500 ms, then invokes `podman rm -f <name>`
- **AND** an `accountability = true, category = "enclave"` log line records the escalation with the offending container name
- **AND** the next verification poll confirms the container is gone

#### Scenario: SIGKILL did not clear — conmon pkill escalation (Unix only)
- **WHEN** a container is still listed after `podman kill --signal=KILL` + `podman rm -f`
- **THEN** the application sends SIGTERM (NOT SIGKILL) to any `conmon` process whose command line matches `conmon.*--name tillandsias-`
- **AND** an `accountability = true, category = "enclave"` log line records the conmon escalation with the offending container name
- **AND** the next verification poll either confirms the container is gone or hits the 5-second budget

#### Scenario: Verification budget exhausted — log and exit anyway
- **WHEN** the 5-second verification budget elapses with one or more stragglers still listed
- **THEN** an `error!(accountability = true, category = "enclave")` log line records each remaining container name with reason `survived_all_escalation`
- **AND** `shutdown_all` returns so the tray can call `app_handle.exit(0)` rather than blocking the user indefinitely

### Requirement: kill_container accepts an explicit signal

The `ContainerLauncher::kill_container` (or its underlying client method) SHALL accept an optional signal argument so callers can distinguish "send the default signal" (today's behavior — SIGTERM) from "force SIGKILL". The verification phase of `shutdown_all` SHALL always pass `Some("KILL")` because graceful has already been attempted by the time it runs.

#### Scenario: Default-signal kill preserved for existing callers
- **WHEN** existing callers (notably `ContainerLauncher::stop`'s timeout fallback) invoke `kill_container` with no signal argument
- **THEN** the underlying `podman kill <name>` invocation has no `--signal` flag (preserving today's behavior)

#### Scenario: Verification phase forces SIGKILL
- **WHEN** the verification phase invokes `kill_container(name, Some("KILL"))`
- **THEN** the underlying `podman kill --signal=KILL <name>` invocation runs

## Sources of Truth

- `docs/cheatsheets/tray-state-machine.md` — Three-tier shutdown escalation and log interpretation
- `docs/cheatsheets/script-hardening.md` — Signal handling and process termination patterns
