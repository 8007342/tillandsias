---
tags: [wsl, wsl2, systemd, cgroups, namespaces, security, lsm]
languages: []
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/systemd
  - https://man7.org/linux/man-pages/man7/cgroups.7.html
  - https://man7.org/linux/man-pages/man1/systemd-nspawn.1.html
  - https://man7.org/linux/man-pages/man7/network_namespaces.7.html
authority: high
status: current
---

# Linux primitives reachable from inside WSL2

@trace spec:cross-platform, spec:podman-orchestration, spec:enclave-network
@cheatsheet runtime/wsl/architecture-isolation.md

## Provenance

- "Use systemd to manage Linux services with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/systemd> — fetched 2026-04-26.

  > "Windows Subsystem for Linux (WSL) now supports systemd, an init system and service manager used by many popular Linux distributions such as Ubuntu, Debian, and more."

  > "You will need version 0.67.6+ of WSL to enable systemd."

  > "As systemd requires PID 1, the WSL init process started within the Linux distribution becomes a child process of the systemd."

  > "It is also important to note that with these changes, systemd services will NOT keep your WSL instance alive."

- `cgroups(7)` — <https://man7.org/linux/man-pages/man7/cgroups.7.html> — fetched 2026-04-26.

  > "the initial cgroups implementation (cgroups version 1), starting in Linux 3.10, work began on a new, orthogonal implementation to remedy these problems."

  > "a controller can't be simultaneously employed in both a cgroups v1 hierarchy and in the cgroups v2 hierarchy."

  Cgroup-v2 controllers (verbatim list): `cpu, cpuset, freezer, hugetlb, io, memory, perf_event, pids, rdma`.

  > "In cgroups v2, all mounted controllers reside in a single unified hierarchy."

  > "a (nonroot) cgroup can't both (1) have member processes, and (2) distribute resources into child cgroups."

- `systemd-nspawn(1)` — <https://www.man7.org/linux/man-pages/man1/systemd-nspawn.1.html> — fetched 2026-04-26.

  > "Spawn a command or OS in a lightweight container"

  > "virtualizes the file system hierarchy, as well as the process tree, the various IPC subsystems"

  > "limits access to various kernel interfaces in the container to read-only, such as /sys/, /proc/sys/"

  > "This sandbox can easily be circumvented from within the container if user namespaces are not used. This means that untrusted code must always be run in a user namespace"

- `network_namespaces(7)` — <https://man7.org/linux/man-pages/man7/network_namespaces.7.html> — fetched 2026-04-26.

  > "A virtual network (veth) device pair provides a pipe-like abstraction that can be used to create tunnels between network namespaces, and can be used to create a bridge to a physical network device in another namespace."

- **Last updated**: 2026-04-26

**Use when**: deciding what isolation primitives to use *inside* a WSL distro to recreate the enclave (network namespaces / veth / bridge / cgroups / seccomp), and what's missing.

## Quick reference — primitive availability under WSL2

| Linux primitive | Available in WSL2? | Authority |
|---|---|---|
| PID namespace | yes (one per distro by default; `unshare --pid` for nested) | learn.microsoft.com/about |
| Mount namespace | yes | learn.microsoft.com/about |
| User namespace (rootless) | yes | learn.microsoft.com/about (`have their own ... User namespace`) |
| Cgroup namespace | yes | learn.microsoft.com/about |
| Network namespace + veth | yes (one shared per VM by default; can `ip netns add` further) | network_namespaces(7) — kernel feature; WSL2 kernel includes `CONFIG_NET_NS` |
| Cgroup v1 | yes (default) | cgroups(7) |
| Cgroup v2 | yes, after `kernelCommandLine=cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1` in `.wslconfig` | wslconfig-tunables.md (third-party recipe) |
| systemd as PID 1 | yes (`[boot] systemd=true` in `wsl.conf`, WSL ≥0.67.6) | learn.microsoft.com/systemd |
| seccomp filters | yes (kernel feature; no WSL-specific docs forbidding) | kernel docs |
| AppArmor LSM | **no documented support; reported broken** | blog.richy.net/2025-06-16 ("AppArmor not operating under WSL") |
| SELinux LSM | not present in MS inbox kernel | absence of doc; `getenforce` returns "Disabled" or missing |
| OverlayFS | yes (used by docker / podman storage drivers under WSL today) | docker/podman in WSL works in practice |
| FUSE | yes (used by `wslfs`/DrvFs internally and 9P) | learn.microsoft.com (file system docs) |
| `unshare` / `nsenter` | yes (standard Linux binaries) | kernel docs |
| `ip netns add` / veth / `bridge` | yes — same kernel API as bare-metal Linux | network_namespaces(7) |
| Custom kernel modules | only if shipped via `kernelModules` VHD; loading arbitrary modules at runtime requires a custom kernel | learn.microsoft.com/wsl-config |
| KVM / nested virt | yes (`nestedVirtualization=true` default on Win11) | learn.microsoft.com/wsl-config |

## What this means for the enclave

The enclave today (proxy / forge / git / inference / router) uses these podman primitives that map 1-to-1 to kernel primitives:

| podman flag | Kernel primitive | WSL2 reachable? |
|---|---|---|
| `--rm` | (podman bookkeeping) | n/a |
| `--cap-drop=ALL` | capabilities (`capset(2)`) | yes |
| `--security-opt=no-new-privileges` | `prctl(PR_SET_NO_NEW_PRIVS)` | yes |
| `--userns=keep-id` | user namespace (`unshare --user`) | yes |
| `--security-opt=label=disable` | SELinux disable | n/a (SELinux absent under WSL) — same effect for free |
| `--init` | tini-style PID 1 reaper | yes (any pid-1 binary works) |
| `--pids-limit` | pids cgroup controller | yes (cgroup v2 once enabled) |
| `--memory` / `--memory-swap` | memory cgroup controller | yes (cgroup v2 once enabled) |
| `--read-only` | `MS_RDONLY` mount | yes |
| `--tmpfs=...` | tmpfs mount with `size=` and `mode=` | yes |
| `--network <internal>` | network namespace + bridge + DROP iptables | yes; build with `ip netns add` + veth + `iptables -A FORWARD -j DROP` |
| `--add-host alias:host-gateway` | `/etc/hosts` injection | yes; or `iptables` SNAT/DNAT |
| `--publish 127.0.0.1:P:4096` | iptables DNAT loopback rule | yes |
| `-v <host>:<container>` | bind mount | yes |
| `-v <host>:<container>:ro` | bind mount with `MS_RDONLY` | yes |
| `--device /dev/dri/...` | bind mount of device node | yes |

## What's actually missing or risky

1. **AppArmor/SELinux confinement** — Both are absent or broken under WSL2. We currently apply `--security-opt=label=disable` on Linux too, so this is not a regression — but it removes one defence-in-depth layer that a Linux Tillandsias install on a SELinux-enforcing host (Fedora) gets for free.

2. **systemd-nspawn alone is insufficient** — Per the man page: *"This sandbox can easily be circumvented from within the container if user namespaces are not used."* If we ever consider using `systemd-nspawn --machine` instead of podman for orchestration, we MUST pair it with `--private-users` and treat it like rootless containers.

3. **One VM, one kernel** — Anything that needs a kernel feature WSL doesn't ship requires `kernel=...` (custom MS-style kernel build) or `kernelModules=...` (modules VHD). This is a maintenance burden we currently avoid by relying on host kernels (Fedora ships what podman needs).

4. **Inter-distro network isolation does not exist** — see `architecture-isolation.md`. Don't lean on it.

## Common pitfalls

- **Assuming `--memory=512m` works out of the box on WSL2**. It silently no-ops without cgroup v2 enabled. Verify with `cat /proc/<pid>/cgroup` showing `0::/...` (v2) not `9:memory:/...` (v1).
- **`systemctl` works inside WSL only if `systemd=true` is set** AND the distro restarted. Common gotcha: editing `wsl.conf`, not running `wsl --terminate`, and wondering why `systemctl` reports "System has not been booted with systemd as init".
- **Loading a kernel module from a script**. `modprobe` will fail unless the module is in the WSL kernel's modules VHD. For network bridge / iptables / nftables this is rarely a problem (compiled in), but for nbd / dm-thin it is.
- **`unshare --net` in interactive shell**. Works, but the new netns has no veth — you've cut yourself off from the bridge. Pair it with veth setup like podman does internally.

## Sources of Truth

- <https://learn.microsoft.com/en-us/windows/wsl/systemd> (fetched 2026-04-26)
- <https://learn.microsoft.com/en-us/windows/wsl/about> (fetched 2026-04-26)
- <https://man7.org/linux/man-pages/man7/cgroups.7.html> (fetched 2026-04-26)
- <https://man7.org/linux/man-pages/man1/systemd-nspawn.1.html> (fetched 2026-04-26)
- <https://man7.org/linux/man-pages/man7/network_namespaces.7.html> (fetched 2026-04-26)
- `cheatsheets/runtime/wsl/architecture-isolation.md` — companion: what WSL shares vs isolates.
- `cheatsheets/runtime/wsl/wslconfig-tunables.md` — companion: how to flip cgroup v2, systemd, kernel cmdline.
