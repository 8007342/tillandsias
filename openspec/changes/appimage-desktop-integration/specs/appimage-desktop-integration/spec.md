## ADDED Requirements

### Requirement: AppImage self-installs desktop integration on first run
When running as an AppImage, the application SHALL install desktop integration files (`.desktop` file and icon PNGs) to the user's XDG directories so that the desktop environment displays the correct application icon.

#### Scenario: First AppImage launch
- **GIVEN** the `$APPIMAGE` environment variable is set (indicating AppImage runtime)
- **AND** no `.desktop` file exists at `~/.local/share/applications/tillandsias.desktop`
- **WHEN** the application starts
- **THEN** a `.desktop` file is written with `Exec=` pointing to the `$APPIMAGE` path
- **AND** icon PNGs are written to `~/.local/share/icons/hicolor/{32x32,128x128,256x256}/apps/tillandsias.png`
- **AND** `update-desktop-database` and `gtk-update-icon-cache` are executed

#### Scenario: AppImage moved to new location
- **GIVEN** the `$APPIMAGE` environment variable is set
- **AND** a `.desktop` file exists but its `Exec=` line does not match the current `$APPIMAGE` path
- **WHEN** the application starts
- **THEN** the `.desktop` file is rewritten with the updated `Exec=` path

#### Scenario: Subsequent launches with unchanged path
- **GIVEN** the `$APPIMAGE` environment variable is set
- **AND** a `.desktop` file exists with a matching `Exec=` path
- **WHEN** the application starts
- **THEN** no files are written (idempotent)

#### Scenario: Non-AppImage launch
- **GIVEN** the `$APPIMAGE` environment variable is NOT set
- **WHEN** the application starts
- **THEN** no desktop integration files are written

#### Scenario: Desktop integration failure
- **GIVEN** writing desktop integration files fails (permissions, disk full, missing commands)
- **WHEN** the application starts
- **THEN** a warning is logged
- **AND** the application continues startup normally (no crash)
