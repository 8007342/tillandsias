# Graceful Shutdown Specification

## Status

status: active
promoted-from: direct
annotation-count: 8

## Purpose

Define the graceful shutdown contract for Tillandsias headless binary: signal handling (SIGTERM/SIGINT), container lifecycle management with timeout, resource cleanup, exit codes, and verification that no ephemeral artifacts remain after shutdown.

## Requirements

### Requirement: SIGTERM and SIGINT trigger graceful shutdown immediately

The application MUST register signal handlers for SIGTERM and SIGINT at startup. When either signal is received, the application MUST begin the graceful shutdown sequence without delay.

#### Scenario: SIGTERM begins graceful shutdown

- **WHEN** the application is running in headless mode
- **AND** SIGTERM is sent to the process
- **THEN** the shutdown sequence MUST begin within 100 ms
- **AND** the application MUST emit `"Received shutdown signal"` to stderr
- **AND** the shutdown sequence MUST NOT be blocked by ongoing operations

#### Scenario: SIGINT begins graceful shutdown

- **WHEN** the application is running in headless mode
- **AND** SIGINT is sent to the process (e.g., via Ctrl+C)
- **THEN** the shutdown sequence MUST begin within 100 ms
- **AND** the application MUST emit `"Received shutdown signal"` to stderr
- **AND** multiple SIGINT signals MUST be idempotent (no crash, no double-shutdown)

### Requirement: All managed containers receive stop signals before force-kill

When shutdown begins, all tillandsias-managed containers MUST be stopped gracefully before any force-kill is applied. The stop signal gives containers up to 30 seconds (default, overridable via `--shutdown-timeout`) to exit cleanly.

#### Scenario: Containers receive SIGTERM before SIGKILL

- **WHEN** graceful shutdown begins
- **AND** there are tillandsias-managed containers running (e.g., proxy, forge, git-service, inference)
- **THEN** each container MUST receive a stop signal (SIGTERM to PID 1 inside the container)
- **AND** the system MUST wait up to 30 seconds for containers to exit
- **AND** only if a container fails to exit within the timeout MUST it be force-killed (SIGKILL)

#### Scenario: Containers without workloads stop immediately

- **WHEN** graceful shutdown begins
- **AND** tillandsias-managed containers are idle (no active tasks)
- **THEN** containers MUST exit within 5 seconds of receiving the stop signal
- **AND** no SIGKILL MUST be needed for idle containers

### Requirement: Graceful shutdown has a configurable timeout with force-kill fallback

The default graceful shutdown timeout is 30 seconds. This timeout is overridable via `--shutdown-timeout <seconds>` CLI flag. If any container does not exit within the timeout, it MUST be force-killed.

#### Scenario: Default 30s timeout for graceful shutdown

- **WHEN** graceful shutdown begins
- **AND** no `--shutdown-timeout` flag is provided
- **THEN** the application MUST wait up to 30 seconds for all containers to stop
- **AND** after 30 seconds, any remaining containers MUST be force-killed
- **AND** the total shutdown time (with at most 2-3 containers) MUST NOT exceed 35 seconds

#### Scenario: Custom timeout via --shutdown-timeout flag

- **WHEN** the application starts with `--shutdown-timeout 60`
- **AND** graceful shutdown is triggered
- **THEN** the application MUST respect the 60-second timeout
- **AND** after 60 seconds, remaining containers MUST be force-killed
- **AND** invalid timeout values (negative, non-numeric) MUST be rejected at startup with a clear error message

#### Scenario: Force-kill after timeout prevents hangs

- **WHEN** a container is unresponsive and does not exit within the timeout
- **THEN** the application MUST force-kill (SIGKILL / `podman kill`) the container
- **AND** the force-kill MUST succeed immediately (not block)
- **AND** the application MUST NOT hang waiting for unresponsive containers

### Requirement: Exit code reflects shutdown status

The application MUST exit with exit code 0 on successful graceful shutdown. If an unrecoverable error occurs during shutdown (e.g., podman unavailable, permission denied on cleanup), the application MUST exit with exit code 1 or higher.

#### Scenario: Clean shutdown returns exit code 0

- **WHEN** graceful shutdown completes successfully
- **AND** all containers are stopped
- **AND** all cleanup operations succeed
- **THEN** the application MUST exit with code 0
- **AND** stderr MUST contain `"Graceful shutdown completed"`

#### Scenario: Unrecoverable error during shutdown returns non-zero

- **WHEN** an unrecoverable error occurs during shutdown (e.g., podman kill command fails due to permissions)
- **THEN** the application MUST exit with code 1 or higher
- **AND** stderr MUST log the error with context (e.g., container name, error message)
- **AND** the application MUST NOT suppress the error

### Requirement: No stale sockets remain after shutdown

After the application exits, no tillandsias-managed sockets or named pipes MUST be left in `/tmp/`. All IPC endpoints (control sockets, log pipes) MUST be cleaned up as part of shutdown.

#### Scenario: Socket cleanup on exit

- **WHEN** graceful shutdown completes
- **THEN** `find /tmp -name 'tillandsias*.sock' 2>/dev/null` MUST return 0 results
- **AND** no sockets matching the pattern `tillandsias-*-control.sock` MUST remain
- **AND** any cleanup error MUST be logged and MUST NOT prevent the process from exiting

#### Scenario: Log file cleanup on exit

- **WHEN** graceful shutdown completes
- **THEN** `find /tmp -name 'tillandsias-init-*.log' 2>/dev/null` MUST return 0 results
- **AND** temporary log files created during initialization MUST be removed
- **AND** persistent logs (if any) MUST be preserved according to `--log-enclave` policy

### Requirement: No stale mounts remain after shutdown

After the application exits, no tillandsias-managed mount points MUST remain. All bind mounts, overlayfs layers, and tmpfs mounts MUST be unmounted as part of shutdown.

#### Scenario: Mounts are fully unmounted after shutdown

- **WHEN** graceful shutdown completes
- **THEN** `mount | grep tillandsias` MUST return empty (0 matches)
- **AND** all bind-mounted project directories MUST be unmounted
- **AND** all container-managed overlay layers MUST be unmounted
- **AND** any mount cleanup error MUST be logged with context (mount point, error)

## Invariants

1. **Signal handlers are always registered** — SIGTERM and SIGINT handlers MUST be registered before the main event loop starts. Unregistered signal delivery MUST fail the startup and exit with code 1.

2. **Shutdown is idempotent** — Multiple signals (SIGTERM + SIGINT, or repeated SIGTERM) MUST not cause double-shutdown, resource leaks, or crashes. The first signal starts shutdown; subsequent signals are acknowledged but do not restart the sequence.

3. **Shutdown always completes** — The application MUST exit within `30s + 5s` (default timeout + cleanup overhead) under all circumstances (success, partial failure, podman unavailable). Infinite waits are NOT allowed.

4. **Container state is observable** — During shutdown, the application MUST emit JSON event logs (`{"event":"app.stopping"}`, `{"event":"container.stopped"}`) so observers (CI, logging systems, users) can track progress.

5. **Cleanup is reversible** — All ephemeral state (sockets, mounts, secrets) MUST be cleaned in reverse order of creation. If cleanup of resource A fails, cleanup of resource B MUST still proceed; failures MUST be logged but MUST NOT cascade.

6. **Exit code is deterministic** — The exit code depends only on the outcome of the shutdown sequence, not on application uptime or prior operations. Replay the shutdown sequence with the same state MUST yield the same exit code.

## Bindings

### Litmus Tests

Bind to tests in `openspec/litmus-tests/litmus-binary-e2e-smoke.yaml`:
- **Steps 3–5** verify socket/mount/log cleanup:
  - Step 3: `verify no stale sockets after status-check` (pattern: `CLEAN`)
  - Step 4: `verify no stale mounts after status-check` (pattern: `CLEAN`)
  - Step 5: `verify init log cleaned up` (pattern: `CLEAN`)

Gating points:
- Signals are caught and acknowledged (stderr: `"Received shutdown signal"`)
- Shutdown completes within SLA (headless: < 5s; with containers: 30s + overhead)
- No ephemeral artifacts remain after exit (sockets, mounts, logs)
- Exit code is 0 on success, non-zero on error

### Cheatsheets

- `cheatsheets/runtime/signal-handling-unix.md` — Signal delivery, handler registration, POSIX semantics
- `cheatsheets/runtime/podman-container-cleanup.md` — Container stop semantics, timeout handling, force-kill
- `cheatsheets/utils/tillandsias-resources-ephemeral.md` — Socket/mount/log cleanup patterns and gotchas

## Sources of Truth

- `cheatsheets/runtime/signal-handling-unix.md` — POSIX signal handling semantics and best practices
- `cheatsheets/runtime/podman-container-cleanup.md` — Podman stop/kill timeout and cleanup mechanics
- `cheatsheets/utils/tillandsias-resources-ephemeral.md` — Ephemeral resource cleanup discipline and verification
