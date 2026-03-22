## ADDED Requirements

### Requirement: Builder toolbox with Nix
A dedicated `tillandsias-builder` toolbox SHALL be auto-created with Nix installed for building container images. No Nix on the host.

#### Scenario: First image build
- **WHEN** an image build is requested and no builder toolbox exists
- **THEN** the builder toolbox is created with Fedora Minimal + Nix, and the build proceeds

#### Scenario: Subsequent builds
- **WHEN** the builder toolbox already exists
- **THEN** the build runs immediately using the existing Nix store

### Requirement: Automatic staleness detection
Image builds SHALL automatically detect when inputs have changed and rebuild only when necessary.

#### Scenario: No changes
- **WHEN** flake.nix, flake.lock, and all image sources are unchanged since last build
- **THEN** the build completes in under 1 second (cache hit)

#### Scenario: Config file changed
- **WHEN** entrypoint.sh or opencode.json is modified
- **THEN** the next build automatically rebuilds the image with the new config

#### Scenario: Dependency update
- **WHEN** flake.lock is updated via `nix flake update`
- **THEN** the next build pulls new packages and rebuilds affected layers
