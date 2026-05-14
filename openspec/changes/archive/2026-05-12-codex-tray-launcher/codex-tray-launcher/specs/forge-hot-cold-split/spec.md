# Forge Hot-Cold Split

@trace spec:forge-hot-cold-split, spec:image-layer-composition

**Purpose**: Tillandsias forge image architecture with two-layer design: cold (baked, immutable) and hot (runtime config, ephemeral). Enables zero-startup-latency agent launch.

## MODIFIED Requirements

### Requirement: Codex tool in cold layer (NEW SCENARIO ADDED)

The forge image cold layer (immutable, Nix build time) SHALL include the Codex binary and dependencies, enabling instant launch without runtime pulls.

#### Scenario: Codex is baked into forge at build time
- **WHEN** the forge image is built via `scripts/build-image.sh forge`
- **THEN** the Codex binary is included in the immutable `/opt/` layer
- **AND** Codex dependencies (runtime libraries, etc.) are resolved and baked in
- **AND** no network access is required when a Codex container starts

#### Scenario: Build time is acceptable for Codex addition
- **WHEN** Codex is added to the Nix build in `flake.nix`
- **THEN** the total build time increase is ≤ 5 minutes (estimated)
- **AND** the total image size increase is ≤ 100 MB (per design trade-off)
- **AND** Codex does not conflict with existing tools (OpenCode, Claude, Flutter, Gradle)

#### Scenario: Codex configuration is runtime (hot layer)
- **WHEN** a Codex container starts with user-specific settings
- **THEN** configuration is loaded from the hot layer (`.tillandsias/config.toml` or equivalent)
- **AND** the cold layer (Codex binary) is unchanged
- **AND** each project can have independent Codex configuration

#### Scenario: Codex binary is discoverable in PATH or /opt
- **WHEN** a Codex container entrypoint runs
- **THEN** the Codex executable is available via standard lookup:
  - In `PATH` environment variable, OR
  - At a known location like `/opt/codex` or `/opt/bin/codex`
- **AND** the entrypoint does not perform any runtime installation

## Sources of Truth

- `cheatsheets/build/nix-image-builds.md` — Nix flake.nix patterns for reproducible image composition
- `cheatsheets/runtime/forge-architecture.md` — Forge cold/hot layer split and design rationale
- `cheatsheets/build/image-layer-optimization.md` — Image size budgets and startup performance targets
