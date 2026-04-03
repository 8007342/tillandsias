## Why
Container shows "Fedora Linux 41" while host is Fedora Silverblue 43. The Containerfile uses `:latest` which is unpinned. Pin to 43 for consistency and reproducibility.

## What Changes
- Pin Containerfile FROM to `fedora-minimal:43` instead of `:latest`
- Verify flake.nix doesn't need changes (it builds from nixpkgs, not the Containerfile directly)

## Capabilities
### New Capabilities
_None_
### Modified Capabilities
- `default-image`: Base image pinned to Fedora 43

## Impact
- images/default/Containerfile — FROM line change
- flake.nix — verify no changes needed (nixpkgs-based build is independent)
