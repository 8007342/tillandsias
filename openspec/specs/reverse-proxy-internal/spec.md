<!-- @trace spec:reverse-proxy-internal -->

# reverse-proxy-internal Specification

## Status

active

## Purpose

Internal reverse proxy for routing enclave traffic with SSL termination, request/response logging, and caching. Sits between agents/web clients and enclave-internal services (forge containers, inference, git mirror). Certificates are ephemeral (tmpfs-based CA). Zero persistence, all state destroyed on shutdown.

This spec ensures:
- Centralized routing and access control
- SSL termination for internal HTTPS
- Transparent request/response logging
- Caching to reduce backend load
- Ephemeral operation (no disk footprint)

## Requirements

### Requirement: Enclave-internal routing

The reverse proxy MUST route all enclave-internal traffic (no external routing).

#### Scenario: Forge container routing
- **WHEN** a client connects to `reverse-proxy:443` requesting `/project/dev`
- **THEN** the proxy MUST route the request to the appropriate forge container (e.g., `tillandsias-myproject-foo:5000`)
- **AND** the routing table MUST be loaded from `/opt/routing-config/routes.toml` (baked into image)

#### Scenario: Inference service routing
- **WHEN** a client connects requesting `inference.tillandsias/v1/chat/completions`
- **THEN** the proxy MUST route to the inference container (e.g., `tillandsias-inference:11434`)
- **AND** the request MUST be forwarded with authentication (if required)

#### Scenario: Git mirror service routing
- **WHEN** a client connects requesting `git.tillandsias/my-repo.git`
- **THEN** the proxy MUST route to the git mirror container (e.g., `tillandsias-git:9418`)
- **AND** credentials MUST be handled via enclave-local authentication (no exposure to forge)

#### Scenario: Unknown route
- **WHEN** a request is made to a route not in the routing table
- **THEN** the proxy MUST return HTTP 404 or 503 (service unavailable)
- **AND** MUST log `route_not_found = true, requested_path = "/unknown"`

### Requirement: SSL termination with ephemeral CA

The proxy MUST terminate HTTPS connections using certificates issued by the ephemeral CA.

#### Scenario: Client HTTPS connection
- **WHEN** a client connects via TLS to the proxy (port 443)
- **THEN** the proxy MUST present a certificate issued by the ephemeral CA (see spec:certificate-authority)
- **AND** the certificate MUST cover the proxy's hostname (e.g., `internal-forge.tillandsias`, `inference.tillandsias`)

#### Scenario: CA certificate installation
- **WHEN** a forge container starts
- **THEN** the ephemeral CA's public certificate MUST be injected into the container
- **AND** the container MUST trust the CA for upstream proxy connections
- **AND** MUST be configured via env var `TILLANDSIAS_CA_BUNDLE=/tmp/ca/ca.crt`

#### Scenario: Certificate rotation on proxy restart
- **WHEN** the reverse-proxy container is stopped and restarted
- **THEN** a new certificate MUST be issued by the (new) ephemeral CA
- **AND** the old certificate MUST be destroyed
- **AND** clients MUST accept the new cert (or pinning MUST be updated)

### Requirement: Request/response logging

All traffic through the proxy MUST be logged in a structured format.

#### Scenario: Request log entry
- **WHEN** a request is received by the proxy
- **THEN** the proxy MUST log:
  ```
  timestamp = "2026-05-03T14:23:45.123Z"
  method = "GET"
  path = "/project/dev"
  status_code = 200
  response_time_ms = 45
  backend = "tillandsias-myproject-foo:5000"
  spec = "reverse-proxy-internal"
  ```
- **AND** the log MUST be written to stdout (captured by podman logs)

#### Scenario: Request headers logging
- **WHEN** a request includes custom headers
- **THEN** non-sensitive headers SHOULD be logged (User-Agent, Accept, etc.)
- **AND** sensitive headers (Authorization, Cookie) MUST be masked in logs
- **AND** logs MUST show `authorization_header = "[REDACTED]"`

#### Scenario: Response body logging
- **WHEN** the response body is small (< 1 KB)
- **THEN** the body SHOULD be logged verbatim
- **AND** large responses MUST be truncated to the first 1 KB with `...truncated` marker

### Requirement: Caching for performance

The proxy SHOULD cache responses to reduce backend load and latency.

#### Scenario: Cache key
- **WHEN** a cacheable request is received (GET, no cookies, Cache-Control: public)
- **THEN** the proxy MUST compute a cache key from method, path, and query string
- **AND** MUST check the cache (stored in tmpfs at `/tmp/proxy-cache/`)

#### Scenario: Cache hit
- **WHEN** a request matches a cached response and the response is fresh
- **THEN** the cached response MUST be returned immediately (no backend call)
- **AND** the response MUST include `X-Cache: HIT` header
- **AND** latency MUST be < 5 ms

#### Scenario: Cache miss
- **WHEN** a request is not in cache or is stale
- **THEN** the request MUST be forwarded to the backend
- **AND** the response SHOULD be cached (if cacheable)
- **AND** the response MUST include `X-Cache: MISS` header

#### Scenario: Cache invalidation
- **WHEN** a POST or PUT request is received
- **THEN** the proxy SHOULD invalidate related cache entries
- **AND** SHOULD log `cache_invalidation = true, pattern = "/project/*"`

#### Scenario: Cache size limit
- **WHEN** the cache reaches 500 MB
- **THEN** least-recently-used (LRU) entries MUST be evicted
- **AND** the proxy MUST log `cache_eviction = true, reason = "size limit"`

### Requirement: Ephemeral cache and state

Cache and all proxy state MUST be stored in tmpfs and MUST be destroyed on shutdown.

#### Scenario: Cache in tmpfs
- **WHEN** responses are cached
- **THEN** the cache MUST be stored in `/tmp/proxy-cache/` (tmpfs)
- **AND** MUST survive for the container's lifetime
- **AND** MUST be destroyed on container exit

#### Scenario: No cache persistence
- **WHEN** the proxy container stops and is removed
- **THEN** all cached responses MUST be destroyed
- **AND** the next proxy instance MUST have an empty cache
- **AND** MUST re-fetch all resources from backends

#### Scenario: Log file cleanup
- **WHEN** the proxy container exits
- **THEN** request/response logs MUST be deleted (not persisted to disk)
- **AND** only summary statistics SHOULD remain in the tray's logs

### Requirement: Access control and authentication

The proxy SHOULD enforce authentication and authorization for upstream services.

#### Scenario: Git service authentication
- **WHEN** a client requests `/git/...` (git mirror)
- **THEN** the proxy SHOULD check credentials (via HTTP Basic Auth or Bearer token)
- **AND** MUST forward credentials to the git service (if required)
- **AND** SHOULD log `authentication_required = true, service = "git"`

#### Scenario: Credential passthrough
- **WHEN** a forge container makes an authenticated request to inference
- **THEN** the proxy MUST forward the request with the container's credentials
- **AND** credentials MUST NOT be logged or exposed to the host

#### Scenario: Unauthorized access
- **WHEN** a request lacks required credentials
- **THEN** the proxy MUST return HTTP 401 or 403
- **AND** SHOULD log `access_denied = true, reason = "missing credentials"`

### Requirement: Litmus test — reverse-proxy-internal lifecycle

Critical verification paths:

#### Test: Routing to forge container
```bash
# Start reverse-proxy and forge
podman run --rm -d --name test-reverse-proxy tillandsias-reverse-proxy \
  reverse-proxy --config=/opt/routing-config/routes.toml

podman run --rm -d --name test-forge --network=tillandsias-enclave tillandsias-forge \
  python3 -m http.server 5000

sleep 2

# Make request through proxy
curl -k https://reverse-proxy/forge/health 2>&1
# Expected: HTTP 200 (routed to forge)

podman stop test-reverse-proxy test-forge
```

#### Test: SSL termination
```bash
# Start proxy
podman run --rm -d --name test-proxy-ssl tillandsias-reverse-proxy

sleep 2

# Connect with TLS and verify certificate
openssl s_client -connect reverse-proxy:443 </dev/null 2>&1 | grep -i "issuer"
# Expected: issuer shows "CN=Tillandsias Ephemeral CA" or similar

# Verify cert is not from system CA
openssl s_client -connect reverse-proxy:443 </dev/null 2>&1 | grep -i "verify error"
# Expected: verification error (self-signed ephemeral CA)

podman stop test-proxy-ssl
```

#### Test: Request logging
```bash
# Start proxy
podman run --rm -d --name test-proxy-logs tillandsias-reverse-proxy

sleep 2

# Make requests
curl -k https://reverse-proxy/test 2>&1 | head -1

# Check logs
podman logs test-proxy-logs 2>&1 | grep -i "method.*GET\|status_code"
# Expected: log lines with method, path, status_code

podman stop test-proxy-logs
```

#### Test: Caching
```bash
# Start proxy and mock backend
podman run --rm -d --name test-proxy-cache tillandsias-reverse-proxy

sleep 2

# Make first request (cache miss)
curl -k -w "Cache: %{http_header{x-cache}}\n" https://reverse-proxy/data 2>&1
# Expected: Cache: MISS

# Make second request (cache hit)
curl -k -w "Cache: %{http_header{x-cache}}\n" https://reverse-proxy/data 2>&1
# Expected: Cache: HIT (if response is cacheable)

podman stop test-proxy-cache
```

#### Test: Cache in tmpfs
```bash
# Start proxy
podman run --rm -d --name test-cache-tmpfs tillandsias-reverse-proxy

sleep 2

# Make requests to populate cache
curl -k https://reverse-proxy/data >/dev/null 2>&1

# Verify cache directory exists
podman exec test-cache-tmpfs ls -la /tmp/proxy-cache/
# Expected: directory with cached files

# Stop proxy
podman stop test-cache-tmpfs

# Start fresh proxy
podman run --rm -d --name test-cache-tmpfs tillandsias-reverse-proxy

sleep 2

# Verify cache is empty
podman exec test-cache-tmpfs ls /tmp/proxy-cache/ 2>&1
# Expected: empty or no directory (fresh cache)

podman stop test-cache-tmpfs
```

#### Test: Ephemeral state cleanup
```bash
# Run proxy
podman run --rm -d --name test-proxy-cleanup tillandsias-reverse-proxy

sleep 3

# Verify tmpfs directories exist
podman exec test-proxy-cleanup df /tmp/proxy-cache /tmp/ca
# Expected: tmpfs mounts visible

# Stop proxy
podman stop test-proxy-cleanup

# Verify state is destroyed
podman run --rm --name test-check tillandsias-reverse-proxy \
  ls -la /tmp/proxy-cache /tmp/ca 2>&1
# Expected: empty or no files (fresh start)
```

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Reverse proxy state is temporary; routing rules don't leak between containers
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:reverse-proxy-internal" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "reverse-proxy-internal"` on all proxy events
- `method = "<HTTP method>"` on each request
- `path = "<path>"` on each request
- `backend = "<container:port>"` on routing decision
- `status_code = N` on response
- `response_time_ms = N` on response completion
- `cache_hit = true|false` on cache decision
- `cache_eviction = true` on LRU cleanup
- `authorization_required = true` on auth check

## Sources of Truth

- `cheatsheets/runtime/networking.md` — enclave-internal routing and DNS patterns
- `cheatsheets/observability/cheatsheet-metrics.md` — structured logging for request/response events
- `cheatsheets/runtime/forge-hot-cold-split.md` — caching strategies and performance optimization

**Related Specs:**
- `spec:certificate-authority` — ephemeral CA for HTTPS termination used by this proxy

