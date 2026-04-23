# Windows Setup Cheatsheet

@trace spec:cross-platform

## One-Line Install

```powershell
irm https://github.com/8007342/tillandsias/releases/latest/download/install.ps1 | iex
```

Downloads the NSIS installer, runs it silently, checks for Podman, and initializes the Podman machine.

## Podman on Windows

@trace spec:podman-orchestration

| Task | Command | Notes |
|------|---------|-------|
| Install Podman | `winget install RedHat.Podman` | Uses WSL2 backend |
| Check version | `podman --version` | Requires v4.0+ |
| Init machine | `podman machine init` | Creates WSL2 VM, ~1GB download |
| Start machine | `podman machine start` | Must run before any container ops |
| Stop machine | `podman machine stop` | Frees resources |
| Remove machine | `podman machine rm` | Destroys VM |
| Check status | `podman machine list` | Shows Running/Stopped |
| Machine info | `podman machine info` | Backend type, paths, etc. |

### Key Differences from Linux

- **Linux**: Podman runs natively, no machine needed.
- **macOS/Windows**: Podman needs a Linux VM ("machine") via WSL2 (Windows) or Apple Virtualization (macOS).
- Tillandsias auto-starts the machine if stopped (`Os::needs_podman_machine()` in `state.rs`).

### WSL2 Backend

Podman on Windows uses WSL2. Requirements:
- Windows 10 version 2004+ or Windows 11
- WSL2 feature enabled (`wsl --install` if needed)
- Hyper-V capable CPU (most modern CPUs)

Config paths:
- Machine config: `%USERPROFILE%\.config\containers\podman\machine\wsl\`
- Machine images: `%USERPROFILE%\.local\share\containers\podman\machine\wsl\`
- Events: `%USERPROFILE%\.local\share\containers\podman\podman\`

## Build on Windows

### Prerequisites

| Tool | Install | Purpose |
|------|---------|---------|
| Rust | `winget install Rustlang.Rustup` | Compiler toolchain |
| Node.js | `winget install OpenJS.NodeJS.LTS` | Tauri frontend build |
| VS Build Tools | `winget install Microsoft.VisualStudio.2022.BuildTools` | MSVC linker, Windows SDK |
| Podman | `winget install RedHat.Podman` | Container runtime |

### Native Build (PowerShell)

```powershell
cargo tauri build          # Release build (NSIS + MSI)
cargo build --workspace    # Debug build (no bundle)
cargo test --workspace     # Run tests
cargo clippy --workspace   # Lint
```

### Install Locations

| Item | Path |
|------|------|
| App binary | `%LOCALAPPDATA%\Tillandsias\tillandsias.exe` |
| NSIS uninstaller | `%LOCALAPPDATA%\Tillandsias\uninstall.exe` |
| App config | `%APPDATA%\tillandsias\config.toml` |
| Start Menu shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk` |
| Singleton lock | `%TEMP%\tillandsias.lock` |
| Build locks | `%TEMP%\tillandsias-build\build-*.lock` |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| TLS error downloading | Script forces TLS 1.2; upgrade PowerShell if still failing |
| `podman machine start` fails | Run `wsl --install` then reboot, then retry |
| "connection closed unexpectedly" | PowerShell 5.1 TLS issue — fixed in install.ps1 |
| Machine won't start after sleep | `podman machine stop && podman machine start` |
| Disk space warning | `podman system prune -a` to clean images |
| Proxy/git/inference do nothing on launch (v0.1.157.180 or earlier) | See "Stale enclave images" below — `podman rmi` the four enclave tags and relaunch |

### Stale enclave images (v0.1.157.180 and earlier)

@trace spec:fix-windows-image-routing, spec:default-image

In versions ≤ v0.1.157.180 the Windows image-build path always built the forge image and tagged it as `tillandsias-forge`, `tillandsias-proxy`, `tillandsias-git`, **and** `tillandsias-inference`. All four tags resolved to the same image ID and the same forge entrypoint, so launching the proxy/git/inference containers either did nothing useful or crashed.

Detect: `podman images | grep tillandsias-` — if all four enclave tags show the same `IMAGE ID`, you are affected.

Fix on existing installs after upgrading to a version with the bug fix:

```bash
# Wipe the broken tag set so the next launch builds the right images
podman rmi localhost/tillandsias-forge:v<old> \
           localhost/tillandsias-proxy:v<old> \
           localhost/tillandsias-git:v<old>   \
           localhost/tillandsias-inference:v<old>

# Launch the tray; first "Attach Here" rebuilds each image from its
# own Containerfile (images/{default,proxy,git,inference}/Containerfile).
```

After the rebuild, re-run `podman images | grep tillandsias-` and verify the four enclave tags now show **different** image IDs.
