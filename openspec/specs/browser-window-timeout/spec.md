# browser-window-timeout Specification

@trace spec:browser-window-timeout

## Status

active

## Requirements

### Requirement: Browser windows expire after inactivity

Browser MCP windows MUST enforce idle and absolute timeout policy so stale browser sessions cannot accumulate indefinitely.

#### Scenario: Idle window expires

- **WHEN** a window has no recorded activity beyond the configured idle timeout
- **THEN** it MUST be eligible for cleanup
- **AND** cleanup MUST close the associated process when a process handle is still available

## Sources of Truth

- `cheatsheets/runtime/browser-isolation.md` - Browser runtime isolation model
- `cheatsheets/runtime/request-rate-limiting.md` - Timeout and defensive request limits
- `cheatsheets/web/cdp.md` - Browser automation behavior

