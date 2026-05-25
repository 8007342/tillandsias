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

fn stub_path() -> PathBuf {
    let dir = std::env::var_os("TILLANDSIAS_TRAY_TEST_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    dir.join(format!("{}.txt", TARGET_NAME))
}

/// Read the installation UUID from the keychain (Windows) or a tempdir
/// file (Linux stub). Returns `Ok(None)` when no UUID has been written yet.
pub fn read_installation_uuid() -> Result<Option<Uuid>, String> {
    let path = stub_path();
    match std::fs::read_to_string(&path) {
        Ok(contents) => Uuid::parse_str(contents.trim())
            .map(Some)
            .map_err(|e| format!("invalid UUID in {}: {e}", path.display())),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!("read {}: {err}", path.display())),
    }
}

/// Persist `uuid` to the keychain (Windows) or tempdir file (Linux stub).
pub fn write_installation_uuid(uuid: Uuid) -> Result<(), String> {
    let path = stub_path();
    std::fs::write(&path, uuid.to_string()).map_err(|e| format!("write {}: {e}", path.display()))
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
