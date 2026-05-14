# spec: wsl-daemon-orchestration

## Status

active

**Version:** v1.0

**Purpose:** Define how Tillandsias router daemon manages lifecycle and coordination on Windows WSL2, enabling seamless communication between the Windows host tray and Linux containers.

<!-- @trace spec:wsl-daemon-orchestration -->

## Requirements

### Requirement 1: WSL daemon startup via systemd
**Modality:** MUST

On Windows WSL2 distributions where Tillandsias daemon runs, the daemon MUST:
1. Register as a systemd service unit in `/etc/systemd/system/tillandsias-router.service`
2. Configure `Type=notify` with `sd_notify()` readiness signal
3. Set `Restart=always` with `RestartSec=1s` to auto-recover from crashes
4. Enable auto-startup: `systemctl enable tillandsias-router`
5. Bind to a socket location that persists across WSL reboots and is accessible from Windows host

**Measurable:** `systemctl is-active tillandsias-router` returns `active`; `systemctl is-enabled tillandsias-router` returns `enabled`; daemon binary is present at path specified in `ExecStart=`; socket exists at configured path.

**Scenario:** After installing Tillandsias on WSL, reboot the WSL distribution. Verify daemon auto-starts and socket is ready before any other service tries to connect.

---

### Requirement 2: Socket location strategy
**Modality:** MUST

The router daemon socket MUST be created at a location that satisfies three constraints:

1. **Persistent across WSL reboots**: Use `/run/user/1000/tillandsias/` (per-user TMPFS, survives reboots) OR `/mnt/c/Users/<USER>/.tillandsias/sockets/` (Windows-visible, shared with host)
2. **Accessible from Windows host**: Windows PowerShell scripts MUST be able to connect via `\\.\pipe\tillandsias-router` (named pipe) OR via the mounted path above
3. **Correct ownership**: Socket file MUST be readable/writable by the daemon user (non-root if daemon runs unprivileged)

**Measurable:** Socket file exists at configured path; `ls -la <socket>` shows correct user ownership; socket is accessible from Windows PowerShell without `sudo`.

**Scenario:** Configure daemon to use `/run/user/1000/tillandsias/router.sock`. Create a WSL connection from Windows PowerShell to the socket and verify bytes can be written and read.

---

### Requirement 3: Coordinated startup handshake
**Modality:** MUST

When the Windows host tray starts:
1. It MUST verify the WSL distribution is running: `wsl -d <distro> -e true`
2. MUST wait for the router daemon socket to appear (timeout: 30 seconds)
3. MUST only proceed with tray initialization after socket is ready
4. MUST log the handshake result: `socket_ready = true/false`, `wait_time_ms = <elapsed>`

**Measurable:** Windows host process blocks until socket appears OR times out; tray startup log includes `socket_ready` field; socket appears within 5 seconds of WSL boot in normal operation.

**Scenario:** Stop the WSL distribution, start the tray on Windows, and observe it waiting for the socket. Restart WSL and verify the tray detects socket readiness and continues.

---

### Requirement 4: Daemon health monitoring
**Modality:** SHOULD

The daemon SHOULD emit periodic `sd_notify("WATCHDOG=1")` signals to systemd, allowing systemd to detect deadlocks or hangs:
1. SHOULD configure `WatchdogSec=10s` in the service unit
2. SHOULD emit `WATCHDOG=1` signal every 5 seconds from the daemon
3. SHOULD allow systemd to automatically restart the daemon on missed watchdog signal

**Measurable:** `journalctl -u tillandsias-router` shows watchdog heartbeats; if daemon hangs, systemd restart is logged within 10 seconds.

**Scenario:** Start the daemon, observe watchdog signals in journalctl. Pause the daemon process and verify systemd restarts it within 10 seconds.

---

### Requirement 5: Environment variable propagation
**Modality:** MUST

The systemd service unit MUST pass necessary environment variables from host to daemon:
- `TILLANDSIAS_WORKSPACE` — path to Tillandsias workspace (from host, mounted in WSL)
- `RUST_BACKTRACE=1` — enable stack traces on panic
- `WSL_DISTRO_NAME` — current WSL distribution name (auto-set by systemd)

**Measurable:** `systemctl show tillandsias-router -p Environment` lists the variables; daemon process (`ps aux | grep tillandsias-router`) shows env vars in `/proc/<pid>/environ`.

**Scenario:** Update the service unit with custom environment variables, reload systemd, and verify the daemon receives them.

---

### Requirement 6: Daemon process lifecycle
**Modality:** MUST

The daemon MUST:
1. Gracefully handle `SIGTERM` (from `systemctl stop`) by closing all sockets and exiting within 5 seconds
2. Refuse new connections during shutdown (close listener socket first)
3. Flush any pending writes to sockets before exit
4. Emit a final log line: `event = "daemon_shutdown"`, `exit_code = 0`

**Measurable:** `systemctl stop tillandsias-router` exits cleanly within 5 seconds; journalctl shows final shutdown log; no orphaned sockets remain.

**Scenario:** Daemon is running, issue `systemctl stop tillandsias-router`, and verify it exits gracefully with a final log line. Check `lsof | grep tillandsias` to confirm sockets are closed.

---

### Requirement 7: Cross-platform logging
**Modality:** MUST

All daemon events MUST be logged to:
1. systemd journal (via stdout/stderr; systemd captures automatically)
2. File log (optional): `~/.cache/tillandsias/tillandsias-router.log` (if configured)
3. MUST include: `event = "<name>"`, `timestamp = ISO8601`, `spec = "wsl-daemon-orchestration"`

**Measurable:** `journalctl -u tillandsias-router | grep 'spec="wsl-daemon-orchestration"'` returns results; host-side monitoring can read daemon logs from either journalctl (via `wsl -e journalctl`) OR from shared log file.

**Scenario:** Daemon runs and emits various events. Verify both Windows host and WSL can read the logs; verify every log line has the `spec` field.

---

## Invariants

1. **Socket is always single instance**: Only one daemon process can own the socket; port/socket collisions are impossible.
2. **Daemon never blocks on I/O**: All socket reads/writes use non-blocking or async I/O to prevent startup hangs.
3. **Systemd unit is immutable post-install**: Service unit definition is part of the installer; users cannot corrupt it via edit.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:wsl-daemon-orchestration-shape`

Gating points:
- The daemon event stream still carries the WSL daemon trace annotation
- Socket path and watchdog wiring remain present in source
- Falsifiable: missing trace, socket path, or watchdog marker fails the source-shape check

---

## Litmus Tests

### Test 1: Systemd unit exists and is enabled
```bash
# Inside WSL
systemctl list-unit-files | grep tillandsias-router
# Expected: tillandsias-router.service  enabled

systemctl is-enabled tillandsias-router
# Expected: enabled
```

### Test 2: Daemon starts automatically after WSL reboot
```bash
# Inside WSL
systemctl restart wsl  # or sudo systemctl reboot
# After reboot:
systemctl is-active tillandsias-router
# Expected: active
```

### Test 3: Socket is accessible from Windows
```powershell
# From PowerShell on host
$socketPath = "$env:USERPROFILE\.tillandsias\sockets\router.sock"
Test-Path $socketPath
# Expected: True
```

### Test 4: Host tray waits for socket on WSL startup
```powershell
# Stop WSL
wsl --terminate Fedora

# Start tray (should block)
# Start WSL in another terminal
wsl -e true

# Tray should detect socket and continue
# Verify: startup log shows socket_ready = true
```

### Test 5: Daemon restarts on failure
```bash
# Inside WSL, get daemon PID
DAEMON_PID=$(pgrep -f tillandsias-router)

# Kill it
kill -9 $DAEMON_PID

# Verify systemd restarts it
sleep 3
ps aux | grep tillandsias-router | grep -v grep
# Expected: new daemon process (different PID)
```

### Test 6: Graceful shutdown on SIGTERM
```bash
# Inside WSL
systemctl stop tillandsias-router

# Verify exit within 5 seconds
# Check logs:
journalctl -u tillandsias-router -n 3
# Expected: final line shows "daemon_shutdown" event
```

---

## Sources of Truth

- `cheatsheets/runtime/wsl-daemon-patterns.md` — WSL boot config, systemd integration, socket patterns
- `cheatsheets/runtime/systemd-socket-activation.md` — systemd service units, sd_notify protocol, watchdog semantics
- `cheatsheets/runtime/unix-socket-ipc.md` — socket creation, permissions, cross-process communication

---

## Implementation References

- **Service unit**: Installed to `/etc/systemd/system/tillandsias-router.service` by Windows installer
- **Daemon binary**: WSL-specific build of Tillandsias router (Rust, async Tokio)
- **Socket coordination**: `src-tauri/src/main.rs` → `verify_wsl_daemon_socket()` (Windows tray side)
- **Daemon process**: `src-tauri/src/wsl_router.rs` (router implementation in tray binary)
