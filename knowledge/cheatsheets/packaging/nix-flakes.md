---
id: nix-flakes
title: Nix Flakes & Container Image Building
category: packaging/nix
tags: [nix, flakes, dockerTools, reproducible, containers, buildLayeredImage]
upstream: https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html
version_pinned: "2.28"
last_verified: "2026-03-30"
authority: official
---

# Nix Flakes & Container Image Building

## Quick Reference

```bash
nix build .#packageName              # Build a flake output
nix build                            # Build default package
nix develop                          # Enter dev shell
nix flake lock                       # Create/add missing inputs (never updates existing)
nix flake update                     # Update all inputs in flake.lock
nix flake update nixpkgs             # Update a single input
nix flake show                       # Show flake outputs
nix flake metadata                   # Show flake inputs and locked revisions
nix flake check                      # Run checks, verify outputs schema
nix store gc                         # Garbage-collect unreferenced store paths
```

Enable flakes without nix.conf:

```bash
nix --extra-experimental-features "flakes nix-command" build
```

## Flake Structure

```nix
{
  description = "Reproducible container images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        packages.default = pkgs.dockerTools.buildLayeredImage { /* ... */ };
        devShells.default = pkgs.mkShell { buildInputs = [ pkgs.nix ]; };
      }
    );
}
```

`flake-utils.lib.eachDefaultSystem` iterates over `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin` so you define outputs once.

## Inputs & Lockfiles

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";     # Branch
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";         # Stable channel
  nixpkgs.url = "github:NixOS/nixpkgs/<commit-sha>";        # Exact pin

  flake-utils.url = "github:numtide/flake-utils";
  flake-utils.inputs.nixpkgs.follows = "nixpkgs";           # Deduplicate

  custom.url = "path:./local-flake";                         # Local path
  custom.url = "git+https://example.com/repo?ref=main";     # Git URL
};
```

`flake.lock` is auto-generated JSON pinning every input to an exact revision and NAR hash. Commit it to version control. `nix flake lock` adds new inputs without touching existing ones; `nix flake update` resolves everything fresh.

## dockerTools

Three main image builders, each with different tradeoffs:

| Function | Output | Disk cost | Layers |
|---|---|---|---|
| `buildImage` | `.tar.gz` in store | Full image | Single layer |
| `buildLayeredImage` | `.tar.gz` in store | Full image | Multi-layer (default 100) |
| `streamLayeredImage` | Script that streams `.tar` to stdout | Minimal (no image in store) | Multi-layer (default 100) |

`streamLayeredImage` is best for CI and large images -- it avoids writing the full tarball to the Nix store. Load with: `$(nix build .#image --print-out-paths) | podman load`

`buildLayeredImage` uses `streamLayeredImage` internally, then materializes the result.

`buildImage` supports `runAsRoot` (real root via VM) for imperative setup; the layered variants use `fakeRootCommands` instead.

## buildLayeredImage

```nix
pkgs.dockerTools.buildLayeredImage {
  name = "my-app";
  tag = "latest";                        # Default: content hash (reproducible)
  fromImage = null;                      # Base image tarball, null = FROM scratch
  contents = [ pkgs.bash pkgs.coreutils ]; # Symlinked into image root (deprecated alias for copyToRoot)
  copyToRoot = pkgs.buildEnv {           # Preferred: merge paths without conflicts
    name = "image-root";
    paths = [ pkgs.bash pkgs.coreutils ];
    pathsToLink = [ "/bin" "/etc" ];
  };
  config = {
    Cmd = [ "/bin/bash" ];
    WorkingDir = "/app";
    Env = [ "PATH=/bin" "HOME=/root" ];
    ExposedPorts = { "8080/tcp" = {}; };
    Volumes = { "/data" = {}; };
    Labels = { "org.opencontainers.image.source" = "https://example.com"; };
  };
  maxLayers = 100;                       # Max 125 (minus fromImage layers)
  fakeRootCommands = ''
    mkdir -p ./app
    chown 1000:1000 ./app
  '';
  enableFakechroot = true;               # Makes / appear as image root in fakeRootCommands
}
```

**Key details:**
- `contents` is a legacy alias for `copyToRoot`; prefer `copyToRoot` with `buildEnv` to avoid symlink collisions.
- The closure of `config` (any store paths referenced in `Cmd`, `Env`, etc.) is automatically included in the image.
- Setting `tag = null` produces a content-addressed tag (the image hash), giving reproducible builds.

## Running Nix in Containers

For ephemeral Nix builds inside toolbox/podman containers:

```bash
# Install Nix in single-user mode (no daemon)
sh <(curl -L https://nixos.org/nix/install) --no-daemon

# Enable flakes
mkdir -p ~/.config/nix
echo 'extra-experimental-features = flakes nix-command' >> ~/.config/nix/nix.conf

# Build with source mounted read-only
podman run --rm -v ./src:/src:ro -v nix-store:/nix nix-builder \
  nix build /src#default --out-link /output/result
```

**Git tracking caveat:** Flakes in git repos only see tracked files. Run `git add` on new files before `nix build`, or the build will silently miss them.

**Caching across runs:** Mount `/nix` as a named volume to persist the store between ephemeral container invocations and avoid re-downloading everything.

## Content-Addressed Store

Every build artifact lives under `/nix/store/<hash>-<name>`. Two addressing modes:

- **Input-addressed** (default): hash derived from the derivation (build recipe + all inputs). Requires trusted signatures to import from binary caches.
- **Content-addressed** (experimental `ca-derivations`): hash derived from the output contents. Enables early cutoff -- if a dependency rebuild produces identical output, downstream rebuilds are skipped.

Binary caches serve pre-built store paths. Configure substituters in `nix.conf`:

```ini
substituters = https://cache.nixos.org https://my-cache.example.com
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= my-cache:AAAA...
```

`nix store verify --all` checks store integrity. `nix store gc` removes paths not reachable from GC roots.

## Upstream Sources

- [dockerTools reference (nixpkgs)](https://ryantm.github.io/nixpkgs/builders/images/dockertools/)
- [dockerTools source (nixpkgs)](https://github.com/NixOS/nixpkgs/blob/master/doc/build-helpers/images/dockertools.section.md)
- [Nix Flakes manual](https://nix.dev/manual/nix/2.28/command-ref/new-cli/nix3-flake.html)
- [nix flake update (2.28)](https://nix.dev/manual/nix/2.28/release-notes/rl-2.28)
- [Building container images tutorial (nix.dev)](https://nix.dev/tutorials/nixos/building-and-running-docker-images.html)
- [flake-utils](https://github.com/numtide/flake-utils)
- [nix2container (alternative)](https://github.com/nlewo/nix2container)
