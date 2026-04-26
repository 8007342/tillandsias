# appimage-build-pipeline Specification

## Purpose
TBD - created by archiving change appimage-builder-source-slim. Update Purpose after archive.
## Requirements
### Requirement: Source copy into the AppImage builder SHALL exclude artefact directories

The host-to-builder source copy step in `build.sh --install` SHALL omit
all directories that are not consumed by the in-builder `cargo tauri
build` invocation. The exclude list MUST include at minimum:
`./target`, `./.git`, `./.nix-output`, `./.claude`, `./.opencode`,
`./node_modules`, and `./*.AppImage`. The script SHALL declare the
exclude list ONCE in a single bash array (`BUILDER_COPY_EXCLUDES`) and
reuse it for every consumer of the list.

#### Scenario: 47 GB target/ does not get copied

- **WHEN** `./build.sh --install` runs against a workspace whose
  `target/` is multi-gigabyte
- **THEN** the in-container `/build` directory is populated WITHOUT a
  `target/` subdirectory
- **AND** the wall-clock time of the source-copy step is under 30 seconds
  on a developer workstation with NVMe storage

#### Scenario: .git is not copied

- **WHEN** the source copy completes
- **THEN** `/build/.git` does not exist
- **AND** the build proceeds (cargo does not require .git)

### Requirement: Source copy size SHALL be capped at 150 MB

Immediately after the source-copy step, the script SHALL measure the
size of the copied tree and abort the build if it exceeds 150 MB
(157 286 400 bytes). The error message SHALL identify the three largest
top-level directories so the offender is obvious.

#### Scenario: Tree under 150 MB proceeds

- **GIVEN** the workspace source (excluding artefact directories) is 17 MB
- **WHEN** `./build.sh --install` runs
- **THEN** the size check passes silently and the cargo build proceeds

#### Scenario: Tree over 150 MB aborts with a helpful error

- **GIVEN** someone has committed a 200 MB binary blob to the workspace
- **WHEN** `./build.sh --install` runs
- **THEN** the script aborts with exit code != 0 BEFORE invoking cargo
- **AND** the error names the top-3 largest top-level dirs in `/build`
- **AND** the error mentions the 150 MB cap and the spec name

### Requirement: Source copy SHALL use a builder-image-default tool

The copy mechanism SHALL rely only on tools present in the upstream
`ubuntu:22.04` image without additional `apt-get install` steps. `tar`
satisfies this; `rsync` does not (would require an install step that
costs cold-cache wall-clock time and a network fetch). The script
SHALL use a `tar … --exclude=… -cf - | tar -xf -` pipe so the source
bytes stream from reader to writer in a single pass.

#### Scenario: rsync is not invoked

- **WHEN** the source-copy step runs in a freshly-pulled `ubuntu:22.04`
  container with no extra packages
- **THEN** the step succeeds without `apt-get install rsync`

