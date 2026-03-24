## Why
Build number resets to 0 on --bump-changes (v0.0.5.10 → v0.0.6.0). Should be monotonic (v0.0.5.10 → v0.0.6.11). Also CI/Release workflows trigger on every push/tag, flooding failed runs.

## What Changes
- bump-version.sh: build counter increments on --bump-changes instead of resetting
- CI workflow: manual trigger only (workflow_dispatch)
- Release workflow: manual trigger only until signing secrets configured

## Capabilities
### Modified Capabilities
- `versioning`: Build number never resets
- `ci-release`: Manual trigger only

## Impact
- scripts/bump-version.sh, .github/workflows/ci.yml, .github/workflows/release.yml
