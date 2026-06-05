# Step 36 — Cross-platform Vault keychain + vsock unseal-key parity

- **Status**: blocked
- **Owner host**: macos + windows (depends on linux step 32)
- **Branch**: osx-next / windows-next (code); linux-next (plan)
- **Depends on**: [32]
- **Specs**: tillandsias-vault, vsock-transport, host-shell-architecture

## Goal

The hardened `tillandsias-vault` spec mandates host-OS-keychain unseal-key storage on **all**
platforms (`spec.md:75-76`: "Secret Service/KWallet on Linux, Credential Manager on Windows,
Keychain on macOS") with delivery to the VM via `vsock-transport`. The current bootstrap
(`crates/tillandsias-headless/src/vault_bootstrap.rs`) is **Linux-only**. macOS and Windows
have no keychain-stored unseal key + `installation-uuid` vsock delivery into the VM. (This was
also the root pre-hardening audit's "Operational Hardening / Step 4" item.)

## Tasks

- [ ] **macos** — store the derived unseal key + `installation-uuid` in macOS Keychain and
  deliver them to the in-VM vault container over the existing vsock control wire; verify
  no-prompt auto-unseal after Start VM. — `crates/tillandsias-macos-tray/*`,
  `crates/tillandsias-vm-layer/*`
- [ ] **windows** — same via Windows Credential Manager + HvSocket control wire. —
  `crates/tillandsias-windows-tray/*`
- [ ] Keep the shared keychain/versioning/sanitization contract in
  `tillandsias-vault.security.transparent-auto-unseal@v3` honored on both.

## Gate / blocker

Blocked until step 32 lands the canonical rekey + keychain handover on Linux (the shared
contract the trays mirror). Until then this is a tracked future packet, not claimable.

## Also tracked here (release acceptance, not code)

- macOS user-attended **m8 smoke** of the rebuilt `Tillandsias.app` remains the only manual
  release-acceptance gate (see `plan/issues/osx-next-work-queue-2026-05-25.md`); it is
  independent of step 32 and can run as soon as a v0.3.x build exists (see step 36's release
  dependency on the step-… version cut).
