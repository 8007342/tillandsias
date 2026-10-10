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
    read_or_generate_in(KEYCHAIN_SERVICE)
}

fn read_or_generate_in(service: &str) -> std::io::Result<String> {
    if let Some(existing) = read_credential_string_in(service, KEYCHAIN_ACCOUNT)? {
        return Ok(existing);
    }
    let new = generate_uuid();
    write_credential_string_in(service, KEYCHAIN_ACCOUNT, &new)?;
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
    spawn_bounded("/usr/bin/security", args, SECURITY_CALL_BUDGET)
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

    // ORDER 1562-sbpd. Drain both pipes WHILE waiting. Reading them only after
    // the child exits deadlocks any child whose output exceeds a pipe buffer
    // (64 KiB): it blocks on write, never exits, and the bound below killed it
    // and blamed a locked keychain. Measured: `security dump-keychain` (~90 KB)
    // timed out every time through this helper and took well under a second to
    // a file.
    let drain = |pipe: Option<Box<dyn std::io::Read + Send>>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut p) = pipe {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        })
    };
    let stdout = drain(child.stdout.take().map(|p| Box::new(p) as _));
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as _));

    let deadline = Instant::now() + budget;
    loop {
        match child.try_wait()? {
            Some(status) => {
                // The child has exited, so its write ends are closed and both
                // readers finish (a grandchild still holding a pipe would be a
                // caller's own doing; none of the `security` calls fork).
                return Ok(std::process::Output {
                    status,
                    stdout: stdout.join().unwrap_or_default(),
                    stderr: stderr.join().unwrap_or_default(),
                });
            }
            None => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    // Reap, so the kill does not leave a zombie (690-w94k
                    // criterion 4 is the same lesson one call away). The
                    // readers end when the killed child's pipes close; they
                    // are not joined, so a straggler cannot hold this return.
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
    read_credential_string_in(KEYCHAIN_SERVICE, target)
}

fn read_credential_string_in(service: &str, target: &str) -> std::io::Result<Option<String>> {
    let output = security_bounded(&["find-generic-password", "-a", target, "-s", service, "-w"])?;
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
    write_credential_string_in(KEYCHAIN_SERVICE, target, value)
}

fn write_credential_string_in(service: &str, target: &str, value: &str) -> std::io::Result<()> {
    let status = security_bounded(&[
        "add-generic-password",
        "-a",
        target,
        "-s",
        service,
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
    delete_credential_string_in(KEYCHAIN_SERVICE, target)
}

fn delete_credential_string_in(service: &str, target: &str) -> std::io::Result<()> {
    let _status = security_bounded(&["delete-generic-password", "-a", target, "-s", service]);
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
    deliver_and_handover_in(client, KEYCHAIN_SERVICE).await
}

/// The delivery and handover against the Keychain service `service`.
/// Production passes [`KEYCHAIN_SERVICE`]; tests pass a scratch
/// `tillandsias-scratch-test-...` service they remove, so a test never reads or
/// writes the operator's real credentials (order 1562-bqcm).
pub(crate) async fn deliver_and_handover_in(
    client: &mut tillandsias_host_shell::vsock_client::Client,
    service: &str,
) -> Result<(), String> {
    let uuid =
        read_or_generate_in(service).map_err(|e| format!("read_or_generate UUID failed: {e}"))?;
    let share = read_credential_string_in(service, "vault-shamir-share-v1")
        .map_err(|e| format!("read share failed: {e}"))?;
    let token = read_credential_string_in(service, "vault-root-token-v1")
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

    capture_vault_handover_in(client, service).await.map(|_| ())
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
    capture_vault_handover_in(client, KEYCHAIN_SERVICE).await
}

async fn capture_vault_handover_in(
    client: &mut tillandsias_host_shell::vsock_client::Client,
    service: &str,
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
                write_credential_string_in(service, "vault-shamir-share-v1", &s)
                    .map_err(|e| format!("write share failed: {e}"))?;
                wrote = true;
            }
            if let Some(t) = root_token {
                write_credential_string_in(service, "vault-root-token-v1", &t)
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
    use super::{SECURITY_CALL_BUDGET, spawn_bounded};
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

    /// ORDER 1562-sbpd. Output larger than a pipe buffer must not hold the call
    /// past the child's own exit. Pre-fix the pipes were read only after exit,
    /// so this child blocked on write and the bound killed it as TimedOut.
    #[test]
    fn output_larger_than_a_pipe_buffer_is_returned_whole() {
        const BYTES: usize = 200 * 1024;
        let t0 = Instant::now();
        let out = spawn_bounded(
            "/bin/sh",
            &[
                "-c",
                "head -c 204800 /dev/zero; head -c 81920 /dev/zero >&2",
            ],
            Duration::from_secs(5),
        )
        .expect("a child that writes 200 KiB and exits must not be killed by the bound");
        assert!(out.status.success(), "{:?}", out.status);
        assert_eq!(
            out.stdout.len(),
            BYTES,
            "every stdout byte must be returned"
        );
        assert_eq!(
            out.stderr.len(),
            80 * 1024,
            "every stderr byte must be returned"
        );
        assert!(
            t0.elapsed() < Duration::from_secs(4),
            "the call must return when the child exits, not at the bound ({:?})",
            t0.elapsed()
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

    // ─── ORDER 1562-bqcm: the Superseded handover, driven end to end ──────

    /// Every scratch service starts with this, and the production service
    /// ([`KEYCHAIN_SERVICE`]) does not, so a sweep by this prefix cannot reach
    /// the operator's real `tillandsias` entries.
    const SCRATCH_SERVICE_PREFIX: &str = "tillandsias-scratch-test-";

    /// `tillandsias-scratch-test-<pid>-<uuid>`: the pid lets a later run tell
    /// a dead run's leftovers from a sibling test that is still running.
    fn scratch_service() -> String {
        format!(
            "{SCRATCH_SERVICE_PREFIX}{}-{}",
            std::process::id(),
            generate_uuid()
        )
    }

    /// Every (service, account) generic-password item whose service starts
    /// with the scratch prefix. `dump-keychain` without `-d` reads attributes
    /// only, never a secret, so it cannot raise a prompt for one.
    ///
    /// The dump goes to a FILE, not through `security_bounded`'s pipe: on this
    /// host it is ~90 KB, past a pipe buffer, and spawn_bounded reads the pipe
    /// only after the child exits — so the child blocks on a full pipe and the
    /// bound kills it every time. Bounded the same way: killed and reaped.
    fn scratch_items() -> Vec<(String, String)> {
        let path = std::env::temp_dir().join(format!(
            "tillandsias-scratch-dump-{}-{}",
            std::process::id(),
            generate_uuid()
        ));
        let file = std::fs::File::create(&path).expect("scratch dump file");
        let mut child = Command::new("/usr/bin/security")
            .arg("dump-keychain")
            .stdout(file)
            .stderr(Stdio::null())
            .spawn()
            .expect("security dump-keychain must spawn");
        let deadline = Instant::now() + SECURITY_CALL_BUDGET;
        while child.try_wait().expect("try_wait").is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&path);
                panic!(
                    "security dump-keychain exceeded {SECURITY_CALL_BUDGET:?} (locked keychain?)"
                );
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        let _ = std::fs::remove_file(&path);
        let quoted = |line: &str, key: &str| -> Option<String> {
            let rest = line.trim().strip_prefix(key)?;
            let v = rest.strip_prefix("<blob>=\"")?.strip_suffix('"')?;
            Some(v.to_string())
        };
        let mut items = Vec::new();
        let (mut svce, mut acct) = (None::<String>, None::<String>);
        let mut flush = |svce: &mut Option<String>, acct: &mut Option<String>| {
            if let (Some(s), Some(a)) = (svce.take(), acct.take())
                && s.starts_with(SCRATCH_SERVICE_PREFIX)
            {
                items.push((s, a));
            }
        };
        for line in text.lines() {
            if line.starts_with("keychain:") {
                flush(&mut svce, &mut acct);
            } else if let Some(v) = quoted(line, "\"svce\"") {
                svce = Some(v);
            } else if let Some(v) = quoted(line, "\"acct\"") {
                acct = Some(v);
            }
        }
        flush(&mut svce, &mut acct);
        items
    }

    fn pid_alive(pid: &str) -> bool {
        std::process::Command::new("/bin/ps")
            .args(["-p", pid])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(true)
    }

    /// Delete scratch items. `own` set: exactly that service's items. `own`
    /// unset: the items of every run that is no longer alive — the leftovers
    /// of a run killed before its cleanup ran (order 1562-uxhc: a Drop-only
    /// cleanup is not a cleanup when the process dies).
    fn sweep_scratch(own: Option<&str>) {
        for (service, account) in scratch_items() {
            let doomed = match own {
                Some(mine) => service == mine,
                None => {
                    let pid = service[SCRATCH_SERVICE_PREFIX.len()..]
                        .split('-')
                        .next()
                        .unwrap_or("");
                    pid.is_empty() || !pid.chars().all(|c| c.is_ascii_digit()) || !pid_alive(pid)
                }
            };
            if doomed {
                assert!(
                    service.starts_with(SCRATCH_SERVICE_PREFIX) && service != KEYCHAIN_SERVICE,
                    "refusing to delete a non-scratch keychain item: {service}"
                );
                let _ = delete_credential_string_in(&service, &account);
            }
        }
    }

    /// Before: sweep dead runs. After (Drop, so a failed assertion still
    /// cleans): sweep this test's own service.
    struct ScratchService(String);
    impl ScratchService {
        fn new() -> Self {
            sweep_scratch(None);
            Self(scratch_service())
        }
    }
    impl Drop for ScratchService {
        fn drop(&mut self) {
            sweep_scratch(Some(&self.0));
        }
    }

    /// The guest's side of deliver-then-handover. Answers DeliverCredentials
    /// with `outcome`; returns whether the tray went on to ask for the handover
    /// (and answers it with fresh credentials when it did).
    async fn fake_guest(
        io: tokio::io::DuplexStream,
        outcome: tillandsias_control_wire::DeliverCredentialsOutcome,
    ) -> bool {
        use futures_util::{SinkExt, StreamExt};
        use tillandsias_control_wire::{ControlEnvelope, ControlMessage, WIRE_VERSION};
        // The shared codec, not a hand-rolled length prefix (framing ratchet
        // 1527-v7cy): the fake speaks exactly what the real guest speaks.
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

    /// Runs the production delivery against `service` and a fake guest that
    /// answers `outcome`. Returns (result, whether the handover was asked for).
    async fn deliver_against_fake_guest(
        service: &str,
        outcome: tillandsias_control_wire::DeliverCredentialsOutcome,
    ) -> (Result<(), String>, bool) {
        let (host, guest) = tokio::io::duplex(1 << 16);
        let guest = tokio::spawn(fake_guest(guest, outcome));
        let mut client = tillandsias_host_shell::vsock_client::Client::from_stream(
            Box::new(host),
            tillandsias_control_wire::transport::Transport::Vsock { cid: 0, port: 0 },
        );
        let result = deliver_and_handover_in(&mut client, service).await;
        drop(client);
        (result, guest.await.unwrap())
    }

    /// ORDER 1562-bqcm (child of 1562-bqcg), the macOS twin of #255's Windows
    /// test. `Superseded` means the guest holds a NEWER handover (890-y72v), so
    /// the tray must go on to GetVaultHandover and write what it returns to the
    /// Keychain. Pre-fix (`is_accepted()`): FAILS — the tray returned Err
    /// before the handover, so after a reinstall cleared the host credentials
    /// the Keychain was never repopulated. Scratch Keychain service only.
    #[tokio::test]
    async fn a_superseded_delivery_repopulates_the_keychain_from_the_handover() {
        let scratch = ScratchService::new();
        assert_eq!(
            read_credential_string_in(&scratch.0, "vault-shamir-share-v1").unwrap(),
            None,
            "the scratch service starts empty, as a reinstalled host does"
        );
        let (result, asked) = deliver_against_fake_guest(
            &scratch.0,
            tillandsias_control_wire::DeliverCredentialsOutcome::Superseded,
        )
        .await;
        assert_eq!(result, Ok(()), "Superseded must not fail the delivery");
        assert!(asked, "Superseded must go on to GetVaultHandover");
        assert_eq!(
            read_credential_string_in(&scratch.0, "vault-shamir-share-v1")
                .unwrap()
                .as_deref(),
            Some("fresh-share"),
            "the handover's share must be written to the Keychain"
        );
        assert_eq!(
            read_credential_string_in(&scratch.0, "vault-root-token-v1")
                .unwrap()
                .as_deref(),
            Some("fresh-token"),
            "the handover's root token must be written to the Keychain"
        );
    }

    /// ORDER 1562-bqcm, the fail-closed side: a REJECTED delivery is still an
    /// error, and the handover is neither asked for nor written.
    #[tokio::test]
    async fn a_rejected_delivery_still_fails_closed_on_macos() {
        let scratch = ScratchService::new();
        let (result, asked) = deliver_against_fake_guest(
            &scratch.0,
            tillandsias_control_wire::DeliverCredentialsOutcome::Rejected {
                reason: "share does not open the store".into(),
            },
        )
        .await;
        assert!(result.is_err(), "Rejected must fail closed");
        assert!(!asked, "a rejected delivery must not go on to the handover");
        assert_eq!(
            read_credential_string_in(&scratch.0, "vault-shamir-share-v1").unwrap(),
            None
        );
    }

    /// The sweep's own guard: a scratch name can never equal, or be a prefix
    /// match for, the production service.
    #[test]
    fn the_scratch_prefix_cannot_reach_the_production_service() {
        assert!(!KEYCHAIN_SERVICE.starts_with(SCRATCH_SERVICE_PREFIX));
        assert!(scratch_service().starts_with(SCRATCH_SERVICE_PREFIX));
        assert_ne!(scratch_service(), KEYCHAIN_SERVICE);
    }
}
