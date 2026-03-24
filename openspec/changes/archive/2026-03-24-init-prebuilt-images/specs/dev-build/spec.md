## ADDED Requirements

### Requirement: Installer triggers init
The installer script SHALL run `tillandsias init` as a background task after installation.

#### Scenario: Fresh install
- **WHEN** `install.sh` completes the binary installation
- **THEN** `tillandsias init` is spawned as a background process
- **AND** the installer prints a message indicating images are building in the background
