---
tags: [podman, wsl2, windows, containers, runtime]
languages: [bash, powershell]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/
  - https://podman.io/docs
authority: medium
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Podman in WSL2

@trace spec:windows-wsl-runtime, spec:podman-orchestration, spec:forge-as-only-runtime

**Use when**: running rootless Podman inside a WSL2 distro, especially for Tillandsias' Windows runtime planning and diagnostics.

## Provenance

- Microsoft WSL docs: <https://learn.microsoft.com/en-us/windows/wsl/>
- Podman docs: <https://podman.io/docs>
- **Last updated:** 2026-05-19

## Quick reference

| Concern | Practice |
|---|---|
| Storage | Keep container storage inside the Linux filesystem, not `/mnt/c` |
| Cgroups | Prefer WSL with systemd enabled for service-like Podman workflows |
| Networking | Expect NAT or mirrored-mode differences by Windows/WSL version |
| UID maps | Verify `/etc/subuid` and `/etc/subgid` for rootless containers |
| Sockets | Keep API/control sockets on Linux paths with tight permissions |

## Common patterns

### Basic diagnostics

```bash
podman info
podman system df
podman ps --all
```

### Confirm rootless storage

```bash
podman info --format '{{.Store.GraphRoot}}'
```

The graph root should be on the distro filesystem for performance and permission correctness.

### Check user namespace ranges

```bash
grep "^$USER:" /etc/subuid /etc/subgid
```

## Common pitfalls

- **Using `/mnt/c` for graphroot** - drvfs semantics and performance are poor for container layers.
- **Assuming host networking parity** - WSL NAT and mirrored networking behave differently from native Linux.
- **Ignoring sparse disk growth** - images and layers grow the distro VHDX.
- **Mixing Windows and Linux path syntax** - bind mounts must use paths valid from inside WSL.

## See also

- `runtime/fedora-minimal-wsl2.md` - Tillandsias distro layout
- `runtime/wsl2-isolation-boundary.md` - WSL hardening and boundary rules
- `runtime/podman-control-plane.md` - Podman orchestration contract

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull WSL and Podman docs before relying on version-specific networking, systemd, or storage-driver behavior.

- **Upstream URL(s):**
  - `https://learn.microsoft.com/en-us/windows/wsl/`
  - `https://podman.io/docs`
- **Archive type:** documentation site references
- **Expected size:** `~5 MB selected pages`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/podman-in-wsl2`
- **License:** upstream-documentation
- **License URL:** `https://learn.microsoft.com/en-us/legal/termsofuse`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/runtime/podman-in-wsl2"
mkdir -p "$TARGET"
cp cheatsheets/runtime/podman-in-wsl2.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Keep Windows host paths and Linux distro paths separate.
2. Verify WSL systemd and rootless Podman behavior on the actual target Windows build.
