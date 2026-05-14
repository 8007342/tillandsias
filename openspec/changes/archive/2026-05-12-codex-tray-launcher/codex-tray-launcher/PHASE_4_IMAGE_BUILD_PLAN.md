# Phase 4: Codex Pre-Installation in Forge Image

## Overview
Add Codex binary/tooling to the forge container image so it's available at startup without runtime pulls. This phase is CRITICAL — all other phases are blocked until Codex is in the image.

## Current State (Pre-Phase 4)
- Menu button is implemented and clickable ✓
- Handler delegates to `handle_attach_here()` (temporary)
- Container launch will fail with "entrypoint not found" until Phase 4 is complete
- Nix image build infrastructure is in place (flake.nix exists with patterns for other tools)

## Required Changes

### 1. Create Codex Entrypoint Script
**File**: `images/default/entrypoint-forge-codex.sh`

**Pattern**: Follow `entrypoint-forge-claude.sh` structure:
```bash
#!/usr/bin/env bash
# entrypoint-forge-codex.sh — Codex code analysis agent entrypoint
#
# Lifecycle: source common -> populate cheatsheets -> setup CA -> find project -> exec codex

source /usr/local/lib/tillandsias/lib-common.sh

# Populate hot paths (cheatsheets tmpfs)
populate_hot_paths

# Setup CA trust (same as Claude)
# ... [copy CA setup from entrypoint-forge-claude.sh] ...

# Find project directory
PROJECT_DIR="${TILLANDSIAS_PROJECT:-.}"
[ ! -d "$PROJECT_DIR" ] && exit 1

# Print welcome banner
echo "🏗 Codex — code analysis agent"

# Launch Codex
exec codex "$@"
```

**Key points**:
- Must call `populate_hot_paths` (cheatsheet tmpfs mounting)
- Must setup CA trust for proxy (same code as Claude)
- Must handle TILLANDSIAS_PROJECT environment variable
- Must exec Codex (not run in background)

### 2. Modify flake.nix

**Changes needed**:

#### A. Add Codex entrypoint file reference (line ~18, after other entrypoints)
```nix
forgeEntrypointCodex = ./images/default/entrypoint-forge-codex.sh;
```

#### B. Add Codex to `contents` package list (lines 36-92)
```nix
# Codex — code analysis agent
# TODO: Replace with actual Codex package when available
# For now: placeholder or lazy-pull from registry
```

**Decision needed**: 
- Is Codex available in nixpkgs?
- If yes: add `codex` to contents list
- If no: either
  - Create a custom build using `fetchurl` + `buildFHSUserEnv`
  - Mark for lazy-pull (download at runtime)
  - Create a placeholder bash script for testing

#### C. Copy entrypoint in fakeRootCommands (after line 120)
```bash
cp ${forgeEntrypointCodex} ./usr/local/bin/entrypoint-forge-codex.sh
chmod +x ./usr/local/bin/entrypoint-forge-codex.sh
```

### 3. Update Container Profile (if needed)
**File**: `crates/tillandsias-core/src/container_profile.rs`

**Check**:
- Does `forge_codex_profile()` function exist? (NO — needs creation)
- Should match `forge_claude_profile()` pattern:
  ```rust
  pub fn forge_codex_profile() -> ContainerProfile {
      ContainerProfile {
          entrypoint: "/usr/local/bin/entrypoint-forge-codex.sh",
          working_dir: None,
          mounts: common_forge_mounts(),
          env_vars: common_forge_env(),
          secrets: vec![],
          image_override: None,
          pids_limit: 512,
          read_only: false,
          tmpfs_mounts: vec![],
      }
  }
  ```

### 4. Update forge_profile() Match
**File**: `src-tauri/src/handlers.rs` (line ~2625)

**Current**:
```rust
match agent {
    OpenCode => forge_opencode_profile(),
    Claude => forge_claude_profile(),
    OpenCodeWeb => forge_opencode_web_profile(),
}
```

**Needed** (for full implementation after Phase 4):
- Need to select Codex profile when handling Codex containers
- Currently `handle_codex_project()` delegates to `handle_attach_here()` which uses Claude profile
- Once proper container launch is implemented, will need Codex-specific profile selection

## Verification Checklist

- [ ] `images/default/entrypoint-forge-codex.sh` exists and is executable
- [ ] `flake.nix` references Codex entrypoint
- [ ] Codex binary/package is in `contents` list (or lazy-pull mechanism in place)
- [ ] `fakeRootCommands` copies entrypoint to `/usr/local/bin/`
- [ ] Image builds without errors: `scripts/build-image.sh forge`
- [ ] Codex binary is present in image: `podman run tillandsias-forge which codex`
- [ ] Codex can be executed: `podman run tillandsias-forge codex --help`

## Estimated Effort
- Entrypoint script: 15 min (copy template, customize)
- flake.nix modifications: 20 min
- Testing + troubleshooting: 30-45 min
- Total: 1-1.5 hours + image build time (10-15 min)

## Blockers & Dependencies
- **Codex availability**: Need to determine if Codex is in nixpkgs, or if custom build needed
- **Nix expertise**: flake.nix modifications require Nix fluent developer
- **Test environment**: Image build requires nix-builder toolbox (auto-created by build.sh)

## Notes for Implementation
- Entrypoint should follow security principles: cap-drop, no credentials, cheatsheet tmpfs
- CA trust setup can be copy-pasted from entrypoint-forge-claude.sh
- Use @trace annotations: `// @trace spec:codex-tray-launcher, spec:forge-hot-cold-split`
- Once this phase completes, come back to `handle_codex_project()` in handlers.rs to implement proper container launch

## Next Phase (After 4)
Once Codex is in image:
1. Implement `forge_codex_profile()` in container_profile.rs
2. Update `forge_profile()` match to handle Codex agent type (might need new MenuCommand variant or agent selection)
3. Implement proper container launch in `handle_codex_project()` (instead of delegating to handle_attach_here)
4. Test container launch end-to-end
5. Run Phase 6-7 tests
