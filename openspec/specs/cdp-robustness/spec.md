# cdp-robustness Specification

@trace spec:cdp-robustness

## Status

active

## Requirements

### Requirement: CDP operations handle transport failure explicitly

Chrome DevTools Protocol clients MUST treat connection loss, malformed responses, timeouts, and target disappearance as recoverable operation failures with structured errors.

#### Scenario: CDP target disappears

- **WHEN** a CDP command is issued after its target closes
- **THEN** the client MUST return a typed failure
- **AND** callers MUST NOT panic or leave the window registry in an inconsistent state

## Sources of Truth

- `cheatsheets/web/cdp.md` - CDP command and session behavior
- `cheatsheets/runtime/cdp-security.md` - CDP exposure and safety constraints
- `cheatsheets/web/websocket.md` - WebSocket transport behavior

