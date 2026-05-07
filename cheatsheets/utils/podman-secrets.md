---
tags: [podman, secrets, tmpfs, security, credentials]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://docs.podman.io/
  - https://docs.podman.io/en/latest/markdown/podman-secret.1.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman Secrets: Secure Secret Management

**Use when**: Passing sensitive data (credentials, certificates, keys, tokens) to containers securely without exposing them in command-line arguments, environment variables, or process listings.

## Provenance

- [Podman Documentation: Secrets](https://docs.podman.io/en/latest/_static/api.html#tag/Secrets) — official podman secrets API
- [Podman Secret Man Page](https://man.archlinux.org/man/podman-secret.1.en) — CLI reference
- [Red Hat Container Security Best Practices](https://access.redhat.com/articles/3757761) — secrets handling in containers
- **Last updated:** 2026-05-03

## Critical Implementation Detail: Secret Names Must Match

**GOTCHA**: Podman does NOT validate that secret names used in `podman run --secret=<name>` actually exist. If you try to mount a non-existent secret, the `podman run` command silently fails or the container exits with a cryptic error.

When implementing secrets:
1. Secret creation: `podman secret create <name> <source>` must use the exact name
2. Secret mounting: `podman run --secret=<name>` must use the **same exact name**
3. Container reading: `/run/secrets/<name>` must match the name above
4. Any mismatch will silently fail at container startup time

Example of the bug:
```bash
# Created as "github-token"
podman secret create github-token <value>

# But mounted as "github-secret" (typo!)
podman run --secret=github-secret myimage

# Result: Container starts but secret doesn't exist, reads from /run/secrets/github-secret fail
```

Always grep your codebase to ensure secret names are consistent across creation, mounting, and reading.

## What Are Podman Secrets?

Podman secrets are a built-in mechanism for managing sensitive data that containers need at runtime. Unlike environment variables or bind mounts, secrets:

- **Are NOT exposed** in `podman ps`, `ps -fea`, or container environment dumps
- **Are NOT logged** in container startup commands or audit trails
- **Are mounted read-only** at `/run/secrets/<name>` inside containers
- **Are stored securely** in the podman storage backend (filesystem, encrypted)
- **Support multiple drivers** (file, pass, shell) for different use cases
- **Are rootless-safe** — work with `--userns=keep-id` without permission issues

## Storage Location

Secrets are stored in the podman storage backend, typically:
```
~/.local/share/containers/storage/secrets/filedriver/  (file driver)
```

Drivers:
- **file** (default): Secrets stored as plaintext files in storage
- **pass**: External password manager (e.g., `pass`, GPG-encrypted)
- **shell**: Shell command that outputs the secret (e.g., `secret-tool get tillandsias github`)

## Security Properties

### NOT Exposed In

- Container process list: `podman ps`, `docker ps`
- Process environment: `ps -eaux`, `env`, `printenv` inside container
- Container startup logs: secrets don't appear in `podman logs`
- Container inspect output: secrets are listed but **values are not shown**
- Audit trails: podman audit events list secret usage but not content

### ARE Stored In

- `/run/secrets/<name>` inside the container (tmpfs by default in rootless mode)
- Podman storage backend (filesystem, can be encrypted with `dm-crypt` or LUKS)
- Container init process has access (PID 1), propagates to child processes

### Comparison Matrix

| Method | Exposed in ps? | Logged in audit? | Survives restart? | Works with --userns=keep-id? |
|--------|---|---|---|---|
| **Bind mount file** | ❌ No | ❌ No | ✅ Yes (if persistent) | ⚠️ Permission issues |
| **Environment var** | ✅ YES (visible) | ✅ YES | ✅ Yes | ✅ Yes |
| **Podman secret** | ❌ No | ⚠️ Usage logged, not value | ❌ No (ephemeral) | ✅ Yes |
| **Podman secret + driver:pass** | ❌ No | ⚠️ Usage logged, not value | ❌ No (ephemeral) | ✅ Yes |

## Usage: Create Secrets

### From stdin

```bash
# Create from piped data
echo "my-secret-token" | podman secret create github-token -

# Create from environment variable
podman secret create github-token --env GITHUB_TOKEN

# Create from file
podman secret create ca-cert /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
```

### File driver (default, plaintext storage)

```bash
podman secret create my-secret /path/to/file
```

Storage location: `~/.local/share/containers/storage/secrets/filedriver/`

### Pass driver (GPG-encrypted external storage)

```bash
# Requires: install `pass` package and GPG keys configured
podman secret create --driver=pass my-secret pass-entry-name
```

Stores secret in `pass` (password manager), encrypted with your GPG key.

### Shell driver (dynamic retrieval)

```bash
# Requires: shell command that outputs secret
podman secret create --driver=shell github-token "secret-tool get tillandsias github"
```

Executes the command each time the secret is needed (useful for short-lived tokens).

## Usage: Mount Secrets in Containers

### In podman run

```bash
podman run \
  --secret=github-token \
  --secret=ca-cert \
  myimage
  
# Inside container:
# /run/secrets/github-token (contains token text)
# /run/secrets/ca-cert (contains PEM cert)
```

### With custom mount path

Secrets are ALWAYS mounted at `/run/secrets/<name>`. To use a different path:

```bash
# Option 1: Symlink in entrypoint
ln -s /run/secrets/ca-cert /etc/ssl/certs/ca.pem

# Option 2: Copy in entrypoint
cp /run/secrets/ca-cert /tmp/ca.pem && chmod 644 /tmp/ca.pem
```

### With SELinux

Podman automatically labels secrets with SELinux types that allow container processes to read them:

```bash
# No special flags needed — SELinux enforcement is automatic
podman run --secret=my-secret myimage
```

SELinux policy:
- Container process can READ `/run/secrets/*`
- Container process CANNOT WRITE to `/run/secrets/*`
- Host processes CANNOT READ `/run/secrets/*` from container namespace

## Usage: List and Inspect Secrets

```bash
# List all secrets
podman secret ls

# Inspect (does NOT show secret value)
podman secret inspect github-token

# Remove secret
podman secret rm github-token

# Check if secret exists
podman secret exists github-token && echo "exists" || echo "not found"
```

## Real-World Examples

### GitHub Token for Container

```bash
# Retrieve from OS keyring (GNOME Keyring, KDE Wallet, etc.)
TOKEN=$(secret-tool lookup tillandsias github)

# Create ephemeral secret (lives only for this session)
podman secret create github-token --env GITHUB_TOKEN

# Launch container with secret
podman run \
  --secret=github-token \
  --env GITHUB_TOKEN_FILE=/run/secrets/github-token \
  myimage bash -c "git clone https://$(cat /run/secrets/github-token)@github.com/user/repo.git"
```

### CA Certificate for HTTPS Proxy

```bash
# Generate CA cert
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.crt -days 30 -nodes

# Create secrets for cert and key
podman secret create proxy-ca-cert ca.crt
podman secret create proxy-ca-key ca.key

# Launch proxy with secrets
podman run \
  --secret=proxy-ca-cert \
  --secret=proxy-ca-key \
  squid-image \
  squid -N -f /etc/squid/squid.conf
```

Inside squid entrypoint:
```bash
# Copy from /run/secrets to /etc/squid/certs (with proper permissions)
cp /run/secrets/proxy-ca-cert /etc/squid/certs/intermediate.crt
cp /run/secrets/proxy-ca-key /etc/squid/certs/intermediate.key
chmod 600 /etc/squid/certs/intermediate.key
chown squid:squid /etc/squid/certs/intermediate.*
```

### Multi-Secret Binding (TLS Certificate Bundle)

```bash
# Create secrets for each part
podman secret create tls-cert server.crt
podman secret create tls-key server.key
podman secret create tls-ca ca-bundle.pem

# Launch with all three
podman run \
  --secret=tls-cert \
  --secret=tls-key \
  --secret=tls-ca \
  nginx-image

# In container entrypoint
cat /run/secrets/tls-cert > /etc/nginx/tls.crt
cat /run/secrets/tls-key > /etc/nginx/tls.key
cat /run/secrets/tls-ca > /etc/nginx/ca.pem
```

## Ephemeral vs. Persistent Secrets

### Ephemeral Secrets (session-only)

```bash
# Created in script, lives for script duration only
TOKEN=$(secret-tool lookup tillandsias github)
podman secret create github-token --env GITHUB_TOKEN

# When podman session ends or secret is removed, data is gone
podman secret rm github-token
```

**Use for:** CA certificates, tokens, credentials that are session-scoped.

### Persistent Secrets (system-wide)

```bash
# Created once, persists across podman sessions
podman secret create system-api-key /path/to/key
podman secret exists system-api-key  # Still exists in future sessions
```

**Use for:** Long-lived credentials shared across multiple containers/pods.

## Security Implications

### What Podman Secrets Protect Against

✅ Accidental exposure in `podman inspect` output
✅ Secrets visible in `ps -eaux` process listings
✅ Secrets in container logs
✅ Secrets in audit trails (content is never logged, only usage)
✅ Secrets readable by other host users (with proper filesystem permissions)
✅ Secrets in environment variable dumps inside container

### What Podman Secrets Do NOT Protect Against

❌ **Root user on host**: Root can always read anything
❌ **Container escape**: If container is compromised, secret is readable by the escaped process
❌ **Privileged containers**: `--cap-add=SYS_PTRACE` can dump container memory
❌ **Source code secrets**: Secrets in git, source files, or Docker images

### Best Practices

1. **Never store secrets in container images** — use secrets at runtime
2. **Rotate credentials regularly** — recreate secrets, remove old ones
3. **Use least privilege** — containers only get secrets they actually need
4. **Audit secret usage** — review `podman secret ls` logs regularly
5. **Encrypt storage** — use `pass` driver or filesystem encryption for persistent secrets
6. **Clean up on exit** — remove ephemeral secrets when container/service stops

## Tillandsias-Specific Recommendations

### For CA Certificates

```bash
# In tray initialization:
# Generate ephemeral CA
openssl req ... > /tmp/ca.crt  && chmod 644 /tmp/ca.crt

# Create secret (from tmpfs, no disk persistence)
podman secret create tillandsias-ca /tmp/ca.crt

# Pass to proxy container
podman run --secret=tillandsias-ca tillandsias-proxy
```

### For GitHub Tokens

```bash
# Retrieve from OS keyring or prompt user
TOKEN=$(secret-tool lookup tillandsias github)

# Create ephemeral secret (lives only for this session)
podman secret create tillandsias-github-token --env GITHUB_TOKEN

# Git service reads from /run/secrets/
podman run --secret=tillandsias-github-token tillandsias-git
```

### For Encrypted Credentials (Future)

```bash
# If using pass driver:
podman secret create --driver=pass tillandsias-github-token github.com/tillandsias

# If using shell driver with secret-tool:
podman secret create --driver=shell tillandsias-github "secret-tool lookup tillandsias github"
```

## Implementation Checklist

- [ ] Replace CA cert bind mounts with `podman secret` in handlers.rs
- [ ] Replace GitHub token environment variable with `podman secret`
- [ ] Update proxy entrypoint to read from `/run/secrets/tillandsias-ca`
- [ ] Update git service entrypoint to read from `/run/secrets/tillandsias-github-token`
- [ ] Add secret cleanup on tray shutdown (remove ephemeral secrets)
- [ ] Add audit logging for secret operations (creation, access, deletion)
- [ ] Document in CLAUDE.md: "All container secrets are ephemeral, created at session start, destroyed on exit"

## Troubleshooting

### Secret Not Accessible in Container

```bash
# Check secret exists
podman secret ls

# Check secret is mounted
podman run --secret=mykey alpine ls -la /run/secrets/

# Check file permissions
podman run --secret=mykey alpine stat /run/secrets/mykey
```

### SELinux Denial

```bash
# Podman handles SELinux labels automatically — if denial occurs:
# Check container has system_r role (required for secret access)
podman run --security-opt label=type:spc_t --secret=mykey alpine
```

### Secret Data Leaks in Child Processes

If a child process inherits the secret file descriptor:

```bash
# In entrypoint, explicitly close after read:
TOKEN=$(cat /run/secrets/github-token)
exec "$@"  # Replace shell, closes all FDs except 0,1,2
```

## References

- Podman Secrets Architecture: [https://github.com/containers/podman/issues/7651](https://github.com/containers/podman/issues/7651)
- SELinux Labels for Secrets: [https://man.archlinux.org/man/containers-certs.d.5.en](https://man.archlinux.org/man/containers-certs.d.5.en)
- Docker Secrets (similar concept): [https://docs.docker.com/engine/swarm/secrets/](https://docs.docker.com/engine/swarm/secrets/)
