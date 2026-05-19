# browser-routing-allowlist Specification

@trace spec:browser-routing-allowlist

## Status

active

## Requirements

### Requirement: Browser routes are allowlisted by project and service

Browser window state MUST keep route targets explicit. A browser-facing route is valid only when its project label, service label, hostname, upstream container, and internal port are known to the tray state model.

#### Scenario: Unknown routes are rejected

- **WHEN** a browser window or service lookup references an unknown project/service pair
- **THEN** the state layer MUST refuse to create or reuse that route
- **AND** the reverse-proxy route table MUST remain unchanged for that unknown pair

## Sources of Truth

- `cheatsheets/runtime/browser-isolation.md` - Browser isolation model
- `cheatsheets/runtime/caddy-reverse-proxy.md` - Reverse proxy route ownership
- `cheatsheets/runtime/networking.md` - Localhost and loopback routing constraints

