# menu-action-error-handling Specification

@trace spec:menu-action-error-handling

## Status

active

## Requirements

### Requirement: Tray menu action failures are visible and bounded

Tray menu actions MUST convert command, process, and runtime failures into visible state or events without crashing the tray loop.

#### Scenario: Menu command fails

- **WHEN** a user triggers a tray menu action and the underlying command fails
- **THEN** the tray MUST record or display the failure
- **AND** subsequent menu actions MUST remain available

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - Tray action state handling
- `cheatsheets/welcome/tray-minimal-ux.md` - Minimal tray UX expectations

