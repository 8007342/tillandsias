---
id: oci-runtime-spec
title: OCI Runtime Specification & crun
category: infra/containers
tags: [oci, crun, runc, runtime, proc, namespaces, fd]
upstream: https://github.com/opencontainers/runtime-spec
version_pinned: "1.2.0"
last_verified: "2026-03-30"
authority: official
---

# OCI Runtime Specification & crun

## Quick Reference

OCI Runtime Spec v1.2.0 defines how a compliant runtime creates and manages containers from a **bundle** (a directory with `config.json` + rootfs).

**Key config.json top-level fields:**

| Field | Purpose |
|-------|---------|
| `ociVersion` | Spec version (MUST be `1.2.0` or compatible) |
| `process` | `args`, `cwd`, `env`, `terminal`, `user`, `rlimits`, `capabilities` |
| `root` | `path` (rootfs location), `readonly` flag |
| `mounts` | Array: `destination`, `source`, `type`, `options` |
| `hooks` | Lifecycle hook arrays (see Hooks section) |
| `linux` | `namespaces`, `uidMappings`, `gidMappings`, `resources`, `seccomp`, `maskedPaths`, `readonlyPaths` |

## Runtime Lifecycle

```
create ──► [creating] ──► [created] ──► start ──► [running] ──► exit ──► [stopped] ──► delete
```

**13-step lifecycle sequence:**

1. `create` invoked with bundle path + container ID
2. Runtime environment created per config.json (namespaces, mounts, cgroups)
3. `prestart` hooks (DEPRECATED)
4. `createRuntime` hooks — runtime namespace, after namespaces created
5. `createContainer` hooks — container namespace, before pivot_root
6. `start` invoked
7. `startContainer` hooks — container namespace, before user process
8. User-specified `process.args` executed
9. `poststart` hooks
10. Container process exits
11. `delete` invoked
12. Resources destroyed (undo step 2)
13. `poststop` hooks

**State values:** `creating`, `created`, `running`, `stopped`

**Operations:** `state`, `create`, `start`, `kill` (signal), `delete` (stopped only)

## crun vs runc

| Aspect | crun | runc |
|--------|------|------|
| Language | C | Go |
| Binary size | ~300 KB | ~15 MB (~50x larger) |
| Memory | Single-digit MB | Higher (Go runtime overhead) |
| Startup speed | ~49% faster in benchmarks | Baseline |
| Scaling | Advantage grows with container count | Degrades under load |
| Spec compliance | Full OCI 1.2.0 | Full OCI 1.2.0 |
| Default on | Fedora, RHEL 9+, Podman 4+ | Docker, older Kubernetes |
| Extras | WASM support (wasmedge/wasmtime handlers), krun (libkrun VMs) | Reference implementation |

crun is the recommended runtime for Podman/Buildah on modern systems. runc remains the safer choice where Go ecosystem maturity and broad community support matter.

## /proc/self/fd Behavior

### Kernel Permission Model

`/proc/[pid]/fd/` entries are symlinks to open file descriptors. Access checks use the kernel's `ptrace_may_access()` with **PTRACE_MODE_READ_FSCREDS**:

- **readlink(2)** on `/proc/self/fd/N` — requires ptrace read access
- **stat(2)** on the symlink target — follows the link, checks target inode permissions
- **open(2)** via `/proc/self/fd/N` — creates a *new* file description; requires target file permissions under the *caller's* credentials, not the original opener's

**Namespace boundary rule:** Access is denied unless:
1. Caller and target are in the **same user namespace** AND caller's capabilities are a superset of target's permitted set, OR
2. Caller has **CAP_SYS_PTRACE** in the target's user namespace

This means after `setuid()` or user namespace transitions, a process may lose the ability to stat its own inherited FDs via `/proc/self/fd/` even though it can still `read(2)`/`write(2)` on them directly.

### FUSE Interaction

When a FUSE-backed FD is inherited into a container, `fstat()` on `/proc/self/fd/N` issues a FUSE request to the filesystem daemon. If the daemon is not yet running (or unreachable from the new namespace), the `fstat()` **hangs indefinitely**. This is why runtimes must handle FD cleanup carefully — iterating `/proc/self/fd` and stat'ing each entry can block on orphaned FUSE descriptors.

## Namespace Configuration

Configured in `linux.namespaces` as an array of objects:

```json
{ "type": "user", "path": "/proc/1234/ns/user" }
```

| Type | Isolates | `path` behavior |
|------|----------|----------------|
| `pid` | Process IDs | Omit path = new namespace |
| `network` | Network stack | Set path = join existing |
| `mount` | Mount table | |
| `ipc` | SysV IPC, POSIX MQs | |
| `uts` | Hostname, domain | |
| `user` | UID/GID mappings | |
| `cgroup` | Cgroup root view | |

**User namespace mappings** (`linux.uidMappings` / `linux.gidMappings`):

```json
{ "containerID": 0, "hostID": 1000, "size": 1 }
```

Maps container UID 0 to host UID 1000. Essential for rootless containers (`--userns=keep-id`).

## Hooks

| Hook | Namespace | Fires at | Deprecated? |
|------|-----------|----------|-------------|
| `prestart` | runtime | After create, before pivot_root | YES (use below) |
| `createRuntime` | runtime | After namespaces created, before pivot_root | No |
| `createContainer` | container | After mounts setup, before pivot_root | No |
| `startContainer` | container | Before user process, during `start` | No |
| `poststart` | runtime | After user process begins | No |
| `poststop` | runtime | After `delete` destroys resources | No |

Hook failure aborts the lifecycle (jumps to step 12) **except** `poststop`, which logs a warning and continues.

Each hook entry: `{ "path": "/usr/bin/hook", "args": ["hook", "--arg"], "env": ["KEY=val"], "timeout": 10 }`

## File Descriptor Management

### crun's Strategy

crun cleans up inherited FDs above the `preserve_fds` threshold (default: close everything >= FD 3).

**Primary path — `close_range(2)` (Linux 5.9+):**

```c
close_range(n, UINT_MAX, 0);              // close immediately
close_range(n, UINT_MAX, CLOSE_RANGE_CLOEXEC);  // mark close-on-exec (5.11+)
```

Single syscall, no `/proc` access needed, no risk of FUSE hangs. Returns 0 on success.

**Fallback path — `/proc/self/fd` iteration:**

When `close_range()` fails (ENOSYS on old kernels, EPERM under restrictive seccomp):

1. Open `/proc/self/fd` as a directory
2. Verify it is real procfs via `fstatfs()` + magic number check (`check_proc_super_magic`) — prevents symlink attacks on fake `/proc`
3. Iterate with `readdir()`, parse FD numbers from entry names
4. Skip FDs below threshold `n` and the dirfd itself
5. Close or set `FD_CLOEXEC` on each remaining FD

**Danger:** Step 3 calls `readdir()` which internally may `fstat()` entries. If a FUSE FD is inherited and the daemon is unreachable, this path can hang. The `close_range()` syscall avoids this entirely.

**Seccomp note:** Some seccomp profiles block `close_range()`, returning EPERM. The Podman fix is `--security-opt seccomp=unconfined` or adding `close_range` to the allowed list.

## Upstream Sources

- [OCI Runtime Spec (GitHub)](https://github.com/opencontainers/runtime-spec) — config.json, runtime.md, lifecycle
- [OCI Runtime Spec v1.2.0 config.md](https://github.com/opencontainers/runtime-spec/blob/main/config.md)
- [crun (GitHub)](https://github.com/containers/crun) — src/libcrun/utils.c (FD management), src/libcrun/linux.c (namespace setup)
- [close_range(2) man page](https://man7.org/linux/man-pages/man2/close_range.2.html)
- [proc_pid_fd(5) man page](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html) — ptrace access mode, PTRACE_MODE_READ_FSCREDS
- [LWN: close_range() design](https://lwn.net/Articles/789238/)
- [LWN: Documenting ptrace access mode checking](https://lwn.net/Articles/692203/)
- [Red Hat: Introduction to crun](https://www.redhat.com/en/blog/introduction-crun)
