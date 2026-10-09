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

/// Credential Manager target holding the host's copy of the guest Vault's
/// Shamir unseal share.
pub const VAULT_SHARE_TARGET: &str = "vault-shamir-share-v1";

/// Credential Manager target holding the host's copy of the guest Vault's
/// root token.
pub const VAULT_ROOT_TOKEN_TARGET: &str = "vault-root-token-v1";

/// The two credentials that describe a SPECIFIC guest Vault's identity, and
/// therefore the two that a guest wipe invalidates. `TARGET_NAME` is
/// deliberately NOT here — see [`clear_guest_vault_credentials`].
pub const GUEST_VAULT_TARGETS: [&str; 2] = [VAULT_SHARE_TARGET, VAULT_ROOT_TOKEN_TARGET];

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

/// Clear the host's copy of the guest Vault's identity — the Shamir unseal
/// share and the root token — from Credential Manager. Returns the targets
/// that were actually present and removed, so a caller can report what it
/// did rather than claiming a clear it did not perform.
///
/// **Every path that wipes the guest must call this** (`--reset-guest`, the
/// installer's `-Purge`, the destructive-reset step of the e2e runbooks).
/// The two credentials describe a specific guest Vault's identity, so a wipe
/// invalidates them by construction — but nothing in the product deleted
/// them, and `deliver_credentials_and_check_handover` sends them into the
/// fresh guest unconditionally, before `GetVaultHandover` reads the guest's
/// real values back. The stale share then loses to the guest's own unseal
/// secret with "cipher: message authentication failed", the self-heal
/// aborts, and GitHub login is permanently broken — so the product's own
/// advertised reset bricked its own login (803-49re, operator-reported on a
/// freshly installed v0.4.260817.1 whose guest had been re-provisioned 40
/// minutes earlier).
///
/// Deleting is the whole fix, and it works because absence is already
/// handled everywhere: [`read_credential_string`] returns `Ok(None)` on
/// NOT_FOUND, so the tray delivers `None` and `GetVaultHandover`
/// re-populates Credential Manager from the guest's real state. That is
/// exactly the manual repair the operator performed and verified on
/// 2026-08-17.
///
/// `tillandsias-vm-uuid` is deliberately PRESERVED. It is the installation
/// anchor the in-VM Vault derives its master key from; it identifies the
/// INSTALL, not the guest, and clearing it would rotate the installation
/// identity on every reset.
///
/// Do NOT repair these entries with `cmdkey`: [`read_credential_string`]
/// parses the blob as UTF-8 and `cmdkey` stores UTF-16, so a hand-written
/// credential fails with "credential blob is not UTF-8". Deleting and
/// letting the handover re-populate is the only correct manual path.
///
/// @trace order:803-49re
pub fn clear_guest_vault_credentials() -> Result<Vec<&'static str>, String> {
    clear_credentials(&GUEST_VAULT_TARGETS)
}

/// The body of [`clear_guest_vault_credentials`], parameterised over the
/// targets so a test can exercise it against unique throwaway targets. A test
/// must NEVER call the public wrapper: its targets are the operator's real
/// credentials, and deleting those on a developer's machine breaks their
/// running install.
fn clear_credentials(targets: &[&'static str]) -> Result<Vec<&'static str>, String> {
    let mut cleared = Vec::new();
    for target in targets {
        // Read first so the return value reports what was actually there;
        // the delete itself is idempotent on NOT_FOUND either way.
        let was_present = read_credential_string(target)?.is_some();
        delete_installation_uuid_for(target)?;
        if was_present {
            cleared.push(*target);
        }
    }
    Ok(cleared)
}

/// Connects to the in-VM agent, delivers the host Credential Manager-backed `vault-shamir-share-v1`
/// and `tillandsias-vm-uuid` on connection startup, and retrieves any pending handover credentials.
pub async fn deliver_credentials_and_check_handover(
    client: &mut tillandsias_host_shell::vsock_client::Client,
) -> Result<(), String> {
    deliver_and_handover_with(client, &PRODUCTION_TARGETS).await
}

/// The three Credential Manager targets the delivery reads and the handover
/// writes. Production uses the real names; tests pass scratch `...-test-<uuid>`
/// names they delete, so a test never writes the operator's real credentials
/// (order 1562-bqcg).
pub(crate) struct CredTargets<'a> {
    pub(crate) uuid: &'a str,
    pub(crate) share: &'a str,
    pub(crate) token: &'a str,
}

const PRODUCTION_TARGETS: CredTargets<'static> = CredTargets {
    uuid: TARGET_NAME,
    share: VAULT_SHARE_TARGET,
    token: VAULT_ROOT_TOKEN_TARGET,
};

pub(crate) async fn deliver_and_handover_with(
    client: &mut tillandsias_host_shell::vsock_client::Client,
    targets: &CredTargets<'_>,
) -> Result<(), String> {
    let uuid = match read_installation_uuid_from(targets.uuid)? {
        Some(existing) => existing,
        None => {
            let fresh = Uuid::new_v4();
            write_installation_uuid_to(targets.uuid, fresh)?;
            fresh
        }
    };
    let share = read_credential_string(targets.share)?;
    let token = read_credential_string(targets.token)?;

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
        // ORDER 890-y72v. `success: true` is FRAME RECEIPT — the guest got the
        // envelope and stored it. It was never an acceptance, and matching on
        // it alone is what let a delivery the guest discarded, or one whose
        // fallback write failed, read here as a working credential. The
        // operator's 2026-08-17 failure was silent for an hour on this arm.
        //
        // `..` still absorbs the rest of the variant, so this arm compiled
        // unchanged when `outcome` was added — which is precisely why it has
        // to be written out rather than left to a field nobody reads.
        tillandsias_control_wire::ControlMessage::DeliverCredentialsReply {
            success: true,
            outcome,
            ..
        } => {
            // ORDER 1562-bqcg: Superseded goes on to read the handover.
            if !outcome.proceeds_to_handover() {
                return Err(format!(
                    "DeliverCredentials was received but not accepted: {}",
                    outcome.describe()
                ));
            }
        }
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
                write_credential_string(targets.share, &s)?;
            }
            if let Some(t) = root_token {
                write_credential_string(targets.token, &t)?;
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

    /// 803-49re, the half that decides the bug: a host-side share that
    /// survives a guest wipe is delivered into the fresh guest unconditionally
    /// and permanently breaks GitHub login. The wipe must clear it.
    ///
    /// Exercised against unique throwaway targets — never the public
    /// [`clear_guest_vault_credentials`], whose targets are the operator's
    /// real credentials.
    ///
    /// Red against the pre-fix product, where nothing outside tests ever
    /// deleted these two credentials.
    ///
    /// @trace order:803-49re
    #[test]
    fn a_guest_wipe_clears_the_host_side_vault_credentials() {
        let run = Uuid::new_v4();
        let share: &'static str =
            Box::leak(format!("vault-shamir-share-v1-test-{run}").into_boxed_str());
        let token: &'static str =
            Box::leak(format!("vault-root-token-v1-test-{run}").into_boxed_str());
        let _c1 = CredCleanup(share.to_string());
        let _c2 = CredCleanup(token.to_string());

        // The state a guest wipe leaves behind today: the host still holds
        // the dead guest's vault identity.
        write_credential_string(share, "stale-share-from-the-wiped-guest").unwrap();
        write_credential_string(token, "stale-root-token-from-the-wiped-guest").unwrap();

        let cleared = clear_credentials(&[share, token]).unwrap();

        assert_eq!(
            cleared,
            vec![share, token],
            "both present credentials must be reported as cleared"
        );
        // This is the property the delivery path depends on: read returns
        // None, so the tray delivers None and GetVaultHandover re-populates
        // from the guest's own state.
        assert_eq!(read_credential_string(share).unwrap(), None);
        assert_eq!(read_credential_string(token).unwrap(), None);

        // Idempotent: a second wipe is not an error, and reports nothing
        // cleared because nothing was there.
        assert!(
            clear_credentials(&[share, token]).unwrap().is_empty(),
            "clearing an already-clear store must report nothing cleared"
        );
    }

    /// A fake guest on the other end of an in-memory stream: answers the
    /// delivery with `outcome`, then (if asked) the handover with
    /// `fresh-share` / `fresh-token`. Returns whether the handover was asked.
    async fn fake_guest(
        io: tokio::io::DuplexStream,
        outcome: tillandsias_control_wire::DeliverCredentialsOutcome,
    ) -> bool {
        use futures_util::{SinkExt, StreamExt};
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
        type Io = tokio_util::codec::Framed<
            tokio::io::DuplexStream,
            tokio_util::codec::LengthDelimitedCodec,
        >;
        let mut io: Io = tokio_util::codec::Framed::new(
            io,
            tillandsias_control_wire::transport::control_frame_codec(),
        );
        async fn recv(io: &mut Io) -> Option<ControlEnvelope> {
            let frame = io.next().await?.ok()?;
            tillandsias_control_wire::decode(&frame).ok()
        }
        async fn send(io: &mut Io, seq: u64, body: ControlMessage) {
            let bytes = tillandsias_control_wire::encode(&ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq,
                body,
            })
            .unwrap();
            io.send(bytes.into()).await.unwrap();
        }
        let Some(env) = recv(&mut io).await else {
            return false;
        };
        let ControlMessage::DeliverCredentials { seq, .. } = env.body else {
            panic!("expected DeliverCredentials first, got {:?}", env.body)
        };
        send(
            &mut io,
            env.seq,
            ControlMessage::DeliverCredentialsReply {
                seq_in_reply_to: seq,
                success: true,
                outcome,
            },
        )
        .await;
        let Some(env) = recv(&mut io).await else {
            return false;
        };
        let ControlMessage::GetVaultHandover { seq } = env.body else {
            panic!("expected GetVaultHandover, got {:?}", env.body)
        };
        send(
            &mut io,
            env.seq,
            ControlMessage::VaultHandoverReply {
                seq_in_reply_to: seq,
                unseal_share_b64: Some("fresh-share".into()),
                root_token: Some("fresh-token".into()),
            },
        )
        .await;
        true
    }

    /// ORDER 1562-bqcg. `Superseded` means the guest holds a NEWER handover
    /// (890-y72v: "the remedy is for the host to re-read, not re-deliver"), so
    /// the tray must go on to GetVaultHandover and store what it returns.
    /// Pre-fix: FAILS — the tray returned Err on any non-Accepted outcome
    /// BEFORE the handover, so after a reset that cleared the host credentials
    /// the first launch failed and Credential Manager never got the share back
    /// (v56.10.8.1 Windows smoke, 2026-10-08). Scratch targets only.
    #[tokio::test]
    async fn a_superseded_delivery_reads_the_guests_handover() {
        let run = Uuid::new_v4();
        let (uuid_t, share_t, token_t) = (
            format!("tillandsias-vm-uuid-test-{run}"),
            format!("vault-shamir-share-v1-test-{run}"),
            format!("vault-root-token-v1-test-{run}"),
        );
        let _c = (
            CredCleanup(uuid_t.clone()),
            CredCleanup(share_t.clone()),
            CredCleanup(token_t.clone()),
        );
        let targets = CredTargets {
            uuid: &uuid_t,
            share: &share_t,
            token: &token_t,
        };
        let (host, guest) = tokio::io::duplex(1 << 16);
        let guest = tokio::spawn(fake_guest(
            guest,
            tillandsias_control_wire::DeliverCredentialsOutcome::Superseded,
        ));
        let mut client = tillandsias_host_shell::vsock_client::Client::from_stream(
            Box::new(host),
            tillandsias_control_wire::transport::Transport::Vsock { cid: 0, port: 0 },
        );
        let result = deliver_and_handover_with(&mut client, &targets).await;
        drop(client);
        let asked = guest.await.unwrap();
        assert_eq!(result, Ok(()), "Superseded must not fail the delivery");
        assert!(asked, "Superseded must go on to GetVaultHandover");
        assert_eq!(
            read_credential_string(&share_t).unwrap().as_deref(),
            Some("fresh-share")
        );
        assert_eq!(
            read_credential_string(&token_t).unwrap().as_deref(),
            Some("fresh-token")
        );
    }

    /// ORDER 1562-bqcg, the fail-closed side: a REJECTED delivery is still an
    /// error and the handover is not trusted or written.
    #[tokio::test]
    async fn a_rejected_delivery_still_fails_closed() {
        let run = Uuid::new_v4();
        let (uuid_t, share_t, token_t) = (
            format!("tillandsias-vm-uuid-test-{run}"),
            format!("vault-shamir-share-v1-test-{run}"),
            format!("vault-root-token-v1-test-{run}"),
        );
        let _c = (
            CredCleanup(uuid_t.clone()),
            CredCleanup(share_t.clone()),
            CredCleanup(token_t.clone()),
        );
        let targets = CredTargets {
            uuid: &uuid_t,
            share: &share_t,
            token: &token_t,
        };
        let (host, guest) = tokio::io::duplex(1 << 16);
        let guest = tokio::spawn(fake_guest(
            guest,
            tillandsias_control_wire::DeliverCredentialsOutcome::Rejected {
                reason: "share does not open the store".into(),
            },
        ));
        let mut client = tillandsias_host_shell::vsock_client::Client::from_stream(
            Box::new(host),
            tillandsias_control_wire::transport::Transport::Vsock { cid: 0, port: 0 },
        );
        let result = deliver_and_handover_with(&mut client, &targets).await;
        drop(client);
        let asked = guest.await.unwrap();
        assert!(result.is_err(), "Rejected must fail closed");
        assert!(!asked, "a rejected delivery must not go on to the handover");
        assert_eq!(read_credential_string(&share_t).unwrap(), None);
    }

    /// The installation UUID is NOT a guest credential. It anchors the
    /// install and the in-VM Vault derives its master key from it, so a
    /// reset that took it would rotate the installation identity every time.
    /// The operator's 2026-08-17 manual repair preserved it deliberately;
    /// this pins that choice against a future "clear everything" edit.
    ///
    /// @trace order:803-49re
    #[test]
    fn clearing_guest_vault_credentials_never_touches_the_installation_uuid() {
        assert!(
            !GUEST_VAULT_TARGETS.contains(&TARGET_NAME),
            "tillandsias-vm-uuid must never be in the guest-wipe target list"
        );
        assert_eq!(
            GUEST_VAULT_TARGETS,
            [VAULT_SHARE_TARGET, VAULT_ROOT_TOKEN_TARGET],
            "the wipe clears exactly the two guest-vault credentials"
        );
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
