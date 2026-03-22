## 1. Version Source of Truth

- [x] 1.1 Create `VERSION` file at project root with initial content `0.0.0.1`
- [x] 1.2 Update all `Cargo.toml` version fields to match first 3 components of VERSION (`0.0.0`)
- [x] 1.3 Update `tauri.conf.json` version to match first 3 components of VERSION (`0.0.0`)

## 2. Version Bump Script

- [x] 2.1 Create `scripts/bump-version.sh` that reads VERSION file and updates all Cargo.toml and tauri.conf.json version fields
- [x] 2.2 Add `--bump-build` flag that increments the 4th component
- [x] 2.3 Add `--bump-changes` flag that increments the 3rd component and resets 4th to 0
- [x] 2.4 Make script idempotent — running twice with no VERSION change produces no diff
- [x] 2.5 Test: verify script updates all 4 Cargo.toml files and tauri.conf.json

## 3. CI Integration

- [x] 3.1 Update `.github/workflows/release.yml` to read version from VERSION file
- [x] 3.2 Add step to validate git tag matches VERSION file content
- [x] 3.3 Add step to force-push `stable` tag to release commit
- [x] 3.4 Add step to force-push `latest` tag to build commit
- [x] 3.5 Ensure version tags (`v*`) are never overwritten (immutable, CI only creates new ones)

## 4. Documentation

- [x] 4.1 Document version scheme in README.md (version format, when each component bumps)
- [x] 4.2 Document `scripts/bump-version.sh` usage in CLAUDE.md
- [x] 4.3 Add version scheme section to CONTRIBUTING guidelines (documented in CLAUDE.md)
