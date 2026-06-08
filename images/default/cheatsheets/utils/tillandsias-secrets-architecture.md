---
tags: [secrets, security, ephemeral, ca, ssh, github-token]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://www.redhat.com/en/blog/container-security-best-practices
  - https://docs.podman.io/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Tillandsias Secrets Architecture: Ephemeral-First Security

**Use when**: Understanding how secrets (CA certificates, GitHub tokens, SSH keys) flow through the Tillandsias ephemeral stack and are secured at each layer.

## Provenance

- `cheatsheets/utils/podman-secrets.md` — podman secrets mechanism
- [Tillandsias GitHub Credential Health Spec](../../openspec/specs/github-credential-health/spec.md) — authentication architecture
- [Tillandsias CA Certificate Spec](../../openspec/specs/certificate-authority/spec.md) — ephemeral trust chain
- [Red Hat Container Security Standards](https://www.redhat.com/en/blog/container-security-best-practices) — container credential handling
- **Last updated:** 2026-05-03

## Overview

Tillandsias runs a local HashiCorp Vault instance (rootless podman) as the single
secrets backend on Linux. All sensitive material — GitHub tokens, per-container
AppRole tokens, the Vault unseal key — lives inside Vault or in tmpfs-only podman
secrets. The legacy OS-keyring + `tillandsias-github-token` podman-secret path
was removed in v0.3.

### Secret Types

| Secret | Scope | Lifetime | Storage | Used By |
|--------|-------|----------|---------|---------|
| **Vault unseal key** | Per-installation | Indefinite (HKDF-derived) | tmpfs podman secret | Vault container |
| **GitHub Token** (in Vault) | Per-user session | Until logout | Vault `secret/github/token` | git-mirror container |
| **Per-container AppRole token** | Per-container lifetime | 1h TTL, 24h max | tmpfs podman secret `vault-token` | git-mirror, forge |
| **CA Cert + Key** | Per-session | Tray uptime | tmpfs podman secret | Proxy (SSL bump) |

### Vault Secret Paths

| Path | Content | Written By | Read By |
|------|---------|-----------|---------|
| `secret/github/token` | GitHub OAuth token | `tillandsias --github-login` | git-mirror via `vault-cli` |
| `auth/approle/role/<name>/role-id` | AppRole Role ID | Tray bootstrap | Container entrypoint |
| `auth/approle/role/<name>/secret-id` | AppRole Secret ID | Tray bootstrap | Container entrypoint |

### Podman Secret Names

| Secret Name | Type | Lifetime | Container | Path |
|---|---|---|---|---|
| `tillandsias-vault-unseal` | HKDF-derived key hex | Tray uptime (tmpfs) | vault | `/run/secrets/vault-unseal` |
| `tillandsias-vault-token-<role>-<id>` | AppRole token | Container lifetime (tmpfs) | per-role | `/run/secrets/vault-token` |
| `tillandsias-ca-cert` | X.509 cert | Session (tmpfs) | proxy, forge | `/run/secrets/tillandsias-ca-cert` |
| `tillandsias-ca-key` | Private key | Session (tmpfs) | proxy, forge | `/run/secrets/tillandsias-ca-key` |

### Architecture: Vault-Native Secret Flow

1. **Tray startup** derives the Vault unseal key from `machine-id` + `installation-uuid`
   via HKDF and creates the `tillandsias-vault-unseal` tmpfs podman secret.

2. **Vault container** initialises on first boot, runs `vault operator rekey` to
   install the HKDF-derived key as the active Shamir share, and deletes
   `init.json`. The root token is captured by `tillandsias-headless` and stored
   in the host keychain; `root.token` is deleted from the Vault data volume.

3. **`tillandsias --github-login`** runs `gh auth login` inside a container,
   reads the resulting token, and writes it to Vault at `secret/github/token`
   using a write-capable AppRole lease.

4. **Per-container token minting**: For each container launch (git-mirror, forge,
   etc.), the tray mints a scoped AppRole token via `vault token create
   -policy=<role-policy> -ttl=1h`, creates a tmpfs podman secret
   `tillandsias-vault-token-<role>-<id>`, and mounts it at `/run/secrets/vault-token`.

5. **Inside the container**, the baked `vault-cli` helper reads the GitHub token:
   ```sh
   TOKEN="$(vault-cli read -field=token secret/github/token)"
   ```

6. **On shutdown**, the tray revokes all minted AppRole tokens via
   `vault token revoke <token>` and removes the corresponding podman secrets.

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

## Implementation: Vault-Native Secret Flow

### Step 1: Vault Bootstrap (`images/vault/entrypoint.sh`)

```bash
# Derive unseal key from machine-id + installation-uuid via HKDF
UNSEAL_KEY_HEX=$(xxd -p -c 64 < /run/secrets/vault-unseal)

# Initialize on first boot, then rekey
if ! vault status 2>/dev/null | grep -q 'Initialized.*true'; then
  vault operator init -key-shares=1 -key-threshold=1 \
    -recovery-shares=0 -format=json > /vault/data/init.json
  ROOT_TOKEN=$(jq -r '.root_token' < /vault/data/init.json)
  vault operator rekey -init -key-shares=1 -key-threshold=1 \
    <(echo "$UNSEAL_KEY_HEX") 2>/dev/null
  rm /vault/data/init.json
fi

vault operator unseal "$UNSEAL_KEY_HEX"
```

### Step 2: Tray Token Minting (`vault_bootstrap.rs`)

```rust
// Mint a scoped AppRole token for a container kind
let token = client.create_token("git-mirror-policy", 3600).await?;
let secret_name = format!("tillandsias-vault-token-git-mirror-{}", id);
podman::secret::create(&secret_name, &token)?;
```

### Step 3: Per-Container Podman Secret Mount

```rust
    // In container launch: mount the vault-token + CA certs
    run_args.push("--secret", "tillandsias-vault-token-git-mirror-abc123");
    if podman::secret::exists("tillandsias-ca-cert")? {
        run_args.push("--secret", "tillandsias-ca-cert");
        run_args.push("--secret", "tillandsias-ca-key");
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

# GitHub token — read from Vault via the baked vault-cli helper.
# The AppRole token is mounted at /run/secrets/vault-token by the
# tray at container launch time.
TOKEN="$(vault-cli read -field=token secret/github/token)"
export GIT_CREDENTIAL_CACHE_DAEMON_TIMEOUT=1

# CA certificate (mounted as tmpfs podman secret)
if [[ -f /run/secrets/tillandsias-ca-cert ]]; then
    export GIT_SSL_CAINFO="/run/secrets/tillandsias-ca-cert"
fi

# Start git daemon
exec git daemon --verbose --listen=0.0.0.0 --base-path=/var/lib/git
```

### Step 4: Shutdown Cleanup (`vault_bootstrap.rs`)

```rust
// Revoke all per-container AppRole tokens
vault_bootstrap::revoke_pending_container_tokens(false).await;

// CA cert podman secrets cleaned by podman GC on container stop
```

## Comparison: Old (Podman Secret) vs. Current (Vault-Native)

### Old (Keyring → Podman Secret — removed in v0.3)

```rust
// ❌ REMOVED — token extracted to host process, podman secret persisted
podman::secret::create("tillandsias-github-token", token)?;
let run_args = vec!["--secret=tillandsias-github-token"];
```

### Current (Vault-native — v0.3+)

```rust
// ✅ Token stays inside a container; tray only holds a short-lived
// AppRole token that can read secret/github/token.
let token = vault_client.read("secret/github/token").await?;
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

## File Locations (Vault-Native)

```
Host System
└── ~/.local/share/containers/storage/secrets/
    ├── tillandsias-vault-unseal (tmpfs, HKDF-derived key)
    ├── tillandsias-vault-token-git-mirror-<id> (tmpfs, AppRole token)
    ├── tillandsias-vault-token-forge-<id> (tmpfs, AppRole token)
    ├── tillandsias-ca-cert (tmpfs)
    └── tillandsias-ca-key (tmpfs)

Vault Container (tillandsias-vault-data volume)
├── secret/github/token (persisted GitHub token)
├── auth/approle/role/<name>/role-id
└── auth/approle/role/<name>/secret-id

Container Runtime
└── /run/secrets/ (tmpfs, created by podman)
    ├── vault-token (AppRole token, 644)
    ├── tillandsias-ca-cert (644)
    └── tillandsias-ca-key (600)
```

## Monitoring and Logging

### Audit Events (Tillandsias Accountability Logging)

```rust
// Log token minting for compliance
info!(
    accountability = true,
    category = "secrets",
    spec = "tillandsias-vault",
    action = "token_create",
    role = "git-mirror",
    "AppRole token minted for container launch"
);

// Log Vault read from inside container
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

## Unclean Shutdown Recovery

### Problem
If the tray crashes or is force-killed (e.g., `pkill -9 tillandsias`), the normal shutdown sequence never runs. Podman secrets persist in the system, and on the next tray startup, secret creation fails with:

```
Error: tillandsias-ca-root: secret name in use
```

### Solution (Automatic)
Tillandsias now automatically refreshes stale secrets on each startup:

1. **Check if stale secret exists**: `podman secret exists tillandsias-ca-root`?
2. **If yes, remove it**: `podman secret rm tillandsias-ca-root` (idempotent, safe)
3. **Create fresh secret**: `podman secret create tillandsias-ca-root <fresh-cert>`

This happens transparently during tray initialization. You will see a warning log:

```
WARN tillandsias::handlers: Removing stale CA secret from unclean shutdown {secret="tillandsias-ca-root", spec="ephemeral-secret-refresh, secrets-management"}
```

This is **normal and expected** after an unclean shutdown. The tray will continue startup without user intervention.

### Manual Recovery (Rarely Needed)
If for some reason you see "secret name in use" errors and the tray doesn't auto-recover:

```bash
# List all Tillandsias secrets
podman secret ls | grep tillandsias

# Remove stale secrets manually
podman secret rm tillandsias-ca-root tillandsias-ca-cert tillandsias-ca-key
podman secret rm tillandsias-github-token  # if it exists

# Verify all are gone
podman secret ls | grep tillandsias || echo "✓ Clean"

# Restart tray
tillandsias /path/to/project
```

**Do NOT manually remove secrets while tray is running** — this will cause containers to fail on next startup.

## Testing Checklist

- [ ] Verify `podman secret inspect` does NOT reveal secret values
- [ ] Verify `podman ps` does NOT show `--secret` flags as command-line args
- [ ] Verify `ps -eaux` does NOT show secret content in process environment
- [ ] Verify secrets are readable at `/run/secrets/<name>` inside containers
- [ ] Verify proxy can load CA cert from `/run/secrets/tillandsias-ca-cert`
- [ ] Verify git service can read token from Vault via `vault-cli` at push time
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
