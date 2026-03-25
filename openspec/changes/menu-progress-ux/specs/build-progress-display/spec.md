## ADDED Requirements

### Requirement: Build progress chips in tray menu

The tray menu SHALL display a disabled status item for each active or recently completed image build and maintenance container setup.

#### Scenario: Build in progress

- **GIVEN** an image build has started
- **WHEN** the tray menu is opened
- **THEN** a disabled item `"⏳ Building {image_name}..."` is visible in the menu

#### Scenario: Build completed — chip visible

- **GIVEN** an image build has just completed
- **WHEN** the tray menu is opened within 10 seconds of completion
- **THEN** a disabled item `"✅ {image_name} ready"` is visible in the menu

#### Scenario: Build completed — chip removed

- **GIVEN** an image build completed more than 10 seconds ago
- **WHEN** the tray menu is opened (or any state-transition rebuild occurs)
- **THEN** no chip for that build appears in the menu

#### Scenario: Build failed

- **GIVEN** an image build has failed
- **WHEN** the tray menu is opened
- **THEN** a disabled item `"❌ {image_name} build failed"` is visible in the menu
- **AND** that item persists across menu opens until a new build attempt begins

#### Scenario: No active builds

- **GIVEN** no builds are in progress and no builds completed in the last 10 seconds
- **WHEN** the tray menu is opened
- **THEN** no build-progress chips are shown

---

### Requirement: State-transition-only menu rebuilds

Menu rebuilds triggered by build progress MUST occur only at discrete state transitions, never on a timer or animation tick.

#### Scenario: No periodic rebuilds during build

- **GIVEN** a build is in progress
- **WHEN** no state transition (started / completed / failed) occurs
- **THEN** `rebuild_menu()` is NOT called
- **AND** the menu does not flicker on Linux/libappindicator

#### Scenario: 10-second chip removal is timer-triggered but single-fire

- **GIVEN** a build completed and the `✅` chip is displayed
- **WHEN** 10 seconds elapse
- **THEN** exactly one `rebuild_menu()` call is made to remove the chip
- **AND** no further timer-driven rebuilds occur

---

## MODIFIED Requirements

### Requirement: Maintenance menu item label

#### Scenario: Project submenu terminal entry

- **WHEN** a project submenu is rendered
- **THEN** the terminal entry displays as `"🔧 Maintenance"` (wrench emoji + label)
- **AND** `MenuCommand::Terminal` is dispatched unchanged when clicked
- **AND** the menu item ID remains `terminal:<path>`
