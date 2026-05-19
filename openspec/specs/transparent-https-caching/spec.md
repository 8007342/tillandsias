# transparent-https-caching Specification

@trace spec:transparent-https-caching

## Status

active

## Requirements

### Requirement: HTTPS cache interception uses generated CA material

Development and enclave proxy paths that enable HTTPS caching MUST generate or mount intermediate CA material before Squid starts SSL bumping traffic.

#### Scenario: Concurrent proxy startup cannot publish partial CA files

- **WHEN** multiple build or runtime flows attempt to prepare CA material at the same time
- **THEN** generation MUST be serialized
- **AND** consumers MUST see either the previous complete certificate/key pair or the new complete pair, never partial files

### Requirement: Runtime containers trust the Tillandsias proxy CA

Containers that use the proxy for HTTPS package traffic MUST install the mounted Tillandsias CA into the container trust store before package managers run.

#### Scenario: CA mount is missing

- **WHEN** a container starts without the expected proxy CA mount
- **THEN** startup MUST make that condition diagnosable
- **AND** package-manager TLS failures MUST not be hidden by silently disabling trust checks

## Sources of Truth

- `cheatsheets/runtime/squid-cache-peer-routing.md` - Squid proxy and peer routing
- `cheatsheets/runtime/networking.md` - Network and localhost constraints
- `cheatsheets/security/owasp-top-10-2021.md` - TLS and trust failure handling

