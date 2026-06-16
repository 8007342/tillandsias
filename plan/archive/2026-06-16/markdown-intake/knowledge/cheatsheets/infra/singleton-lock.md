---
id: singleton-lock
title: Process Singleton & Lock File Patterns
category: infra/patterns
tags: [singleton, lock-file, pid-file, flock, xdg-runtime-dir, process-management]
upstream: https://man7.org/linux/man-pages/man2/flock.2.html
version_pinned: "POSIX"
last_verified: "2026-03-30"
authority: official
---

# Process Singleton & Lock File Patterns

## PID File Pattern

Write the process ID to a known path on startup; check it on subsequent launches.

```
Startup:
  1. Read PID from /run/user/<UID>/myapp.pid (or /tmp/myapp.pid)
  2. If file exists, check /proc/<pid>/cmdline for your process name
  3. If process alive and matches -> exit (already running)
  4. If stale (no process or wrong name) -> overwrite with own PID
  5. If no file -> write own PID
```

**Stale detection**: Always verify `/proc/<pid>/cmdline` or `/proc/<pid>/exe`, not just
PID existence. PIDs wrap around and get reused.

**Fatal flaw**: TOCTOU race. Between reading the PID file and writing your own, another
instance can do the same. Two instances both conclude the lock is stale and both start.

## flock(2) Advisory Locking

The reliable POSIX approach. The kernel manages the lock -- no race conditions.

```c
int fd = open("/run/user/1000/myapp.lock", O_CREAT | O_RDWR, 0600);
if (flock(fd, LOCK_EX | LOCK_NB) == -1) {
    // EWOULDBLOCK -> another instance holds the lock
    exit(1);
}
// Lock acquired. Keep fd open for process lifetime.
```

| Flag      | Meaning                                      |
|-----------|----------------------------------------------|
| `LOCK_EX` | Exclusive lock (one holder at a time)        |
| `LOCK_SH` | Shared lock (multiple readers)               |
| `LOCK_NB` | Non-blocking; fail with `EWOULDBLOCK` if held|
| `LOCK_UN` | Release (also happens on `close(fd)`)        |

**Auto-release**: When the process exits (including crash, SIGKILL), the fd closes and the
lock releases. No stale locks. This is the key advantage over PID files.

**Inheritance**: Locks survive `fork()`. Child inherits the fd and the lock. `exec()` drops
it only if `O_CLOEXEC` is set.

## XDG_RUNTIME_DIR

Best location for lock files on Linux desktop/session systems.

- Path: `/run/user/<UID>` (set by systemd at login)
- Permissions: `0700`, owned by user
- Backed by tmpfs (RAM) -- fast, no disk I/O
- Cleaned on logout -- no stale files across sessions
- Guaranteed to support `AF_UNIX` sockets, `flock`, symlinks, notifications

```
Lock file path: $XDG_RUNTIME_DIR/myapp.lock
Socket path:    $XDG_RUNTIME_DIR/myapp.sock
```

**Fallback**: If `XDG_RUNTIME_DIR` is unset (SSH sessions, cron, containers), fall back to
`/tmp/myapp-<uid>.lock`. Never hard-code `/run/user/1000`.

## Socket-Based Singleton

Bind a Unix domain socket; if binding fails, an instance is already running.

```
Startup:
  1. Try bind() on a well-known socket path (or abstract name)
  2. EADDRINUSE -> another instance running; optionally send it a message
  3. Success -> listen(); you are the singleton
```

**Abstract sockets** (Linux-only): Prefix name with `\0` (or `@` in socat notation).
Lives in kernel namespace, not filesystem. No cleanup needed, no stale files. Disappears
when all fd references close.

**Windows equivalent**: Named pipes (`\\.\pipe\myapp`). Create the pipe; if it already
exists, another instance owns it. Can also send activation messages to the first instance.

**Advantage over flock**: Enables IPC. Second instance can tell the first to raise its
window or open a file, then exit.

## Cross-Platform Approaches

| Platform | Recommended mechanism              | Auto-cleanup |
|----------|------------------------------------|--------------|
| Linux    | `flock(2)` on `$XDG_RUNTIME_DIR`  | Yes          |
| macOS    | `flock(2)` on `$TMPDIR` or socket | Yes          |
| Windows  | `CreateMutexW` (named mutex)      | Yes          |

**Windows named mutex**: Call `CreateMutexW` with a global name. If `GetLastError()`
returns `ERROR_ALREADY_EXISTS`, another instance is running. Kernel auto-releases on
process exit. Beware: any process can create a mutex with your name first (DoS vector).

**macOS launchd**: For daemons managed by launchd, singleton behavior is built in.
`KeepAlive` + `MachServices` ensures one instance. Not applicable to user-launched apps.

## Rust Crate Options

**`fd-lock`** (by yoshuawuyts): Wraps `flock` on Unix, `LockFileEx` on Windows. Provides
`RwLock`-style API on file descriptors. Minimal, no dependencies beyond libc/winapi.

```rust
use fd_lock::RwLock;
let mut lock = RwLock::new(std::fs::File::create(lock_path)?);
match lock.try_write() {
    Ok(_guard) => { /* singleton acquired; guard auto-releases on drop */ }
    Err(_) => { eprintln!("already running"); std::process::exit(1); }
}
```

**`fslock`**: Similar file-based locking. Locks are per-handle (not per-process), which
matches Windows semantics but differs from `flock` on Unix. Lock file persists after close.

## Common Gotchas

**NFS**: `flock(2)` does NOT work on NFS (silently succeeds without locking on many
kernels). Use `fcntl(F_SETLK)` if you must lock over NFS, but avoid network filesystems
for singleton locks entirely.

**Containers and PID namespaces**: PID 1 inside a container is not PID 1 on the host.
PID file checks across namespace boundaries are meaningless. Use socket or flock patterns
with a shared volume mount if cross-container singleton is needed.

**macOS and `O_EXLOCK`**: macOS supports `O_EXLOCK` flag on `open()` for atomic
open-and-lock. Not portable to Linux.

**Stale PID files after crash**: `flock` auto-releases. PID files do not. If you must use
PID files, always validate the PID is alive AND belongs to your application.

**File descriptor leaks**: If you `fork()` without `O_CLOEXEC` and exec a child, the child
inherits the lock fd. The lock persists until both parent and child close it.

## Decision Checklist

1. Need IPC with existing instance? -> **Unix domain socket** (or named pipe on Windows)
2. Just need "am I already running?" -> **flock(2)** via `fd-lock` crate
3. Targeting Windows only? -> **Named mutex** via `CreateMutexW`
4. Must work on NFS? -> **Socket-based** (never flock on NFS)
5. Inside containers? -> **Socket on shared volume** or **flock on shared mount**
