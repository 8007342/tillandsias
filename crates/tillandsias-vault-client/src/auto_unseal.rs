//! Transparent Vault auto-unseal.
//!
//! Derives the 32-byte unseal key via HKDF-SHA256 over `machine_id` and
//! `installation_uuid`. The user NEVER sees a passphrase prompt — this is
//! the core property the spec's litmus tests will assert.
//!
//! See `openspec/specs/tillandsias-vault/spec.md` for the threat model.
//!
//! @trace spec:tillandsias-vault
//! @cheatsheet runtime/hashicorp-vault-tillandsias.md

use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroize;

/// Salt used in the HKDF extract step.
///
/// Versioned because if we ever change the derivation algorithm we need to
/// rotate the salt to force a re-bootstrap rather than silently produce a
/// different key for the same inputs.
pub const HKDF_SALT: &[u8] = b"tillandsias-vault-unseal-v1";

/// Info string used in the HKDF expand step.
pub const HKDF_INFO: &[u8] = b"vault-unseal-key";

/// Derive the 32-byte unseal key.
///
/// HKDF-SHA256 with:
/// - `salt = "tillandsias-vault-unseal-v1"`
/// - `ikm  = machine_id || installation_uuid`
/// - `info = "vault-unseal-key"`
///
/// Both inputs are byte slices to keep the function format-agnostic
/// (`/etc/machine-id` is hex ASCII, `installation_uuid` is a hyphenated
/// UUID string — callers pass them as bytes verbatim).
///
/// The output never leaves tmpfs at the call site; callers should
/// [`zeroize::Zeroize::zeroize`] the array as soon as it has been
/// written into the podman secret.
pub fn derive_unseal_key(machine_id: &[u8], installation_uuid: &[u8]) -> [u8; 32] {
    let mut ikm = Vec::with_capacity(machine_id.len() + installation_uuid.len());
    ikm.extend_from_slice(machine_id);
    ikm.extend_from_slice(installation_uuid);

    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), &ikm);
    let mut okm = [0u8; 32];
    hk.expand(HKDF_INFO, &mut okm)
        .expect("HKDF expand failed for 32-byte output (impossible per RFC 5869)");

    // Wipe the concatenated IKM from memory before returning.
    ikm.zeroize();
    okm
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derive_unseal_key_is_deterministic_for_same_inputs() {
        let machine_id = b"abcdef0123456789abcdef0123456789";
        let installation_uuid = b"550e8400-e29b-41d4-a716-446655440000";

        let k1 = derive_unseal_key(machine_id, installation_uuid);
        let k2 = derive_unseal_key(machine_id, installation_uuid);
        assert_eq!(k1, k2, "HKDF must be deterministic for identical inputs");
        assert_eq!(k1.len(), 32);
    }

    #[test]
    fn derive_unseal_key_differs_for_different_machine_ids() {
        let installation_uuid = b"550e8400-e29b-41d4-a716-446655440000";
        let mid_a = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let mid_b = b"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

        let ka = derive_unseal_key(mid_a, installation_uuid);
        let kb = derive_unseal_key(mid_b, installation_uuid);
        assert_ne!(
            ka, kb,
            "different machine-ids must produce different unseal keys"
        );
    }

    #[test]
    fn derive_unseal_key_differs_for_different_installation_uuids() {
        let machine_id = b"abcdef0123456789abcdef0123456789";
        let uuid_a = b"550e8400-e29b-41d4-a716-446655440000";
        let uuid_b = b"550e8400-e29b-41d4-a716-446655440001";

        let ka = derive_unseal_key(machine_id, uuid_a);
        let kb = derive_unseal_key(machine_id, uuid_b);
        assert_ne!(ka, kb);
    }

    #[test]
    fn derive_unseal_key_is_not_all_zero() {
        let machine_id = b"abcdef0123456789abcdef0123456789";
        let installation_uuid = b"550e8400-e29b-41d4-a716-446655440000";
        let k = derive_unseal_key(machine_id, installation_uuid);
        assert!(k.iter().any(|&b| b != 0), "HKDF output must not be all-zero");
    }
}
