## ADDED Requirements

### Requirement: Git-tracked files for flake builds
Nix flake builds SHALL only see files that are tracked by git. New or untracked files MUST be staged with `git add` before running a flake build, or the build will silently exclude them.

#### Scenario: Untracked file excluded from build
- **WHEN** a new file is added to the `images/` directory but not staged with `git add`
- **THEN** the Nix flake build does not include that file, potentially producing an incorrect image

#### Scenario: Staged file included in build
- **WHEN** a new file is added to the `images/` directory and staged with `git add`
- **THEN** the Nix flake build includes the file and produces the correct image

#### Scenario: Build script handles tracking
- **WHEN** `build-image.sh` detects source changes via hashing
- **THEN** the staleness check operates on the working tree, but the Nix build only sees git-tracked files — these can diverge if files are not staged

### Requirement: Preferred dockerTools API usage
The flake.nix image definitions SHALL use `copyToRoot` instead of the legacy `contents` attribute in `dockerTools.buildLayeredImage`.

#### Scenario: Image definition uses copyToRoot
- **WHEN** an image is defined in `flake.nix` using `dockerTools.buildLayeredImage`
- **THEN** the `copyToRoot` attribute is used to specify packages to include. The `contents` attribute is a legacy alias that still works but is deprecated in favor of `copyToRoot`.
