## Context
The Containerfile uses `FROM registry.fedoraproject.org/fedora-minimal:latest`. The Nix build (flake.nix) uses `pkgs.dockerTools.buildLayeredImage` which assembles the image from nixpkgs packages, not from the Fedora base image directly. However, the Containerfile serves as documentation and may be used by non-Nix build paths.

## Goals / Non-Goals
**Goals:** Pin Fedora version to 43 in Containerfile
**Non-Goals:** Changing the Nix build system

## Decisions
- Pin to `:43` rather than `:latest` for reproducibility
- Add @trace spec:default-image comment
