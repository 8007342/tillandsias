//! Encrypted, version-bound control channel for Tillandsias.
//!
//! One reusable primitive secures both hops of the transparent exec chain:
//! host tray ⇄ guest `tillandsias-headless` (over vsock), and guest headless ⇄
//! the innermost podman container. The design lives in
//! `plan/issues/encrypted-control-channel-research-2026-07-01.md`.
//!
//! This crate currently implements **slices 1–2** of the implementation packet:
//! the crate skeleton and the **version-binding key derivation** — the core of
//! the requirement that *only matching-version binaries can communicate*. The
//! Noise handshake + AEAD [`EncryptedStream`] wrapper (slices 3+) land next; the
//! [`secure_stream`] module is a documented placeholder until then.
//!
//! ## Why derivation, not comparison
//!
//! A version *check* (compare a self-reported `Hello.build_version`) is
//! skippable by a hostile peer — exactly the P0 the zero-trust audit flagged.
//! Instead the pre-shared key is **derived from the build version**, so a host
//! and guest on different releases compute *different* PSKs and simply cannot
//! complete the handshake. Version binding is enforced by construction.
//!
//! ```text
//! PSK = HKDF-SHA256(
//!         ikm  = release_root_secret,      // build-embedded per-release (O1a)
//!         salt = "tillandsias-control-channel",
//!         info = "v=<build_version>;wire=<wire_version>;hop=<hop_id>"
//!       )[0..32]
//! ```
//!
//! `hop_id` domain-separates the host↔guest and guest↔container hops so a key
//! captured on one hop can never be replayed on the other.

use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

/// HKDF salt for every control-channel PSK. Stable across releases; the
/// per-release variation comes from `release_root_secret` (ikm) and the version
/// string (info), never the salt.
pub const CONTROL_CHANNEL_SALT: &[u8] = b"tillandsias-control-channel";

/// Which hop a derived key is for. Mixed into the HKDF `info` so the two hops
/// never share key material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HopId {
    /// Host tray ⇄ guest `tillandsias-headless` over vsock.
    HostGuest,
    /// Guest headless ⇄ the innermost podman container.
    GuestContainer,
}

impl HopId {
    /// Stable wire label used in the HKDF `info`. MUST NOT change without a
    /// deliberate key rotation — it is part of the derived-key identity.
    pub const fn as_str(self) -> &'static str {
        match self {
            HopId::HostGuest => "host-guest",
            HopId::GuestContainer => "guest-container",
        }
    }
}

/// Fixed, non-secret dev seed used in debug builds.
/// It lets a locally-built host + guest of the *same* tree interoperate
/// without a release build. It is intentionally NOT a secret and MUST NOT be
/// relied on for release builds — release builds use the binary's own hash.
#[cfg(debug_assertions)]
const DEV_ROOT_SEED: &[u8] = b"tillandsias-dev-root-not-a-secret";

/// The deterministic per-release secret: SHA-256 of the running binary.
///
/// On release builds, every invocation of this function returns the SHA-256
/// hash of the binary's own on-disk content. This creates a cryptographic
/// version binding — only binaries compiled from identical source produce
/// identical hashes and therefore derive the same PSK. When the host embeds
/// the guest binary and overwrites the guest on each boot (order 190), both
/// ends automatically run identical content and derive matching keys.
///
/// On debug (dev) builds, falls back to [`DEV_ROOT_SEED`] so locally-built
/// peers interoperate without a full release build.
///
/// The hash is computed once (lazily via OnceLock) and cached for the process
/// lifetime. The per-boot hardening that mixes in a host-controlled secret is
/// deferred to `plan/issues/encrypted-channel-perboot-key-hardening-2026-07-01.md`
/// (order 142) and is intentionally NOT part of this function.
pub fn release_root_secret() -> &'static [u8] {
    #[cfg(not(debug_assertions))]
    {
        use sha2::{Digest, Sha256};
        use std::sync::OnceLock;

        static HASH: OnceLock<Vec<u8>> = OnceLock::new();
        HASH.get_or_init(|| {
            let exe = std::env::current_exe().expect("current_exe for self-hash");
            let bytes = std::fs::read(&exe).expect("read self binary for hash");
            Sha256::digest(&bytes).to_vec()
        })
    }
    #[cfg(debug_assertions)]
    DEV_ROOT_SEED
}

/// Workspace release version used to bind both ends of the control channel.
///
/// This comes from the repo-root `VERSION` file rather than each crate's
/// `CARGO_PKG_VERSION`, because the host tray and guest headless are released
/// as separate crates with different package versions.
pub fn workspace_version() -> &'static str {
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../VERSION")).trim()
}

/// Derive the 32-byte control-channel PSK from an explicit root secret.
///
/// Kept root-explicit (rather than always reading [`release_root_secret`]) so
/// the version-binding behavior is unit-testable and so the future per-boot
/// hardening (order 142) can layer a salt without changing this signature's
/// meaning. The returned key zeroizes on drop.
pub fn derive_psk(
    root_secret: &[u8],
    build_version: &str,
    wire_version: u16,
    hop: HopId,
) -> Zeroizing<[u8; 32]> {
    let info = format!("v={build_version};wire={wire_version};hop={}", hop.as_str());
    let hk = Hkdf::<Sha256>::new(Some(CONTROL_CHANNEL_SALT), root_secret);
    let mut okm = Zeroizing::new([0u8; 32]);
    hk.expand(info.as_bytes(), okm.as_mut())
        .expect("32 is a valid HKDF-SHA256 output length");
    okm
}

/// Convenience: derive the PSK for this binary using the build-embedded release
/// secret. Callers pass the local `build_version` (the `VERSION` string) and the
/// control-wire `WIRE_VERSION`.
pub fn channel_psk(build_version: &str, wire_version: u16, hop: HopId) -> Zeroizing<[u8; 32]> {
    derive_psk(release_root_secret(), build_version, wire_version, hop)
}

pub mod secure_stream;

pub use secure_stream::{EncryptedStream, client_handshake, server_handshake};

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: &[u8] = b"test-release-root-secret";
    const WIRE: u16 = 2;

    /// The core requirement: different build versions derive different keys, so
    /// mismatched-version peers cannot complete a handshake.
    #[test]
    fn psk_differs_across_build_version() {
        let a = derive_psk(ROOT, "0.3.260630.1", WIRE, HopId::HostGuest);
        let b = derive_psk(ROOT, "0.3.260701.1", WIRE, HopId::HostGuest);
        assert_ne!(*a, *b, "different build_version MUST yield a different PSK");
    }

    /// Hop domain separation: a host↔guest key is never usable guest↔container.
    #[test]
    fn psk_differs_across_hop() {
        let hg = derive_psk(ROOT, "0.3.260630.1", WIRE, HopId::HostGuest);
        let gc = derive_psk(ROOT, "0.3.260630.1", WIRE, HopId::GuestContainer);
        assert_ne!(*hg, *gc, "different hop MUST yield a different PSK");
    }

    /// A WIRE_VERSION change also re-keys the channel.
    #[test]
    fn psk_differs_across_wire_version() {
        let a = derive_psk(ROOT, "0.3.260630.1", 2, HopId::HostGuest);
        let b = derive_psk(ROOT, "0.3.260630.1", 3, HopId::HostGuest);
        assert_ne!(*a, *b, "different wire_version MUST yield a different PSK");
    }

    /// A different root secret re-keys everything (per-release binding + the
    /// future per-boot salt both rely on this).
    #[test]
    fn psk_differs_across_root_secret() {
        let a = derive_psk(b"root-a", "0.3.260630.1", WIRE, HopId::HostGuest);
        let b = derive_psk(b"root-b", "0.3.260630.1", WIRE, HopId::HostGuest);
        assert_ne!(*a, *b, "different root secret MUST yield a different PSK");
    }

    /// Determinism: both endpoints independently derive the SAME key from the
    /// same inputs, or they could never agree.
    #[test]
    fn psk_is_deterministic() {
        let a = derive_psk(ROOT, "0.3.260630.1", WIRE, HopId::HostGuest);
        let b = derive_psk(ROOT, "0.3.260630.1", WIRE, HopId::HostGuest);
        assert_eq!(*a, *b, "same inputs MUST yield the same PSK");
    }

    /// Dev builds fall back to the (non-secret) dev seed so local peers
    /// interoperate; release builds use the binary's own hash (never the seed).
    #[cfg(debug_assertions)]
    #[test]
    fn dev_root_secret_is_dev_seed() {
        assert_eq!(release_root_secret(), DEV_ROOT_SEED);
    }

    #[cfg(not(debug_assertions))]
    #[test]
    fn release_root_secret_is_binary_hash() {
        let secret = release_root_secret();
        assert!(!secret.is_empty());
        assert_eq!(secret.len(), 32, "SHA-256 output is 32 bytes");
    }

    #[test]
    fn hop_labels_are_stable() {
        assert_eq!(HopId::HostGuest.as_str(), "host-guest");
        assert_eq!(HopId::GuestContainer.as_str(), "guest-container");
    }
}
