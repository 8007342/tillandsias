# Tillandsias

*Create. Work. Run. Stop.*

A portable Linux binary that makes software appear — safely, locally, reproducibly. Runs headless (CLI/automation) or with native trays for Linux, macOS, and Windows.

> **v0.3.0 "Fedora Pivot".** Tillandsias now uses official Fedora Project images for its runtime, eliminating custom rootfs maintenance and improving security and updates.

## Install

All three installers download the binary, verify SHA-256, and run
`tillandsias --init` automatically — no extra step required.

**Linux (Fedora Silverblue, Ubuntu, Debian, etc.)**
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

**macOS (Sonoma/Sequoia on Apple Silicon)**
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```

**Windows 10/11 (WSL2 required — run in PowerShell or Windows Terminal)**
```powershell
irm https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1 | iex
```

Each installer provisions the local runtime on first run:
- **Linux**: runs `tillandsias --init` inline in your terminal.
- **macOS**: launches the tray, which provisions a Fedora VM automatically.
- **Windows**: launches the tray, which provisions a Fedora WSL2 distro automatically.

Podman is the only host dependency on Linux (auto-detected). macOS and Windows
provision a lightweight Fedora-based utility VM; no host Podman required.

## Run

**Desktop (Tray Mode):**
The installer launches the tray automatically. A tray icon appears in your
system menu bar / notification area. Click it to view projects and container status.

**Headless (CLI/Automation — Linux only):**
```bash
tillandsias --headless /path/to/project
```

## How it Works: The Fedora Pivot

Tillandsias v0.3.0 introduced the "Fedora Pivot" architecture:
- **Official Images**: Instead of shipping custom rootfs tarballs, we pull official, signed images directly from the Fedora Project (WSL2 for Windows, Cloud Base for macOS).
- **Runtime Bootstrap**: The tray application provisions the VM, installs the `tillandsias-headless` agent, and materializes your local development environment on demand.
- **Zero-Drift**: All three platforms now share the exact same Fedora-based runtime environment for your projects.

## OpenCode: Analyze Code with LLM

Analyze a project with local LLM inference (no cloud, no credentials sent):

```bash
tillandsias /path/to/project --opencode --prompt "What is the main purpose?"
```

## Platform support

### Linux
First-class support for x86_64 and aarch64. musl-static binary requires only rootless podman.

### macOS
Native AppKit tray for Apple Silicon. Uses Apple's Virtualization.framework to run a Fedora-based utility VM. Supports high-performance virtio-vsock communication and native Terminal.app integration.

### Windows
Native Win32 NotifyIcon tray. Uses WSL2 to run a Fedora-based utility VM. Supports Windows Terminal and `wsl.exe` integration.

## All Downloads

See the [latest release](https://github.com/8007342/tillandsias/releases/latest) for all platform binaries, checksums, and Cosign signatures.
Release operators should run the [local release gate](docs/RELEASING.md) before dispatching the hosted signing and publishing workflow.

| File | Description |
|------|-------------|
| [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) | Checksums for all artifacts |
| [VERIFICATION.md](docs/VERIFICATION.md) | Signature verification instructions |

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
