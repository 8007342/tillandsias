## ADDED Requirements

### Requirement: Disk usage report
The binary SHALL support a `--stats` flag that prints a human-readable disk usage report to stdout and exits with code 0.

#### Scenario: Image list
- **WHEN** `tillandsias --stats` is run
- **THEN** each podman image whose repository name contains `tillandsias` or `macuahuitl` is listed with its tag and size

#### Scenario: Container list
- **WHEN** `tillandsias --stats` is run
- **THEN** each podman container whose name starts with `tillandsias-` is listed with its status (running/stopped)

#### Scenario: Cache sizes
- **WHEN** `tillandsias --stats` is run
- **THEN** the sizes of `~/.cache/tillandsias/nix/`, `~/.cache/tillandsias/cargo-registry/`, and the installed binary (`~/.local/bin/.tillandsias-bin`) are shown when those paths exist

#### Scenario: Total
- **WHEN** `tillandsias --stats` is run
- **THEN** a total disk usage line is printed at the end

#### Scenario: Podman unavailable
- **WHEN** `tillandsias --stats` is run and podman is not in PATH
- **THEN** the image and container sections are skipped with a note, other sections are still shown

---

### Requirement: Artifact cleanup
The binary SHALL support a `--clean` flag that removes stale Tillandsias artifacts and exits with code 0.

#### Scenario: Dangling image removal
- **WHEN** `tillandsias --clean` is run
- **THEN** `podman image prune -f` is executed and the number of images pruned (if any) is reported

#### Scenario: Stopped container removal
- **WHEN** `tillandsias --clean` is run
- **THEN** all podman containers whose name starts with `tillandsias-` and whose status is exited/stopped are removed and reported

#### Scenario: Nix cache removal
- **WHEN** `tillandsias --clean` is run and `~/.cache/tillandsias/nix/` exists
- **THEN** that directory is removed and the reclaimed size is reported

#### Scenario: Space summary
- **WHEN** `tillandsias --clean` completes
- **THEN** a summary of what was cleaned is printed

#### Scenario: Nothing to clean
- **WHEN** `tillandsias --clean` is run and no stale artifacts exist
- **THEN** "Nothing to clean." is printed and exit code is 0

---

### Requirement: Build-time image prune
The `build.sh` script SHALL run `podman image prune -f` after every successful build to prevent dangling layer accumulation.

#### Scenario: Debug build prune
- **WHEN** `./build.sh` (debug build) succeeds
- **THEN** `podman image prune -f` is executed automatically

#### Scenario: Release build prune
- **WHEN** `./build.sh --release` succeeds
- **THEN** `podman image prune -f` is executed automatically
