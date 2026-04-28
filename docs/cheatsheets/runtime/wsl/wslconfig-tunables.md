---
tags: [wsl, wsl2, wslconfig, configuration, kernel, cgroup, systemd]
languages: []
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/systemd
authority: high
status: current
---

# .wslconfig and wsl.conf — tunable reference

@trace spec:cross-platform
@cheatsheet runtime/wsl/architecture-isolation.md, runtime/wsl/networking-modes.md

## Provenance

- "Advanced settings configuration in WSL" — <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — fetched 2026-04-26. `ms.date: 2025-07-31`, `updated_at: 2025-12-09`.

  Layout (verbatim):

  > "`.wslconfig` — General settings that apply to all of WSL — Feature enablement in WSL, settings for the virtual machine powering WSL 2 (RAM, kernel to boot, number of CPUs, etc.) — Location: `%UserProfile%\.wslconfig`, outside of a WSL distribution"
  >
  > "`wsl.conf` — Settings for WSL distributions only — Distribution settings in WSL such as boot options, DrvFs automounts, networking, interoperability with the Windows system, systemd usage, and default user — Location: `/etc/wsl.conf`, while inside a WSL distribution"

  Reload semantics (verbatim):

  > "You must wait until the subsystem running your Linux distribution completely stops running and restarts for configuration setting updates to appear. This typically takes about 8 seconds after closing ALL instances of the distribution shell."
  >
  > "The command `wsl --shutdown` is a fast path to restarting WSL 2 distributions, but it will shut down all running distributions, so use wisely. You can also use `wsl --terminate <distroName>` to terminate a specific distribution that's running instantly."

- "Use systemd to manage Linux services with WSL" — <https://learn.microsoft.com/en-us/windows/wsl/systemd> — fetched 2026-04-26. `ms.date: 2025-01-13`, `updated_at: 2025-06-10`.

  > "To enable systemd, open your `wsl.conf` file in a text editor using `sudo` for admin permissions and add these lines to the `/etc/wsl.conf`:
  >
  > ```bash
  > [boot]
  > systemd=true
  > ```"

  > "It is also important to note that with these changes, systemd services will NOT keep your WSL instance alive. Your WSL instance will stay alive in the same way it did previous to this update."

- **Last updated**: 2026-04-26

**Use when**: configuring WSL2 for Tillandsias workloads — RAM caps, processor count, systemd, custom kernel cmdline.

## Quick reference — `.wslconfig` (`%UserProfile%\.wslconfig`, `[wsl2]` section)

Verbatim from Microsoft Learn (table reproduced; defaults / units / availability per the linked page).

| Key | Default | Notes (verbatim or near-verbatim) |
|---|---|---|
| `kernel` | inbox MS kernel | "An absolute Windows path to a custom Linux kernel." |
| `kernelModules` | none | "An absolute Windows path to a custom Linux kernel modules VHD." |
| `memory` | 50% of host | "How much memory to assign to the WSL 2 VM." |
| `processors` | host logical CPUs | "How many logical processors to assign to the WSL 2 VM." |
| `localhostForwarding` | `true` | NAT-mode auto-bind of Linux ports to Windows `localhost`. |
| `kernelCommandLine` | none | "Additional kernel command line arguments." |
| `safeMode` | `false` | Win11 + WSL ≥0.66.2; recovery mode. |
| `swap` | 25% of host | "How much swap space to add to the WSL 2 VM, 0 for no swap file." |
| `swapFile` | `%Temp%\swap.vhdx` | Path to swap VHD. |
| `guiApplications` | `true` | WSLg toggle. |
| `debugConsole` | `false` | dmesg console (Win11 only). |
| `nestedVirtualization` | `true` | Allow nested VMs inside WSL2 (Win11 only). |
| `vmIdleTimeout` | `60000` | "The number of milliseconds that a VM is idle, before it is shut down." (Win11 only) |
| `dnsProxy` | `true` | NAT-only; mirror DNS from Windows. |
| `networkingMode` | `nat` | `none` / `nat` / `bridged` (deprecated) / `mirrored` / `virtioproxy`. |
| `firewall` | `true` | Hyper-V firewall filters WSL traffic (Win11 22H2+). |
| `dnsTunneling` | `true` | DNS via virtio (Win11 22H2+). |
| `autoProxy` | `true` | Inherit Windows HTTP proxy (Win11 22H2+). |
| `defaultVhdSize` | 1 TB | Per-distribution VHDX cap. |

`[experimental]` keys (selected):

| Key | Default | Notes |
|---|---|---|
| `autoMemoryReclaim` | `dropCache` | `disabled` / `gradual` / `dropCache`. |
| `sparseVhd` | `false` | New VHDs created sparse. |
| `ignoredPorts` | none | Mirrored-only; ports Linux can bind even if Windows uses them. |
| `hostAddressLoopback` | `false` | Mirrored-only; container ↔ host via host's IPs. |

## Quick reference — `wsl.conf` (`/etc/wsl.conf` inside a distro)

| Section / key | Default | Notes |
|---|---|---|
| `[automount] enabled` | `true` | Mounts `C:\` etc. under `/mnt/`. |
| `[automount] mountFsTab` | `true` | Process `/etc/fstab` on boot. |
| `[automount] root` | `/mnt/` | Mount root for Windows drives. |
| `[automount] options` | none | DrvFs options (uid, gid, umask, metadata, case). |
| `[network] generateHosts` | `true` | Auto-write `/etc/hosts`. |
| `[network] generateResolvConf` | `true` | Auto-write `/etc/resolv.conf`. |
| `[network] hostname` | Windows hostname | Linux hostname. |
| `[interop] enabled` | `true` | Launch Windows processes from Linux. |
| `[interop] appendWindowsPath` | `true` | Add Windows `PATH` entries. |
| `[user] default` | first user | Default UID. |
| `[boot] systemd` | `false` (default Ubuntu now flips this) | Run systemd as PID 1. |
| `[boot] command` | none | Run as root on boot. |
| `[boot] protectBinfmt` | `true` | Prevent WSL from generating systemd units when systemd is enabled. |
| `[gpu] enabled` | `true` | Para-virtualized GPU. |
| `[time] useWindowsTimezone` | `true` | Sync TZ from Windows. |

## Cgroup-v2 enablement (third-party-confirmed pattern)

Per <https://blog.richy.net/2025/06/16/wsl2.html> (fetched 2026-04-26), enabling cgroup v2 inside WSL2 — required for podman/runc/crun memory and pids limits to actually be enforced — uses `kernelCommandLine` in `.wslconfig`:

> "kernelCommandLine=cgroup_no_v1=all systemd.unified_cgroup_heirarchy=1"

(Note the typo `heirarchy` in the upstream blog; the canonical kernel parameter is `systemd.unified_cgroup_hierarchy`. Verify on first prototype.)

This is the WSL equivalent of the cgroup-v2 enablement that distros like Fedora 31+ ship by default. Without it, `--memory` / `--memory-swap` / `--pids-limit` may silently no-op under WSL2's default (cgroup-v1) configuration, depending on WSL kernel build date.

## Implications for Tillandsias

| Tillandsias requirement | `.wslconfig` / `wsl.conf` knob | Notes |
|---|---|---|
| Per-VM memory cap | `memory=8GB` (e.g.) | Applies to whole VM, not per container |
| Per-container `--memory` cap (today: `compute_run_args` sets this for tmpfs containers) | requires cgroup v2 → `kernelCommandLine` | Today Tillandsias relies on the host providing v2; under WSL, must set explicitly |
| systemd PID 1 (e.g., to run a D-Bus session bus for the git service) | `[boot] systemd=true` in distro's `wsl.conf` | Ubuntu's WSL distro has this on by default |
| Container DNS via Squid → `proxy:3128` | `[network] generateResolvConf=false` if writing custom; otherwise default WSL proxy works | We do this *inside* the enclave, not at the host level |
| Custom kernel for cgroup-v2 / specific CONFIG_* | `kernel=...` | Avoid; pin to MS inbox kernel until proven necessary |
| Swap-disable for RAM-only enclave | `swap=0` | Mirrors `--memory-swap=<memory>` semantics today |
| Idle VM auto-shutdown (UX: tray exits → VM stops) | `vmIdleTimeout=60000` | Useful; avoids leaving a 4 GB ghost VM running after tray quit |
| Disable Windows interop in service distro | `[interop] enabled=false` in service-distro's `wsl.conf` | Hardens the boundary if we ever go multi-distro |

## Common pitfalls

- **`.wslconfig` requires VM restart**. Edit, then `wsl --shutdown`. Editing while a distro runs is silently ignored until next start.
- **`wsl.conf` requires distro restart, not VM**. `wsl --terminate <distro>` is enough.
- **`memory` applies to the VM, not per distro**. There is no per-distro RAM cap — that's a fundamental architectural limit (one VM serves all distros).
- **Setting `firewall=false` to "make networking work"**. This breaks Hyper-V firewall enforcement and exposes WSL to the LAN. Don't.
- **Mixing `.wslconfig` and `wsl.conf`**. Same-named keys exist in different files (`hostname` is in `wsl.conf`, but VM-wide settings are in `.wslconfig`). Read the table above before editing.

## Sources of Truth

- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> (fetched 2026-04-26)
- <https://learn.microsoft.com/en-us/windows/wsl/systemd> (fetched 2026-04-26)
- <https://blog.richy.net/2025/06/16/wsl2.html> (fetched 2026-04-26) — third-party recipe for cgroup-v2 inside WSL; verify on first prototype before quoting as authoritative.
