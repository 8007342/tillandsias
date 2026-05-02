<!-- @trace spec:versioning -->
# versioning Specification

## Purpose
TBD - created by archiving change version-scheme. Update Purpose after archive.
## Requirements
### Requirement: VERSION file as source of truth
The project SHALL maintain a `VERSION` file at the repository root containing the full 4-part version number (`Major.Minor.ChangeCount.BuildIncrement`).

#### Scenario: VERSION file exists
- **WHEN** the repository is cloned
- **THEN** a `VERSION` file exists at the root containing a valid 4-part version string

#### Scenario: VERSION file is authoritative
- **WHEN** a version is needed for any build artifact, tag, or release
- **THEN** it is derived from the `VERSION` file, not hardcoded elsewhere

### Requirement: Monotonic version increments
Every released version SHALL be strictly greater than all previous versions when compared component-by-component left to right.

#### Scenario: Build increment on release
- **WHEN** a new release is created
- **THEN** the BuildIncrement component is greater than the previous release

#### Scenario: ChangeCount on archive
- **WHEN** an OpenSpec change is archived via `/opsx:archive`
- **THEN** the ChangeCount component is incremented by 1 and BuildIncrement resets to 0

### Requirement: Cargo/Tauri semver derivation
Cargo.toml and tauri.conf.json SHALL use 3-part semver derived from the first 3 components of the VERSION file (`Major.Minor.ChangeCount`).

#### Scenario: Cargo version matches
- **WHEN** `VERSION` contains `0.1.3.7`
- **THEN** all Cargo.toml files contain `version = "0.1.3"`

#### Scenario: Tauri version matches
- **WHEN** `VERSION` contains `0.1.3.7`
- **THEN** `tauri.conf.json` contains `"version": "0.1.3"`

### Requirement: Immutable version tags
Git tags for specific versions (`v0.0.0.1`) SHALL be immutable and MUST NOT be force-pushed or deleted.

#### Scenario: Version tag created
- **WHEN** a release is published
- **THEN** a git tag `v<full-version>` is created and pushed

#### Scenario: Tag immutability
- **WHEN** a version tag already exists
- **THEN** the CI pipeline MUST NOT overwrite or delete it

### Requirement: Rolling stable and latest tags
The `stable` and `latest` git tags SHALL be rolling (force-pushed) to track the current stable release and latest build respectively.

#### Scenario: stable tag updated
- **WHEN** a release is published to main
- **THEN** the `stable` tag is force-pushed to point to the release commit

#### Scenario: latest tag updated
- **WHEN** any CI build completes successfully
- **THEN** the `latest` tag is force-pushed to point to the build commit

### Requirement: Automated version bump script
A `scripts/bump-version.sh` script SHALL atomically update all version locations (VERSION, Cargo.toml files, tauri.conf.json) from the VERSION file.

#### Scenario: Bump script updates all files
- **WHEN** `scripts/bump-version.sh` is run after modifying the VERSION file
- **THEN** all Cargo.toml `version` fields and tauri.conf.json `version` field are updated to match

#### Scenario: Bump script is idempotent
- **WHEN** the script is run twice with no VERSION change
- **THEN** no files are modified on the second run

