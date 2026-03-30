## Why

When Tillandsias runs as an AppImage on Linux, the squashfuse FUSE mount creates file descriptors that are inherited by child processes. When `podman run` is invoked, crun (the OCI runtime) iterates `/proc/self/fd/` and attempts to stat each FD. The kernel denies access to the FUSE FDs across the user namespace boundary, producing:

```
Error: crun: cannot stat `/proc/self/fd/19`: Permission denied: OCI permission denied
```

No upstream fix exists in squashfuse, AppImage, or crun. The responsibility falls on the application spawning child processes to sanitize inherited file descriptors.

## What Changes

Add a `pre_exec` hook in both `podman_cmd_sync()` and `podman_cmd()` (the sync and async podman command constructors) that closes all file descriptors >= 3 before exec'ing podman. This extends the existing AppImage compatibility logic that already clears `LD_LIBRARY_PATH` and `LD_PRELOAD` in these functions.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **podman-orchestration** — podman command construction gains FD sanitization to prevent FUSE FD leakage into child processes on Linux.

## Impact

- `crates/tillandsias-podman/src/lib.rs` — `podman_cmd_sync()` and `podman_cmd()` gain `pre_exec` FD cleanup hooks, gated behind `#[cfg(target_os = "linux")]`.
