<!-- @trace spec:tillandsias-vault -->
# tillandsias-vault Specification

## Status

proposed
phase: 3

## Purpose

Run a HashiCorp Vault container inside the Fedora 44 Core VM enclave to hold
all long-lived credentials (GitHub tokens, future Google/AWS/etc.) and issue
short-lived per-container tokens scoped by fine-grained ACL policies. Vault
SHALL auto-unseal **transparently** — the user SHALL never see a passphrase
prompt — by deriving the unseal key from a host-bound installation UUID
combined with the VM's `machine-id`. This is a research-level approach
(`RESEARCH` markers below) but the litmus tests assert the no-prompt
property unconditionally.

This is a POC. The success criterion at the end of Phase 3 is "Linux can
migrate off the host keyring to this same Vault." That migration is a
separate spec (`linux-tray-vault-migration`, not authored in this wave).

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`. Decision matrix row
11 establishes vault as the credential surface.

Cross-references:
- `host-shell-architecture` — host process holds only the `installation-uuid`.
- `vm-provisioning-lifecycle` — first-run vault container build/launch.
- `vsock-transport` — host pushes the `installation-uuid` to the VM via vsock.
- `git-mirror-service` — consumes `git-mirror-policy` tokens for GitHub push.

## Requirements

### Requirement: Vault container runs inside the enclave with file storage
- **ID**: tillandsias-vault.deployment.vault-container@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.vault-listener-enclave-only, tillandsias-vault.invariant.vault-storage-persistent]

A new container `tillandsias-vault` SHALL run inside the in-VM enclave with
hostname `vault`. Configuration: storage backend `file` at `/vault/data`
backed by the podman volume `tillandsias-vault-data` for persistence across
VM restarts; TCP listener on `0.0.0.0:8200` reachable only on the enclave
network (NEVER published to the VM's external network or the host); audit
device `file` writing to `/vault/audit/audit.log` tailed by
`tillandsias-headless` for the observability stream.

@trace spec:tillandsias-vault

#### Scenario: Vault container is launched as part of enclave startup
- **WHEN** the in-VM headless brings up the enclave on VM boot
- **THEN** the `tillandsias-vault` container SHALL start with `--network tillandsias-enclave --hostname vault --volume tillandsias-vault-data:/vault/data`
- **AND** the container SHALL NOT have `--publish` flags (no host port exposure)

#### Scenario: Vault data survives VM restart
- **WHEN** the VM is stopped via `VmShutdownRequest` and restarted
- **THEN** secrets written before the stop SHALL be readable after the restart
- **AND** the `tillandsias-vault-data` podman volume SHALL persist on the VM's filesystem

#### Scenario: Vault is unreachable from outside the enclave
- **WHEN** the host process attempts to connect to the VM's IP on port `8200`
- **THEN** the connection SHALL be refused
- **AND** vault SHALL be reachable only from containers on the `tillandsias-enclave` network

### Requirement: Auto-unseal derives from machine-id + installation-uuid (RESEARCH)
- **ID**: tillandsias-vault.security.transparent-auto-unseal@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.no-passphrase-prompt-ever, tillandsias-vault.invariant.unseal-key-tmpfs-only, tillandsias-vault.invariant.installation-uuid-in-os-keychain]

The vault SHALL auto-unseal on every boot **with zero user interaction**.
The unseal key SHALL be derived via HKDF-SHA256 over the byte concatenation
of:
1. The VM's `/etc/machine-id` (32 hex chars) — read inside the VM on boot.
2. The host's `tillandsias-installation-uuid` (UUIDv4) — generated on first
   provision and stored in the host OS keychain (Windows Credential Manager
   under `tillandsias-vm-uuid`; macOS Keychain Services under the service
   name `com.tillandsias.vm-uuid`).

The derivation SHALL run inside the VM. The host pushes the
`installation-uuid` to the VM over vsock at every boot. The derived 32-byte
key SHALL be written to `/run/secrets/vault-unseal` (tmpfs only —
regenerated each boot and never persisted to disk). The vault container's
init script SHALL read this file and call `vault operator unseal` once per
shamir share (single share for POC).

**RESEARCH ITEM 1**: confirm WSL2 `/etc/machine-id` persistence across
distro restarts. If it regenerates per boot, use `wsl --list -v
--verbose-export` distro UUID instead, or stash an anchor at
`/etc/tillandsias/installation-uuid` inside the distro on first provision.

**RESEARCH ITEM 2**: VZ guest `/etc/machine-id` — confirmed to persist across
VM restarts in typical Linux init flows but needs verification on the chosen
Fedora 44 rootfs image.

**RESEARCH ITEM 3**: recovery flow if the host loses the installation-uuid
(keychain corruption, OS reinstall). Likely path: "re-bootstrap" that loses
existing vault data and forces a re-login to every external service. Spec
authors a forward-pointer to a future `tillandsias-vault-recovery` spec.

@trace spec:tillandsias-vault, spec:host-shell-architecture

#### Scenario: First boot unseals without prompt
- **WHEN** the VM boots for the first time after provisioning
- **THEN** the host pushes the freshly-generated `installation-uuid` via vsock
- **AND** the in-VM init derives the unseal key via HKDF
- **AND** vault SHALL transition to `sealed=false` within 5s of container start
- **AND** the user SHALL see NO UI prompt, NO terminal prompt, NO file dialog requesting a passphrase

#### Scenario: Subsequent boots unseal without prompt
- **WHEN** the VM is stopped and restarted
- **THEN** the host reads the existing `installation-uuid` from the OS keychain
- **AND** vault re-unseals via the same HKDF derivation
- **AND** the no-prompt property holds

#### Scenario: Unseal key never lands on disk
- **WHEN** the VM is running and the vault is unsealed
- **THEN** `find /vault /etc -type f | xargs grep -l <unseal-key-bytes>` SHALL return zero results
- **AND** `/run/secrets/vault-unseal` SHALL be on tmpfs (verified via `findmnt /run/secrets`)

### Requirement: Policy taxonomy enforces least-privilege per container kind
- **ID**: tillandsias-vault.security.policy-taxonomy@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.policies-defined, tillandsias-vault.invariant.forge-policy-has-no-token-read]

Vault SHALL be configured at provision time with the following ACL policies:
- `git-mirror-policy` — `path "secret/data/github/token" { capabilities = ["read"] }`. Nothing else readable. No write.
- `forge-policy` — `path "secret/data/ca/proxy-cert" { capabilities = ["read"] }`. NO token paths readable. NO write. Forge containers MUST NOT be able to exfiltrate any token.
- `tray-policy` — `path "secret/*" { capabilities = ["create", "read", "update", "delete", "list"] }`. The host-pushed migration tooling and future credential-management UX use this scope.
- `inference-policy` — empty (`{}`). Placeholder for future ollama-cloud or other inference credentials.
- Future placeholders documented (not implemented in POC): `forge-googledrive-policy` (read-only on `secret/data/google/drive-readonly`), `forge-aws-policy` (read-only on a narrowly-scoped AWS keypair path).

@trace spec:tillandsias-vault

#### Scenario: forge-policy token cannot read GitHub token
- **WHEN** a token scoped to `forge-policy` calls `vault kv get secret/github/token`
- **THEN** vault SHALL return HTTP 403 with `permission denied`
- **AND** the audit log SHALL record the denied attempt with `policy=forge-policy`

#### Scenario: git-mirror-policy token can read its own token only
- **WHEN** a token scoped to `git-mirror-policy` reads `secret/github/token`
- **THEN** the call SHALL succeed
- **WHEN** the same token tries to read `secret/ca/proxy-cert`
- **THEN** the call SHALL return HTTP 403

#### Scenario: tray-policy can rotate any secret
- **WHEN** a token scoped to `tray-policy` writes `secret/github/token` with a fresh value
- **THEN** the call SHALL succeed
- **AND** subsequent reads by `git-mirror-policy` SHALL return the new value

### Requirement: Per-container tokens are short-lived and scoped
- **ID**: tillandsias-vault.security.short-lived-tokens@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.token-ttl-1h, tillandsias-vault.invariant.tokens-revoked-on-stop]

At container startup, each enclave container SHALL receive a Vault token
with TTL 1h, renewable up to 24h, scoped to a single policy. The token SHALL
be injected via a podman secret (`tillandsias-vault-token-<container>`) and
SHALL NOT be passed as an environment variable, command-line argument, or
file in a non-tmpfs mount. On container stop, the token SHALL be revoked.

@trace spec:tillandsias-vault, spec:podman-secrets-integration

#### Scenario: Git mirror container receives a 1h token
- **WHEN** `tillandsias-git` container starts
- **THEN** the host's `setup_secrets` flow SHALL request `vault token create -policy=git-mirror-policy -ttl=1h -renewable=true`
- **AND** the resulting token SHALL be loaded into the podman secret `tillandsias-vault-token-git` and mounted at `/run/secrets/vault-token`

#### Scenario: Forge tokens cannot be exfiltrated via env
- **WHEN** `podman inspect <forge-container>` is run
- **THEN** the `Env` array SHALL NOT contain any string starting with `hvs.` or `s.` (vault token prefixes)
- **AND** the `Args` array SHALL NOT contain any such string

#### Scenario: Token is revoked when container stops
- **WHEN** the git mirror container stops via `podman stop`
- **THEN** the in-VM headless SHALL call `vault token revoke <token-id>` for that container's token
- **AND** subsequent vault calls with the token SHALL return HTTP 403

### Requirement: Forge containers receive zero vault tokens (offline confirmation)
- **ID**: tillandsias-vault.security.forge-offline@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tillandsias-vault.invariant.forge-no-vault-token, tillandsias-vault.invariant.forge-cannot-reach-vault]

Forge containers SHALL NOT receive any vault token. Forge containers SHALL
NOT have network reachability to `vault:8200` (enforced by enclave network
ACL or by omitting forge from the enclave network and using a separate
forge-only network).

@trace spec:tillandsias-vault

#### Scenario: Forge container has no vault mount
- **WHEN** `podman inspect <forge-container>` is run
- **THEN** the `Mounts` array SHALL NOT contain any path under `/run/secrets/vault-token`

#### Scenario: Forge container cannot resolve vault hostname
- **WHEN** the forge container runs `getent hosts vault`
- **THEN** the call SHALL return exit code 2 (no entry)

#### Scenario: Forge container cannot reach vault by IP
- **WHEN** the forge container runs `curl -sS http://<vault-enclave-ip>:8200/v1/sys/health`
- **THEN** the call SHALL fail with a network error within 5s (firewall/ACL denial)

## Invariants

### Invariant: Vault listener is enclave-only
- **ID**: tillandsias-vault.invariant.vault-listener-enclave-only
- **Expression**: `vault.listener.address EQ 0.0.0.0:8200 AND container HAS NO --publish flag`
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

### Invariant: Installation-uuid is in OS keychain
- **ID**: tillandsias-vault.invariant.installation-uuid-in-os-keychain
- **Expression**: `installation_uuid_storage IS_IN {windows_credential_manager, macos_keychain_services} AND NEVER on plain filesystem`
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
- **Expression**: `vault_token.ttl EQ 3600s AND renewable`
- **Measurable**: true

### Invariant: Tokens are revoked on container stop
- **ID**: tillandsias-vault.invariant.tokens-revoked-on-stop
- **Expression**: `container.stop EVENT TRIGGERS vault.token.revoke FOR_THAT_CONTAINER`
- **Measurable**: true

### Invariant: Forge has no vault token
- **ID**: tillandsias-vault.invariant.forge-no-vault-token
- **Expression**: `forge_container.mounts DOES_NOT_CONTAIN /run/secrets/vault-token`
- **Measurable**: true

### Invariant: Forge cannot reach vault
- **ID**: tillandsias-vault.invariant.forge-cannot-reach-vault
- **Expression**: `forge_container.network ISOLATED_FROM vault_container.network`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:vault-auto-unseal-no-prompt` — asserts the no-prompt property.
- `litmus:vault-policy-forge-cannot-read-github-token` — asserts forge-policy 403s on token path.
- `litmus:vm-provisioning-idempotent` — transitively validates vault container provisioning idempotency.

## Litmus Chain

Smallest actionable boundary: `cargo test -p tillandsias-vault-client
policy::tests::forge_policy_denies_token_read --strict`. Runtime entry
boundary: starting the vault container in a local podman session (Phase 3
Linux loop, before WSL/VZ wiring), pushing a fake `installation-uuid` over
vsock, and asserting `vault status` reports `sealed=false` within 5s without
any TTY prompt or X11 dialog.

## Sources of Truth

- `cheatsheets/runtime/hashicorp-vault-tillandsias.md` — auto-unseal model and policy templates (DRAFT until POC ships).
- `cheatsheets/utils/podman-secrets.md` — token injection discipline.
- `cheatsheets/utils/tillandsias-secrets-architecture.md` — credential flow Linux today; migration target for Phase 6.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tillandsias-vault" crates/ images/ --include="*.rs" --include="*.sh"
```
