---
id: fuse-userspace-fs
title: FUSE — Filesystem in Userspace
category: infra/filesystem
tags: [fuse, squashfuse, fuse3, libfuse, fd-inheritance, userspace-filesystem]
upstream: https://www.kernel.org/doc/html/latest/filesystems/fuse.html
version_pinned: "kernel 6.x"
last_verified: "2026-03-30"
authority: official
---

## Architecture

FUSE consists of three components:

1. **fuse.ko** — kernel module, registers a `fuse` filesystem type with the VFS
2. **libfuse** — userspace library (libfuse2 legacy, libfuse3 current)
3. **fusermount3** — setuid helper binary for unprivileged mount/unmount

Communication path for every VFS operation:

```
userspace process → syscall (open/read/stat/…)
  → VFS → fuse.ko → writes request to /dev/fuse fd
  → userspace daemon reads /dev/fuse, handles request, writes reply
  → fuse.ko → returns result to original syscall
```

The `/dev/fuse` character device is the sole channel between kernel and daemon. The daemon opens it, receives a file descriptor, and passes that fd as a mount option (`fd=N`) to `mount(2)`.

## libfuse API Levels

| API | Header | Notes |
|-----|--------|-------|
| High-level | `fuse.h` | Path-based, synchronous, simpler |
| Low-level | `fuse_lowlevel.h` | Inode-based, async, better perf |

libfuse3 is not ABI-compatible with libfuse2. Both can coexist on a system. Distros ship `libfuse3-dev` / `fuse3` packages.

## Mount Lifecycle

1. Daemon opens `/dev/fuse` → gets fd
2. `fusermount3` (or direct `mount(2)` if root) mounts filesystem type `fuse` at mountpoint, passing `fd=N`
3. Daemon enters event loop: read request from fd → process → write reply
4. Unmount: `fusermount3 -u /mountpoint` or `umount /mountpoint`

**Connection lifetime**: exists until the daemon dies OR the filesystem is unmounted. Lazy unmount (`umount -l` / `MNT_DETACH`) detaches the mountpoint but keeps the connection alive until the last reference is released.

**Daemon death**: if the daemon exits without unmounting, the mount becomes a stale endpoint. Any access returns `ENOTCONN` ("Transport endpoint is not connected"). The mount must be cleaned up with `fusermount3 -u` or `umount -l`.

## Key Mount Options

| Option | Effect |
|--------|--------|
| `allow_other` | Lets users other than the mounter access the mount. Requires `user_allow_other` in `/etc/fuse.conf`. |
| `allow_root` | Only root and the mounter can access. Mutually exclusive with `allow_other`. |
| `auto_unmount` | Automatically unmount when the daemon exits. **Caution**: if daemon crashes, mountpoint appears empty instantly — downstream tools (backup, sync) may interpret this as deletion. |
| `default_permissions` | Kernel enforces permission checks based on mode bits instead of delegating to the daemon. |
| `max_read=N` | Cap read request size (default 128K). |
| `nonempty` | Allow mounting over a non-empty directory (libfuse2 only; libfuse3 always allows). |

## fusermount3 vs fusermount

`fusermount` ships with libfuse2, `fusermount3` with libfuse3. Both are setuid-root helpers that perform `mount(2)` on behalf of unprivileged users. On modern distros `fusermount` may be a symlink to `fusermount3`. The helper enforces `allow_other` restrictions and validates mount options before calling `mount(2)`.

## squashfuse — Read-Only SquashFS via FUSE

[squashfuse](https://github.com/vasi/squashfuse) mounts SquashFS archives in userspace without root or kernel squashfs support.

```
squashfuse archive.squashfs /mnt/point
squashfuse_ll archive.squashfs /mnt/point   # low-level API, better perf
```

Supports zlib, LZO, LZMA2 (xz), LZ4, zstd compression. Read-only. Used internally by AppImage type-2 runtime to mount the embedded SquashFS payload.

## FD Inheritance and the Container Problem

This is the core issue when FUSE mounts interact with containers (podman, toolbox, AppImage):

**The problem chain:**

1. An AppImage self-mounts its SquashFS payload via FUSE at a temporary mountpoint
2. The process opens files from that mount — these file descriptors reference inodes on a FUSE filesystem
3. If a child process inherits those fds (or if `/proc/<pid>/fd/` is inspected), crossing a namespace boundary triggers permission checks
4. The kernel returns `EACCES` on `stat()` of a FUSE mount owned by a different user or in a different mount namespace — this is intentional security isolation, not a bug

**`/proc/self/fd` behavior**: `stat()` on `/proc/<pid>/fd/N` where N points to a file on a FUSE mount owned by another user fails with `EACCES`. The kernel restricts cross-user access to FUSE mounts to prevent a malicious FUSE daemon from attacking other users' processes. The owning user (or root) can access via `/proc/<pid>/root/...` if they share the mount namespace.

**Container namespace isolation**: FUSE mounts are visible only within their mount namespace. A container in a separate mount namespace cannot see the host's FUSE mounts. Passing an inherited fd into a container does not grant access to the underlying FUSE filesystem if the daemon is outside the container's namespace.

## FUSE in Containers (Podman)

Running FUSE inside rootless containers requires:

- `/dev/fuse` device access (`--device /dev/fuse`)
- `SYS_ADMIN` capability or a user namespace with mount privileges
- AppArmor may block FUSE mounts even in privileged mode (Ubuntu 25.04+)

Alternative: `unshare -Ufirmp` creates user + mount namespaces where unprivileged `mount(2)` works directly, bypassing fusermount entirely (kernel 4.18+). Contents are visible outside only via `/proc/<pid>/root/`.

## Cleanup on Process Exit

- Kernel does **not** auto-unmount when the daemon exits (unless `auto_unmount` is set)
- The `/dev/fuse` fd is closed, making the connection dead
- Subsequent access to the mountpoint returns `ENOTCONN`
- Cleanup requires explicit `fusermount3 -u` or `umount -l`
- `auto_unmount` delegates cleanup to fusermount3, which stays alive as a child process watching the daemon

## Performance Considerations

Every FUSE operation requires two kernel-userspace context switches (request + reply). Impact:

| Workload | Overhead vs native |
|----------|-------------------|
| Sequential large reads | ~5-10% (amortized over large buffers) |
| Metadata-heavy (stat, readdir) | 20-80% depending on daemon speed |
| Small random I/O (4K) | Up to 80% degradation |
| Cached repeat access | Near zero (page cache serves reads) |

Mitigations: `writeback_cache` mount option, `max_read`/`max_write` tuning, multi-threaded daemon, low-level API. Kernel 6.x adds FUSE-over-io\_uring for batched submission (approximately 2x read bandwidth, 50% latency reduction at high queue depths).

## FUSE on Immutable OS (Silverblue / Kinoite)

On Fedora Silverblue/Kinoite (rpm-ostree):

- `/usr` is read-only, but `fusermount3` is part of the base image (fuse3 package)
- `/etc/fuse.conf` is writable (lives in `/etc`, which is mutable)
- `user_allow_other` can be set persistently
- FUSE mounts work normally in user home dirs (`/var/home/`)
- Inside toolbox containers: `/dev/fuse` is available, fusermount3 works because toolbox shares the host mount namespace and device access
- Flatpak: FUSE access requires explicit portal/permission grants; most Flatpak sandboxes block `/dev/fuse`
