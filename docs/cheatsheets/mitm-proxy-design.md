# MITM Proxy Design — Ephemeral CA Certificates for the Tillandsias Enclave

@trace spec:proxy-container

## Overview

This document designs a MITM (Man-in-the-Middle) proxy architecture for the Tillandsias enclave. The proxy currently uses SNI-based HTTPS filtering via CONNECT tunneling, which means HTTPS content cannot be cached -- only the domain is visible. By adding SSL bump (TLS interception) with ephemeral per-container CA certificates, we gain:

1. **HTTPS caching** -- npm, cargo, pip, and other package downloads served from disk on repeat installs
2. **Content inspection** -- deeper security controls beyond domain-only filtering
3. **Ephemeral trust** -- certificates born with a container, die with it, no persistent trust chain leakage
4. **Potential git commit signing** -- same CA infrastructure can sign commits for enclave provenance

@trace spec:proxy-container

---

## 1. Architecture

### Current State (SNI-Only)

```
forge ──CONNECT──> squid ──TLS tunnel──> registry.npmjs.org
                   ^                     ^
                   sees: domain only     squid sees: encrypted bytes
                   caches: nothing       client TLS terminates at origin
```

### Target State (SSL Bump)

```
forge ──HTTPS──> squid (decrypt, cache, re-encrypt) ──HTTPS──> registry.npmjs.org
                 ^                                              ^
                 terminates TLS from forge                      new TLS to origin
                 with ephemeral server cert                     squid sees plaintext
                 signed by container-specific                   caches response body
                 intermediate CA
```

### Full Enclave Topology with MITM

```
                          +------------------------------------------------------------+
                          |              tillandsias-enclave (--internal)               |
                          |                                                            |
  +----------+            |  +--------------------+  +----------+   +------------+     |
  |          |<--bridge---|  |      proxy         |  |   git    |   | inference  |     |
  | internet |            |  |  :3128 (strict)    |  | service  |   |  (ollama)  |     |
  |          |---bridge-->|  |  :3129 (permissive) |  |  mirror  |   |            |     |
  +----------+            |  |  ssl_bump enabled  |  +----^-----+   +------^-----+     |
                          |  |  sslcrtd running   |       |               |            |
                          |  +--------^-----------+       |               |            |
                          |           |                   |               |            |
                          |           | HTTPS (decrypted) | git://        | :11434     |
                          |           |                   |               |            |
                          |  +--------+-------------------+---------------+-------+    |
                          |  |                        forge                       |    |
                          |  |  trusts: container-specific intermediate CA        |    |
                          |  |  NO credentials, NO direct internet               |    |
                          |  +---------------------------------------------------+    |
                          |                                                            |
                          +------------------------------------------------------------+
                                          ^
                                          | bind-mount (CA cert, read-only)
                                          | D-Bus (git service only)
                                          v
                                 +------------------+
                                 |   host app       |
                                 |   (Tillandsias)  |
                                 |                  |
                                 |  Root CA key     |
                                 |  (keyring or     |
                                 |   secure file)   |
                                 +------------------+
```

@trace spec:proxy-container, spec:enclave-network

### Certificate Hierarchy

```
Root CA (Tillandsias)          <-- generated once, stored on host, long-lived (10 years)
  |
  +-- Intermediate CA          <-- per-container, short-lived (30 days max)
       (container-X)               generated at container launch, injected via bind-mount
       |
       +-- Server cert         <-- per-domain, generated on-the-fly by squid sslcrtd
            (registry.npmjs.org)   lives only in squid's in-memory cert cache
            (crates.io)
            (pypi.org)
            ...
```

---

## 2. Certificate Lifecycle

@trace spec:proxy-container

### Phase 1: Root CA Generation (One-Time)

**When**: First time Tillandsias launches (or on explicit user action).

**How**: The host Tillandsias binary generates a self-signed root CA certificate.

```
Tool: openssl (CLI) or rcgen (Rust crate)

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -days 3650 -nodes \
    -keyout tillandsias-root-ca.key \
    -out tillandsias-root-ca.crt \
    -subj "/O=Tillandsias/CN=Tillandsias Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
```

**Storage**:
- **Private key**: OS keyring (preferred) or `$XDG_DATA_HOME/tillandsias/ca/root.key` with mode 0600
- **Certificate**: `$XDG_DATA_HOME/tillandsias/ca/root.crt` (readable, not secret)

**Rotation**: Manual. Replacing the root CA invalidates all intermediate CAs. Should only happen if the root key is compromised or approaching expiry (~10 years).

### Phase 2: Intermediate CA Generation (Per-Container Launch)

**When**: Every time a container (forge, inference) is launched.

**How**: The host Tillandsias binary signs an intermediate CA cert using the root CA.

```
# Generate intermediate key + CSR
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -nodes -keyout intermediate.key -out intermediate.csr \
    -subj "/O=Tillandsias/CN=tillandsias-myapp-aeranthos"

# Sign with root CA (30-day validity, max)
openssl x509 -req -in intermediate.csr \
    -CA root.crt -CAkey root.key \
    -CAcreateserial -days 30 \
    -extfile <(echo "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign")  \
    -out intermediate.crt
```

**Delivery to proxy container**:
- Bind-mount `intermediate.crt` + `intermediate.key` into proxy at `/etc/squid/certs/`
- Read-only for the cert, read-only for the key (squid runs as `proxy` user)
- The proxy's `ssl_bump` config references these files

**Delivery to forge container** (trust injection):
- Bind-mount `ca-chain.crt` (root + intermediate) into forge at `/run/tillandsias/ca-chain.crt:ro`
- Podman env: `NODE_EXTRA_CA_CERTS=/run/tillandsias/ca-chain.crt` (Node.js adds to built-in trust)
- Entrypoint creates combined bundle: `cat $SYSTEM_CA $CA_CHAIN > /tmp/tillandsias-combined-ca.crt`
- Entrypoint exports `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` pointing to the combined bundle
- NOTE: `update-ca-trust` / `update-ca-certificates` cannot work under `--cap-drop=ALL` + `--userns=keep-id` (non-root, read-only system dirs). The combined bundle approach is the production path.

**Destruction**:
- Intermediate key lives only on the host in `$XDG_RUNTIME_DIR/tillandsias/certs/<container-name>/`
- This is tmpfs (RAM only), same pattern as token files
- Deleted when the container stops (same lifecycle as GitHub token files)

### Phase 3: Dynamic Server Certificates (Per-Domain, Squid-Generated)

**When**: Every HTTPS request through the proxy.

**How**: Squid's `security_file_certgen` (formerly `ssl_crtd`) dynamically generates server certificates signed by the intermediate CA. These certs exist only in squid's in-memory cache.

```
Request flow:
1. forge -> HTTPS request to registry.npmjs.org
2. squid peeks at the ClientHello SNI
3. squid connects to registry.npmjs.org, completes TLS, gets the real cert
4. squid calls sslcrtd to generate a fake cert for registry.npmjs.org
   signed by the intermediate CA, mimicking the real cert's Subject/SANs
5. squid presents this fake cert to forge
6. forge trusts it because the intermediate CA is in its trust store
7. squid decrypts, caches, re-encrypts, returns response to forge
```

### Lifecycle Summary Table

| Certificate | Generated by | Validity | Storage | Destroyed when |
|-------------|-------------|----------|---------|----------------|
| Root CA | Tillandsias host app | 10 years | Host keyring or `$XDG_DATA_HOME` | Manual rotation only |
| Intermediate CA | Tillandsias host app | 30 days | Host tmpfs (`$XDG_RUNTIME_DIR`) | Container stops |
| Server certs | Squid `sslcrtd` | Minutes | Squid in-memory cache | Squid stops |

@trace spec:proxy-container

---

## 3. Squid SSL Bump Configuration

@trace spec:proxy-container

### Alpine Squid Version

Alpine 3.20 ships **squid 6.9** (package `squid`). Squid 6.x fully supports `ssl_bump` with the `security_file_certgen` helper (renamed from `ssl_crtd` in 5.x). The Alpine package is built with `--enable-ssl-crtd` and OpenSSL support by default.

Additional Alpine packages needed: `squid-ssl` or `openssl` (for the certgen helper).

**Verification**: `squid -v 2>&1 | grep -i ssl` should show `--enable-ssl-crtd` and `--with-openssl`.

### Modified Containerfile

```dockerfile
# @trace spec:proxy-container
FROM docker.io/library/alpine:3.20

# squid + openssl for SSL bump support
# ca-certificates for upstream TLS verification
RUN apk add --no-cache squid squid-openssl openssl bash ca-certificates \
    && adduser -D -u 1000 -s /sbin/nologin proxy \
    && mkdir -p /var/spool/squid /var/log/squid /var/run/squid \
    && mkdir -p /var/lib/squid/ssl_db /etc/squid/certs \
    && chown -R proxy:proxy /var/spool/squid /var/log/squid /var/run/squid \
    && chown -R proxy:proxy /var/lib/squid/ssl_db

COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER proxy

EXPOSE 3128 3129

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### Modified entrypoint.sh

```bash
#!/bin/bash
set -e
# @trace spec:proxy-container
# Entrypoint for the Tillandsias MITM caching proxy container.

# Initialize cache structure if swap directories don't exist yet.
if [ ! -d /var/spool/squid/00 ]; then
    echo "Initializing squid cache directories..."
    squid -z -N 2>&1
    echo "Cache directories created."
fi

# Initialize SSL certificate database if not present.
# This is where sslcrtd stores dynamically generated server certificates.
if [ ! -d /var/lib/squid/ssl_db/certs ]; then
    echo "Initializing SSL certificate database..."
    /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16
    echo "SSL certificate database created."
fi

# Validate that the intermediate CA cert and key were injected.
if [ ! -f /etc/squid/certs/intermediate.crt ] || [ ! -f /etc/squid/certs/intermediate.key ]; then
    echo "ERROR: Intermediate CA cert/key not found at /etc/squid/certs/"
    echo "  The host must bind-mount these files at container launch."
    exit 1
fi

echo "========================================"
echo "  tillandsias proxy (ssl-bump enabled)"
echo "  strict:     :3128"
echo "  permissive: :3129"
echo "========================================"

exec squid -N
```

### Modified squid.conf (SSL Bump)

```squid
# @trace spec:proxy-container
# Squid forward proxy for Tillandsias enclave network.
#
# DUAL-PORT ARCHITECTURE with SSL BUMP:
#   Port 3128 — STRICT (runtime containers): allowlisted domains only, SSL bump
#   Port 3129 — PERMISSIVE (image builds): all domains allowed, SSL bump
#
# Both ports share the same disk cache. SSL bump enables HTTPS content caching.

# --- Listen (SSL Bump enabled on both ports) ---
# The intermediate CA cert/key are bind-mounted by the host at launch time.
http_port 3128 ssl-bump \
    tls-cert=/etc/squid/certs/intermediate.crt \
    tls-key=/etc/squid/certs/intermediate.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=16MB

http_port 3129 ssl-bump \
    tls-cert=/etc/squid/certs/intermediate.crt \
    tls-key=/etc/squid/certs/intermediate.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=16MB

# --- Certificate generator (sslcrtd) ---
# Squid 6.x: security_file_certgen replaces the old ssl_crtd name.
# -s: storage directory, -M: max cert cache size in MB
sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 16
sslcrtd_children 5 startup=1 idle=1

# --- TLS outgoing (proxy -> origin) ---
# Verify upstream server certificates against system CA store.
tls_outgoing_options cafile=/etc/ssl/certs/ca-certificates.crt \
    options=NO_SSLv3,NO_TLSv1,NO_TLSv1_1 \
    cipher=HIGH:!aNULL:!MD5 \
    flags=DONT_VERIFY_PEER

# NOTE: DONT_VERIFY_PEER is set initially for compatibility. In production,
# remove this flag to enforce upstream certificate verification. Some registries
# use certificate pinning or unusual CAs that may need explicit trust anchors.

# --- DNS ---
dns_nameservers 1.1.1.1 8.8.8.8

# --- ACLs ---
acl allowlist dstdomain "/etc/squid/allowlist.txt"
acl strict_port myport 3128
acl build_port myport 3129
acl SSL_ports port 443
acl SSL_ports port 8443
acl CONNECT method CONNECT

# --- Selective SSL Bump ---
# Domains that MUST NOT be bumped (certificate pinning, HSTS preload, etc.)
acl no_bump_domains dstdomain .google.com .googleapis.com .gstatic.com
acl no_bump_domains dstdomain .microsoft.com .azure.com .azureedge.net
acl no_bump_domains dstdomain .github.com .githubusercontent.com
acl no_bump_domains dstdomain .anthropic.com .openai.com

# Package registries — ALWAYS bump for caching benefit
acl bump_domains dstdomain .npmjs.org .npmjs.com .yarnpkg.com
acl bump_domains dstdomain .crates.io .rust-lang.org
acl bump_domains dstdomain .pypi.org .pythonhosted.org
acl bump_domains dstdomain .rubygems.org .packagist.org
acl bump_domains dstdomain .pub.dev .nuget.org .maven.org .hex.pm
acl bump_domains dstdomain .cocoapods.org .cpan.org
acl bump_domains dstdomain .cran.r-project.org
acl bump_domains dstdomain .hackage.haskell.org .clojars.org .opam.ocaml.org
acl bump_domains dstdomain .jsdelivr.net .unpkg.com .esm.sh
acl bump_domains dstdomain .nodejs.org .golang.org .go.dev

# SSL Bump steps:
#   1. "peek" at the ClientHello to read SNI
#   2. "stare" at the server's certificate to get Subject/SANs
#   3. "bump" (intercept) or "splice" (passthrough) based on domain

# Step 1: Always peek at client hello for SNI
ssl_bump peek all

# Step 2: Splice (no interception) for pinned domains
ssl_bump splice no_bump_domains

# Step 3: Bump package registries (enables caching)
ssl_bump bump bump_domains

# Step 4: Default — splice everything else (conservative default)
ssl_bump splice all

# --- Access rules ---
# Port 3129 (permissive/build): allow everything on SSL ports
http_access allow CONNECT SSL_ports build_port
http_access allow build_port

# Port 3128 (strict/runtime): allowlisted domains only
http_access allow CONNECT SSL_ports allowlist strict_port
http_access allow allowlist strict_port

# Deny CONNECT to non-SSL ports
http_access deny CONNECT

# Deny everything else
http_access deny all

# --- Cache ---
cache_dir ufs /var/spool/squid 500 16 256
maximum_object_size 256 MB

# Cache HTTPS content (this is the whole point of SSL bump)
# Without SSL bump, HTTPS responses are tunneled and never cached.
# With SSL bump, squid sees the plaintext HTTP response and can cache it.

# --- Logging (container-friendly) ---
access_log stdio:/dev/stdout
cache_log stdio:/dev/stderr
cache_store_log none

# --- Identity ---
visible_hostname tillandsias-proxy

# --- Privacy ---
forwarded_for delete
via off

# --- Runtime ---
cache_effective_user proxy
cache_effective_group proxy

shutdown_lifetime 3 seconds

pid_filename /var/run/squid/squid.pid
```

### Key Squid Directives Explained

| Directive | Purpose |
|-----------|---------|
| `http_port ... ssl-bump` | Enable TLS interception on this listener |
| `tls-cert=` / `tls-key=` | The intermediate CA used to sign fake server certs |
| `generate-host-certificates=on` | Auto-generate certs for each upstream domain |
| `dynamic_cert_mem_cache_size=16MB` | In-memory cache for generated certs |
| `sslcrtd_program` | External helper that generates + caches certs on disk |
| `sslcrtd_children` | Number of cert-gen helper processes |
| `tls_outgoing_options` | TLS settings for squid-to-origin connections |
| `ssl_bump peek` | Read ClientHello SNI without terminating TLS |
| `ssl_bump stare` | Read upstream server cert before deciding bump/splice |
| `ssl_bump bump` | Terminate TLS on both sides (full MITM) |
| `ssl_bump splice` | Pass TLS through unmodified (no interception) |

---

## 4. Selective Bump Strategy — What to Intercept

@trace spec:proxy-container

Not all HTTPS traffic should be intercepted. The strategy is: **bump what we want to cache, splice everything else**.

### Bump (Intercept + Cache)

| Category | Domains | Rationale |
|----------|---------|-----------|
| npm | `.npmjs.org`, `.npmjs.com`, `.yarnpkg.com` | Largest cache win -- `node_modules` downloads are massive and repetitive |
| Rust | `.crates.io`, `.rust-lang.org` | Cargo downloads are large, `crates.io` serves tarballs over HTTPS |
| Python | `.pypi.org`, `.pythonhosted.org` | pip wheels are large binaries |
| Ruby | `.rubygems.org` | Gem downloads |
| CDNs | `.jsdelivr.net`, `.unpkg.com`, `.esm.sh` | Static assets, highly cacheable |
| Other registries | `.pub.dev`, `.nuget.org`, `.maven.org`, `.hex.pm`, etc. | Completeness |

### Splice (Passthrough, No Interception)

| Category | Domains | Rationale |
|----------|---------|-----------|
| Auth/OAuth | `.github.com`, `.githubusercontent.com` | Certificate pinning in `gh` CLI; authentication flows |
| Google | `.google.com`, `.googleapis.com`, `.gstatic.com` | Chrome/Chromium use certificate pinning (CRLSets) |
| Microsoft | `.microsoft.com`, `.azure.com` | .NET SDK may pin certs |
| AI APIs | `.anthropic.com`, `.openai.com` | API clients may pin certs; low cache value (unique responses) |
| All other | everything not in bump list | Conservative default -- splice unknown traffic |

### Why Not Bump Everything?

1. **Certificate pinning** -- Some tools (Chrome, `gh` CLI, gcloud) embed expected certificate hashes and reject MITM certs. Bumping these breaks functionality.
2. **HSTS + HPKP** -- HTTP Strict Transport Security and Public Key Pinning headers can cause hard failures when the presented cert chain doesn't match expectations.
3. **Performance** -- Each bumped connection requires cert generation + dual TLS handshake. Only bump where caching provides a measurable benefit.
4. **Privacy** -- Minimize the amount of traffic we decrypt. Package downloads are safe to inspect; API calls and authentication flows are not.

---

## 5. Dual Proxy Architecture — Single Instance vs Two Instances

@trace spec:proxy-container

### Option A: Single Squid Instance, Two Ports (Recommended)

The current architecture already uses a single squid with two `http_port` directives. SSL bump extends this naturally:

```
Single squid process
  |
  +-- Port 3128 (strict):  ssl_bump + allowlist ACLs
  +-- Port 3129 (permissive): ssl_bump + allow all
  |
  +-- Shared cache_dir: /var/spool/squid (500MB UFS)
  +-- Shared ssl_db:   /var/lib/squid/ssl_db
```

**Pros**:
- No cache locking issues (single process owns the cache)
- Simpler lifecycle management (one container to start/stop/health-check)
- Port-based ACLs already work for strict vs permissive routing
- Lower resource usage (one squid process, one set of sslcrtd helpers)

**Cons**:
- If squid crashes, both strict and permissive go down together
- All traffic shares the same cert-gen workers (but 5 workers is plenty)

### Option B: Two Squid Instances (Not Recommended)

Two separate squid processes sharing the same `cache_dir`.

**Why this fails**: Squid's UFS cache store uses file-level locking. Two processes writing to the same `cache_dir` causes corruption. The `rock` store type supports shared access but requires explicit configuration and has different performance characteristics. Not worth the complexity.

**Verdict**: Stick with **Option A** (single instance, two ports). This is simpler, safer, and already the established pattern in the codebase.

---

## 6. Certificate Injection into Containers

@trace spec:proxy-container

### Strategy: Bind-Mount + Entrypoint Trust Update

At container launch, the host Tillandsias binary:

1. Generates the intermediate CA cert (see Phase 2 above)
2. Concatenates `root.crt` + `intermediate.crt` into a single `tillandsias-ca-chain.crt`
3. Bind-mounts the chain file read-only into the container

The container's entrypoint script updates the system trust store before starting the main process.

### Per-Distro Trust Store Commands

| Base Image | Copy Destination | Update Command |
|------------|-----------------|----------------|
| Alpine | `/usr/local/share/ca-certificates/tillandsias-ca.crt` | `update-ca-certificates` |
| Fedora/RHEL | `/etc/pki/ca-trust/source/anchors/tillandsias-ca.crt` | `update-ca-trust` |
| Debian/Ubuntu | `/usr/local/share/ca-certificates/tillandsias-ca.crt` | `update-ca-certificates` |
| Arch | `/etc/ca-certificates/trust-source/anchors/tillandsias-ca.crt` | `update-ca-trust` |

### Forge Entrypoint Snippet

```bash
# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
CA_CHAIN="/run/tillandsias/ca-chain.crt"
if [ -f "$CA_CHAIN" ]; then
    # Detect distro and install CA cert
    if command -v update-ca-trust &>/dev/null; then
        # Fedora/RHEL/Arch
        cp "$CA_CHAIN" /etc/pki/ca-trust/source/anchors/tillandsias-ca.crt
        update-ca-trust
    elif command -v update-ca-certificates &>/dev/null; then
        # Alpine/Debian/Ubuntu
        cp "$CA_CHAIN" /usr/local/share/ca-certificates/tillandsias-ca.crt
        update-ca-certificates
    fi
fi
```

### Tool-Specific Trust Store Behavior

| Tool | Honors System CA Store? | Override Env Var | Notes |
|------|------------------------|------------------|-------|
| curl | Yes | `CURL_CA_BUNDLE` | Uses OpenSSL/NSS system store |
| wget | Yes | `SSL_CERT_FILE` | |
| npm | **NO** (uses Node.js built-in) | `NODE_EXTRA_CA_CERTS` | Must set this env var |
| cargo | Yes (via native-tls or rustls) | `SSL_CERT_FILE` | `native-tls` uses system store; `rustls` may need `CARGO_HTTP_CAINFO` |
| pip | Yes | `REQUESTS_CA_BUNDLE` | pip uses `certifi` by default; set env var to override |
| go | Yes | `SSL_CERT_FILE` | Go stdlib reads system store |
| git | Yes (with OpenSSL backend) | `GIT_SSL_CAINFO` | Git on macOS uses SecureTransport, not OpenSSL |
| ruby/gem | Yes | `SSL_CERT_FILE` | |

**Critical**: npm/Node.js does NOT read the system trust store. The forge entrypoint MUST set:

```bash
export NODE_EXTRA_CA_CERTS="/run/tillandsias/ca-chain.crt"
```

### Env Vars to Set in Container Profile

```rust
// @trace spec:proxy-container
// Ensure all tools trust the Tillandsias CA chain for HTTPS proxy caching.
ProfileEnvVar { name: "NODE_EXTRA_CA_CERTS", value: EnvValue::Literal("/run/tillandsias/ca-chain.crt") },
ProfileEnvVar { name: "REQUESTS_CA_BUNDLE", value: EnvValue::Literal("/etc/ssl/certs/ca-certificates.crt") },
ProfileEnvVar { name: "SSL_CERT_FILE",      value: EnvValue::Literal("/etc/ssl/certs/ca-certificates.crt") },
```

After `update-ca-certificates` runs, the system bundle at `/etc/ssl/certs/ca-certificates.crt` includes the Tillandsias CA. So `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` point to the updated system bundle.

`NODE_EXTRA_CA_CERTS` is special -- it appends to Node's built-in roots rather than replacing them. It must point to the raw chain file, not the system bundle.

---

## 7. Container Trust Model

@trace spec:proxy-container, spec:enclave-network

### Trust Hierarchy

| Container Type | Proxy Port | SSL Bumped? | Internet Access | CA Cert Injected? |
|---------------|------------|-------------|-----------------|-------------------|
| **Forge** (runtime) | 3128 (strict) | Yes (package registries) | Allowlist only | Yes (intermediate CA) |
| **Forge** (build via trusted proxy) | 3129 (permissive) | Yes (package registries) | All domains | Yes (intermediate CA) |
| **Inference** | 3128 (strict) | Yes (for model downloads) | Allowlist only | Yes (intermediate CA) |
| **Git service** | None | N/A | Enclave only | No (no HTTPS traffic) |
| **Proxy** | N/A (is the proxy) | N/A | Dual-homed (bridge) | No |

### Per-Container Intermediate CA Isolation

Each container gets its own intermediate CA. This means:

- **Container A** cannot forge HTTPS responses to **Container B** -- different trust roots
- If a forge container is compromised, its intermediate CA cannot be used outside that container
- The intermediate CA dies with the container (tmpfs-backed private key)

In practice, because all traffic goes through the single proxy, the proxy uses whichever intermediate CA is currently configured. If we want true per-container cert isolation, we would need either:

1. Multiple proxy instances (rejected above -- cache corruption risk)
2. A proxy that selects the signing CA based on the source IP (complex, not supported by squid natively)

**Practical decision**: Use a single intermediate CA for all containers behind the proxy. The intermediate CA is scoped to the proxy container's lifetime, not individual forge containers. This is acceptable because:

- The proxy is already the single point of trust (all traffic goes through it)
- The intermediate CA's private key never leaves the proxy container
- The intermediate CA expires when the proxy container stops (which happens on app exit)
- Forge containers only receive the public cert chain (no private keys)

### Revised Certificate Lifecycle

| Certificate | Scope | Generated when | Dies when |
|-------------|-------|---------------|-----------|
| Root CA | Host app (global) | First launch | Manual rotation (10yr) |
| Intermediate CA | Proxy container | Proxy starts | Proxy stops (app exit) |
| Server certs | Per-domain (in squid memory) | First HTTPS request to domain | Squid restarts |

---

## 8. Git Commit Signing with Container CAs

@trace spec:proxy-container

### The Idea

Use the same CA infrastructure to sign git commits made inside containers. A signed commit proves: "This commit was made inside a Tillandsias enclave container."

### How Git X.509 Signing Works

Git supports X.509 (S/MIME) commit signing via `gpg.format = x509`:

```gitconfig
[gpg]
    format = x509
[gpg "x509"]
    program = gpgsm
    # OR:
    program = smimesign
[commit]
    gpgsign = true
[user]
    signingkey = <key-id-or-email>
```

The signing flow:
1. Git calls the signing program with the commit data
2. The program signs with a private key + certificate
3. The signature (PKCS#7/CMS) is embedded in the commit object
4. Verifiers check the signature against the certificate chain

### Certificate for Signing

We would generate a signing certificate (not a CA cert) signed by the intermediate CA:

```
Root CA (Tillandsias)
  +-- Intermediate CA (proxy lifetime)
       +-- Signing cert (per-container, per-user)
            Subject: CN=<user-name>, O=Tillandsias Enclave
            Key Usage: digitalSignature
            Extended Key Usage: emailProtection (S/MIME)
            SAN: email=<user-email>
```

### GitHub Verification

GitHub verifies X.509 commit signatures, but with limitations:

| Aspect | Status |
|--------|--------|
| GitHub shows "Verified" badge for X.509? | Yes, since 2019 (via `smimesign`) |
| GitHub trusts custom CAs? | **No** -- GitHub only trusts well-known public CAs |
| Can we make GitHub trust Tillandsias CA? | No, unless we get a publicly-trusted S/MIME cert |
| What does GitHub show for custom-CA-signed commits? | "Unverified" or "The signing certificate or its chain could not be verified" |
| Can users verify locally? | Yes, with `git log --show-signature` + local trust of the CA |

### Practical Assessment

| Pro | Con |
|-----|-----|
| Cryptographic proof of enclave origin | GitHub will never show "Verified" for these commits |
| Local verification possible | Adds `gpgsm` or `smimesign` to the forge image (~5-10MB) |
| Unique to Tillandsias (differentiator) | Complex key lifecycle management (generate, inject, destroy) |
| Zero trust of the signing key outside the enclave | Users must manually trust the Tillandsias root CA for local verification |
| Tamper-evident history | Alternative: use git notes or commit trailers (much simpler, no crypto) |

### Recommendation

**Defer git commit signing to a later phase.** The cost-benefit is unfavorable:

- GitHub will not show "Verified" badges (the primary user-visible benefit)
- Local verification requires trusting the Tillandsias root CA on every developer's machine
- A simpler approach (commit trailer: `Enclave: tillandsias-myapp-aeranthos`) achieves 80% of the value with 5% of the complexity
- The CA infrastructure for HTTPS caching does not naturally extend to signing -- different key usage, different certificate profiles, different tooling (`smimesign` vs `sslcrtd`)

If revisited in the future, consider:
1. Git's `gpg.format = ssh` (much simpler, uses SSH keys already available)
2. Sigstore/Gitsign (keyless signing, uses OIDC identity, GitHub trusts the Sigstore root)

---

## 9. Pros and Cons Summary

@trace spec:proxy-container

### Pros

| Benefit | Impact |
|---------|--------|
| HTTPS content caching | Large: `npm install` in 2s instead of 30s on cache hit |
| Reduced bandwidth | Medium: avoids re-downloading identical packages across containers |
| Deeper security inspection | Medium: can inspect request/response bodies, not just domains |
| Selective bump/splice | High: only intercept what we need, pass through everything else |
| Ephemeral certificates | High: no persistent trust chain leakage, keys die with container |
| Compatible with existing dual-port design | High: extends current architecture, does not replace it |

### Cons

| Risk | Impact | Mitigation |
|------|--------|------------|
| Certificate pinning breakage | High | Splice pinned domains (google, github, etc.) |
| Added latency per HTTPS request | Low-Medium | ~2-5ms per request for cert gen + dual TLS; cached certs are ~0ms |
| Larger proxy image | Low | +5-10MB for openssl + squid-openssl |
| Root CA key compromise | Critical | Store in OS keyring; restrict file permissions; rotate procedure |
| npm `NODE_EXTRA_CA_CERTS` requirement | Medium | Must set env var in every forge profile |
| Complexity of cert generation at launch | Medium | Use `rcgen` crate in Rust (no external openssl CLI dependency) |
| Some tools use their own CA bundles | Medium | Set `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS` |
| Debugging TLS errors becomes harder | Medium | Good error messages in entrypoint; `--log-proxy` shows bump/splice |

---

## 10. Implementation Phases

@trace spec:proxy-container

### Phase A: Root CA Generation (Rust-Native)

**Scope**: Generate the root CA certificate at first launch using the `rcgen` crate.

| Item | Estimate |
|------|----------|
| New dependency | `rcgen` crate (~pure Rust, no OpenSSL linkage) |
| Code changes | ~150 LOC in new `src-tauri/src/ca.rs` module |
| Config changes | Store root CA path in `GlobalConfig` |
| Security | Root key in OS keyring (reuse existing keyring infrastructure) |
| Test | Unit test: generate CA, verify cert fields, check key storage |

### Phase B: Intermediate CA + Cert Injection

**Scope**: Generate intermediate CA at proxy launch, inject into proxy and forge containers.

| Item | Estimate |
|------|----------|
| Code changes | ~200 LOC: intermediate CA generation, bind-mount assembly, env var additions |
| Profile changes | Add `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` to forge profiles |
| Containerfile changes | Add `squid-openssl`, `ca-certificates` packages to proxy image |
| Entrypoint changes | Proxy: init ssl_db, validate cert files. Forge: update-ca-certificates |
| Mount changes | Proxy: cert/key at `/etc/squid/certs/`. Forge: chain at `/run/tillandsias/ca-chain.crt` |
| Test | Integration test: launch proxy + forge, `curl https://httpbin.org/get` through proxy |

### Phase C: Squid SSL Bump Configuration

**Scope**: Configure squid for selective SSL bump.

| Item | Estimate |
|------|----------|
| squid.conf changes | ~60 lines of new ACL + ssl_bump directives (config file, not code) |
| Selective bump list | Curated list of package registries to bump (see Section 4) |
| No-bump list | Domains known to use certificate pinning |
| Test | Verify: (1) bumped domain responses are cached, (2) spliced domains still work, (3) pinned tools like `gh` still connect |

### Phase D: Accountability + Telemetry

**Scope**: Add SSL bump visibility to `--log-proxy`.

| Item | Estimate |
|------|----------|
| Log format | `[proxy] BUMP registry.npmjs.org (cached, 2.1MB)` vs `[proxy] SPLICE github.com` |
| Code changes | ~50 LOC: parse squid access log for bump/splice status |
| Cheatsheet update | Update `enclave-architecture.md` and `logging-levels.md` |

### Phase Order and Dependencies

```
Phase A ──> Phase B ──> Phase C ──> Phase D
(root CA)   (intermediate)  (squid config)  (telemetry)
~150 LOC    ~200 LOC        ~60 lines conf  ~50 LOC
```

Total estimated new code: ~400 LOC Rust + ~60 lines squid config + ~30 lines shell.

Each phase is independently testable and can ship incrementally. Phase A can be developed and tested without any squid changes. Phase B can be tested with splice-all (no bump) to verify cert injection. Phase C enables the actual caching. Phase D adds observability.

---

## 11. Known Risks and Mitigations

@trace spec:proxy-container

### Risk: Certificate Pinning Breaks Tools

**Symptom**: `gh auth login` fails, Chrome extensions fail to load, gcloud CLI rejects connection.

**Mitigation**: Maintain a curated `no_bump_domains` ACL in squid.conf. Default to `splice all` and only bump known-safe package registries. The splice-first approach means unknown tools work by default.

**Detection**: `--log-proxy` will show `DENY` or connection errors for bumped domains. Users can report these, and we add them to the no-bump list.

### Risk: Root CA Key Compromise

**Symptom**: An attacker with the root CA key can sign arbitrary intermediate CAs, enabling MITM of any HTTPS traffic on the user's machine (if the root CA is in their system trust store).

**Mitigation**:
- The root CA is NOT added to the host's system trust store -- only to containers
- The root CA key is stored in the OS keyring (hardware-backed on macOS, GNOME Keyring on Linux)
- The root CA subject includes "Tillandsias" to make it obvious in cert inspection
- `pathlen:1` constraint prevents creation of sub-sub-CAs
- If compromised: generate new root CA, all containers automatically get new chain on next launch

### Risk: Performance Degradation

**Symptom**: HTTPS requests are slower due to dual TLS handshake + cert generation.

**Quantification**:
- First request to a new domain: ~5-10ms overhead (cert generation)
- Subsequent requests to same domain: ~1-2ms overhead (cached cert, dual TLS)
- Cache hit (no upstream connection): negative overhead (faster than direct)

**Mitigation**: The whole point is that cache hits vastly outnumber cache misses for package downloads. `npm install` in a fresh container with warm cache goes from 30s to 2s.

### Risk: Stale Cache Serves Old Package Versions

**Symptom**: Package manager installs an outdated version from cache even after a new release.

**Mitigation**: Package managers include version-specific URLs. `npm install lodash@4.17.21` requests a specific tarball URL that won't match a cached `4.17.20` tarball. Cache invalidation happens naturally through URL uniqueness. For registries that serve the same URL with different content (rare), squid's `refresh_pattern` and `Cache-Control` header handling applies.

### Risk: squid Memory Usage with SSL Bump

**Symptom**: Proxy container uses significantly more RAM with sslcrtd helpers + cert cache.

**Quantification**: ~50-100MB additional RAM (cert cache + 5 sslcrtd child processes).

**Mitigation**: Acceptable for a development workstation. The `dynamic_cert_mem_cache_size=16MB` and sslcrtd disk cache (`-M 16`) cap memory growth. The proxy container is shared across all projects, so the cost is amortized.

### Risk: Alpine `squid-openssl` Package Unavailable

**Symptom**: `apk add squid-openssl` fails because Alpine 3.20 doesn't have it.

**Mitigation**: Alpine's squid package is built with OpenSSL support by default. Verify with: `squid -v 2>&1 | grep ssl`. If the default package lacks SSL support, we either:
1. Switch to `squid` from Alpine edge (which always has SSL)
2. Build squid from source in the Containerfile (adds ~1 minute to image build)
3. Switch base image to Debian slim (larger but guaranteed openssl squid)

---

## 12. Alternative Approaches Considered

@trace spec:proxy-container

### Alternative: Dedicated Package Cache (Verdaccio, cargo-local-registry)

Instead of MITM proxy caching, run per-ecosystem cache services:
- **Verdaccio** for npm
- **cargo-local-registry** for Rust
- **devpi** for Python

**Why rejected**: Each requires its own container, its own config, its own cache storage. The proxy approach is universal -- one cache for all ecosystems, no per-language configuration.

### Alternative: mitmproxy Instead of Squid

`mitmproxy` is a Python-based MITM proxy with better developer ergonomics.

**Why rejected**: Heavier image (Python runtime), higher memory usage, not designed for caching. Squid is purpose-built for caching and is already deployed.

### Alternative: Bump Everything (No Selective Bump)

Set `ssl_bump bump all` and let all HTTPS traffic be intercepted.

**Why rejected**: Breaks certificate-pinned tools. The conservative approach (splice by default, bump package registries) avoids surprises.

### Alternative: Use WPAD or Transparent Proxy

Configure containers to auto-discover the proxy via WPAD, or use iptables to transparently redirect HTTPS traffic.

**Why rejected**: WPAD is complex and fragile. Transparent HTTPS interception requires iptables + TPROXY, which needs `NET_ADMIN` capability (violates our `--cap-drop=ALL` requirement). The explicit `HTTP_PROXY` env var approach is simpler and already working.

---

## 13. Dependency Assessment

@trace spec:proxy-container

### New Rust Dependencies

| Crate | Purpose | Size | Audit Status |
|-------|---------|------|-------------|
| `rcgen` | X.509 certificate generation (pure Rust) | ~50KB | Widely used, 10M+ downloads |
| `time` | Certificate validity period calculation | Already a transitive dep | N/A |

`rcgen` is preferred over shelling out to `openssl` CLI because:
1. No external binary dependency
2. Pure Rust, no OpenSSL linkage (works on all platforms without system openssl)
3. Well-tested API for CA cert generation
4. Already used by rustls, which is a transitive dep of reqwest

### New Container Packages

| Package | Image | Purpose | Size Impact |
|---------|-------|---------|-------------|
| `ca-certificates` | proxy | Upstream TLS verification | ~1MB |
| `openssl` | proxy | Certificate utilities (may already be a squid dep) | ~3MB |

### No New Host Dependencies

The host Tillandsias binary generates certificates using `rcgen` (compiled in). No `openssl` CLI needed on the host.

---

## 14. References

### Squid Documentation
- Squid SSL Bump: https://wiki.squid-cache.org/Features/SslBump
- Squid SSL Peek and Splice: https://wiki.squid-cache.org/Features/SslPeekAndSplice
- security_file_certgen: https://www.squid-cache.org/Doc/config/sslcrtd_program/
- http_port ssl-bump: https://www.squid-cache.org/Doc/config/http_port/
- tls_outgoing_options: https://www.squid-cache.org/Doc/config/tls_outgoing_options/
- ssl_bump directive: https://www.squid-cache.org/Doc/config/ssl_bump/

### Certificate Generation
- rcgen crate: https://docs.rs/rcgen/
- OpenSSL CA tutorial: https://jamielinux.com/docs/openssl-certificate-authority/
- Alpine CA certificates: https://wiki.alpinelinux.org/wiki/Setting_up_a_ssl-vpn#CA_certificate

### Git X.509 Signing
- Git gpg.format: https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgformat
- GitHub X.509 signing: https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification#smime-commit-signature-verification
- Sigstore Gitsign: https://docs.sigstore.dev/signing/gitsign/

### Tool-Specific CA Trust
- Node.js NODE_EXTRA_CA_CERTS: https://nodejs.org/api/cli.html#node_extra_ca_certsfile
- pip REQUESTS_CA_BUNDLE: https://pip.pypa.io/en/stable/topics/https-certificates/
- cargo CARGO_HTTP_CAINFO: https://doc.rust-lang.org/cargo/reference/environment-variables.html

---

## Related

**Specs:**
- `openspec/specs/proxy-container/spec.md` -- current proxy specification
- `openspec/specs/enclave-network/spec.md` -- network isolation model
- `openspec/specs/forge-offline/spec.md` -- forge container security requirements

**Source files:**
- `images/proxy/squid.conf` -- current squid configuration (no SSL bump)
- `images/proxy/Containerfile` -- current proxy image definition
- `images/proxy/entrypoint.sh` -- current proxy entrypoint
- `crates/tillandsias-core/src/container_profile.rs` -- container profiles (env vars, mounts)
- `src-tauri/src/handlers.rs` -- proxy lifecycle management
- `src-tauri/src/launch.rs` -- podman arg builder

**Cheatsheets:**
- `docs/cheatsheets/enclave-architecture.md` -- full enclave design
- `docs/cheatsheets/secret-management.md` -- credential lifecycle
