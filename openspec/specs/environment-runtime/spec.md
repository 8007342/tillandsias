## MODIFIED Requirements

### Requirement: Global and per-project configuration
The configuration system SHALL support a two-level hierarchy: global defaults at a platform-specific path and per-project overrides at `<project>/.tillandsias/config.toml`.

#### Scenario: Platform-specific config paths
- **WHEN** the application runs on macOS
- **THEN** the global config is located at `~/Library/Application Support/tillandsias/config.toml`

#### Scenario: Platform-specific config paths (Windows)
- **WHEN** the application runs on Windows
- **THEN** the global config is located at `%APPDATA%\tillandsias\config.toml`

#### Scenario: Platform-specific config paths (Linux)
- **WHEN** the application runs on Linux
- **THEN** the global config is located at `~/.config/tillandsias/config.toml`

### Requirement: User-facing files must be verbose and non-technical

All configuration files, log directories, and data files that a user
may discover on their filesystem SHALL include clear, non-technical
documentation explaining:
- What the file/directory is for
- Whether it is safe to delete
- What each setting does in plain language
- That security settings cannot be weakened

Users should never feel alarmed or confused by Tillandsias artifacts
on their system. Transparency and accountability are non-negotiable.

### Requirement: Accountable uninstall

The uninstall script SHALL:
- Print a list of files and directories that will be removed BEFORE deletion
- Remove all Tillandsias artifacts: binary, libraries, data, settings, and logs
- Report what was cleaned after deletion
- Confirm that project files were NOT touched
- Support `--wipe` for cache and container image removal
