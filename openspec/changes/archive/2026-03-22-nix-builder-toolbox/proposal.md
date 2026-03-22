## Why

Container images built with `podman build` have no staleness detection — once cached, they're never rebuilt even when the Containerfile, entrypoint, or opencode config changes. Users must manually `podman rmi` to force a rebuild. This is broken UX.

Nix flakes solve this with content-addressable builds — any input change triggers an automatic rebuild, cache hits are <1 second. But Nix shouldn't be installed on the host. Instead, a dedicated builder toolbox (Fedora Minimal + Nix) handles all image builds. The builder toolbox's Nix store persists across runs (shared home dir), making subsequent builds fast.

## What Changes

- New `tillandsias-builder` toolbox: Fedora Minimal + single-user Nix with flakes enabled
- New `flake.nix` at project root: declarative image definitions for `forge` and `web` images
- New `scripts/build-image.sh`: staleness detection, builds via Nix inside builder toolbox, loads into podman on host
- Modified `build.sh`: calls `build-image.sh` for image management
- Modified `PodmanClient`: add `load_image` method for nix-built tarballs
- Modified `runner.rs`/`handlers.rs`: use staleness-aware image building

## Capabilities

### New Capabilities
- `nix-builder`: Builder toolbox with Nix for reproducible container image builds

### Modified Capabilities
- `podman-orchestration`: Staleness detection, `load_image` for nix tarballs
- `default-image`: Rebuilt declaratively via flake.nix instead of Containerfile
- `dev-build`: build.sh integrates image building

## Impact

- New toolbox: `tillandsias-builder` (auto-created on first image build)
- New files: `flake.nix`, `scripts/build-image.sh`
- Host requirements: podman + toolbox only (no Nix on host)
- Builder toolbox Nix store at `~/.local/share/nix` persists across runs
- Image rebuilds: ~5s for config-only changes, ~60s for dependency changes, <1s for cache hits
