## CHANGED Requirements

### Requirement: Install section shows exactly three platform sections

The `## Install` section of `README.md` SHALL contain exactly three platform sub-sections — Linux, macOS, and Windows — each rendered as a bold label followed by a fenced code block containing the one-shot install command. No `<details>` wrappers SHALL surround these sections.

#### Scenario: Linux install command
- **GIVEN** a user reads the Install section
- **THEN** they see `**Linux**` followed by a `bash` code block containing:
  ```
  curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
  ```

#### Scenario: macOS install command
- **GIVEN** a user reads the Install section
- **THEN** they see `**macOS**` followed by a `bash` code block containing:
  ```
  curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
  ```

#### Scenario: Windows install command
- **GIVEN** a user reads the Install section
- **THEN** they see `**Windows**` followed by a `powershell` code block containing:
  ```
  irm https://github.com/8007342/tillandsias/releases/latest/download/install.ps1 | iex
  ```

### Requirement: Distro-specific package manager instructions are absent

The Install section SHALL NOT contain instructions for APT repository setup, Fedora COPR, or Silverblue rpm-ostree layering.

#### Scenario: No APT instructions
- **WHEN** a user reads the Install section
- **THEN** there is no reference to `gpg --dearmor`, `apt.sources.list.d`, or `sudo apt install tillandsias`

#### Scenario: No COPR instructions
- **WHEN** a user reads the Install section
- **THEN** there is no reference to `dnf copr enable` or `sudo dnf install tillandsias`

#### Scenario: No rpm-ostree instructions
- **WHEN** a user reads the Install section
- **THEN** there is no reference to `rpm-ostree install tillandsias`

### Requirement: Direct downloads are collapsed in a single details block

A single `<details>` block with summary text `Direct downloads` SHALL appear after the three platform sections. It SHALL contain a markdown table with exactly four rows.

#### Scenario: Direct downloads table contents
- **GIVEN** the direct downloads block is expanded
- **THEN** the table contains these rows in order:
  1. Linux — `Tillandsias-linux-x86_64.AppImage`
  2. macOS (Apple Silicon) — `Tillandsias-macos-aarch64.dmg`
  3. macOS (Intel) — `Tillandsias-macos-x86_64.dmg`
  4. Windows — `Tillandsias-windows-x86_64-setup.exe`
- **AND** each row links to the corresponding file under `https://github.com/8007342/tillandsias/releases/latest/download/`

#### Scenario: RPM, DEB, MSI, and .app.tar.gz are absent from direct downloads
- **WHEN** the direct downloads block is expanded
- **THEN** there is no row for RPM, DEB, MSI, or `.app.tar.gz` formats

### Requirement: Sections after Install are unchanged

Every section at or after `## Run` SHALL be byte-for-byte identical to its state before this change.
