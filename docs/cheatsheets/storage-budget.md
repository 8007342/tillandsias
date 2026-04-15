# Storage Budget

@trace spec:default-image, spec:inference-container, spec:proxy-container, spec:enclave-network

Target storage footprint for the full Tillandsias enclave stack. Goal: fit comfortably on 100GB drives.

## Component Sizes

| Component | Target Size | Notes |
|-----------|-------------|-------|
| Podman machine VM | 10 GB | `--disk-size=10` (macOS/Windows only) |
| Forge image | <400 MB | Lean dev tools, no terminal UX bloat |
| Proxy image | <25 MB | Alpine + squid |
| Git image | <30 MB | Alpine + git + gh |
| Inference image | <500 MB | CPU-only binary, no GPU libs baked in |
| Tools overlay | <250 MB | 1 version only (no rollback slot) |
| Models (T0+T1) | ~1 GB | CPU-only models (qwen2.5:0.5b + tinyllama:1.1b) |
| **Total runtime** | **<2.5 GB** | **Fits on 100GB drives** |

## Design Decisions

### Inference: CPU-only binary

The ollama install script downloads ~2GB including CUDA/ROCm GPU libraries. We download the release tarball and extract only `bin/ollama` (~200MB), skipping `lib/ollama/` (~1.8GB of GPU runners). GPU users get device passthrough at runtime; GPU runner libs can be volume-mounted if needed.

### Forge: lean packages

Removed from base image: `mc vim-minimal nano eza bat fd-find fzf htop tree zoxide`. These are terminal UX conveniences, not build essentials. Users who need them can install via `microdnf install` inside a running container.

### Tools overlay: no rollback

Each overlay version is ~234MB. Keeping only the current version (no rollback slot) saves ~234MB. If the current version is broken, a rebuild takes <2 minutes.

### Podman machine: 10GB disk

Default is 20GB. The enclave stack totals <2.5GB, so 10GB provides ample headroom while halving the VM footprint on macOS/Windows.

## Verification

```bash
# Check image sizes
podman images --format "table {{.Repository}} {{.Tag}} {{.Size}}" | grep tillandsias

# Check overlay size
du -sh ~/.local/share/tillandsias/tools-overlay/current/

# Check model cache size
du -sh ~/.local/share/tillandsias/models/

# Check podman machine disk (macOS/Windows)
podman machine inspect --format '{{.Resources.DiskSize}}'
```
