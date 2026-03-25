## NEW Requirements

### Requirement: Silverblue install instructions in README

The README SHALL include Fedora Silverblue instructions alongside the existing Fedora COPR section.

#### Scenario: User reads install instructions on Silverblue
- **GIVEN** a user on Fedora Silverblue reading the README
- **WHEN** they expand "Other ways to install" under Linux
- **THEN** they see a "Fedora Silverblue (COPR — auto-updates)" section
- **AND** it shows: curl the .repo file, rpm-ostree install, reboot

### Requirement: Silverblue update instructions

The UPDATING.md SHALL document how layered RPMs auto-update on Silverblue.

#### Scenario: User checks how updates work on Silverblue
- **GIVEN** a user who installed via rpm-ostree on Silverblue
- **WHEN** they read docs/UPDATING.md
- **THEN** they see that rpm-ostree upgrade picks up new versions from COPR
- **AND** they understand a reboot applies the update
