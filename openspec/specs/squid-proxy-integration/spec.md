# squid-proxy-integration Specification

@trace spec:squid-proxy-integration

## Status

active

## Requirements

### Requirement: Runtime traffic uses the Squid proxy policy

Forge and runtime containers MUST route configured HTTP/HTTPS traffic through the Squid proxy so allowlists, localhost peer routing, and cache policy are enforced consistently.

#### Scenario: Localhost service request stays inside enclave

- **WHEN** a forge process requests a `*.localhost` service URL through the configured proxy
- **THEN** Squid MUST route it to the internal router peer
- **AND** it MUST NOT resolve the name through public DNS

## Sources of Truth

- `cheatsheets/runtime/squid-cache-peer-routing.md` - Squid peer routing rules
- `cheatsheets/runtime/networking.md` - Network boundary context

