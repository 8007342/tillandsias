---
tags: [vault, hashicorp, secrets, enclave, auto-unseal, policy, poc, research]
languages: [bash, hcl, rust]
since: 2026-05-23
last_verified: 2026-05-23
sources:
  - openspec/specs/tillandsias-vault/spec.md
  - openspec/specs/vm-provisioning-lifecycle/spec.md
  - https://developer.hashicorp.com/vault/docs
  - https://developer.hashicorp.com/vault/docs/configuration
  - https://developer.hashicorp.com/vault/docs/concepts/seal
  - https://developer.hashicorp.com/vault/docs/concepts/policies
  - https://developer.hashicorp.com/vault/docs/auth/approle
  - https://developer.hashicorp.com/vault/docs/audit
authority: medium
status: proposed
tier: bundled
---

# HashiCorp Vault inside the Tillandsias enclave (POC)

@trace spec:tillandsias-vault
@cheatsheet runtime/vsock-transport.md, runtime/vm-provisioning-lifecycle if available

**Use when**: implementing the Phase-3 Vault POC, debugging an unseal failure, writing a new policy file, or evaluating whether to migrate Linux off the host keyring onto Vault (Phase 6).

## Provenance

- HashiCorp Vault docs — concepts, configuration, seal, policies, auth/approle, audit
- `openspec/specs/tillandsias-vault/spec.md` — Tillandsias contract (RESEARCH items marked inline)
- `openspec/specs/vm-provisioning-lifecycle/spec.md` — the `installation-uuid` lifecycle this depends on

## Scope: this is a POC

The Vault POC sits inside the Fedora 44 VM as a new container hostname `vault`. It speaks to other enclave containers (git-mirror, forge, inference, tray-side bridge) over the enclave network on port 8200. **Nothing in the Vault flow is exposed beyond the enclave.** Multiple items in this cheatsheet are marked `RESEARCH` — they require empirical confirmation during Phase 3 implementation.

## Architecture in one diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ Fedora 44 VM                                                     │
│                                                                  │
│  ┌────────────────────┐   ┌────────────────────┐                 │
│  │ tillandsias-vault  │   │ tillandsias-git    │                 │
│  │  (vault.io 1.18+)  │   │   (mirror)         │                 │
│  │  :8200             │←──│  fetches GitHub    │                 │
│  │  storage: file     │   │  token from vault  │                 │
│  │  /vault/data       │   │  on each push      │                 │
│  └─────────┬──────────┘   └────────────────────┘                 │
│            │                                                     │
│            ↓                                                     │
│  ┌────────────────────┐   ┌────────────────────┐                 │
│  │ unseal key on      │   │ forge containers   │                 │
│  │ tmpfs at           │   │  (NO github access; │                 │
│  │ /run/secrets/...   │   │   read CA cert only)│                 │
│  │ HKDF(machine-id || │   │                    │                 │
│  │   installation-uuid)│   │                    │                 │
│  └─────────┬──────────┘   └────────────────────┘                 │
└────────────┼─────────────────────────────────────────────────────┘
             ↑ installation-uuid (pushed at VM boot via vsock)
             │
┌────────────┴─────────────────────────────────────────────────────┐
│ Host (Windows Credential Manager / macOS Keychain)               │
│                                                                  │
│  key: "tillandsias-vm-uuid"                                      │
│  value: <UUID generated at first VM provision>                   │
└──────────────────────────────────────────────────────────────────┘
```

## Container image

Built locally via `scripts/build-image.sh vault`:

| Aspect | Choice |
|---|---|
| Base | `docker.io/hashicorp/vault:1.18` (or whatever is the latest 1.x at build time) |
| Network | `--network tillandsias-enclave`, `--network-alias vault` |
| Persistent volume | `tillandsias-vault-data:/vault/data` |
| Listener | `tcp 0.0.0.0:8200`, TLS disabled (enclave-only; if ever exposed, add TLS) |
| Storage backend | `file` at `/vault/data` |
| Logging | `journald` driver inside the VM; tail'd by `tillandsias-headless` for observability convergence |

### `/vault/config.hcl` (baked into the container or bind-mounted)

```hcl
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"          # enclave-only; do NOT relax beyond that
}

api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8201"

ui = false                       # no web UI in the POC
disable_mlock = true             # podman rootless cannot mlock; safe within enclave
log_level    = "info"

# RESEARCH: confirm Vault 1.18's "transit auto-unseal" cannot self-host
# (chicken-and-egg). If confirmed, the wrapper script below provides
# unseal keys at start time.
```

## Storage backend choice

`file` is the simplest backend, durable, and avoids Raft/cluster complexity for a single-node POC. Storage layout under `/vault/data/`:

- `core/` — Vault's internal metadata (mount table, audit config, etc.)
- `logical/` — secret data, encrypted at rest with Vault's master key
- `sys/` — system data

The podman volume `tillandsias-vault-data` is the only persistent state outside the VM's root disk. Backing it up by `podman volume export tillandsias-vault-data > backup.tar` is a sanctioned recovery path; however, the volume includes encrypted blobs — without the unseal mechanism's inputs (machine-id + installation-uuid), the backup is useless. This is intentional.

## Transparent auto-unseal — the core trick

Vault always boots **sealed**. Standard Vault deployment requires a human to type unseal keys; Tillandsias must boot Vault with **no user prompt ever**.

The mechanism:

1. **`installation-uuid`** is generated at first VM provision and stored on the host:
   - Windows: Credential Manager entry under target name `tillandsias-vm-uuid`.
   - macOS: Keychain item under service `tillandsias`, account `vm-uuid`.
2. **At every VM boot**, the host tray pushes the `installation-uuid` into the VM via vsock as the first post-handshake message. The in-VM headless writes it to tmpfs at `/run/tillandsias/installation-uuid`.
3. **The VM's `/etc/machine-id`** (regenerated per boot for WSL — RESEARCH item: confirm; on macOS VZ this is stable per persistent root disk) combined with the installation-uuid forms the HKDF input.
4. **Unseal key derivation** runs once per boot, before Vault starts:
   ```
   ikm  = sha256(machine-id || installation-uuid)
   salt = "tillandsias-vault-v1"
   info = "auto-unseal"
   unseal_key = HKDF-SHA256(ikm, salt, info, length=32)
   ```
   The 32 bytes land at `/run/secrets/vault-unseal` (tmpfs, root:root, 0400).
5. **Vault unseal** is performed by a small `vault-unseal-helper` script (described below). Vault uses Shamir's secret sharing by default; for the POC we use a **single share with threshold 1** so one 32-byte key fully unseals.

### `vault-unseal-helper` flow (runs in vault container entrypoint)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Wait for unseal key to appear (the host shell writes it via the in-VM
# headless after vsock handshake; up to 30s budget).
for i in $(seq 1 30); do
  if [ -r /run/secrets/vault-unseal ]; then break; fi
  sleep 1
done
if [ ! -r /run/secrets/vault-unseal ]; then
  echo "FATAL: no unseal key at /run/secrets/vault-unseal after 30s" >&2
  exit 1
fi

# Start Vault in the background.
vault server -config=/vault/config.hcl &
VAULT_PID=$!

# Wait for the API to come up.
export VAULT_ADDR=http://127.0.0.1:8200
for i in $(seq 1 30); do
  if vault status 2>/dev/null | grep -q 'Initialized'; then break; fi
  sleep 1
done

# Initialize on first boot.
if ! vault status 2>/dev/null | grep -q 'Initialized.*true'; then
  vault operator init -key-shares=1 -key-threshold=1 \
    -recovery-shares=0 -format=json \
    > /vault/data/init.json
  ROOT_TOKEN=$(jq -r '.root_token' < /vault/data/init.json)
  # NB: the generated unseal key is DISCARDED — we re-derive it from
  # machine-id+installation-uuid via HKDF, then call vault operator
  # rekey to install the derived key as the active share.
  # RESEARCH: confirm rekey allows this in-place.
fi

# Unseal using the HKDF-derived key.
UNSEAL_KEY_HEX=$(xxd -p -c 64 < /run/secrets/vault-unseal)
vault operator unseal "$UNSEAL_KEY_HEX"

# Hand control to vault (server is already running).
wait "$VAULT_PID"
```

**Verification**: `vault status | grep Sealed` must report `false` within 5s of container start, with zero user input. The litmus `litmus-vault-auto-unseal-no-prompt.yaml` asserts this end-to-end.

### Failure path — installation-uuid lost

If the host's keychain entry vanishes (OS reinstall, user deletes credential):

1. The host shell generates a **new** `installation-uuid` and pushes it.
2. The HKDF derivation produces a **different** unseal key.
3. Vault refuses to unseal (`incorrect unseal key`).
4. The host shell detects this via the `vault operator unseal` exit code on `vault-unseal-helper`, and surfaces the menu line:
   ```
   🥀 Vault re-bootstrap required: previous secrets unrecoverable.
      [Reset Vault] [Open log]
   ```
5. "Reset Vault" wipes the `tillandsias-vault-data` volume, generates a fresh installation-uuid, and re-initializes Vault. **All prior secrets are lost.** The user re-runs `--github-login` and any other credential-acquisition flows.

This is documented as the "re-bootstrap flow"; it is a research item to confirm the UX is acceptable.

## Policy taxonomy

Vault ACLs are HCL files; each container's token is scoped to one policy.

### `git-mirror-policy.hcl`

```hcl
# Read-only on the GitHub OAuth token. Nothing else.
path "secret/data/github/token" {
  capabilities = ["read"]
}
path "secret/metadata/github/token" {
  capabilities = ["read"]
}
```

### `forge-policy.hcl`

```hcl
# Read-only on the CA cert used for the enclave proxy.
# Explicitly NO github access; forge containers must remain credential-free
# for everything beyond TLS trust.
path "secret/data/ca/proxy-cert" {
  capabilities = ["read"]
}
path "secret/metadata/ca/proxy-cert" {
  capabilities = ["read"]
}
```

### `tray-policy.hcl`

```hcl
# Full CRUD on the secret tree; the tray manages secret rotation
# on the user's behalf (e.g., on --github-login).
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

### `inference-policy.hcl`

```hcl
# Empty — inference needs no secrets today.
# Placeholder so the inference container has a defined policy slot.
```

### Future, illustrative

```hcl
# forge-googledrive-policy.hcl — read-only on the read-only google drive token
path "secret/data/google/drive-readonly" {
  capabilities = ["read"]
}
# No write paths. The forge can never elevate to drive-readwrite.
```

The pattern: every long-lived integration (Google, AWS, Azure, etc.) gets its own policy with **least privilege**, and is mounted into the specific container that needs it. Forges remain otherwise credential-free.

## Token issuance

The flow:

1. **Tray bootstraps** by reading `init.json` (the root token landed here at first init).
2. **Tray creates AppRole** auth roles for each container type:
   ```bash
   vault auth enable approle
   vault write auth/approle/role/git-mirror \
     token_policies="git-mirror-policy" \
     token_ttl=1h token_max_ttl=4h
   ```
3. **Per-container startup**, the tray issues a fresh `secret_id`:
   ```bash
   vault write -f auth/approle/role/git-mirror/secret-id
   ```
   The resulting `role_id` + `secret_id` are injected into the container via podman secret (ephemeral; same pattern as `tillandsias-github-token` today).
4. **Container at startup** does the AppRole login:
   ```bash
   vault write auth/approle/login \
     role_id=$(cat /run/secrets/vault-role-id) \
     secret_id=$(cat /run/secrets/vault-secret-id)
   # → returns a 1h token scoped to git-mirror-policy
   ```
5. **Container renews** the token via `vault token renew` every 30 min while running.
6. **On container exit**, the tray revokes the secret-id; the issued token's TTL expires within 1h regardless.

Alternative: **Token auth** — the tray issues short-lived tokens directly. Simpler, but the secret-id flow is more idiomatic Vault and supports rotation. RESEARCH: confirm AppRole works inside the enclave's flat network with all containers sharing one Vault.

## Debugging recipes

```bash
# Vault status
podman exec tillandsias-vault vault status
# Expect: Initialized true, Sealed false, Cluster Name vault-...

# Audit devices
podman exec tillandsias-vault vault audit list
# Expect: file/ enabled (path=/vault/audit/audit.log)

# Token introspection (debugging a scope issue)
VAULT_TOKEN=<token> podman exec -e VAULT_TOKEN tillandsias-vault \
  vault token lookup
# Shows policies, ttl, renewable, accessor

# List secrets at a path
VAULT_TOKEN=<root> podman exec -e VAULT_TOKEN tillandsias-vault \
  vault kv list secret/

# Read a secret (raw)
VAULT_TOKEN=<root> podman exec -e VAULT_TOKEN tillandsias-vault \
  vault kv get -format=json secret/github/token

# Tail audit log (from host via the in-VM headless tail forwarder)
journalctl -u tillandsias-headless -f | grep '"path":"audit"'
```

## Audit logging

Enable at init time:

```bash
vault audit enable file file_path=/vault/audit/audit.log
```

Every request emits a JSON line containing path, method, client token accessor (not the token itself), and parameters. `tillandsias-headless` tails this file and forwards lines via the observability convergence stream. **RESEARCH**: rotation policy — uncapped audit logs will grow forever; we likely need a logrotate sidecar or syslog forwarding.

## Failure modes

### `vault operator unseal` fails after a clean install

The HKDF inputs changed. Either `machine-id` changed (WSL2 regenerates per boot — RESEARCH item) or `installation-uuid` is wrong/lost. Check `/run/tillandsias/installation-uuid` and `/etc/machine-id` inside the VM; compare with the previous values logged by the helper.

### `vault status` reports `Initialized false`

The `vault operator init` step did not run, or the `init.json` is missing. Re-run the helper from a fresh state.

### Forge container gets 403 on `secret/github/token`

Working as designed — forge's policy denies that path. If the forge legitimately needs a token, give it a separate policy that grants the specific path. Do NOT widen `forge-policy.hcl`.

### Tray cannot push `installation-uuid` via vsock

Vsock not up yet (race) — Vault helper's 30s wait covers this. If the timeout fires, Vault container exits 1 and is restarted; the tray retries the vsock send. Loop converges within ~60s in practice.

### File backend corruption

If `/vault/data/core` is corrupted (kernel panic mid-write), Vault refuses to start. The recovery flow is the same as the lost-installation-uuid path: wipe volume, re-init, lose secrets.

## Linux migration outlook (Phase 6)

Today Linux Tillandsias uses the host's Secret Service (GNOME Keyring) for `github-token`, `ca-cert`, `ca-key`. The migration:

1. After Phase 4-5 Windows/macOS ship, audit Vault for stability (latency, audit log size, unseal robustness over months).
2. If green: author `linux-tray-vault-migration` spec.
3. Linux runs the same Fedora-VM-equivalent (or simply runs Vault in a host-side rootless podman) and migrates flows one at a time.

Until Phase 6 lands, Linux **keeps** the existing keyring flow. There is no dual-write.

## Common pitfalls

- **Treating the unseal helper as production-quality.** It's POC code; the rekey-after-init step is RESEARCH.
- **Assuming `disable_mlock = false`.** Rootless podman cannot `mlock`; setting `false` makes Vault refuse to start.
- **Putting Vault on `0.0.0.0:8200` without the enclave-only firewall.** The enclave-only assumption requires that no port-publish flag exposes 8200 to the host. The launcher must NEVER pass `-p 8200:8200`.
- **Long-lived tokens.** AppRole tokens MUST be ≤1h TTL. The litmus enforces a config check.
- **Treating audit log as low-priority.** Without rotation it fills the volume; budget for it.
- **Logging unseal key.** The helper script must never `echo` the key. The fragment shown above uses `xxd` to convert then immediately consumes the variable.

## See also

- `runtime/vsock-transport.md` — how the installation-uuid reaches the VM
- `runtime/idiomatic-vm-exec.md` — how the host shell drives `vault` commands inside the VM
- `runtime/wsl2-provisioning.md` — sibling architecture surrounding the Vault container on Windows
- `runtime/vz-framework-provisioning.md` — sibling architecture on macOS
- `openspec/specs/tillandsias-vault/spec.md` — normative contract with RESEARCH items
- `docs/cheatsheets/tillandsias-secrets-architecture.md` — current Linux keyring flow (to be retired in Phase 6)
