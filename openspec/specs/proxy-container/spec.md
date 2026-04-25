# proxy-container Specification

## Purpose

Caching HTTP/HTTPS forward proxy with domain allowlist that mediates all external traffic from forge containers. Alpine-based with squid, ~500MB disk cache. Uses ssl-bump MITM infrastructure with an ephemeral CA chain for HTTPS handling. Currently operates in splice-all mode (passthrough, no decryption) but the architecture supports selective per-domain interception for HTTPS content caching.
## Requirements
### Requirement: Caching HTTP/HTTPS proxy with ssl-bump MITM architecture
The system SHALL build and run a `tillandsias-proxy` container that provides a caching HTTP/HTTPS proxy service. The proxy SHALL use squid configured with ssl-bump on all ports, using an ephemeral intermediate CA certificate for dynamic server certificate generation. The ssl-bump policy SHALL default to splice-all (passthrough): squid peeks at the TLS ClientHello to read the SNI for domain filtering, then splices (tunnels) the connection without decryption. The proxy cache SHALL be ~500MB disk-based, stored in a persistent volume.

**Current operating mode**: splice-all. Squid reads SNI for domain filtering but does NOT decrypt TLS traffic. The MITM infrastructure (certs, sslcrtd, dynamic cert generation) is fully deployed but dormant. One configuration change (`ssl_bump bump bump_domains` replacing `ssl_bump splice all`) would enable active interception for selected domains.

@trace spec:proxy-container

#### Scenario: HTTP request to allowlisted domain
- **WHEN** a container sends an HTTP request to `registry.npmjs.org` through port 3128
- **THEN** the proxy SHALL forward the request and cache the response
- **AND** log the request via `--log-proxy` with domain, size, and cache status

#### Scenario: HTTPS request to allowlisted domain (splice-all mode)
- **WHEN** a container sends an HTTPS request to `crates.io` through port 3128
- **THEN** the proxy SHALL peek at the TLS ClientHello to read the SNI
- **AND** splice (tunnel) the connection to the origin without decryption
- **AND** log the domain via `--log-proxy`
- **AND** the HTTPS response SHALL NOT be cached (tunneled traffic is opaque to squid)

#### Scenario: Request to non-allowlisted domain blocked (port 3128)
- **WHEN** a container sends a request to `evil.example.com` through port 3128
- **THEN** the proxy SHALL deny the request with HTTP 403
- **AND** log the denied domain prominently via `--log-proxy`

#### Scenario: Cache hit (HTTP only in splice-all mode)
- **WHEN** a container requests an HTTP resource previously downloaded by another container
- **THEN** the proxy SHALL serve the cached copy without contacting the origin
- **AND** log the cache hit via `--log-proxy`

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
| 3128 | Strict | Allowlisted domains only | Enabled (splice-all) | Runtime forge containers |
| 3129 | Permissive | All domains allowed | Enabled (splice-all) | Reserved for future use |

#### Scenario: Port 3128 strict filtering
- **WHEN** a forge container sends a request through port 3128
- **THEN** only domains matching `allowlist.txt` SHALL be permitted
- **AND** all other domains SHALL be denied with HTTP 403

#### Scenario: Port 3129 permissive access
- **WHEN** a request is sent through port 3129
- **THEN** all domains on SSL ports (443, 8443) SHALL be permitted
- **AND** domain filtering SHALL NOT apply

### Requirement: Image builds bypass the proxy
Container image builds (via `build-image.sh`) SHALL NOT route through the proxy. Build containers run outside the enclave network and do not have the ephemeral CA chain installed. If ssl-bump were active, build containers would reject the MITM'd certificates because they lack the CA trust anchor. Only runtime containers (forge, terminal) have the CA chain injected.

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
Runtime containers (forge, terminal) SHALL have the ephemeral CA chain bind-mounted and trust environment variables set. This enables these containers to trust the proxy's dynamically generated server certificates if ssl-bump is activated in the future.

@trace spec:proxy-container

#### Injection mechanism
| Mount/Env | Value | Consumer |
|-----------|-------|----------|
| Bind mount | `ca-chain.crt` -> `/run/tillandsias/ca-chain.crt:ro` | All tools |
| `NODE_EXTRA_CA_CERTS` | `/run/tillandsias/ca-chain.crt` | Node.js (npm, yarn, pnpm) |
| `SSL_CERT_FILE` | `/etc/ssl/certs/ca-certificates.crt` | OpenSSL, Go, rustls |
| `REQUESTS_CA_BUNDLE` | `/etc/ssl/certs/ca-certificates.crt` | Python requests, pip |

#### Scenario: Forge container trusts proxy CA
- **WHEN** a forge container is launched
- **THEN** `inject_ca_chain_mounts()` SHALL add the CA chain bind-mount and trust env vars
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

### Requirement: SSL bump policy and future activation
The ssl-bump infrastructure SHALL be fully deployed but dormant by default. The current policy SHALL be splice-all (peek SNI, then tunnel without decryption). The configuration SHALL define three domain categories for future selective bumping.

@trace spec:proxy-container

#### Domain categories for ssl-bump policy

| Category | ACL name | Behavior (splice-all mode) | Behavior (selective bump mode) |
|----------|----------|---------------------------|-------------------------------|
| No-bump domains | `no_bump_domains` | Spliced (passthrough) | Spliced (passthrough) |
| Bump domains | `bump_domains` | Spliced (passthrough) | Bumped (MITM decryption + caching) |
| All other domains | (default) | Spliced (passthrough) | Spliced (passthrough) |

**No-bump domains** (NEVER intercepted, even if bumping is enabled): domains with certificate pinning, HSTS preload, or where interception would break functionality:
- `.google.com`, `.googleapis.com`, `.gstatic.com`
- `.microsoft.com`, `.azure.com`, `.azureedge.net`
- `.github.com`, `.githubusercontent.com`
- `.anthropic.com`, `.openai.com`

**Bump domains** (intercepted when selective bumping is enabled): package registries where HTTPS content caching provides the most benefit:
- `.npmjs.org`, `.npmjs.com`, `.yarnpkg.com`, `.crates.io`, `.rust-lang.org`
- `.pypi.org`, `.pythonhosted.org`, `.rubygems.org`, `.packagist.org`
- `.pub.dev`, `.nuget.org`, `.maven.org`, `.hex.pm`
- `.cocoapods.org`, `.cpan.org`, `.cran.r-project.org`
- `.hackage.haskell.org`, `.clojars.org`, `.opam.ocaml.org`
- `.jsdelivr.net`, `.unpkg.com`, `.esm.sh`
- `.nodejs.org`, `.golang.org`, `.go.dev`
- `.opencode.ai`

#### Current activation status: NEVER
Active ssl-bump interception is not enabled. The splice-all policy is hardcoded in `images/proxy/squid.conf`. Enabling selective bumping requires:
1. Solving non-root CA trust injection (forge containers run under `--cap-drop=ALL` so `update-ca-trust` fails)
2. Changing `ssl_bump splice all` to domain-selective bump rules in `squid.conf`
3. Verifying that `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars provide sufficient trust for all package managers

#### Scenario: Current mode (splice-all)
- **WHEN** any HTTPS request passes through the proxy
- **THEN** squid SHALL peek at the ClientHello to extract the SNI
- **AND** splice the connection (passthrough tunnel) without decryption
- **AND** no dynamic server certificates SHALL be generated by sslcrtd
- **AND** no HTTPS response content SHALL be cached

#### Scenario: Future selective bumping (not yet enabled)
- **WHEN** selective bumping is enabled and a request targets a bump_domain
- **THEN** squid SHALL generate a dynamic server certificate signed by the intermediate CA
- **AND** decrypt the HTTPS traffic, cache the response, and re-encrypt to the client
- **AND** the client SHALL trust the dynamic cert via the injected CA chain

### Requirement: Upstream TLS verification
The proxy SHALL verify upstream (origin) server certificates against the system CA store when connecting to origin servers. TLS options SHALL enforce minimum TLS 1.2 with strong ciphers.

@trace spec:proxy-container

**Current exception**: `DONT_VERIFY_PEER` is set in `tls_outgoing_options` for initial compatibility. Some registries use unusual CAs or certificate pinning that may need explicit trust anchors. This flag SHOULD be removed in production to enforce upstream certificate verification.

#### Scenario: Upstream TLS connection
- **WHEN** the proxy connects to an origin HTTPS server
- **THEN** it SHALL use TLS 1.2+ with `HIGH:!aNULL:!MD5` ciphers
- **AND** currently: it SHALL NOT verify the upstream certificate (`DONT_VERIFY_PEER`)
- **AND** future: it SHALL verify against `/etc/ssl/certs/ca-certificates.crt`

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
- Read SNI from all HTTPS ClientHello messages (peek step, always active)
- Block connections to non-allowlisted domains (port 3128)
- If bumping is enabled: decrypt, inspect, cache, and re-encrypt HTTPS traffic for bump_domains
- Generate dynamic server certificates trusted by forge containers (via injected CA chain)

### What the proxy DOES NOT do (current policy)
- Decrypt any HTTPS traffic (splice-all policy)
- Cache any HTTPS response content (tunneled traffic is opaque)
- Generate dynamic server certificates (sslcrtd is running but idle)
- Inspect request/response bodies
- Store or exfiltrate credentials

### Trust boundaries
1. **Forge containers trust the proxy CA**: the ca-chain.crt is bind-mounted and environment variables point package managers to it. This is a prerequisite for future ssl-bump, not a current risk.
2. **Proxy has no credentials**: it cannot authenticate to any service on behalf of forge containers.
3. **Key material is ephemeral**: all CA keys live on tmpfs and die with the session. There is no persistent CA that could be compromised across reboots.
4. **Image builds are outside the trust boundary**: they fetch packages directly, never through the proxy.
