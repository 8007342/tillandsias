//! Linux compile-stub for the Windows installation-UUID helper.
//!
//! The Windows module reads/writes the installation UUID via
//! `CredReadW`/`CredWriteW`. On Linux we can't talk to Windows Credential
//! Manager, so this stub:
//! - Reads from / writes to a deterministic tempdir file
//! - Returns an error if the env var
//!   `TILLANDSIAS_WINDOWS_TRAY_INSTALL_UUID_LINUX` is unset and no file
//!   exists yet, leaving callers to handle the "not initialised" case.
//!
//! Tests in `tests/` exercise this stub to validate the lifecycle without
//! a Windows Credential Manager.
//!
//! @trace spec:windows-native-tray

#![allow(dead_code)]

use std::path::PathBuf;

use uuid::Uuid;

/// Stable target name used by both the Windows real and Linux stub paths.
/// The Windows path uses it as the `CredReadW` target; the Linux stub
/// composes a file path under `$TMPDIR/<TARGET_NAME>`.
pub const TARGET_NAME: &str = "tillandsias-vm-uuid";

fn stub_path_for(target: &str) -> PathBuf {
    let dir = std::env::var_os("TILLANDSIAS_TRAY_TEST_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    dir.join(format!("{}.txt", target))
}

fn stub_path() -> PathBuf {
    stub_path_for(TARGET_NAME)
}

/// Read a generic string credential stored under `target` from the stub store.
pub fn read_credential_string(target: &str) -> Result<Option<String>, String> {
    let path = stub_path_for(target);
    match std::fs::read_to_string(&path) {
        Ok(contents) => Ok(Some(contents.trim().to_string())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!("read {}: {err}", path.display())),
    }
}

/// Persist a generic string credential `value` under `target` in the stub store.
pub fn write_credential_string(target: &str, value: &str) -> Result<(), String> {
    let path = stub_path_for(target);
    std::fs::write(&path, value).map_err(|e| format!("write {}: {e}", path.display()))
}

/// Read the installation UUID from the keychain (Windows) or a tempdir
/// file (Linux stub). Returns `Ok(None)` when no UUID has been written yet.
pub fn read_installation_uuid() -> Result<Option<Uuid>, String> {
    if let Some(text) = read_credential_string(TARGET_NAME)? {
        Uuid::parse_str(&text)
            .map(Some)
            .map_err(|e| format!("invalid UUID: {e}"))
    } else {
        Ok(None)
    }
}

/// Persist `uuid` to the keychain (Windows) or tempdir file (Linux stub).
pub fn write_installation_uuid(uuid: Uuid) -> Result<(), String> {
    write_credential_string(TARGET_NAME, &uuid.to_string())
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

/// Remove the credential stored under `target` from the stub store.
pub fn delete_installation_uuid_for(target: &str) -> Result<(), String> {
    let path = stub_path_for(target);
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| format!("remove {}: {e}", path.display()))?;
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
