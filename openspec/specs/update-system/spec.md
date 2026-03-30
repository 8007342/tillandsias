# update-system Specification

## Purpose
TBD - created by archiving change auto-updater. Update Purpose after archive.
## Requirements
### Requirement: Silent update check on app launch
The application SHALL check for available updates in the background after startup without blocking the UI or delaying tray icon appearance.

#### Scenario: Update check after startup delay
- **WHEN** the tray application finishes initialization and the tray icon is visible
- **THEN** an update check is initiated in a background task after a 5-second delay, with no visible indication to the user

#### Scenario: Update check does not block UI
- **WHEN** the background update check is in progress (network request to GitHub Releases)
- **THEN** the tray icon, menu, and all user interactions remain fully responsive

#### Scenario: Periodic update check while running
- **WHEN** the application has been running for the configured check interval (default 6 hours)
- **THEN** a background update check is performed automatically without user interaction

#### Scenario: Configurable check interval
- **WHEN** the user sets `check_interval_hours` in `~/.config/tillandsias/config.toml`
- **THEN** the application uses the configured interval instead of the default 6-hour interval

### Requirement: User-approved update installation
The application SHALL notify the user when an update is available and SHALL NOT install any update without explicit user approval.

#### Scenario: Update available notification in tray menu
- **WHEN** the background check detects a newer version on GitHub Releases
- **THEN** a tray menu item appears showing "Update available (vX.Y.Z)" where X.Y.Z is the new version number

#### Scenario: System notification on first detection
- **WHEN** an update is detected for the first time during a session
- **THEN** a platform-native system notification (toast) is displayed informing the user that an update is available

#### Scenario: User approves update
- **WHEN** the user clicks the "Update available" tray menu item
- **THEN** the update download and installation process begins

#### Scenario: Update not installed without approval
- **WHEN** an update is detected but the user does not click the menu item
- **THEN** no update is downloaded or installed, and the menu item persists until the user acts or the app is restarted

#### Scenario: Update notification persists across menu rebuilds
- **WHEN** the tray menu is rebuilt due to container state changes or project detection events
- **THEN** the "Update available" menu item remains visible if an update is still pending

### Requirement: Signature verification before install
The application SHALL verify the Ed25519 signature of every update bundle before applying it. Unsigned or incorrectly signed updates MUST be rejected.

#### Scenario: Valid signature allows installation
- **WHEN** the updater downloads an update bundle and the Ed25519 signature matches the public key compiled into the running binary
- **THEN** the update is applied and the binary is replaced

#### Scenario: Invalid signature rejects installation
- **WHEN** the updater downloads an update bundle whose Ed25519 signature does not match the compiled-in public key
- **THEN** the update is rejected, no binary replacement occurs, and an error is logged

#### Scenario: Missing signature rejects installation
- **WHEN** the updater downloads an update bundle that has no signature
- **THEN** the update is rejected, no binary replacement occurs, and an error is logged

#### Scenario: Tampered update bundle detection
- **WHEN** an update bundle has been modified after signing (content does not match signature)
- **THEN** signature verification fails, the update is rejected, and the running binary is unchanged

#### Scenario: Public key is compiled into the binary
- **WHEN** the application is built
- **THEN** the Tauri updater public key is embedded in the binary via `tauri.conf.json` and cannot be modified at runtime

### Requirement: Graceful restart after update
The application SHALL perform a clean shutdown of all managed resources before restarting with the updated binary.

#### Scenario: Containers stopped before restart
- **WHEN** the user approves an update and the update is ready to install
- **THEN** all managed containers are stopped gracefully (SIGTERM followed by 10-second grace period, then SIGKILL) before the binary is replaced and the application restarts

#### Scenario: Application relaunches after update
- **WHEN** all managed containers have been stopped and the binary replacement is complete
- **THEN** the application relaunches automatically with the new version, and the tray icon reappears

#### Scenario: State preserved across restart
- **WHEN** the application restarts after an update
- **THEN** the filesystem scanner re-detects projects and the application resumes normal operation (container state is rediscovered from running containers if any survived)

#### Scenario: Update progress indication
- **WHEN** the update download and installation are in progress
- **THEN** the tray menu shows a progress indicator (e.g., "Updating..." or "Downloading update...") and disables the update menu item to prevent duplicate actions

### Requirement: Offline resilience
The application SHALL handle the absence of network connectivity gracefully during update checks without crashing, showing error dialogs, or degrading tray app functionality.

#### Scenario: No network on launch
- **WHEN** the application starts and has no network connectivity
- **THEN** the update check fails silently, no error is shown to the user, and the application continues running the current version normally

#### Scenario: Network loss during periodic check
- **WHEN** a periodic update check is attempted but the network is unavailable
- **THEN** the check fails silently and is retried at the next scheduled interval

#### Scenario: Network loss during download
- **WHEN** the user approves an update and the download begins but the network connection is lost mid-download
- **THEN** the download is aborted, the tray menu reverts to showing "Update available," and the user can retry when connectivity is restored

#### Scenario: DNS resolution failure
- **WHEN** the update check cannot resolve the GitHub Releases hostname
- **THEN** the check fails silently with no user-visible error, identical to a network timeout

#### Scenario: GitHub API rate limiting
- **WHEN** the GitHub Releases API returns a rate-limit response (HTTP 403/429)
- **THEN** the update check is silently deferred to the next scheduled interval without error dialogs

### Requirement: Update endpoint configuration
The application SHALL use GitHub Releases as the sole update endpoint, configured in `tauri.conf.json`.

#### Scenario: GitHub Releases endpoint
- **WHEN** the updater checks for a new version
- **THEN** it queries the GitHub Releases API for the Tillandsias repository to find the latest release and its platform-specific artifacts

#### Scenario: Platform-appropriate artifact selection
- **WHEN** an update is available and the updater downloads the update bundle
- **THEN** it selects the artifact matching the current platform (AppImage for Linux, .dmg/.app for macOS, .exe for Windows)

#### Scenario: AppImage on immutable OS without FUSE
- **WHEN** the application runs as an AppImage on an immutable operating system (e.g., Fedora Silverblue, SteamOS) where FUSE is unavailable or restricted
- **THEN** the application sets the `APPIMAGE_EXTRACT_AND_RUN=1` environment variable to enable AppImage execution via extraction fallback instead of FUSE mounting

### Requirement: CI signing of update bundles
The release CI workflow SHALL sign all Tauri update bundles with the Ed25519 private key stored in GitHub Actions secrets.

#### Scenario: Update bundles signed during CI
- **WHEN** the release workflow builds Tauri bundles for each platform
- **THEN** each bundle is signed with the `TAURI_SIGNING_PRIVATE_KEY` secret, producing a signature that matches the public key embedded in the application

#### Scenario: Missing signing key fails the build
- **WHEN** the `TAURI_SIGNING_PRIVATE_KEY` secret is not configured in GitHub Actions
- **THEN** the Tauri build fails and no release is created (preventing unsigned updates from being published)

