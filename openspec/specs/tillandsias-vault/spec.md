<!-- @trace spec:tillandsias-vault -->
# tillandsias-vault Specification

## Status

active
phase: 6.5

## Purpose

Run a HashiCorp Vault container as the default and ONLY Linux secrets backend for
Tillandsias. Vault stores long-lived external credentials, starting with the
GitHub token at `secret/github/token`, and issues short-lived per-container
tokens scoped by fine-grained ACL policies.

Phase 6.5 hardens the Vault integration by removing the legacy keyring fallback,
mandating the use of the host OS native keychain for auto-unseal key storage across
all platforms (including Linux), and requiring a true `vault operator rekey` to
eliminate the transitional XOR envelope.

Cross-references:
- `host-shell-architecture` - host process owns platform bootstrap and keychain delivery.
- `vm-provisioning-lifecycle` - first-run Vault image/container provisioning.
- `vsock-transport` - Windows/macOS host shells deliver host state to the VM.
- `git-mirror-service` - consumes `git-mirror-policy` AppRole tokens for GitHub push.

## Requirements

### Requirement: Vault container runs inside the secrets boundary with persistent storage
- **ID**: tillandsias-vault.deployment.vault-container@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.vault-listener-boundary-scoped, tillandsias-vault.invariant.vault-storage-persistent]

The `tillandsias-vault` container SHALL run with hostname/network alias `vault`
and persistent storage at `/vault/data`, backed by the podman volume
`tillandsias-vault-data`. Vault SHALL listen on `0.0.0.0:8200` inside its
container/network namespace. On the Linux loop, the launcher MAY publish
`127.0.0.1:8201:8200` so the host process can bootstrap policies and write
tokens; it MUST NOT publish Vault on `0.0.0.0`, a non-loopback address, or a
remote interface. Windows and macOS hosts SHALL keep Vault reachable through the
VM/control channel rather than exposing it to the external host network.

@trace spec:tillandsias-vault

#### Scenario: Default bootstrap starts Vault
- **WHEN** `tillandsias --init` runs
- **THEN** the launcher SHALL build or reuse the `tillandsias-vault` image
- **AND** the launcher SHALL start `tillandsias-vault` with
  `tillandsias-vault-data:/vault/data`
- **AND** Vault SHALL be reachable by the host only at `127.0.0.1:8201`
- **AND** Vault SHALL be reachable by enclave peers at `http://vault:8200`
- **AND** Vault SHALL NOT be published on a non-loopback address.

#### Scenario: Vault data survives restart
- **WHEN** Tillandsias stops and starts again
- **THEN** secrets written before the stop SHALL be readable after restart
- **AND** the `tillandsias-vault-data` volume SHALL remain mounted at
  `/vault/data`.

#### Scenario: Non-loopback exposure is forbidden
- **WHEN** container launch arguments are inspected
- **THEN** no `--publish` argument SHALL expose Vault as `0.0.0.0:8200`,
  `0.0.0.0:8201`, `<host-ip>:8200`, or `<host-ip>:8201`.

### Requirement: Auto-unseal key securely stored in host native keychain with versioning
- **ID**: tillandsias-vault.security.transparent-auto-unseal@v3
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.no-passphrase-prompt-ever, tillandsias-vault.invariant.unseal-key-tmpfs-only, tillandsias-vault.invariant.host-keychain-storage, tillandsias-vault.invariant.keychain-sanitization]

Vault SHALL auto-unseal on every boot with zero user interaction. The unseal key
(derived via HKDF-SHA256 from the machine identity and an installation anchor) SHALL
be stored directly in the host OS's native secure keychain (Secret Service/KWallet
on Linux, Credential Manager on Windows, Keychain on macOS).

The host MUST implement secret versioning (e.g., `tillandsias-vault-unseal-v1`).
On launch, the host SHALL sanitize and delete any stale, older-version keys or
keys associated with non-existent container instances to maintain a minimal
attack surface. The unseal secret SHALL be loaded into a podman secret and
mounted at `/run/secrets/vault-unseal` on tmpfs only.

The transitional XOR envelope is FORBIDDEN. The unseal key provided by the host
MUST be installed as the actual Shamir share via `vault operator rekey`. `init.json`
MUST be deleted immediately after initialization.

@trace spec:tillandsias-vault, spec:host-shell-architecture

#### Scenario: First boot unseals and rekeys without prompt
- **WHEN** Vault is provisioned for the first time
- **THEN** the launcher SHALL generate and store the versioned unseal key in the host OS keychain
- **AND** Vault SHALL initialize and immediately `vault operator rekey` to use this key as the active share
- **AND** `init.json` SHALL be permanently deleted
- **AND** Vault SHALL transition to `sealed=false` without any terminal prompt.

#### Scenario: Subsequent boots unseal without prompt
- **WHEN** Tillandsias restarts
- **THEN** the launcher SHALL retrieve the live unseal key from the host OS keychain
- **AND** Vault SHALL unseal using this key
- **AND** the user SHALL see no credential or passphrase prompt.

#### Scenario: Unseal key never lands on persistent disk
- **WHEN** Vault is running
- **THEN** `/run/secrets/vault-unseal` SHALL be tmpfs-backed
- **AND** no persistent file under `/vault` or `/etc` SHALL contain the unseal
  key bytes in plaintext or XOR'd form.

#### Scenario: Stale keychain entries are sanitized
- **WHEN** the host launcher initializes
- **THEN** it SHALL scan the host OS keychain for `tillandsias-vault-unseal-*`
- **AND** SHALL delete any entries that are not the current version (`v1`) or belong to defunct installations.

### Requirement: Vault is the ONLY secret store (Legacy Fallback Removed)
- **ID**: tillandsias-vault.linux.only-secret-store@v3
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.vault-always-on-linux, tillandsias-vault.invariant.legacy-flags-rejected]

Vault is the exclusive secrets backend. The legacy keyring-backed podman-secret flow
(`--legacy-keyring-secrets` and `--without-vault`) was removed in v0.3.
`tillandsias --init` SHALL ALWAYS bootstrap Vault. `tillandsias --github-login` SHALL
ALWAYS store the GitHub token in Vault at `secret/github/token`.

@trace spec:tillandsias-vault

#### Scenario: GitHub login writes to Vault
- **WHEN** the user runs `tillandsias --github-login`
- **THEN** the git container SHALL capture the GitHub token
- **AND** SHALL write it to Vault at `secret/github/token`
- **AND** SHALL read the token back and fail if the stored value does not match.
- **AND** the token SHALL NOT be extracted or stored on the host.

#### Scenario: Legacy flags are rejected
- **WHEN** `--legacy-keyring-secrets` or `--without-vault` is passed
- **THEN** the launcher SHALL exit with a fatal error indicating the flags are removed.

### Requirement: Policy taxonomy enforces least privilege per container kind
- **ID**: tillandsias-vault.security.policy-taxonomy@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.policies-defined, tillandsias-vault.invariant.forge-policy-has-no-token-read]

Vault SHALL be configured idempotently with these ACL policies:

- `git-mirror-policy` can read only `secret/data/github/token`.
- `forge-policy` can read only non-token forge material such as
  `secret/data/ca/proxy-cert`; it cannot read GitHub or future external-service
  tokens.
- `tray-policy` can create, read, update, delete, and list under `secret/*` for
  host-owned credential management and migrations.
- `inference-policy` remains empty until an inference credential contract exists.

@trace spec:tillandsias-vault

#### Scenario: forge-policy token cannot read GitHub token
- **WHEN** a token scoped to `forge-policy` calls `vault kv get secret/github/token`
- **THEN** Vault SHALL return HTTP 403 with `permission denied`
- **AND** the audit log SHALL record the denied path and policy.

#### Scenario: git-mirror-policy token can read its own token only
- **WHEN** a token scoped to `git-mirror-policy` reads `secret/github/token`
- **THEN** the call SHALL succeed
- **WHEN** the same token tries to read `secret/ca/proxy-cert`
- **THEN** the call SHALL return HTTP 403.

#### Scenario: tray-policy can rotate any secret
- **WHEN** a token scoped to `tray-policy` writes `secret/github/token` with a fresh value
- **THEN** the call SHALL succeed
- **AND** subsequent reads by `git-mirror-policy` SHALL return the new value.

### Requirement: Per-container tokens are short-lived AppRole tokens
- **ID**: tillandsias-vault.security.short-lived-tokens@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.token-ttl-1h, tillandsias-vault.invariant.tokens-revoked-on-stop]

At container startup, enclave containers that need Vault SHALL receive a fresh
Vault token minted through the AppRole backend. Each role SHALL map to exactly
one policy, tokens SHALL default to TTL 1h with a maximum TTL of 24h, and tokens
SHALL be injected through a podman secret mounted at `/run/secrets/vault-token`.
Tokens MUST NOT appear in environment variables, command-line arguments, or
non-tmpfs bind mounts. On shutdown, the host SHALL revoke every tracked
per-container token before exiting.

@trace spec:tillandsias-vault, spec:podman-secrets-integration

#### Scenario: Git mirror container receives a 1h AppRole token
- **WHEN** a git mirror container starts
- **THEN** the launcher SHALL mint a `git-mirror` AppRole token scoped to
  `git-mirror-policy`
- **AND** SHALL create a podman secret named
  `tillandsias-vault-token-git-mirror-<container-instance>`
- **AND** SHALL mount that secret at `/run/secrets/vault-token`
- **AND** SHALL set `VAULT_ADDR=http://vault:8200`.

#### Scenario: Tokens are not exposed via env or args
- **WHEN** `podman inspect <container>` is run
- **THEN** the `Env` and `Args` arrays SHALL NOT contain a Vault token value.

#### Scenario: Token is revoked when container stops
- **WHEN** the git mirror container stops
- **THEN** the host SHALL revoke that container's Vault token
- **AND** later Vault calls with that token SHALL return HTTP 403.

### Requirement: Forge containers receive zero Vault tokens
- **ID**: tillandsias-vault.security.forge-offline@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.forge-no-vault-token, tillandsias-vault.invariant.forge-cannot-reach-vault]

Forge containers SHALL NOT receive any Vault token. Forge containers SHALL NOT
have network reachability to `vault:8200` unless a future spec introduces a
separate, narrowly-scoped forge credential contract.

@trace spec:tillandsias-vault

#### Scenario: Forge container has no Vault mount
- **WHEN** `podman inspect <forge-container>` is run
- **THEN** `Mounts` SHALL NOT contain `/run/secrets/vault-token`.

#### Scenario: Forge container cannot resolve Vault hostname
- **WHEN** the forge container runs `getent hosts vault`
- **THEN** the call SHALL return no entry.

## Invariants

### Invariant: Vault listener is boundary-scoped
- **ID**: tillandsias-vault.invariant.vault-listener-boundary-scoped
- **Expression**: `vault.listener.container EQ 0.0.0.0:8200 AND host_publish IN {none, 127.0.0.1:8201:8200}`
- **Measurable**: true

### Invariant: Vault storage is persistent
- **ID**: tillandsias-vault.invariant.vault-storage-persistent
- **Expression**: `podman_volume tillandsias-vault-data EXISTS AND is_mounted_at /vault/data`
- **Measurable**: true

### Invariant: No passphrase prompt ever
- **ID**: tillandsias-vault.invariant.no-passphrase-prompt-ever
- **Expression**: `vault_unseal_flow EMITS_NO {NSWindow, MessageBox, terminal_password_prompt, file_dialog}`
- **Measurable**: true

### Invariant: Unseal key is tmpfs-only
- **ID**: tillandsias-vault.invariant.unseal-key-tmpfs-only
- **Expression**: `/run/secrets/vault-unseal IS_ON tmpfs AND NEVER persisted to disk`
- **Measurable**: true

### Invariant: Installation UUID is platform-bound
- **ID**: tillandsias-vault.invariant.installation-uuid-platform-bound
- **Expression**: `installation_uuid_storage IN {linux_0600_config_file, windows_credential_manager, macos_keychain_services}`
- **Measurable**: true

### Invariant: Vault is always-on on Linux
- **ID**: tillandsias-vault.invariant.vault-always-on-linux
- **Expression**: `linux_init ALWAYS STARTS tillandsias-vault`
- **Measurable**: true

### Invariant: Legacy flags are rejected
- **ID**: tillandsias-vault.invariant.legacy-flags-rejected
- **Expression**: `--legacy-keyring-secrets OR --without-vault TRIGGERS fatal_error "flag removed"`
- **Measurable**: true

### Invariant: Policies are defined
- **ID**: tillandsias-vault.invariant.policies-defined
- **Expression**: `vault.policies HAS_KEYS {git-mirror-policy, forge-policy, tray-policy, inference-policy}`
- **Measurable**: true

### Invariant: forge-policy has no token read capability
- **ID**: tillandsias-vault.invariant.forge-policy-has-no-token-read
- **Expression**: `forge-policy.paths DOES_NOT_CONTAIN secret/*/github/* OR secret/*/token`
- **Measurable**: true

### Invariant: Token TTL is 1h
- **ID**: tillandsias-vault.invariant.token-ttl-1h
- **Expression**: `vault_token.ttl EQ 3600s AND renewable AND max_ttl LE 86400s`
- **Measurable**: true

### Invariant: Tokens are revoked on container stop
- **ID**: tillandsias-vault.invariant.tokens-revoked-on-stop
- **Expression**: `container.stop EVENT TRIGGERS vault.token.revoke FOR_THAT_CONTAINER`
- **Measurable**: true

### Invariant: Forge has no Vault token
- **ID**: tillandsias-vault.invariant.forge-no-vault-token
- **Expression**: `forge_container.mounts DOES_NOT_CONTAIN /run/secrets/vault-token`
- **Measurable**: true

### Invariant: Forge cannot reach Vault
- **ID**: tillandsias-vault.invariant.forge-cannot-reach-vault
- **Expression**: `forge_container.network ISOLATED_FROM vault_container.network`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:vault-auto-unseal-no-prompt` - asserts the no-prompt property.
- `litmus:vault-policy-forge-cannot-read-github-token` - asserts
  forge-policy 403s on token path.
- `litmus:git-mirror-safe-refspec-push` - transitively checks the git mirror
  Vault-token mount shape and safe forwarding contract.

## Litmus Chain

Smallest actionable boundary: `cargo test -p tillandsias-vault-client`. Linux
default-flow boundary: `cargo test -p tillandsias-headless --features vault`
for the argument/mount shape tests, then a local `tillandsias --init --debug`
smoke to verify `127.0.0.1:8201` health, policy loading, AppRole provisioning,
and no-prompt auto-unseal. Windows and macOS hosts reuse the same spec through
their host-shell VM transport once those platform branches wire the thin tray
wrappers into the shared host-shell crate.

## Sources of Truth

- `crates/tillandsias-headless/src/vault_bootstrap.rs` - Linux Phase 6 bootstrap,
  UUID storage, AppRole role provisioning, token minting, and revocation.
- `crates/tillandsias-headless/src/main.rs` - default `--init`,
  `--github-login`, and deprecated flag routing.
- `crates/tillandsias-vault-client` - Vault HTTP client, policy model, and
  auto-unseal helper.
- `images/vault/policies/*.hcl` - shipped ACL policy bodies.
- `cheatsheets/runtime/hashicorp-vault-tillandsias.md` - operational walkthrough
  and verification commands.


## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tillandsias-vault" crates/ images/ --include="*.rs" --include="*.sh"
```
