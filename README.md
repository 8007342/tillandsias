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
