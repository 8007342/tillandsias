---
tags: [windows, wsl, runtime, podman, development]
languages: [powershell]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# WSL on Windows Cheatsheet

## Provenance

- **URL**: https://learn.microsoft.com/en-us/windows/wsl/
- **Last updated**: 2026-04-29

## Basic Commands

### WSL Management

```powershell
# List distributions
wsl --list --verbose

# Import distribution
wsl --import <name> <install_dir> <tarball> --version 2

# Unregister distribution
wsl --unregister <name>

# Check WSL version
wsl --version
```

### Troubleshooting

```powershell
# Check available disk space in WSL
wsl df -h

# Check WSL status
wsl --status

# Shutdown WSL
wsl --shutdown
```

## Sources of Truth

- `openspec/specs/cross-platform/spec.md` — Cross-platform specification
- `docs/cross-platform-builds.md` — Cross-platform build strategy
