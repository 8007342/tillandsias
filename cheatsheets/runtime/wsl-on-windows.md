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
