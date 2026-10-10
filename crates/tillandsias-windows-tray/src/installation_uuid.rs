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
//! persistence is proven by the OPT-IN test at the bottom of this file, which runs
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
    store::read(target)
}

/// Persist a generic string credential `value` under `target` in Windows Credential Manager.
pub fn write_credential_string(target: &str, value: &str) -> Result<(), String> {
    store::write(target, value)
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
/// so this is safe to call on uninstall or key rotation. The eventual step-36
/// keychain rotation / uninstall flow can reuse it.
pub fn delete_installation_uuid_for(target: &str) -> Result<(), String> {
    store::delete(target)
}

// ORDER 1562-uxhc — THE STORE SEAM. Every read, write and delete above goes
// through `store`, which is the real Credential Manager in the product and an
// in-memory scratch store in the test build. The tests used to write the real
// store under `...-test-<uuid>` targets and remove them in a Drop guard, and a
// Drop guard never runs when the test process is killed, times out or aborts:
// three such targets leaked into yolanda's real store (v56.10.8.1 Windows
// smoke, 2026-10-08). A scratch store cannot leak, whatever ends the process.
#[cfg(test)]
use scratch as store;
#[cfg(not(test))]
use win32 as store;

/// The real Windows Credential Manager. In the test build every entry point
/// first asks [`real_store_guard`], which refuses (panics) unless the calling
/// thread opted in through `RealStoreOptIn` AND the target is a `-test-` one,
/// so a test can neither write the real store by accident nor touch a
/// production target on purpose.
mod win32 {
    use super::*;

    pub(super) fn read(target: &str) -> Result<Option<String>, String> {
        #[cfg(test)]
        real_store_guard("read", target);
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

    pub(super) fn write(target: &str, value: &str) -> Result<(), String> {
        #[cfg(test)]
        real_store_guard("write", target);
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

    pub(super) fn delete(target: &str) -> Result<(), String> {
        #[cfg(test)]
        real_store_guard("delete", target);
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

    /// The names of the generic credentials matching `filter` (Credential
    /// Manager's own syntax: a trailing `*` is the only wildcard). Only the
    /// opt-in round trip uses it, to find what earlier aborted runs left.
    #[cfg(test)]
    pub(super) fn list(filter: &str) -> Result<Vec<String>, String> {
        real_store_guard("list", filter);
        let filter_w = to_pwstr(filter);
        let mut count = 0u32;
        let mut creds = std::ptr::null_mut::<*mut CREDENTIALW>();
        let result = unsafe {
            windows::Win32::Security::Credentials::CredEnumerateW(
                PCWSTR(filter_w.as_ptr()),
                windows::Win32::Security::Credentials::CRED_ENUMERATE_FLAGS(0),
                &mut count,
                &mut creds,
            )
        };
        if let Err(err) = result {
            if err.code().0 as u32 == HRESULT_ERROR_NOT_FOUND {
                return Ok(Vec::new());
            }
            return Err(format!("CredEnumerateW failed for {filter}: {err:?}"));
        }
        let mut names = Vec::new();
        for i in 0..count as usize {
            let cred = unsafe { &**creds.add(i) };
            if let Ok(name) = unsafe { cred.TargetName.to_string() } {
                names.push(name);
            }
        }
        unsafe {
            CredFree(creds as *mut _);
        }
        Ok(names)
    }
}

#[cfg(test)]
thread_local! {
    /// Set only by `RealStoreOptIn`, on the thread of the one opt-in test.
    static REAL_STORE_OPT_IN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The guard. A test reaching the real store outside the opt-in, or naming a
/// target without `-test-` in it even inside the opt-in, panics: an `Err`
/// could be swallowed by a `let _ =`, a panic fails the test.
#[cfg(test)]
fn real_store_guard(op: &str, target: &str) {
    let opted_in = REAL_STORE_OPT_IN.with(|c| c.get());
    if !opted_in || !target.contains("-test-") {
        panic!(
            "refused:real-credential-store-in-test:{op}:{target} — tests use the scratch store; \
             only the opt-in round trip may reach the real Credential Manager, and only for \
             -test- targets (order 1562-uxhc)"
        );
    }
}

/// The scratch store the test build uses: per thread, so every test starts
/// empty and no two tests see each other, and in memory, so nothing outlives
/// the process however it ends. Same contract as the real store: a missing
/// target reads `None`, a delete of one is success, values come back trimmed.
#[cfg(test)]
mod scratch {
    use std::cell::RefCell;
    use std::collections::HashMap;

    thread_local! {
        static STORE: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
    }

    pub(super) fn read(target: &str) -> Result<Option<String>, String> {
        Ok(STORE.with(|s| s.borrow().get(target).map(|v| v.trim().to_string())))
    }

    pub(super) fn write(target: &str, value: &str) -> Result<(), String> {
        STORE.with(|s| s.borrow_mut().insert(target.to_string(), value.to_string()));
        Ok(())
    }

    pub(super) fn delete(target: &str) -> Result<(), String> {
        STORE.with(|s| s.borrow_mut().remove(target));
        Ok(())
    }
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

    // ORDER 1562-uxhc: every test here runs against the scratch store (see
    // `store`), so none needs a cleanup guard and none can leak a credential
    // into the real Credential Manager, however the test process ends.

    /// 803-49re, the half that decides the bug: a host-side share that
    /// survives a guest wipe is delivered into the fresh guest unconditionally
    /// and permanently breaks GitHub login. The wipe must clear it.
    ///
    /// Exercised on the scratch store and unique throwaway targets — never the public
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
    /// (v56.10.8.1 Windows smoke, 2026-10-08). Runs on the scratch store.
    #[tokio::test]
    async fn a_superseded_delivery_reads_the_guests_handover() {
        let run = Uuid::new_v4();
        let (uuid_t, share_t, token_t) = (
            format!("tillandsias-vm-uuid-test-{run}"),
            format!("vault-shamir-share-v1-test-{run}"),
            format!("vault-root-token-v1-test-{run}"),
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

    /// The store contract every caller relies on, pinned on the seam the
    /// tests run against: absent reads `None`, a later read sees an earlier
    /// write, an overwrite replaces, a delete clears and is idempotent. The
    /// same contract against the REAL store is
    /// `credential_manager_persists_uuid_across_calls`, which is opt-in.
    #[test]
    fn the_store_round_trips_a_uuid() {
        let target = format!("tillandsias-vm-uuid-test-{}", Uuid::new_v4());
        assert_eq!(read_installation_uuid_from(&target).unwrap(), None);
        let first = Uuid::new_v4();
        write_installation_uuid_to(&target, first).unwrap();
        assert_eq!(read_installation_uuid_from(&target).unwrap(), Some(first));
        let second = Uuid::new_v4();
        write_installation_uuid_to(&target, second).unwrap();
        assert_eq!(read_installation_uuid_from(&target).unwrap(), Some(second));
        delete_installation_uuid_for(&target).unwrap();
        assert_eq!(read_installation_uuid_from(&target).unwrap(), None);
        delete_installation_uuid_for(&target).unwrap();
    }

    /// The panic message of `f`, or `None` when it returned normally.
    fn refusal_of<R>(f: impl FnOnce() -> R + std::panic::UnwindSafe) -> Option<String> {
        let err = std::panic::catch_unwind(f).err()?;
        err.downcast_ref::<String>()
            .cloned()
            .or_else(|| err.downcast_ref::<&str>().map(|s| s.to_string()))
    }

    /// ORDER 1562-uxhc, the guard. A test that reaches the REAL Credential
    /// Manager outside the opt-in is refused before any Win32 call, and inside
    /// the opt-in a production target still is. Pre-fix: four tests wrote the
    /// real store and nothing refused them.
    ///
    /// The write arm names a `-test-` target, so a broken guard would leave a
    /// scratch-named credential behind, never clobber a real one; the
    /// production-target arm only READS.
    #[test]
    fn a_test_reaching_the_real_store_is_refused() {
        let probe = format!("tillandsias-guard-probe-test-{}", Uuid::new_v4());
        for (op, msg) in [
            (
                "write",
                refusal_of(|| win32::write(&probe, "must-not-land")),
            ),
            ("read", refusal_of(|| win32::read(&probe))),
            ("delete", refusal_of(|| win32::delete(&probe))),
        ] {
            let msg = msg.unwrap_or_else(|| panic!("the real-store {op} was NOT refused"));
            assert!(
                msg.starts_with(&format!("refused:real-credential-store-in-test:{op}:")),
                "unexpected refusal for {op}: {msg}"
            );
        }
        // Opted in, a production target is still refused.
        let _opt_in = RealStoreOptIn::enter();
        let msg = refusal_of(|| win32::read(TARGET_NAME))
            .expect("the opt-in must not open production targets");
        assert!(msg.contains(&format!(":read:{TARGET_NAME} ")), "{msg}");
    }

    /// ORDER 1562-uxhc, the guard's static half: the runtime guard sits in
    /// `mod win32`, so a Win32 credential call anywhere else (a test calling
    /// CredWriteW directly) would bypass it. Every such call in the crate's
    /// sources must sit inside `mod win32`. Comments are stripped before the
    /// scan, and the needles are assembled so this test cannot match itself.
    #[test]
    fn win32_credential_calls_live_only_behind_the_guard() {
        let needles: Vec<String> = ["Write", "Read", "Delete", "Enumerate"]
            .iter()
            .map(|op| format!("Cred{op}W("))
            .collect();
        let code = |src: &str| -> Vec<String> {
            src.lines()
                .map(|l| l.split("//").next().unwrap_or("").to_string())
                .collect()
        };
        let others = [
            ("main.rs", include_str!("main.rs")),
            ("notify_icon.rs", include_str!("notify_icon.rs")),
            ("wsl_lifecycle.rs", include_str!("wsl_lifecycle.rs")),
            ("eventlog.rs", include_str!("eventlog.rs")),
            ("hvsocket.rs", include_str!("hvsocket.rs")),
            ("provision_console.rs", include_str!("provision_console.rs")),
            ("tray_phase_icon.rs", include_str!("tray_phase_icon.rs")),
            ("tray_registry.rs", include_str!("tray_registry.rs")),
            ("wsl_probe_policy.rs", include_str!("wsl_probe_policy.rs")),
        ];
        let mut offenders = Vec::new();
        for (name, src) in others {
            for (i, line) in code(src).iter().enumerate() {
                if needles.iter().any(|n| line.contains(n.as_str())) {
                    offenders.push(format!("{name}:{}", i + 1));
                }
            }
        }
        let own = code(include_str!("installation_uuid.rs"));
        let start = own
            .iter()
            .position(|l| l.trim_end() == "mod win32 {")
            .expect("mod win32 is where the guarded calls live");
        let end = start
            + own[start..]
                .iter()
                .position(|l| l.trim_end() == "}")
                .expect("mod win32 closes at column 0");
        let mut inside = 0;
        for (i, line) in own.iter().enumerate() {
            if needles.iter().any(|n| line.contains(n.as_str())) {
                if i > start && i < end {
                    inside += 1;
                } else {
                    offenders.push(format!("installation_uuid.rs:{}", i + 1));
                }
            }
        }
        assert!(
            offenders.is_empty(),
            "unguarded Win32 credential calls: {offenders:?}"
        );
        // Cardinality, so a scan that sees nothing cannot pass: read, write,
        // delete and the opt-in's enumerate.
        assert_eq!(
            inside, 4,
            "expected exactly the 4 guarded calls in mod win32"
        );
    }

    /// Opens the real store to the current thread for as long as it lives.
    struct RealStoreOptIn;
    impl RealStoreOptIn {
        fn enter() -> Self {
            REAL_STORE_OPT_IN.with(|c| c.set(true));
            RealStoreOptIn
        }
    }
    impl Drop for RealStoreOptIn {
        fn drop(&mut self) {
            REAL_STORE_OPT_IN.with(|c| c.set(false));
        }
    }

    /// The prefixes of every scratch target a test of this file has ever used
    /// against the real store. All of them carry `-test-`.
    const STALE_TEST_PREFIXES: [&str; 3] = [
        "tillandsias-vm-uuid-test-",
        "vault-shamir-share-v1-test-",
        "vault-root-token-v1-test-",
    ];

    /// Removes the `-test-` targets earlier aborted runs left in the REAL
    /// store, by name, and returns them. Never anything else: the enumeration
    /// is by prefix, and each name is checked again for the prefix AND for
    /// `-test-` before it is deleted.
    fn remove_stale_test_targets() -> Vec<String> {
        let mut removed = Vec::new();
        for prefix in STALE_TEST_PREFIXES {
            for name in win32::list(&format!("{prefix}*")).unwrap() {
                if name.starts_with(prefix) && name.contains("-test-") {
                    win32::delete(&name).unwrap();
                    removed.push(name);
                }
            }
        }
        removed
    }

    /// Round-trip proof against the *real* Windows Credential Manager: a value
    /// written in one call is read back by a separate later call (persisting
    /// across calls is the in-process proxy for persisting across process
    /// runs), an overwrite replaces it, and delete clears it.
    ///
    /// OPT-IN (order 1562-uxhc): it writes the real store, so it is
    /// `#[ignore]`d AND needs TILLANDSIAS_REAL_CREDENTIAL_STORE_TEST=1. A
    /// person runs it deliberately:
    ///   TILLANDSIAS_REAL_CREDENTIAL_STORE_TEST=1 cargo test -p tillandsias-windows-tray \
    ///     credential_manager_persists_uuid_across_calls -- --ignored
    /// It first removes, by name, the `-test-` targets earlier aborted runs
    /// left behind (see `remove_stale_test_targets`), and removes its own
    /// before asserting anything about the result. It lives here rather than
    /// in tests/ because this crate is a binary with no library target.
    ///
    /// @trace spec:tillandsias-vault, spec:windows-native-tray
    #[test]
    #[ignore = "writes the real Credential Manager; opt-in, see the doc comment"]
    fn credential_manager_persists_uuid_across_calls() {
        if std::env::var("TILLANDSIAS_REAL_CREDENTIAL_STORE_TEST").as_deref() != Ok("1") {
            eprintln!("skip:real-credential-store:TILLANDSIAS_REAL_CREDENTIAL_STORE_TEST is not 1");
            return;
        }
        let _opt_in = RealStoreOptIn::enter();
        for name in remove_stale_test_targets() {
            eprintln!("removed stale test target: {name}");
        }
        let target = format!("tillandsias-vm-uuid-test-{}", Uuid::new_v4());
        let read =
            |t: &str| win32::read(t).map(|v| v.map(|s| Uuid::parse_str(&s).expect("a UUID")));

        let absent = read(&target).unwrap();
        let first = Uuid::new_v4();
        win32::write(&target, &first.to_string()).unwrap();
        let after_first = read(&target).unwrap();
        let second = Uuid::new_v4();
        win32::write(&target, &second.to_string()).unwrap();
        let after_second = read(&target).unwrap();
        win32::delete(&target).unwrap();
        let after_delete = read(&target).unwrap();
        win32::delete(&target).unwrap();

        assert_eq!(absent, None, "fresh target should have no credential yet");
        assert_eq!(
            after_first,
            Some(first),
            "a later call must read the earlier write"
        );
        assert_eq!(
            after_second,
            Some(second),
            "overwrite must replace the stored value"
        );
        assert_eq!(after_delete, None, "delete must remove the credential");
    }
}
