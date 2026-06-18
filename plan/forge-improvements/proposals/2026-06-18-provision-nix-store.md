---
title: Provision Nix store inside forge container
gap: "missing_tools: nix — nix-first.md instruction exists, TILLANDSIAS_SHARED_CACHE=/nix/store configured, but /nix does not exist"
category: runtime-tool
status: proposed
proposed_at: 2026-06-18T06:00:00Z
changes:
  - file: images/default/Containerfile
    description: |
      Install Nix package manager via the official installer script
      (curl | sh), creating /nix/store and setting up the Nix daemon or
      single-user install.
  - file: images/default/entrypoint-forge-opencode.sh
    description: |
      Ensure NIX_PATH, NIX_SSL_CERT_FILE, and related env vars are set
      at runtime. Source nix-daemon or nix.sh if present.
---

## Gap

Diagnostic run `diagnostics_20260617T201317Z-summary.md` reports Nix as missing:

- Proposed enhancements: "nix — nix-first.md instruction references Nix workflow;
  env var TILLANDSIAS_SHARED_CACHE=/nix/store set but /nix does not exist; Nix
  store is not provisioned"

The project includes a `nix-first.md` instruction file that agents are expected
to follow, and the forge environment has `TILLANDSIAS_SHARED_CACHE=/nix/store`
preconfigured. However, the Nix package manager and store are not installed,
making the instruction file and env var misleading.

## Evidence

- `diagnostics_20260617T201317Z-summary.md`: nix in proposed enhancements
- `images/default/entrypoint-forge-opencode.sh` or Containerfile: env var
  `TILLANDSIAS_SHARED_CACHE=/nix/store` is set
- Agent instruction file referencing Nix workflow exists in the repository

## Privacy / Isolation Assessment

- Nix single-user install creates `/nix/store` locally — no daemon needed
- Nix builds run in sandboxed mode by default; respects existing proxy
- Download of packages goes through the existing proxy ACL
- No new credentials, mounts, or privileges required
- **Safe within the existing privacy/isolation envelope.**
