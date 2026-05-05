# Tillandsias

*Create. Work. Run. Stop.*

A tray app that makes software appear — safely, locally, reproducibly.

## Install

**Linux** (Fedora, Ubuntu, Debian, etc.)
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

<details>
<summary>Direct download</summary>

| Download |
|----------|
| [Tillandsias-linux-x86_64.AppImage](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias-linux-x86_64.AppImage) |

</details>

> **Note**: macOS and Windows support is planned via container stack. Currently, Linux is the primary platform.

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

- **Linux** (Fedora, Ubuntu, Debian, etc.)
- [Podman](https://podman.io) (rootless) — `sudo dnf install podman` or `sudo apt install podman`
- **GNOME desktop**: the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) must be enabled for the tray icon to appear. Install via Extension Manager or:
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
