//! Windows Credential Manager-backed installation UUID helper.
//!
//! Per the host-shell architecture spec, the only host-side secret the
//! tray is aware of is the `tillandsias-installation-uuid`. It is the
//! anchor the in-VM Vault auto-unseal derives its master key from. The
//! Windows tray persists the UUID in Windows Credential Manager under
//! target name `tillandsias-vm-uuid` so it survives reboots without
//! prompting the user.
//!
//! Note this is the host's *raw Win32* `CredReadW`/`CredWriteW` path — it
//! does NOT go through the `keyring` crate (that backend is only linked by
//! the in-VM `tillandsias-headless` Vault bootstrap on Linux). So the RC1
//! keyring-backend persistence fix does not cover this path; its cross-run
//! persistence is proven by the test at the bottom of this file, which runs
//! on a real Windows host (Linux CI never compiles this module).
//!
//! @trace spec:windows-native-tray, spec:host-shell-architecture, spec:tillandsias-vault

use uuid::Uuid;
use windows::Win32::Foundation::FILETIME;
use windows::Win32::Security::Credentials::{
    CRED_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredDeleteW, CredFree,
    CredReadW, CredWriteW,
};
use windows::core::{PCWSTR, PWSTR};

/// Stable target name used by `CredReadW`/`CredWriteW`. The Linux stub
/// shares this constant for cross-platform tests.
pub const TARGET_NAME: &str = "tillandsias-vm-uuid";

/// `HRESULT` for `ERROR_NOT_FOUND` (1168) — returned by Credential Manager
/// reads/deletes when no credential is registered under the target.
const HRESULT_ERROR_NOT_FOUND: u32 = 0x8007_0490;

/// Read the installation UUID from Windows Credential Manager. Returns
/// `Ok(None)` when no credential is registered yet (the most common case
/// on a fresh install).
pub fn read_installation_uuid() -> Result<Option<Uuid>, String> {
    read_installation_uuid_from(TARGET_NAME)
}

/// Persist `uuid` to Windows Credential Manager under `TARGET_NAME`.
///
/// Uses `CRED_PERSIST_LOCAL_MACHINE` so the secret survives logoff/reboot
/// without requiring the user to be present.
pub fn write_installation_uuid(uuid: Uuid) -> Result<(), String> {
    write_installation_uuid_to(TARGET_NAME, uuid)
}

/// Read-or-generate convenience used by the tray bootstrap.
pub fn ensure_installation_uuid() -> Result<Uuid, String> {
    if let Some(existing) = read_installation_uuid()? {
        return Ok(existing);
    }
    let fresh = Uuid::new_v4();
    write_installation_uuid(fresh)?;
    Ok(fresh)
}

/// Read a generic string credential stored under `target` from Windows Credential Manager.
pub fn read_credential_string(target: &str) -> Result<Option<String>, String> {
    let target_w = to_pwstr(target);
    let mut cred_ptr = std::ptr::null_mut::<CREDENTIALW>();
    let result = unsafe {
        CredReadW(
            PWSTR(target_w.as_ptr() as *mut _),
            CRED_TYPE_GENERIC,
            0,
            &mut cred_ptr,
        )
    };
    if let Err(err) = result {
        if err.code().0 as u32 == HRESULT_ERROR_NOT_FOUND {
            return Ok(None);
        }
        return Err(format!("CredReadW failed for {target}: {err:?}"));
    }
    if cred_ptr.is_null() {
        return Ok(None);
    }
    let cred = unsafe { &*cred_ptr };
    let blob = unsafe {
        std::slice::from_raw_parts(cred.CredentialBlob, cred.CredentialBlobSize as usize)
    };
    let text = std::str::from_utf8(blob)
        .map_err(|e| format!("credential blob for {target} is not UTF-8: {e}"))?
        .to_string();
    unsafe {
        CredFree(cred_ptr as *mut _);
    }
    Ok(Some(text.trim().to_string()))
}

/// Persist a generic string credential `value` under `target` in Windows Credential Manager.
pub fn write_credential_string(target: &str, value: &str) -> Result<(), String> {
    let target_w = to_pwstr(target);
    let value_bytes = value.as_bytes();

    let cred = CREDENTIALW {
        Flags: CRED_FLAGS(0),
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target_w.as_ptr() as *mut _),
        Comment: PWSTR::null(),
        LastWritten: FILETIME::default(),
        CredentialBlobSize: value_bytes.len() as u32,
        CredentialBlob: value_bytes.as_ptr() as *mut u8,
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        AttributeCount: 0,
        Attributes: std::ptr::null_mut(),
        TargetAlias: PWSTR::null(),
        UserName: PWSTR::null(),
    };
    let result = unsafe { CredWriteW(&cred, 0) };
    result.map_err(|err| format!("CredWriteW failed for {target}: {err:?}"))
}

/// Read the UUID stored under an arbitrary `target`. The public
/// [`read_installation_uuid`] delegates here with [`TARGET_NAME`]; tests use
/// a unique target so they never touch the production credential.
fn read_installation_uuid_from(target: &str) -> Result<Option<Uuid>, String> {
    if let Some(text) = read_credential_string(target)? {
        Uuid::parse_str(&text)
            .map(Some)
            .map_err(|e| format!("credential blob is not a UUID: {e}"))
    } else {
        Ok(None)
    }
}

/// Persist `uuid` under an arbitrary `target`. The public
/// [`write_installation_uuid`] delegates here with [`TARGET_NAME`].
fn write_installation_uuid_to(target: &str, uuid: Uuid) -> Result<(), String> {
    write_credential_string(target, &uuid.to_string())
}

/// Remove the credential stored under `target` from Windows Credential
/// Manager. Idempotent: an already-absent credential is treated as success,
/// so this is safe to call on uninstall or key rotation. Tests use it to
/// clean up their unique target; the eventual step-36 keychain rotation /
/// uninstall flow can reuse it.
pub fn delete_installation_uuid_for(target: &str) -> Result<(), String> {
    let target_w = to_pwstr(target);
    let result = unsafe { CredDeleteW(PCWSTR(target_w.as_ptr()), CRED_TYPE_GENERIC, 0) };
    if let Err(err) = result {
        if err.code().0 as u32 == HRESULT_ERROR_NOT_FOUND {
            return Ok(());
        }
        return Err(format!("CredDeleteW failed: {err:?}"));
    }
    Ok(())
}

/// Connects to the in-VM agent, delivers the host Credential Manager-backed `vault-shamir-share-v1`
/// and `tillandsias-vm-uuid` on connection startup, and retrieves any pending handover credentials.
pub async fn deliver_credentials_and_check_handover(
    client: &mut tillandsias_host_shell::vsock_client::Client,
) -> Result<(), String> {
    let uuid = ensure_installation_uuid()?;
    let share = read_credential_string("vault-shamir-share-v1")?;
    let token = read_credential_string("vault-root-token-v1")?;

    let seq = client.allocate_seq();
    let env = tillandsias_control_wire::ControlEnvelope {
        wire_version: tillandsias_control_wire::WIRE_VERSION,
        seq,
        body: tillandsias_control_wire::ControlMessage::DeliverCredentials {
            seq,
            unseal_share_b64: share,
            installation_uuid: uuid.to_string(),
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
                write_credential_string("vault-shamir-share-v1", &s)?;
            }
            if let Some(t) = root_token {
                write_credential_string("vault-root-token-v1", &t)?;
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

fn to_pwstr(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RAII cleanup so the test's unique target credential is removed even if
    /// an assertion panics mid-test — the test must never leak a credential
    /// into the operator's real Credential Manager store.
    struct CredCleanup(String);
    impl Drop for CredCleanup {
        fn drop(&mut self) {
            let _ = delete_installation_uuid_for(&self.0);
        }
    }

    /// Round-trip proof against the *real* Windows Credential Manager: a value
    /// written in one call is read back by a separate later call (persisting
    /// across calls is the in-process proxy for persisting across process
    /// runs), an overwrite replaces it, and delete clears it. Uses a unique
    /// per-run target so it never reads or clobbers the production
    /// `tillandsias-vm-uuid` credential. This is the automated coverage that
    /// the long-empty `installation_uuid_roundtrips_via_credential_manager`
    /// placeholder in `tests/portable_smoke.rs` always pointed at but never
    /// implemented — Linux CI cannot compile this `#[cfg(windows)]` module.
    ///
    /// @trace spec:tillandsias-vault, spec:windows-native-tray
    #[test]
    fn credential_manager_persists_uuid_across_calls() {
        let target = format!("tillandsias-vm-uuid-test-{}", Uuid::new_v4());
        let _cleanup = CredCleanup(target.clone());

        // Absent before the first write.
        assert_eq!(
            read_installation_uuid_from(&target).unwrap(),
            None,
            "fresh target should have no credential yet"
        );

        // Write, then read it back in a *separate* call — the persistence proof.
        let first = Uuid::new_v4();
        write_installation_uuid_to(&target, first).unwrap();
        assert_eq!(
            read_installation_uuid_from(&target).unwrap(),
            Some(first),
            "value written in one call must be readable in a later call"
        );

        // Overwrite replaces the stored value.
        let second = Uuid::new_v4();
        write_installation_uuid_to(&target, second).unwrap();
        assert_eq!(
            read_installation_uuid_from(&target).unwrap(),
            Some(second),
            "overwrite must replace the previously stored value"
        );

        // Delete clears it; a second delete is idempotent (already absent).
        delete_installation_uuid_for(&target).unwrap();
        assert_eq!(
            read_installation_uuid_from(&target).unwrap(),
            None,
            "delete must remove the credential"
        );
        delete_installation_uuid_for(&target).unwrap();
    }
}
