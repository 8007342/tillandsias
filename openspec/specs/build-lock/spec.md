# build-lock Specification

## Purpose
TBD - created by archiving change init-prebuilt-images. Update Purpose after archive.
## Requirements
### Requirement: Build lock coordination
Image builds SHALL use a lock file to prevent duplicate concurrent builds.

#### Scenario: Acquire lock
- **WHEN** a build starts and no lock exists
- **THEN** a lock file is created at `$XDG_RUNTIME_DIR/tillandsias/build-forge.lock` with the current PID

#### Scenario: Wait for existing build
- **WHEN** a build is requested and a lock exists with a live PID
- **THEN** the requester polls every 2 seconds until the lock is released, then verifies the image exists

#### Scenario: Stale lock
- **WHEN** a build is requested and a lock exists but the PID is dead
- **THEN** the stale lock is replaced and the build proceeds

#### Scenario: Lock released on completion
- **WHEN** a build completes (success or failure)
- **THEN** the lock file is removed

