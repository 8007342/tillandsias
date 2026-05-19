# podman-image-eviction Specification

@trace spec:podman-image-eviction

## Status

active

## Requirements

### Requirement: Image eviction is targeted and explainable

Cache management MUST evict Podman images only after identifying Tillandsias-owned candidates and reporting what will be removed.

#### Scenario: Eviction excludes unrelated images

- **WHEN** image eviction runs
- **THEN** it MUST restrict deletion candidates to known Tillandsias images or explicitly selected cache targets
- **AND** it MUST NOT prune unrelated user images as part of normal cache management

## Sources of Truth

- `cheatsheets/build/podman-image-management.md` - Image pruning and inspection
- `cheatsheets/runtime/podman.md` - Podman operations

