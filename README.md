# Tillandsias

*Create. Work. Run. Stop.*

A portable Linux binary that makes software appear — safely, locally, reproducibly. Runs headless (CLI/automation) or with optional native GTK tray.

## Install

**Linux** (Fedora, Ubuntu, Debian, Arch, etc.)
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

The binary is fully portable (musl-static) and runs on any x86_64 Linux system without external dependencies.

<details>
<summary>Direct download</summary>

| Download |
|----------|
| [tillandsias-linux-x86_64](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-linux-x86_64) |

</details>

> **Note**: macOS and Windows support is planned via thin platform wrappers. Linux is the source of truth.

## Run

**Desktop (with tray UI, requires GTK4 runtime):**
```bash
tillandsias
```
A tray icon appears. Click to view projects and container status. Right-click → pick a project → Attach Here.

**Headless (CLI/automation):**
```bash
tillandsias --headless /path/to/project
```
No UI. Emits JSON events on stdout for scripting. Perfect for CI/CD, automation, and remote servers.

The binary auto-detects your environment and chooses the appropriate mode.

## Uninstall

```bash
tillandsias-uninstall
```

<details>
<summary>Uninstall + wipe everything</summary>

```bash
tillandsias-uninstall --wipe
```

Removes the binary, caches, container images, and all Tillandsias data.

</details>

## Requirements

**Required:**
- **Linux** (x86_64) — Fedora, Ubuntu, Debian, Arch, or any distro with podman
- [Podman](https://podman.io) (rootless) — `sudo dnf install podman` or `sudo apt install podman`

**For Tray Mode (optional):**
- GTK4 runtime — usually pre-installed on desktop systems
- For GNOME: [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) for system tray

**Note**: Headless mode requires no GTK or display server. Tray mode is optional and auto-disabled if GTK is unavailable.

## All Downloads

See the [latest release](https://github.com/8007342/tillandsias/releases/latest) for all platform binaries, checksums, and Cosign signatures.

| File | Description |
|------|-------------|
| [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) | Checksums for all artifacts |
| [VERIFICATION.md](docs/VERIFICATION.md) | Signature verification instructions |

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
