# transparent-https-caching Specification

@trace spec:transparent-https-caching

<!-- freshness: auditor=macos-tlatoanis-macbook-air-fable5 date=2026-08-17 verdict=updated scope=cycle-26 audit — the spec owned the CA material but stated no confidentiality requirement for the PRIVATE key, the exact property 755-qcxh and 772-shi9 established in code and pins; requirement + scenario added from verified sources (images/proxy/entrypoint.sh secret-only + exit 1, PROXY_CA_KEY_SECRET_OPTS mode=0400, enforce_ca_key_mode 0600) -->

## Status

active

## Requirements

### Requirement: HTTPS cache interception uses generated CA material
<!-- req-id: 49ce05dd -->

Development and enclave proxy paths that enable HTTPS caching MUST generate or mount intermediate CA material before Squid starts SSL bumping traffic.

#### Scenario: Concurrent proxy startup cannot publish partial CA files

- **WHEN** multiple build or runtime flows attempt to prepare CA material at the same time
- **THEN** generation MUST be serialized
- **AND** consumers MUST see either the previous complete certificate/key pair or the new complete pair, never partial files

### Requirement: The intermediate CA private key is never world-readable
<!-- req-id: b036cfc1 -->

The interception CA's PRIVATE key MUST reach Squid only through a
confidential channel, and MUST NOT be readable by other local users at any
point in its lifetime. Any local uid that can read this key can mint
certificates every enclave client trusts, so a widened mode is a
trust-boundary break, not an inconvenience.

This requirement was learned twice and is written down so it is not learned
a third time: `755-qcxh` found the key world-readable in `/tmp`, and
`772-shi9` found two macOS guest preambles re-widening it to `0644` on every
login and cloud-project read, justified by a comment claiming Squid needed
it — a claim that had already been false since the secret channel landed.

#### Scenario: Squid receives the key as a confidential secret, not a mode-widened file

- **WHEN** the enclave proxy container starts
- **THEN** the key MUST arrive as a podman secret mounted `mode=0400` owned
  by the proxy uid, and the container entrypoint MUST refuse to start
  (non-zero exit) when that secret is absent — never fall back to reading a
  bind-mounted or world-readable copy
- **AND** no host or guest code path may `chmod` the key wider than `0600`
- **AND** a pre-existing widened key MUST be healed DOWN on the next ensure
  or diagnose pass, including on paths that skip generation because the key
  already exists

### Requirement: Runtime containers trust the Tillandsias proxy CA
<!-- req-id: 7bc09274 -->

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
<!-- req-id: 254c9eee -->

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
