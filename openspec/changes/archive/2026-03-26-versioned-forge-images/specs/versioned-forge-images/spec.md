## NEW Requirements

### Requirement: Version-derived image tag
The forge image tag SHALL be derived from the application's semver version at compile time.

#### Scenario: Tag format
- **WHEN** the application version is `0.1.72`
- **THEN** the forge image tag is `tillandsias-forge:v0.1.72`

#### Scenario: Version source
- **WHEN** the binary is compiled
- **THEN** `CARGO_PKG_VERSION` provides the version string used in the tag

### Requirement: build-image.sh tag override
The build-image.sh script SHALL accept an optional `--tag <tag>` argument that overrides the default image tag.

#### Scenario: Tag argument provided
- **WHEN** `build-image.sh forge --tag tillandsias-forge:v0.1.72` is invoked
- **THEN** the built image is tagged as `tillandsias-forge:v0.1.72`

#### Scenario: No tag argument
- **WHEN** `build-image.sh forge` is invoked without `--tag`
- **THEN** the built image is tagged as `tillandsias-forge:latest` (backward compatible)

### Requirement: Old image pruning
After a successful versioned image build, older `tillandsias-forge:v*` images SHALL be removed.

#### Scenario: Update from older version
- **WHEN** `tillandsias-forge:v0.1.73` is built successfully
- **AND** `tillandsias-forge:v0.1.72` exists
- **THEN** `tillandsias-forge:v0.1.72` is removed

#### Scenario: No old images
- **WHEN** `tillandsias-forge:v0.1.73` is built successfully
- **AND** no other `tillandsias-forge:v*` images exist
- **THEN** no pruning occurs

#### Scenario: Pruning failure
- **WHEN** pruning an old image fails
- **THEN** the failure is logged but does not block operation

### Requirement: Launch-time update detection
The launch-time forge check SHALL distinguish between first-time builds and update builds.

#### Scenario: First-time build
- **WHEN** the versioned image does not exist
- **AND** no `tillandsias-forge:v*` images exist
- **THEN** the progress message is "Building Forge"

#### Scenario: Update build
- **WHEN** the versioned image does not exist
- **AND** at least one older `tillandsias-forge:v*` image exists
- **THEN** the progress message is "Building Updated Forge"

## MODIFIED Requirements

### Requirement: Build script invocation
All Rust code that invokes build-image.sh SHALL pass `--tag <versioned_tag>` so the image is tagged with the app version.

#### Scenario: Tray mode build
- **WHEN** the tray app triggers a forge build
- **THEN** `build-image.sh forge --tag tillandsias-forge:v<version>` is executed

#### Scenario: CLI mode build
- **WHEN** the CLI runner triggers a forge build
- **THEN** `build-image.sh forge --tag tillandsias-forge:v<version>` is executed

#### Scenario: Init mode build
- **WHEN** `tillandsias init` triggers a forge build
- **THEN** `build-image.sh forge --tag tillandsias-forge:v<version>` is executed

### Requirement: Image existence checks
All image existence checks SHALL use the versioned tag instead of `:latest`.

#### Scenario: Tray launch check
- **WHEN** the tray app checks for the forge image at startup
- **THEN** it checks for `tillandsias-forge:v<version>`

#### Scenario: Attach Here check
- **WHEN** the user clicks Attach Here
- **THEN** the image check uses `tillandsias-forge:v<version>`

#### Scenario: GitHub operations
- **WHEN** GitHub fetch_repos or clone_repo runs
- **THEN** the container uses `tillandsias-forge:v<version>`
