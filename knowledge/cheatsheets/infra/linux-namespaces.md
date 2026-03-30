---
id: linux-namespaces
title: Linux Namespaces
category: infra/containers
tags: [linux, namespaces, user, mount, pid, network, unshare, nsenter]
upstream: https://man7.org/linux/man-pages/man7/namespaces.7.html
version_pinned: "kernel 6.x"
last_verified: "2026-03-30"
authority: official
---

# Linux Namespaces

## Quick Reference

| Namespace | Clone Flag         | `/proc/pid/ns/` | Isolates                    | Since  |
|-----------|--------------------|------------------|-----------------------------|--------|
| Mount     | `CLONE_NEWNS`      | `mnt`            | Mount points                | 2.4.19 |
| UTS       | `CLONE_NEWUTS`     | `uts`            | Hostname, NIS domain        | 2.6.19 |
| IPC       | `CLONE_NEWIPC`     | `ipc`            | SysV IPC, POSIX MQs         | 2.6.19 |
| PID       | `CLONE_NEWPID`     | `pid`            | Process IDs                 | 2.6.24 |
| Network   | `CLONE_NEWNET`     | `net`            | Network stack               | 2.6.29 |
| User      | `CLONE_NEWUSER`    | `user`           | UIDs, GIDs, capabilities    | 3.8    |
| Cgroup    | `CLONE_NEWCGROUP`  | `cgroup`         | Cgroup root directory       | 4.6    |
| Time      | `CLONE_NEWTIME`    | `time`           | CLOCK_MONOTONIC, BOOTTIME   | 5.6    |

Syscalls: `clone(2)` (create child in new ns), `unshare(2)` (move current process), `setns(2)` (join existing ns via fd).

## User Namespace

The foundation for unprivileged containers. A process creating a user namespace gains **all capabilities** within it, even as an unprivileged user on the host.

**UID/GID mapping** (write-once per namespace):
- `/proc/<pid>/uid_map` and `/proc/<pid>/gid_map` -- format: `<ns_id> <host_id> <count>`
- Unprivileged writes: only single-line identity mapping (map your own UID)
- Privileged writes: arbitrary mappings, limited to 340 lines (kernel 6.x)

**Subordinate IDs** enable multi-UID mapping without root:
- `/etc/subuid` and `/etc/subgid` -- format: `<user>:<start>:<count>`
- `newuidmap(1)` / `newgidmap(1)` -- setuid helpers that write to `uid_map`/`gid_map` using ranges from subuid/subgid

**Capability rules**: capabilities in a user namespace grant power only over resources owned by that namespace. Creating a user namespace resets the effective/permitted sets to full within the new ns. The `--userns=keep-id` flag (podman) maps host UID to the same UID inside.

## Mount Namespace

Created with `CLONE_NEWNS`. Child inherits parent's mount table (copy-on-write semantics).

**Propagation types** (set via `mount --make-*`):

| Type          | Flag             | Receives events | Sends events |
|---------------|------------------|-----------------|--------------|
| `shared`      | `MS_SHARED`      | Yes             | Yes          |
| `slave`       | `MS_SLAVE`       | Yes             | No           |
| `private`     | `MS_PRIVATE`     | No              | No           |
| `unbindable`  | `MS_UNBINDABLE`  | No              | No (+ no bind source) |

Shared mounts form **peer groups**. Slave mounts have a master peer group. Unbindable prevents mount-point explosion in recursive bind scenarios. Default propagation for new mounts since systemd: `shared`.

## PID Namespace

- First process becomes PID 1 (init) -- must reap orphans or the namespace accumulates zombies.
- Nested PID namespaces: a process has a PID in each ancestor namespace up to the root. `getpid()` returns the PID in the process's own namespace.
- `/proc` must be mounted inside the PID namespace to reflect the new PID numbering (`mount -t proc proc /proc`).
- Signals: only processes in the same or an ancestor PID namespace can send signals. PID 1 in a child namespace gets default SIGKILL/SIGSTOP immunity (like real init).

## Network Namespace

Each network namespace has its own interfaces, routing tables, firewall rules, `/proc/net`, and port space.

**Connectivity patterns for rootless networking:**

| Method       | Mechanism             | Default since |
|--------------|-----------------------|---------------|
| `pasta`      | tap + L4 socket relay | Podman 5.0    |
| `slirp4netns`| User-mode TCP/IP (libslirp) | Podman <5.0 |
| `veth` pair  | Kernel virtual ethernet (needs CAP_NET_ADMIN in root netns) | -- |
| Bridge       | `ip link add br0 type bridge` + veth pairs | -- |

Pasta copies host network config into the namespace (no NAT). Slirp4netns creates a private 10.0.2.0/24 with NAT. Both avoid requiring root.

## Other Namespaces

**IPC** (`CLONE_NEWIPC`): isolates SysV shared memory, semaphores, message queues, and POSIX message queues. Each namespace has independent `ipcs` state.

**UTS** (`CLONE_NEWUTS`): isolates `hostname` and `domainname`. Changing hostname inside does not affect host.

**Cgroup** (`CLONE_NEWCGROUP`): virtualizes `/proc/self/cgroup` so the process sees its cgroup root as `/`. Does not prevent access to the actual cgroup hierarchy if mounted.

**Time** (`CLONE_NEWTIME`): offsets `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` per namespace. Does NOT virtualize `CLOCK_REALTIME`. Set offsets via `/proc/<pid>/timens_offsets` before first process enters. Created via `unshare(2)` only (not `clone`); children of the caller enter the new time ns.

## Namespace Interactions

- **User ns is the gatekeeper**: creating any other namespace type (except user) in a non-initial user namespace requires capabilities in that user namespace. User ns creation itself is unprivileged (if enabled).
- **Mount + User**: unprivileged mount namespace operations are possible only inside a user namespace where the process has `CAP_SYS_ADMIN`.
- **PID + Mount**: a new PID namespace almost always needs a fresh `/proc` mount to be useful.
- **Network + User**: rootless networking (pasta, slirp4netns) works because the process has `CAP_NET_ADMIN` inside its user namespace.
- **Ownership**: every non-user namespace is owned by the user namespace active at creation time. Capabilities for ns operations are checked against the owning user namespace.

## Key Commands

```bash
# Create isolated shell (user + mount + pid + net)
unshare --user --map-root-user --mount --pid --fork --net bash

# Enter an existing namespace by PID
nsenter -t <pid> -m -u -i -n -p

# Enter by namespace file
nsenter --user=/proc/<pid>/ns/user bash

# List all namespaces on the system
lsns

# List namespaces for a specific process
lsns -p <pid>

# Network namespace management (iproute2)
ip netns add test0
ip netns exec test0 ip link list
ip netns delete test0

# Inspect namespace inode (same inode = same namespace)
readlink /proc/self/ns/net
stat -L /proc/<pid>/ns/user
```

## /proc and Namespaces

**Namespace symlinks**: `/proc/<pid>/ns/<type>` are magic symlinks of the form `<type>:[<inode>]`. Opening one yields an fd that can be passed to `setns(2)` or held open to keep the namespace alive (even after all member processes exit).

**Permission model -- PTRACE_MODE_READ_FSCREDS**:

Many `/proc/<pid>/` files gate access behind `ptrace_may_access()` using `PTRACE_MODE_READ_FSCREDS` (`PTRACE_MODE_READ | PTRACE_MODE_FSCREDS`). The check proceeds:

1. **Credential match**: caller's `fsuid`/`fsgid` must match target's real, effective, saved-set, and filesystem UID/GID.
2. **Capability check**: if credentials do not match, caller needs `CAP_SYS_PTRACE` in the target's user namespace.
3. **LSM check**: an LSM (AppArmor, SELinux) can further deny access.
4. **Cross-user-ns rule**: if caller and target are in different user namespaces, the caller must have `CAP_SYS_PTRACE` in the target's user namespace (requires being in an ancestor user ns).

**Files gated by PTRACE_MODE_READ_FSCREDS** include:
`/proc/<pid>/auxv`, `/proc/<pid>/environ`, `/proc/<pid>/stat` (certain fields), `/proc/<pid>/maps`, `/proc/<pid>/mem`, `/proc/<pid>/cwd` (readlink), `/proc/<pid>/exe` (readlink), `/proc/<pid>/ns/*` (readlink).

The `FSCREDS` variant uses filesystem UID (typically equals euid) rather than real UID, aligning with how file-access permissions work elsewhere.

**Sysctl**: `kernel.yama.ptrace_scope` further restricts ptrace:
- `0` = classic (any process can ptrace any other with same UID)
- `1` = restricted (only direct parent, or CAP_SYS_PTRACE)
- `2` = admin-only (CAP_SYS_PTRACE required)
- `3` = no ptrace at all

## Upstream Sources

- [namespaces(7)](https://man7.org/linux/man-pages/man7/namespaces.7.html) -- canonical reference
- [user_namespaces(7)](https://man7.org/linux/man-pages/man7/user_namespaces.7.html) -- UID mapping, capabilities
- [mount_namespaces(7)](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html) -- propagation types
- [pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html) -- PID 1, nesting
- [time_namespaces(7)](https://man7.org/linux/man-pages/man7/time_namespaces.7.html) -- clock offsets
- [network_namespaces(7)](https://man7.org/linux/man-pages/man7/network_namespaces.7.html) -- net isolation
- [ptrace(2)](https://man7.org/linux/man-pages/man2/ptrace.2.html) -- access mode checking
- [Kernel docs: namespaces](https://docs.kernel.org/admin-guide/namespaces/index.html)
- [LWN: Mount namespaces and shared subtrees](https://lwn.net/Articles/689856/)
- [pasta/passt](https://passt.top/passt/about/) -- rootless networking
