//! Persist + read the Tillandsias installation UUID from the macOS Keychain.
//!
//! Per `tillandsias-vault` spec, the host stores exactly one secret in the
//! OS keychain: a stable random UUID used as the anchor for the in-VM
//! vault's auto-unseal derivation. Loss of the UUID means the user has to
//! re-bootstrap (the VM's vault gets wiped); persistence across OS upgrades
//! is therefore important enough to use the Keychain rather than a plain
//! file under `~/Library/Application Support/`.
//!
//! Implementation: we shell out to the `security` CLI rather than linking
//! `Security.framework` directly. `security add-generic-password` /
//! `security find-generic-password` are stable since Mac OS X 10.4 and
//! avoid the Cocoa code-signing requirements of the direct API. The
//! account name `tillandsias-vm-uuid` is what the spec mandates.
//!
//! macOS-only.
//!
//! @trace spec:host-shell-architecture.security.no-host-credentials@v1,
//!        spec:tillandsias-vault

#![allow(dead_code)]
#![allow(unused)]

use std::process::Command;

/// Account name passed to `security`. Matches the spec's "single hidden key
/// `tillandsias-vm-uuid`" wording.
pub const KEYCHAIN_ACCOUNT: &str = "tillandsias-vm-uuid";

/// Service name for the keychain entry — namespaced so users can find
/// it in Keychain Access.app under the obvious search.
pub const KEYCHAIN_SERVICE: &str = "tillandsias";

/// Read the installation UUID from the macOS keychain, generating + storing
/// a new one on first call. Idempotent: every subsequent call returns the
/// same UUID for the host's lifetime.
///
/// @trace spec:host-shell-architecture.security.no-host-credentials@v1
pub fn read_or_generate() -> std::io::Result<String> {
    if let Some(existing) = read_uuid()? {
        return Ok(existing);
    }
    let new = generate_uuid();
    write_uuid(&new)?;
    Ok(new)
}

/// Look up the existing UUID. Returns `Ok(None)` if the keychain has no
/// entry under our account name; returns `Err` only for unexpected I/O.
fn read_uuid() -> std::io::Result<Option<String>> {
    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-a",
            KEYCHAIN_ACCOUNT,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
        ])
        .output()?;
    if !output.status.success() {
        // `security` exits 44 (errSecItemNotFound) when the entry is
        // missing. Treat any non-zero exit as "missing" rather than
        // surfacing the noisy stderr to the tray.
        return Ok(None);
    }
    let uuid = String::from_utf8(output.stdout)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?
        .trim()
        .to_string();
    if uuid.is_empty() {
        return Ok(None);
    }
    Ok(Some(uuid))
}

/// Add the UUID under the conventional account+service pair.
///
/// `-U` makes the call idempotent: it updates the entry if it already
/// exists rather than failing with errSecDuplicateItem.
fn write_uuid(uuid: &str) -> std::io::Result<()> {
    let status = Command::new("security")
        .args([
            "add-generic-password",
            "-a",
            KEYCHAIN_ACCOUNT,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
            uuid,
            "-U",
        ])
        .status()?;
    if !status.success() {
        return Err(std::io::Error::other(format!(
            "security add-generic-password exited {status}"
        )));
    }
    Ok(())
}

/// Generate a fresh UUIDv4 string. We avoid pulling in the `uuid` crate
/// here because the macos-tray binary already has enough dependencies;
/// this single producer is the only call site.
///
/// @trace spec:host-shell-architecture.security.no-host-credentials@v1
fn generate_uuid() -> String {
    use std::time::SystemTime;
    // Best-effort entropy mix from the wall clock + process id. Sufficient
    // for the spec's "machine-bound UUID" purpose; not a security key on
    // its own (the actual unseal anchor is HKDF'd over machine-id + this).
    let now_nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id() as u128;
    let mut bytes = [0u8; 16];
    bytes[..8].copy_from_slice(&now_nanos.to_le_bytes()[..8]);
    bytes[8..].copy_from_slice(&pid.to_le_bytes()[..8]);
    // Force version=4 (random) and variant=10xx per RFC 4122.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// @trace spec:host-shell-architecture.security.no-host-credentials@v1
    #[test]
    fn generated_uuid_has_v4_format() {
        let uuid = generate_uuid();
        assert_eq!(uuid.len(), 36, "UUID string length");
        assert_eq!(uuid.as_bytes()[8], b'-');
        assert_eq!(uuid.as_bytes()[13], b'-');
        assert_eq!(uuid.as_bytes()[18], b'-');
        assert_eq!(uuid.as_bytes()[23], b'-');
        // Version 4 marker at the 14th character (index 14).
        assert_eq!(uuid.as_bytes()[14], b'4', "v4 marker");
        // Variant bits at the 19th character: must be one of 8, 9, a, b.
        let variant = uuid.as_bytes()[19];
        assert!(
            matches!(variant, b'8' | b'9' | b'a' | b'b'),
            "variant marker, got {}",
            variant as char
        );
    }

    /// @trace spec:host-shell-architecture.security.no-host-credentials@v1
    #[test]
    fn keychain_account_matches_spec_wording() {
        assert_eq!(KEYCHAIN_ACCOUNT, "tillandsias-vm-uuid");
    }
}
