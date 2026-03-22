## Context

Tillandsias uses OpenSpec for spec-driven development. Each change goes through proposal → design → specs → tasks → implementation → archive. The version scheme must reflect this workflow and ensure monotonic increments across all release artifacts.

Cargo and Tauri both require semver (3 parts), but our full version is 4 parts. We bridge this by using the first 3 parts for Cargo/Tauri and the full 4 parts for git tags and release naming.

## Goals / Non-Goals

**Goals:**
- 4-part version: `v<Major>.<Minor>.<OpenSpecChangeCount>.<BuildIncrement>`
- Monotonic — every build has a strictly increasing version
- Rolling `stable` and `latest` tags updated automatically
- Version tracked in a single source of truth file
- CI automates version bumping and tag management

**Non-Goals:**
- Calendar-based versioning
- Pre-release channels (alpha/beta) — not needed for MVP
- Automatic major/minor bumps — those are manual decisions

## Decisions

### D1: Version Source of Truth

**Choice:** A `VERSION` file at the project root containing the full 4-part version (e.g., `0.0.0.1`). CI and build scripts read from this file. Cargo.toml and tauri.conf.json derive their 3-part semver from the first 3 components.

**Why:** Single source of truth avoids version drift. The VERSION file is trivial to read in any language (Rust, shell, GitHub Actions).

### D2: Component Semantics

| Component | Meaning | Bumped when |
|-----------|---------|-------------|
| Major | Breaking changes | Manual decision — API/UX breaks |
| Minor | New features | Manual decision — feature additions |
| ChangeCount | OpenSpec archived changes | Incremented by `/opsx:archive` |
| BuildIncrement | Build number | Auto-incremented by CI on each release |

### D3: Rolling Tags

| Tag | Points to | Updated when |
|-----|-----------|-------------|
| `stable` | Latest release on main | Every release push |
| `latest` | Most recent build | Every CI build |

Both are force-pushed (rolling). Version tags (`v0.0.0.1`) are immutable.

### D4: Cargo/Tauri Compatibility

Cargo requires semver. We use `Major.Minor.ChangeCount` for Cargo/Tauri (3 parts). The build increment only appears in git tags and release artifact names. A `scripts/bump-version.sh` script updates all version locations atomically.

## Risks / Trade-offs

**[4-part version non-standard]** → Mitigation: Git tags and release names use full 4 parts. Cargo/Tauri use standard 3-part semver derived from the first 3 components. No tooling breakage.

**[Rolling tag force-push]** → Mitigation: Only `stable` and `latest` are force-pushed. Version tags are never moved. CI uses specific version tags for reproducibility.
