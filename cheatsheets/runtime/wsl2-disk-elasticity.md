---
tags: [wsl2, windows, disk, vhdx, runtime]
languages: [powershell, bash]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/disk-space
authority: high
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# WSL2 disk elasticity

@trace spec:windows-wsl-runtime, spec:disk-usage-detection

**Use when**: reasoning about WSL2 distro VHDX growth, sparse disk behavior, cleanup, and resize operations.

## Provenance

- Microsoft WSL disk space docs: <https://learn.microsoft.com/en-us/windows/wsl/disk-space>
- **Last updated:** 2026-05-19

## Quick reference

| Topic | Practice |
|---|---|
| Growth | WSL2 VHDX files grow as Linux writes blocks |
| Cleanup | Delete files inside Linux first, then compact if needed |
| Images | Container layers can dominate distro size |
| Shutdown | Run `wsl --shutdown` before host-side compaction or resize work |
| Monitoring | Check both Linux free space and Windows free space |

## Common patterns

### Check Linux filesystem usage

```bash
df -h /
du -sh ~/.local/share/containers 2>/dev/null || true
```

### Check WSL state from Windows

```powershell
wsl --list --verbose
wsl --shutdown
```

### Reclaim container space first

```bash
podman system df
podman image prune
```

## Common pitfalls

- **Expecting host disk to shrink automatically** - deleting Linux files does not always compact the VHDX immediately.
- **Only checking `df -h`** - Windows free space can still be the limiting factor.
- **Pruning live images** - only remove images/volumes the runtime no longer needs.
- **Resizing while WSL is running** - shut down WSL before host-managed disk operations.

## See also

- `runtime/fedora-minimal-wsl2.md` - distro build and image storage context
- `runtime/wsl2-isolation-boundary.md` - WSL boundary hardening
- `runtime/podman-in-wsl2.md` - Podman storage inside WSL

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull Microsoft docs before using current `wsl --manage`, sparse VHD, compaction, or resize commands.

- **Upstream URL(s):**
  - `https://learn.microsoft.com/en-us/windows/wsl/`
- **Archive type:** documentation site reference
- **Expected size:** `~3 MB selected pages`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/wsl2-disk-elasticity`
- **License:** upstream-documentation
- **License URL:** `https://learn.microsoft.com/en-us/legal/termsofuse`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/wsl2-disk-elasticity"
mkdir -p "$TARGET"
cp cheatsheets/runtime/wsl2-disk-elasticity.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Check whether the target Windows build supports sparse VHD and `wsl --manage`.
2. Prefer pruning unused container layers before host-level VHD operations.
