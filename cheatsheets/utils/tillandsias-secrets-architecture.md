# Tillandsias Secrets Architecture: Ephemeral-First Security

**Use when**: Understanding how secrets (CA certificates, GitHub tokens, SSH keys) flow through the Tillandsias ephemeral stack and are secured at each layer.

## Provenance

- `cheatsheets/utils/podman-secrets.md` — podman secrets mechanism
- [Tillandsias GitHub Credential Health Spec](../../openspec/specs/github-credential-health/spec.md) — authentication architecture
- [Tillandsias CA Certificate Spec](../../openspec/specs/certificate-authority/spec.md) — ephemeral trust chain
- [Red Hat Container Security Standards](https://www.redhat.com/en/blog/container-security-best-practices) — container credential handling
- **Last updated:** 2026-05-03

## Overview

Tillandsias follows **ephemeral-first security**: all secrets are created at session start, live in memory/tmpfs only, and are destroyed when the session ends. No secrets persist to disk.

### Secret Types

| Secret | Scope | Lifetime | Storage | Used By |
|--------|-------|----------|---------|---------|
| **CA Cert + Key** | Per-session | Tray uptime | tmpfs | Proxy (SSL bump) |
| **GitHub Token** | Per-session | Until logout | Ephemeral tmpfs | Git service, health probe |
| **SSH Keys** (future) | Per-session | Until logout | Ephemeral tmpfs | Git clone/push |
| **Database Password** (future) | Per-session | Container lifetime | Ephemeral tmpfs | Inference container |

## Secret Names Reference

All secrets in Tillandsias use explicit, hardcoded names. These names are **critical** — they must match exactly across all code paths.

| Secret Name | Type | Lifetime | Container | Path |
|---|---|---|---|---|
| `tillandsias-ca-root` | X.509 cert | Session | (none) | Archive |
| `tillandsias-ca-cert` | X.509 cert | Session | proxy, forge | `/run/secrets/tillandsias-ca-cert` |
| `tillandsias-ca-key` | Private key | Session | proxy, forge | `/run/secrets/tillandsias-ca-key` |
| `tillandsias-github-token` | OAuth token | Session | git service | `/run/secrets/tillandsias-github-token` |

**How to verify names match**: grep for these strings in:
```bash
grep -r "tillandsias-ca-cert\|tillandsias-ca-key\|tillandsias-github-token" \
  src-tauri/src/handlers.rs \
  src-tauri/src/launch.rs \
  images/*/entrypoint.sh
```

All matches should show the same names in creation, mounting, and reading contexts.

## Architecture: Three-Layer Secret Flow

### Layer 1: Secret Source (Host)

Source | Driver | Lifetime | Security |
|--------|--------|----------|---------|
| **OS Keyring** (GNOME Keyring, KDE Wallet) | `secret-tool` command | User session | Encrypted by OS, user-locked |
| **GitHub OAuth** (web login) | HTTP callback | User session | TLS-protected, user authenticates |
| **SSH Agent** (ssh-add) | SSH_AUTH_SOCK | User session | Agent-only access, no caching |
| **Environment** (CI/CD pipelines) | `$GITHUB_TOKEN` | Job duration | Scoped to job, auto-revoked |

**Tillandsias tray reads from OS keyring or prompts user for fresh auth.**

### Layer 2: Tray Process (Ephemeral Conversion)

```rust
// In handlers.rs during tray initialization:

// 1. Retrieve from OS keyring (sync, D-Bus to Secret Service)
let token = secrets::retrieve_github_token()?;  // Returns String

// 2. Create CA certificate (new per-session)
let ca = ca::generate_ephemeral_ca()?;  // Returns (cert, key) PEM strings

// 3. Create podman secrets (ephemeral, tmpfs-backed)
podman::secret::create("tillandsias-github-token", token)?;
podman::secret::create("tillandsias-ca-cert", ca.cert)?;
podman::secret::create("tillandsias-ca-key", ca.key)?;

// 4. At shutdown, remove secrets (automatic cleanup)
// podman secret rm tillandsias-github-token
// podman secret rm tillandsias-ca-cert
// podman secret rm tillandsias-ca-key
```

### Layer 3: Container Access (Read-Only)

Containers receive secrets via `--secret=<name>` flag:

```bash
podman run \
  --secret=tillandsias-github-token \
  --secret=tillandsias-ca-cert \
  --secret=tillandsias-ca-key \
  tillandsias-git
```

Inside container:

```bash
#!/bin/bash
# In git service entrypoint

# GitHub token (for authenticated git operations)
GITHUB_TOKEN=$(cat /run/secrets/tillandsias-github-token)
export GIT_ASKPASS_OVERRIDE="true"  # Use env var, not prompt
git config credential.helper "store --file=/dev/null"  # Prevent caching
git clone "https://$GITHUB_TOKEN@github.com/user/repo.git"

# CA certificate (for MITM proxy)
cp /run/secrets/tillandsias-ca-cert /tmp/ca.pem
chmod 644 /tmp/ca.pem
export CURL_CA_BUNDLE=/tmp/ca.pem
```

## Security Guarantees

### Not Exposed In

- **Host `ps -eaux`**: Podman secrets are NOT command-line arguments
- **Container logs**: `podman logs` shows no secret content
- **Audit trails**: Secret operations logged, but not values
- **Container inspect**: `podman inspect` lists secrets but not values
- **Other containers**: Secrets in one container are not accessible to others
- **Host filesystem**: Secrets live in tmpfs, not written to disk

### Protected By

- **Podman storage backend**: Secrets encrypted at rest (if using LUKS volume)
- **SELinux**: Secrets labeled `container_file_t`, readable only by container processes
- **User namespace isolation**: `--userns=keep-id` ensures correct UID mapping
- **Filesystem permissions**: Only tray process (UID 1000) can read `.../secrets/` dir
- **Memory protection**: Tillandsias tray uses `Zeroizing<String>` to wipe from RAM

## Implementation: Podman Secrets Migration

### Step 1: Tray Initialization

```rust
// src-tauri/src/handlers.rs: ensure_infrastructure_ready()

// Retrieve GitHub token from OS keyring
match secrets::retrieve_github_token() {
    Ok(Some(token)) => {
        // Create ephemeral secret
        podman::secret::create("tillandsias-github-token", token)?;
    }
    Ok(None) => {
        // No token — user hasn't authenticated yet
        warn!("No GitHub token found — cloning will require authentication");
    }
    Err(e) => {
        // Keyring unavailable (non-fatal for local projects)
        warn!("Keyring unavailable: {e}");
    }
}

// Generate ephemeral CA certificate
let (ca_cert, ca_key) = ca::generate_ephemeral_ca()?;
podman::secret::create("tillandsias-ca-cert", ca_cert)?;
podman::secret::create("tillandsias-ca-key", ca_key)?;
```

### Step 2: Container Launch

```rust
// src-tauri/src/launch.rs: launch_container()

// Add secrets to podman run arguments
if podman::secret::exists("tillandsias-github-token")? {
    run_args.push("--secret=tillandsias-github-token".to_string());
}
if podman::secret::exists("tillandsias-ca-cert")? {
    run_args.push("--secret=tillandsias-ca-cert".to_string());
    run_args.push("--secret=tillandsias-ca-key".to_string());
}

podman.run_container(&run_args).await?;
```

### Step 3: Container Entrypoints

#### Proxy Entrypoint (`images/proxy/entrypoint.sh`)

```bash
#!/bin/bash
set -e

# Initialize squid cache
[[ ! -d /var/spool/squid/00 ]] && squid -z -N

# Initialize SSL certificate database
rm -rf /var/lib/squid/ssl_db
/usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 16

# Copy CA cert and key from secret to working location
if [[ -f /run/secrets/tillandsias-ca-cert ]]; then
    cp /run/secrets/tillandsias-ca-cert /etc/squid/certs/intermediate.crt
    chmod 644 /etc/squid/certs/intermediate.crt
fi

if [[ -f /run/secrets/tillandsias-ca-key ]]; then
    cp /run/secrets/tillandsias-ca-key /etc/squid/certs/intermediate.key
    chmod 600 /etc/squid/certs/intermediate.key
    chown proxy:proxy /etc/squid/certs/intermediate.key
fi

# Start squid
exec squid -N
```

#### Git Service Entrypoint (`images/git/entrypoint.sh`)

```bash
#!/bin/bash
set -e

# GitHub token (if available)
if [[ -f /run/secrets/tillandsias-github-token ]]; then
    GITHUB_TOKEN=$(cat /run/secrets/tillandsias-github-token)
    export GIT_CREDENTIAL_CACHE_DAEMON_TIMEOUT=1  # One-shot use
    
    # Configure git to use token-based auth
    git config --global credential.helper store
fi

# CA certificate (if available)
if [[ -f /run/secrets/tillandsias-ca-cert ]]; then
    export GIT_SSL_CAINFO="/run/secrets/tillandsias-ca-cert"
fi

# Start git daemon
exec git daemon --verbose --listen=0.0.0.0 --base-path=/var/lib/git
```

### Step 4: Shutdown Cleanup

```rust
// src-tauri/src/main.rs: shutdown path

pub async fn cleanup_all_secrets() {
    let secrets = vec![
        "tillandsias-github-token",
        "tillandsias-ca-cert",
        "tillandsias-ca-key",
    ];
    
    for secret in secrets {
        match podman::secret::remove(secret).await {
            Ok(()) => {
                info!(
                    accountability = true,
                    spec = "secrets-management",
                    secret = secret,
                    "Cleaned up ephemeral secret on shutdown"
                );
            }
            Err(e) => {
                warn!(
                    spec = "secrets-management",
                    secret = secret,
                    error = %e,
                    "Failed to clean up secret (will be cleaned by podman GC)"
                );
            }
        }
    }
}
```

## Comparison: Before vs. After

### Before (Bind Mounts + Environment Variables)

```rust
// ❌ INSECURE
// CA certs exposed in podman inspect, permission issues with --userns=keep-id
let run_args = vec![
    "-v", &format!("{}:/etc/squid/certs/intermediate.crt:ro", ca_cert_path),
    "-v", &format!("{}:/etc/squid/certs/intermediate.key:ro", ca_key_path),
    // ❌ Token visible in podman ps, process env
    "-e", &format!("GITHUB_TOKEN={}", token),
];
```

### After (Podman Secrets)

```rust
// ✅ SECURE
// Secrets not in command-line, not in process list, not in logs
podman::secret::create("tillandsias-ca-cert", ca_cert)?;
podman::secret::create("tillandsias-ca-key", ca_key)?;
podman::secret::create("tillandsias-github-token", token)?;

let run_args = vec![
    "--secret=tillandsias-ca-cert",
    "--secret=tillandsias-ca-key",
    "--secret=tillandsias-github-token",
];
```

## Threat Mitigation

### Threat: Secrets in Process Environment

- **Before**: `ps -eaux | grep GITHUB_TOKEN` reveals token
- **After**: Secrets mounted at `/run/secrets/`, not in environment
- **Mitigation**: SELinux prevents unprivileged read of `/run/secrets/`

### Threat: Secrets in Bind Mount Files

- **Before**: `podman inspect` shows mount paths, permission issues with UID mapping
- **After**: Secrets are opaque to inspection tools
- **Mitigation**: `podman secret inspect` does NOT show secret values

### Threat: Secrets in Container Logs

- **Before**: If entrypoint echoes `$GITHUB_TOKEN`, logs contain token
- **After**: Entrypoint reads `/run/secrets/`, does NOT echo or log
- **Mitigation**: Secret content never flows through logging pipeline

### Threat: Secrets on Persistent Disk

- **Before**: Bind-mounted files persist on host filesystem
- **After**: Secrets are ephemeral, removed on tray shutdown
- **Mitigation**: `podman secret rm` on exit ensures no disk residue

## File Locations (After Migration)

```
Host System
├── OS Keyring (GNOME Keyring / KDE Wallet)
│   └── tillandsias/github → GitHub token (encrypted by OS)
├── Tray Process (main.rs)
│   └── RAM: temporary String (zeroized on drop)
└── Podman Secrets Storage (~/.local/share/containers/storage/secrets/)
    ├── filedriver/
    │   ├── tillandsias-github-token
    │   ├── tillandsias-ca-cert
    │   └── tillandsias-ca-key

Container Runtime
├── /run/secrets/ (tmpfs, auto-created by podman)
│   ├── tillandsias-github-token (readable, 644)
│   ├── tillandsias-ca-cert (readable, 644)
│   └── tillandsias-ca-key (readable, 600)
└── /tmp/ (tmpfs for entrypoint-copied files, ephemeral)
    ├── ca.pem (copied from secret, auto-cleanup on exit)
    └── cert-db/ (squid cache)
```

## Monitoring and Logging

### Audit Events (Tillandsias Accountability Logging)

```rust
// Log secret operations for compliance
info!(
    accountability = true,
    category = "secrets",
    spec = "secrets-management",
    action = "secret_create",
    secret_name = "tillandsias-github-token",
    "Ephemeral secret created at session start"
);

// Log secret access inside containers (via entrypoint)
info!(
    accountability = true,
    category = "secrets",
    spec = "git-mirror-service",
    action = "secret_read",
    container = "tillandsias-git-java",
    "Git service read GitHub token from /run/secrets/"
);

// Log cleanup
info!(
    accountability = true,
    category = "secrets",
    spec = "secrets-management",
    action = "secret_cleanup",
    secret_name = "tillandsias-github-token",
    "Ephemeral secret removed on shutdown"
);
```

### Queries for Compliance

```bash
# Show all secret operations in current session
journalctl -u tillandsias | grep "action.*secret"

# Show only secret cleanup (verify ephemeral behavior)
journalctl -u tillandsias | grep "action=\"secret_cleanup\""

# Verify no secrets in container logs
podman logs tillandsias-proxy | grep -i "token\|secret\|key" || echo "✓ No secrets in logs"

# List remaining secrets (should be empty after shutdown)
podman secret ls | grep tillandsias || echo "✓ No ephemeral secrets remaining"
```

## Testing Checklist

- [ ] Verify `podman secret inspect` does NOT reveal secret values
- [ ] Verify `podman ps` does NOT show `--secret` flags as command-line args
- [ ] Verify `ps -eaux` does NOT show secret content in process environment
- [ ] Verify secrets are readable at `/run/secrets/<name>` inside containers
- [ ] Verify proxy can load CA cert from `/run/secrets/tillandsias-ca-cert`
- [ ] Verify git service can read token from `/run/secrets/tillandsias-github-token`
- [ ] Verify SELinux does NOT deny container access to `/run/secrets/`
- [ ] Verify `podman secret rm` succeeds and removes all ephemeral secrets on shutdown
- [ ] Verify no secrets left in ~/.local/share/containers/storage/secrets/ after cleanup

## Migration Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Containers fail to start (secret not found) | Medium | Add explicit checks in entrypoints, log loud warnings |
| Secrets not removed on abnormal exit | High | Add explicit cleanup in signal handlers, use podman GC |
| Backward compat with old binding method | Medium | Keep bind-mount support for 3 releases, then drop |
| SELinux blocks secret access | Low | Test on SELinux=enforcing before merging |
| Performance impact (secret I/O) | Very Low | Secrets are small (<10KB each), tmpfs-backed |

## References

- Podman Secrets Upstream: https://github.com/containers/podman/blob/main/docs/source/markdown/podman-secret.1.md
- Docker Secrets (similar): https://docs.docker.com/engine/swarm/secrets/
- OWASP Container Security: https://cheatsheetseries.owasp.org/cheatsheets/Container_Security_Cheat_Sheet.html
- Kubernetes Secrets (more complex variant): https://kubernetes.io/docs/concepts/configuration/secret/
