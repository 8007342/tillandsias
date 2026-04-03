## MODIFIED Requirements

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
