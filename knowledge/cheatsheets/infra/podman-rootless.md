---
id: podman-rootless
title: Podman Rootless Containers
category: infra/containers
tags: [podman, rootless, namespaces, security, crun, userns]
upstream: https://docs.podman.io/en/latest/markdown/podman.1.md
version_pinned: "5.4"
last_verified: "2026-03-29"
authority: official
---

# Podman Rootless Containers

## Quick Reference

| Task | Command |
|---|---|
| Run rootless container | `podman run --rm -it IMAGE` |
| Run with UID preserved | `podman run --userns=keep-id IMAGE` |
| Hardened run | `podman run --rm --cap-drop=ALL --security-opt=no-new-privileges IMAGE` |
| Check subuid allocation | `cat /etc/subuid` |
| Add subuid range | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 USER` |
| Migrate after subuid change | `podman system migrate` |
| Show current user namespace | `podman unshare cat /proc/self/uid_map` |
| Reset rootless storage | `podman system reset` |
| Set unprivileged port start | `sudo sysctl net.ipv4.ip_unprivileged_port_start=80` |

## Key Concepts

**User namespaces.** Rootless podman maps a block of host UIDs (allocated via `/etc/subuid` and `/etc/subgid`) into the container using `newuidmap`/`newgidmap`. Inside the container, UID 0 exists but maps to an unprivileged host UID.

**`--userns=keep-id`.** Maps the invoking user's UID/GID to the same values inside the container. Essential when bind-mounting host directories so the container process can read/write without permission errors. Uses the full subuid/subgid range.

**subuid/subgid.** Each rootless user needs an entry in `/etc/subuid` and `/etc/subgid` granting at least 65536 subordinate IDs. Format: `username:start:count`. After editing these files, run `podman system migrate`.

**Networking (pasta vs slirp4netns).** Since Podman 5.0, **pasta** is the default rootless network backend. It copies host network config into the container (no NAT), offering better performance than slirp4netns. Configurable in `containers.conf` under `[network]` via `default_rootless_network_cmd`.

**OCI runtime.** Podman defaults to **crun** over runc when available. crun is smaller (~300K vs ~15M), faster, and supports rootless-specific features like `--security-opt=unmask` and supplementary group passthrough (`keep-groups`).

## Security Model

Rootless containers never gain privileges beyond the invoking user on the host:

- **No host root.** UID 0 inside the container maps to the user's unprivileged subordinate UID on the host.
- **Capabilities are relative.** `CAP_SYS_ADMIN` inside a user namespace only grants admin over that namespace, not the host.
- **Seccomp.** A default seccomp profile restricts syscalls. Override with `--security-opt seccomp=PROFILE.json` or disable (not recommended) with `--security-opt seccomp=unconfined`.
- **no-new-privileges.** `--security-opt=no-new-privileges` prevents setuid binaries from escalating. Always use in hardened setups.
- **AppArmor/SELinux.** Confinement applies on top of user namespace isolation. The `:z`/`:Z` volume suffix handles SELinux relabeling.

## Common Flags

| Flag | Purpose |
|---|---|
| `--userns=keep-id` | Map host UID/GID into container unchanged |
| `--userns=keep-id:uid=UID,gid=GID` | Map host user to specific container UID/GID |
| `--cap-drop=ALL` | Drop all Linux capabilities |
| `--cap-add=CAP_NAME` | Selectively re-add a capability |
| `--security-opt=no-new-privileges` | Block privilege escalation via setuid |
| `--rm` | Auto-remove container on exit |
| `--init` | Run tini as PID 1 (reaps zombies, forwards signals) |
| `--network=pasta` | Explicit pasta networking (default in 5.x) |
| `--network=slirp4netns:port_handler=slirp4netns` | Legacy networking backend |
| `-v /host:/ctr:Z` | Bind mount with SELinux private relabel |
| `--passwd-entry=USER:*:UID:GID::/home/USER:/bin/sh` | Inject passwd entry without modifying image |

## Gotchas

**Ports below 1024.** Rootless users cannot bind to privileged ports by default. Fix: `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80` (persist in `/etc/sysctl.d/`).

**Overlayfs and kernel version.** Native rootless overlayfs requires kernel >= 5.12 and podman >= 3.1. Older systems fall back to fuse-overlayfs (slower, runs in userspace). SELinux with rootless overlayfs requires kernel >= 5.13.

**SELinux on immutable desktops (Silverblue, Kinoite).** Volume mounts may fail with permission denied if SELinux labels are wrong. Use `:z` (shared) or `:Z` (private) suffix. For read-only mounts, combine `:ro,z`.

**`/dev/fuse` access.** Not available by default in rootless containers. Required for FUSE mounts (sshfs, rclone). Add with `--device /dev/fuse` and `--cap-add SYS_ADMIN` (scoped to user namespace).

**Ping.** ICMP requires `net.ipv4.ping_group_range` to include the user's GID. Most distributions set this broadly, but verify if ping fails inside containers.

**`--userns=auto` conflict.** Containers started with `--userns=keep-id` and `--userns=auto` cannot coexist for the same user. Stick to one mode.

**Storage migration.** Changing `/etc/subuid` or `/etc/subgid` requires stopping all user containers, then running `podman system migrate`. Failing to do this causes UID mapping errors.

**cgroup v2.** Rootless resource limits (CPU, memory) require cgroup v2 with delegation enabled. Verify with `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers`.

## Upstream Sources

- [Rootless tutorial](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md) -- step-by-step setup
- [podman-rootless(7)](https://github.com/containers/podman/blob/main/rootless.md) -- limitations and workarounds
- [podman-run(1)](https://docs.podman.io/en/latest/markdown/podman-run.1.html) -- full flag reference
- [--userns option](https://docs.podman.io/en/latest/markdown/options/userns.container.html) -- namespace mode details
- [--security-opt option](https://docs.podman.io/en/latest/markdown/options/security-opt.html) -- seccomp and privilege control
- [Rootless networking docs](https://github.com/eriksjolund/podman-networking-docs) -- community pasta/slirp4netns examples
- [crun introduction](https://www.redhat.com/en/blog/introduction-crun) -- crun vs runc comparison
- [Rootless overlay support](https://www.redhat.com/en/blog/podman-rootless-overlay) -- overlayfs kernel requirements
