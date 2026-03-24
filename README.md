# Tillandsias

*Create. Work. Run. Stop.*

A tray app that makes software appear — safely, locally, reproducibly.

## Install

### Linux
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

### macOS
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

### Windows
```powershell
irm https://github.com/8007342/tillandsias/releases/latest/download/install.ps1 | iex
```

<details>
<summary><strong>Other Binaries</strong> (direct download)</summary>

All binaries are signed with [Sigstore Cosign](https://docs.sigstore.dev/) and include SHA256 checksums.

#### Linux
| Format | Download |
|--------|----------|
| AppImage (portable) | [Tillandsias.AppImage](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.AppImage) |
| Debian (.deb) | [Tillandsias_amd64.deb](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_amd64.deb) |

#### macOS
| Format | Download |
|--------|----------|
| Disk Image (.dmg) — Apple Silicon | [Tillandsias_aarch64.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_aarch64.dmg) |
| Disk Image (.dmg) — Intel | [Tillandsias_x64.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_x64.dmg) |
| App Bundle (.app.tar.gz) — Apple Silicon | [Tillandsias.app.tar.gz](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_aarch64.app.tar.gz) |

#### Windows
| Format | Download |
|--------|----------|
| Installer (.exe) | [Tillandsias.exe](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.exe) |
| MSI Installer | [Tillandsias.msi](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.msi) |

#### Checksums & Signatures
| File | Download |
|------|----------|
| SHA256 checksums | [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) |

See [docs/VERIFICATION.md](docs/VERIFICATION.md) for signature verification instructions.

</details>

## Run

```bash
tillandsias
```

That's it. A tray icon appears. Right-click → pick a project → Attach Here.

## Uninstall

```bash
tillandsias-uninstall
```

### Uninstall + Wipe Everything

```bash
tillandsias-uninstall --wipe
```

Removes the binary, caches, container images, and all Tillandsias data.

## Requirements

- [Podman](https://podman.io) (rootless) — the only dependency
  - Linux: `sudo dnf install podman` / `sudo apt install podman`
  - macOS: `brew install podman && podman machine init && podman machine start`
  - Windows: [Podman Desktop](https://podman-desktop.io)

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
