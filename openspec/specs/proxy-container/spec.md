# proxy-container Specification

## Purpose

Caching HTTP/HTTPS proxy with domain allowlist that mediates all external traffic from forge containers. Alpine-based with squid, ~500MB disk cache, SNI-based HTTPS filtering (no TLS interception).

## Requirements

### Requirement: Caching HTTP/HTTPS proxy with domain allowlist
The system SHALL build and run a `tillandsias-proxy` container that provides a caching HTTP/HTTPS proxy service. The proxy SHALL use squid with a curated domain allowlist. HTTPS SHALL be handled transparently via CONNECT method with SNI-based domain filtering (no TLS interception). The proxy cache SHALL be ~500MB disk-based, stored in a persistent volume.

@trace spec:proxy-container

#### Scenario: HTTP request to allowlisted domain
- **WHEN** a container sends an HTTP request to `registry.npmjs.org` through the proxy
- **THEN** the proxy SHALL forward the request and cache the response
- **AND** log the request via `--log-proxy` with domain, size, and cache status

#### Scenario: HTTPS CONNECT to allowlisted domain
- **WHEN** a container sends an HTTPS request to `crates.io` through the proxy
- **THEN** the proxy SHALL allow the CONNECT tunnel via SNI inspection
- **AND** log the domain via `--log-proxy`

#### Scenario: Request to non-allowlisted domain blocked
- **WHEN** a container sends a request to `evil.example.com` through the proxy
- **THEN** the proxy SHALL deny the request with HTTP 403
- **AND** log the denied domain prominently via `--log-proxy`

#### Scenario: Cache hit
- **WHEN** a container requests a package previously downloaded by another container
- **THEN** the proxy SHALL serve the cached copy without contacting the origin
- **AND** log the cache hit via `--log-proxy`

### Requirement: Generous developer-focused domain allowlist
The proxy SHALL include a built-in allowlist covering web, mobile, and cloud development ecosystems. The allowlist SHALL be comprehensive enough that common development workflows (npm install, cargo build, pip install, flutter pub get) work out of the box without configuration.

@trace spec:proxy-container

#### Scenario: npm install works through proxy
- **WHEN** a forge container runs `npm install` with `HTTP_PROXY` pointing to the proxy
- **THEN** all npm registry requests SHALL be allowed and packages SHALL install successfully

#### Scenario: cargo build works through proxy
- **WHEN** a forge container runs `cargo build` with `HTTPS_PROXY` pointing to the proxy
- **THEN** all crates.io requests SHALL be allowed and dependencies SHALL download successfully

#### Scenario: Unknown domain denied with clear message
- **WHEN** a request to an unlisted domain is denied
- **THEN** the proxy response SHALL include the blocked domain name for debugging

### Requirement: Proxy container image versioned and built via pipeline
The proxy container image SHALL be tagged as `tillandsias-proxy:v{FULL_VERSION}` and built via the existing `build-image.sh` pipeline. The image SHALL be Alpine-based with squid installed. The Containerfile and configuration SHALL be stored in `images/proxy/`.

@trace spec:proxy-container

#### Scenario: Proxy image build
- **WHEN** `build-image.sh proxy` is run
- **THEN** the system SHALL build `tillandsias-proxy:v{FULL_VERSION}` from `images/proxy/Containerfile`

#### Scenario: Proxy image size
- **WHEN** the proxy image is built
- **THEN** it SHALL be under 30MB (Alpine + squid)

### Requirement: Proxy container lifecycle management
The proxy container SHALL be started automatically on first container launch and shared across all projects. It SHALL be health-checked periodically and auto-restarted if it crashes. It SHALL be stopped on application exit.

@trace spec:proxy-container

#### Scenario: Proxy auto-start on first launch
- **WHEN** a forge container is launched and the proxy is not running
- **THEN** the system SHALL start the proxy container before launching the forge

#### Scenario: Proxy health check
- **WHEN** the proxy container is running
- **THEN** the system SHALL verify it is responsive every 60 seconds via the event loop
- **AND** restart it if unresponsive

#### Scenario: Proxy stop on app exit
- **WHEN** the Tillandsias application exits
- **THEN** the system SHALL stop the proxy container

### Requirement: Proxy request telemetry
All proxy requests SHALL be logged to the `--log-proxy` accountability window. Logs SHALL include domain, request size, allow/deny status, and cache hit/miss. No request content or credentials SHALL appear in logs.

@trace spec:proxy-container

#### Scenario: Allowed request logged
- **WHEN** a request to an allowlisted domain is proxied
- **THEN** the system SHALL log `[proxy] ALLOW <domain> (<size>) [cache: HIT|MISS]` with `@trace spec:proxy-container`

#### Scenario: Denied request logged prominently
- **WHEN** a request to a non-allowlisted domain is denied
- **THEN** the system SHALL log `[proxy] DENY <domain>` with `@trace spec:proxy-container`
- **AND** the log entry SHALL be at WARN level for visibility
