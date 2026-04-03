# nix-builder Specification

## Purpose
TBD - created by archiving change nix-builder-toolbox. Update Purpose after archive.
## Requirements
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

### Requirement: Git-tracked files for flake builds
Nix flake builds SHALL only see files that are tracked by git. The staleness check in `build-image.sh` SHALL use `git ls-files` to enumerate source files, ensuring the staleness hash covers exactly the same files that Nix will build.

#### Scenario: Staleness check matches Nix view
- **WHEN** `build-image.sh` computes a staleness hash for image sources
- **THEN** it SHALL use `git ls-files` to enumerate files in `images/default/` and `images/web/`
- **AND** the hash SHALL cover exactly the same files that Nix will include in the build

#### Scenario: Untracked file detected in image sources
- **WHEN** untracked files exist in `images/default/` or `images/web/` directories
- **THEN** `build-image.sh` SHALL fail with a clear error listing the untracked files and instructing the developer to run `git add`

#### Scenario: Staged file included in build
- **WHEN** a new file is added to the `images/` directory and staged with `git add`
- **THEN** both the staleness check and the Nix flake build SHALL include that file

#### Scenario: Non-git environment fallback
- **WHEN** `build-image.sh` runs outside a git repository (e.g., from a source tarball)
- **THEN** the staleness check SHALL fall back to `find`-based enumeration with a warning that untracked file detection is unavailable

### Requirement: Preferred dockerTools API usage
The flake.nix image definitions SHALL use `copyToRoot` instead of the legacy `contents` attribute in `dockerTools.buildLayeredImage`.

#### Scenario: Image definition uses copyToRoot
- **WHEN** an image is defined in `flake.nix` using `dockerTools.buildLayeredImage`
- **THEN** the `copyToRoot` attribute is used to specify packages to include. The `contents` attribute is a legacy alias that still works but is deprecated in favor of `copyToRoot`.

