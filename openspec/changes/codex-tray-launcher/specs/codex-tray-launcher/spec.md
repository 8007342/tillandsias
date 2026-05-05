# Codex Tray Launcher

@trace spec:codex-tray-launcher, spec:tray-app, spec:agent-icon-representation

**Purpose**: Enable users to launch the Codex agent directly from the tray menu for code analysis and understanding.

## ADDED Requirements

### Requirement: Menu button for Codex
The tray menu SHALL display a 🏗 Codex button for each project, positioned after Claude and before Terminal in the action row.

#### Scenario: Codex button visible when authenticated
- **WHEN** user is authenticated and views a project's menu
- **THEN** the Codex button appears with label "🏗 Codex"
- **AND** the button is enabled if forge is available

#### Scenario: Codex button disabled when forge unavailable
- **WHEN** forge image has not been built or is inaccessible
- **THEN** the Codex button appears but is disabled (grayed out)
- **AND** tooltip indicates "Forge unavailable"

### Requirement: Launch Codex container on button click
The system SHALL spawn a new Codex container when the user clicks the Codex menu button.

#### Scenario: Codex container launches successfully
- **WHEN** user clicks the Codex button
- **THEN** system creates a container named `tillandsias-<project>-codex`
- **AND** the container joins the enclave network (proxy, git service, inference)
- **AND** a progress chip labeled "🏗 Codex — <project>" appears in the tray
- **AND** stdout/stderr are piped to the tray log with `[codex]` prefix

#### Scenario: Launch fails due to missing image
- **WHEN** user clicks Codex but the forge image is missing
- **THEN** system displays an error message: "Forge image not found"
- **AND** user is offered to run `tillandsias --init` to rebuild

#### Scenario: Container already running
- **WHEN** user clicks Codex but a Codex container is already running for the project
- **THEN** system attaches to the existing container instead of creating a new one
- **AND** the existing progress chip is highlighted

### Requirement: Manage Codex container lifecycle
The system SHALL manage Codex container state: launch, monitor, stop, and destroy.

#### Scenario: Stop Codex container
- **WHEN** user clicks the progress chip for Codex and selects "Stop"
- **THEN** system stops the container gracefully (SIGTERM, then SIGKILL after timeout)
- **AND** the progress chip transitions to gray and disappears after 2 seconds

#### Scenario: Destroy Codex container and cleanup
- **WHEN** user clicks the progress chip and selects "Destroy"
- **THEN** system removes the container and all ephemeral state
- **AND** uncommitted work in the container is lost (user is warned)

### Requirement: Visual state feedback
The system SHALL provide tray icon state and progress chip color feedback during Codex launch.

#### Scenario: Tray icon state during Codex launch
- **WHEN** Codex is launching
- **THEN** tray icon transitions to 🔄 (working state)
- **AND** progress chip color is yellow

#### Scenario: Tray icon state when Codex is ready
- **WHEN** Codex container is ready to accept input
- **THEN** tray icon returns to 🌟 (success state)
- **AND** progress chip color changes to green

## Sources of Truth

- `cheatsheets/runtime/container-lifecycle.md` — Container lifecycle state machine
- `cheatsheets/runtime/tray-minimal-ux.md` — Tray menu structure and minimal action set
- `cheatsheets/runtime/tray-state-machine.md` — Tray icon state transitions
