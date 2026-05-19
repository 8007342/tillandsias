# disk-usage-detection Specification

@trace spec:disk-usage-detection

## Status

active

## Requirements

### Requirement: Cache tooling reports disk pressure before eviction

Cache management tools MUST inspect Podman and filesystem usage before evicting images or cache directories.

#### Scenario: Disk usage is summarized

- **WHEN** cache management runs in diagnostic mode
- **THEN** it MUST report relevant image/cache size information
- **AND** it MUST distinguish measurement failure from an empty cache

## Sources of Truth

- `cheatsheets/build/podman-image-management.md` - Podman image inspection and pruning
- `cheatsheets/runtime/podman.md` - Podman runtime operations
- `cheatsheets/runtime/wsl2-disk-elasticity.md` - Disk growth and reclamation context

