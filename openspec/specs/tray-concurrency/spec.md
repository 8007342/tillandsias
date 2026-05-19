# tray-concurrency Specification

@trace spec:tray-concurrency

## Status

active

## Requirements

### Requirement: Tray operations are concurrency-safe

Tray state operations MUST tolerate rapid user actions and background task completion without corrupting active project, menu, or service state.

#### Scenario: Concurrent project actions complete out of order

- **WHEN** two project-related operations complete in a different order than they were started
- **THEN** each completion MUST update only the state owned by its project/action token
- **AND** the active project MUST not be overwritten by stale completion data

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - Tray state ownership
- `cheatsheets/runtime/async-patterns-rust.md` - Async concurrency patterns

