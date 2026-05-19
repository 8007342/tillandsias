# browser-window-lifecycle Specification

@trace spec:browser-window-lifecycle

## Status

active

## Requirements

### Requirement: Browser windows have explicit lifecycle state

Browser MCP windows MUST be tracked from launch through close with stable IDs, creation timestamps, last activity timestamps, and process handles where available.

#### Scenario: Closed windows are removed from active registry

- **WHEN** a tracked browser process exits or is explicitly closed
- **THEN** the registry MUST remove it from active lookup
- **AND** later operations MUST fail with a clear missing-window result instead of reusing stale state

## Sources of Truth

- `cheatsheets/runtime/browser-isolation.md` - Isolated browser process expectations
- `cheatsheets/runtime/tray-state-machine.md` - State transition conventions
- `cheatsheets/web/cdp.md` - Browser control protocol context

