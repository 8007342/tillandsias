## Context

Tillandsias is a tray-only app (no main window). Multiple instances create duplicate tray icons, each running independent scanners and podman event streams. There's no current mechanism to prevent this. The CLI attach mode (`tillandsias attach <project>`) should NOT be affected — only the tray mode needs singleton enforcement.

## Goals / Non-Goals

**Goals:**
- Prevent duplicate tray instances via PID lock file
- Detect and replace stale locks from crashed instances
- Clean up lock file on graceful shutdown
- Work cross-platform (Linux, macOS, Windows)

**Non-Goals:**
- IPC between instances (no "raise window" since there's no window)
- Using the Tauri single-instance plugin (it's designed for windowed apps that need to focus/raise on second launch — overkill for a headless tray app)
- Sending commands from a second instance to the first

## Decisions

### Decision 1: PID lock file over Tauri plugin

**Choice**: Custom PID lock file at `$XDG_RUNTIME_DIR/tillandsias.lock`.

**Alternatives considered**:
- *tauri-plugin-single-instance*: Designed for windowed apps. Calls a callback to raise/focus the existing window. Tillandsias has no window — the callback would be a no-op. Adds a dependency for something a 30-line module handles.
- *Unix domain socket*: More robust for IPC, but we don't need IPC. Second instance should just exit.
- *Named mutex (Windows)*: Would need platform-specific code. PID file works on Windows too via `%TEMP%`.

**Rationale**: A PID lock file is the simplest cross-platform solution for "exit if already running." It handles the crash case (stale PID check) and needs zero dependencies.

### Decision 2: Lock file location

**Choice**: Platform-specific runtime directories:
- Linux: `$XDG_RUNTIME_DIR/tillandsias.lock` (falls back to `/tmp/tillandsias-$UID.lock`)
- macOS: `$TMPDIR/tillandsias.lock`
- Windows: `%TEMP%\tillandsias.lock`

**Rationale**: `XDG_RUNTIME_DIR` is per-user, per-session, and auto-cleaned on logout. This is exactly what it's designed for. Fallback to `/tmp` with UID suffix prevents cross-user conflicts.

### Decision 3: Stale lock detection via /proc (Linux) and platform equivalents

**Choice**: Read PID from lock file, check if that PID is alive AND is a tillandsias process.

**Linux**: Check `/proc/<pid>/exe` symlink resolves to the tillandsias binary, or check `/proc/<pid>/comm` contains `tillandsias`.
**macOS**: Use `kill(pid, 0)` to check liveness (signal 0 doesn't kill, just checks).
**Windows**: `OpenProcess` with the PID to check if it exists.

**Rationale**: Just checking if a PID is alive isn't enough — PIDs get recycled. Verifying the process name prevents false positives after a crash + PID reuse.

### Decision 4: Check happens before Tauri builder

**Choice**: Run the singleton check in `main()` before `tauri::Builder::default()`, right after CLI argument parsing.

**Rationale**: If we're going to exit, do it immediately. Don't initialize the async runtime, scanner, or Tauri subsystems only to tear them down. The check is synchronous and takes microseconds.

## Risks / Trade-offs

- **[PID recycling]** → Mitigated by checking process name, not just PID existence. Vanishingly unlikely that a recycled PID runs another process named `tillandsias-tray`.
- **[Stale lock after hard crash]** → Handled by stale detection. If the PID in the lock file doesn't correspond to a running tillandsias process, the lock is replaced.
- **[Race condition between check and write]** → Extremely unlikely in practice (user would need to launch two instances in the same millisecond). Could use `flock()` for atomic locking, but adds complexity for a near-impossible scenario.
