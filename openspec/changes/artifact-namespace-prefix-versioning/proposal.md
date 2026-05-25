## Why

Tillandsias now ships three host-shell artifacts that are binary-locked to the same Linux tillandsias version: the canonical Linux binary, the macOS tray (`tillandsias-macos-tray` → `tillandsias-tray.app`), and the Windows tray (`tillandsias-windows-tray` → `tillandsias-tray.exe`). All three speak the same vsock control wire and materialize the same VM rootfs recipe, so they MUST release as a versioned set. Today the version string `v0.2.260523.6+abcd123` does not declare which host context the artifact was built for, and CI does not enforce that all three variants of a release carry the same `Major.Minor.YYMMDD.Build`. The result is opaque release artifacts and no machine-checkable parity contract.

## What Changes

- **ADDED** `artifact_namespace_prefix` section to `methodology/versioning.yaml` defining the prefix vocabulary: `v` (Linux tillandsias, canonical), `m` (macOS tray), `w` (Windows tray). The prefix replaces the leading `v` of the version string.
- **ADDED** parity contract: all three variants of the same logical release SHALL share identical `Major.Minor.YYMMDD.Build`. Hash component MAY differ (different commits build different host code) but the four leading components MUST be equal.
- **MODIFIED** `scripts/bump-version.sh` to accept `--prefix=v|m|w` (default `v`); emits artifact-stamped versions used by each host build pipeline.
- **MODIFIED** `scripts/verify-version-monotonic.sh` to validate any of `v|m|w` as a valid leading character.
- **ADDED** `scripts/verify-release-parity.sh` — given a release tag, fetches the three variant artifacts and verifies their embedded versions share the leading four components.
- **ADDED** CI `release-parity-check` job that runs `verify-release-parity.sh` after the macOS and Windows builds complete and before the release is marked stable.
- **MODIFIED** `openspec/specs/versioning/spec.md` (delta) to add the namespace-prefix requirement and parity scenario.

No breaking change: existing `v`-prefixed tags continue to work unchanged. The macOS and Windows tray binaries are new (Phase 4/5) — they have no installed base, so adopting `m`/`w` prefixes on their first release is free.

## Capabilities

### New Capabilities

(none — this refines an existing capability)

### Modified Capabilities

- `versioning`: add requirements for the `v|m|w` artifact namespace prefix and cross-host release parity contract.

## Impact

- **Methodology authority file**: `methodology/versioning.yaml` gains the new section. Per the invariant `methodology_refinements_do_not_push_directly_to_main`, lands on `linux-next` via PR.
- **Build scripts**: `scripts/bump-version.sh`, `scripts/verify-version-monotonic.sh` get small extensions; new `scripts/verify-release-parity.sh`.
- **CI**: new `release-parity-check` job in `.github/workflows/release.yml`.
- **Affected specs**: `openspec/specs/versioning` (delta), cross-references in `openspec/specs/macos-native-tray`, `openspec/specs/windows-native-tray`.
- **Affected crates**: `tillandsias-macos-tray`, `tillandsias-windows-tray` build scripts will stamp the prefixed version into their binary metadata.
- **No runtime impact**: existing running tillandsias instances are unaffected. Pure release-engineering change.
