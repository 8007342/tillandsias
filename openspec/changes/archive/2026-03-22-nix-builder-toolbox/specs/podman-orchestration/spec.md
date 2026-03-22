## ADDED Requirements

### Requirement: Load nix-built image tarballs
The podman client SHALL support loading OCI image tarballs produced by Nix builds.

#### Scenario: Load tarball
- **WHEN** a Nix build produces a tarball
- **THEN** `podman load` imports it and the image is available locally
