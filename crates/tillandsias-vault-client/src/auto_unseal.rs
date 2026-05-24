//! Transparent Vault auto-unseal.
//!
//! Derives the 32-byte unseal key by HKDF over `machine-id` (read inside the
//! VM) and `installation-uuid` (pushed in from the host keychain at boot
//! time). The user NEVER sees a passphrase prompt — this is the core
//! property the spec's litmus test will assert.
//!
//! See `openspec/specs/tillandsias-vault/spec.md` for the threat model.
//!
//! @trace spec:tillandsias-vault

#![allow(dead_code)]
#![allow(unused)]

/// HKDF over `(machine_id || installation_uuid)` producing a 32-byte
/// unseal key. The output never leaves tmpfs.
pub fn derive_unseal_key(_machine_id: &[u8], _installation_uuid: &[u8]) -> [u8; 32] {
    todo!("@spec tillandsias-vault: HKDF-SHA256 with project-specific info string")
}
