<!-- @trace spec:proxy-container -->
# proxy-container Specification

## Status

active

## Purpose

Caching HTTP/HTTPS forward proxy with a domain allowlist that mediates external
traffic from forge containers. It is Alpine-based with Squid and a bounded 4GiB
disk cache. HTTPS interception is deliberately exceptional: the proxy bumps
only the exact GitHub release-asset CDN hostname and splices all other TLS
traffic end to end.

## Requirements
### Requirement: Caching HTTP/HTTPS proxy with ssl-bump MITM architecture
The system SHALL build and run a `tillandsias-proxy` container that provides a
caching HTTP/HTTPS proxy service. The proxy SHALL use Squid configured with
ssl-bump on both ports, using an ephemeral intermediate CA certificate for
dynamic server certificate generation. The ssl-bump policy SHALL peek only at
`SslBump1`, make its terminal decision at `SslBump2`, bump only
`release-assets.githubusercontent.com`, and splice every other destination.
The proxy cache SHALL be a bounded 4GiB disk cache stored in a persistent
volume, with a 2GiB per-object ceiling so the observed ~1.44GiB Ollama release
asset is eligible for storage.

@trace spec:proxy-container

#### Scenario: HTTP request to allowlisted domain
- **WHEN** a container sends an HTTP request to `registry.npmjs.org` through port 3128
- **THEN** the proxy SHALL forward the request and cache the response
- **AND** log the request via `--log-proxy` with domain, size, and cache status

#### Scenario: HTTPS request to the exact release-asset CDN
- **WHEN** a container follows a GitHub release redirect to
  `release-assets.githubusercontent.com`
- **THEN** Squid SHALL peek only at `SslBump1` to obtain ClientHello/SNI
- **AND** bump the connection at `SslBump2`
- **AND** validate the origin certificate and hostname against the system CA
- **AND** cache the response only when standard HTTP response semantics permit

#### Scenario: HTTPS request to any other allowlisted domain
- **WHEN** a container sends an HTTPS request to `crates.io` through port 3128
- **THEN** the proxy SHALL peek at the TLS ClientHello to read the SNI
- **AND** splice (tunnel) the connection to the origin without decryption
- **AND** log the domain via `--log-proxy`
- **AND** the HTTPS response SHALL NOT be cached (tunneled traffic is opaque to squid)

#### Scenario: Request to non-allowlisted domain blocked (port 3128)
- **WHEN** a container sends a request to `evil.example.com` through port 3128
- **THEN** the proxy SHALL deny the request with HTTP 403
- **AND** log the denied domain prominently via `--log-proxy`

#### Scenario: Cache hit under an identical cache key
- **WHEN** a container requests a cacheable HTTP resource or an identical
  release-asset HTTPS URL previously downloaded by another container
- **THEN** the proxy SHALL serve the cached copy without contacting the origin
- **AND** log the cache hit via `--log-proxy`
- **AND** a changed signed query string SHALL remain a distinct cache key unless
  a separately verified StoreID policy is introduced

### Requirement: Ephemeral CA chain (per-launch generation)
The system SHALL generate a fresh two-level CA chain on every proxy launch. The chain SHALL consist of a self-signed Root CA and an Intermediate CA signed by the root, both using EC P-256 keys. All key material SHALL be stored on tmpfs (`$XDG_RUNTIME_DIR/tillandsias/proxy-certs/`) and SHALL be destroyed when the session ends (logout/reboot). No CA keys SHALL persist to disk.

@trace spec:proxy-container

#### Files generated
| File | Purpose | Lifetime |
|------|---------|----------|
| `root.crt` | Root CA certificate, injected into forge containers for trust | Session (tmpfs) |
| `intermediate.crt` | Intermediate CA cert, used by squid for ssl-bump | Session (tmpfs) |
| `intermediate.key` | Intermediate CA private key, mode 0600 | Session (tmpfs) |
| `ca-chain.crt` | Concatenated chain (intermediate + root), for client trust | Session (tmpfs) |

#### Scenario: Cert generation on proxy launch
- **WHEN** `ensure_proxy_running` is called
- **THEN** `generate_ephemeral_certs()` SHALL create root + intermediate CA certs on tmpfs
- **AND** the intermediate cert/key SHALL be bind-mounted into the proxy container at `/etc/squid/certs/`
- **AND** the operation SHALL complete in under 10ms (EC P-256 key generation)

#### Scenario: Cert rotation on restart
- **WHEN** the proxy container is restarted (e.g., version upgrade)
- **THEN** a completely new CA chain SHALL be generated
- **AND** the old chain SHALL be overwritten on tmpfs
- **AND** running forge containers SHALL continue working until restarted (they hold the old chain in memory)

#### Scenario: Session end destroys all key material
- **WHEN** the user logs out or reboots
- **THEN** all CA files on tmpfs SHALL be destroyed by the OS
- **AND** no CA keys SHALL remain on any persistent storage

### Requirement: Dual-port architecture
The proxy SHALL listen on two ports with different access policies. Both ports SHALL have ssl-bump configured (same intermediate CA cert/key). The port determines which ACL rules apply.

@trace spec:proxy-container

| Port | Name | Domain policy | SSL bump | Use case |
|------|------|---------------|----------|----------|
| 3128 | Strict | Allowlisted domains only | Exact release-asset host only; splice otherwise | Runtime forge containers |
| 3129 | Permissive | All domains allowed | Exact release-asset host only; splice otherwise | Reserved for future use |

#### Scenario: Port 3128 strict filtering
- **WHEN** a forge container sends a request through port 3128
- **THEN** only domains matching `allowlist.txt` SHALL be permitted
- **AND** all other domains SHALL be denied with HTTP 403

#### Scenario: Port 3129 permissive access
- **WHEN** a request is sent through port 3129
- **THEN** all domains on SSL ports (443, 8443) SHALL be permitted
- **AND** domain filtering SHALL NOT apply

### Requirement: Image builds bypass the proxy
Container image builds (via `build-image.sh`) SHALL NOT route through the proxy.
Build containers run outside the enclave network and do not have the ephemeral
CA chain installed. Because ssl-bump is active for the exact release-asset CDN,
build containers would reject that proxy-issued certificate. Only runtime
containers (forge, terminal) have the CA chain injected.

@trace spec:proxy-container

#### Scenario: Image build without proxy
- **WHEN** `build-image.sh forge` is run
- **THEN** the build SHALL fetch packages directly from the internet, not through the proxy
- **AND** no `HTTP_PROXY` or `HTTPS_PROXY` environment variables SHALL be set

#### Scenario: Degraded mode (proxy unavailable)
- **WHEN** the proxy fails to start during infrastructure setup
- **THEN** forge image builds SHALL still succeed (they bypass the proxy)
- **AND** the tray SHALL notify the user of degraded mode

### Requirement: CA chain injection into forge containers
Runtime containers (forge, terminal) SHALL have the ephemeral CA chain bind-mounted once. The shared rootless initializer SHALL incorporate it into the image's system-default bundle before clients start. This enables these containers to trust the proxy's dynamically generated server certificates without per-client CA path overrides.

@trace spec:proxy-container

#### Injection mechanism
| Mount/Image path | Value | Consumer |
|------------------|-------|----------|
| Bind mount | `ca-chain.crt` -> `/run/tillandsias/ca-chain.crt:ro` | Shared initializer |
| Immutable image path | `/usr/local/share/tillandsias/vendor-ca-bundle.crt` | Shared initializer |
| Fedora system-default bundle | `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` -> `/run/tillandsias/ca-bundle.crt` | Git, curl, Node system-CA mode, Python/Requests |

#### Scenario: Forge container trusts proxy CA
- **WHEN** a forge container is launched
- **THEN** the launcher SHALL add only the CA chain bind-mount
- **AND** `lib-common.sh` SHALL initialize the system-default bundle atomically
- **AND** tools inside the container SHALL be able to verify certificates signed by the ephemeral intermediate CA

### Requirement: Generous developer-focused domain allowlist
The proxy SHALL include a built-in allowlist (`images/proxy/allowlist.txt`) covering web, mobile, and cloud development ecosystems. The allowlist SHALL be comprehensive enough that common development workflows (npm install, cargo build, pip install, flutter pub get) work out of the box without configuration. The allowlist applies only to port 3128 (strict).

@trace spec:proxy-container

#### Allowlist categories
| Category | Examples |
|----------|----------|
| Package registries | npmjs.org, crates.io, pypi.org, rubygems.org, pub.dev, nuget.org, maven.org, hex.pm |
| CDNs / package hosting | jsdelivr.net, unpkg.com, esm.sh |
| Language/framework tools | nodejs.org, rustup.rs, go.dev, dart.dev, flutter.dev |
| VCS (git dependencies) | github.com, gitlab.com, bitbucket.org, sr.ht, codeberg.org |
| Cloud SDKs | amazonaws.com, azure.com, googleapis.com, cloudflare.com |
| AI/ML | ollama.com, huggingface.co, openai.com, anthropic.com |
| AI search/tools | exa.ai, tavily.com, serper.dev, brave.com, perplexity.ai |
| Documentation | docs.rs, stackoverflow.com, readthedocs.io, mozilla.org |
| Security/certificates | letsencrypt.org, digicert.com, pki.goog |
| Container/OS | docker.io, ghcr.io, quay.io, fedoraproject.org, alpine-linux.org |

#### Format
One domain per line, prefixed with `.` to match the domain and all subdomains. Subdomain duplicates of already-listed domains MUST NOT appear (squid 6.x treats these as fatal errors).

#### Scenario: npm install works through proxy
- **WHEN** a forge container runs `npm install` with `HTTP_PROXY` pointing to port 3128
- **THEN** all npm registry requests SHALL be allowed and packages SHALL install successfully

#### Scenario: cargo build works through proxy
- **WHEN** a forge container runs `cargo build` with `HTTPS_PROXY` pointing to port 3128
- **THEN** all crates.io requests SHALL be allowed and dependencies SHALL download successfully

#### Scenario: Unknown domain denied with clear message
- **WHEN** a request to an unlisted domain is denied on port 3128
- **THEN** the proxy response SHALL include the blocked domain name for debugging

### Requirement: SSL bump policy is step-aware and narrowly selective
The ssl-bump policy SHALL use an `at_step SslBump1` ACL so `peek` runs only
once. At `SslBump2`, Squid SHALL use the client-requested
`ssl::server_name` and bump only the exact hostname
`release-assets.githubusercontent.com`. The terminal fallback SHALL be
`ssl_bump splice all`. Broad suffixes such as `.githubusercontent.com`,
package registries, provider endpoints, and authentication domains MUST NOT
enter the bump ACL.

@trace spec:proxy-container, spec:transparent-https-caching,
spec:security-privacy-isolation

This order is semantic, not cosmetic: Squid 6 evaluates every rule at every
SSL-bump step and applies the first possible match. `ssl_bump peek all` would
match at `SslBump2` as well and usually preclude bumping later.

#### Scenario: Exact release-asset host is bumped

- **WHEN** ClientHello SNI is exactly
  `release-assets.githubusercontent.com`
- **THEN** the `SslBump1` peek SHALL expose SNI
- **AND** the exact-host bump rule SHALL terminate the decision at `SslBump2`
- **AND** Squid SHALL generate a leaf certificate from the ephemeral
  intermediate CA
- **AND** Squid SHALL verify origin TLS before forwarding plaintext HTTP

#### Scenario: TLS-sensitive and non-allowlisted hosts remain end-to-end

- **WHEN** ClientHello SNI is `github.com`, `api.github.com`,
  `objects.githubusercontent.com`, a package registry, or a provider/auth host
- **THEN** the exact release-asset ACL SHALL NOT match
- **AND** `ssl_bump splice all` SHALL preserve client-to-origin TLS and pinning

### Requirement: Release-asset caching preserves origin semantics
The release-asset refresh rule SHALL be scoped to the exact HTTPS hostname and
checked before Squid's conservative defaults. It MAY provide bounded heuristic
freshness when the origin omits an explicit lifetime, but MUST NOT use
`override-expire`, `ignore-no-store`, `ignore-private`, or `ignore-reload`.
Signed query terms SHALL remain out of logs. They SHALL remain part of the
cache key: `strip_query_terms` is log privacy only, and no StoreID or URL
rewriter may normalize them without separate fixture and live proof that two
keys are content-identical.

#### Scenario: Origin marks an asset private or no-store
- **WHEN** the release-asset response contains `Cache-Control: private` or
  `Cache-Control: no-store`
- **THEN** Squid SHALL honor that directive
- **AND** the refresh pattern SHALL NOT force the response into shared cache

#### Scenario: A later redirect yields a different signed URL
- **WHEN** the release redirect produces a different query string
- **THEN** Squid SHALL treat it as a different cache key
- **AND** the system SHALL NOT claim a HIT until a real Squid fixture or live
  trace demonstrates stable keys and a repeated `TCP_HIT`

### Requirement: Upstream TLS verification
The proxy SHALL verify upstream (origin) server certificates against the system CA store when connecting to origin servers. TLS options SHALL enforce minimum TLS 1.2 with strong ciphers.

@trace spec:proxy-container

#### Scenario: Upstream TLS connection
- **WHEN** the proxy connects to an origin HTTPS server
- **THEN** it SHALL use TLS 1.2+ with `HIGH:!aNULL:!MD5` ciphers
- **AND** it SHALL verify against `/etc/ssl/certs/ca-certificates.crt`
- **AND** neither `DONT_VERIFY_PEER` nor `DONT_VERIFY_DOMAIN` SHALL be active

### Requirement: Proxy container image versioned and built via pipeline
The proxy container image SHALL be tagged as `tillandsias-proxy:v{FULL_VERSION}` and built via the existing `build-image.sh` pipeline. The image SHALL be Alpine-based with squid + SSL support installed. The Containerfile and configuration SHALL be stored in `images/proxy/`.

@trace spec:proxy-container

#### Scenario: Proxy image build
- **WHEN** `build-image.sh proxy` is run
- **THEN** the system SHALL build `tillandsias-proxy:v{FULL_VERSION}` from `images/proxy/Containerfile`

#### Scenario: Proxy image contents
- **WHEN** the proxy image is built
- **THEN** it SHALL contain: squid (with SSL/ssl-bump support), openssl, bash, ca-certificates
- **AND** it SHALL expose ports 3128 and 3129
- **AND** it SHALL run as non-root user `proxy` (UID 1000)

### Requirement: Proxy container lifecycle management
The proxy container SHALL be started automatically as part of infrastructure setup (before any forge containers). It SHALL be shared across all projects. It SHALL be version-checked and auto-restarted if running a stale image version. It SHALL be stopped on application exit.

@trace spec:proxy-container

#### Scenario: Proxy auto-start on infrastructure setup
- **WHEN** `ensure_infrastructure_ready` is called and the proxy is not running
- **THEN** the system SHALL build the proxy image if absent
- **AND** generate an ephemeral CA chain
- **AND** start the proxy container with CA cert/key bind-mounted
- **AND** connect it to both the enclave network (alias `proxy`) and the default podman network

#### Scenario: Proxy version check on startup
- **WHEN** a proxy container is already running
- **THEN** the system SHALL inspect its image tag
- **AND** if the tag does not match the current `proxy_image_tag()`, stop and restart with the correct version

#### Scenario: Proxy stop on app exit
- **WHEN** the Tillandsias application exits
- **THEN** the system SHALL stop the proxy container

### Requirement: Proxy request telemetry
All proxy requests SHALL be logged to the `--log-proxy` accountability window. Logs SHALL include domain, request size, allow/deny status, and cache hit/miss. No request content or credentials SHALL appear in logs. Squid access logs go to stdout, cache logs to stderr, for container log capture.

@trace spec:proxy-container

#### Scenario: Allowed request logged
- **WHEN** a request to an allowlisted domain is proxied
- **THEN** the system SHALL log `[proxy] ALLOW <domain> (<size>) [cache: HIT|MISS]` with `@trace spec:proxy-container`

#### Scenario: Denied request logged prominently
- **WHEN** a request to a non-allowlisted domain is denied
- **THEN** the system SHALL log `[proxy] DENY <domain>` with `@trace spec:proxy-container`
- **AND** the log entry SHALL be at WARN level for visibility

### Requirement: Privacy and identity
The proxy SHALL delete the `Forwarded` (and `X-Forwarded-For`) header from outgoing requests and disable the `Via` header. Origin servers SHALL not be able to determine that requests are proxied or identify the client.

@trace spec:proxy-container

#### Scenario: No forwarding headers
- **WHEN** a request is sent through the proxy to an origin server
- **THEN** the `Forwarded` / `X-Forwarded-For` header SHALL be absent
- **AND** the `Via` header SHALL be absent

### Requirement: Allowlist covers OpenCode's default egress footprint

The domain allowlist (`/etc/squid/allowlist.txt`, sourced from `images/proxy/allowlist.txt`) SHALL include every external domain that OpenCode Web reaches in its default configuration. At minimum the allowlist MUST contain `.models.dev` (OpenCode model registry), `.openrouter.ai` (OpenRouter aggregation gateway), and `.helicone.ai` (Helicone telemetry / gateway), in addition to the provider domains already listed (`.anthropic.com`, `.openai.com`, `.together.ai`, `.groq.com`, `.deepseek.com`, `.mistral.ai`, `.fireworks.ai`, `.cerebras.ai`, `.sambanova.ai`, `.huggingface.co`). New providers added to OpenCode MUST have their domains added to the allowlist in the same commit that introduces the provider.

#### Scenario: models.dev is allowed
- **WHEN** a forge container issues `CONNECT models.dev:443` via the proxy
- **THEN** Squid matches `.models.dev` in the allowlist
- **AND** responds with `TCP_TUNNEL/200` (not `TCP_DENIED`)

#### Scenario: OpenRouter is allowed
- **WHEN** a forge container issues `CONNECT openrouter.ai:443` or
  `CONNECT api.openrouter.ai:443`
- **THEN** Squid matches `.openrouter.ai` in the allowlist
- **AND** the CONNECT tunnel is established

### Requirement: Allowlist entries follow Squid 6.x single-entry rule

Every allowlist entry SHALL be listed exactly once and SHALL use the
leading-dot form (`.example.com`). Bare-domain duplicates of an already-listed
subdomain pattern are prohibited because Squid 6.x treats duplicate dstdomain
entries as a fatal startup error.

#### Scenario: Proxy starts with no duplicate dstdomain errors
- **WHEN** the proxy container boots
- **THEN** Squid parses `allowlist.txt` without emitting
  `FATAL: duplicate key "..."` for any entry
- **AND** the proxy listens on port 3128 ready to serve the enclave

#### Scenario: Adding a new provider appends one line
- **WHEN** an engineer adds a new provider to OpenCode's default config
- **THEN** they add one `.provider.example` line to `allowlist.txt`
- **AND** do NOT add a bare `provider.example` alongside
- **AND** the change is reviewed against the existing list to avoid subdomain
  duplicates of already-covered domains

### Requirement: Forward proxy recognises `*.localhost` as enclave-internal

The Squid proxy SHALL allow `*.localhost` destinations and forward
them to a sibling reverse-proxy container at `router:80` instead of
attempting external resolution.

This lets forge agents run `curl http://<project>.<service>.localhost/`
through their existing `HTTP_PROXY=http://proxy:3128` and reach
enclave-local services without any client-side configuration.

`*.localhost` MUST never be forwarded externally — by RFC 6761 these
hostnames are loopback-only, and a leak past the proxy to an external
DNS server would itself be a violation. The Squid config MUST contain
both an `acl localhost_subdomain dstdomain .localhost` and a
`cache_peer router parent 80 0` directive (or equivalent), with
`cache_peer_access router allow localhost_subdomain` and
`never_direct allow localhost_subdomain`.

#### Scenario: Forge agent reaches enclave service through proxy
- **WHEN** an agent inside a forge container runs
  `curl http://my-project.flutter.localhost/`
- **THEN** the request SHALL go to `proxy:3128` (forward proxy)
- **AND** Squid SHALL forward the request to `router:80` (reverse
  proxy peer)
- **AND** the router SHALL route to the right container at the right
  internal port
- **AND** the agent SHALL receive the dev server's response

#### Scenario: External `.localhost` resolution attempt is denied
- **WHEN** Squid receives a `.localhost` request and the router peer
  is unreachable
- **THEN** Squid SHALL return an error response, NOT fall through to
  external DNS resolution
- **AND** no `*.localhost` lookup SHALL ever leave the host

## Security implications and trust model

### What the proxy CAN do (architecturally)
- Read SNI from HTTPS ClientHello messages after the step-1 peek
- Block connections to non-allowlisted domains (port 3128)
- Decrypt, cache when HTTP permits, and re-encrypt traffic only for the exact
  `release-assets.githubusercontent.com` host
- Generate dynamic server certificates trusted by forge containers (via injected CA chain)

### What the proxy DOES NOT do (current policy)
- Decrypt GitHub/API/provider/auth/package-registry traffic outside the exact
  release-asset CDN host
- Override `private`/`no-store`/origin expiry directives
- Normalize signed query strings or assume different redirect URLs share content
- Store or exfiltrate credentials

### Trust boundaries
1. **Forge containers trust the proxy CA**: the CA chain is bind-mounted and
   incorporated into the system-default bundle. Therefore the proxy MUST verify
   the real release-asset origin; `DONT_VERIFY_*` is forbidden.
2. **Proxy has no credentials**: it cannot authenticate to any service on behalf of forge containers.
3. **Key material is ephemeral**: all CA keys live on tmpfs and die with the session. There is no persistent CA that could be compromised across reboots.
4. **Image builds are outside the trust boundary**: they fetch packages directly, never through the proxy.

## Sources of Truth

- `cheatsheets/runtime/networking.md` — Networking reference and patterns
- `cheatsheets/web/http.md` — Http reference and patterns
- https://www.squid-cache.org/Doc/config/ssl_bump/ — Squid 6 rule evaluation and actions
- https://www.squid-cache.org/Doc/config/acl/ — `at_step` and `ssl::server_name`
- https://www.squid-cache.org/Doc/config/refresh_pattern/ — first-match freshness semantics and unsafe overrides
- https://www.squid-cache.org/Doc/config/strip_query_terms/ — log-only query privacy
- https://docs.github.com/en/rest/releases/assets — release asset identity and replacement API

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation`
- `litmus:proxy-container-shape`
- `cargo test -p tillandsias-headless --test proxy_cache_policy`

Gating points:
- Proxy enforces network isolation; no unauthorized egress
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:proxy-container" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
