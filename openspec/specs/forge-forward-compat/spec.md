<!-- @trace spec:forge-forward-compat -->

# forge-forward-compat Specification

## Status

status: active
annotation-count: 8
derived-from: code annotations only (no archive)
last-updated: 2026-05-02

## Purpose

Defines forward compatibility behavior when a forge container image with a HIGHER version than the currently expected version is discovered on disk. Instead of rebuilding the image, the tray SHALL use the newer image with a warning log, preserving user work and enabling safe version downgrades without data loss.

## Requirements

### Requirement: Detect Newer Forge Images

The tray app SHALL periodically scan local podman images and detect when a forge image exists with version > expected version.

- **Expected version**: The version tag computed from the current Tillandsias VERSION file (e.g., `tillandsias-forge:v0.1.170.45`)
- **Scan scope**: Only images matching pattern `tillandsias-forge:v*`
- **Search**: Use `podman images --format {{.Repository}}:{{.Tag}}` with filter `reference=tillandsias-forge:v*`
- **Version comparison**: Compare all version parts lexicographically (Major.Minor.ChangeCount.Build)

#### Scenario: Newer image detected

- **WHEN** Tillandsias VERSION is `0.1.170.45` (expects `tillandsias-forge:v0.1.170.45`)
- **AND** podman has image `tillandsias-forge:v0.1.170.50` on disk
- **THEN** version comparison determines 170.50 > 170.45 (true on Build part)
- **AND** `find_newer_forge_image()` returns `"tillandsias-forge:v0.1.170.50"`

#### Scenario: No newer image

- **WHEN** expected image is `tillandsias-forge:v0.1.170.45`
- **AND** podman has only `tillandsias-forge:v0.1.169.30` and `tillandsias-forge:v0.1.170.45`
- **THEN** `find_newer_forge_image()` returns `None` (expected or older only)

### Requirement: Use Newer Image Instead of Rebuild

When a newer forge image is discovered, the tray SHALL use it directly instead of rebuilding.

- **Condition**: Newer image MUST exist (from Requirement: Detect Newer Forge Images)
- **Action**: Use discovered image with warning log
- **Version tag**: Preserve the newer image's tag (e.g., `tillandsias-forge:v0.1.170.50`)
- **Rebuild**: SKIP image build entirely
- **Logging**: Emit WARN-level log explaining the situation

#### Scenario: Use newer image at startup

- **WHEN** init handler checks forge image staleness
- **AND** `find_newer_forge_image()` returns `"tillandsias-forge:v0.1.170.50"`
- **THEN** skip `build_forge_image()` call entirely
- **AND** emit log: `"Forge image newer than expected; using existing image {found=v0.1.170.50, expected=v0.1.170.45}"`
- **AND** create enclave containers using tag `tillandsias-forge:v0.1.170.50`

#### Scenario: Downgrade without data loss

- **WHEN** user downgrades Tillandsias from v0.1.170.50 to v0.1.170.45
- **AND** v0.1.170.50 forge image still exists on disk
- **THEN** tray detects newer image, uses v0.1.170.50, allows containers to start
- **AND** user project data preserved in container volumes
- **AND** no rebuild required

### Requirement: Staleness Check Ordering

The forge staleness detection logic SHALL check for newer images BEFORE deciding whether to rebuild.

#### Staleness Check Sequence

1. Compute expected image tag from current VERSION: `tillandsias-forge:v<MAJOR>.<MINOR>.<CHANGECOUNT>.<BUILD>`
2. Check if expected image exists on disk
   - If exists: Check for newer images (Requirement: Detect Newer Forge Images)
   - If newer exists: Use newer (skip build)
   - If no newer: Continue with stale/missing logic
   - If does not exist: Proceed to build
3. If no expected image AND no newer image: THEN build (normal path)

#### Scenario: Expected image exists, newer exists

- **WHEN** expected image `v0.1.170.45` exists AND `v0.1.170.50` exists
- **THEN** staleness check detects both
- **AND** returns newer image without rebuild

#### Scenario: Expected image missing, newer exists

- **WHEN** expected image `v0.1.170.45` does NOT exist
- **AND** newer image `v0.1.170.50` exists
- **THEN** staleness check finds newer and uses it
- **AND** no rebuild triggered

### Requirement: Logging and Observability

Forward-compat detection SHALL emit logs at WARN level to inform users and debugging.

- **Event**: Image selection (newer vs. expected vs. rebuild)
- **Format**: Structured log with version tags and action taken
- **Accountability**: Not a sensitive operation; no accountability fields required
- **Spec trace**: `@trace spec:forge-forward-compat, spec:forge-staleness`

#### Log Examples

```
WARN forge: Using newer forge image {found=tillandsias-forge:v0.1.170.50, expected=tillandsias-forge:v0.1.170.45}
  @trace spec:forge-forward-compat
```

```
INFO forge: Expected forge image exists and is current {image=tillandsias-forge:v0.1.170.45}
  @trace spec:forge-staleness
```

### Requirement: No Cache Invalidation on Forward-Compat

When using a newer image, the tray SHALL NOT invalidate any local caches or rebuild dependent images.

- **Proxy image**: Use existing proxy image (no rebuild)
- **Git service image**: Use existing git image (no rebuild)
- **Inference image**: Use existing inference image (no rebuild)
- **Project caches**: User workspace and project caches remain unchanged

#### Scenario: Version downgrade preserves caches

- **WHEN** user downgrades Tillandsias v0.1.170.50 → v0.1.170.45
- **AND** tray detects and uses newer image v0.1.170.50
- **THEN** all other enclave images remain unchanged
- **AND** project workspace, caches, git mirror volumes preserved

## Sources of Truth

- `cheatsheets/runtime/logging-levels.md` — WARN-level logging conventions
- `cheatsheets/runtime/image-versioning.md` — Version tag format and comparison rules (if exists)

## Related Specifications

- `forge-staleness` — Image staleness detection and rebuild triggers
- `forge-launch` — Enclave creation and forge container startup
- `init-command` — Initialization workflow and image management
