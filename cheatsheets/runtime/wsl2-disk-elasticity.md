---
tags: [windows, wsl2, vhdx, ext4, sparse, fragmentation, disk-space, ollama, podman-storage]
languages: [powershell, bash]
since: 2026-04-28
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/disk-space
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/basic-commands
  - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: true
pull_recipe: see-section-pull-on-demand
---

# WSL2 disk elasticity — vhdx, sparse, and growth

@trace spec:agent-cheatsheets, spec:cross-platform, spec:windows-wsl-runtime, spec:default-image, spec:inference-container

**Version baseline**: WSL2 ≥ 2.5 for `wsl --manage`; sparseVhd is `[experimental]` on Windows 11 22H2+ (still flagged experimental as of 2026-04-28).
**Use when**: sizing the tillandsias WSL distro's vhdx for podman image storage + ollama model cache + project scratch; reclaiming disk after `podman rmi`/`ollama rm`/repo wipe; resizing the cap when the user runs out of room mid-pull.

## Provenance

- <https://learn.microsoft.com/en-us/windows/wsl/disk-space> — vhdx file location, default size (1 TB sparse since WSL 0.58.0), `wsl --manage <distro> --resize`, manual diskpart fallback
- <https://learn.microsoft.com/en-us/windows/wsl/wsl-config> — `[wsl2] defaultVhdSize`, `[experimental] sparseVhd`, `[experimental] autoMemoryReclaim`
- <https://learn.microsoft.com/en-us/windows/wsl/basic-commands> — `wsl --shutdown`, `wsl --terminate`, `wsl --update`, `wsl --status`
- <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart> — manual `expand vdisk` fallback for older WSL where `--manage` is unavailable
- **Last updated:** 2026-04-28

## The model

Each WSL2 distro has one **dynamic-expansion VHDX** on Windows. WSL mounts it as ext4 inside the VM. From `disk-space`:

> "These VHDs use the [ext4 file system type] and are represented on your Windows hard drive as an *ext4.vhdx* file."

> "By default each VHD file used by WSL 2 is initially allocated a 1TB maximum amount of disk space (prior to WSL release 0.58.0 this default was set to a 512GB max and 256GB max prior to that)."

> "WSL mounts a VHD that will expand in size as you use it, so your Linux distribution sees that it can grow to the allocated maximum size of 1TB."

So: the Linux side sees a 1 TB ext4 filesystem. The Windows-side `ext4.vhdx` file starts small and grows ON-DEMAND as data is written. The "1 TB" is a **cap**, not an allocation. With the experimental `sparseVhd=true` flag, the host-side NTFS file is also block-sparse — when Linux frees blocks (via `fstrim` or after `--manage --set-sparse true`), the underlying NTFS file *shrinks back*.

## What this means for Tillandsias

- **No need to allocate large vhdx up-front.** Ship the distro with default cap (1 TB on WSL ≥ 0.58.0); let it grow as the user pulls images and models.
- **Multi-GB model downloads** (ollama pulls 4-40 GB; podman image layer pulls 1-6 GB) write large sequential files. ext4's extents allocator handles these well — fragmentation in practice is low. Microsoft Learn does NOT make a fragmentation guarantee, but ext4's behavior on this case is well-known kernel-side. The risk is **NTFS-side fragmentation** of the vhdx file as it grows, which we mitigate with sparseVhd + Windows defrag scheduling.
- **Reclaim is opt-in.** `rm` inside the distro frees ext4 blocks but does NOT shrink the vhdx file on Windows unless you separately run reclaim. Two paths: `wsl --manage <distro> --set-sparse true` (one-shot), or `[experimental] sparseVhd=true` for new VHDs (auto on creation).

## Recommended `.wslconfig` for the tillandsias distro

```ini
# @trace spec:windows-wsl-runtime, spec:cross-platform
# @cheatsheet runtime/wsl2-disk-elasticity.md
[wsl2]
# 256 GiB cap. NTFS-side starts small (sparse); the cap is the linux-side
# fs size only. We picked 256 GiB rather than the 1 TB default because
# Tillandsias' largest realistic working set (10x ollama mid-size models +
# all our podman images + per-project scratch) fits in ~120 GB, leaving
# headroom for growth without committing to an unrecoverable cap.
# (Microsoft Learn `wsl-config`: "Set the Virtual Hard Disk (VHD) size
# that stores the Linux distribution … file system. Can be used to limit
# the maximum size that a distribution file system is allowed to take up.")
defaultVhdSize = 274877906944          # 256 GiB

# 5-min idle timeout — when tray quits, VM stops, RAM returns to Windows.
vmIdleTimeout = 300000

[experimental]
# NTFS-side block-sparse new VHDs: deleted blocks return to host fs.
# Without this, vhdx never shrinks on disk even when Linux frees blocks.
sparseVhd = true

# Reclaim cached memory gradually when host is under pressure.
# Per `wsl-config`: "cached memory will be reclaimed slowly and automatically".
autoMemoryReclaim = gradual
```

## Sizing policy for the tillandsias distro

| Workload | Approximate size | Notes |
|---|---|---|
| Fedora-minimal rootfs (after `microdnf install` of podman/crun/etc.) | 600 MB | Initial vhdx after `wsl --import` |
| podman image cache (forge + proxy + git + router + inference + browser-chrome, all versions) | 4–8 GB | Stable; old versions pruned by `prune_old_images()` |
| ollama model cache | 4–60 GB | One small model is 4 GB, full model lineup can hit 60 GB |
| podman volume mounts (per-project scratch, build caches) | 5–30 GB | Caps via tmpfs sizes; persistent caches grow with usage |
| **Working set total (typical user)** | 30–60 GB | |
| **Working set total (heavy user)** | 100–150 GB | |

**Recommended cap: 256 GiB.** Rationale: leaves 1.5-2× headroom over the heavy-user case. Sparse, so the Windows-side file only grows to actual usage. If the cap is hit mid-`ollama pull`, the user runs `wsl --manage tillandsias --resize 512GB` (one command, takes ≤30 s on WSL ≥ 2.5).

**Don't ship with a smaller cap.** A 64 GB cap would force users to grow the vhdx within 1–2 model pulls; the resize-up procedure on older WSL versions (which is the diskpart fallback below) is painful enough to be a real support cost.

## `wsl --import` invocation

```powershell
$rootfs   = "$env:LOCALAPPDATA\Tillandsias\stage\tillandsias-distro.tar"
$instDir  = "$env:LOCALAPPDATA\Tillandsias\WSL\tillandsias"
New-Item -ItemType Directory -Force -Path $instDir | Out-Null

wsl.exe --import tillandsias $instDir $rootfs --version 2
```

The vhdx file lands at `$instDir\ext4.vhdx`. Per `disk-space`: *"To find the location of your VHD file, used to store your Linux distribution data, you can either find it stored as a 'LocalState' folder associated with the package name of the distribution …"* — i.e., `%LOCALAPPDATA%\Packages\…\LocalState\ext4.vhdx` for Microsoft Store distros, or your chosen `--import` path otherwise.

`wsl --import` documented options at `basic-commands`:

> "Options include: `--vhd`: Specifies the import distribution should be a .vhdx file instead of a tar file (this is only supported using WSL 2). `--version <1/2>`: Specifies whether to import the distribution as a WSL 1 or WSL 2 distribution"

The `defaultVhdSize` from `.wslconfig` applies to the new VHD created during `--import`. There is no documented `--vhd-size` argument; community recipes mentioning it are unreliable.

## Resizing the cap after the fact

### Modern path (WSL ≥ 2.5)

Per `disk-space`:

> "The `wsl --manage` command is only available to WSL releases 2.5 and higher. … Run `wsl --manage <distribution name> --resize <memory string>`. Supported memory strings are of the form `<Memory Value>B/M/MB/G/GB/T/TB`. Decimal values are currently unsupported …"

```powershell
wsl --shutdown                              # MUST shutdown first
wsl --manage tillandsias --resize 512GB
```

The Linux-side will show a 512 GB ext4 capacity after next boot; existing data is preserved. The host-side vhdx file is still sparse — the bytes haven't been allocated, just the cap raised.

### Legacy path (WSL < 2.5) — diskpart

For users on older WSL builds, the manual fallback is documented at `disk-space`:

```powershell
# (from disk-space; verbatim)
wsl --shutdown
diskpart
DISKPART> Select vdisk file="<vhdx path>"
DISKPART> expand vdisk maximum=<new size in MB>
DISKPART> exit
```

After diskpart raises the file cap, boot the distro and grow ext4:

```bash
wsl -d tillandsias -- /usr/sbin/resize2fs /dev/sdX     # see lsblk for the right device
```

This is documented in `disk-space` step-by-step. It works but is more error-prone than `--manage`. Tillandsias' `--init` checks `wsl --version` and steers users toward `--update` if they're stuck on legacy.

## Reclaim — getting space back to NTFS

After heavy churn (`podman rmi`, `ollama rm`, `git gc` on the mirrors), the Linux ext4 has free blocks but the host-side `ext4.vhdx` does NOT shrink unless you reclaim. Three options:

1. **`sparseVhd=true` from the start** (recommended; we ship this in `.wslconfig`). New VHDs are block-sparse — when Linux ftrims, the NTFS file shrinks naturally. No manual step needed.

2. **One-shot retroactive** (for vhdxs created before sparseVhd was on):
   ```powershell
   wsl --shutdown
   wsl --manage tillandsias --set-sparse true
   ```
   This converts an existing vhdx to block-sparse. After conversion, Linux's `fstrim -av` (or just deleting files) propagates back to NTFS.
   *Caveat:* `--set-sparse` is documented at `disk-space` but the exact verb form may have evolved in WSL 2.5+; verify with `wsl --manage --help` on first prototype.

3. **Manual `optimize-vhd` (PowerShell)** — Hyper-V module:
   ```powershell
   wsl --shutdown
   Optimize-VHD -Path "$instDir\ext4.vhdx" -Mode Full
   ```
   This is a Hyper-V cmdlet, not a WSL one. Requires the Hyper-V PowerShell tools to be installed (they are when `Microsoft-Hyper-V-Management-PowerShell` is enabled). Reduces vhdx file size if the guest has freed blocks. Slower than `--manage --set-sparse` but works on every WSL version.

## Fragmentation — the ollama-model-pull case

The user-flagged concern: *"prevent fragmentation when downloading large models"*. Two layers:

### Linux side (ext4 inside the vhdx)

ext4 uses extents (since 2008) for large file allocation. A multi-GB sequential write (ollama pulls write the model file once, contiguously) lands in a small number of extents — typically <10 for a 40 GB file when there's enough free space ahead of the write. Microsoft Learn doesn't speak to this, but the kernel.org ext4 documentation does. Practical recommendation:

- **Keep ≥20% free space inside the distro.** Below that, ext4 starts placing extents in non-optimal locations. Tillandsias should warn the user when free space is below 20% of the cap (matches existing guidance for any ext4 system).
- **`fallocate(2)` is your friend** — `ollama` uses it correctly when downloading. If you write your own model fetcher, pre-allocate the target file's full size with `fallocate -l <size> <path>` BEFORE writing data.

### NTFS side (the vhdx file as a Windows file)

The vhdx grows in chunks. Over time, the file's NTFS extents can fragment as Windows decides to extend the file in non-contiguous regions. Mitigations:

- **`sparseVhd=true`** keeps the file block-sparse, so growth-extension is more uniform.
- **Run Windows Defrag occasionally on the volume** containing the vhdx (typically `C:\`). Microsoft schedules this weekly by default; for SSDs, defrag becomes "TRIM optimization" which is fine.
- **Don't store the vhdx on a fragmented volume.** If the user's `C:\` is < 15% free, defrag won't help; they need to clean up Windows.

## Verifying disk state

```powershell
# Linux side — what does ext4 see
wsl -d tillandsias -- df -h /
# Expected: /dev/sdc 256G used Available Use% /

# Linux side — extent count for a specific file
wsl -d tillandsias -- /usr/sbin/filefrag /var/lib/containers/storage/overlay/<sha>/diff
# Expected: <10 extents for a multi-GB file

# Windows side — vhdx file size on NTFS
$vhd = "$env:LOCALAPPDATA\Tillandsias\WSL\tillandsias\ext4.vhdx"
(Get-Item $vhd).Length / 1GB
# Expected: < cap; matches actual usage if sparseVhd=true

# Windows side — vhdx fragmentation
fsutil file queryextents $vhd
# Expected: small number of extents on a fresh distro;
# growing as the file extends
```

## Common pitfalls

- **`--manage --resize` requires `wsl --shutdown` first.** It cannot resize a running distro. The Tillandsias `--init` flow does the shutdown automatically; user-invoked resize must do it explicitly.
- **The `--manage` command is WSL ≥ 2.5.** Older WSL: use `wsl --update` first. If it can't update (admin restrictions, offline), the diskpart fallback above works on any version.
- **`Optimize-VHD` requires the Hyper-V Management PowerShell module.** Not available on Windows Home by default; users on Home should rely on `sparseVhd=true` from the start.
- **`sparseVhd=true` only affects NEWLY created VHDs.** Existing VHDs need `wsl --manage --set-sparse true`.
- **The `[experimental]` flag means Microsoft may change semantics.** sparseVhd has been experimental since 2023 and is widely used; safe to enable, but watch for behavior changes in WSL release notes.
- **`defaultVhdSize` is bytes, not GB.** Easy off-by-1024 trap. 256 GiB = 274877906944 bytes. Pet peeve: `wsl-config` documents this in bytes only.
- **Cap below 64 GB is risky.** A single model pull plus a podman image cache fills it. Surface a clear error to the user if they configure < 64 GB.
- **Linux `df -h` may show "use%" higher than actual** because ext4 reserves 5% for root. `tune2fs -m 0 /dev/sdX` removes the reservation; we don't, because root reservation prevents fragmentation in the last 5% of free space.

## Tillandsias `--init` flow

```text
1. Read host's .wslconfig; if defaultVhdSize is missing, write 256 GiB.
2. If [experimental] sparseVhd is missing, write sparseVhd = true.
3. wsl --shutdown   (so the new .wslconfig takes effect)
4. wsl --import tillandsias $instDir $rootfs --version 2
5. Confirm vhdx file at $instDir\ext4.vhdx exists.
6. Confirm cap with: wsl -d tillandsias -- df -BG / | tail -n1 | awk '{print $2}'
   Expected: 256G
7. If cap is < 256G (older WSL applied a different default), prompt the user
   to either accept the smaller cap or run `wsl --manage tillandsias --resize 256G`.
```

## See also

- `runtime/wsl2-isolation-boundary.md` — the rest of `.wslconfig` keys (firewall, autoProxy, dnsTunneling)
- `runtime/fedora-minimal-wsl2.md` — what gets baked into the rootfs that the vhdx hosts
- `runtime/wsl-on-windows.md` — `wsl --import` semantics including the orphaned ext4.vhdx pre-clean we already ship
- `runtime/podman-in-wsl2.md` — podman storage backend (`/var/lib/containers/storage` lives inside this vhdx) — planned
- `runtime/wsl-mount-points.md` — drvfs (irrelevant once `/mnt/c` is disabled, but contextually useful)

## Pull on Demand

> Hand-curated, tracked in-repo (`committed_for_project: true`).
> Provenance: vendor primary sources only (Microsoft Learn).
> Refresh cadence: when WSL releases a new `--manage` subcommand, when
> `[experimental] sparseVhd` graduates from experimental, or when the
> default cap changes again (was 256 GB → 512 GB → 1 TB historically).
