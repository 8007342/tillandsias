# desktop-integration Specification

## Purpose
Platform-native desktop launcher entries so non-terminal users can discover and launch Tillandsias from their operating system's standard application launcher.

## Requirements

### Requirement: Linux .desktop file installation
The install process SHALL create an XDG-compliant `.desktop` file so Tillandsias appears in the desktop environment's application launcher.

#### Scenario: Manual install creates .desktop file
- **WHEN** the user runs the install script on Linux
- **THEN** a `tillandsias.desktop` file is created at `~/.local/share/applications/tillandsias.desktop` with `Exec=` pointing to the installed binary, `Icon=tillandsias-tray`, `Terminal=false`, and `Categories=Development;`

#### Scenario: Application appears in launcher
- **WHEN** the .desktop file is installed and the icon cache is refreshed
- **THEN** Tillandsias appears in the GNOME Activities overview, KDE Application Launcher, or equivalent XDG-compliant launcher with the tillandsia icon

#### Scenario: Launching from desktop entry
- **WHEN** the user clicks the Tillandsias entry in their app launcher
- **THEN** the tray application starts and a system tray icon appears, with no terminal window opened

#### Scenario: Uninstall removes .desktop file
- **WHEN** the user runs the uninstall script on Linux
- **THEN** the `tillandsias.desktop` file is removed from `~/.local/share/applications/` and the desktop database is updated

### Requirement: Linux icon installation
The install process SHALL copy tillandsia icon PNGs to the XDG icon theme directory at standard resolutions.

#### Scenario: Icons installed at multiple resolutions
- **WHEN** the user runs the install script on Linux
- **THEN** tillandsia icons are installed at `~/.local/share/icons/hicolor/32x32/apps/tillandsias-tray.png`, `~/.local/share/icons/hicolor/128x128/apps/tillandsias-tray.png`, and `~/.local/share/icons/hicolor/256x256/apps/tillandsias-tray.png`

#### Scenario: Icon cache refreshed
- **WHEN** icons are installed or removed
- **THEN** the install/uninstall script runs `gtk-update-icon-cache ~/.local/share/icons/hicolor/` if the command is available

#### Scenario: Uninstall removes icons
- **WHEN** the user runs the uninstall script on Linux
- **THEN** all `tillandsias-tray.png` files are removed from `~/.local/share/icons/hicolor/` at all resolutions

### Requirement: macOS .app bundle
The install process SHALL create a `.app` bundle so Tillandsias appears in Finder, Spotlight, and Launchpad.

#### Scenario: Manual install creates .app bundle
- **WHEN** the user runs the install script on macOS
- **THEN** a `Tillandsias.app` bundle is created in `~/Applications/` with a valid `Info.plist`, the binary in `Contents/MacOS/`, and the icon in `Contents/Resources/` as `.icns` format

#### Scenario: Spotlight indexing
- **WHEN** the .app bundle is placed in `~/Applications/`
- **THEN** Spotlight indexes it and the user can find Tillandsias by typing its name

#### Scenario: Launching from Launchpad
- **WHEN** the user clicks the Tillandsias icon in Launchpad
- **THEN** the tray application starts and a menu bar icon appears

#### Scenario: Uninstall removes .app bundle
- **WHEN** the user runs the uninstall script on macOS
- **THEN** the `Tillandsias.app` bundle is removed from `~/Applications/`

### Requirement: Windows Start Menu shortcut
The install process SHALL create a Start Menu shortcut so Tillandsias appears in the Windows Start Menu.

#### Scenario: Installer creates Start Menu entry
- **WHEN** Tillandsias is installed via the NSIS or MSI installer on Windows
- **THEN** a shortcut appears in the Start Menu under Programs with the tillandsia icon

#### Scenario: Manual install creates Start Menu shortcut
- **WHEN** the user runs the install PowerShell script on Windows
- **THEN** a shortcut is created at `$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Tillandsias.lnk` pointing to the installed binary with the tillandsia icon

#### Scenario: Launching from Start Menu
- **WHEN** the user clicks the Tillandsias entry in the Start Menu
- **THEN** the tray application starts and a system tray icon appears in the notification area

#### Scenario: Uninstall removes Start Menu shortcut
- **WHEN** the user runs the uninstall script or uninstaller on Windows
- **THEN** the Start Menu shortcut is removed

### Requirement: Optional autostart on login
The application SHALL support an optional autostart-on-login mode, disabled by default, using each platform's native autostart mechanism.

#### Scenario: Autostart disabled by default
- **WHEN** Tillandsias is installed with default configuration
- **THEN** no autostart entry is created and the application does not launch on login

#### Scenario: Enabling autostart on Linux
- **WHEN** the user sets `autostart = true` in `~/.config/tillandsias/config.toml`
- **THEN** a `.desktop` file is created at `~/.config/autostart/tillandsias.desktop` with `X-GNOME-Autostart-enabled=true`

#### Scenario: Enabling autostart on macOS
- **WHEN** the user enables autostart
- **THEN** a Launch Agent plist is created at `~/Library/LaunchAgents/com.tillandsias.tray.plist` that runs the binary on login

#### Scenario: Enabling autostart on Windows
- **WHEN** the user enables autostart
- **THEN** a registry entry is created at `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` pointing to the installed binary

#### Scenario: Disabling autostart removes the entry
- **WHEN** the user sets `autostart = false` or runs the uninstall script
- **THEN** the platform-specific autostart entry is removed

#### Scenario: Autostart with missing binary
- **WHEN** autostart is enabled but the binary has been removed without running uninstall
- **THEN** the operating system handles the missing executable gracefully (silent failure, no error dialog)

### Requirement: Idempotent install and uninstall
Running the install or uninstall script multiple times SHALL produce the same result as running it once.

#### Scenario: Repeated install
- **WHEN** the install script is run twice
- **THEN** the second run overwrites the existing .desktop file, icons, and shortcuts without errors or duplicate entries

#### Scenario: Repeated uninstall
- **WHEN** the uninstall script is run after the files have already been removed
- **THEN** the script completes without errors

#### Scenario: Uninstall after manual deletion
- **WHEN** the user manually deletes the .desktop file and then runs uninstall
- **THEN** the uninstall script completes without errors and removes any remaining files (icons, autostart entries)
