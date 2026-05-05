# default-image Specification (Delta)

@trace spec:default-image, spec:forge-nix-toolchain

## ADDED Requirements

### Requirement: Nix installed with flakes enabled

The forge image SHALL include nix installed in single-user mode with experimental features (`nix-command`, `flakes`) enabled in `/etc/nix/nix.conf`. The nix binary SHALL be on PATH and available to all users.

#### Scenario: Nix is available
- **WHEN** a container starts with the updated forge image
- **THEN** `nix --version` outputs a valid version string

#### Scenario: Flakes work without warnings
- **WHEN** a user runs `nix flake show <path>`
- **THEN** the command succeeds without experimental feature warnings

### Requirement: /etc/nix/nix.conf includes experimental features

The forge image configuration file at `/etc/nix/nix.conf` SHALL include the line `experimental-features = nix-command flakes`.

#### Scenario: Configuration is readable
- **WHEN** a user runs `cat /etc/nix/nix.conf`
- **THEN** the output includes `experimental-features = nix-command flakes`

### Requirement: Image grows ~50 MB due to nix layer

The forge image size SHALL increase by approximately 50 MB compared to the previous version due to the nix toolchain and dependencies.

#### Scenario: Image size is reasonable
- **WHEN** the image is built
- **THEN** the image size is approximately 10-15% larger than the baseline (expected ~50 MB additional)

