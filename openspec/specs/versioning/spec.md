<!-- @trace spec:versioning -->
<!-- # freshness: auditor=linux-macuahuitl-fable5-20260831 date=2026-08-31 verdict=rewritten scope=operator ruling — epoch-anchored scheme replaces Major.Minor.YYMMDD.Build; milestone decoupled into the plan ledger; stale tauri.conf.json references removed (no such file ships) -->
# versioning Specification

## Status

status: active

## Purpose

Define the artifact version scheme and its single source of truth. The scheme
is epoch-anchored CalVer (operator ruling 2026-08-31): versions encode WHEN an
artifact was built, never WHAT milestone it contains — milestone membership
lives in the plan ledger (`desired_release` ordered buckets) and the README
release row's milestone clause.

## Requirements

### Requirement: Epoch-anchored version scheme
The full version SHALL be four dot-separated decimal fields:
`<years_since_epoch>.<month>.<day>.<build>` — UTC year minus 1970, UTC month
and day without zero padding, and a build counter (e.g. 2026-08-31 daily
build 5 is `56.8.31.5`). The first field MUST never be 0 and MUST be at most
65535 (the Microsoft Store's per-field cap; it overflows in the year 67505).
The fourth field `0` is reserved for DURABLE builds (the Store requires
field four to be 0, and the constraint carries that meaning); local daily
bumps always produce a build of at least 1.

#### Scenario: Daily bump encodes today
- **WHEN** `scripts/bump-version.sh --bump-build` runs on a new UTC day
- **THEN** VERSION becomes `<year-1970>.<month>.<day>.1` for the current UTC date

#### Scenario: Legacy version migrates
- **WHEN** the bump runs against a legacy `0.x.YYMMDD.N` VERSION
- **THEN** it migrates to the epoch-anchored encoding of today with build 1, announcing the migration

#### Scenario: Cutover ordering is structural
- **WHEN** an epoch-anchored tag is compared with any legacy `v0.x.*` tag
- **THEN** every comparator (field-wise compare, `sort -V`, git version sort) orders it later, because field one resolves the comparison (56 > 0) before any field that could invert

### Requirement: VERSION file as source of truth
The project SHALL maintain a `VERSION` file at the repository root containing
the full 4-part version. Every build artifact, tag, and release derives its
version from this file — including per-store derivations (the MSIX manifest
uses the same four fields with field four forced to 0 for Store submissions),
never from the wall clock, so rebuilding an old tag reproduces that tag's
version.

#### Scenario: VERSION file is authoritative
- **WHEN** a version is needed for any build artifact, tag, or release
- **THEN** it is derived from the `VERSION` file, not hardcoded elsewhere

### Requirement: Monotonic version increments
Every released version SHALL be strictly greater than all previous versions
when compared component-by-component left to right, enforced by
`scripts/verify-version-monotonic.sh` against tags reachable from HEAD.

#### Scenario: Build increment on release
- **WHEN** a new release is created
- **THEN** its version compares strictly greater than the newest reachable release tag

### Requirement: Milestones are decoupled from versions
The version SHALL carry no milestone or minor field. Release milestones live
in the plan ledger's `desired_release` values, which are ORDERED PLANNING
BUCKETS (the historical tokens `v0.4`…`v0.8` remain valid bucket labels and
order as milestones 4…8), and each published release's README ledger row
SHALL open its INTENDED FEATURES cell with a `milestone:` clause naming the
milestone(s) the release advances — the row answers WHAT, the version answers
WHEN.

#### Scenario: A packet's bucket survives the cutover
- **WHEN** a packet carries `desired_release: v0.5`
- **THEN** it remains in the fifth ordered milestone bucket with no repointing, regardless of artifact version shape

### Requirement: Cargo semver derivation
Cargo.toml files SHALL use 3-part semver equal to the first three fields of
VERSION verbatim (`years.month.day`, e.g. `56.8.31`), which is numerically
monotonic and greater than every legacy `0.x.*` crate version at the major
field.

#### Scenario: Cargo version matches
- **WHEN** `VERSION` contains `56.8.31.5`
- **THEN** all workspace Cargo.toml files contain `version = "56.8.31"`

### Requirement: Immutable version tags
Git tags for specific versions (`v56.8.31.5`) SHALL be immutable and MUST NOT
be force-pushed or deleted. Legacy `v0.x.*` tags remain in history unchanged;
the cutover requires no tag rewrite.

#### Scenario: Tag immutability
- **WHEN** a version tag already exists
- **THEN** the CI pipeline MUST NOT overwrite or delete it

### Requirement: Rolling channel tags
The `unstable` rolling tag SHALL be force-pushed by the release workflow to
track the newest daily; stable channel resolution uses the newest
non-prerelease release. Channel resolution survives the scheme cutover
because every epoch-anchored tag sorts after every legacy tag.

#### Scenario: unstable tag updated
- **WHEN** a daily release is published
- **THEN** the `unstable` tag points at it and `/releases/download/unstable/<asset>` serves its assets

### Requirement: Automated version bump script
`scripts/bump-version.sh` SHALL atomically update all version locations
(VERSION, workspace Cargo.toml files) and SHALL refuse retired operations
loudly (`--bump-minor` names where milestones now live). Same-day re-syncs
MUST NOT rewrite byte-identical files (mtime feeds staleness probes).

#### Scenario: Bump script is idempotent
- **WHEN** the script is run twice with no VERSION change
- **THEN** no files are modified on the second run

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — version monotonicity, tag immutability, semver parity

Gating points:
- VERSION file exists at repo root with a valid epoch-anchored 4-part version
- VERSION is the source of truth; all artifacts derive from it
- Version increments are strictly monotonic (left-to-right component comparison), including across the 2026-08-31 scheme cutover
- Field one never 0 and ≤ 65535; field four 0 reserved for durable builds
- Cargo.toml uses the first three fields verbatim as semver
- Version-specific tags are immutable; legacy v0.x.* tags untouched
- bump-version.sh is idempotent, migrates legacy versions, and refuses --bump-minor loudly

## Sources of Truth

- `scripts/bump-version.sh` — the scheme's executable definition
- `scripts/verify-version-monotonic.sh` — the monotonicity enforcement
- `methodology/multi-host-development.yaml` — loop cadence and release coordination

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:versioning" scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
