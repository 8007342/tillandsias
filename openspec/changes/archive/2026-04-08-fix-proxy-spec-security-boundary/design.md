# Design: Fix proxy-container spec security boundary

## Approach

Rewrite the proxy-container spec to accurately describe the implemented architecture. This is a documentation correction, not a design change. The code is correct; the spec is wrong.

## Key architectural facts to document

### 1. SSL Bump MITM infrastructure

The proxy uses squid's ssl-bump feature. On both ports (3128, 3129), squid is configured with:
- `ssl-bump` directive on `http_port`
- Intermediate CA cert + key for dynamic certificate generation
- `security_file_certgen` (sslcrtd) daemon for on-demand cert creation
- Certificate memory cache (16MB per port)

### 2. Ephemeral CA chain

`src-tauri/src/ca.rs` generates a fresh two-level CA chain on every proxy launch:
- **Root CA**: self-signed, EC P-256, 30-day validity, stored on tmpfs
- **Intermediate CA**: signed by root, EC P-256, 30-day validity, used by squid
- **ca-chain.crt**: concatenated chain injected into forge containers for trust
- All key material lives in `$XDG_RUNTIME_DIR/tillandsias/proxy-certs/` (tmpfs, dies with session)

### 3. Splice-all default

The current ssl-bump policy is:
```
ssl_bump peek all     # Step 1: Read SNI from ClientHello
ssl_bump splice all   # Step 2: Passthrough, no interception
```

This means squid peeks at the SNI for domain filtering but does NOT decrypt traffic. The TLS session is spliced (tunneled) directly to the origin. The MITM infrastructure is in place but dormant.

### 4. Dual-port architecture

| Port | Name | Access policy | Use case |
|------|------|---------------|----------|
| 3128 | Strict | Allowlisted domains only | Runtime forge containers |
| 3129 | Permissive | All domains allowed | Image builds (currently unused) |

### 5. Image builds bypass the proxy

Image builds (`build-image.sh`) run outside the proxy entirely. The comment in `handlers.rs:1675-1678` explains: build containers don't have the CA cert installed, so they'd reject MITM'd certificates. Only runtime containers (forge, terminal) have the CA chain injected.

### 6. CA chain injection into forge containers

`inject_ca_chain_mounts()` in `handlers.rs` adds:
- Bind mount: `ca-chain.crt` -> `/run/tillandsias/ca-chain.crt:ro`
- `NODE_EXTRA_CA_CERTS=/run/tillandsias/ca-chain.crt` (Node.js)
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` (OpenSSL, Go, rustls)
- `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` (Python)

### 7. No-bump domains

Domains with certificate pinning or HSTS preload are listed in `no_bump_domains` ACL and would be spliced even if bumping were enabled:
- `.google.com`, `.googleapis.com`, `.gstatic.com`
- `.microsoft.com`, `.azure.com`, `.azureedge.net`
- `.github.com`, `.githubusercontent.com`
- `.anthropic.com`, `.openai.com`

### 8. Bump domains (future)

Package registries are listed in `bump_domains` ACL for selective bumping when/if enabled. These would benefit most from HTTPS content caching.

## Spec structure

The rewritten spec preserves the original requirement format (SHALL statements, scenarios) but replaces every incorrect claim with the truth.
