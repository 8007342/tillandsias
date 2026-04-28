---
tags: [windows, sandbox, isolation, hyper-v, chromium, browser-isolation, cross-platform]
languages: []
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/
  - https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file
  - https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-architecture
  - https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-cli
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# Windows Sandbox

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:chromium-browser-isolation

**Version baseline**: Windows 10 1903+ / Windows 11 (Pro/Enterprise/Education only — **NOT Home**).
**Use when**: hosting an isolated, ephemeral Windows process tree (e.g., the Chromium framework) with kernel-level isolation from the host — no shared filesystem, registry, credentials, or network namespace. Tillandsias' Windows browser-isolation backend per `spec:chromium-browser-isolation`.

## Provenance

- <https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/> — feature overview, SKU/hardware matrix, isolation model
- <https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file> — `.wsb` file format, all keys, defaults
- <https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-architecture> — Hyper-V container model, vGPU mechanics, "direct map" memory sharing
- <https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-cli> — `wsb start|exec|stop|list|connect` CLI (Windows 11 24H2+)
- **Last updated:** 2026-04-28

## What it is — and isn't

Hyper-V-backed lightweight VM with a separate Windows kernel. Per Microsoft Learn: *"Windows Sandbox uses hardware-based virtualization for kernel isolation. It relies on the Microsoft hypervisor to run a separate kernel that isolates Windows Sandbox from the host."* Spawned per session, ephemeral by default — closing the window deletes everything.

| Property | Default | Configurable? |
|---|---|---|
| Filesystem | fully isolated; no host paths visible | yes via `<MappedFolders>` (read-only recommended) |
| Registry | fully isolated | no |
| Credentials | none transferred from host (clean account `WDAGUtilityAccount`) | no |
| Network namespace | shared with Hyper-V default switch (NAT) | yes — `<Networking>Default|Disable</Networking>` |
| Clipboard | bidirectional with host | yes — `<ClipboardRedirection>` |
| GPU | software (WARP) by default; vGPU optional | yes — `<vGPU>Enable|Disable|Default</vGPU>` |
| Persistence | none — VHDX scratch is wiped on close | partial: Windows 11 22H2+ persists across in-sandbox **reboots** |

Windows Sandbox is NOT a security-equivalent replacement for a separate physical machine. Microsoft explicitly states it's a balance between isolation and convenience; targeted attacks against Hyper-V escapes are still in scope.

## Availability matrix

| Edition | Supported? |
|---|---|
| Windows 10/11 **Pro** | ✅ |
| Windows 10/11 **Enterprise** | ✅ |
| Windows 10/11 **Education** / Pro Education / SE | ✅ |
| Windows 10/11 **Home** | ❌ (hard block — feature absent) |

Hardware: x64 + Intel VT-x or AMD-V + SLAT + DEP/NX, virtualization enabled in BIOS, ≥4 GB RAM (8 GB recommended). On VMs, nested virtualization must be enabled.

Enable feature once: `Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM"` (PowerShell elevated) or via Optional Features → "Windows Sandbox" → reboot.

## `.wsb` configuration reference

XML at `*.wsb`. Launch with `WindowsSandbox.exe path\to\config.wsb` (legacy) or `wsb start --config path\to\config.wsb` (24H2+).

| Key | Values | Default | Tillandsias-relevant security note |
|---|---|---|---|
| `<vGPU>` | `Enable` / `Disable` / `Default` | `Default` (Enable if WDDM 2.5+) | Enable for Chromium GPU rendering perf; Disable falls back to WARP CPU rasterizer (~10× slower) |
| `<Networking>` | `Default` / `Disable` | `Default` (NAT via Hyper-V default switch) | **No middle ground**: full host-network access OR zero. See "Network gap" below |
| `<MappedFolders>` | list of `<MappedFolder>` | empty | Per-folder `<ReadOnly>true</ReadOnly>` strongly recommended — write-mapped folders survive sandbox close |
| `<LogonCommand>` | one `<Command>` element | none | Runs at boot as `WDAGUtilityAccount` (admin in sandbox); use to install Chromium |
| `<MemoryInMB>` | integer ≥2048 | 4096 | Auto-bumped to 2048 if too low; Tillandsias should set 4096 for Chromium framework |
| `<AudioInput>` | `Enable` / `Disable` / `Default` | `Default` (Enable) | **Disable** for Tillandsias — no mic exposure |
| `<VideoInput>` | `Enable` / `Disable` / `Default` | `Default` (Disable) | Already off; keep disabled |
| `<ProtectedClient>` | `Enable` / `Disable` / `Default` | `Default` (Disable) | Enable for AppContainer-level isolation: blocks copy/paste, restricts the RDP-style window |
| `<PrinterRedirection>` | `Enable` / `Disable` / `Default` | `Default` (Disable) | Keep disabled |
| `<ClipboardRedirection>` | `Enable` / `Disable` / `Default` | `Default` (Enable) | **Disable** for Tillandsias — blocks data exfil via clipboard |

## Tillandsias-recommended `.wsb` skeleton

Pre-stage the Chromium installer to a host folder, mount it read-only, install at logon:

```xml
<Configuration>
  <vGPU>Enable</vGPU>
  <Networking>Default</Networking>
  <MemoryInMB>4096</MemoryInMB>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <ProtectedClient>Enable</ProtectedClient>
  <PrinterRedirection>Disable</PrinterRedirection>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>C:\Users\bullo\AppData\Local\tillandsias\sandbox\framework</HostFolder>
      <SandboxFolder>C:\framework</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -File C:\framework\install-and-launch.ps1</Command>
  </LogonCommand>
</Configuration>
```

The `install-and-launch.ps1` (mounted read-only) silent-installs Chromium then launches it pinned to the project's URL.

## CLI (Windows 11 24H2+)

`wsb` replaces direct `WindowsSandbox.exe` for programmatic use:

| Command | Purpose | Tillandsias usage |
|---|---|---|
| `wsb start --config <path.wsb>` | Spawn a sandbox; returns sandbox ID | `tray_spawn::spawn_sandbox(project)` |
| `wsb list` | Enumerate running sandboxes | health check, multi-project tracking |
| `wsb exec --id <id> -c "<cmd>" -r System` | Run a command inside | (limited — no stdout capture) |
| `wsb connect --id <id>` | Open RDP session | inspection / debugging |
| `wsb stop --id <id>` | Force-terminate the sandbox | on project close |

Pre-24H2, only `WindowsSandbox.exe path.wsb` is available — no programmatic stop, no `exec`, no enumerated IDs. Tillandsias should detect 24H2+ at runtime and degrade gracefully.

## Memory cost

Per Microsoft Learn: *"Running Windows Sandbox with no applications open offers the Sandbox VM 4 GB of memory, but on test machines it only consumed 237 MB of memory on the host."* Memory sharing via "direct map" technology means the sandbox kernel pages map to the host's clean OS files (immutable read-only). Realistic Tillandsias overhead per sandbox: **~240 MB host RAM** + Chromium working set (200–800 MB depending on tabs).

## Common pitfalls (Tillandsias-specific)

- **Network gap (HARD)**: there is no documented `.wsb` config that lets the sandbox reach `localhost:3128` on the host while blocking external internet. `Networking=Default` exposes the entire host network; `Networking=Disable` blocks even host loopback. Two viable workarounds — both have trade-offs:
  1. **Host IP + per-project allowlist on the proxy**: keep `Networking=Default`, configure Chromium inside sandbox to use proxy at `<host-LAN-IP>:3128`, and rely on Squid's allowlist to enforce per-project egress. Risk: sandbox sees the LAN.
  2. **Mapped-folder proxy bridge**: `<Networking>Disable</Networking>` plus a host-side relay process that polls a file-shared queue under `<MappedFolders>`. Heavyweight; not Microsoft-documented.
- **No headless mode**: the sandbox window is always visible. Tillandsias can spawn it minimized but cannot suppress it entirely. For Tillandsias' design (per `spec:chromium-browser-isolation`, the window IS the browser window), this is desired behaviour.
- **No CDP attach across the sandbox boundary**: host-based Playwright cannot drive Chromium inside the sandbox via Chrome DevTools Protocol on `localhost:9222`. **Run Playwright INSIDE the sandbox** (bake into the framework folder at install time) rather than from the host. This aligns with `chromium-browser-isolation`'s "Playwright vendored in framework image" decision.
- **Multiple concurrent instances are 24H2+ only**: pre-24H2 Microsoft docs state *"Windows Sandbox currently doesn't allow multiple instances to run simultaneously"*. The 24H2 `wsb` CLI does support multi-instance per the new docs but Tillandsias must guard the multi-project case behind a Windows-version check.
- **`wsb exec` cannot capture stdout**: any "is Chromium ready" probe must use a side-channel (file in `<MappedFolders>`, network heartbeat to the proxy, etc.).
- **Read-only mapped folders DO survive process restart inside sandbox**: not a leak risk by themselves, but be deliberate about which paths are mapped read-only.
- **`WDAGUtilityAccount` is admin inside the sandbox**: `LogonCommand` runs elevated. The trade-off is: this only matters inside the sandbox VM, which is destroyed on close.
- **Persistence-across-reboot (Win11 22H2+)** is `In-sandbox restart preserves state, host restart wipes`. Tillandsias should treat sandbox lifetime as bound to host uptime.

## Tillandsias integration sketch

```text
tray (Rust)
  └─ tray_spawn::spawn_browser_window(project, session_id)
      ├─ Stage installer + install-and-launch.ps1 to:
      │     %LOCALAPPDATA%\tillandsias\sandbox\<project>\framework\
      ├─ Render .wsb from template, write to:
      │     %LOCALAPPDATA%\tillandsias\sandbox\<project>\<session>.wsb
      ├─ wsb start --config <session>.wsb       (24H2)
      │     OR  WindowsSandbox.exe <session>.wsb (legacy fallback)
      ├─ Track sandbox-id ⇄ session_id mapping in tray state
      └─ On project close:
            wsb stop --id <sandbox-id>          (24H2)
            OR  send WM_CLOSE to the WindowsSandbox.exe child (legacy)
```

## See also

- `runtime/wsl-on-windows.md` — sibling Windows isolation backend (WSL2 distros for forge/git/proxy/router/inference)
- `runtime/wsl-mount-points.md` — drvfs ownership semantics that DON'T apply here (Sandbox doesn't see /mnt/c)
- `runtime/podman-security-flags.md` — sibling Linux backend for `chromium-browser-isolation`
- `runtime/secrets-management.md` — credential isolation rationale (sandbox provides this for free)

## Pull on Demand

> This cheatsheet is hand-curated and tracked in-repo (committed_for_project: true).
> Provenance is exclusively Microsoft Learn. Refresh cadence: when Microsoft
> announces new `.wsb` keys or `wsb` subcommands.
