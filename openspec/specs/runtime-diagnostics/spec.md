<!-- @trace spec:runtime-diagnostics -->

# runtime-diagnostics Specification

## Status

status: active

## Purpose

Capture and surface container failure diagnostics (exit code, stderr, resource exhaustion, timeout) in a structured format that enables root-cause analysis without exposing raw container internals to the user. Emphasize ephemeral failure data: diagnostics are collected only for the container's lifetime, then discarded.

This spec ensures:
- Container crashes produce actionable error messages
- Timeout and OOM conditions are detectable
- Stderr is captured and analyzed for common patterns
- Ephemeral data is not persisted across container launches

## Requirements

### Requirement: Capture exit code and termination signal

When a container exits, the runtime MUST record the exit code, any termination signal, and the duration the container ran.

#### Scenario: Normal exit
- **WHEN** a container exits cleanly (status 0)
- **THEN** the tray MUST log `container_exit_code = 0, duration_seconds = N`
- **AND** the user MUST NOT be notified of a failure (cleanup succeeded)

#### Scenario: Abnormal exit
- **WHEN** a container exits with non-zero status (e.g., 139 from SIGSEGV)
- **THEN** the tray MUST log `container_exit_code = 139, signal = "SIGSEGV"` with `category = "runtime-diagnostics"`
- **AND** a toast or tray message MUST tell the user "Build failed. Check logs for details."
- **AND** the error message MUST NOT expose the exit code or signal name to the user

#### Scenario: Timeout termination
- **WHEN** a container exceeds a build timeout (default 3600 seconds)
- **THEN** the tray MUST send SIGTERM to the container
- **AND** MUST log `timeout_seconds = 3600, terminated_reason = "timeout"`
- **AND** the user MUST see "Build timed out after 1 hour"

### Requirement: Capture container stderr during execution

The container's stderr output MUST be streamed to a temporary log file during execution and MUST be deleted on shutdown.

#### Scenario: Stderr collection
- **WHEN** a container is running and outputs to stderr
- **THEN** the tray MUST capture stderr to `$XDG_RUNTIME_DIR/tillandsias-<project>-<genus>-stderr.log` (tmpfs-backed on Linux)
- **AND** the log file MUST be world-unreadable (0400)
- **AND** the log MUST be available for inspection during the container's lifetime

#### Scenario: Stderr destruction
- **WHEN** the container stops (graceful or crash)
- **THEN** the stderr log is deleted from the runtime directory
- **AND** stderr history does NOT persist to disk or `.tillandsias/` cache
- **AND** if the container is restarted, a fresh stderr log is created

#### Scenario: Stderr size limit
- **WHEN** a container writes > 100 MB to stderr (runaway logging)
- **THEN** the tray truncates the log to the last 10 MB
- **AND** logs `stderr_truncated = true, max_bytes = 104857600, kept_tail_bytes = 10485760`
- **AND** continues capture without blocking the container

### Requirement: Detect resource exhaustion conditions

The runtime SHALL detect OOM (out of memory) kills, disk full conditions, and file descriptor exhaustion from container-side signals.

#### Scenario: OOM kill detected
- **WHEN** a container receives SIGKILL due to memory pressure
- **THEN** the tray detects the condition via cgroup memory limits or podman events
- **AND** logs `oom_kill = true, memory_limit_bytes = N, memory_used_bytes = M` with `category = "runtime-diagnostics"`
- **AND** the user sees "Build ran out of memory. Increase container memory and retry."

#### Scenario: Disk full detection
- **WHEN** a container attempts to write and receives ENOSPC
- **THEN** the tray logs stderr pattern match: `"No space left on device"`
- **AND** logs `disk_full_detected = true, mount_point = "/"`
- **AND** the user sees "Build failed: disk space exhausted"

#### Scenario: File descriptor exhaustion
- **WHEN** a container receives EMFILE (too many open files)
- **THEN** the tray detects via stderr analysis
- **AND** logs `fd_exhaustion_detected = true, ulimit = "default"`
- **AND** the user sees "Build failed: too many open files (increase ulimit)"

### Requirement: Analyze stderr for common failure patterns

The runtime SHALL scan captured stderr for patterns indicating common failures and surface human-readable explanations.

#### Scenario: Compilation error detection
- **WHEN** stderr contains `"error[E"` (Rust compiler pattern)
- **THEN** the tray extracts the first 3 compilation errors
- **AND** displays them as "Compilation failed" with line numbers and error text
- **AND** does NOT expose the full stderr wall to the user

#### Scenario: Network error detection
- **WHEN** stderr contains `"Connection refused"` or `"Name or service not known"`
- **THEN** the tray logs `network_error_detected = true, pattern = "Connection refused"`
- **AND** suggests to the user "Check that required services are running"

#### Scenario: Permission error detection
- **WHEN** stderr contains `"Permission denied"` or `"Operation not permitted"`
- **THEN** the tray logs `permission_error_detected = true`
- **AND** suggests "Check file/directory ownership or container capabilities"

### Requirement: Ephemeral diagnostics lifecycle

Diagnostic data (stderr logs, exit codes, failure analysis) SHALL be ephemeral, collected only during container execution, and destroyed on shutdown.

#### Scenario: Ephemeral stderr log
- **WHEN** a container is running
- **THEN** stderr is captured to a tmpfs-backed runtime file
- **AND** the file is accessible for debugging during the container's lifetime
- **AND** on container stop, the file is immediately deleted
- **AND** the next container start creates a fresh log file

#### Scenario: No diagnostic persistence
- **WHEN** checking project cache or config after container shutdown
- **THEN** no stderr logs, exit codes, or failure history is found
- **AND** the only persistent record is a one-line summary in tray logs (e.g., "Project X failed: timeout")

#### Scenario: Log cleanup on tray exit
- **WHEN** the tray exits while containers are still running
- **THEN** all ephemeral stderr logs are deleted via cleanup signal handler
- **AND** next tray launch has no inherited diagnostic data

### Requirement: Litmus test — runtime diagnostics capture and lifecycle

Critical verification paths:

#### Test: Exit code captured
```bash
# Start container that exits with known status
podman run --rm --name test-diag alpine sh -c "exit 42"

# Verify tray logs captured exit code
grep -i "exit_code.*42" ~/.config/tillandsias/logs/
# Expected: log line with container_exit_code = 42
```

#### Test: Stderr captured
```bash
# Start container that logs to stderr
podman run --rm --name test-stderr alpine sh -c "echo 'error: test' >&2; sleep 10" &

# Check runtime stderr log exists
ls /run/user/$(id -u)/tillandsias-*-stderr.log
# Expected: log file exists and is readable

# Kill container and verify log cleaned up
podman stop test-stderr
ls /run/user/$(id -u)/tillandsias-*-stderr.log 2>&1
# Expected: no such file (cleaned up)
```

#### Test: OOM detection
```bash
# Create container with very low memory limit
podman run --rm --memory=10m --name test-oom alpine \
  sh -c "dd if=/dev/zero of=/tmp/big bs=1M count=100"

# Wait for OOM
sleep 5

# Check tray logs for OOM marker
grep -i "oom_kill\|out.*memory" ~/.config/tillandsias/logs/
# Expected: oom_kill = true or similar
```

#### Test: Stderr pattern matching
```bash
# Container with compilation error (simulated)
podman run --rm --name test-rust alpine sh -c "echo 'error[E0425]: cannot find value' >&2" &

# Wait and check tray logs for pattern detection
sleep 1
grep -i "compilation.*error\|error_pattern" ~/.config/tillandsias/logs/
# Expected: compilation error detected

podman stop test-rust
```

#### Test: Ephemeral cleanup
```bash
# Run complete container lifecycle
podman run --rm --name test-lifecycle alpine sleep 30 &
PID=$!

# Verify stderr log exists while running
sleep 1
ls /run/user/$(id -u)/tillandsias-*-lifecycle-stderr.log
# Expected: log exists

# Stop container
wait $PID

# Verify log is cleaned up
ls /run/user/$(id -u)/tillandsias-*-lifecycle-stderr.log 2>&1
# Expected: no such file
```

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Diagnostics are ephemeral; diagnostic data doesn't persist
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:runtime-diagnostics" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "runtime-diagnostics"` on all diagnostic events
- `container_exit_code = N` on container exit
- `termination_signal = "SIGSEGV"` on signal termination
- `oom_kill = true` on OOM detection
- `disk_full_detected = true` on disk exhaustion
- `stderr_captured_bytes = N` on capture completion
- `pattern_detected = "<name>"` on error pattern match
- `duration_seconds = N` on container lifetime

## Sources of Truth

- `cheatsheets/runtime/container-health-checks.md` — exit code semantics and health probe integration
- `cheatsheets/runtime/event-driven-monitoring.md` — container event streaming and failure detection
- `cheatsheets/observability/cheatsheet-metrics.md` — structured logging for failure analysis
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — tmpfs-backed ephemeral file layout

