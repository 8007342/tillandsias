## ADDED Requirements

### Requirement: Declarative image definition via flake.nix
The default forge image SHALL be defined declaratively in flake.nix using Nix's dockerTools, replacing the Containerfile as the primary build path.

#### Scenario: Build forge image
- **WHEN** `scripts/build-image.sh forge` is run
- **THEN** the image is built via `nix build .#forge-image` inside the builder toolbox

#### Scenario: Build web image
- **WHEN** `scripts/build-image.sh web` is run
- **THEN** the image is built via `nix build .#web-image` inside the builder toolbox
