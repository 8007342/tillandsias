# tray-menu Specification

@trace spec:tray-menu

## Status

active

## Requirements

### Requirement: Tray menu reflects current runtime state

The tray menu MUST expose actions and status labels that match current runtime state, selected project, and available services.

#### Scenario: Project-specific menu action is rendered

- **WHEN** a project is selected and its actions are available
- **THEN** the menu MUST render actions for that project
- **AND** invoking an action MUST carry the selected project identity

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - Menu and state behavior
- `cheatsheets/welcome/tray-minimal-ux.md` - Minimal tray UX expectations

