## MODIFIED Requirements

### Requirement: First-launch readiness feedback

The tray application SHALL provide clear visual feedback during first-launch setup and SHALL NOT silently fail when infrastructure is unavailable.

#### Scenario: Forge image not yet built
- **WHEN** the tray starts and the forge image is absent
- **THEN** a "Setting up..." build chip appears in the tray menu
- **AND** all forge-dependent menu items (Attach Here, Maintenance, Root) are disabled
- **AND** the build chip transitions to "ready" or "failed" when the build completes

#### Scenario: Infrastructure setup failure
- **WHEN** `ensure_infrastructure_ready` fails at startup
- **THEN** a desktop notification informs the user of the issue
- **AND** the tray continues operating in degraded mode (forge builds bypass proxy cache)

#### Scenario: Attach Here called before forge ready
- **WHEN** `handle_attach_here` is invoked while `forge_available` is false
- **THEN** a desktop notification tells the user to wait
- **AND** the handler returns early without attempting a build
- **AND** no silent failure occurs

### Requirement: Cross-platform tray behavior
The tray application SHALL function correctly on Linux, macOS, and Windows using Tauri v2's native tray support.

#### Scenario: Linux tray
- **WHEN** the application runs on Linux
- **THEN** the tray icon integrates with the desktop environment via DBus StatusNotifierItem (libayatana-appindicator)

#### Scenario: macOS tray
- **WHEN** the application runs on macOS
- **THEN** the tray icon appears in the macOS menu bar as a native NSStatusItem

#### Scenario: Windows tray
- **WHEN** the application runs on Windows
- **THEN** the tray icon appears in the Windows system tray notification area
