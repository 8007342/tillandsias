# Tillandsias

*Create. Work. Run. Stop.*

A tray app that makes software appear — safely, locally, reproducibly.

## Install

<!-- GitHub doesn't support JS-based tab switching in markdown.
     We use <details> to show the user's likely OS expanded, others collapsed. -->

<details open>
<summary><strong>Linux</strong></summary>

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

<details>
<summary>Other ways to install</summary>

| Format | Download |
|--------|----------|
| RPM package (Fedora/RHEL) | [Tillandsias.rpm](https://github.com/8007342/tillandsias/releases/latest) |
| DEB package (Ubuntu/Debian) | [Tillandsias.deb](https://github.com/8007342/tillandsias/releases/latest) |
| AppImage (portable) | [Tillandsias.AppImage](https://github.com/8007342/tillandsias/releases/latest) |

</details>
</details>

<details>
<summary><strong>macOS</strong></summary>

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

<details>
<summary>Other ways to install</summary>

| Format | Download |
|--------|----------|
| Disk Image — Apple Silicon | [Tillandsias_aarch64.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_0.1.35_aarch64.dmg) |
| Disk Image — Intel | [Tillandsias_x64.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_0.1.35_x64.dmg) |
| App Bundle (.app) | [Tillandsias.app.tar.gz](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.app.tar.gz) |

</details>
</details>

<details>
<summary><strong>Windows</strong></summary>

```powershell
irm https://github.com/8007342/tillandsias/releases/latest/download/install.ps1 | iex
```

<details>
<summary>Other ways to install</summary>

| Format | Download |
|--------|----------|
| Installer (.exe) | [Tillandsias_x64-setup.exe](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_0.1.35_x64-setup.exe) |
| MSI Installer | [Tillandsias_x64.msi](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias_0.1.35_x64_en-US.msi) |

</details>
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

<details>
<summary>Uninstall + wipe everything</summary>

```bash
tillandsias-uninstall --wipe
```

Removes the binary, caches, container images, and all Tillandsias data.

</details>

## Requirements

- [Podman](https://podman.io) (rootless)
  - Linux: `sudo dnf install podman` / `sudo apt install podman`
  - macOS: `brew install podman && podman machine init && podman machine start`
  - Windows: [Podman Desktop](https://podman-desktop.io)
- **GNOME desktop** (Linux): the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) must be enabled for the tray icon to appear. Install via Extension Manager or:
  ```bash
  gnome-extensions install appindicatorsupport@rgcjonas.gmail.com
  ```

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
