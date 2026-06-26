# Step 102 — Replace all hardcoded enclave IPs with DNS-based service discovery

- **Status**: pending
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: podman-health-lifecycle-facade
- **Audit origin**: `plan/issues/build-install-smoke-e2e-findings-2026-06-25.md`

## Why this exists

The codebase has hardcoded `10.0.42.x` IP addresses in 5+ locations across 3 crates. This creates coupling between host processes and enclave network topology. Podman's aardvark-dns already runs on the bridge gateway and can resolve `--network-alias` hostnames — the code should use DNS names like `vault` instead of bare IPs.

Hardcoded IPs found:
- `crates/tillandsias-vm-layer/src/vz.rs:508` — `Environment=TILLANDSIAS_VAULT_API_BASE_URL=https://10.0.42.2:8200`
- `crates/tillandsias-headless/src/vault_bootstrap.rs:37` — `const VAULT_ENCLAVE_IP: &str = "10.0.42.2"`
- `crates/tillandsias-headless/src/vault_bootstrap.rs:1173-1174` — `-p 127.0.0.1:8201:8200` publish
- `crates/tillandsias-macos-tray/src/diagnose.rs:544` — export in vsock exec bash
- `crates/tillandsias-headless/src/main.rs:8` — `ENCLAVE_SUBNET = "10.0.42.0/24"`

## Tasks

### Task 1: Inventory

Use `grep -rn '10\.0\.42\.' crates/` to find every occurrence. The list above is non-exhaustive.

### Task 2: Remove unnecessary port publish

Remove `-p 127.0.0.1:8201:8200` from vault container launch. Host processes should reach vault via the vsock control wire or podman exec, not loopback publish.

### Task 3: DNS migration

- Replace `VAULT_ENCLAVE_IP = "10.0.42.2"` with `"vault"` (podman `--network-alias vault` is already set)
- Configure VM resolv.conf/systemd-resolved to forward `10.0.42.0/24` to aardvark-dns
- Update macOS tray's `TILLANDSIAS_VAULT_API_BASE_URL` to `https://vault:8200`

### Task 4: Subnet constant

Move `ENCLAVE_SUBNET` to a configurable constant with env var override.
