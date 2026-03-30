## Context

Tillandsias already handles AppImage environment quirks in its podman command constructors — `podman_cmd_sync()` and `podman_cmd()` clear `LD_LIBRARY_PATH` and `LD_PRELOAD` to prevent AppImage's bundled libraries from leaking into podman. However, file descriptor inheritance is a separate leak vector. The squashfuse FUSE mount backing the AppImage creates FDs that the kernel will not allow crun to stat across user namespace boundaries, breaking container launches entirely.

This is a standard POSIX child-process hygiene problem. The conventional solution is to close all non-standard FDs (>= 3) before exec.

## Goals / Non-Goals

**Goals:**
- Eliminate the `crun: cannot stat /proc/self/fd/N: Permission denied` error when running as an AppImage.
- Apply the fix to both sync and async podman command paths.
- Keep the fix minimal and self-contained within existing AppImage compatibility code.

**Non-Goals:**
- Fixing squashfuse or crun upstream.
- Changing AppImage extraction or mount behavior.
- Modifying FD handling on macOS or Windows (neither platform uses AppImage or FUSE in this context).

## Decisions

1. **Use `unsafe { pre_exec }` with `libc::close()` loop.** This is the standard POSIX pattern for FD sanitization before exec. The `pre_exec` hook runs after fork but before exec, which is exactly the right place — it affects only the child process.

2. **Close FDs 3..1024.** A conservative upper bound that covers all realistic FUSE FDs without introducing measurable cost. The loop is O(1024) calls to `close()` on mostly-invalid FDs, which return `EBADF` instantly. No syscall overhead concern.

3. **Linux-only via `#[cfg(target_os = "linux")]`.** AppImage only exists on Linux. macOS has no AppImage and no squashfuse concern. Windows has no FUSE. The compile-time gate keeps the code out of platforms where it is irrelevant.

4. **Always close, not just when `$APPIMAGE` is set.** FD sanitization before exec is good hygiene regardless of whether the process was launched from an AppImage. Gating on `$APPIMAGE` would add complexity for zero benefit — closing already-closed or non-existent FDs is a no-op.

**Alternatives considered and rejected:**

- **`APPIMAGE_EXTRACT_AND_RUN=1`** — This env var tells the AppImage runtime to extract to a temp directory instead of FUSE-mounting. Rejected because it changes startup behavior for all users, adds 2-3 seconds of extraction delay on every launch, and consumes additional disk space. The FD cleanup is strictly better.

- **Only close when `$APPIMAGE` is set** — Rejected because FD sanitization is unconditionally safe and unconditionally beneficial. The conditional adds a code path that is harder to test and provides no advantage.

## Risks / Trade-offs

- **Risk: closing an FD that podman actually needs.** Mitigated by only closing FDs >= 3, preserving stdin (0), stdout (1), and stderr (2). Podman is exec'd as a fresh process and opens its own FDs; it does not inherit application-specific FDs by design.

- **Risk: `unsafe` block.** The `pre_exec` hook requires `unsafe` because it runs between fork and exec where async-signal-safety constraints apply. `libc::close()` is async-signal-safe per POSIX. The loop contains no allocations, no locks, and no non-trivial logic. This is a well-understood safe usage of `unsafe`.

- **Trade-off: closing up to FD 1024 vs. reading `/proc/self/fd/`.** Reading `/proc/self/fd/` would close only actual open FDs, but requires directory iteration in a post-fork context where async-signal-safety matters. The brute-force loop is simpler, safer, and fast enough (< 0.1ms).
