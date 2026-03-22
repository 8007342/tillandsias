## Context

The forge project runs `nix build` inside a `nixos/nix:latest` container. We follow a similar pattern but use a Fedora-based toolbox instead — consistent with the project convention (toolbox name = purpose), and the toolbox shares the host home directory so the Nix store persists.

## Goals / Non-Goals

**Goals:**
- Zero Nix on host — builder toolbox handles everything
- Automatic staleness detection — any input change triggers rebuild
- Fast cache hits (<1s when nothing changed)
- Shared Nix store across builds (persistent in toolbox home)
- flake.nix defines forge and web images declaratively
- build.sh integrates seamlessly

**Non-Goals:**
- Multi-arch cross-compilation (CI handles that)
- Nix devShell for Rust development (toolbox handles that)
- Remote Nix cache (cachix etc) — local only for now

## Decisions

### D1: Separate builder toolbox

`tillandsias-builder` toolbox: Fedora Minimal + Nix (single-user). Separate from the `tillandsias` dev toolbox because Nix is only needed for image builds, not Rust compilation. Auto-created on first image build.

### D2: Nix store persistence

Toolbox shares host home dir. Nix store lives at `~/.local/share/nix/` (configured via `NIX_STORE_DIR` or default `/nix` inside toolbox). The Nix store persists across toolbox recreations because it's on the host filesystem.

Actually — Nix requires `/nix` to exist. In a toolbox, we can create `/nix` since toolbox containers are mutable. The store lives inside the toolbox's `/nix` which persists as long as the toolbox exists. If the builder toolbox is destroyed, Nix rebuilds from scratch (acceptable — still reproducible).

### D3: Staleness detection via flake.lock hash

Instead of mtime-based detection, use the flake.lock content hash. If `sha256sum flake.lock` matches the hash stored at build time, skip rebuild. Any `nix flake update`, dependency bump, or config change updates flake.lock or flake.nix, changing the hash.

For non-flake files (entrypoint.sh, opencode.json), these are copied into the Nix derivation as sources — Nix tracks their content hashes automatically.

### D4: Build flow

```
build.sh --install (or tillandsias attach-here)
  → scripts/build-image.sh forge
    → ensure tillandsias-builder toolbox exists
    → toolbox run -c tillandsias-builder nix build .#forge-image
    → Nix: content hash check → cache hit? skip : rebuild
    → outputs /nix/store/...-image.tar.gz
    → podman load < tarball (runs on host, podman is shared)
    → tag as tillandsias-forge:latest
```

### D5: flake.nix image structure

Two outputs:
- `#forge-image`: Fedora-based dev environment (OpenCode, OpenSpec, Nix, git, node)
- `#web-image`: Alpine-based httpd (tiny, <10MB)

The forge image uses `pkgs.dockerTools.buildLayeredImage` for efficient layering.
Config files (entrypoint.sh, opencode.json) are included as Nix path references — changing them triggers rebuild automatically.
