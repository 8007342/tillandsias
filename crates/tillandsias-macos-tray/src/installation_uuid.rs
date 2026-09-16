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

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

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

/// How long a single `security` invocation may run before we stop waiting.
///
/// ORDER 690-w94k criterion 3. A LOCKED LOGIN KEYCHAIN IS THE CASE THIS EXISTS
/// FOR: `security` can block indefinitely there, and these calls sit on the
/// tray's 30s VmStatus path. Unbounded, one locked keychain stalls the status
/// surface for as long as the daemon lives.
///
/// 10s is chosen against the consumer, not the tool: the status path's own
/// budget is 30s, so a keychain read must fail well inside it and leave room
/// for the work that follows. A healthy `security` answers in milliseconds.
const SECURITY_CALL_BUDGET: Duration = Duration::from_secs(10);

/// Run `security` with the arguments given, bounded by [`SECURITY_CALL_BUDGET`].
///
/// WHY THIS IS NOT `Command::output()`. `output()` waits forever. The three
/// call sites below are reached from async paths (see
/// `deliver_credentials_and_check_handover`), and this function keeps the SYNC
/// signature its 34 callers already use — bounding the subprocess here costs no
/// caller a change, where converting the signatures to async would touch all of
/// them. Off-the-worker is handled separately at the async boundary.
///
/// KILLED MEANS KILLED: on expiry the child is killed AND reaped, so a hung
/// `security` cannot outlive the call and become one of the zombies criterion 4
/// just removed from this crate.
///
/// PIPE-BUFFER CAVEAT, stated because it is a real limit of this shape: stdout
/// is read only after the child exits, so a child that fills the pipe buffer
/// would block instead of finishing. These calls return a UUID or a short
/// error — kilobytes below any pipe limit — so it does not arise here. It
/// would if this helper were reused for a chatty command.
fn security_bounded(args: &[&str]) -> std::io::Result<std::process::Output> {
    spawn_bounded("security", args, SECURITY_CALL_BUDGET)
}

/// The bounded spawn itself, with the program and budget as parameters so a
/// test can drive it with a stand-in that hangs on demand. `security` cannot
/// be made to block deterministically in a unit test; `/bin/sleep` can, and
/// the property under test — the child does not outlive the bound — is the
/// same one either way.
fn spawn_bounded(
    program: &str,
    args: &[&str],
    budget: Duration,
) -> std::io::Result<std::process::Output> {
    let mut child = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let deadline = Instant::now() + budget;
    loop {
        match child.try_wait()? {
            Some(_) => return child.wait_with_output(),
            None => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    // Reap, so the kill does not leave a zombie (690-w94k
                    // criterion 4 is the same lesson one call away).
                    let _ = child.wait();
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        format!(
                            "`{} {}` exceeded {}s and was killed — a LOCKED LOGIN \
                             KEYCHAIN is the usual cause, and the tray's 30s status path \
                             must not wait on it (order 690-w94k)",
                            program,
                            args.first().copied().unwrap_or("?"),
                            budget.as_secs()
                        ),
                    ));
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }
}

/// Read a generic string credential stored under `target` from the macOS keychain.
pub fn read_credential_string(target: &str) -> std::io::Result<Option<String>> {
    let output = security_bounded(&[
        "find-generic-password",
        "-a",
        target,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
    ])?;
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
    let status = security_bounded(&[
        "add-generic-password",
        "-a",
        target,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
        value,
        "-U",
    ])?
    .status;
    if !status.success() {
        return Err(std::io::Error::other(format!(
            "security add-generic-password exited {status}"
        )));
    }
    Ok(())
}

/// Remove the credential stored under `target` from the macOS keychain.
pub fn delete_credential_string(target: &str) -> std::io::Result<()> {
    let _status = security_bounded(&[
        "delete-generic-password",
        "-a",
        target,
        "-s",
        KEYCHAIN_SERVICE,
    ]);
    // Already-absent, successfully deleted, and a bound that fired are all Ok
    // for idempotency — the caller is removing a credential and any of those
    // leaves it removed or absent. The bound still did its job: the child was
    // killed and reaped rather than left holding a prompt.
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
            if !outcome.is_accepted() {
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

    capture_vault_handover(client).await.map(|_| ())
}

/// The CAPTURE half of the handover, without the deliver half (701-g98y).
///
/// Split out because the two halves are needed independently and delivering
/// when you only meant to capture is actively harmful. A CLI one-shot
/// (`--github-login`) creates a NEW Vault epoch inside the guest; the host
/// Keychain still holds the PREVIOUS one. If such a caller used
/// `deliver_credentials_and_check_handover`, it would push the stale Keychain
/// values into the guest FIRST — overwriting the epoch it just created — and
/// only then ask for a handover that is no longer pending.
///
/// So: a caller that has just caused a new epoch calls THIS. A caller that is
/// re-attaching to an existing guest and needs to seed it calls the full
/// deliver-then-capture above.
///
/// Returns whether anything was actually written. A guest only holds a PENDING
/// handover after a FRESH Vault init — a login that reuses an already
/// initialized Vault legitimately has nothing to hand over. Callers must be able
/// to tell those apart: reporting "Keychain updated" when the reply was empty is
/// a success claim with no evidence behind it, which is exactly the failure this
/// codebase keeps being bitten by. (Observed: the first version of this call
/// site printed "host Keychain updated" on a run where both fingerprints were
/// provably unchanged.)
pub async fn capture_vault_handover(
    client: &mut tillandsias_host_shell::vsock_client::Client,
) -> Result<bool, String> {
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
            let mut wrote = false;
            if let Some(s) = unseal_share_b64 {
                write_credential_string("vault-shamir-share-v1", &s)
                    .map_err(|e| format!("write share failed: {e}"))?;
                wrote = true;
            }
            if let Some(t) = root_token {
                write_credential_string("vault-root-token-v1", &t)
                    .map_err(|e| format!("write token failed: {e}"))?;
                wrote = true;
            }
            Ok(wrote)
        }
        tillandsias_control_wire::ControlMessage::Error { message, .. } => {
            Err(format!("GetVaultHandover failed: {message}"))
        }
        other => Err(format!("unexpected reply to GetVaultHandover: {other:?}")),
    }
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
    use super::{spawn_bounded, SECURITY_CALL_BUDGET};
    use std::time::{Duration, Instant};

    /// Count live processes whose PARENT is us and whose command matches.
    ///
    /// ppid-anchored, never a bare `grep <name>`: macneo's count of exactly this
    /// shape was wrong this morning because the grep matched ITS OWN command
    /// line. Filtering on our pid removes that and also removes the operator's
    /// unrelated processes.
    fn live_children_matching(needle: &str) -> usize {
        let me = std::process::id().to_string();
        let out = std::process::Command::new("/bin/ps")
            .args(["-Ao", "pid,ppid,command"])
            .output()
            .expect("ps must run; without it this test measures nothing");
        String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| l.contains(needle))
            .filter_map(|l| l.split_whitespace().nth(1).map(|p| p.to_string()))
            .filter(|ppid| *ppid == me)
            .count()
    }

    /// ORDER 690-w94k criterion 3 — THE BOUND MUST KILL, NOT JUST RETURN.
    ///
    /// WHY THIS ASSERTS ON THE PROCESS TABLE AND NOT ON ELAPSED TIME. macneo
    /// measured the failure this guards against on a macOS host this week: a
    /// timeout killed the PARENT, the `security` grandchild survived at PPID 1
    /// still holding an undismissable GUI prompt, one accumulated per call, and
    /// a SecurityAgent stayed alive 21h45m ignoring SIGTERM until the host was
    /// restarted. A test that only checked "the call returned inside the budget"
    /// passes on exactly that outcome — the caller IS unblocked, and the host is
    /// left worse than if it had stalled.
    ///
    /// Our case is better by construction: this crate spawns `security` itself
    /// and owns the handle, so there is no intermediate parent to kill instead.
    /// That is the thing being asserted rather than assumed.
    ///
    /// /bin/sleep stands in because `security` cannot be made to block
    /// deterministically in a unit test. The property is identical: a child that
    /// outruns its budget must be dead and reaped when the call returns.
    #[test]
    fn a_bound_that_fires_leaves_no_surviving_child() {
        let before = live_children_matching("/bin/sleep");

        let t0 = Instant::now();
        let err = spawn_bounded("/bin/sleep", &["30"], Duration::from_millis(300))
            .expect_err("a 30s sleep under a 300ms budget must not succeed");
        let elapsed = t0.elapsed();

        assert_eq!(
            err.kind(),
            std::io::ErrorKind::TimedOut,
            "the bound must report TimedOut, not a generic failure: {err}"
        );
        assert!(
            elapsed < Duration::from_secs(5),
            "the call must return near its budget, not near the child's lifetime \
             (took {elapsed:?})"
        );

        // THE ASSERTION THAT MATTERS. Poll briefly: kill+reap is not instant,
        // and a fixed sleep here would be a race rather than a measurement.
        let mut survivors = usize::MAX;
        for _ in 0..40 {
            std::thread::sleep(Duration::from_millis(25));
            survivors = live_children_matching("/bin/sleep").saturating_sub(before);
            if survivors == 0 {
                break;
            }
        }
        assert_eq!(
            survivors, 0,
            "the bound returned but left {survivors} child(ren) alive. That is the \
             21h45m failure macneo measured: the caller is unblocked and the host \
             keeps a process holding a prompt (order 690-w94k)"
        );
    }

    /// The budget is sized against its CONSUMER, and that relationship is the
    /// reason for the number. If the tray's status path budget ever drops below
    /// this, a keychain call could eat the whole thing and this pin should fail
    /// rather than let the ordering invert silently.
    #[test]
    fn the_security_budget_fits_inside_the_status_path_budget() {
        assert!(
            SECURITY_CALL_BUDGET < Duration::from_secs(30),
            "a keychain call must fail well inside the 30s status path, leaving \
             room for the work that follows (order 690-w94k)"
        );
    }

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
