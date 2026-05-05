---
tags: [wsl, wsl2, architecture, isolation, kernel, hyper-v, namespaces]
languages: []
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/about
  - https://man7.org/linux/man-pages/man7/network_namespaces.7.html
authority: high
status: current
---

# WSL2 architecture and inter-distro isolation

@trace spec:cross-platform
@cheatsheet runtime/wsl/networking-modes.md

## Provenance

- "What is Windows Subsystem for Linux" — <https://learn.microsoft.com/en-us/windows/wsl/about> — fetched 2026-04-26. Page `ms.date: 2025-05-19`, `updated_at: 2025-06-10`.

  > "WSL 2 is the default distro type when installing a Linux distribution. WSL 2 uses virtualization technology to run a Linux kernel inside of a lightweight utility virtual machine (VM). Linux distributions run as isolated containers inside of the WSL 2 managed VM. Linux distributions running via WSL 2 will share the same network namespace, device tree (other than `/dev/pts`), CPU/Kernel/Memory/Swap, `/init` binary, but have their own PID namespace, Mount namespace, User namespace, Cgroup namespace, and `init` process."

  > "WSL 2 **increases file system performance** and adds **full system call compatibility** in comparison to the WSL 1 architecture."

- Linux network_namespaces(7) — <https://man7.org/linux/man-pages/man7/network_namespaces.7.html> — fetched 2026-04-26.

  > "Network namespaces provide isolation of the system resources associated with networking: network devices, IPv4 and IPv6 protocol stacks, IP routing tables, firewall rules, the /proc/net directory (which is a symbolic link to /proc/[pid]/net), the /sys/class/net directory, various files under /proc/sys/net, port numbers (sockets), and so on."

  > "A physical network device can live in exactly one network namespace. When a network namespace is freed (i.e., when the last process in the namespace terminates), its physical network devices are moved back to the initial network namespace (not to the namespace of the parent of the process)."

  > "A virtual network (veth) device pair provides a pipe-like abstraction that can be used to create tunnels between network namespaces, and can be used to create a bridge to a physical network device in another namespace."

- **Last updated**: 2026-04-26

**Use when**: you need to know whether two WSL distros are isolated from each other, whether a single WSL distro could host an entire enclave, or what kernel primitives are reachable from inside a WSL distro.

## Quick reference

| Property | Shared across all distros in the VM | Private per distro |
|---|---|---|
| Linux kernel | yes (one VM, one kernel) | — |
| CPU / RAM / Swap | yes (governed by `.wslconfig`) | — |
| `/init` binary | yes | — |
| Network namespace | **yes** (default; see below) | no |
| Device tree (except `/dev/pts`) | yes | — |
| `/dev/pts` | — | yes |
| PID namespace | — | yes |
| Mount namespace | — | yes |
| User namespace | — | yes |
| Cgroup namespace | — | yes |
| `init` process (PID 1) | — | yes |
| Filesystem (VHDX) | — | yes |

The single most important consequence: **two WSL distros share the same network namespace by default**. They see each other on the same loopback and can bind to each other's ports if they listen on `0.0.0.0`. This rules out the design "one distro per enclave service for network isolation" — they would all be on the same network.

## Implications for Tillandsias

| Question | Answer | Source |
|---|---|---|
| Can we use four distros (proxy / forge / git / inference) for network isolation? | **No.** They share a network namespace by default. To get isolation you'd recreate the enclave with `ip netns` + veth pairs **inside a single distro**, exactly the way podman/docker do it. | learn.microsoft.com/about |
| Can we get cgroups-v2 memory caps inside a single distro? | Yes, after the cgroup namespace is unshared, but kernel command line must be set in `.wslconfig` (see `wslconfig-tunables.md`). | blog.richy.net/2025-06-16 (third-party) |
| Can we get user namespaces (`--userns=keep-id` equivalent)? | Yes — each distro has its own user namespace, and unprivileged user-namespace creation is supported by the WSL2 kernel. | learn.microsoft.com/about |
| Can we get seccomp profiles? | Yes (kernel feature, present). | Linux kernel docs (no WSL-specific limitation documented) |
| Can we get AppArmor / SELinux LSM? | **No documented support; AppArmor is widely reported broken under WSL2.** Treat as absent for design purposes. | blog.richy.net/2025-06-16 ("AppArmor not operating under WSL") |
| Will physical devices (e.g. NIC, GPU) appear inside a distro? | Only via the WSL VM's virtual interfaces; the host NIC stays in the Windows host's namespace. | network_namespaces(7) (`A physical network device can live in exactly one network namespace`) |

## Common pitfalls

- **Assuming distro = isolation**. Two WSL distros are roughly as isolated as two `unshare --pid --mount --user` containers under one kernel — *not* as isolated as two virtual machines. Microsoft is explicit: same network namespace, same kernel, same /init binary.
- **Assuming each distro gets its own VM**. There is one Hyper-V utility VM per logged-in Windows user; all that user's WSL2 distros run inside it.
- **Treating `wsl --terminate` as a kill of a separate VM**. It tears down the distro's init process and namespaces but the underlying VM stays alive serving other distros until `wsl --shutdown` (or `vmIdleTimeout` expires).
- **Believing AppArmor / SELinux confine a WSL container**. The host (Windows) provides no LSM; the WSL kernel may compile in AppArmor but in practice, profile loading is broken or absent. The same `--security-opt=label=disable` we already use on Linux hosts applies *de facto* on Windows — for a different reason.

## Sources of Truth

- `https://learn.microsoft.com/en-us/windows/wsl/about` — canonical statement of what WSL2 is and what it shares between distros (fetched 2026-04-26).
- `https://man7.org/linux/man-pages/man7/network_namespaces.7.html` — canonical Linux network namespace definition.
- `cheatsheets/runtime/wsl/networking-modes.md` — what NAT vs mirrored mode does to the shared network namespace.
- `cheatsheets/runtime/wsl/wslconfig-tunables.md` — how to actually set kernel command line / memory limits / DNS tunneling.
