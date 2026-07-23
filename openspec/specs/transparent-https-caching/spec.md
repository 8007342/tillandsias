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

Containers whose proxied HTTPS traffic may follow a redirect to the exact
release-asset bump target MUST install the mounted Tillandsias CA into the
container trust store before network clients run. The forge image SHALL
preserve the immutable vendor roots and expose a forge-owned ephemeral bundle
through the distribution's system-default trust path. One shared rootless
initializer SHALL atomically compose the vendor roots and runtime CA before
any entrypoint network work; launchers and entrypoints SHALL NOT select CA
files with `GIT_SSL_CAINFO`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, or
`NODE_EXTRA_CA_CERTS`.

#### Scenario: Rootless forge initializes one system-default bundle

- **WHEN** a forge or maintenance container starts with `/run/tillandsias/ca-chain.crt` mounted read-only
- **THEN** the shared entrypoint library SHALL atomically compose it with the image-baked vendor roots under `/run/tillandsias`
- **AND** Git, curl, Node, and Python SHALL validate through the distribution's standard trust lookup
- **AND** the unprivileged forge user SHALL have no write access to the immutable vendor bundle or any host trust store

#### Scenario: CA mount is missing

- **WHEN** a container starts without the expected proxy CA mount
- **THEN** startup MUST make that condition diagnosable
- **AND** package-manager TLS failures MUST not be hidden by silently disabling trust checks

### Requirement: HTTPS interception is exact-host, step-aware, and fail-closed

Squid MUST restrict the initial `peek` action to `SslBump1`, use
client-requested `ssl::server_name` at `SslBump2`, bump only the exact
`release-assets.githubusercontent.com` hostname, and splice all other TLS
traffic. For bumped traffic, Squid MUST validate the origin certificate and
hostname against its system CA store. Cache freshness MUST continue honoring
origin `private`, `no-store`, and explicit expiry directives.

#### Scenario: Non-release TLS traffic preserves end-to-end trust

- **WHEN** a forge client connects to any TLS host other than the exact
  release-asset CDN hostname
- **THEN** Squid SHALL apply the terminal splice-all fallback
- **AND** the client SHALL retain end-to-end certificate and pinning decisions

#### Scenario: Signed redirect URL changes

- **WHEN** two GitHub redirects identify an asset with different signed query
  strings
- **THEN** the query strings SHALL remain distinct cache keys
- **AND** `strip_query_terms` SHALL hide them from logs only
- **AND** no StoreID normalization SHALL be introduced without fixture and
  real-Squid evidence that the mappings are content-identical

## Sources of Truth

- `cheatsheets/runtime/squid-cache-peer-routing.md` - Squid proxy and peer routing
- `cheatsheets/runtime/networking.md` - Network and localhost constraints
- `cheatsheets/security/owasp-top-10-2021.md` - TLS and trust failure handling
- https://www.squid-cache.org/Doc/config/ssl_bump/ - Squid 6 action ordering
- https://www.squid-cache.org/Doc/config/acl/ - `SslBump1` and SNI ACL semantics
- https://www.squid-cache.org/Doc/config/refresh_pattern/ - freshness and unsafe overrides
- https://www.squid-cache.org/Doc/config/store_id_program/ - StoreID correctness warning
