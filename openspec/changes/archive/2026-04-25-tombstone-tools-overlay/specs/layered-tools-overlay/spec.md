## ADDED Requirements

### Requirement: Capability is tombstoned

The `layered-tools-overlay` capability SHALL remain in the spec index
only as a tombstone. All operative requirements have been removed.
Any code or documentation that references this capability SHALL be
treated as legacy and migrated to `spec:default-image` (agent
hard-install) or `spec:opencode-web-session` (config overlay on
tmpfs).

#### Scenario: Tombstone visible to readers
- **WHEN** an engineer opens `openspec/specs/layered-tools-overlay/spec.md`
- **THEN** they SHALL see exactly one active requirement noting the
  tombstone
- **AND** they SHALL be pointed to the superseding specs

## REMOVED Requirements

### Requirement: Tools overlay directory structure

**Reason**: Superseded by image-baked agents in `spec:default-image`
(see `images/default/Containerfile` — claude, opencode, openspec are
installed at image build time under `/opt/agents/` with
`/usr/local/bin/` symlinks). The runtime overlay builder
(`scripts/build-tools-overlay.sh`) and its Rust driver
(`src-tauri/src/tools_overlay.rs`) have been tombstoned on 2026-04-25.

### Requirement: Tools overlay mounted read-only into forge containers

**Reason**: Tombstoned. Forge profiles no longer include the
`MountSource::ToolsOverlay` mount. `/home/forge/.tools` is not mounted
at all — agents resolve from `/usr/local/bin/` inside the image.

### Requirement: Entrypoints detect pre-installed tools

**Reason**: Tombstoned. Entrypoints now call `require_opencode`,
`require_claude`, `require_openspec` helpers in `lib-common.sh` which
verify the hard-installed paths (`/usr/local/bin/*`). Fallback to
runtime install has been removed — missing binary means the image is
corrupt and the entrypoint fails loudly.

### Requirement: Builder container populates overlay

**Reason**: Tombstoned. No builder container runs at attach time.
Agent installation moved to image-build time — see the
`RUN mkdir -p /opt/agents/...` step in `images/default/Containerfile`.

### Requirement: Background version checking and updates

**Reason**: Tombstoned. Agent version drift is now handled via
Tillandsias releases that ship a new forge image with new pinned
versions. Users get updates via the existing auto-updater.

### Requirement: Forge image version tracking

**Reason**: Tombstoned. The overlay's `forge_image` manifest field
was used to detect when a new forge image invalidated the overlay.
With no overlay, there's nothing to invalidate.

### Requirement: Cross-platform support

**Reason**: Tombstoned along with the overlay. Image-based agent
install is inherently cross-platform (the forge image is the same on
every platform that can run podman).
