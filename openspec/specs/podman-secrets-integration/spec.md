<!-- @trace spec:podman-secrets-integration -->
# podman-secrets-integration Specification

## Status

status: active

## Purpose

Tillandsias SHALL use podman's native secret mechanism (`podman secret`) as the exclusive transport for all credential material (CA certificates, GitHub tokens, future SSH keys). Secrets are created at tray startup as ephemeral tmpfs-backed artifacts, mounted into containers via `--secret` flag (not bind mounts or environment variables), and cleaned up on tray shutdown. This migration eliminates credential exposure in `podman inspect`, process environment listings, and container logs.

@trace spec:podman-secrets-integration

## Requirements

### Requirement: Ephemeral secrets created at tray startup

The tray process SHALL create all ephemeral secrets during initialization, before any containers are launched. Secrets are created once per tray session and persisted in podman's storage backend (tmpfs by default in rootless mode) until explicitly removed.

@trace spec:podman-secrets-integration

#### Scenario: GitHub token secret created if token available
- **WHEN** the tray initializes and a GitHub token exists in the OS keyring
- **THEN** the tray SHALL call `podman secret create tillandsias-github-token <token>` (file driver, stdin)
- **AND** an accountability log entry SHALL record `action="secret_create"`, `secret_name="tillandsias-github-token"`, `category="secrets"`, `spec="podman-secrets-integration"`
- **AND** no log entry SHALL contain the token value

#### Scenario: CA certificate and key secrets created
- **WHEN** the tray initializes
- **THEN** the tray SHALL generate an ephemeral CA certificate and key (valid for 24 hours)
- **AND** call `podman secret create tillandsias-ca-cert <cert_pem>` (file driver)
- **AND** call `podman secret create tillandsias-ca-key <key_pem>` (file driver)
- **AND** accountability log entries SHALL record both creations with `spec="podman-secrets-integration"`, `action="secret_create"`

#### Scenario: No token available—silent degradation
- **WHEN** the tray initializes and the OS keyring has no GitHub token
- **THEN** the tray SHALL log a warning: `"GitHub token not available; cloning authenticated repos will fail"`
- **AND** SHALL NOT create `tillandsias-github-token` secret
- **AND** SHALL proceed to create CA cert/key secrets normally

### Requirement: Secrets mounted via `--secret` flag, never bind mounts

All credential material SHALL be mounted into containers using podman's `--secret` flag, which places secrets at `/run/secrets/<name>` inside the container (tmpfs, read-only, inaccessible to `podman inspect`). Bind mounts for credentials are forbidden.

@trace spec:podman-secrets-integration

#### Scenario: Proxy container receives CA secrets
- **WHEN** the proxy container is launched
- **THEN** the tray SHALL add `--secret=tillandsias-ca-cert` and `--secret=tillandsias-ca-key` to the `podman run` command
- **AND** the container's entrypoint SHALL read from `/run/secrets/tillandsias-ca-cert` and `/run/secrets/tillandsias-ca-key`
- **AND** SHALL NOT receive bind-mounted files (no `-v /host/path:/container/path` for certs)

#### Scenario: Git service container receives GitHub token
- **WHEN** the git service container is launched and `tillandsias-github-token` secret exists
- **THEN** the tray SHALL add `--secret=tillandsias-github-token` to the `podman run` command
- **AND** the container's entrypoint SHALL read the token from `/run/secrets/tillandsias-github-token`
- **AND** the `GIT_ASKPASS` environment variable SHALL point to a script that reads the token from the secret

#### Scenario: Forge containers receive no credentials
- **WHEN** a forge container (opencode, claude) is launched
- **THEN** the tray SHALL NOT add any `--secret` flags
- **AND** the forge container SHALL have zero credential mounts
- **AND** an accountability log entry SHALL record `credential-free (no token mounts)`, `spec="podman-secrets-integration"`

#### Scenario: Terminal containers receive no credentials
- **WHEN** a terminal or root terminal container is launched
- **THEN** the tray SHALL NOT add any `--secret` flags for credentials
- **AND** the terminal container SHALL have zero credential mounts

### Requirement: Secrets readable at `/run/secrets/<name>` inside containers

Podman automatically mounts secrets at the read-only path `/run/secrets/<name>`. Container entrypoints SHALL read secrets from this fixed location. The implementation SHALL NOT assume custom mount paths or symlinks.

@trace spec:podman-secrets-integration

#### Scenario: Secret file is readable
- **WHEN** a container with `--secret=tillandsias-github-token` starts
- **THEN** `/run/secrets/tillandsias-github-token` SHALL exist and be readable (mode `0644` or tighter)
- **AND** the file content SHALL match the secret value created on the host

#### Scenario: Secret file is read-only
- **WHEN** a container reads a secret at `/run/secrets/<name>`
- **THEN** write access SHALL fail with `EACCES` (permission denied)
- **AND** the file mode SHALL have write bit disabled

#### Scenario: Secrets accessible to all processes in container
- **WHEN** any process inside the container (UID 1000, UID 0) attempts to read `/run/secrets/<name>`
- **THEN** read access SHALL succeed (SELinux policy allows `container_t` to read `container_file_t`)
- **AND** secrets SHALL NOT be isolated to UID 1000 only (all container processes see secrets)

### Requirement: Secrets hidden from `podman inspect` and process environment

The `podman inspect` command SHALL NOT reveal secret values. Secrets SHALL NOT appear in container environment variables, process `ps` listings, or container logs.

@trace spec:podman-secrets-integration

#### Scenario: podman inspect does not reveal secret content
- **WHEN** `podman inspect <container>` is run on a running container with `--secret=tillandsias-github-token`
- **THEN** the output SHALL list the secret name in the `.Secrets` field (if supported by podman version)
- **AND** the secret value SHALL NOT appear anywhere in the output
- **AND** no `--secret` flag SHALL appear in the `.Config.Cmd` or `.Config.Entrypoint` fields

#### Scenario: Secrets not in container environment
- **WHEN** a process inside the container runs `env` or `printenv`
- **THEN** the output SHALL NOT contain any `GITHUB_TOKEN`, `CA_CERT`, or similar variable names containing secret values
- **AND** the entrypoint SHALL read `/run/secrets/<name>` and NOT export environment variables

#### Scenario: Secrets not in process list
- **WHEN** a user on the host runs `ps -eaux` or `podman ps` while containers are running
- **THEN** the output SHALL NOT show secret content in command-line arguments
- **AND** secrets SHALL be listed only as mounted artifacts (not visible in process args)

### Requirement: All secrets cleaned up on tray shutdown

The tray process SHALL remove all ephemeral secrets on graceful shutdown. A Drop guard SHALL ensure cleanup even in panic or signal-based termination. Cleanup is idempotent.

@trace spec:podman-secrets-integration

#### Scenario: Secrets removed on normal shutdown
- **WHEN** the tray receives a termination signal (SIGTERM, SIGINT) and begins graceful shutdown
- **THEN** the cleanup code SHALL call `podman secret rm tillandsias-github-token` (if exists)
- **AND** `podman secret rm tillandsias-ca-cert` and `podman secret rm tillandsias-ca-key`
- **AND** accountability log entries SHALL record `action="secret_cleanup"`, `spec="podman-secrets-integration"` for each secret removed
- **AND** the tray SHALL exit after all secrets are cleaned

#### Scenario: Secrets removed on panic
- **WHEN** the tray panics or crashes
- **THEN** a Drop guard (or signal handler) SHALL trigger the cleanup code
- **AND** all ephemeral secrets SHALL be removed from podman storage
- **AND** a warning log entry SHALL record `"Panic cleanup triggered; removing ephemeral secrets"`

#### Scenario: Cleanup is idempotent
- **WHEN** the cleanup code calls `podman secret rm tillandsias-github-token` and the secret does not exist
- **THEN** the command SHALL return success (exit code 0) or handle the ENOENT gracefully
- **AND** SHALL NOT propagate an error up the call stack

#### Scenario: No secrets remain after tray exit
- **WHEN** the tray has exited cleanly (normal or via crash)
- **AND** a user runs `podman secret ls | grep tillandsias`
- **THEN** the output SHALL be empty (no secrets matching `tillandsias-*`)

### Requirement: Secrets creation uses podman filedriver (default)

The tray SHALL use podman's default file driver (plaintext in podman storage) for all ephemeral secrets. No custom drivers (pass, shell) are required for this capability.

@trace spec:podman-secrets-integration

#### Scenario: File driver is used
- **WHEN** the tray calls `podman secret create tillandsias-github-token <token>`
- **THEN** podman SHALL use the default file driver
- **AND** the secret SHALL be stored in `~/.local/share/containers/storage/secrets/filedriver/`
- **AND** the secret SHALL be listed in `podman secret ls` output

#### Scenario: No custom driver configuration required
- **WHEN** the tray initializes
- **THEN** the tray SHALL NOT require or configure podman secret drivers
- **AND** no driver selection logic SHALL be present in the implementation

### Requirement: Secrets tied to OS keyring for GitHub token source

The GitHub token secret is sourced from the host OS keyring (Linux: Secret Service via `secret-tool`, macOS: Keychain, Windows: Credential Manager). The tray retrieves the token synchronously from the keyring and immediately creates the ephemeral secret.

@trace spec:podman-secrets-integration

#### Scenario: Token retrieved from OS keyring
- **WHEN** the tray initializes and the user has previously authenticated via `--github-login`
- **THEN** the tray SHALL retrieve the token from the OS keyring synchronously (blocking call)
- **AND** the token value SHALL exist only in the tray process memory and the ephemeral secret, never on disk

#### Scenario: Token not in keyring—user not authenticated
- **WHEN** the tray initializes and the OS keyring has no GitHub token entry
- **THEN** the tray SHALL not create `tillandsias-github-token` secret
- **AND** cloning public repos SHALL work; cloning private repos SHALL fail at git time with an authentication error

### Requirement: Accountability logging for all secret operations

Every secret operation (creation, access, deletion) SHALL be logged to the accountability system with at minimum `category="secrets"`, `spec="podman-secrets-integration"`, and the operation name. No secret values SHALL appear in logs.

@trace spec:podman-secrets-integration

#### Scenario: Secret creation logged
- **WHEN** `podman secret create tillandsias-github-token ...` completes
- **THEN** the tray SHALL log: `action="secret_create"`, `secret_name="tillandsias-github-token"`, `category="secrets"`, `spec="podman-secrets-integration"`
- **AND** the log entry SHALL NOT contain the token value, a hash of the value, or any derivable hint

#### Scenario: Secret cleanup logged
- **WHEN** `podman secret rm tillandsias-github-token` completes
- **THEN** the tray SHALL log: `action="secret_cleanup"`, `secret_name="tillandsias-github-token"`, `category="secrets"`, `spec="podman-secrets-integration"`

#### Scenario: Container launch with secrets logged
- **WHEN** a container is launched with `--secret=tillandsias-ca-cert`
- **THEN** the tray SHALL log: `container_name="tillandsias-proxy-..."`, `mounted_secrets=["tillandsias-ca-cert", "tillandsias-ca-key"]`, `spec="podman-secrets-integration"`

### Requirement: CA certificate generation is ephemeral and per-session

CA certificates are generated anew at each tray startup, valid for 24 hours, and never persisted to disk. The cert and key are created in-memory and immediately converted to podman secrets.

@trace spec:podman-secrets-integration

#### Scenario: CA cert generated at startup
- **WHEN** the tray initializes
- **THEN** the tray SHALL call a CA generation function (e.g., `ca::generate_ephemeral_ca()`)
- **AND** the function SHALL return (cert_pem, key_pem) as in-memory strings
- **AND** no intermediate files SHALL be written to disk (not even in `/tmp/`)

#### Scenario: CA cert valid for 24 hours
- **WHEN** a CA certificate is generated
- **THEN** the certificate's `notAfter` field SHALL be 24 hours from generation time
- **AND** the certificate's `notBefore` field SHALL be `now` (or a few seconds past)

#### Scenario: Different cert on each tray restart
- **WHEN** the tray is stopped and restarted
- **THEN** a new CA certificate SHALL be generated with a new serial number
- **AND** the new cert's fingerprint SHALL differ from the previous session's cert
- **AND** containers using the old cert's key for SSL bump SHALL need to restart to pick up the new one

## Litmus Tests

The following automated tests verify the implementation:

### Test 1: Secrets created on startup
```bash
# After tray starts, verify secrets exist
podman secret ls | grep -E "tillandsias-(github-token|ca-cert|ca-key)"
# Expected: 3 lines (or 2 if no GitHub token in keyring)
```

### Test 2: Secrets not visible in inspect
```bash
# Start a container with secrets
podman run --secret=tillandsias-ca-cert --secret=tillandsias-github-token <image> sleep 100

# Inspect container
podman inspect <container> | grep -i secret

# Expected: secret names listed (if podman version supports it), but values hidden
```

### Test 3: Secrets not in process environment
```bash
# Inside a container with --secret=tillandsias-github-token
env | grep -i github

# Expected: (empty output — no GITHUB_TOKEN env var)
```

### Test 4: Secrets readable at /run/secrets/
```bash
# Inside a container with --secret=tillandsias-github-token
cat /run/secrets/tillandsias-github-token

# Expected: (token contents printed; file exists and is readable)
```

### Test 5: Secrets cleaned up on shutdown
```bash
# Before tray startup:
podman secret ls | grep tillandsias
# Expected: (empty output)

# After tray starts:
podman secret ls | grep tillandsias
# Expected: 2-3 lines (secrets created)

# After tray shutdown:
podman secret ls | grep tillandsias
# Expected: (empty output — all cleaned)
```

### Test 6: Accountability logs record operations
```bash
# After tray startup, check logs
grep 'action="secret_create"' ~/.cache/tillandsias/logs/accountability.jsonl

# Expected: 2-3 lines (one per secret created)

# After tray shutdown
grep 'action="secret_cleanup"' ~/.cache/tillandsias/logs/accountability.jsonl

# Expected: 2-3 lines (one per secret removed)
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
- `cheatsheets/utils/tillandsias-secrets-architecture.md` — Tillandsias three-layer secret flow, threat mitigation, and implementation patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-secrets-integration" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Related specs:
```bash
grep -rn "podman-secrets-integration" openspec/specs/ --include="*.md"
grep -rn "@trace spec:secrets-management" src-tauri/ --include="*.rs"
```
