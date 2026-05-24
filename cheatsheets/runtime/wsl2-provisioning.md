---
tags: [wsl, wsl2, windows, provisioning, fedora, rootfs, systemd, wslg]
languages: [bash, powershell]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/vm-provisioning-lifecycle/spec.md
  - openspec/specs/windows-native-tray/spec.md
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro
  - https://learn.microsoft.com/en-us/windows/wsl/systemd
  - https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps
authority: medium
status: proposed
tier: bundled
---

# WSL2 provisioning for the Tillandsias VM on Windows

@trace spec:vm-provisioning-lifecycle, spec:windows-native-tray
@cheatsheet runtime/vsock-transport.md, runtime/wslg-chromium-passthrough.md

**Use when**: the Windows tray's first-run lifecycle is being implemented or debugged, when reasoning about the single-distro contract, or when triaging a "Setting up Fedora Linux…" failure.

## Provenance

- Microsoft Learn `basic-commands` — `wsl --install`, `wsl --import`, `wsl --terminate`, `wsl --unregister`
- Microsoft Learn `use-custom-distro` — tarball-based distro import
- Microsoft Learn `systemd` — `[boot] systemd=true` semantics
- Microsoft Learn `tutorials/gui-apps` — WSLg passthrough requirements
- `openspec/specs/vm-provisioning-lifecycle/spec.md` — Tillandsias contract

## The single-distro contract

Tillandsias maintains **exactly one** WSL distro per Windows install, named `tillandsias`. Every container — proxy, git, forge, inference, browser-chrome, future vault — runs as a **podman container inside that one distro**. The prior multi-distro architecture (one WSL distro per service) is retired.

The user never sees the distro name, never logs into it interactively, and never edits files inside it. The tray treats it as an opaque VM.

```
Windows host
└─ tillandsias-tray.exe                    (Win32 NotifyIcon)
   └─ wsl --distribution tillandsias --exec ...
      └─ Fedora 44 VM (one only)
         ├─ tillandsias-headless           (vsock listener on :42420)
         └─ podman containers
            ├─ tillandsias-proxy
            ├─ tillandsias-git-<project>
            ├─ tillandsias-inference
            ├─ tillandsias-vault
            └─ tillandsias-forge-<project>
```

## `wsl --install` vs `wsl --import`

| Command | What it does | Why Tillandsias prefers it |
|---|---|---|
| `wsl --install [-d Distro]` | Downloads from Microsoft Store, registers, runs first-time setup wizard | Pulls Microsoft's pre-rolled images; we want Fedora 44 specifically |
| `wsl --import <name> <install-dir> <tarball>` | Imports a rootfs tarball as a new distro; no Store interaction | **This is the path we use.** We control the rootfs source. |

Tillandsias does NOT call `wsl --install` for distro creation; it only calls it for WSL itself if `wsl --status` reports WSL is missing.

## Fedora rootfs source

The rootfs is pulled from Fedora's official container registry mirror at first-run, **on the host**, then handed to `wsl --import`. Note that Fedora's "Container Base Generic" tarball is the closest published rootfs to "minimal init-friendly" — it is suitable for `wsl --import` after a trivial post-process.

```
https://dl.fedoraproject.org/pub/fedora/linux/releases/<ver>/Container/<arch>/images/Fedora-Container-Base-Generic-<ver>-<build>.x86_64.tar.xz
```

Concrete pattern for Fedora 44 x86_64:

```
https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-Container-Base-Generic.44-1.5.x86_64.tar.xz
```

(The exact `1.5` build suffix changes per snapshot; the host shell resolves the latest by parsing the directory listing.)

After download:

1. SHA-256 verify against `<filename>-CHECKSUM` from the same directory.
2. Cache at `%LOCALAPPDATA%\tillandsias\rootfs\fedora-44-<sha>.tar.xz`.
3. `wsl --import tillandsias %LOCALAPPDATA%\tillandsias\wsl\tillandsias-disk <tarball>`.

## Provisioning command sequence

This is the host shell's first-run flow in shorthand.

```powershell
# Step 1: precondition checks
wsl --version            # require recent WSL (Win10 19044+ / Win11)
wsl --status             # if missing → wsl --install --no-distribution

# Step 2: download rootfs (with progress reporting to the tray)
$rootfs = "$env:LOCALAPPDATA\tillandsias\rootfs\fedora-44-<sha>.tar.xz"
# (the host shell handles the curl-equivalent)

# Step 3: import as our distro
wsl --import tillandsias `
  "$env:LOCALAPPDATA\tillandsias\wsl\tillandsias-disk" `
  $rootfs `
  --version 2

# Step 4: bake /etc/wsl.conf inside the distro (enables systemd, etc.)
wsl --distribution tillandsias --user root -- /bin/sh -c "cat > /etc/wsl.conf << 'EOF'
[boot]
systemd = true
[user]
default = forge
[interop]
enabled = true
appendWindowsPath = false
[automount]
enabled = false
EOF"

# Step 5: forcibly restart the distro so systemd starts
wsl --terminate tillandsias
wsl --distribution tillandsias -- /bin/true   # cold start

# Step 6: drop the tillandsias-headless binary into the VM
wsl --distribution tillandsias --user root -- /bin/sh -c "install -m 755 /mnt/staged/tillandsias-headless /usr/local/bin/tillandsias-headless"

# Step 7: enable the in-VM headless as a systemd unit listening on vsock
wsl --distribution tillandsias --user root -- /bin/sh -c "cat > /etc/systemd/system/tillandsias-headless.service << 'EOF'
[Unit]
Description=Tillandsias in-VM headless (vsock control wire)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/tillandsias-headless --listen-vsock 42420
Restart=always
RestartSec=1s
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now tillandsias-headless.service"
```

After Step 7 the tray opens a vsock connection to `(vm_cid, 42420)` and the menu transitions to the standard UX.

## Lifecycle commands

| Command | Effect | When used |
|---|---|---|
| `wsl --distribution tillandsias -- /bin/true` | Starts the VM if stopped, no-op if running | Every tray launch |
| `wsl --terminate tillandsias` | Stops the VM but keeps `ext4.vhdx` and config | Tray exit, after graceful drain |
| `wsl --unregister tillandsias` | Removes the distro AND deletes `ext4.vhdx` | "Reset Tillandsias" maintenance path; never on normal exit |
| `wsl --shutdown` | Stops ALL WSL distros on the host | Avoid — too broad; would affect other users' WSL workloads |

## Enabling systemd inside the VM

WSL2 supports systemd via `/etc/wsl.conf`:

```ini
[boot]
systemd = true
```

After writing this, a `wsl --terminate tillandsias` is required for the change to take effect; on the next start, `systemd` runs as PID 1 and `tillandsias-headless.service` activates.

Verify systemd is up:

```powershell
wsl --distribution tillandsias -- systemctl --version
# Expect: systemd 256+ (Fedora 44 ships with a recent build)
wsl --distribution tillandsias -- systemctl is-system-running
# Expect: running (or degraded — that's still fine for our purposes)
```

If `systemctl --version` errors with "command not found", systemd was not enabled and the distro is running under the WSL `init` shim. Re-write `wsl.conf` and `wsl --terminate`.

## WSLg requirements

WSLg is the Linux GUI passthrough layer used by `wslg-chromium-passthrough.md`. Requirements:

| Requirement | Why | Verification |
|---|---|---|
| Windows 11 (22H2+ preferred) | WSLg ships pre-installed on Win11; on Win10 it requires the WSL Preview package | `winver` shows 22H2 or later |
| GPU driver supporting WDDM 3.0+ | WSLg uses Hyper-V vGPU; older WDDM has no Linux passthrough | `dxdiag` → "Driver Model: WDDM 3.x" |
| Intel/AMD/NVIDIA WDDM driver | Generic display drivers (basic VGA) cannot do vGPU | Vendor driver from Intel.com / AMD.com / NVIDIA.com |
| WSL2 (not WSL1) | WSLg requires the Linux kernel VM | `wsl --list -v` shows `2` in VERSION |

Quick check that WSLg works inside our distro:

```powershell
wsl --distribution tillandsias -- /bin/sh -c "command -v xeyes && DISPLAY=:0 xeyes"
```

`xeyes` from `xorg-x11-apps` opens a Linux GUI window on the Windows desktop. If you see eyes, WSLg works. If `DISPLAY` is unset, WSLg is not wired (likely Win10 without the Preview package, or `[wsl2] guiApplications=false` in `.wslconfig`).

For Tillandsias' Chromium passthrough specifically, see `wslg-chromium-passthrough.md`.

## File share strategy

Two competing options exist; Tillandsias picks the second.

| Option | Path | Trade-off |
|---|---|---|
| **drvfs** auto-mount of Windows drives | `/mnt/c/Users/<user>/src` inside VM | Built-in but slow on `node_modules`-style trees and reports `root:root` ownership |
| **virtio-fs / 9p** explicit share of `~/src/` | `/home/forge/src` inside VM (bind from `%USERPROFILE%\src`) | Faster, controlled ownership, only shares what we want |

The host shell mounts `%USERPROFILE%\src` into the VM at `/home/forge/src`. This is the single project home convention across Linux, Windows, and macOS (decision #7 in the host-shell plan). The user navigates `C:\Users\<user>\src\<project>` from Explorer; the in-VM forge sees `/home/forge/src/<project>`.

`/mnt/c/...` access via drvfs is **disabled** by `[automount] enabled = false` in `wsl.conf` — see `wsl2-isolation-boundary.md` for the rationale. The explicit share is the only sanctioned host↔VM filesystem bridge.

## Common pitfalls

- **`wsl --import` fails with "Hostname contains invalid characters"** — the install-dir was passed as a UNC path (`\\?\C:\...`). Pass a plain `C:\...` path.
- **`systemctl` says "Failed to connect to bus"** — `[boot] systemd=true` was added but `wsl --terminate tillandsias` was not run; the running VM is still using the legacy init.
- **`wsl --distribution tillandsias -- ...` hangs forever** — the VM has a stuck systemd unit blocking boot. `wsl --terminate tillandsias`, then start with `--user root -- /bin/sh` to debug.
- **The tarball SHA mismatches** — Fedora's mirror sometimes serves a partial file behind a CDN; re-download from a different mirror under `https://download.fedoraproject.org/...`.
- **`appendWindowsPath = true` leaks Windows `PATH` into Linux** — disable it; otherwise `which` finds `cmd.exe` and breaks shell tab-completion.
- **Two `wsl --import` calls with the same name race** — `wsl --import` is not atomic. The host shell takes a file lock at `%LOCALAPPDATA%\tillandsias\.wsl-import.lock` before invoking.
- **VHDX growth is irreversible without compaction** — every container layer pulled inside the VM grows the disk; deleted files do not return space to Windows. See `wsl2-disk-elasticity.md` for compaction.

## Failure-mode → status-line mapping

The tray's `🔵 Setting up Fedora Linux…` status text rolls through one of these sub-states (all displayed under the same menu line so the user sees one progress thread):

| Sub-state | Trigger | Failure → menu line |
|---|---|---|
| `Downloading rootfs…` | Step 2 in progress | `🥀 Rootfs download failed: <reason>` |
| `Installing tillandsias…` | Steps 3-6 in progress | `🥀 Provisioning failed: import error` |
| `Starting VM…` | Step 7 + vsock connect | `🥀 Provisioning failed: VM start timeout` |

Each failure shows "Retry" and "Open log" sub-items. The log path is `%LOCALAPPDATA%\tillandsias\logs\provisioning-<timestamp>.log`.

## See also

- `runtime/wsl2-isolation-boundary.md` — the hardening profile baked into `/etc/wsl.conf`
- `runtime/wsl2-disk-elasticity.md` — VHDX growth and compaction
- `runtime/fedora-minimal-wsl2.md` — the rootfs we build (alternative to pulling from Fedora's mirror)
- `runtime/idiomatic-vm-exec.md` — how the host shell drives commands inside the VM after provisioning
- `runtime/vsock-transport.md` — the control-wire that activates once the VM is up
- `runtime/wslg-chromium-passthrough.md` — Chromium GUI passthrough on top of WSLg
- `openspec/specs/vm-provisioning-lifecycle/spec.md` — normative contract
- `openspec/specs/windows-native-tray/spec.md` — Windows native tray architecture
