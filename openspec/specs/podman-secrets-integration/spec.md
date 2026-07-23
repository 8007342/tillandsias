<!-- @trace spec:podman-secrets-integration -->
# podman-secrets-integration Specification

## Status

active

## Purpose

Tillandsias SHALL use podman's native secret mechanism (`podman secret`) as the
transport for credential material that must cross the host-container boundary
(CA certificates, Vault unseal key, per-container Vault tokens). Secrets are
created at tray startup as ephemeral tmpfs-backed artifacts, mounted into
containers via `--secret` flag (not bind mounts or environment variables), and
cleaned up on tray shutdown. Long-lived credentials (including the GitHub token
and provider credentials) live inside Vault and are read only by a service or
provider lane whose AppRole policy names the exact path. Long-lived credential
values never cross the host-container boundary as podman secrets; the mounted
secret contains only the short-lived Vault token.

@trace spec:podman-secrets-integration

## Secret Names Registry

All ephemeral podman secrets use the following names. These names are hardcoded
and MUST match across all references (creation, mounting, entrypoint reading).

| Secret Name | Purpose | Created In | Mounted To | Read At |
|---|---|---|---|---|
| `tillandsias-ca-root` | Root CA certificate (for cert chain validation) | `main.rs:ensure_ca_bundle()` | None (archive only) | N/A |
| `tillandsias-ca-cert` | Intermediate CA certificate (for MITM proxy) | `main.rs:ensure_ca_bundle()` | proxy, forge | `/run/secrets/tillandsias-ca-cert` |
| `tillandsias-ca-key` | Intermediate CA private key (for MITM proxy) | `main.rs:ensure_ca_bundle()` | proxy, forge | `/run/secrets/tillandsias-ca-key` |
| `tillandsias-vault-unseal` | Vault auto-unseal HKDF key | `vault_bootstrap.rs:ensure_unseal_key()` | vault container | `/run/secrets/tillandsias-vault-unseal` |
| `tillandsias-vault-tls-cert` | Vault HTTPS leaf certificate | `vault_bootstrap.rs:ensure_vault_tls_leaf()` | vault container | `/run/secrets/tillandsias-vault-tls-cert` |
| `tillandsias-vault-tls-key` | Vault HTTPS leaf private key | `vault_bootstrap.rs:ensure_vault_tls_leaf()` | vault container | `/run/secrets/tillandsias-vault-tls-key` |
| `tillandsias-vault-tls-ca` | Vault HTTPS issuer CA certificate | `vault_bootstrap.rs:refresh_vault_tls_secrets()` | vault container | `/run/secrets/tillandsias-vault-tls-ca` |
| `tillandsias-vault-token-<role>-<id>` | Per-container AppRole token | `vault_bootstrap.rs:mint_container_token()` | git service or explicitly credentialed provider forge | `/run/secrets/vault-token` |

**Critical**: Secret name references MUST be identical in:
1. `crates/tillandsias-headless/src/main.rs` / `vault_bootstrap.rs` — creation
2. `crates/tillandsias-podman/src/launch.rs` — `--secret=` flags
3. Container entrypoints (`images/proxy/entrypoint.sh`, `images/git/entrypoint.sh`) — reading from `/run/secrets/<name>`
4. This spec document — documented in the table above

Any mismatch between these locations is a critical bug that prevents containers
from accessing credentials.

## Requirements

### Requirement: Ephemeral secrets created at tray startup

The tray process MUST create all ephemeral secrets during initialization, before
any containers are launched. Secrets MUST be created once per tray session and
persisted in podman's storage backend (tmpfs by default in rootless mode) until
explicitly removed.

@trace spec:podman-secrets-integration

#### Scenario: Vault unseal key secret created at startup
- **WHEN** the tray initializes
- **THEN** the tray MUST derive the unseal key via HKDF-SHA256 from machine-id
  + installation-uuid
- **AND** MUST call `podman secret create tillandsias-vault-unseal <key>` (file driver)
- **AND** an accountability log entry MUST record `action="secret_create"`,
  `secret_name="tillandsias-vault-unseal"`, `category="secrets"`,
  `spec="podman-secrets-integration"`
- **AND** the unseal key SHALL be stored in the host OS keychain for reuse
  across restarts.

#### Scenario: Vault token secret created per container launch
- **WHEN** a git-mirror container is launched and Vault is running
- **THEN** the tray MUST mint a `git-mirror-policy` scoped AppRole token with
  TTL 1h
- **AND** MUST call `podman secret create tillandsias-vault-token-git-mirror-<id> <token>`
- **AND** MUST mount it at `/run/secrets/vault-token`
- **AND** the token SHALL be revoked when the container stops.

#### Scenario: CA certificate and key secrets created
- **WHEN** the tray initializes
- **THEN** the tray MUST generate an ephemeral CA certificate and key (valid for 24 hours)
- **AND** MUST call `podman secret create tillandsias-ca-cert <cert_pem>` (file driver)
- **AND** MUST call `podman secret create tillandsias-ca-key <key_pem>` (file driver)
- **AND** accountability log entries MUST record both creations with
  `spec="podman-secrets-integration"`, `action="secret_create"`

### Requirement: Secrets mounted via `--secret` flag, never bind mounts

All credential material MUST be mounted into containers using podman's `--secret`
flag, which places secrets at `/run/secrets/<name>` inside the container (tmpfs,
read-only, inaccessible to `podman inspect`). Bind mounts for credentials are
MUST_NOT be used.

@trace spec:podman-secrets-integration

#### Scenario: Proxy container receives CA secrets
- **WHEN** the proxy container is launched
- **THEN** the tray MUST add `--secret=tillandsias-ca-cert` and
  `--secret=tillandsias-ca-key` to the `podman run` command
- **AND** the container's entrypoint MUST read from `/run/secrets/tillandsias-ca-cert`
  and `/run/secrets/tillandsias-ca-key`
- **AND** MUST NOT receive bind-mounted files (no `-v /host/path:/container/path` for certs)

#### Scenario: Vault container receives unseal key
- **WHEN** the vault container is launched
- **THEN** the tray MUST add `--secret=tillandsias-vault-unseal` to the `podman run` command
- **AND** the vault entrypoint MUST read the unseal key from `/run/secrets/vault-unseal`
- **AND** the unseal key SHALL NOT appear in environment variables or bind mounts.

#### Scenario: Git service container receives Vault AppRole token
- **WHEN** the git service container is launched and Vault is running
- **THEN** the tray MUST add `--secret=tillandsias-vault-token-<id>,target=vault-token,mode=0400`
- **AND** the container's entrypoint MUST read the token from `/run/secrets/vault-token`
- **AND** the container MUST receive `VAULT_ADDR=http://vault:8200` and
  `VAULT_ROLE=git-mirror`
- **AND** the container MUST NOT receive the token via environment variables or bind mounts

#### Scenario: Configured OpenCode receives a provider-scoped AppRole token
- **WHEN** a Gemini API key exists in Vault and an OpenCode or OpenCode Web
  forge is launched
- **THEN** the tray MUST add
  `--secret=tillandsias-vault-token-opencode-forge-<id>,target=vault-token,uid=1000,gid=1000,mode=0400`
- **AND** the container MUST receive `VAULT_ROLE=opencode-forge`
- **AND** the Gemini key and derived `OPENCODE_AUTH_CONTENT` document MUST NOT
  appear in Podman argv or launcher logs
- **AND** the entrypoint MAY export the derived document only inside the
  OpenCode process environment after reading Vault.

#### Scenario: Provider-free forge containers receive no credential mount
- **WHEN** a maintenance forge or an OpenCode forge without a configured
  Gemini key is launched
- **THEN** the tray MUST NOT add any provider `--secret` flag
- **AND** the forge container MUST have zero provider credential mounts
- **AND** an accountability log entry MUST record
  `credential-free (no token mounts)`, `spec="podman-secrets-integration"`

#### Scenario: Terminal containers receive no credentials
- **WHEN** a terminal or root terminal container is launched
- **THEN** the tray MUST NOT add any `--secret` flags for credentials
- **AND** the terminal container MUST have zero credential mounts

### Requirement: Secrets readable at `/run/secrets/<name>` inside containers

Podman automatically mounts secrets at the read-only path `/run/secrets/<name>`.
Container entrypoints MUST read secrets from this fixed location. The
implementation MUST NOT assume custom mount paths or symlinks.

@trace spec:podman-secrets-integration

#### Scenario: Secret file is readable
- **WHEN** a container with `--secret=tillandsias-vault-token-<id>` starts
- **THEN** `/run/secrets/vault-token` MUST exist and be readable (mode `0400` or tighter)
- **AND** the file content MUST match the secret value created on the host

#### Scenario: Secret file is read-only
- **WHEN** a container reads a secret at `/run/secrets/<name>`
- **THEN** write access MUST fail with `EACCES` (permission denied)
- **AND** the file mode MUST have write bit disabled

#### Scenario: Secrets accessible to all processes in container
- **WHEN** any process inside the container (UID 1000, UID 0) attempts to read
  `/run/secrets/<name>`
- **THEN** read access MUST succeed (SELinux policy allows `container_t` to read
  `container_file_t`)
- **AND** Secrets MUST NOT be isolated to UID 1000 only (all container processes
  see secrets)

### Requirement: Secrets hidden from `podman inspect` and process environment

The `podman inspect` command MUST NOT reveal secret values. Secrets MUST NOT
appear in container environment variables, process `ps` listings, or container
logs.

@trace spec:podman-secrets-integration

#### Scenario: podman inspect does not reveal secret content
- **WHEN** `podman inspect <container>` is run on a running container with
  `--secret=tillandsias-ca-cert`
- **THEN** the output MAY list the secret name in the `.Secrets` field (if
  supported by podman version)
- **AND** the secret value MUST NOT appear anywhere in the output
- **AND** no `--secret` flag value MUST appear in the `.Config.Cmd` or
  `.Config.Entrypoint` fields

#### Scenario: Secrets not in container environment
- **WHEN** a process inside the container runs `env` or `printenv`
- **THEN** the output MUST NOT contain `GITHUB_TOKEN`, `VAULT_TOKEN`,
  `CA_CERT`, or similar variable names containing secret values
- **AND** the entrypoint MUST read `/run/secrets/<name>` and MUST NOT export
  environment variables

#### Scenario: Secrets not in process list
- **WHEN** a user on the host runs `ps -eaux` or `podman ps` while containers
  are running
- **THEN** the output MUST NOT show secret content in command-line arguments
- **AND** secrets MUST be listed only as mounted artifacts (not visible in
  process args)

### Requirement: All secrets cleaned up on tray shutdown

The tray process MUST remove all ephemeral secrets on graceful shutdown. A Drop
guard MUST ensure cleanup even in panic or signal-based termination. Cleanup
MUST be idempotent.

@trace spec:podman-secrets-integration

#### Scenario: Secrets removed on normal shutdown
- **WHEN** the tray receives a termination signal (SIGTERM, SIGINT) and begins
  graceful shutdown
- **THEN** the cleanup code MUST call `podman secret rm tillandsias-vault-unseal`
  (if exists)
- **AND** MUST call `podman secret rm tillandsias-ca-cert` and
  `podman secret rm tillandsias-ca-key`
- **AND** MUST call `podman secret rm tillandsias-vault-tls-cert`,
  `podman secret rm tillandsias-vault-tls-key`, and
  `podman secret rm tillandsias-vault-tls-ca`
- **AND** `tillandsias-vault-token-*` secrets are revoked by Vault token
  revocation in `revoke_pending_container_tokens()`
- **AND** accountability log entries MUST record `action="secret_cleanup"`,
  `spec="podman-secrets-integration"` for each secret removed
- **AND** the tray MUST exit after all secrets are cleaned

#### Scenario: Secrets removed on panic
- **WHEN** the tray panics or crashes
- **THEN** a Drop guard (or signal handler) MUST trigger the cleanup code
- **AND** all ephemeral secrets MUST be removed from podman storage
- **AND** a warning log entry MUST record
  `"Panic cleanup triggered; removing ephemeral secrets"`

#### Scenario: Cleanup is idempotent
- **WHEN** the cleanup code calls `podman secret rm tillandsias-vault-unseal`
  and the secret does not exist
- **THEN** the command MUST return success (exit code 0) or handle the ENOENT
  gracefully
- **AND** MUST NOT propagate an error up the call stack

#### Scenario: No secrets remain after tray exit
- **WHEN** the tray has exited cleanly (normal or via crash)
- **AND** a user runs `podman secret ls | grep tillandsias`
- **THEN** the output MUST be empty (no secrets matching `tillandsias-*`)

### Requirement: Secrets creation uses podman filedriver (default)

The tray MUST use podman's default file driver (plaintext in podman storage) for
all ephemeral secrets. No custom drivers (pass, shell) are required for this
capability.

@trace spec:podman-secrets-integration

#### Scenario: File driver is used
- **WHEN** the tray calls `podman secret create tillandsias-vault-unseal <key>`
- **THEN** podman MUST use the default file driver
- **AND** the secret MUST be stored in
  `~/.local/share/containers/storage/secrets/filedriver/`
- **AND** the secret MUST be listed in `podman secret ls` output

#### Scenario: No custom driver configuration required
- **WHEN** the tray initializes
- **THEN** the tray MUST NOT require or configure podman secret drivers
- **AND** no driver selection logic MUST be present in the implementation

### Requirement: Accountability logging for all secret operations

Every secret operation (creation, access, deletion) MUST be logged to the
accountability system with at minimum `category="secrets"`,
`spec="podman-secrets-integration"`, and the operation name. No secret values
MUST appear in logs.

@trace spec:podman-secrets-integration

#### Scenario: Secret creation logged
- **WHEN** `podman secret create tillandsias-vault-unseal ...` completes
- **THEN** the tray MUST log: `action="secret_create"`,
  `secret_name="tillandsias-vault-unseal"`, `category="secrets"`,
  `spec="podman-secrets-integration"`
- **AND** the log entry MUST NOT contain the secret value, a hash of the value,
  or any derivable hint

#### Scenario: Secret cleanup logged
- **WHEN** `podman secret rm tillandsias-vault-unseal` completes
- **THEN** the tray MUST log: `action="secret_cleanup"`,
  `secret_name="tillandsias-vault-unseal"`,
  `spec="podman-secrets-integration"`

#### Scenario: Container launch with secrets logged
- **WHEN** a container is launched with `--secret=tillandsias-ca-cert`
- **THEN** the tray MUST log: `container_name="tillandsias-proxy-..."`,
  `mounted_secrets=["tillandsias-ca-cert", "tillandsias-ca-key"]`,
  `spec="podman-secrets-integration"`

### Requirement: CA certificate generation is ephemeral and per-session

CA certificates MUST be generated anew at each tray startup, valid for 24 hours,
and MUST NOT be persisted to disk. The cert and key MUST be created in-memory
and immediately converted to podman secrets.

@trace spec:podman-secrets-integration

#### Scenario: CA cert generated at startup
- **WHEN** the tray initializes
- **THEN** the tray MUST call a CA generation function (e.g.,
  `ca::generate_ephemeral_ca()`)
- **AND** the function MUST return (cert_pem, key_pem) as in-memory strings
- **AND** no intermediate files MUST be written to disk (not even in `/tmp/`)

#### Scenario: CA cert valid for 24 hours
- **WHEN** a CA certificate is generated
- **THEN** the certificate's `notAfter` field MUST be 24 hours from generation time
- **AND** the certificate's `notBefore` field MUST be `now` (or a few seconds past)

#### Scenario: Different cert on each tray restart
- **WHEN** the tray is stopped and restarted
- **THEN** a new CA certificate MUST be generated with a new serial number
- **AND** the new cert's fingerprint MUST differ from the previous session's cert
- **AND** containers using the old cert's key for SSL bump MUST restart to pick
  up the new one

## Litmus Tests

The following automated tests verify the implementation:

- `litmus:opencode-vault-auth-content` verifies the provider-scoped token
  mount shape while credential bytes remain absent from launcher argv, and
  verifies the free lane has no token mount.

### Test 1: Secrets created on startup
```bash
# After tray starts, verify secrets exist
podman secret ls | grep -E "tillandsias-(ca-cert|ca-key|vault-unseal|vault-token-)"
# Expected: 3+ lines (ca-cert, ca-key, vault-unseal; vault-token lines appear
# when git containers launch)
```

### Test 2: Secrets not visible in inspect
```bash
# Start a container with secrets
podman run --secret=tillandsias-ca-cert --secret=tillandsias-ca-key <image> sleep 100

# Inspect container
podman inspect <container> | grep -i secret

# Expected: secret names listed (if podman version supports it), but values hidden
```

### Test 3: Secrets not in process environment
```bash
# Inside a container with --secret=tillandsias-ca-cert
env | grep -iE "token|secret|key|cert"
# Expected: (empty output — no credential env vars)
```

### Test 4: Secrets readable at /run/secrets/
```bash
# Inside a vault container
cat /run/secrets/vault-unseal
# Expected: (unseal key contents printed; file exists and is readable)
```

### Test 5: Secrets cleaned up on shutdown
```bash
# Before tray startup:
podman secret ls | grep tillandsias
# Expected: (empty output)

# After tray starts:
podman secret ls | grep tillandsias
# Expected: 3+ lines (secrets created)

# After tray shutdown:
podman secret ls | grep tillandsias
# Expected: (empty output — all cleaned)
```

### Test 6: Accountability logs record operations
```bash
# After tray startup, check logs
grep 'action="secret_create"' ~/.cache/tillandsias/logs/accountability.jsonl
# Expected: 3+ lines (one per secret created)

# After tray shutdown
grep 'action="secret_cleanup"' ~/.cache/tillandsias/logs/accountability.jsonl
# Expected: 3+ lines (one per secret removed)
```

### Test 7: Proxy reads CA cert from /run/secrets/
```bash
# Container logs should show cert loaded, no bind mounts used
podman logs <proxy-container> | grep -i "cert"
# Expected: evidence that cert was loaded from /run/secrets/, NOT from a bind mount
```

### Test 8: CA certificate is different on each restart
```bash
# Extract cert fingerprint from first session
CERT1=$(podman run --secret=tillandsias-ca-cert <image> openssl x509 -in /run/secrets/tillandsias-ca-cert -fingerprint -noout)
# Restart tray, extract cert fingerprint from second session
CERT2=$(podman run --secret=tillandsias-ca-cert <image> openssl x509 -in /run/secrets/tillandsias-ca-cert -fingerprint -noout)
# Expected: CERT1 != CERT2 (different fingerprints, new cert each session)
```

## Sources of Truth

- `cheatsheets/utils/podman-secrets.md` — Podman secrets mechanism, storage, and API
- `cheatsheets/runtime/hashicorp-vault-tillandsias.md` — Vault bootstrap, unseal, and token minting walkthrough

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-secrets-integration" crates/ scripts/ images/ --include="*.rs" --include="*.sh"
```

Related specs:
```bash
grep -rn "podman-secrets-integration" openspec/specs/ --include="*.md"
```
