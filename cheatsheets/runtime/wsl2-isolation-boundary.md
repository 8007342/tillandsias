---
tags: [windows, wsl2, isolation, hyper-v, security-boundary, drvfs, interop, wslg, networking, threat-model]
languages: []
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/about
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/networking
  - https://learn.microsoft.com/en-us/windows/wsl/filesystems
  - https://learn.microsoft.com/en-us/windows/wsl/disk-space
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# WSL2 isolation boundary — what crosses, what doesn't

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:chromium-browser-isolation

**Version baseline**: WSL2 on Windows 10 build 19044+ / Windows 11; latest knobs (`sparseVhd`, `dnsTunneling`, `autoProxy`, `firewall`, `hostAddressLoopback`) require Windows 11 22H2+.
**Use when**: deciding whether the WSL2 layer is providing a security boundary for a given concern, OR designing the host-side configuration that closes a host↔distro bridge. The architectural premise of `spec:windows-wsl-runtime` after 2026-04-28: a vanilla WSL2 distro is a **porous Hyper-V utility VM**, not a container. Real container isolation requires podman *inside* the distro plus the wsl.conf hardening below.

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/about> — utility VM model, single Linux kernel per Windows user
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `wsl.conf` (per-distro) + `.wslconfig` (per-host) full key reference
- <https://learn.microsoft.com/en-us/windows/wsl/networking> — NAT vs mirrored mode, DNS tunneling, autoProxy, Hyper-V firewall
- <https://learn.microsoft.com/en-us/windows/wsl/filesystems> — DrvFs `/mnt/c`, 9P bridge, runtime interop disable
- <https://learn.microsoft.com/en-us/windows/wsl/disk-space> — VHD elasticity, `--manage --resize`
- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — `wsl --status`, `wsl --shutdown`, `wsl --terminate`
- **Last updated:** 2026-04-28

## Threat model — what the WSL2 boundary IS and IS NOT

**IS**: a Hyper-V Type-1 utility VM with a separate Linux kernel, isolated process tree, isolated filesystem (vhdx), separate user accounts, separate registry-equivalent (none), separate networking when configured to NAT mode.

**IS NOT**: a container. By default, WSL2 has at least 13 documented bridges back to the Windows host. A vanilla `wsl --import` distro can:
- read every file under `C:\Users\<you>` (drvfs auto-mount of `/mnt/c`)
- execute Windows binaries from inside Linux (interop subsystem invokes `wsl.exe` reverse-call)
- bind-mount `/tmp/.X11-unix` and `/mnt/wslg` to Windows-side sockets (WSLg)
- use the Windows GPU (DXG vGPU at `/dev/dxg`)
- inherit the Windows clock + timezone
- inherit the Windows DNS resolver (NAT mode) or share the Windows network namespace (mirrored mode)
- expose every Linux file under `\\wsl$\<distro>\…` to any Win32 process running as the same user
- be reached from Windows on `127.0.0.1:port` (mirrored mode or `localhostForwarding=true` under NAT)

A forge container running inside a vanilla WSL distro is therefore **NOT isolated from the host filesystem or credentials**. Closing each bridge requires explicit `wsl.conf` / `.wslconfig` configuration. The table below is the complete known list.

## The bridges table

Every row: a documented host↔distro bridge, its default state, the exact knob that closes it, and the Microsoft Learn URL with a literal quote. The threat-impact column is for Tillandsias' threat model: **forge agents inside the distro are untrusted code**.

| Bridge | Default | Disable knob | Vendor citation | Forge threat impact |
|---|---|---|---|---|
| **DrvFs `/mnt/c`** auto-mount of Windows drives | on | `[automount] enabled=false` (`wsl.conf`) | "`enabled` … `true` causes fixed drives (i.e `C:/` or `D:/`) to be automatically mounted with DrvFs under `/mnt`. `false` means drives won't be mounted automatically …" — `wsl-config` | CRITICAL — exposes `C:\Users\<you>` to forge processes |
| **Windows interop / `binfmt_misc WSLInterop`** | on | `[interop] enabled=false` (`wsl.conf`) OR runtime: `echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop` | "Setting this key will determine whether WSL will support launching Windows processes." — `wsl-config`. Per-session: "Users may disable the ability to run Windows tools for a single WSL session by running the following command as root: `echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop`" — `filesystems` | HIGH — forge can shell out to Windows binaries (`cmd.exe /c …`) |
| **Append Windows `$PATH`** to Linux PATH | on | `[interop] appendWindowsPath=false` | "Setting this key will determine whether WSL will add Windows path elements to the `$PATH` environment variable." — `wsl-config` | MEDIUM — convenience for the human, attack vector when interop is on |
| **WSLg / GUI bridge** (X11 + Wayland sockets at `/tmp/.X11-unix`, `/mnt/wslg`) | on | `[wsl2] guiApplications=false` (`.wslconfig`, host-wide) | "Boolean to turn on or off support for GUI applications (WSLg) in WSL." — `wsl-config` | LOW for headless services; HIGH for forge if it needs to NOT poke the user's session |
| **DXG / vGPU `/dev/dxg`** | on | `[gpu] enabled=false` (`wsl.conf`) | "`true` … Allow Linux applications to access the Windows GPU via para-virtualization." — `wsl-config` | LOW (not exploitable directly) but exposes GPU driver attack surface |
| **Time sync to Windows clock + TZ** | on | `[time] useWindowsTimezone=false` (`wsl.conf`) | "Setting this key will make WSL use and sync to the timezone set in Windows." — `wsl-config` | NEGLIGIBLE — privacy-only (TZ leak) |
| **DNS via Windows resolver** (NAT mode + `/etc/resolv.conf`) | on | `[wsl2] dnsTunneling=false` + `[network] generateResolvConf=false` | "`dnsTunneling` … Changes how DNS requests are proxied from WSL to Windows" — `wsl-config`. "On machines running Windows 11 22H2 and higher the `dnsTunneling` feature is on by default … it uses a virtualization feature to answer DNS requests from within WSL, instead of requesting them over a networking packet." — `networking` | MEDIUM — DNS is a side-channel; we want our proxy to control resolution |
| **Auto Windows HTTP proxy** | on (Win11 22H2+) | `[wsl2] autoProxy=false` | "Enforces WSL to use Windows' HTTP proxy information" — `wsl-config` | HIGH — silently honours user's WPAD/manual proxy; forge agents could route through unexpected upstream |
| **Hyper-V firewall** filtering WSL traffic | on (Win11 22H2+) | `[wsl2] firewall=false` (DO NOT — exposes WSL to LAN) | "Setting this to true allows the Windows Firewall rules, as well as rules specific to Hyper-V traffic, to filter WSL network traffic." — `wsl-config` | KEEP ENABLED — the firewall is a host-side boundary we WANT |
| **`localhost:port` Win↔Linux** (NAT mode) | on | `[wsl2] localhostForwarding=false` (`.wslconfig`) | "Boolean specifying if ports bound to wildcard or localhost in the WSL 2 VM should be connectable from the host via `localhost:port`." — `wsl-config` | DEPENDS — Tillandsias needs the *tray* to reach `localhost:14000`, but does NOT want forge to reach the host's localhost services |
| **`127.0.0.1` reflection** (mirrored mode) | when enabled | switch to `nat`/`none` | "Connect to Windows servers from within Linux using the localhost address `127.0.0.1`." — `networking` | DEPENDS — same trade-off as above; mirrored is bidirectional |
| **9P bridge `\\wsl$\<distro>\…`** | always available, NOT disableable | (no documented disable knob; mitigate by not putting secrets on disk) | "To view all of your available Linux distributions and their root file systems in Windows File explorer, in the address bar enter: `\\wsl$`" — `filesystems` | HIGH — anything in the distro filesystem is reachable from any Win32 process running as the same user |
| **Memory ballooning** | on | `[experimental] autoMemoryReclaim=disabled` | "`disabled` / `gradual` / `dropCache`. … cached memory will be reclaimed slowly and automatically … cached memory will be reclaimed immediately." — `wsl-config` | NEGLIGIBLE — performance, not security |
| **VM idle auto-shutdown** | 60 s (Win11) | `[wsl2] vmIdleTimeout=<ms>`; `0` to disable | "The number of milliseconds that a VM is idle, before it is shut down." — `wsl-config` | NEGLIGIBLE — UX behavior |

## Tillandsias hardening profile

The distro the tray imports as `tillandsias` SHALL ship with the following `wsl.conf` and the host SHALL ship the matching `.wslconfig`. Knobs whose defaults already match the desired state are repeated explicitly so the configuration is self-documenting.

### `/etc/wsl.conf` (per-distro, baked into the rootfs)

```ini
# @trace spec:windows-wsl-runtime, spec:cross-platform
# @cheatsheet runtime/wsl2-isolation-boundary.md
# Tillandsias hardening profile — closes every documented host↔distro bridge
# that Microsoft Learn flags as default-on. See cheatsheet for citations.

[automount]
enabled = false                  # row 1: drvfs gone — forge can't see /mnt/c
mountFsTab = false               # don't process /etc/fstab from a 9P-bridged file

[interop]
enabled = false                  # row 2: no wsl.exe reverse-call from Linux to Windows
appendWindowsPath = false        # row 3: don't pollute $PATH with Windows tools

[network]
generateResolvConf = false       # we ship our own /etc/resolv.conf pointing at our proxy
generateHosts = false            # ditto for /etc/hosts

[gpu]
enabled = true                   # row 5: needed for ollama inference + Chromium GPU
                                 # acceptable: GPU driver attack surface < usability win

[time]
useWindowsTimezone = true        # row 6: privacy-non-issue for our use case

[boot]
systemd = true                   # podman wants it (containers.conf events_logger=journald)
```

### `%UserProfile%\.wslconfig` (per-host, written by `tillandsias --init`)

```ini
# @trace spec:windows-wsl-runtime, spec:cross-platform
# @cheatsheet runtime/wsl2-isolation-boundary.md

[wsl2]
memory = 12GB
processors = 8
swap = 0                         # forge spec is RAM-only
networkingMode = mirrored        # tray needs localhost:port reachable; see networking-modes
firewall = true                  # KEEP — Hyper-V firewall filters WSL traffic per Win FW rules
dnsTunneling = true              # default, needed for resolver during forge build
autoProxy = false                # row 8: do NOT honor Windows WPAD; we manage proxy in-enclave
guiApplications = false          # row 4: tray is headless; no WSLg X11/Wayland
vmIdleTimeout = 300000           # 5 min idle then VM stops (memory frees back to Windows)
defaultVhdSize = 274877906944    # 256 GiB cap (sparse — see runtime/wsl2-disk-elasticity.md)
kernelCommandLine = cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1
                                 # cgroup v2 needed by podman --memory etc.

[experimental]
autoMemoryReclaim = gradual
sparseVhd = true                 # NTFS-side block-sparse → returns space when files deleted
```

## What the WSL2 boundary canNOT close (residual gaps)

Three items have no Microsoft Learn-documented disable knob. Each is a known-accepted residual; mitigation strategy is documented per row.

| Residual | Why it can't be disabled | Tillandsias mitigation |
|---|---|---|
| **9P bridge `\\wsl$\<distro>\…`** | No `wsl.conf` key turns it off; it's how the host reaches the distro filesystem | Treat distro filesystem as host-readable: never write secrets to disk; secrets go through D-Bus to the host keyring or via process env (per `runtime/secrets-management.md`) |
| **Single Linux kernel per Windows user** (all distros + all containers share one VM) | Per `learn.microsoft.com/wsl/about`: "WSL provides a Linux-compatible kernel interface … run WSL 1 or WSL 2 distributions on the same machine, side by side." Same kernel, ergo a kernel exploit in any container reaches all containers in that VM. | Accept: this is the same trust model rootless podman has on a Linux host. Layer container hardening on top (cap-drop, seccomp, no-new-privileges, SELinux). |
| **Windows file ACLs are NOT projected through 9P** | When the host writes a file to `\\wsl$\…\path`, the Linux-side ACL is fixed (no ACL inheritance). | Don't share state via 9P — share via in-VM podman volumes. |

## Process for adding a new isolation requirement

When a new spec demands a host↔distro bridge be closed:

1. Find the bridge in this cheatsheet's table. If absent, file a follow-up to grow the table from a vendor citation.
2. Add the disable knob to `/etc/wsl.conf` (per-distro) or `.wslconfig` (per-host).
3. Add a `@trace spec:<new-spec>, spec:windows-wsl-runtime` near the knob with a 1-line rationale.
4. Update `cheatsheets/runtime/wsl2-isolation-boundary.md` (this file) and re-run the cheatsheet INDEX regenerator.
5. Smoke: `tillandsias --init` rebuilds the distro; verify the bridge is closed (`ls /mnt/c` should return nothing; `which cmd.exe` should fail; etc.).

## Common pitfalls

- **`wsl.conf` is per-distro; `.wslconfig` is per-host.** They're not interchangeable. Microsoft Learn `wsl-config` documents the split: "*`wsl.conf` … is used to apply settings on a per WSL distro basis*"; "*`.wslconfig` … is used to apply settings globally across all installed distros running with WSL 2*". Tillandsias writes BOTH.
- **`[interop] enabled=false` does NOT disable 9P.** Different bridge. The 9P bridge is always on.
- **Disabling `firewall` reduces security**, not increases it. Despite intuition; the Hyper-V firewall is a host-side boundary that filters distro traffic per the Windows firewall rules. Keep it enabled.
- **Changing `kernelCommandLine` requires `wsl --shutdown`.** Per `wsl-config`. Tillandsias' `--init` flow detects "no current cgroup-v2" and prompts the user with a one-liner (`Set-Content ...; wsl --shutdown`).
- **`autoMemoryReclaim=dropCache` is aggressive.** It evicts caches immediately; better is `gradual` (evict slowly when host is under pressure) per `wsl-config`.
- **`networkingMode=mirrored` requires Win 11 22H2+.** On older builds it silently falls back to NAT. Tillandsias' `windows-installer-prereqs.md` already requires 22H2+ for the new architecture.
- **WSLg sockets stay around** even with `[wsl2] guiApplications=false` if the file was already created. Run `wsl --shutdown` after toggling — `.wslconfig` only re-reads on VM start.
- **`generateResolvConf=false` removes `/etc/resolv.conf` regeneration**, but if you don't ship a replacement, Linux DNS is broken. Tillandsias ships `/etc/resolv.conf` pointing at the proxy container's DNS at distro-build time.

## See also

- `runtime/wsl-on-windows.md` — `wsl --import` semantics, drvfs ownership reporting
- `runtime/wsl-mount-points.md` — what drvfs reports when it IS mounted (irrelevant once disabled, but useful for diagnosing if a user enables it)
- `runtime/wsl2-disk-elasticity.md` — vhdx growth, sparseVhd, `--manage --resize` (planned)
- `runtime/podman-in-wsl2.md` — podman quirks under WSL2 — cgroup v2, fuse-overlayfs, subuid/subgid (planned)
- `runtime/wsl-daemon-patterns.md` — long-running services in WSL: systemd, `[boot] command`, `[boot] systemd`
- `runtime/secrets-management.md` — credential isolation rationale; why we don't put secrets on the distro filesystem
- `runtime/windows-installer-prereqs.md` — installer's WSL2 hard-requirement check
- `runtime/wsl-browser-isolation.md` — applies this hardening profile to the chromium-browser-isolation spec

## Pull on Demand

### Source

This cheatsheet documents the security boundary between Windows host and WSL2 distros, including 13 default bridges (drvfs, interop, WSLg, networking), and the hardening profile (wsl.conf knobs) that closes each bridge for the Tillandsias distro.

### Materialize recipe

```bash
#!/bin/bash
# Generate WSL2 isolation boundary hardening reference
# @trace spec:windows-wsl-runtime, spec:cross-platform

cat > wsl2-hardening.md <<'EOF'
# WSL2 Isolation Boundary Hardening

## Default Bridges (Closed by Tillandsias wsl.conf)
1. /mnt/c auto-mount (drvfs) → [automount] enabled=false
2. Windows binary interop → [interop] enabled=false
3. WSLg X11/Wayland → [gui] gui=false
4. /mnt/wsl vGPU → [gpu] memory limit + disable vGPU
5. /mnt/wslg → [wsl2] guiApplications=false

## Host-Side Hardening (.wslconfig)
- kernel command-line: cgroup_no_v1=all
- mirrored networking mode (no NAT exposure)
- host address loopback disabled (no 172.31.0.1 access)
- firewall enabled (Hyper-V boundary)

## Verification
- ls /mnt/c should fail (auto-mount disabled)
- which cmd.exe should fail (interop disabled)
- wsl --status shows mirrored mode, firewall enabled
EOF
```

### Generation guidelines

This cheatsheet is hand-curated and tracked in-repo. Regenerate after:
1. Microsoft adds new wsl.conf or .wslconfig keys
2. A new bridge is documented (Microsoft Learn updates)
3. Default behaviors flip between Windows builds
4. WSL2 networking mode changes

### License

License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) Content derived from Microsoft Learn (public documentation).
Last materialized: 2026-05-03
