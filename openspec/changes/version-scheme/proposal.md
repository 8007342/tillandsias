## Why

The project needs a versioning scheme that is monotonically increasing, tied to the spec-driven development workflow, and supports rolling release tags for container images and binary distribution. Standard semver alone doesn't capture the relationship between OpenSpec changes and build iterations.

## What Changes

- Establish 4-part version format: `v<Major>.<Minor>.<OpenSpecChangeCount>.<BuildIncrement>`
- Configure version sources across Cargo.toml, tauri.conf.json, and CI workflows
- Add `stable` and `latest` rolling git tags updated on each release
- Automate version bumping in the release pipeline
- Document the versioning convention for contributors

## Capabilities

### New Capabilities
- `versioning`: 4-part version scheme with automated bumping, rolling tags, and CI integration

### Modified Capabilities
- `ci-release`: Release workflow must bump build number and update rolling tags

## Impact

- All Cargo.toml files use 3-part semver (`Major.Minor.ChangeCount`) since Cargo requires semver
- tauri.conf.json uses 3-part semver for Tauri compatibility
- Git tags use full 4-part format (`v0.0.0.1`)
- Rolling tags `stable` and `latest` point to head of main and latest build respectively
- CI release workflow auto-increments build number on tag push
