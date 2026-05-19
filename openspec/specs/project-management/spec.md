# project-management Specification

@trace spec:project-management

## Status

active

## Requirements

### Requirement: Project selection is stable across tray operations

Project state MUST use a canonical project label and workspace path so rapid switching, service launch, and browser routing target the selected project consistently.

#### Scenario: Rapid project switch does not cross-wire state

- **WHEN** the active project changes while background operations are still running
- **THEN** each operation MUST continue using the project label it was created with
- **AND** new operations MUST use the newly selected project

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - Tray state transitions
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` - Project path ownership

