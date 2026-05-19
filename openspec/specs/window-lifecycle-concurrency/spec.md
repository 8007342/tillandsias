# window-lifecycle-concurrency Specification

@trace spec:window-lifecycle-concurrency

## Status

active

## Requirements

### Requirement: Window lifecycle updates are token-scoped

Browser window lifecycle operations MUST be scoped to the window/project token that initiated them so concurrent launches, closes, and route updates cannot overwrite unrelated state.

#### Scenario: Stale close event arrives after relaunch

- **WHEN** a close event for an old window arrives after a new window has been launched for the same project
- **THEN** the old close event MUST NOT remove the new window record
- **AND** diagnostics MUST retain enough identity to explain the ignored stale event

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` - State token ownership
- `cheatsheets/runtime/async-patterns-rust.md` - Async lifecycle patterns
