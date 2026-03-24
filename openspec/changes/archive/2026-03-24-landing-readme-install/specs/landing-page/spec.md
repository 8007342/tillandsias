## NEW Requirements

### Requirement: Landing page README

The project README.md SHALL serve as a concise landing page focused on installation and usage.

#### Scenario: First-screen content
- **WHEN** a visitor opens the GitHub repository page
- **THEN** they see a tagline, install commands, and run instructions without scrolling past architecture details

#### Scenario: Install instructions
- **WHEN** the visitor reads the Install section
- **THEN** they find a single curl command for Linux, a single curl command for macOS, and a PowerShell command for Windows

#### Scenario: Uninstall instructions
- **WHEN** the visitor reads the Uninstall section
- **THEN** they find `tillandsias-uninstall` for standard removal and `tillandsias-uninstall --wipe` for full cleanup

#### Scenario: Architecture link
- **WHEN** the visitor wants deeper documentation
- **THEN** the README links to README-ABOUT.md under a "Learn More" section

### Requirement: Install script

The install script SHALL download the correct platform binary and install it to `~/.local/bin`.

#### Scenario: OS and architecture detection
- **GIVEN** the script runs on a supported OS (linux, darwin) and architecture (x86_64, aarch64)
- **THEN** it downloads the matching binary from GitHub Releases

#### Scenario: Unsupported platform
- **GIVEN** the script runs on an unsupported OS or architecture
- **THEN** it exits with a clear error message

#### Scenario: Download failure
- **GIVEN** the GitHub Release does not yet exist
- **THEN** the script prints a fallback message with build-from-source instructions

### Requirement: Uninstall script

The uninstall script SHALL remove Tillandsias binaries and optionally all data.

#### Scenario: Standard uninstall
- **WHEN** `tillandsias-uninstall` is run without flags
- **THEN** it removes the binary, libraries, and data directories but preserves cache

#### Scenario: Wipe uninstall
- **WHEN** `tillandsias-uninstall --wipe` is run
- **THEN** it removes the binary, libraries, data, cache, container images, and builder toolbox
