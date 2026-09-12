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
/// identical hashes and therefore derive the same PSK.
///
/// THIS IS THE **GUEST**'S DERIVATION ONLY. The host must NOT use it for the
/// host↔guest hop — see [`channel_psk_for_guest`]. The sentence that used to
/// stand here claimed that "when the host embeds the guest binary and
/// overwrites the guest on each boot (order 190), both ends automatically run
/// identical content and derive matching keys". That was never implemented on
/// the host side and cannot be: the host runs the TRAY (a macOS Mach-O or a
/// Windows PE) while the guest runs `tillandsias-headless` (a Linux musl ELF),
/// so `current_exe()` names a different file on each end and the two binaries
/// can never be byte-identical. Both ends derived from their own self-hash,
/// the ikm differed, and the NNpsk0 handshake failed with a perfectly equal
/// (build_version, wire_version, hop) triple.
///
/// MEASURED on macOS 2026-09-12 against published v56.9.12.1 (order
/// 1084-x8ya): tray `3777f0ae…`, guest `68f176d0…`; the guest asserted
/// readiness in 36 s and kept running while the host, unable to complete the
/// handshake, reported "phase never reached Ready" 300 s later. The defect was
/// invisible until 79e3ca876 made the wire secure by default, because before
/// that the handshake did not run at all. Linux never saw it: there is no
/// guest VM there, so this hop does not exist.
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

/// Derive the host's side of the host↔guest PSK from the GUEST binary's digest.
///
/// **This is the host's derivation for [`HopId::HostGuest`]; [`channel_psk`] is
/// the guest's.** The guest self-hashes the binary it is running, so the host
/// must supply exactly that digest — SHA-256 over the same bytes — or the two
/// ends derive different keys and NNpsk0 fails closed (order 1084-x8ya).
///
/// `guest_binary_sha256` MUST be a digest the host knows at TRAY BUILD TIME —
/// the SHA-256 of the guest asset shipped with this release — and never a hash
/// of a file read from the host at runtime. A runtime read would make the host
/// agree with whatever guest happens to be on disk, which is precisely the
/// skew that must stay visible: a guest that was never re-staged keeps its old
/// self-hash, mismatches, and is refused with a named cause. That refusal is
/// the design working, not a regression.
///
/// It exists as a named function rather than leaving each caller to hash for
/// itself because there are several call sites and two candidate files on each
/// platform; hand-rolled hashing is a wrong file waiting to happen.
pub fn channel_psk_for_guest(
    guest_binary_sha256: &[u8; 32],
    build_version: &str,
    wire_version: u16,
    hop: HopId,
) -> Zeroizing<[u8; 32]> {
    derive_psk(guest_binary_sha256, build_version, wire_version, hop)
}

pub mod secure_stream;

pub use secure_stream::{
    EncryptedStream, client_handshake, server_handshake, server_handshake_or_reclaim,
};

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

    /// ORDER 1084-x8ya — the defect this crate shipped, expressed as a test.
    ///
    /// The host and the guest are DIFFERENT BINARIES: a macOS/Windows tray and
    /// a Linux musl `tillandsias-headless`. Every host caller used to derive
    /// from `release_root_secret()` = SHA-256 of its OWN exe, so the ikm
    /// differed from the guest's self-hash and NNpsk0 failed closed even with
    /// an identical (build_version, wire_version, hop) triple.
    ///
    /// WHY THIS TEST USES EXPLICIT BYTE STRINGS AND NOT `release_root_secret`:
    /// a single-process fixture has exactly ONE `current_exe`, so it derives
    /// ONE self-hash for both ends and CANNOT express this defect by
    /// construction. That is also why the round-trip test below could never
    /// have caught it. **Do not "upgrade" either test to `--release` to cover
    /// this**: under `--release` a one-process test still hashes the same file
    /// on both sides and passes whether or not the keying is correct — a
    /// harness that guarantees the invariant it checks. The only integration
    /// proof is two DISTINCT binaries: a release-built tray and the release
    /// guest reaching Ready on a real cold provision.
    #[test]
    fn host_derives_the_guests_key_from_the_guest_binary_not_its_own() {
        use sha2::Digest;

        // Stand-ins for two binaries that can never be byte-identical.
        const TRAY_BYTES: &[u8] = b"pretend-mach-o-tray-bytes";
        const GUEST_BYTES: &[u8] = b"pretend-musl-guest-bytes";

        let guest_digest: [u8; 32] = Sha256::digest(GUEST_BYTES).into();
        let tray_digest: [u8; 32] = Sha256::digest(TRAY_BYTES).into();

        // What the GUEST derives: self-hash of the bytes it is running.
        let guest_self = derive_psk(&guest_digest, "56.9.12.1", WIRE, HopId::HostGuest);
        // What the HOST derives now: from the guest's digest.
        let host_from_guest =
            channel_psk_for_guest(&guest_digest, "56.9.12.1", WIRE, HopId::HostGuest);
        // What the HOST used to derive: self-hash of its own exe. The defect.
        let host_self = derive_psk(&tray_digest, "56.9.12.1", WIRE, HopId::HostGuest);

        assert_eq!(
            *host_from_guest, *guest_self,
            "host and guest MUST derive the same PSK — the host keys off the \
             guest binary's digest, which is what the guest self-hashes"
        );
        assert_ne!(
            *host_from_guest, *host_self,
            "deriving from the host's OWN binary is order 1084-x8ya; if these \
             are equal the fix has been reverted and the handshake is broken \
             again on every guest-VM platform"
        );
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
