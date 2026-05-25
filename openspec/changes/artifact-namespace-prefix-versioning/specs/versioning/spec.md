## ADDED Requirements

### Requirement: Artifact namespace prefix for host-shell variants

The version string SHALL begin with a single-letter prefix denoting the artifact's host-shell context. The prefix replaces the leading `v` of the existing four-positional CalVer format `<prefix><Major>.<Minor>.<YYMMDD>.<Build>+<CommitHash>`.

The closed vocabulary of prefixes SHALL be:
- `v` — Linux tillandsias (the canonical artifact; default when no prefix is specified).
- `m` — macOS tray (`tillandsias-macos-tray` → `tillandsias-tray.app`).
- `w` — Windows tray (`tillandsias-windows-tray` → `tillandsias-tray.exe`).

Extensions to the vocabulary SHALL require a methodology refinement landed via `linux-next` per the invariant `methodology_refinements_do_not_push_directly_to_main`.

The prefix is a label of artifact namespace; it is NOT a positional version component. Version comparison SHALL be performed on the four positional components (`Major.Minor.YYMMDD.Build`) and SHALL ignore the prefix.

@trace spec:versioning

#### Scenario: Linux artifact carries the default `v` prefix
- **WHEN** the Linux tillandsias binary is released
- **THEN** its embedded version SHALL begin with `v` (e.g. `v0.2.260523.6+abcd123`)
- **AND** the git tag SHALL be `v<Major>.<Minor>.<YYMMDD>.<Build>` (unchanged from current behavior)

#### Scenario: macOS tray artifact carries the `m` prefix
- **WHEN** `tillandsias-tray.app` is built by the macOS release pipeline
- **THEN** its embedded `CFBundleShortVersionString` and the `Info.plist` build metadata SHALL begin with `m`
- **AND** the artifact filename SHALL include the prefixed version (e.g. `tillandsias-tray-m0.2.260523.6.app.tar.gz`)

#### Scenario: Windows tray artifact carries the `w` prefix
- **WHEN** `tillandsias-tray.exe` is built by the Windows release pipeline
- **THEN** its embedded `FileVersion` resource SHALL begin with `w`
- **AND** the artifact filename SHALL include the prefixed version (e.g. `tillandsias-tray-w0.2.260523.6.exe`)

#### Scenario: Unknown prefix is rejected
- **WHEN** `scripts/verify-version-monotonic.sh` is invoked on a version string whose leading character is not `v`, `m`, or `w`
- **THEN** the script SHALL exit non-zero with the message `unknown artifact namespace prefix; expected one of: v m w`

#### Scenario: Version comparison ignores prefix
- **WHEN** two version strings `m0.2.260523.6` and `v0.2.260523.6` are compared
- **THEN** the comparison SHALL report them as equal in the four-positional component sense (same release tuple)
- **AND** when sorted by version, all artifacts of the same release SHALL group together regardless of prefix

### Requirement: Release parity across host-shell variants

For every release that publishes more than one host-shell artifact, all published variants SHALL share identical `Major.Minor.YYMMDD.Build`. The CommitHash component MAY differ (different host code on different commits) but the four leading positional components MUST be byte-equal.

A new script `scripts/verify-release-parity.sh <tag>` SHALL fetch the artifacts associated with `<tag>`, extract their embedded versions, and verify the parity contract. The CI release workflow SHALL invoke this script after all host pipelines complete and before the release is marked stable. A failure SHALL block the release.

@trace spec:versioning

#### Scenario: Parity-check passes when all variants align
- **WHEN** the release pipeline has produced `v0.2.260523.6+aaa`, `m0.2.260523.6+bbb`, `w0.2.260523.6+ccc`
- **AND** `scripts/verify-release-parity.sh` is run against the tag
- **THEN** it SHALL exit zero

#### Scenario: Parity-check fails on Major.Minor.YYMMDD.Build drift
- **WHEN** the macOS pipeline produced `m0.2.260523.7` while the Linux pipeline produced `v0.2.260523.6`
- **AND** `scripts/verify-release-parity.sh` is run against the tag
- **THEN** it SHALL exit non-zero with a diagnostic naming the diverging variants and their version values
- **AND** the CI release workflow SHALL mark the release blocked, not stable

#### Scenario: Single-variant release is permitted (Linux-only legacy)
- **WHEN** a tagged release contains only the Linux artifact (no macOS or Windows variant uploaded)
- **THEN** the parity check SHALL pass vacuously (one artifact has trivial parity with itself)
- **AND** no diagnostic SHALL be emitted

### Requirement: `bump-version.sh` accepts `--prefix=v|m|w`

The version-bump script `scripts/bump-version.sh` SHALL accept an optional `--prefix=<v|m|w>` flag (default `v`) that determines which prefix the emitted version string carries. The script SHALL reject any other value with a usage message.

@trace spec:versioning

#### Scenario: Default prefix is `v`
- **WHEN** `scripts/bump-version.sh` is invoked with no `--prefix` flag
- **THEN** the emitted version string SHALL begin with `v`

#### Scenario: macOS build pipeline stamps `m`
- **WHEN** the macOS tray build invokes `scripts/bump-version.sh --prefix=m`
- **THEN** the emitted version string SHALL begin with `m`
- **AND** the `VERSION` file's four positional components SHALL be unchanged (the prefix is a presentation layer, not stored in `VERSION`)

#### Scenario: Invalid prefix rejected
- **WHEN** `scripts/bump-version.sh --prefix=q` is invoked
- **THEN** the script SHALL exit non-zero with `unknown prefix 'q'; valid prefixes: v m w`

### Requirement: `version-history.jsonl` records prefix separately

The append-only audit log `version-history.jsonl` SHALL gain a `"prefix"` string field on each entry. The existing `"version"` field SHALL continue to hold only the four positional components plus the commit hash, with NO prefix character. Existing `jq` queries on `version` SHALL continue to function unchanged.

@trace spec:versioning

#### Scenario: New entry includes prefix field
- **WHEN** a release is recorded for `m0.2.260523.6+abcd123`
- **THEN** the appended JSONL entry SHALL contain `"version": "0.2.260523.6+abcd123"` (no leading character)
- **AND** SHALL contain `"prefix": "m"`

#### Scenario: Existing entries remain valid
- **WHEN** old entries written before this change are read
- **THEN** they SHALL still parse as valid JSONL
- **AND** the absence of the `"prefix"` field SHALL be interpreted as the default `"v"` by consuming queries
