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

## Resolution

**Fixed** (commit 61b316c): Updated `scripts/verify-version-monotonic.sh` to strip the `+<hash>` suffix before parsing version components. 

The fix:
```bash
version="${version#v}"   # Remove 'v' prefix
version="${version%+*}"  # Remove '+hash' suffix (new: CalVer provenance)
```

This allows the script to handle both:
- Old format: `v0.1.184.561` (no hash)
- New format: `v0.1.260504.32+6e8fd78d` (with commit hash)

**Status**: All checks now pass (8/8). Version monotonicity is enforced correctly.

## Remaining Methodology Refinement Opportunities

1. **Release discipline documentation** — Create `cheatsheets/build/release-versioning.md` with:
   - CalVer format explanation
   - Commit hash provenance (why it's included)
   - When version bumping happens (build auto-increment vs manual bumps)
   - How monotonicity check works

2. **Gate CI on version check** — Currently blocks local push, should also be in CI/CD pipeline to prevent non-monotonic releases from reaching GitHub

3. **Document pre-flight validation** — When release workflows should validate version, when they should fail, what recovery looks like

## Observations for Release Discipline

This gap reveals that release discipline was never fully documented:
- **Version format**: Defined in methodology.yaml but not enforced by scripts
- **Commit provenance**: Documented (include hash) but check script doesn't validate it
- **Monotonicity validation**: Intended but implementation-broken
- **Pre-release gating**: Check exists but output is not actionable

The fix is straightforward, but the pattern (document > implement > validate) was incomplete.
