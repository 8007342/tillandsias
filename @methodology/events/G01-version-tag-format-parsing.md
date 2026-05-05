---
event_id: G01
title: Version Tag Format Parsing Gap
date: 2026-05-04
severity: medium
---

# Gap: Version Tag Format Parsing — Documented vs Actual

## What Happened

Release workflow for `v0.1.260504.32` succeeded but the post-release version monotonicity check failed with:

```
ERROR: Failed to parse latest tag 'v0.1.260504.32+6e8fd78d'
```

The check script could not parse the tag format that the release workflow generated.

## Context

- **User action**: Triggered release to fix broken download links in README.md
- **Workflow**: GitHub Actions release.yml created tag `v0.1.260504.32+6e8fd78d` (includes commit hash)
- **Monotonicity check**: Pre-push validation expects to compare versions but failed on parsing
- **Implication**: Release succeeded (tag created, assets published) but CI check failed

## Root Cause: Format Mismatch

### Documented Format (methodology.yaml)

```
v<Major>.<Minor>.<YYMMDD>.<Build>+<CommitHash>
```

Example: `v0.1.260504.32+6e8fd78d`

This is CalVer with monotonic build number and commit provenance.

### Actual Implementation (release.yml)

Tag is created with `+<CommitHash>` suffix, as documented.

### The Script (version-check)

The script that validates monotonicity does not parse the `+<hash>` suffix. It fails immediately on parsing, unable to extract Major/Minor/YYMMDD/Build components.

### Historical Context

Older tags in the repository follow the format:
- `v0.1.184.561` (no `+hash` suffix)
- `v0.1.184.559` (no `+hash` suffix)

These were created before the CalVer+hash format was standardized. The version check script was written to handle this old format and does not account for the new suffix.

## The Gap

| Aspect | Documented | Actual | Issue |
|--------|-----------|--------|-------|
| Tag format | `v<M>.<m>.<YYMMDD>.<B>+<hash>` | Created correctly with hash | ✓ OK |
| Release workflow | Append commit hash to tag | Doing this | ✓ OK |
| Version check script | Parse +hash suffix, compare versions | Does not parse +hash suffix | ❌ **BROKEN** |
| Historical compatibility | Support old format without hash | Script only handles old format | ❌ **Blocks new format** |

## Why This Matters

The version check is a gating pre-push validation. It's supposed to prevent:
- Releasing with a version that's not monotonically greater than the last release
- Accidental version decrements (e.g., bumping build number but forgetting Major/Minor)

But the check is currently **broken for the documented format**, so:
1. Releases succeed but the check shows red
2. Users don't know if version monotonicity is actually correct
3. The gap between "what we document" and "what we enforce" is invisible

## Next Steps for Methodology Refinement

1. **Update version-check script** to parse `v<M>.<m>.<YYMMDD>.<B>+<hash>` format
2. **Support dual format** during transition period (old tags without hash, new tags with hash)
3. **Document the check's behavior** in cheatsheets/release-discipline (e.g., `cheatsheets/build/release-versioning.md`)
4. **Add to CI** so version-check is run and reported (currently blocks push but doesn't gate CI)

## Observations for Release Discipline

This gap reveals that release discipline was never fully documented:
- **Version format**: Defined in methodology.yaml but not enforced by scripts
- **Commit provenance**: Documented (include hash) but check script doesn't validate it
- **Monotonicity validation**: Intended but implementation-broken
- **Pre-release gating**: Check exists but output is not actionable

The fix is straightforward, but the pattern (document > implement > validate) was incomplete.
