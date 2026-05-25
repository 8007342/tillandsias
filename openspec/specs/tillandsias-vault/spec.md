<!-- @trace spec:tillandsias-vault -->
# tillandsias-vault Specification

## Status

active
phase: 6

## Purpose

Run a HashiCorp Vault container as the default Linux secrets backend for
Tillandsias. Vault stores long-lived external credentials, starting with the
GitHub token at `secret/github/token`, and issues short-lived per-container
tokens scoped by fine-grained ACL policies.

Phase 6 promotes Vault from POC to default on Linux. The current Linux loop runs
the Vault container under host-rootless podman and treats the Linux host as the
VM boundary until the Windows WSL2 and macOS Virtualization.framework hosts
route the same control plane through their host shells. The old native-keyring
path is retained only behind deprecated flags:

- `--without-vault` skips default Vault bootstrap for debugging.
- `--legacy-keyring-secrets` also creates the old keyring-backed podman secret.
- `--with-vault` is a no-op alias because Vault is now the default.
- all legacy keyring-only paths are scheduled for removal in v0.3.

Cross-references:
- `host-shell-architecture` - host process owns platform bootstrap and UUID
  delivery.
- `vm-provisioning-lifecycle` - first-run Vault image/container provisioning.
- `vsock-transport` - Windows/macOS host shells deliver host state to the VM.
- `git-mirror-service` - consumes `git-mirror-policy` AppRole tokens for GitHub
  push.
- `secrets-management` - superseded native-keyring path retained only as a
  deprecated fallback.

## Requirements

### Requirement: Vault container runs inside the secrets boundary with persistent storage
- **ID**: tillandsias-vault.deployment.vault-container@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.vault-listener-boundary-scoped, tillandsias-vault.invariant.vault-storage-persistent]

The `tillandsias-vault` container SHALL run with hostname/network alias `vault`
and persistent storage at `/vault/data`, backed by the podman volume
`tillandsias-vault-data`. Vault SHALL listen on `0.0.0.0:8200` inside its
container/network namespace. On the Linux Phase 6 loop, the launcher MAY publish
`127.0.0.1:8201:8200` so the host process can bootstrap policies and write
tokens; it MUST NOT publish Vault on `0.0.0.0`, a non-loopback address, or a
remote interface. Windows and macOS hosts SHALL keep Vault reachable through the
VM/control channel rather than exposing it to the external host network.

@trace spec:tillandsias-vault

#### Scenario: Linux default bootstrap starts Vault
- **WHEN** `tillandsias --init` runs on Linux without `--without-vault`
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

### Requirement: Auto-unseal derives from machine-id + installation-uuid
- **ID**: tillandsias-vault.security.transparent-auto-unseal@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.no-passphrase-prompt-ever, tillandsias-vault.invariant.unseal-key-tmpfs-only, tillandsias-vault.invariant.installation-uuid-platform-bound]

Vault SHALL auto-unseal on every boot with zero user interaction. The unseal key
SHALL be derived through HKDF-SHA256 from the platform's installation UUID and
the machine identity of the running Linux boundary. On Linux Phase 6 the UUID is
stored at `~/.config/tillandsias/installation-uuid` with mode `0600`; Windows
and macOS host shells SHALL store the equivalent UUID in platform keychain APIs
and deliver it through the host-shell/VM channel. The derived unseal secret
SHALL be loaded into a podman secret and mounted at `/run/secrets/vault-unseal`
on tmpfs only.

@trace spec:tillandsias-vault, spec:host-shell-architecture

#### Scenario: First boot unseals without prompt
- **WHEN** Vault is provisioned for the first time
- **THEN** the launcher SHALL create a platform-bound installation UUID
- **AND** the Linux boundary SHALL derive the unseal key via HKDF
- **AND** Vault SHALL transition to `sealed=false` without any terminal prompt,
  window prompt, or file dialog.

#### Scenario: Subsequent boots unseal without prompt
- **WHEN** Tillandsias restarts
- **THEN** the launcher SHALL reuse the existing installation UUID
- **AND** Vault SHALL unseal with the same derivation
- **AND** the user SHALL see no credential or passphrase prompt.

#### Scenario: Unseal key never lands on persistent disk
- **WHEN** Vault is running
- **THEN** `/run/secrets/vault-unseal` SHALL be tmpfs-backed
- **AND** no persistent file under `/vault` or `/etc` SHALL contain the unseal
  key bytes.

### Requirement: Linux Vault is the default secret store
- **ID**: tillandsias-vault.linux.default-secret-store@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.vault-default-on-linux, tillandsias-vault.invariant.legacy-keyring-deprecated]

On Linux, `tillandsias --init` SHALL bootstrap Vault by default and
`tillandsias --github-login` SHALL store the GitHub token in Vault at
`secret/github/token`. The deprecated keyring-backed podman-secret flow SHALL be
used only when explicitly requested with `--legacy-keyring-secrets`, when the
binary is compiled without the `vault` feature, or when Vault bootstrap fails
and the caller elects the legacy fallback.

@trace spec:tillandsias-vault, spec:secrets-management

#### Scenario: GitHub login writes to Vault
- **WHEN** the user runs `tillandsias --github-login` with the default feature set
- **THEN** the host SHALL capture the GitHub token
- **AND** SHALL write it to Vault at `secret/github/token`
- **AND** SHALL NOT create `tillandsias-github-token` unless
  `--legacy-keyring-secrets` is present.

#### Scenario: Legacy keyring path is explicit
- **WHEN** `--legacy-keyring-secrets` is present
- **THEN** the launcher MAY create the old `tillandsias-github-token` podman
  secret
- **AND** it SHALL log that the path is deprecated and scheduled for v0.3
  removal.

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

### Invariant: Vault is default on Linux
- **ID**: tillandsias-vault.invariant.vault-default-on-linux
- **Expression**: `linux_init WITHOUT --without-vault STARTS tillandsias-vault`
- **Measurable**: true

### Invariant: Legacy keyring path is deprecated
- **ID**: tillandsias-vault.invariant.legacy-keyring-deprecated
- **Expression**: `legacy_keyring_secret_flow REQUIRES explicit_flag --legacy-keyring-secrets OR vault_feature_absent`
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
- `openspec/specs/secrets-management/spec.md` - superseded native-keyring spec.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tillandsias-vault" crates/ images/ --include="*.rs" --include="*.sh"
```
