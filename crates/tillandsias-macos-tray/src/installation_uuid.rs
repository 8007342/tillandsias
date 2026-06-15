//! Persist + read the Tillandsias credentials from the macOS Keychain.
//!
//! Per `tillandsias-vault` spec, the host stores exactly one secret in the
//! OS keychain: a stable random UUID used as the anchor for the in-VM
//! vault's auto-unseal derivation. Loss of the UUID means the user has to
//! re-bootstrap (the VM's vault gets wiped); persistence across OS upgrades
//! is therefore important enough to use the Keychain rather than a plain
//! file under `~/Library/Application Support/`.
//!
//! Under Step 36, the host also stores Vault's generated unseal share and
//! root token in the Keychain once captured from the VM, delivering them
//! on VM start.
//!
//! Implementation: we shell out to the `security` CLI rather than linking
//! `Security.framework` directly. `security add-generic-password` /
//! `security find-generic-password` are stable since Mac OS X 10.4 and
//! avoid the Cocoa code-signing requirements of the direct API.
//!
//! macOS-only.
//!
//! @trace spec:host-shell-architecture.security.no-host-credentials@v1,
//!        spec:tillandsias-vault

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
    if let Some(existing) = read_credential_string(KEYCHAIN_ACCOUNT)? {
        return Ok(existing);
    }
    let new = generate_uuid();
    write_credential_string(KEYCHAIN_ACCOUNT, &new)?;
    Ok(new)
}

/// Read a generic string credential stored under `target` from the macOS keychain.
pub fn read_credential_string(target: &str) -> std::io::Result<Option<String>> {
    let output = Command::new("security")
        .args([
            "find-generic-password",
            "-a",
            target,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
        ])
        .output()?;
    if !output.status.success() {
        // `security` exits 44 (errSecItemNotFound) when the entry is missing.
        return Ok(None);
    }
    let secret = String::from_utf8(output.stdout)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?
        .trim()
        .to_string();
    if secret.is_empty() {
        return Ok(None);
    }
    Ok(Some(secret))
}

/// Persist a generic string credential `value` under `target` in the macOS keychain.
pub fn write_credential_string(target: &str, value: &str) -> std::io::Result<()> {
    let status = Command::new("security")
        .args([
            "add-generic-password",
            "-a",
            target,
            "-s",
            KEYCHAIN_SERVICE,
            "-w",
            value,
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

/// Remove the credential stored under `target` from the macOS keychain.
pub fn delete_credential_string(target: &str) -> std::io::Result<()> {
    let _status = Command::new("security")
        .args([
            "delete-generic-password",
            "-a",
            target,
            "-s",
            KEYCHAIN_SERVICE,
        ])
        .status()?;
    // We treat already-absent or successfully deleted as Ok for idempotency.
    Ok(())
}

/// Connects to the in-VM agent, delivers the host Keychain-backed `vault-shamir-share-v1`
/// and `tillandsias-vm-uuid` on connection startup, and retrieves any pending handover credentials.
pub async fn deliver_credentials_and_check_handover(
    client: &mut tillandsias_host_shell::vsock_client::Client,
) -> Result<(), String> {
    let uuid = read_or_generate().map_err(|e| format!("read_or_generate UUID failed: {e}"))?;
    let share = read_credential_string("vault-shamir-share-v1")
        .map_err(|e| format!("read share failed: {e}"))?;
    let token = read_credential_string("vault-root-token-v1")
        .map_err(|e| format!("read token failed: {e}"))?;

    let seq = client.allocate_seq();
    let env = tillandsias_control_wire::ControlEnvelope {
        wire_version: tillandsias_control_wire::WIRE_VERSION,
        seq,
        body: tillandsias_control_wire::ControlMessage::DeliverCredentials {
            seq,
            unseal_share_b64: share,
            installation_uuid: uuid,
            root_token: token,
        },
    };
    let reply = client
        .request(&env)
        .await
        .map_err(|e| format!("DeliverCredentials request failed: {e}"))?;

    match reply.body {
        tillandsias_control_wire::ControlMessage::DeliverCredentialsReply {
            success: true, ..
        } => {}
        tillandsias_control_wire::ControlMessage::Error { message, .. } => {
            return Err(format!("DeliverCredentials failed: {message}"));
        }
        other => {
            return Err(format!("unexpected reply to DeliverCredentials: {other:?}"));
        }
    }

    let seq = client.allocate_seq();
    let env = tillandsias_control_wire::ControlEnvelope {
        wire_version: tillandsias_control_wire::WIRE_VERSION,
        seq,
        body: tillandsias_control_wire::ControlMessage::GetVaultHandover { seq },
    };
    let reply = client
        .request(&env)
        .await
        .map_err(|e| format!("GetVaultHandover request failed: {e}"))?;

    match reply.body {
        tillandsias_control_wire::ControlMessage::VaultHandoverReply {
            unseal_share_b64,
            root_token,
            ..
        } => {
            if let Some(s) = unseal_share_b64 {
                write_credential_string("vault-shamir-share-v1", &s)
                    .map_err(|e| format!("write share failed: {e}"))?;
            }
            if let Some(t) = root_token {
                write_credential_string("vault-root-token-v1", &t)
                    .map_err(|e| format!("write token failed: {e}"))?;
            }
        }
        tillandsias_control_wire::ControlMessage::Error { message, .. } => {
            return Err(format!("GetVaultHandover failed: {message}"));
        }
        other => {
            return Err(format!("unexpected reply to GetVaultHandover: {other:?}"));
        }
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

    /// RAII cleanup so the test's unique target credential is removed even if
    /// an assertion panics mid-test.
    struct CredCleanup(String);
    impl Drop for CredCleanup {
        fn drop(&mut self) {
            let _ = delete_credential_string(&self.0);
        }
    }

    /// Round-trip proof against the real macOS Keychain.
    #[test]
    fn keychain_persists_credentials_across_calls() {
        let target = format!("tillandsias-test-target-{}", generate_uuid());
        let _cleanup = CredCleanup(target.clone());

        assert_eq!(
            read_credential_string(&target).unwrap(),
            None,
            "fresh target should have no credential yet"
        );

        let value = "my-test-secret-value-123";
        write_credential_string(&target, value).unwrap();
        assert_eq!(
            read_credential_string(&target).unwrap(),
            Some(value.to_string()),
            "value written in one call must be readable in a later call"
        );

        let value2 = "my-test-secret-value-456";
        write_credential_string(&target, value2).unwrap();
        assert_eq!(
            read_credential_string(&target).unwrap(),
            Some(value2.to_string()),
            "overwrite must replace the previously stored value"
        );

        delete_credential_string(&target).unwrap();
        assert_eq!(
            read_credential_string(&target).unwrap(),
            None,
            "delete must remove the credential"
        );
    }

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
