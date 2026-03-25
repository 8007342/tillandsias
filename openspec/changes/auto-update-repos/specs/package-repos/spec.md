## ADDED Requirements

### Requirement: RPM repository via COPR
The project SHALL maintain a COPR repository that distributes RPM packages with automatic updates.

#### Scenario: User installs via COPR
- **WHEN** a Fedora user runs `sudo dnf copr enable 8007342/tillandsias && sudo dnf install tillandsias`
- **THEN** the latest RPM is installed from the COPR repository

#### Scenario: Automatic RPM update
- **WHEN** a new release is published on GitHub
- **THEN** the COPR repository is updated and `dnf update tillandsias` installs the new version

### Requirement: APT repository via GitHub Pages
The project SHALL maintain a GPG-signed APT repository hosted on GitHub Pages for Debian/Ubuntu users.

#### Scenario: User adds APT source
- **WHEN** a Debian/Ubuntu user adds the repository GPG key and source list
- **THEN** `apt install tillandsias` installs the latest .deb package

#### Scenario: Automatic DEB update
- **WHEN** a new release is published on GitHub
- **THEN** the APT repository metadata is updated on the gh-pages branch and `apt upgrade tillandsias` installs the new version

#### Scenario: GPG-signed repo
- **WHEN** the APT repository metadata is generated
- **THEN** the Release file is signed with a dedicated GPG key and an InRelease file is produced

### Requirement: Install script configures repos
The installer script SHALL configure the appropriate package repository so future updates are automatic.

#### Scenario: Fedora installer
- **WHEN** `install.sh` runs on Fedora and detects dnf
- **THEN** it enables the COPR repository and installs via dnf

#### Scenario: Debian/Ubuntu installer
- **WHEN** `install.sh` runs on Debian/Ubuntu and detects dpkg
- **THEN** it adds the GPG key, configures the APT source, and installs via apt
