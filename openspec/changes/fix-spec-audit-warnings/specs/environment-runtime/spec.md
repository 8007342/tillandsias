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
