---
title: Install Nix for reproducible builds in forge image
gap: Nix package manager is not installed in the forge image
category: runtime-tool
status: implemented
proposed_at: 2026-05-28T22:00:00Z
implemented_at: 2026-05-29T08:24:52Z
evidence: Added RUN microdnf install -y nix + ENV vars to Containerfile and nix profile sourcing to entrypoint
changes:
  - file: images/default/Containerfile
    description: Add `RUN microdnf install -y nix` and configure nix with flakes enabled. Set ENV for nix paths and add `nix` group setup for multi-user install or use single-user mode.
  - file: images/default/entrypoint-forge-opencode.sh
    description: Source nix profile if present so `nix` commands work for the forge user
approved_by: orchestrator
---

## Gap

The `default-image` spec (openspec/specs/default-image/spec.md, line 23) requires:

> **Scenario: Image contains Nix**
> - **WHEN** the container starts
> - **THEN** `nix` SHALL be available for reproducible builds with flakes enabled

The current Containerfile does NOT install Nix. Running `nix` inside the forge fails with "command not found".

## Evidence

- `openspec/specs/default-image/spec.md` requirement: "Image contains Nix"
- `images/default/Containerfile` line 17-24: only installs bash, git, nodejs, java, maven — no nix
- `openspec/specs/forge-cache-dual/spec.md` references `/nix/store/` as the shared cache mount point (lines 82-96), but the Containerfile never installs nix or creates the `/nix/store/` directory

## Impact

Without Nix:
- Agents cannot use `nix build` or `nix develop` for reproducible builds
- The shared cache (`/nix/store/`) mount point is unused — no nix-managed process populates it
- The `nix-first.md` agent instruction at `config-overlay/opencode/instructions/nix-first.md` exists but the tool it documents is absent
- Flake-based project workflows are impossible inside the forge

## Proposed Change

Add to Containerfile after the system packages installation:

```dockerfile
# Nix for reproducible builds (flake-enabled, single-user mode)
RUN microdnf install -y nix \
    && nix-env -iA nixpkgs.nix \
    && mkdir -p /nix/store /nix/var \
    && chmod 0755 /nix /nix/store /nix/var
ENV NIX_PATH=nixpkgs=channel:nixos-unstable \
    NIX_BUILD_CORES=0 \
    NIX_CONF_DIR=/etc/nix
```

And source nix profile in entrypoint (idempotent — no-op if nix not present).

## Safety

- Nix runs inside the container as the `forge` user — no host Nix install required
- No network access to `cache.nixos.org` if enclave network is active; builds use pre-cached derivations from the `/nix/store/` bind-mount
- No credential exposure — Nix is a pure build tool
- The nix daemon (multi-user) is intentionally NOT used; single-user mode avoids root dependency and socket activation
