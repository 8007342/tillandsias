<!-- @trace spec:certificate-authority -->

# certificate-authority Specification

## Status

status: active

## Purpose

Provide per-launch, ephemeral TLS certificate authority for enclave-internal HTTPS traffic. The CA is generated in tmpfs during container startup, used for proxy and reverse-proxy SSL termination, then destroyed on container shutdown. Zero persistence, zero credential leakage.

This spec ensures:
- Enclave-internal HTTPS isolation (internal services do not expose certs to the host)
- Ephemeral lifecycle (CA deleted on shutdown)
- Proxy/reverse-proxy can terminate SSL without hardcoded credentials
- Zero disk footprint

## Requirements

### Requirement: Ephemeral CA generation on startup

The CA (root cert and private key) SHALL be generated fresh in tmpfs during container initialization, deleted on shutdown, and NEVER persisted to disk.

#### Scenario: CA created in tmpfs
- **WHEN** an enclave-internal container (proxy, reverse-proxy, inference) starts
- **THEN** it generates a self-signed root CA certificate and private key
- **AND** both are written to `/tmp/ca/` (tmpfs-backed)
- **AND** file permissions are 0400 (read-only to owner)

#### Scenario: CA lifetime tied to container
- **WHEN** the container exits (cleanly or crashed)
- **THEN** the `/tmp/ca/` directory and all its contents are lost when tmpfs is unmounted
- **AND** the CA is automatically destroyed (no explicit deletion required)

#### Scenario: No CA on host
- **WHEN** the tray application inspects the host's filesystem
- **THEN** no CA files appear in any persistent location (`~/.config`, `/etc/ssl`, etc.)
- **AND** the host has no way to decrypt enclave-internal HTTPS traffic

### Requirement: Proxy uses ephemeral CA for SSL termination

The HTTP/HTTPS proxy container SHALL use the ephemeral CA to issue short-lived certificates for all upstream connections. Certificates are created on-demand and destroyed on shutdown.

#### Scenario: Proxy terminates HTTPS
- **WHEN** a forge container makes an HTTPS request to an external service via the proxy
- **THEN** the proxy terminates the client connection with a cert issued by the ephemeral CA
- **AND** the cert is valid for the target domain (SAN matching)
- **AND** the cert is stored in `/tmp/proxy-certs/` (tmpfs)

#### Scenario: Untrusted cert to forge
- **WHEN** a forge receives the proxy's termination cert
- **THEN** the forge sees the proxy as an untrusted CA (not in system roots)
- **AND** the forge MUST be configured to accept the proxy's CA bundle (via env var or config)
- **AND** the CA trust is scoped to the enclave network (not system-wide)

### Requirement: Reverse-proxy uses ephemeral CA for internal HTTPS

The reverse-proxy container (routing to forge or web containers) SHALL use the ephemeral CA to issue certificates for all internal HTTPS endpoints.

#### Scenario: Reverse-proxy HTTPS to forge
- **WHEN** a web client connects to the reverse-proxy on an HTTPS port
- **THEN** the reverse-proxy presents a certificate issued by the ephemeral CA
- **AND** the certificate covers the expected hostname (e.g., `internal-forge.tillandsias`)
- **AND** the cert is valid for the connection duration

#### Scenario: Certs destroyed on shutdown
- **WHEN** the reverse-proxy container stops
- **THEN** all issued certificates and the CA are deleted via tmpfs unmount
- **AND** no recovery or archival of cert material occurs

### Requirement: CA is never exposed to user or host

The CA private key SHALL never be written outside tmpfs, logged in plaintext, or transmitted to the host in any form.

#### Scenario: No CA in logs
- **WHEN** querying container logs or host-side telemetry
- **THEN** no CA private key material appears
- **AND** cert fingerprints or public certs may be logged for auditing, but never private keys

#### Scenario: No CA in config files
- **WHEN** inspecting `~/.config/tillandsias/` or `.tillandsias/` project config
- **THEN** no CA certificates are persisted
- **AND** proxy and reverse-proxy CA refs are tmpfs-only (`/tmp/ca/`, `/tmp/proxy-certs/`, etc.)

#### Scenario: No CA in container volumes
- **WHEN** a forge container runs with a project cache volume
- **THEN** no CA files are copied or mounted into the volume
- **AND** the CA is inaccessible from the forge except via proxy connections

### Requirement: Cert validity and rotation

Certificates issued by the ephemeral CA SHALL have short lifetimes (session-scoped) and be regenerated on-demand.

#### Scenario: Proxy cert validity
- **WHEN** a cert is issued by the proxy for a new upstream connection
- **THEN** the cert is valid for at least 24 hours (session duration)
- **AND** the cert is regenerated if the upstream connection is re-established after container restart

#### Scenario: Reverse-proxy cert fixed lifetime
- **WHEN** the reverse-proxy starts
- **THEN** it issues a single certificate (or small set) for the enclave-internal HTTPS endpoint
- **AND** the certificate is valid for the container's entire lifetime
- **AND** a new certificate is issued on the next container start

### Requirement: Litmus test — ephemeral CA lifecycle

Critical verification paths for CA ephemeral design:

#### Test: CA created on startup
```bash
# Start enclave with proxy container
podman run --rm -d --name test-proxy tillandsias-proxy

# Wait for initialization
sleep 2

# Verify CA in tmpfs from inside container
podman exec test-proxy ls -la /tmp/ca/ca.crt /tmp/ca/ca.key
# Expected: files exist with 0400 permissions

# Stop container
podman stop test-proxy
```

#### Test: CA destroyed on shutdown
```bash
# After container stops, verify tmpfs is cleaned
podman ps -a | grep test-proxy
# Expected: no container listed (--rm removes it)

# If container had persistent volume, verify CA not in volume
ls /var/lib/containers/storage/volumes/*/ca.*
# Expected: no CA files found
```

#### Test: No CA persistence on host
```bash
# Run complete enclave lifecycle
./tillandsias-tray
# Start project, run build, stop
# Quit tray

# Verify no CA on host
find ~/.config/tillandsias -name "*.key" -o -name "ca*"
# Expected: no results
```

#### Test: Proxy cert issued and destroyed
```bash
# Inside forge, make HTTPS request via proxy
curl -v https://example.com/ 2>&1 | grep -i certificate

# Verify cert is from ephemeral CA (not system root)
openssl s_client -connect proxy:3128 </dev/null 2>&1 | grep -i "issuer"
# Expected: issuer shows "CN=Tillandsias Ephemeral CA" or similar

# Stop forge, verify proxy certs directory is empty
podman exec test-proxy ls /tmp/proxy-certs/ | wc -l
# Expected: 0 (or no output)
```

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:certificate-authority" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "certificate-authority"` on CA generation
- `cert_issued = "<domain>"` on proxy cert issuance
- `cert_lifetime_seconds = N` on cert creation
- `ca_destroyed = true` on shutdown

## Sources of Truth

- `cheatsheets/runtime/networking.md` — ephemeral network setup and internal routing patterns
- `cheatsheets/security/owasp-top-10-2021.md` — zero-persistence credential handling (A02:2021 - Cryptographic Failures)
- `cheatsheets/observability/cheatsheet-metrics.md` — event counting for cert issuance lifecycle

