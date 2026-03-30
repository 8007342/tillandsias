---
id: podman-security
title: Podman Container Security
category: infra/containers
tags: [podman, security, capabilities, seccomp, selinux, no-new-privileges]
upstream: https://docs.podman.io/en/latest/markdown/podman-run.1.html
version_pinned: "5.4"
last_verified: "2026-03-30"
authority: official
---

# Podman Container Security

## Quick Reference

| Flag | Purpose | Example |
|------|---------|---------|
| `--cap-drop` | Remove Linux capabilities | `--cap-drop=ALL` |
| `--cap-add` | Grant Linux capabilities | `--cap-add=CAP_NET_BIND_SERVICE` |
| `--security-opt` | Kernel security module options | `--security-opt=no-new-privileges` |
| `--read-only` | Read-only root filesystem | `--read-only` |
| `--read-only-tmpfs` | Auto-mount tmpfs on /run, /tmp | `--read-only-tmpfs=true` |
| `--userns` | User namespace mapping | `--userns=keep-id` |
| `--privileged` | Disable ALL confinement (avoid) | `--privileged` |

## Capabilities

Linux capabilities split root's power into discrete units. Containers should run with the minimum set required.

**Default capabilities** (rootful, UID 0 in container):
`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `NET_BIND_SERVICE`, `NET_RAW`, `SETFCAP`, `SETGID`, `SETPCAP`, `SETUID`, `SYS_CHROOT`, `MKNOD`, `AUDIT_WRITE`

**Rootless containers**: when the in-container UID is non-zero, default capabilities are dropped from the effective set and placed only in the inherited set.

**Hardening pattern** -- drop everything, add back only what you need:

```bash
podman run --cap-drop=ALL --cap-add=CAP_NET_BIND_SERVICE ...
```

**Dangerous capabilities to avoid granting:**

| Capability | Risk |
|------------|------|
| `CAP_SYS_ADMIN` | Near-root; mount, namespace manipulation |
| `CAP_SYS_PTRACE` | Trace/inspect any process in container |
| `CAP_SYS_MODULE` | Load kernel modules |
| `CAP_NET_ADMIN` | Modify network stack, firewall rules |
| `CAP_SYS_RAWIO` | Direct I/O port access |

> In rootless mode, `CAP_SYS_ADMIN` is scoped to the user namespace, not the host -- less dangerous but still avoid unless necessary.

## Seccomp

Seccomp (Secure Computing Mode) filters syscalls at the kernel level.

**Default profile**: Podman ships a default seccomp profile that blocks ~130 of ~435 syscalls (x86_64). Blocked calls include `reboot`, `mount`, `kexec_load`, `init_module`, `swapon`.

```bash
# Use default profile (implicit)
podman run ...

# Custom profile
podman run --security-opt seccomp=/path/to/profile.json ...

# Disable seccomp (development only, never production)
podman run --security-opt seccomp=unconfined ...
```

**Generating custom profiles**: Use `oci-seccomp-bpf-hook` or Podman's `--annotation io.containers.trace-syscall` to record syscalls made by your workload, then build a minimal allowlist.

## SELinux

SELinux enforces Mandatory Access Control via labels on processes and files.

**Container label options** (`--security-opt label=...`):

| Option | Effect |
|--------|--------|
| `label=disable` | Disable SELinux separation entirely |
| `label=type:TYPE` | Set process type (e.g., `container_runtime_t`) |
| `label=level:LEVEL` | Set MCS level (e.g., `s0:c100,c200`) |
| `label=nested` | Allow SELinux modifications inside container |

**Volume labels** (`:z` and `:Z` suffixes):

- `:z` -- shared label; multiple containers can access the volume
- `:Z` -- private label; only this container can access the volume
- Omitting both means no relabeling; may cause permission denials

**Immutable OS notes** (Fedora Silverblue, CoreOS): SELinux is enforcing by default. The `container_t` type is tightly confined. Use `label=nested` only when the container itself must manage SELinux contexts (e.g., running nested podman).

## No New Privileges

```bash
podman run --security-opt=no-new-privileges ...
```

Prevents container processes from gaining privileges beyond those granted at exec time:

- Blocks `setuid` / `setgid` bit escalation
- Prevents capability transitions via `execve()`
- Enforced via the kernel's `PR_SET_NO_NEW_PRIVS` prctl bit
- Once set, inherited by all child processes and cannot be unset

This is one of the most effective single hardening flags. Combine with `--cap-drop=ALL` for defense in depth.

## Security Opt Flags

Complete `--security-opt` reference:

| Value | Description |
|-------|-------------|
| `no-new-privileges` | Block privilege escalation (see above) |
| `seccomp=unconfined` | Disable seccomp filtering |
| `seccomp=PROFILE.json` | Apply custom seccomp profile |
| `label=disable` | Disable SELinux/AppArmor separation |
| `label=type:TYPE` | Set SELinux process type |
| `label=level:LEVEL` | Set MCS/MLS security level |
| `label=nested` | Allow in-container SELinux modifications |
| `apparmor=unconfined` | Disable AppArmor confinement |
| `apparmor=PROFILE` | Apply named AppArmor profile |
| `mask=/path1:/path2` | Mask paths (inaccessible in container) |
| `unmask=/path1:/path2` | Unmask default-masked paths |
| `unmask=ALL` | Unmask all default-masked paths |
| `proc-opts=OPTIONS` | Custom /proc mount options |

**Default masked paths**: `/proc/acpi`, `/proc/kcore`, `/proc/keys`, `/proc/latency_stats`, `/proc/sched_debug`, `/proc/scsi`, `/proc/timer_list`, `/proc/timer_stats`, `/sys/firmware`, `/sys/fs/selinux`

## Read-Only Filesystem

```bash
# Read-only root, auto tmpfs on /run and /tmp
podman run --read-only --read-only-tmpfs ...

# Read-only root, explicit tmpfs mounts
podman run --read-only --tmpfs /tmp:rw,size=64m --tmpfs /run:rw ...

# Read-only root, no automatic tmpfs
podman run --read-only --read-only-tmpfs=false ...
```

- `--read-only` makes the container root filesystem read-only
- `--read-only-tmpfs` (default `true` when `--read-only` is set) auto-mounts tmpfs on `/run`, `/tmp`, `/var/tmp`
- Applications needing persistent writes should use explicit `--volume` or `--mount` for specific paths
- Combine with `--tmpfs` for fine-grained control over size and permissions

## Rootful vs Rootless

| Aspect | Rootful | Rootless |
|--------|---------|----------|
| Daemon UID | root | unprivileged user |
| User namespace | Optional | Always active |
| Network | Full CNI/netavark | pasta/slirp4netns (pasta default in 5.x) |
| Bind ports < 1024 | Yes | Requires `net.ipv4.ip_unprivileged_port_start=0` |
| Capabilities scope | Host namespace | User namespace only |
| Escape impact | Full root on host | Unprivileged user on host |

**Prefer rootless mode** -- even if an attacker escapes the container, they land as an unprivileged user. Rootless is the default in Podman and requires no extra configuration.

## Upstream Sources

- [podman-run(1)](https://docs.podman.io/en/latest/markdown/podman-run.1.html) -- all runtime flags
- [--security-opt reference](https://docs.podman.io/en/latest/markdown/options/security-opt.html) -- security option details
- [capabilities(7)](https://www.man7.org/linux/man-pages/man7/capabilities.7.html) -- Linux capabilities manual
- [Red Hat: Improving container security with seccomp](https://www.redhat.com/en/blog/container-security-seccomp)
- [Red Hat: SELinux container labeling](https://developers.redhat.com/articles/2025/04/11/my-advice-selinux-container-labeling)
- [Red Hat: --privileged flag explained](https://www.redhat.com/en/blog/privileged-flag-container-engines)
