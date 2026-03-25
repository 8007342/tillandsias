## ADDED Requirements

### Requirement: Three-state tray icon
The main tray icon SHALL reflect the overall application health and activity through three distinct visual states: Base, Building, and Decay.

#### Scenario: Base state — ready and idle
- **WHEN** podman is available AND no image builds are in progress
- **THEN** the tray icon displays the Base (bud) icon

#### Scenario: Building state — image build in progress
- **WHEN** podman is available AND one or more image builds are in progress
- **THEN** the tray icon displays the Building (bloom, green tones) icon

#### Scenario: Decay state — podman unavailable
- **WHEN** podman is not available or cannot be contacted
- **THEN** the tray icon displays the Decay (dried, brown) icon and remains in this state until the app is restarted

### Requirement: State machine transitions
Tray icon state transitions SHALL follow a defined state machine with Decay as a terminal non-recoverable state.

#### Scenario: Build starts from Base
- **WHEN** an image build begins while in Base state
- **THEN** the icon transitions immediately to Building

#### Scenario: Last build completes
- **WHEN** the final in-progress build completes (active build count reaches zero)
- **THEN** the icon transitions from Building back to Base

#### Scenario: Podman disappears during build
- **WHEN** podman becomes unavailable while in Building state
- **THEN** the icon transitions to Decay; the build is considered failed

#### Scenario: Decay is terminal
- **WHEN** the application is in Decay state
- **THEN** no transition out of Decay occurs; the user must restart the application after fixing podman

### Requirement: Launch-time podman check
On every launch, the application SHALL verify podman availability before entering the event loop.

#### Scenario: Podman not found on launch
- **WHEN** the application starts and podman is not in PATH or cannot respond to a version query
- **THEN** the app enters Decay state immediately, displays the Decay icon, and shows a single disabled error item in the tray menu explaining podman is not available

#### Scenario: Podman found on launch
- **WHEN** the application starts and podman responds successfully
- **THEN** the launch sequence continues to the forge image check

### Requirement: Automatic forge image build on first launch
If podman is available but the forge image is absent, the application SHALL build it automatically without requiring user action.

#### Scenario: Forge image absent at launch
- **WHEN** podman is available AND `tillandsias-forge:latest` is not present in the local image store
- **THEN** a forge image build starts automatically using the existing build lock, the icon is set to Building, and the app becomes ready (Base) when the build completes

#### Scenario: Forge image present at launch
- **WHEN** podman is available AND `tillandsias-forge:latest` already exists
- **THEN** no build is triggered and the app starts directly in Base state

#### Scenario: Web image at launch
- **WHEN** the application starts
- **THEN** the web image is NOT checked and NOT built; it is built on-demand only when first needed

### Requirement: Decay state disables all actions
When in Decay state, all project and environment actions SHALL be disabled to prevent operations that cannot succeed.

#### Scenario: Menu in Decay state
- **WHEN** the user opens the tray menu while in Decay state
- **THEN** all project items and action items are rendered as disabled, a single non-interactive error message is shown at the top, and only the Quit item remains interactive

## MODIFIED Requirements

### Requirement: Tray icon state management (replaces static icon)
The main tray icon SHALL update at runtime by calling `TrayIcon::set_icon()` whenever the icon state changes, replacing the prior behavior of a static icon set once at startup.

#### Scenario: Icon updates on state transition
- **WHEN** `tray_icon_state` changes between any two states
- **THEN** `TrayIcon::set_icon()` is called exactly once with the new icon bytes, and no call is made when the state value is unchanged
