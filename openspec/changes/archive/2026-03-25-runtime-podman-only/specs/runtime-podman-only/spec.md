# runtime-podman-only Specification

## Purpose
The runtime image build pipeline SHALL use only podman (no toolbox) so that the installed Tillandsias binary can build container images on any platform where podman is available.

## Requirements

### Requirement: Ephemeral build container via podman run
The `build-image.sh` script SHALL use `podman run --rm nixos/nix:latest` to execute `nix build` instead of `toolbox run -c tillandsias-builder`.

#### Scenario: First image build on a fresh system
- **WHEN** the user runs `tillandsias init` or triggers "Attach Here" and no forge image exists
- **THEN** `build-image.sh` runs `podman run --rm nixos/nix:latest` to build the image
- **AND** podman automatically pulls `nixos/nix:latest` if not already present
- **AND** the resulting tarball is loaded into podman via `podman load`
- **AND** the image is tagged as `tillandsias-forge:latest`

#### Scenario: Subsequent build with sources unchanged
- **WHEN** `build-image.sh` is called and the source hash matches the last build
- **AND** the image exists in podman
- **THEN** the script exits immediately without launching a container
- **AND** no `podman run` is invoked

#### Scenario: Force rebuild
- **WHEN** `build-image.sh` is called with `--force`
- **THEN** the staleness check is skipped
- **AND** `podman run --rm nixos/nix:latest` executes the nix build

### Requirement: Source files mounted read-only
The embedded source tree (flake.nix, flake.lock, images/) SHALL be mounted into the build container at `/src` with read-only permissions.

#### Scenario: Source directory contains flake.nix
- **WHEN** the build container starts
- **THEN** `/src/flake.nix` is readable inside the container
- **AND** `nix build /src#forge-image` can resolve the flake

### Requirement: Tarball extracted via output volume
The nix build tarball SHALL be copied to a host-mounted output volume, not piped through `toolbox run ... cat`.

#### Scenario: Successful nix build
- **WHEN** `nix build` completes and produces a tarball in `/nix/store/`
- **THEN** the tarball is copied to `/output/result.tar.gz` inside the container
- **AND** on the host, the file exists at `<cache_dir>/result.tar.gz`
- **AND** `podman load < <cache_dir>/result.tar.gz` succeeds

### Requirement: Flakes enabled explicitly
The `nix build` invocation SHALL pass `--extra-experimental-features "nix-command flakes"` to guarantee flake support regardless of the base image's Nix configuration.

#### Scenario: nixos/nix image without flakes in config
- **WHEN** the `nixos/nix:latest` image does not have flakes enabled by default
- **THEN** the CLI flag enables flakes for the build invocation
- **AND** the build succeeds

### Requirement: No toolbox dependency at runtime
The installed Tillandsias binary SHALL NOT invoke `toolbox` for any operation. Toolbox is permitted only in the development `build.sh` script.

#### Scenario: Running on Ubuntu
- **WHEN** a user installs Tillandsias on Ubuntu (no toolbox available)
- **THEN** `build-image.sh` succeeds using only `podman`
- **AND** no command fails with "toolbox: command not found"

#### Scenario: Running on macOS with podman machine
- **WHEN** a user installs Tillandsias on macOS with `podman machine` configured
- **THEN** `build-image.sh` succeeds using `podman run`

### Requirement: ensure-builder.sh removed
The `scripts/ensure-builder.sh` file SHALL be deleted and all references to it removed from the embedded binary and documentation.

#### Scenario: Embedded binary does not contain ensure-builder.sh
- **WHEN** the binary is compiled
- **THEN** `embedded.rs` does not include `ensure-builder.sh`
- **AND** `write_image_sources()` does not write an `ensure-builder.sh` file

### Requirement: Uninstall does not reference toolbox
The `scripts/uninstall.sh` SHALL NOT attempt to remove a builder toolbox, since none exists.

#### Scenario: Uninstall with --wipe
- **WHEN** the user runs `tillandsias-uninstall --wipe`
- **THEN** the script does not invoke `toolbox rm`
- **AND** the script completes successfully on systems without toolbox
