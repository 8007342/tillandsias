//! Windows Credential Manager-backed installation UUID helper.
//!
//! Per the host-shell architecture spec, the only host-side secret the
//! tray is aware of is the `tillandsias-installation-uuid`. It is the
//! anchor the in-VM Vault auto-unseal derives its master key from. The
//! Windows tray persists the UUID in Windows Credential Manager under
//! target name `tillandsias-vm-uuid` so it survives reboots without
//! prompting the user.
//!
//! @trace spec:windows-native-tray, spec:host-shell-architecture, spec:tillandsias-vault

#![allow(dead_code)]

use std::mem::size_of;

use uuid::Uuid;
use windows::Win32::Foundation::FILETIME;
use windows::Win32::Security::Credentials::{
    CRED_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC, CREDENTIALW, CredFree, CredReadW,
    CredWriteW,
};
use windows::core::PWSTR;

/// Stable target name used by `CredReadW`/`CredWriteW`. The Linux stub
/// shares this constant for cross-platform tests.
pub const TARGET_NAME: &str = "tillandsias-vm-uuid";

/// Read the installation UUID from Windows Credential Manager. Returns
/// `Ok(None)` when no credential is registered yet (the most common case
/// on a fresh install).
pub fn read_installation_uuid() -> Result<Option<Uuid>, String> {
    let target = to_pwstr(TARGET_NAME);
    let mut cred_ptr = std::ptr::null_mut::<CREDENTIALW>();
    let result = unsafe {
        CredReadW(
            PWSTR(target.as_ptr() as *mut _),
            CRED_TYPE_GENERIC,
            0,
            &mut cred_ptr,
        )
    };
    if let Err(err) = result {
        // ERROR_NOT_FOUND (1168) = no credential, which is normal pre-bootstrap.
        if err.code().0 as u32 == 0x80070490 {
            return Ok(None);
        }
        return Err(format!("CredReadW failed: {err:?}"));
    }
    if cred_ptr.is_null() {
        return Ok(None);
    }
    let cred = unsafe { &*cred_ptr };
    let blob = unsafe {
        std::slice::from_raw_parts(cred.CredentialBlob, cred.CredentialBlobSize as usize)
    };
    let text = std::str::from_utf8(blob)
        .map_err(|e| format!("credential blob is not UTF-8: {e}"))?
        .to_string();
    unsafe {
        CredFree(cred_ptr as *mut _);
    }
    Uuid::parse_str(text.trim())
        .map(Some)
        .map_err(|e| format!("credential blob is not a UUID: {e}"))
}

/// Persist `uuid` to Windows Credential Manager under `TARGET_NAME`.
///
/// Uses `CRED_PERSIST_LOCAL_MACHINE` so the secret survives logoff/reboot
/// without requiring the user to be present.
pub fn write_installation_uuid(uuid: Uuid) -> Result<(), String> {
    let target = to_pwstr(TARGET_NAME);
    let value = uuid.to_string();
    let value_bytes = value.as_bytes();

    let cred = CREDENTIALW {
        Flags: CRED_FLAGS(0),
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target.as_ptr() as *mut _),
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
    let _ = size_of::<CREDENTIALW>();
    let result = unsafe { CredWriteW(&cred, 0) };
    result.map_err(|err| format!("CredWriteW failed: {err:?}"))
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

fn to_pwstr(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
