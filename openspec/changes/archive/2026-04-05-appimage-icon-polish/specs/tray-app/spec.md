## ADDED Requirements

### Requirement: AppImage icon display
The AppImage SHALL display the tillandsia icon in file managers, desktop launchers, and when integrated with the desktop.

#### Scenario: Desktop integration icon
- **WHEN** the AppImage is integrated with the desktop (via appimaged or manual extraction)
- **THEN** the application launcher shows the tillandsia icon

#### Scenario: Icon at all standard sizes
- **WHEN** the AppImage is built
- **THEN** icons at 32x32, 128x128, 256x256 are embedded in the hicolor theme structure inside the AppDir
