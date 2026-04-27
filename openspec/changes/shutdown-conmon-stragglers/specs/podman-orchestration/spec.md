## ADDED Requirements

### Requirement: Container teardown escalates to SIGKILL on verification failure

When the post-shutdown verification phase finds a `tillandsias-*` container still running after the graceful-stop pass, the application SHALL invoke `podman kill --signal=KILL <name>` (force SIGKILL) rather than relying on `podman kill` with no `--signal` argument (which sends SIGTERM by default). After the SIGKILL, the application SHALL invoke `podman rm -f <name>` to free the container slot and any associated mounts. This escalation path is invoked only by the verification phase of `shutdown_all` — not by per-container Stop actions or the routine teardown loop.

#### Scenario: Verification finds straggler, escalates to SIGKILL
- **WHEN** the verification phase polls `podman ps --filter name=tillandsias-` and finds a non-empty result after the graceful pass
- **THEN** each listed container is killed with `podman kill --signal=KILL <name>`
- **AND** each is then removed with `podman rm -f <name>`

#### Scenario: Routine teardown still uses graceful path
- **WHEN** a per-container Stop action (`MenuCommand::Stop`-equivalent or the standard shutdown loop) runs
- **THEN** the launcher's existing graceful path is used — SIGTERM with 10-second grace, fallback to default-signal `podman kill`, no SIGKILL escalation at this layer

### Requirement: Conmon SIGTERM is the last-resort orphan wipe (Unix only)

When even SIGKILL + `podman rm -f` fails to clear a `tillandsias-*` container, the application SHALL identify any `conmon` process whose command-line arguments contain `--name tillandsias-` and SHALL send it SIGTERM (NOT SIGKILL). This step is conditionally compiled to Unix targets only (`#[cfg(unix)]`); Windows hosts use the Windows Container Service which has no `conmon` analogue and SHALL skip this step.

The conmon SIGTERM SHALL be SIGTERM specifically, not SIGKILL, so conmon has the chance to flush the container's exit status file and avoid leaving podman with a permanently-zombie state record.

#### Scenario: Container survives SIGKILL, conmon pkill clears it (Unix)
- **WHEN** a `tillandsias-*` container is still listed after `podman kill --signal=KILL` + `podman rm -f` on Linux or macOS
- **THEN** the application sends SIGTERM to every matching `conmon` process
- **AND** the next verification poll either confirms the container is gone or hits the global 5-second budget

#### Scenario: Conmon SIGKILL is not used
- **WHEN** the conmon escalation runs
- **THEN** the signal sent is SIGTERM, NOT SIGKILL
- **AND** conmon's exit-status-file flush is allowed to complete before the process exits

#### Scenario: Windows skips conmon escalation
- **WHEN** the verification phase runs on Windows
- **THEN** the conmon SIGTERM step is skipped (no-op)
- **AND** the SIGKILL escalation is the terminal escalation step on Windows

## Sources of Truth

- `docs/cheatsheets/script-hardening.md` — SIGTERM vs SIGKILL tradeoffs, signal handling best practices
- `docs/cheatsheets/tray-state-machine.md` — Three-tier shutdown escalation reference
