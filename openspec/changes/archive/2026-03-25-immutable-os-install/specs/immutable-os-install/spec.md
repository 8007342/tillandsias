## NEW Requirements

### Requirement: Immutable OS detection

The installer SHALL detect immutable/ostree-based OS variants before performing any package manager operations.

#### Scenario: Detection via ostree marker
- **GIVEN** a system with `/run/ostree-booted` present
- **WHEN** the install script runs (any invocation context)
- **THEN** `IS_IMMUTABLE` is set to `true`
- **AND** the script prints: "Immutable OS detected (Silverblue/Kinoite/uBlue) — installing to userspace"

#### Scenario: Detection via rpm-ostree command
- **GIVEN** a system where `rpm-ostree` is in PATH but `/run/ostree-booted` is absent
- **WHEN** the install script runs
- **THEN** `IS_IMMUTABLE` is set to `true`
- **AND** the script prints: "Immutable OS detected (Silverblue/Kinoite/uBlue) — installing to userspace"

#### Scenario: No detection on mutable systems
- **GIVEN** a standard Fedora Workstation, Ubuntu, or Debian system
- **WHEN** the install script runs
- **THEN** `IS_IMMUTABLE` remains `false`
- **AND** the existing deb/rpm/AppImage fallback chain runs unchanged

### Requirement: AppImage-first routing on immutable OS

On immutable OS, the installer SHALL skip all package manager paths and go directly to AppImage userspace install.

#### Scenario: Piped from curl on Silverblue
- **GIVEN** an immutable OS and the script invoked via `curl ... | bash`
- **WHEN** `IS_IMMUTABLE` is `true`
- **THEN** the deb, COPR, dnf, and rpm-ostree install paths are all skipped
- **AND** the AppImage is downloaded to `~/.local/bin/tillandsias`

#### Scenario: Interactive invocation on Silverblue
- **GIVEN** an immutable OS and the script invoked interactively (stdin is a terminal)
- **WHEN** `IS_IMMUTABLE` is `true`
- **THEN** the deb, COPR, dnf, and rpm-ostree install paths are all skipped
- **AND** the AppImage is downloaded to `~/.local/bin/tillandsias`
- **AND** behavior is identical to the piped-from-curl case

### Requirement: Immutable OS detection is early

The immutable OS detection SHALL occur before the `HAS_SUDO` check, so it cannot be bypassed by sudo availability.

#### Scenario: Detection order
- **GIVEN** an immutable OS where sudo is available
- **WHEN** the install script runs
- **THEN** `IS_IMMUTABLE=true` is set before `HAS_SUDO` is evaluated
- **AND** the immutable routing takes effect regardless of `HAS_SUDO`
