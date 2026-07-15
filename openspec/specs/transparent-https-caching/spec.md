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

Containers that use the proxy for HTTPS package traffic MUST install the mounted Tillandsias CA into the container trust store before package managers run. The forge image SHALL preserve the immutable vendor roots and expose a forge-owned ephemeral bundle through the distribution's system-default trust path. One shared rootless initializer SHALL atomically compose the vendor roots and runtime CA before any entrypoint network work; launchers and entrypoints SHALL NOT select CA files with `GIT_SSL_CAINFO`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, or `NODE_EXTRA_CA_CERTS`.

#### Scenario: Rootless forge initializes one system-default bundle

- **WHEN** a forge or maintenance container starts with `/run/tillandsias/ca-chain.crt` mounted read-only
- **THEN** the shared entrypoint library SHALL atomically compose it with the image-baked vendor roots under `/run/tillandsias`
- **AND** Git, curl, Node, and Python SHALL validate through the distribution's standard trust lookup
- **AND** the unprivileged forge user SHALL have no write access to the immutable vendor bundle or any host trust store

#### Scenario: CA mount is missing

- **WHEN** a container starts without the expected proxy CA mount
- **THEN** startup MUST make that condition diagnosable
- **AND** package-manager TLS failures MUST not be hidden by silently disabling trust checks

## Sources of Truth

- `cheatsheets/runtime/squid-cache-peer-routing.md` - Squid proxy and peer routing
- `cheatsheets/runtime/networking.md` - Network and localhost constraints
- `cheatsheets/security/owasp-top-10-2021.md` - TLS and trust failure handling
