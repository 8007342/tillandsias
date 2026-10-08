// @trace spec:tillandsias-vault
// @cheatsheet runtime/hashicorp-vault-tillandsias.md
//
//! Vault bootstrap path — Phase 6 promotes Vault to the default Linux secrets
//! backend.
//!
//! On Linux this short-circuits the in-VM lifecycle (Phase 4/5 work) and runs
//! the vault container directly under host-rootless podman, treating the host
//! as the "VM" for the POC. The host generates a per-installation UUID, reads
//! `/etc/machine-id`, derives the unseal key via HKDF, pushes it as a podman
//! secret, then launches the vault container. After healthcheck, the four
//! built-in policies are loaded, the AppRole backend is enabled, and per-kind
//! roles (`git-mirror`, `forge`, `tray`, `inference`) are provisioned.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

#[cfg(feature = "vault")]
use keyring::Entry;

use tillandsias_control_wire::DeliverCredentialsOutcome;
use tillandsias_podman::{PodmanClient, podman_cmd_sync};
use tillandsias_vault_client::{HealthStatus, Policy, VaultClient, VaultError, auto_unseal};
use zeroize::Zeroize;

const VAULT_CONTAINER_NAME: &str = "tillandsias-vault";

const VAULT_UNSEAL_SECRET: &str = "tillandsias-vault-unseal";
const VAULT_TLS_CERT_SECRET: &str = "tillandsias-vault-tls-cert";
const VAULT_TLS_KEY_SECRET: &str = "tillandsias-vault-tls-key";
const VAULT_TLS_CA_SECRET: &str = "tillandsias-vault-tls-ca";
const VAULT_NETWORK_ALIAS: &str = "vault";
const VAULT_API_BASE_URL_ENV: &str = "TILLANDSIAS_VAULT_API_BASE_URL";
// Native rootless Linux cannot resolve the enclave network alias or directly
// route to the bridge. It remains the one named consumer of this compatibility
// publish; in-VM headless launches never publish Vault to the host namespace.
pub const VAULT_HOST_PORT: u16 = 8201;

/// Keychain service name for Tillandsias.
const KEYCHAIN_SERVICE: &str = "tillandsias";
/// Keychain user for the versioned Shamir unseal share.
const VAULT_SHAMIR_SHARE_V1: &str = "vault-shamir-share-v1";
/// Keychain user for the installation anchor (UUID).
const INSTALL_ANCHOR_V1: &str = "installation-uuid-v1";

#[cfg(feature = "vault")]
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct InVmCredentials {
    pub unseal_share_b64: Option<String>,
    pub installation_uuid: String,
    pub root_token: Option<String>,
}

#[cfg(feature = "vault")]
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct PendingHandover {
    pub unseal_share_b64: Option<String>,
    pub root_token: Option<String>,
}

#[cfg(feature = "vault")]
pub static IN_VM_CREDENTIALS: OnceLock<Mutex<Option<InVmCredentials>>> = OnceLock::new();
#[cfg(feature = "vault")]
#[allow(dead_code)]
pub static PENDING_HANDOVER: OnceLock<Mutex<Option<PendingHandover>>> = OnceLock::new();

/// ORDER 1200-ih38. What can be known about a delivered share WITHOUT a live
/// vault, decided before anything is stored or persisted.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DeliveredShareCheck {
    /// The delivery carried no share (token-only): nothing to check.
    NoShare,
    /// Not base64, or not exactly 32 key bytes. `ensure_unseal_key` would
    /// silently skip it and fall through to the fallback file or a derived
    /// dummy key, so adopting it only puts a useless share on disk.
    Malformed(String),
    /// Well-formed, but different from this guest's own
    /// `tillandsias-vault-unseal` podman secret. NOT A REJECTION (1200-ih38
    /// review): the podman secret is a STAND-IN for the vault, and in the
    /// documented dummy-key state it is the wrong one, so refusing on it would
    /// manufacture a rejection (888-miiy); and refusing skipped the fallback
    /// write that keeps has_shamir_share_in_keyring true, so a guest with a
    /// missing share file would WIPE vault-data on its next launch. The share is
    /// therefore stored exactly as before; rejecting on LIVE evidence (the vault
    /// observed unsealed with the own secret) is a follow-up row.
    DiffersFromOwnSecret,
    /// Well-formed and byte-identical to the guest's own secret.
    MatchesOwnSecret,
    /// Well-formed, and the guest has no readable own secret to compare
    /// against (first boot before init, or podman unavailable). NOT a
    /// rejection: "could not check" is not "checked and refused" (888-miiy).
    Unverifiable,
}

/// Pure decision, so every branch is testable without podman or a cache dir.
pub(crate) fn check_delivered_share(
    delivered_b64: Option<&str>,
    own_secret: Option<&[u8]>,
) -> DeliveredShareCheck {
    use base64::Engine;
    let Some(encoded) = delivered_b64.map(str::trim).filter(|s| !s.is_empty()) else {
        return DeliveredShareCheck::NoShare;
    };
    let bytes = match base64::engine::general_purpose::STANDARD.decode(encoded) {
        Ok(b) => b,
        // no decoder error text: it names the offending byte and offset, which
        // would reach tracing::warn! with the reason (1200-ih38 review)
        Err(_) => return DeliveredShareCheck::Malformed("not base64".to_string()),
    };
    let mut bytes = bytes;
    let verdict = if bytes.len() != 32 {
        DeliveredShareCheck::Malformed(format!(
            "decodes to {} bytes, a share is exactly 32",
            bytes.len()
        ))
    } else {
        match own_secret {
            Some(own) if own == bytes.as_slice() => DeliveredShareCheck::MatchesOwnSecret,
            Some(_) => DeliveredShareCheck::DiffersFromOwnSecret,
            None => DeliveredShareCheck::Unverifiable,
        }
    };
    bytes.zeroize();
    verdict
}

// The guest's own unseal secret, for the delivery check. Production reads the
// podman secret (bounded; does not need the vault running, so delivery never
// waits on vault startup). Tests get a hermetic override that defaults to
// "unavailable", so no test ever reads the host's real secret.
#[cfg(test)]
thread_local! {
    pub(crate) static TEST_OWN_UNSEAL_SECRET: std::cell::RefCell<Option<Vec<u8>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(feature = "vault")]
fn own_unseal_secret_for_delivery_check() -> Option<Vec<u8>> {
    #[cfg(test)]
    {
        TEST_OWN_UNSEAL_SECRET.with(|s| s.borrow().clone())
    }
    #[cfg(not(test))]
    {
        read_unseal_secret_bytes()
    }
}

#[cfg(feature = "vault")]
#[allow(dead_code)]
/// ORDER 890-y72v. Returns WHAT HAPPENED, where this used to return unit.
///
/// The unit return was the whole defect at this end: every path through this
/// function looked identical to its caller, so `vsock_server` had nothing to
/// build a reply from and hardcoded `success: true`. Two of those paths are
/// not success. The early return below drops the delivery on the floor, and a
/// failed fallback write leaves the guest without the share it was just told
/// it had.
///
/// `Accepted` here means STORED AND PERSISTED — in memory, and to the fallback
/// file when a cache dir exists — AND (1200-ih38) the share is a well-formed
/// 32-byte key; a malformed share is REJECTED BEFORE anything is stored. A
/// well-formed share that differs from this guest's own unseal secret is still
/// stored (see DiffersFromOwnSecret: refusing it could wipe vault-data), so
/// Accepted does NOT claim the share opens the vault; the live verdict is
/// 1400-b7h4's.
pub fn set_in_vm_credentials(
    unseal_share_b64: Option<String>,
    installation_uuid: String,
    root_token: Option<String>,
) -> DeliverCredentialsOutcome {
    // If we have a pending fresh handover, the VM's state is strictly newer than
    // whatever the host tray just delivered. Ignore the stale delivery to prevent
    // clobbering the fresh token in memory and the fallback file.
    //
    // 890-y72v: this return is CORRECT and was SILENT. The host was told
    // success=true for a delivery this guest deliberately discarded, so a tray
    // that delivered a stale share saw the same answer as one that delivered a
    // working one. `Superseded` says the host's copy is stale without implying
    // anything is broken.
    if get_pending_handover().1.is_some() {
        return DeliverCredentialsOutcome::Superseded;
    }

    // 1200-ih38: VALIDATE BEFORE PERSIST, using only what needs no live vault.
    // A rejection here stores nothing — neither in memory (ensure_unseal_key
    // tries the delivered share FIRST) nor on disk.
    let own = if unseal_share_b64.is_some() {
        own_unseal_secret_for_delivery_check()
    } else {
        None
    };
    let mut own = own;
    let check = check_delivered_share(unseal_share_b64.as_deref(), own.as_deref());
    if let Some(o) = own.as_mut() {
        o.zeroize();
    }
    match check {
        // A malformed share never kept a vault alive either: the wipe
        // predicate (has_shamir_share_in_keyring) only counts a file that
        // decodes to exactly 32 bytes, so refusing it opens no wipe path.
        DeliveredShareCheck::Malformed(why) => {
            return DeliverCredentialsOutcome::Rejected {
                reason: format!("malformed unseal share: {why}; not stored"),
            };
        }
        DeliveredShareCheck::DiffersFromOwnSecret => {
            eprintln!(
                "[tillandsias-vault] delivered unseal share differs from this guest's own \
                 unseal secret; kept UNVERIFIED (no live evidence at delivery; 1400-b7h4)"
            );
        }
        DeliveredShareCheck::NoShare
        | DeliveredShareCheck::MatchesOwnSecret
        | DeliveredShareCheck::Unverifiable => {}
    }

    let share_for_disk = unseal_share_b64.clone();
    let cell = IN_VM_CREDENTIALS.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cell.lock() {
        *guard = Some(InVmCredentials {
            unseal_share_b64,
            installation_uuid,
            root_token: root_token.clone(),
        });
    }

    // 701-se6x: persist BOTH, not just the token. This function used to write
    // `fallback_vault-root-token-v1` and drop the delivered share on the floor —
    // the identical asymmetry 694-mhz8 fixed at the fresh-init site, surviving
    // here. It matters because `has_shamir_share_in_keyring` (the predicate the
    // partial-init WIPE turns on) consults an OS keychain, absent in this guest,
    // and then this file. So a guest that had lost only its share file would be
    // handed a perfectly good share by the host, use it in memory, still fail
    // the predicate, and have its intact Vault wiped on the next launch — the
    // host had the evidence and the guest threw it away.
    // 701-se6x criterion 2: surface a failed write instead of discarding it.
    // The `Err` arm of init_cache_dir was silent too — same consequence, since
    // no cache dir means no share file either.
    match crate::init_cache_dir() {
        Ok(cache_dir) => {
            if let Err(e) = write_vm_credential_fallbacks(
                &cache_dir,
                root_token.as_deref(),
                share_for_disk.as_deref(),
            ) {
                report_fallback_write_failure("host delivery into the guest", &e.to_string());
                // 890-y72v: the in-memory copy survives this process and the
                // file does not, so the next launch has nothing. Reporting
                // success here is how a guest tells the host it holds a
                // credential it will have forgotten by morning.
                return DeliverCredentialsOutcome::Rejected {
                    reason: format!("fallback write failed: {e}"),
                };
            }
        }
        Err(e) => {
            report_fallback_write_failure(
                "host delivery into the guest",
                &format!("cache dir unavailable: {e}"),
            );
            return DeliverCredentialsOutcome::Rejected {
                reason: format!("cache dir unavailable: {e}"),
            };
        }
    }
    DeliverCredentialsOutcome::Accepted
}

#[cfg(feature = "vault")]
#[allow(dead_code)]
pub fn get_pending_handover() -> (Option<String>, Option<String>) {
    let cell = PENDING_HANDOVER.get_or_init(|| Mutex::new(None));
    if let Ok(guard) = cell.lock()
        && let Some(handover) = &*guard
    {
        return (
            handover.unseal_share_b64.clone(),
            handover.root_token.clone(),
        );
    }
    (None, None)
}

/// Set once a GetVaultHandover reply actually carries the first-boot Shamir
/// share. An empty reply is only a timeout observation, not delivery: a later
/// request must retain the bounded first-boot retry window. Steady-state
/// connections skip that window after real delivery — the loop used to sleep
/// its full 8s budget on every fresh control-wire connection against an
/// already-bootstrapped vault (slowdown audit 2026-07-23: 8.1-8.2s measured on
/// every --status-once; the tray paid it twice serially at startup).
#[cfg(feature = "vault")]
pub static HANDOVER_DELIVERED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[cfg(feature = "vault")]
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
pub fn handover_already_delivered() -> bool {
    HANDOVER_DELIVERED.load(std::sync::atomic::Ordering::SeqCst)
}

/// A handover reply closes the first-boot retry window only when it contains
/// the Shamir share the host must persist. Root-token-only or empty replies do
/// not make a later unseal safe.
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
pub fn handover_reply_delivers_unseal_share(unseal_share_b64: Option<&str>) -> bool {
    unseal_share_b64.is_some_and(|share| !share.trim().is_empty())
}

#[cfg(feature = "vault")]
#[allow(dead_code)]
pub fn clear_pending_handover(delivered_unseal_share: bool) {
    let cell = PENDING_HANDOVER.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cell.lock() {
        *guard = None;
    }
    if delivered_unseal_share {
        HANDOVER_DELIVERED.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

#[cfg(feature = "vault")]
pub fn is_running_in_vm() -> bool {
    if let Some(cell) = IN_VM_CREDENTIALS.get()
        && let Ok(guard) = cell.lock()
        && guard.is_some()
    {
        return true;
    }
    if std::env::var("TILLANDSIAS_HOST_KIND").is_ok() {
        return true;
    }
    if let Ok(hostname) = std::fs::read_to_string("/proc/sys/kernel/hostname")
        && hostname.trim() == "tillandsias-vm"
    {
        return true;
    }
    // Provisioning-owned guest marker. WSL distros inherit the WINDOWS
    // hostname (Esmeralda field failure, 2026-08-09: a bare `--github-login`
    // shell had no delivered credentials, no TILLANDSIAS_HOST_KIND, and a
    // non-"tillandsias-vm" hostname, misclassified as a native Linux host,
    // and probed vault at the 127.0.0.1:8201 port-forward — the known
    // WSL2/netavark TLS-hang). The Windows tray's inject_bootstrap_logic
    // writes this marker so every in-guest lane classifies correctly.
    if std::path::Path::new("/etc/tillandsias/in-vm").exists() {
        return true;
    }
    false
}

/// 890-y72v: the no-vault build stores nothing, so it must not answer
/// `Accepted`. It is not a rejection either — there is no vault to reject
/// anything — and `Unstated` is the value whose whole contract is "no claim
/// was made", which is exactly true here.
#[cfg(not(feature = "vault"))]
pub fn set_in_vm_credentials(
    _unseal_share_b64: Option<String>,
    _installation_uuid: String,
    _root_token: Option<String>,
) -> DeliverCredentialsOutcome {
    DeliverCredentialsOutcome::Unstated
}

#[cfg(not(feature = "vault"))]
pub fn get_pending_handover() -> (Option<String>, Option<String>) {
    (None, None)
}

#[cfg(not(feature = "vault"))]
pub fn clear_pending_handover(_delivered_unseal_share: bool) {}

#[cfg(not(feature = "vault"))]
#[cfg_attr(not(feature = "listen-vsock"), allow(dead_code))]
pub fn handover_already_delivered() -> bool {
    true
}

#[cfg(not(feature = "vault"))]
pub fn is_running_in_vm() -> bool {
    false
}

/// Default token TTL for per-container AppRole tokens (1h).
pub const APPROLE_TOKEN_TTL_SECS: u64 = 3_600;
/// Hard upper bound on a renewed AppRole token (24h).
pub const APPROLE_TOKEN_MAX_TTL_SECS: u64 = 86_400;
/// Dedicated bounded-reuse AppRole for the long-running git-mirror Vault Agent.
///
/// Ordinary roles keep one-use, 30-second SecretIDs. This role is the narrow
/// exception that can log in again after its client token reaches max_ttl;
/// the host destroys each issued SecretID by accessor on shutdown, while the
/// role's 48h server TTL bounds credentials orphaned by an uncatchable crash.
pub const GIT_MIRROR_AGENT_ROLE: &str = "git-mirror-agent";

/// Process-wide registry of per-container vault tokens that should be
/// revoked on shutdown. The tray installs entries here when minting a token
/// for a container launch; `revoke_pending_container_tokens` drains the
/// registry, calling `vault token revoke` on each entry.
fn revocation_registry() -> &'static Mutex<HashMap<String, String>> {
    static REG: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Bounded-reuse AppRole login material issued to a long-running Vault Agent.
///
/// Only the non-secret accessor is retained by the host. It lets shutdown
/// invalidate the secret ID without ever reading the credential back from its
/// Podman secret.
struct AppRoleAutoAuthRegistration {
    role: String,
    secret_id_accessor: String,
    /// The container this material was minted FOR, when the caller knows it.
    ///
    /// Order 828-k3mq: the drain must not destroy a SecretID whose container is
    /// still running. `None` means the caller could not name one, and such a
    /// registration keeps the pre-828 behaviour (destroy on drain).
    owning_container: Option<String>,
}

/// Whether the container an AppRole registration belongs to is still alive.
///
/// Order 828-k3mq. Deliberately TRI-STATE, and deliberately NOT
/// [`container_running`], which collapses every failure to `false`. That
/// collapse is the right default for "should I start this?" and exactly the
/// wrong one here: a transient `podman inspect` failure would read as "the
/// container is gone", and the drain would destroy the credential of a mirror
/// that is still serving clones — the precise defect 828-k3mq records.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OwningContainerState {
    /// Inspect answered and the container is up. Never destroy its material.
    Running,
    /// Inspect answered that no such container exists. Safe to destroy.
    Gone,
    /// Inspect could not answer. Treated as Running (leak-not-destroy), the
    /// same rule `cleanup_shared_stack_if_no_running_forge` applies to a failed
    /// container listing. The role's 48h server-side SecretID TTL bounds the
    /// resulting orphan, which is the job that TTL exists to do.
    Unknown,
}

/// Classify a `podman inspect --format {{.State.Running}}` result.
///
/// Split out of [`owning_container_state`] as a PURE function so the
/// destroy/keep decision is testable without podman — the decision is the
/// load-bearing half of order 828-k3mq, and a rule that can only be exercised
/// against a live daemon is a rule nothing gates.
fn classify_owning_container_output(
    exit_ok: bool,
    stdout: &str,
    stderr: &str,
) -> OwningContainerState {
    if exit_ok {
        return if stdout.trim() == "true" {
            OwningContainerState::Running
        } else {
            OwningContainerState::Gone
        };
    }
    // A non-zero inspect is "no such container" (the container really is gone)
    // OR a transport failure. Only the former is safe to act on, so the message
    // is matched explicitly and everything else stays Unknown.
    let stderr = stderr.to_ascii_lowercase();
    if stderr.contains("no such container") || stderr.contains("no such object") {
        OwningContainerState::Gone
    } else {
        OwningContainerState::Unknown
    }
}

/// Split drained AppRole registrations into (destroy, keep) by owner liveness.
///
/// Order 828-k3mq, closure half. The keep/destroy decision used to live inline
/// in `revoke_pending_container_tokens`'s loop, which meant the only way to
/// exercise it was to have a live Vault and a live podman — and a rule that
/// can only be tested against live infrastructure is a rule nothing gates.
/// That is the same reasoning that split `classify_owning_container_output`
/// out of `owning_container_state`, applied one level up: here it is the
/// DRAIN's behaviour under test, not just the classifier's.
///
/// `probe` is injected so a fixture can drive every arm without podman.
///
/// A registration with NO owning container is destroyed, preserving pre-828
/// behaviour for any caller that cannot name one — that arm is asserted too,
/// because silently starting to keep unowned material would be a credential
/// leak wearing this fix's clothes.
///
/// Returns `(to_destroy, kept)` where `kept` carries the container name and
/// the observed state so the caller can log the right thing for each arm.
/// `Gone` never appears in `kept`.
#[allow(clippy::type_complexity)]
fn partition_auto_auth_entries<P>(
    entries: Vec<(String, AppRoleAutoAuthRegistration)>,
    mut probe: P,
) -> (
    Vec<(String, AppRoleAutoAuthRegistration)>,
    Vec<(String, String, OwningContainerState)>,
)
where
    P: FnMut(&str) -> OwningContainerState,
{
    let mut to_destroy = Vec::new();
    let mut kept = Vec::new();
    for (secret_name, registration) in entries {
        let Some(container) = registration.owning_container.clone() else {
            to_destroy.push((secret_name, registration));
            continue;
        };
        match probe(&container) {
            OwningContainerState::Gone => to_destroy.push((secret_name, registration)),
            state => kept.push((secret_name, container, state)),
        }
    }
    (to_destroy, kept)
}

fn owning_container_state(name: &str) -> OwningContainerState {
    let out = podman_cmd_sync()
        .args(["inspect", "--format", "{{.State.Running}}", name])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget());
    match out {
        Ok(o) => classify_owning_container_output(
            o.status.success(),
            &String::from_utf8_lossy(&o.stdout),
            &String::from_utf8_lossy(&o.stderr),
        ),
        Err(_) => OwningContainerState::Unknown,
    }
}

#[derive(serde::Serialize)]
struct AppRoleAutoAuthDocument<'a> {
    role_id: &'a str,
    secret_id: &'a str,
}

fn approle_auto_auth_registry() -> &'static Mutex<HashMap<String, AppRoleAutoAuthRegistration>> {
    static REG: OnceLock<Mutex<HashMap<String, AppRoleAutoAuthRegistration>>> = OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_approle_auto_auth_secret_name(role: &str, container_instance: &str) -> String {
    // A random issuance component avoids collisions both on same-process
    // relaunch and after a crash followed by PID reuse, when a prior Podman
    // secret can still exist pending cleanup.
    let issuance = uuid::Uuid::new_v4();
    format!("tillandsias-vault-approle-{role}-{container_instance}-{issuance}")
}

/// Default base URL the macOS/Windows tray uses to talk to the local Vault
/// container via the host-side port-forward. Not used on Linux where the
/// in-VM headless reaches Vault directly over the enclave bridge network.
#[cfg(not(target_os = "linux"))]
pub fn host_base_url() -> String {
    format!("https://127.0.0.1:{VAULT_HOST_PORT}")
}

/// Direct URL for the in-VM headless to reach the Vault container via the
/// enclave bridge network. Uses the network alias `vault` which netavark's
/// aardvark-dns resolves via systemd-resolved. The vault TLS cert carries
/// `DNS:vault` as a SAN so certificate verification succeeds without any
/// skip-verify workaround. Bypasses host-side port forwarding (127.0.0.1:8201)
/// which has a known TLS-hang issue with podman/netavark on Fedora WSL2.
// PLEASE REVIEW (linux): the only non-test caller is inside the
// `#[cfg(target_os = "linux")]` branch of vault_api_base_url below, so a
// non-Linux, non-test build (bin/clippy target) sees this as dead code
// (-D warnings). It IS exercised unconditionally by
// vault_api_base_url_honors_env_override below, so the allow is scoped to
// non-Linux only — no change to the Linux dead-code contract. Discovered
// running `./build.sh --check` on macOS for the first time after fixing the
// Homebrew-Podman wrapper bug (order 201) — see
// plan/issues/macos-build-check-podman-wrapper-2026-07-05.md.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn vault_service_base_url() -> String {
    format!("https://{VAULT_NETWORK_ALIAS}:8200")
}

#[cfg(target_os = "linux")]
fn linux_vault_api_base_url(running_in_vm: bool) -> String {
    if running_in_vm {
        vault_service_base_url()
    } else {
        format!("https://127.0.0.1:{VAULT_HOST_PORT}")
    }
}

fn vault_host_publish_arg(running_in_vm: bool) -> Option<String> {
    (!running_in_vm).then(|| format!("127.0.0.1:{VAULT_HOST_PORT}:8200"))
}

fn vault_api_base_url() -> String {
    std::env::var(VAULT_API_BASE_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| {
            // The Linux binary runs in TWO contexts:
            //  - In-VM headless (inside the guest, ON the enclave bridge): the
            //    alias `vault` resolves via aardvark-dns and the cert carries
            //    DNS:vault, so use the enclave URL (also dodges a WSL2/netavark
            //    loopback TLS-hang).
            //  - Native Linux HOST (e.g. rootless Fedora Silverblue `--init`):
            //    vault bootstrap runs on the host, where `vault` does NOT resolve
            //    — the podman network's DNS lives in the container netns, and the
            //    /etc/hosts fallback needs root (skipped rootless). It must use
            //    the PUBLISHED loopback port. The cert SANs include IP:127.0.0.1,
            //    so TLS verifies. This is the P0 that made the host probe fail
            //    with `https://vault:8200 -> dns error: Name does not resolve`.
            // @trace plan/issues/vault-host-dns-vault-name-unresolvable-2026-07-03.md
            #[cfg(target_os = "linux")]
            {
                linux_vault_api_base_url(is_running_in_vm())
            }
            #[cfg(not(target_os = "linux"))]
            {
                host_base_url()
            }
        })
}

fn tls_material_dir(debug: bool) -> Result<PathBuf, String> {
    crate::ensure_ca_bundle(debug)
}

fn vault_tls_cert(certs_dir: &std::path::Path) -> PathBuf {
    certs_dir.join("vault.crt")
}

fn vault_tls_key(certs_dir: &std::path::Path) -> PathBuf {
    certs_dir.join("vault.key")
}

fn vault_tls_leaf_has_service_identity(cert: &std::path::Path) -> bool {
    match Command::new("openssl")
        .args(["x509", "-noout", "-ext", "subjectAltName", "-in"])
        .arg(cert)
        .output()
    {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            stdout.contains("DNS:vault") && stdout.contains("IP Address:127.0.0.1")
        }
        _ => false,
    }
}

fn vault_tls_leaf_needs_refresh(
    ca_cert: &std::path::Path,
    cert: &std::path::Path,
    key: &std::path::Path,
) -> bool {
    if !cert.exists() || !key.exists() {
        return true;
    }
    if let (Ok(ca_meta), Ok(cert_meta)) = (fs::metadata(ca_cert), fs::metadata(cert))
        && let (Ok(ca_modified), Ok(cert_modified)) = (ca_meta.modified(), cert_meta.modified())
        && ca_modified > cert_modified
    {
        return true;
    }
    if !vault_tls_leaf_has_service_identity(cert) {
        return true;
    }
    match Command::new("openssl")
        .args(["x509", "-checkend", "86400", "-noout", "-in"])
        .arg(cert)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(status) => !status.success(),
        Err(_) => true,
    }
}

fn ensure_vault_tls_leaf(certs_dir: &std::path::Path, debug: bool) -> Result<(), String> {
    let ca_cert = certs_dir.join("intermediate.crt");
    let ca_key = certs_dir.join("intermediate.key");
    let cert = vault_tls_cert(certs_dir);
    let key = vault_tls_key(certs_dir);
    if !vault_tls_leaf_needs_refresh(&ca_cert, &cert, &key) {
        return Ok(());
    }

    let lock_dir = certs_dir.join(".vault-tls-generation.lock");
    let mut acquired_lock = false;
    for _ in 0..50 {
        match fs::create_dir(&lock_dir) {
            Ok(()) => {
                acquired_lock = true;
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(format!("acquire Vault TLS generation lock: {e}")),
        }
    }
    if !acquired_lock {
        return Err("timed out waiting for Vault TLS generation lock".to_string());
    }
    struct LockDir(PathBuf);
    impl Drop for LockDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir(&self.0);
        }
    }
    let _lock = LockDir(lock_dir);
    if !vault_tls_leaf_needs_refresh(&ca_cert, &cert, &key) {
        return Ok(());
    }

    let unique = format!(
        "{}.{}",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
    );
    let csr = certs_dir.join(format!("vault.csr.{unique}.tmp"));
    let tmp_cert = certs_dir.join(format!("vault.crt.{unique}.tmp"));
    let tmp_key = certs_dir.join(format!("vault.key.{unique}.tmp"));
    let vault_san = "subjectAltName=DNS:vault,DNS:localhost,IP:127.0.0.1";
    if debug {
        eprintln!(
            "[tillandsias-vault] refreshing Vault TLS leaf certificate at {}",
            cert.display()
        );
    }

    let req_status = Command::new("openssl")
        .args(["req", "-newkey", "rsa:2048", "-nodes", "-keyout"])
        .arg(&tmp_key)
        .arg("-out")
        .arg(&csr)
        .args(["-subj", "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=vault"])
        .arg("-addext")
        .arg(vault_san)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("spawn openssl req for Vault TLS leaf: {e}"))?;
    if !req_status.success() {
        let _ = fs::remove_file(&csr);
        let _ = fs::remove_file(&tmp_key);
        return Err(format!(
            "openssl req for Vault TLS leaf failed: {req_status}"
        ));
    }

    let sign_status = Command::new("openssl")
        .args(["x509", "-req", "-in"])
        .arg(&csr)
        .arg("-CA")
        .arg(&ca_cert)
        .arg("-CAkey")
        .arg(&ca_key)
        .args([
            "-CAcreateserial",
            "-days",
            "30",
            "-sha256",
            "-copy_extensions",
            "copy",
            "-out",
        ])
        .arg(&tmp_cert)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("spawn openssl x509 for Vault TLS leaf: {e}"))?;
    let _ = fs::remove_file(&csr);
    if !sign_status.success() {
        let _ = fs::remove_file(&tmp_cert);
        let _ = fs::remove_file(&tmp_key);
        return Err(format!(
            "openssl x509 for Vault TLS leaf failed: {sign_status}"
        ));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&tmp_cert, fs::Permissions::from_mode(0o644))
            .map_err(|e| format!("set Vault TLS cert permissions: {e}"))?;
        fs::set_permissions(&tmp_key, fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("set Vault TLS key permissions: {e}"))?;
    }
    fs::rename(&tmp_key, &key).map_err(|e| format!("publish Vault TLS key: {e}"))?;
    fs::rename(&tmp_cert, &cert).map_err(|e| format!("publish Vault TLS cert: {e}"))?;
    Ok(())
}

fn vault_client(base_url: &str, token: &str, debug: bool) -> Result<VaultClient, String> {
    let certs_dir = tls_material_dir(debug)?;
    let ca_pem = fs::read(certs_dir.join("intermediate.crt"))
        .map_err(|e| format!("read Vault CA certificate: {e}"))?;
    VaultClient::new_with_ca_certificate(base_url, token, &ca_pem)
        .map_err(|e| format!("build Vault TLS client: {e}"))
}

/// Public entry point: bring Vault up as part of the standard init flow.
///
/// Idempotent — skips work when the container is already running and
/// healthy. Called automatically from `run_init`; the previous `--with-vault`
/// opt-in is now a no-op.
pub fn ensure_vault_running(debug: bool) -> Result<(), String> {
    // Order 234 (R6): refuse before waiting on the lock during drain/stop.
    if !crate::runtime_phase::container_mutations_allowed() {
        return Err(crate::runtime_phase::refusal("ensure tillandsias-vault"));
    }
    // Order 232 (R4): serialize the whole running-check + build + launch +
    // init/unseal window. 600s bound: a cold vault image build plus first
    // init is the slowest ensure path. The liveness probe (order 228) takes
    // this same lock, so its self-heal can no longer race a user login's
    // vault bring-up.
    let _vault_lock =
        crate::resource_lock::acquire("vault", std::time::Duration::from_secs(600), debug)?;
    let certs_dir = tls_material_dir(debug)?;
    ensure_vault_tls_leaf(&certs_dir, debug)?;

    if container_running(VAULT_CONTAINER_NAME) {
        // Refresh /etc/hosts before any API probe — each podman restart can
        // give the container a new IP from the enclave bridge IPAM.
        update_etc_hosts_vault(debug);
        // Already up. Probe health to make sure it's serving.
        let rt = tokio_runtime()?;
        let base_url = vault_api_base_url();
        let client = vault_client(&base_url, "", debug)?;
        match wait_for_vault_api_ready(&rt, &client, debug) {
            Ok(h) => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] container already running and unsealed (v={})",
                        h.version
                    );
                }
                let root_token = validated_root_token(&rt, &base_url, debug)?;
                let client = vault_client(&base_url, &root_token, debug)?;
                // Sentinel must be the NEWEST provisioned role, not the oldest:
                // probing an older role lets vaults provisioned before a Policy
                // addition skip provisioning forever, so newly added roles were
                // never created on existing vault volumes and every token
                // mint 404'd. load_policies/create_approle_role are
                // idempotent overwrites, so re-provisioning is safe. Bump this
                // to the newest role EVERY time a Policy is added — order 431
                // adds the read-only OpenCode auth-document role, so the
                // conventional newest sentinel is 'opencode-forge'.
                //
                // git-mirror-agent is a dedicated lifecycle role rather than
                // a Policy enum entry. Probe it independently: a volume
                // upgraded through order 431 before order 424 can already have
                // the newest Policy sentinel while still lacking the Agent
                // role. Skip only when BOTH migrations are present.
                let opencode_role_exists = rt
                    .block_on(client.approle_role_exists("opencode-forge"))
                    .unwrap_or(false);
                let git_mirror_agent_role_exists = rt
                    .block_on(client.approle_role_exists(GIT_MIRROR_AGENT_ROLE))
                    .unwrap_or(false);
                if opencode_role_exists && git_mirror_agent_role_exists {
                    if debug {
                        eprintln!(
                            "[tillandsias-vault] AppRoles 'opencode-forge' (newest Policy sentinel) and '{GIT_MIRROR_AGENT_ROLE}' (Agent lifecycle migration) already exist; skipping policy and role provisioning"
                        );
                    }
                } else {
                    rt.block_on(load_policies(&client, debug))?;
                    rt.block_on(provision_approle_roles(&client, debug))?;
                }
                return Ok(());
            }
            Err(e) => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] container present but health probe returned {e}; relaunching"
                    );
                }
            }
        }
    }

    eprintln!("[tillandsias-vault] bootstrap starting (Phase 6.5 hardened)");

    #[cfg(feature = "vault")]
    sanitize_keychain(debug);

    let vault_image_tag = build_vault_image(debug)?;
    refresh_vault_tls_secrets(&certs_dir, debug)?;

    // Verify-before-persist (restart self-wedge, 2026-07-17): NEVER
    // speculatively `--replace` an existing unseal secret. A routine headless
    // restart re-ensured here, `ensure_unseal_key()` recovered a share that
    // did NOT match the initialized storage, and the unconditional
    // `create_unseal_secret` overwrote the WORKING podman secret with it —
    // the container then crash-looped on unseal, and because vault stayed
    // down, every liveness cycle regenerated the secret again (self-
    // sustaining wedge on real operator secrets). An existing secret is
    // reused unchanged — sitting ABOVE both the VM-handover and native-
    // keychain key sources — and the launch itself proves whether it still
    // unseals; only a PROVEN key rejection may enter the one-shot recovery
    // seam below. Creating from `ensure_unseal_key` remains correct ONLY
    // when no secret exists at all (true first boot — nothing working can
    // be destroyed).
    // @trace plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md
    let reusing_existing_secret = cfg!(feature = "vault") && unseal_secret_exists();
    if reusing_existing_secret {
        if debug {
            eprintln!(
                "[tillandsias-vault] podman secret {VAULT_UNSEAL_SECRET} already exists; \
                 reusing it unchanged (verify-before-persist)"
            );
        }
    } else {
        let mut unseal_key = ensure_unseal_key(debug)?;
        create_unseal_secret(&unseal_key, debug)?;
        unseal_key.zeroize();
    }
    launch_vault_container(&vault_image_tag, debug)?;

    let rt = tokio_runtime()?;
    let base_url = vault_api_base_url();
    let root_token = match wait_for_vault_ready(&rt, &base_url, debug) {
        Ok(token) => token,
        // Only a launch that REUSED a pre-existing secret may enter the
        // recovery seam. When this process just created the secret itself,
        // the key already came from the recovery stores, so there is no
        // second candidate to offer — the failure propagates unchanged.
        Err(wait_err) if reusing_existing_secret => {
            recover_rejected_unseal_secret_once(&rt, &base_url, &vault_image_tag, &wait_err, debug)?
        }
        Err(e) => return Err(e),
    };
    let client = vault_client(&base_url, &root_token, debug)?;

    rt.block_on(load_policies(&client, debug))?;
    rt.block_on(provision_approle_roles(&client, debug))?;

    eprintln!("[tillandsias-vault] bootstrap complete");
    eprintln!(
        "[tillandsias-vault]   container : {VAULT_CONTAINER_NAME} (network alias: {VAULT_NETWORK_ALIAS})"
    );
    eprintln!("[tillandsias-vault]   policies : {:?}", Policy::all());
    eprintln!("[tillandsias-vault]   base_url : {base_url}");
    Ok(())
}

fn wait_for_vault_api_ready(
    rt: &crate::RuntimeOrHandle,
    client: &VaultClient,
    debug: bool,
) -> Result<HealthStatus, String> {
    let mut delay = Duration::from_millis(250);
    let max_delay = Duration::from_secs(2);
    let mut last_failure = "vault API probe did not run".to_string();
    const MAX_API_PROBE_ATTEMPTS: usize = 8;

    for attempt in 1..=MAX_API_PROBE_ATTEMPTS {
        match rt.block_on(client.health()) {
            Ok(h) if h.initialized && !h.sealed => return Ok(h),
            Ok(h) => {
                last_failure = format!(
                    "vault API reports initialized={} sealed={}",
                    h.initialized, h.sealed
                );
            }
            Err(e) => {
                last_failure = format!("vault API probe failed: {e}");
            }
        }
        if attempt == MAX_API_PROBE_ATTEMPTS {
            break;
        }
        if debug {
            eprintln!(
                "[tillandsias-vault] {last_failure}; retrying API probe ({attempt}/{MAX_API_PROBE_ATTEMPTS})"
            );
        }
        std::thread::sleep(delay);
        delay = std::cmp::min(delay.saturating_mul(2), max_delay);
    }

    Err(last_failure)
}

/// Compatibility shim retained for the deprecated `--with-vault` opt-in
/// flag. Reduces to `ensure_vault_running`.
#[allow(dead_code)]
pub fn run_with_vault_init(debug: bool) -> Result<(), String> {
    ensure_vault_running(debug)
}

/// Write the GitHub token directly to Vault at `secret/github/token`.
///
/// Used by the new (Phase 6) `tillandsias --github-login` flow. Returns
/// `Err` if Vault cannot be brought up or the write fails.
///
/// Self-healing: rather than telling the operator to run `tillandsias --init`
/// (which they may already have done — Vault can have died from a userns
/// mapping drift or a host reboot since then), we bring Vault up on demand via
/// the same idempotent path `--init` uses. The token has already been pasted
/// by this point, so failing fast with a stale hint would waste it.
#[allow(dead_code)]
pub fn write_github_token_to_vault(token: &str, debug: bool) -> Result<(), String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        if debug {
            eprintln!(
                "[tillandsias-vault] {VAULT_CONTAINER_NAME} not running; bringing Vault up on demand before token write"
            );
        }
        ensure_vault_running(debug)
            .map_err(|e| format!("could not bring Vault up to store the GitHub token: {e}"))?;
    }
    // Order 235 (R7): AFTER the on-demand bring-up (ensure holds the same
    // resource exclusively — taking shared first would self-deadlock), hold
    // shared so a concurrent recreate waits for this write to finish.
    let _stability = vault_stability_lease(debug)?;
    let rt = tokio_runtime()?;
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;

    if debug {
        eprintln!(
            "[tillandsias-vault] writing GitHub token ({} chars) to secret/github/token",
            token.len()
        );
    }
    rt.block_on(client.write_secret("secret/github/token", serde_json::json!({ "token": token })))
        .map_err(|e| format!("vault write_secret failed: {e}"))?;
    // Round-trip verification so the user sees a hard failure if the policy
    // changed under them.
    let read_back = rt
        .block_on(client.read_secret("secret/github/token"))
        .map_err(|e| format!("vault read_secret verification failed: {e}"))?;
    if read_back["token"].as_str() != Some(token) {
        return Err("vault read-back did not match written token".into());
    }
    println!(
        "[tillandsias] GitHub token stored in Vault at secret/github/token (policy: git-mirror-policy)"
    );
    Ok(())
}

/// Where the GitHub App credential lives in Vault (order 1383-5hpk).
///
/// TWO PATHS, deliberately. `secret/github/token` holds only what a git
/// operation needs (the access token and its expiry) and is what the
/// git-mirror policy reads. The REFRESH token mints new access tokens for
/// months and must not be readable by the git-mirror service, which only ever
/// needs the short-lived one. Vault KV v2 policies are path-scoped, not
/// field-scoped, so the refresh token gets its own path, which no git-mirror
/// grant covers (images/vault/policies/git-mirror.hcl names
/// secret/data/github/token exactly).
pub const GITHUB_TOKEN_PATH: &str = "secret/github/token";
pub const GITHUB_REFRESH_PATH: &str = "secret/github/refresh";

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GitHubTokenBundle {
    pub token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<u64>,
    pub refresh_token_expires_at: Option<u64>,
    pub client_id: Option<String>,
}

/// The token-path record: what the git-mirror service may read.
fn github_token_record(b: &GitHubTokenBundle) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    map.insert("token".into(), b.token.clone().into());
    if let Some(exp) = b.expires_at {
        map.insert("expires_at".into(), exp.into());
    }
    if let Some(cid) = &b.client_id {
        map.insert("client_id".into(), cid.clone().into());
    }
    serde_json::Value::Object(map)
}

/// The refresh-path record: never readable by git-mirror.
fn github_refresh_record(b: &GitHubTokenBundle) -> Option<serde_json::Value> {
    let rt = b.refresh_token.as_ref()?;
    let mut map = serde_json::Map::new();
    map.insert("refresh_token".into(), rt.clone().into());
    if let Some(rexp) = b.refresh_token_expires_at {
        map.insert("refresh_token_expires_at".into(), rexp.into());
    }
    if let Some(cid) = &b.client_id {
        map.insert("client_id".into(), cid.clone().into());
    }
    Some(serde_json::Value::Object(map))
}

/// Vault as the rotation sees it. A trait so the ordering and failure rules of
/// [`rotate_github_token`] are testable without a Vault.
pub trait GitHubTokenStore {
    fn read_bundle(&self) -> Result<Option<GitHubTokenBundle>, String>;
    fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String>;
}

/// Write a bundle: the REFRESH record first, then the token record.
///
/// The order is the failure rule. GitHub refresh tokens are single-use, so
/// after a successful refresh the old one is already dead and the new one
/// exists only in this process. Writing it first means the scarce credential
/// is persisted before anything else can go wrong. If that write fails,
/// NOTHING in Vault has changed and the old bundle is intact. If the token
/// write fails afterwards, the new refresh token is already safe and the old
/// access token stays valid until its own expiry.
pub fn store_github_token_bundle(
    store: &dyn GitHubTokenStore,
    bundle: &GitHubTokenBundle,
) -> Result<(), String> {
    if let Some(refresh) = github_refresh_record(bundle) {
        store
            .write_record(GITHUB_REFRESH_PATH, refresh)
            .map_err(|e| format!("could not store the rotated refresh token: {e}"))?;
    }
    store
        .write_record(GITHUB_TOKEN_PATH, github_token_record(bundle))
        .map_err(|e| format!("could not store the rotated access token: {e}"))
}

/// The live store: Vault through the root token, the same client the rest of
/// this module uses.
pub struct VaultGitHubTokenStore {
    pub debug: bool,
}

impl GitHubTokenStore for VaultGitHubTokenStore {
    fn read_bundle(&self) -> Result<Option<GitHubTokenBundle>, String> {
        let debug = self.debug;
        if !container_running(VAULT_CONTAINER_NAME) {
            return Ok(None);
        }
        let _stability = vault_stability_lease(debug)?;
        let rt = tokio_runtime()?;
        let base_url = vault_api_base_url();
        let root_token = match read_and_handover_root_token(debug) {
            Ok(t) => t,
            Err(_) => return Ok(None),
        };
        let client = vault_client(&base_url, &root_token, debug)?;
        let secret = match rt.block_on(client.read_secret(GITHUB_TOKEN_PATH)) {
            Ok(s) => s,
            Err(_) => return Ok(None),
        };
        let token = match secret["token"].as_str() {
            Some(t) if !t.is_empty() => t.to_string(),
            _ => return Ok(None),
        };
        // An absent refresh record is a legitimate state (a token-only login);
        // a read error is not the same thing and is reported as one.
        let refresh = rt.block_on(client.read_secret(GITHUB_REFRESH_PATH)).ok();
        let refresh_token = refresh
            .as_ref()
            .and_then(|r| r["refresh_token"].as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
        Ok(Some(GitHubTokenBundle {
            token,
            refresh_token,
            expires_at: secret["expires_at"].as_u64(),
            refresh_token_expires_at: refresh
                .as_ref()
                .and_then(|r| r["refresh_token_expires_at"].as_u64()),
            client_id: secret["client_id"].as_str().map(|s| s.to_string()),
        }))
    }

    fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
        let debug = self.debug;
        if !container_running(VAULT_CONTAINER_NAME) {
            ensure_vault_running(debug)
                .map_err(|e| format!("could not bring Vault up to store {path}: {e}"))?;
        }
        let _stability = vault_stability_lease(debug)?;
        let rt = tokio_runtime()?;
        let base_url = vault_api_base_url();
        let root_token = read_and_handover_root_token(debug)?;
        let client = vault_client(&base_url, &root_token, debug)?;
        rt.block_on(client.write_secret(path, value.clone()))
            .map_err(|e| format!("vault write of {path} failed: {e}"))?;
        // Read back and compare, without echoing either side into the error.
        let read_back = rt
            .block_on(client.read_secret(path))
            .map_err(|e| format!("vault read-back of {path} failed: {e}"))?;
        if read_back != value {
            return Err(format!(
                "vault read-back of {path} did not match what was written"
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GitHubRefreshResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: u64,
    pub refresh_token_expires_in: u64,
}

/// Parse GitHub's refresh response WITHOUT ever putting the body in an error.
///
/// Order 1383-5hpk: the first version formatted the whole body into
/// "missing refresh_token in refresh response: {body}". When GitHub returns a
/// new access token but no refresh token, that body CONTAINS the fresh access
/// token, and the error was printed. Errors here name the missing field, and
/// GitHub's `error` code only after checking it is a plain identifier, never
/// `error_description` or any other body text.
pub fn parse_github_refresh_response(
    body: &serde_json::Value,
) -> Result<GitHubRefreshResponse, String> {
    if let Some(err) = body.get("error").and_then(|e| e.as_str()) {
        let code = if !err.is_empty()
            && err.len() <= 64
            && err.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        {
            err
        } else {
            "unrecognised-error-code"
        };
        return Err(format!("GitHub refused the token refresh ({code})"));
    }
    let access_token = body["access_token"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("GitHub's refresh response has no access_token")?
        .to_string();
    let refresh_token = body["refresh_token"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("GitHub's refresh response has no refresh_token")?
        .to_string();
    Ok(GitHubRefreshResponse {
        access_token,
        refresh_token,
        expires_in: body["expires_in"].as_u64().unwrap_or(28800),
        refresh_token_expires_in: body["refresh_token_expires_in"]
            .as_u64()
            .unwrap_or(15_811_200),
    })
}

pub fn perform_github_token_refresh(
    client_id: &str,
    refresh_token: &str,
    debug: bool,
) -> Result<GitHubRefreshResponse, String> {
    let rt = tokio_runtime()?;
    rt.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| format!("failed to build HTTP client for token refresh: {e}"))?;
        if debug {
            eprintln!(
                "[tillandsias] POST https://github.com/login/oauth/access_token (grant_type=refresh_token)"
            );
        }
        let res = client
            .post("https://github.com/login/oauth/access_token")
            .header(reqwest::header::ACCEPT, "application/json")
            .form(&[
                ("client_id", client_id),
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh_token),
            ])
            .send()
            .await
            .map_err(|e| format!("token refresh HTTP request failed: {e}"))?;
        if !res.status().is_success() {
            return Err(format!(
                "token refresh request failed with HTTP {}",
                res.status()
            ));
        }
        // A parse failure names the failure, never the bytes it failed on.
        let body: serde_json::Value = res
            .json()
            .await
            .map_err(|_| "GitHub's refresh response is not valid JSON".to_string())?;
        parse_github_refresh_response(&body)
    })
}

/// What a rotation did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RotationOutcome {
    Rotated,
    /// There is a stored token but no refresh token: nothing can be rotated.
    /// Callers must treat this as a NON-ZERO verdict (order 1383-5hpk): a
    /// "refresh" that could not refresh anything did not succeed.
    NoRefreshToken,
    /// There is no GitHub credential in Vault at all.
    NoToken,
}

/// Rotate the GitHub App token: read, refresh, then STORE, and only then
/// return the new pair to anyone.
///
/// The new pair is written to Vault before this function hands it out, so
/// nothing can use a token that Vault does not hold. The caller holds the
/// exclusive rotation lock (see [`refresh_github_token_in_vault`]); two
/// unserialised rotations would both spend the same single-use refresh token,
/// and the loser's write could replace the winner's live pair with a dead one.
pub fn rotate_github_token(
    store: &dyn GitHubTokenStore,
    refresh: &dyn Fn(&str, &str) -> Result<GitHubRefreshResponse, String>,
    now: u64,
) -> Result<(RotationOutcome, Option<GitHubTokenBundle>), String> {
    let Some(bundle) = store.read_bundle()? else {
        return Ok((RotationOutcome::NoToken, None));
    };
    let Some(old_refresh) = bundle.refresh_token.as_deref().filter(|s| !s.is_empty()) else {
        return Ok((RotationOutcome::NoRefreshToken, None));
    };
    let client_id = bundle
        .client_id
        .clone()
        .unwrap_or_else(|| crate::GITHUB_APP_CLIENT_ID.to_string());
    let resp = refresh(&client_id, old_refresh)?;
    let rotated = GitHubTokenBundle {
        token: resp.access_token,
        refresh_token: Some(resp.refresh_token),
        expires_at: Some(now + resp.expires_in),
        refresh_token_expires_at: Some(now + resp.refresh_token_expires_in),
        client_id: Some(client_id),
    };
    store_github_token_bundle(store, &rotated)?;
    Ok((RotationOutcome::Rotated, Some(rotated)))
}

/// The lock every rotation takes: an exclusive advisory flock under the
/// runtime dir (resource_lock), so a second tillandsias process that decides
/// to refresh at the same moment waits and then sees the first one's result.
pub const GITHUB_ROTATION_LOCK: &str = "github-token-rotation";

/// [`rotate_github_token`] under the exclusive rotation lock. The lock is
/// taken BEFORE the bundle is read, so a process that waited sees the winner's
/// new refresh token rather than spending the dead one.
pub fn rotate_github_token_locked(
    lock_timeout: std::time::Duration,
    store: &dyn GitHubTokenStore,
    refresh: &dyn Fn(&str, &str) -> Result<GitHubRefreshResponse, String>,
    now: u64,
    debug: bool,
) -> Result<(RotationOutcome, Option<GitHubTokenBundle>), String> {
    let _lock = crate::resource_lock::acquire(GITHUB_ROTATION_LOCK, lock_timeout, debug)
        .map_err(|e| format!("another GitHub token rotation holds the lock: {e}"))?;
    rotate_github_token(store, refresh, now)
}

pub fn refresh_github_token_in_vault(debug: bool) -> Result<RotationOutcome, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();
    let store = VaultGitHubTokenStore { debug };
    let (outcome, _) = rotate_github_token_locked(
        std::time::Duration::from_secs(60),
        &store,
        &|client_id, refresh_token| perform_github_token_refresh(client_id, refresh_token, debug),
        now,
        debug,
    )?;
    Ok(outcome)
}

// ── Order 1461-8tyy: the token rotates itself before it expires ─────────────
//
// GitHub App user-to-server access tokens expire after 8 hours. The locked
// exchange above existed, but its only caller was the explicit
// `--refresh-github-token`, gated to a desktop session, so nothing ran it on a
// schedule: every 8 hours every mirror push was refused upstream until the
// operator re-seeded by hand (twice on 2026-09-28). The live spec
// (gh-auth-script, "Token Rotation and Expiration Management") already requires
// rotation within 30 minutes of expiry; this is the thing that runs it.

/// Rotate when the access token has this long or less to live.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const GITHUB_ROTATION_WINDOW_SECS: u64 = 30 * 60;
/// How often the resident scheduler asks.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const GITHUB_ROTATION_CHECK_EVERY: std::time::Duration =
    std::time::Duration::from_secs(15 * 60);

/// What one due-check did. Every variant is a verdict, never a silence.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DueCheck {
    /// Rotated; the new access token expires at this time. The refresh token's
    /// own expiry rides along for the 14-day warning.
    Rotated {
        expires_at: u64,
        refresh_expires_at: Option<u64>,
    },
    /// The stored token has more than the window left.
    NotDue {
        expires_at: u64,
        refresh_expires_at: Option<u64>,
    },
    /// A stored token with no expiry (a token-only login): nothing to schedule.
    NoExpiry,
    NoToken,
    NoRefreshToken,
    /// A forge never rotates: its policy cannot read the refresh token, and a
    /// second rotating process would race the host's.
    RefusedInForge,
}

#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
impl DueCheck {
    pub fn verdict(&self) -> String {
        match self {
            DueCheck::Rotated { expires_at, .. } => {
                format!("ok:github-token-rotation:rotated:expires_at={expires_at}")
            }
            DueCheck::NotDue { expires_at, .. } => {
                format!("ok:github-token-rotation:not-due:expires_at={expires_at}")
            }
            DueCheck::NoExpiry => "ok:github-token-rotation:no-expiry".into(),
            DueCheck::NoToken => "ok:github-token-rotation:no-token".into(),
            DueCheck::NoRefreshToken => "ok:github-token-rotation:no-refresh-token".into(),
            DueCheck::RefusedInForge => "skip:github-token-rotation:forge".into(),
        }
    }
}

/// Is a token that expires at `expires_at` due for rotation at `now`?
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn github_token_rotation_due(expires_at: u64, now: u64) -> bool {
    expires_at.saturating_sub(now) <= GITHUB_ROTATION_WINDOW_SECS
}

/// The due-check: under the exclusive rotation lock, read the stored bundle,
/// and exchange ONLY when it is inside the window.
///
/// THE DECISION IS MADE UNDER THE LOCK, which is what makes two concurrent
/// checks spend the single-use refresh token once: the second waits, re-reads
/// the winner's new `expires_at`, and finds nothing due. `lock_name` is a
/// parameter so tests never contend with a live tray's scheduler.
///
/// There is NO desktop-session gate here, deliberately: this spends the refresh
/// token only when the access token is due, and only under the host lock. The
/// session gate stays on the explicit forced rotation.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn rotate_github_token_if_due(
    store: &dyn GitHubTokenStore,
    refresh: &dyn Fn(&str, &str) -> Result<GitHubRefreshResponse, String>,
    now: u64,
    host_is_forge: bool,
    lock_name: &str,
    lock_timeout: std::time::Duration,
    debug: bool,
) -> Result<DueCheck, String> {
    if host_is_forge {
        return Ok(DueCheck::RefusedInForge);
    }
    let _lock = crate::resource_lock::acquire(lock_name, lock_timeout, debug)
        .map_err(|e| format!("github-token-rotation-failed:lock:{e}"))?;
    let Some(bundle) = store
        .read_bundle()
        .map_err(|e| format!("github-token-rotation-failed:read:{e}"))?
    else {
        return Ok(DueCheck::NoToken);
    };
    if bundle.refresh_token.as_deref().is_none_or(str::is_empty) {
        return Ok(DueCheck::NoRefreshToken);
    }
    let Some(expires_at) = bundle.expires_at else {
        return Ok(DueCheck::NoExpiry);
    };
    if !github_token_rotation_due(expires_at, now) {
        return Ok(DueCheck::NotDue {
            expires_at,
            refresh_expires_at: bundle.refresh_token_expires_at,
        });
    }
    match rotate_github_token(store, refresh, now) {
        Ok((RotationOutcome::Rotated, Some(b))) => Ok(DueCheck::Rotated {
            expires_at: b.expires_at.unwrap_or(0),
            refresh_expires_at: b.refresh_token_expires_at,
        }),
        Ok((RotationOutcome::NoToken, _)) => Ok(DueCheck::NoToken),
        Ok((RotationOutcome::NoRefreshToken, _)) => Ok(DueCheck::NoRefreshToken),
        Ok((RotationOutcome::Rotated, None)) => {
            Err("github-token-rotation-failed:no-bundle-returned".into())
        }
        // The exchange's errors already name the cause without echoing any
        // token (parse_github_refresh_response), and the old pair is intact
        // because nothing is written before the exchange succeeds.
        Err(e) => Err(format!("github-token-rotation-failed:{e}")),
    }
}

/// The live due-check: Vault, GitHub's token endpoint, the real clock, and the
/// host kind from the environment.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn github_token_due_check_live(debug: bool) -> Result<DueCheck, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_secs();
    let forge = std::env::var("TILLANDSIAS_HOST_KIND").as_deref() == Ok("forge");
    let store = VaultGitHubTokenStore { debug };
    rotate_github_token_if_due(
        &store,
        &|client_id, refresh_token| perform_github_token_refresh(client_id, refresh_token, debug),
        now,
        forge,
        GITHUB_ROTATION_LOCK,
        std::time::Duration::from_secs(60),
        debug,
    )
}

/// The delay before the next check: the regular interval after a verdict, and
/// a backoff after a failure (1 min doubling, capped at the interval), so a
/// transient failure is retried well before the token dies.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn github_rotation_next_delay(
    last: &Result<DueCheck, String>,
    prev_backoff: std::time::Duration,
) -> std::time::Duration {
    match last {
        Ok(_) => GITHUB_ROTATION_CHECK_EVERY,
        Err(_) => {
            let next = if prev_backoff.is_zero() {
                std::time::Duration::from_secs(60)
            } else {
                prev_backoff * 2
            };
            next.min(GITHUB_ROTATION_CHECK_EVERY)
        }
    }
}

/// Warn this many days before the refresh token expires (gh-auth-script:
/// "Fourteen days before refresh_token_expires_at the tray MUST tell the
/// operator to run tillandsias --github-login").
pub const GITHUB_REFRESH_WARN_DAYS: u64 = 14;

/// Days left on the refresh token when it is inside the warning window, else
/// None. An expired refresh token answers Some(0): only a new login fixes it.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn github_refresh_expiry_warning(refresh_expires_at: Option<u64>, now: u64) -> Option<u64> {
    let exp = refresh_expires_at?;
    let left = exp.saturating_sub(now);
    (left <= GITHUB_REFRESH_WARN_DAYS * 86_400).then_some(left / 86_400)
}

/// The operator-facing line for the warning.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn github_refresh_expiry_message(days_left: u64) -> String {
    if days_left == 0 {
        "GitHub sign-in has EXPIRED: run `tillandsias --github-login` to keep pushes working".into()
    } else {
        format!(
            "GitHub sign-in expires in {days_left} day(s): run `tillandsias --github-login` before then to keep pushes working"
        )
    }
}

/// True at most once per UTC day: the scheduler checks every 15 minutes and a
/// warning every 15 minutes would be noise the operator learns to ignore.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn should_warn_today(last_warned_day: &mut Option<u64>, now: u64) -> bool {
    let today = now / 86_400;
    if *last_warned_day == Some(today) {
        return false;
    }
    *last_warned_day = Some(today);
    true
}

/// The accountability event the spec requires for every rotation
/// (gh-auth-script "Token Rotation and Expiration Management" ->
/// spec:gh-auth-script; secret-rotation is tombstoned, 1397-eppt). Its own
/// operation name, so an audit can tell an automatic rotation from the
/// explicit `github_token_refresh`.
// @trace spec:gh-auth-script, order:1489-8qd6
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn audit_github_token_auto_rotation(outcome: &str) {
    tracing::info!(
        accountability = true,
        category = "secrets",
        spec = "gh-auth-script",
        operation = "github_token_auto_rotation",
        secret_name = "github-token",
        outcome = outcome,
        "GitHub token auto-rotation: {outcome}"
    );
}

/// One scheduler per process (1461-8tyy): the tray starts it, and so does every
/// lane launch through `ensure_enclave_for_project`; a long-lived tray that
/// launches many lanes must not accumulate a thread per launch. Returns true
/// exactly once per process.
fn claim_github_rotation_scheduler_slot() -> bool {
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    !STARTED.swap(true, std::sync::atomic::Ordering::SeqCst)
}

/// Start the resident rotation scheduler on its own thread: a check at start,
/// then per [`github_rotation_next_delay`]. Idempotent per process.
///
/// WHO STARTS IT, and why that covers every regime that pushes:
/// - the Linux tray, at start;
/// - the guest's resident service on macOS/Windows;
/// - EVERY LANE LAUNCH (`ensure_enclave_for_project`), so a bare-metal Linux
///   host with no tray — one that only runs `tillandsias --bash <project>` and
///   the mirror — rotates too. The mirror lives only while a lane is open
///   (1448-yt96), and the lane process lives exactly that long, so the thread
///   is alive whenever something can push.
///
/// Concurrent schedulers (a tray plus lanes, several lanes) are safe: the
/// due-check decides under the host-wide rotation lock, so one exchange
/// happens per due window. Never effective in a forge (the check refuses and
/// the thread ends).
pub fn spawn_github_token_rotation_scheduler(
    debug: bool,
    on_refresh_expiring: Option<Box<dyn Fn(String) + Send + 'static>>,
) {
    if !claim_github_rotation_scheduler_slot() {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("github-token-rotation".into())
        .spawn(move || {
            let mut backoff = std::time::Duration::ZERO;
            let mut last_warned_day: Option<u64> = None;
            loop {
                let out = github_token_due_check_live(debug);
                // The 14-day refresh-expiry warning, at most once a day.
                if let Ok(
                    DueCheck::Rotated {
                        refresh_expires_at, ..
                    }
                    | DueCheck::NotDue {
                        refresh_expires_at, ..
                    },
                ) = &out
                {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    if let Some(days) = github_refresh_expiry_warning(*refresh_expires_at, now)
                        && should_warn_today(&mut last_warned_day, now)
                    {
                        let msg = github_refresh_expiry_message(days);
                        eprintln!("[tillandsias] warn:github-refresh-expiring:{days}d: {msg}");
                        if let Some(cb) = &on_refresh_expiring {
                            cb(msg);
                        }
                    }
                }
                match &out {
                    Ok(DueCheck::RefusedInForge) => return,
                    Ok(v @ DueCheck::Rotated { .. }) => {
                        audit_github_token_auto_rotation("rotated");
                        eprintln!("[tillandsias] {}", v.verdict());
                    }
                    Ok(v) if debug => eprintln!("[tillandsias] {}", v.verdict()),
                    Ok(_) => {}
                    Err(e) => {
                        audit_github_token_auto_rotation("failed");
                        eprintln!("[tillandsias] blocked:{e}");
                    }
                }
                let delay = github_rotation_next_delay(&out, backoff);
                backoff = if out.is_err() {
                    delay
                } else {
                    std::time::Duration::ZERO
                };
                std::thread::sleep(delay);
            }
        });
}

// ── Order 1505-iysn: the Cloudflare OAuth bundle in Vault, and its rotation ──
//
// @trace order:1505-iysn, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 2)
// @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
//
// SIBLINGS of the GitHub items above, not a generalization of them (design
// Decision 2): the GitHub code is under a live p0 and the two providers have
// different lifetimes. What is REUSED is the machinery: the same Vault (root
// token, stability lease, read-back verification), the same host-wide
// advisory lock (`resource_lock`), the same "refresh record first" ordering
// rule and the same three resident entry points (tray start, every lane
// launch, the guest listener).
//
// What is STRICTER than the GitHub sibling, deliberately, because this is a
// new credential with no legacy callers:
// - The live store FAILS CLOSED: an unreachable, sealed or refusing Vault is a
//   named error (`vault-unavailable`, `vault-sealed`, `vault-unauthorized`),
//   never "no token", and a refresh-path read error is never read as "no
//   refresh token". There is no file, keychain or plaintext fallback anywhere
//   on this path.
// - No error string, verdict or `Debug` output carries token bytes: Vault and
//   OAuth failures are reduced to fixed reason tokens before they leave this
//   block (`cloudflare_refresh_failure_reason`, `cloudflare_vault_reason`),
//   and `CloudflareTokenBundle`'s `Debug` redacts both tokens.
// - The token endpoint must be https (plain http only to loopback, which is
//   where the fixtures' fake lives), so the refresh token is never sent in
//   clear to a host a discovery document named.

/// Where the Cloudflare OAuth credential lives in Vault. TWO PATHS for the
/// GitHub reason: KV v2 policies are path-scoped, not field-scoped, so the
/// long-lived refresh token gets a path no reader of the access token can be
/// granted by accident. Only the host's resident process (root token; the
/// `tray` policy's `secret/*`) reads the refresh path; no forge, mirror,
/// inference or login-container policy names anything under
/// `secret/data/cloudflare/` (asserted by
/// `cloudflare_token_rotation_policies_keep_forges_out`).
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const CLOUDFLARE_TOKEN_PATH: &str = "secret/cloudflare/token";
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const CLOUDFLARE_REFRESH_PATH: &str = "secret/cloudflare/refresh";

/// The Cloudflare bundle as the two records hold it.
///
/// `expires_at` is `Some` only when Cloudflare reported `expires_in` (token
/// lifetimes are undocumented, design Risks): a bundle without it is never
/// rotated on a guess, and the surfaces say "expiry unknown".
///
/// NO `Display`, and a hand-written `Debug` that redacts both tokens: a bundle
/// that reaches a log line, a panic message or an `{:?}` in an error must not
/// carry a credential with it.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
#[derive(Clone, Default, PartialEq, Eq)]
pub struct CloudflareTokenBundle {
    pub access_token: String,
    pub expires_at: Option<u64>,
    pub account_id: Option<String>,
    pub client_id: String,
    pub refresh_token: Option<String>,
    pub refresh_token_expires_at: Option<u64>,
}

impl std::fmt::Debug for CloudflareTokenBundle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CloudflareTokenBundle")
            .field("access_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("account_id", &self.account_id)
            .field("client_id", &self.client_id)
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .field("refresh_token_expires_at", &self.refresh_token_expires_at)
            .finish()
    }
}

/// The token-path record: `access_token`, `expires_at` (when known),
/// `account_id` (when known), `client_id`. Never the refresh token.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_token_record(b: &CloudflareTokenBundle) -> serde_json::Value {
    let mut map = serde_json::Map::new();
    map.insert("access_token".into(), b.access_token.clone().into());
    if let Some(exp) = b.expires_at {
        map.insert("expires_at".into(), exp.into());
    }
    if let Some(acct) = &b.account_id {
        map.insert("account_id".into(), acct.clone().into());
    }
    map.insert("client_id".into(), b.client_id.clone().into());
    serde_json::Value::Object(map)
}

/// The refresh-path record: `refresh_token`, `refresh_token_expires_at` (when
/// reported), `client_id`. `None` for a bundle without a refresh token.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_refresh_record(b: &CloudflareTokenBundle) -> Option<serde_json::Value> {
    let rt = b.refresh_token.as_ref().filter(|s| !s.is_empty())?;
    let mut map = serde_json::Map::new();
    map.insert("refresh_token".into(), rt.clone().into());
    if let Some(rexp) = b.refresh_token_expires_at {
        map.insert("refresh_token_expires_at".into(), rexp.into());
    }
    map.insert("client_id".into(), b.client_id.clone().into());
    Some(serde_json::Value::Object(map))
}

/// Vault as the Cloudflare rotation sees it. A trait so the ordering, lock and
/// failure rules are testable against an in-memory store; the only production
/// implementation is [`VaultCloudflareTokenStore`], and nothing in production
/// selects another one (no env switch, no fallback store).
///
/// Errors are REASON TOKENS (`vault-sealed`, `write-not-confirmed`, ...), never
/// a Vault response body and never a record's contents.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub trait CloudflareTokenStore {
    /// `Ok(None)` ONLY when Vault answered that the token record does not
    /// exist. Unreachable, sealed or refusing is `Err`.
    fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String>;
    /// Write one record and CONFIRM it (read back and compare); `Ok` means the
    /// record is durably in Vault.
    fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String>;
    /// Destroy one record, EVERY version (1505-kc5f `--cloudflare-logout`), and
    /// CONFIRM it is gone. Idempotent: an absent record is `Ok`. Unreachable,
    /// sealed or refusing is `Err` — never read as "already deleted".
    fn delete_record(&self, path: &str) -> Result<(), String>;
}

/// Delete the Cloudflare bundle (1505-kc5f `--cloudflare-logout`): the
/// long-lived REFRESH record first, then the token record, and NOTHING else —
/// `secret/cloudflare/mesh` (the host's fleet-vpn service token) is not this
/// bundle and is never touched here.
///
/// Errors name which record is still present:
/// `refresh-record-delete-failed:<reason>` (both records remain) or
/// `token-record-delete-failed:<reason>` (the refresh record is gone, so the
/// remaining access token can no longer be renewed and dies at its expiry).
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn delete_cloudflare_token_bundle(store: &dyn CloudflareTokenStore) -> Result<(), String> {
    store
        .delete_record(CLOUDFLARE_REFRESH_PATH)
        .map_err(|e| format!("refresh-record-delete-failed:{e}"))?;
    store
        .delete_record(CLOUDFLARE_TOKEN_PATH)
        .map_err(|e| format!("token-record-delete-failed:{e}"))
}

/// How many times the refresh-record write is attempted before the rotation
/// gives up. Once Cloudflare has answered a refresh, the OLD refresh token is
/// spent (refresh-token rotation) and the new one exists only in this
/// process: a transient Vault hiccup at that moment must not cost the
/// operator a login. The write is idempotent, so retrying it is safe.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
const CLOUDFLARE_REFRESH_WRITE_ATTEMPTS: u32 = 3;

/// Write a bundle: the REFRESH record first, then the token record — the
/// GitHub failure rule ([`store_github_token_bundle`]).
///
/// - Refresh write fails (after [`CLOUDFLARE_REFRESH_WRITE_ATTEMPTS`]):
///   NOTHING in Vault changed; the old pair is intact. Error
///   `refresh-record-write-failed:<reason>`.
/// - Token write fails afterwards: Vault holds the NEW refresh token and the
///   OLD access-token record, whose `expires_at` is still inside the window,
///   so the next due-check rotates again with the new refresh token. At no
///   point is neither credential stored. Error
///   `token-record-write-failed:<reason>`.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn store_cloudflare_token_bundle(
    store: &dyn CloudflareTokenStore,
    bundle: &CloudflareTokenBundle,
) -> Result<(), String> {
    if bundle.access_token.is_empty() || bundle.client_id.is_empty() {
        return Err("bundle-incomplete".into());
    }
    if let Some(refresh) = cloudflare_refresh_record(bundle) {
        let mut last = String::new();
        let mut stored = false;
        for attempt in 1..=CLOUDFLARE_REFRESH_WRITE_ATTEMPTS {
            match store.write_record(CLOUDFLARE_REFRESH_PATH, refresh.clone()) {
                Ok(()) => {
                    stored = true;
                    break;
                }
                Err(e) => {
                    last = e;
                    if attempt < CLOUDFLARE_REFRESH_WRITE_ATTEMPTS {
                        std::thread::sleep(std::time::Duration::from_millis(
                            250 * u64::from(attempt),
                        ));
                    }
                }
            }
        }
        if !stored {
            return Err(format!("refresh-record-write-failed:{last}"));
        }
    }
    store
        .write_record(CLOUDFLARE_TOKEN_PATH, cloudflare_token_record(bundle))
        .map_err(|e| format!("token-record-write-failed:{e}"))
}

/// A Vault client error reduced to a fixed reason token. The variants' payloads
/// (Vault response bodies, `missing data.data in response: {envelope}`) are
/// DROPPED: an envelope can hold a record's contents.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_vault_reason(e: &VaultError) -> &'static str {
    match e {
        VaultError::Network(_) => "vault-unavailable",
        VaultError::Unauthorized(_) => "vault-unauthorized",
        VaultError::Sealed(_) => "vault-sealed",
        VaultError::NotFound(_) => "vault-not-found",
        VaultError::Other(_) => "vault-error",
    }
}

/// The live store: the same Vault, root token, stability lease and client the
/// GitHub store uses. Fails closed on every path (see [`CloudflareTokenStore`]).
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub struct VaultCloudflareTokenStore {
    pub debug: bool,
}

#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
impl VaultCloudflareTokenStore {
    fn client(
        &self,
    ) -> Result<
        (
            crate::resource_lock::ResourceLockGuard,
            crate::RuntimeOrHandle,
            VaultClient,
        ),
        String,
    > {
        let debug = self.debug;
        let stability = vault_stability_lease(debug).map_err(|_| "vault-lease".to_string())?;
        let rt = tokio_runtime().map_err(|_| "vault-runtime".to_string())?;
        let root_token = read_and_handover_root_token(debug)
            .map_err(|_| "vault-root-token-unavailable".to_string())?;
        let client = vault_client(&vault_api_base_url(), &root_token, debug)
            .map_err(|_| "vault-unavailable".to_string())?;
        Ok((stability, rt, client))
    }
}

impl CloudflareTokenStore for VaultCloudflareTokenStore {
    fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
        if !container_running(VAULT_CONTAINER_NAME) {
            return Err("vault-unavailable".into());
        }
        let (_stability, rt, client) = self.client()?;
        let token_rec = match rt.block_on(client.read_secret(CLOUDFLARE_TOKEN_PATH)) {
            Ok(v) => v,
            Err(VaultError::NotFound(_)) => return Ok(None),
            Err(e) => return Err(cloudflare_vault_reason(&e).into()),
        };
        let access_token = token_rec["access_token"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("token-record-malformed")?
            .to_string();
        // An absent refresh record is a legitimate state; any OTHER read
        // failure is not "absent" and is reported.
        let refresh_rec = match rt.block_on(client.read_secret(CLOUDFLARE_REFRESH_PATH)) {
            Ok(v) => Some(v),
            Err(VaultError::NotFound(_)) => None,
            Err(e) => return Err(format!("refresh-{}", cloudflare_vault_reason(&e))),
        };
        let client_id = token_rec["client_id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(crate::cloudflare_oauth::client_id);
        Ok(Some(CloudflareTokenBundle {
            access_token,
            expires_at: token_rec["expires_at"].as_u64(),
            account_id: token_rec["account_id"].as_str().map(str::to_string),
            client_id,
            refresh_token: refresh_rec
                .as_ref()
                .and_then(|r| r["refresh_token"].as_str())
                .filter(|s| !s.is_empty())
                .map(str::to_string),
            refresh_token_expires_at: refresh_rec
                .as_ref()
                .and_then(|r| r["refresh_token_expires_at"].as_u64()),
        }))
    }

    fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
        if !container_running(VAULT_CONTAINER_NAME) {
            // Bring Vault itself up (the same idempotent path `--init` uses);
            // if that fails the write is REFUSED. There is no other store.
            ensure_vault_running(self.debug).map_err(|_| "vault-unavailable".to_string())?;
        }
        let (_stability, rt, client) = self.client()?;
        rt.block_on(client.write_secret(path, value.clone()))
            .map_err(|e| cloudflare_vault_reason(&e).to_string())?;
        let read_back = rt
            .block_on(client.read_secret(path))
            .map_err(|e| format!("write-not-confirmed:{}", cloudflare_vault_reason(&e)))?;
        if read_back != value {
            return Err("write-not-confirmed:mismatch".into());
        }
        Ok(())
    }

    fn delete_record(&self, path: &str) -> Result<(), String> {
        // No auto-start here: a Vault that is not running holds records this
        // call cannot reach, so "deleted" would be a lie. Refuse instead.
        if !container_running(VAULT_CONTAINER_NAME) {
            return Err("vault-unavailable".into());
        }
        let (_stability, rt, client) = self.client()?;
        rt.block_on(client.delete_secret_all_versions(path))
            .map_err(|e| cloudflare_vault_reason(&e).to_string())?;
        match rt.block_on(client.read_secret(path)) {
            Err(VaultError::NotFound(_)) => Ok(()),
            Ok(_) => Err("delete-not-confirmed:still-present".into()),
            Err(e) => Err(format!(
                "delete-not-confirmed:{}",
                cloudflare_vault_reason(&e)
            )),
        }
    }
}

/// A `cloudflare_oauth` refresh failure reduced to a reason token. The core's
/// errors are shaped `refused:cloudflare-login:token-exchange-http-<status>:<code>`
/// (code from the server's JSON), `...:token-response-parse:<serde error>` (a
/// serde type error can QUOTE the offending value, e.g. a token sent as a
/// number) or a transport error; only the status and a plain-identifier OAuth
/// error code survive.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_refresh_failure_reason(err: &str) -> String {
    const HTTP: &str = "refused:cloudflare-login:token-exchange-http-";
    if let Some(rest) = err.strip_prefix(HTTP) {
        let (status, code) = rest.split_once(':').unwrap_or((rest, ""));
        let status =
            if (1..=3).contains(&status.len()) && status.bytes().all(|b| b.is_ascii_digit()) {
                status
            } else {
                "unknown"
            };
        let code = if !code.is_empty()
            && code.len() <= 64
            && code.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        {
            code
        } else {
            "unrecognised-error-code"
        };
        return format!("refresh-refused:http-{status}:{code}");
    }
    if err.starts_with("refused:cloudflare-login:token-response-parse") {
        return "refresh-response-unusable".into();
    }
    "refresh-transport".into()
}

/// May a refresh token be POSTed to this endpoint? https anywhere; plain http
/// only to a loopback host (the fixtures' fake). A userinfo component
/// (`http://127.0.0.1@elsewhere/`) is refused. The login (1505-kc5f) applies
/// the same rule to every endpoint it sends a code, verifier or token to.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub(crate) fn cloudflare_token_endpoint_is_safe(endpoint: &str) -> bool {
    if endpoint.starts_with("https://") {
        return true;
    }
    let Some(rest) = endpoint.strip_prefix("http://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') {
        return false;
    }
    let host = if let Some(v6) = authority.strip_prefix('[') {
        v6.split(']').next().unwrap_or("")
    } else {
        authority.split(':').next().unwrap_or("")
    };
    matches!(host, "127.0.0.1" | "localhost" | "::1")
}

/// The token endpoint, read from the OpenID discovery document at `base_url`
/// (design Decision 1: endpoints come from discovery, never a compiled path).
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_token_endpoint(
    http: &dyn crate::cloudflare_oauth::HttpClient,
    base_url: &str,
) -> Result<String, String> {
    let url = format!(
        "{}/.well-known/openid-configuration",
        base_url.trim_end_matches('/')
    );
    let resp = http
        .get(&url)
        .map_err(|_| "discovery-unreachable".to_string())?;
    if resp.status != 200 {
        return Err(format!("discovery-http-{}", resp.status));
    }
    let doc: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|_| "discovery-unusable".to_string())?;
    let endpoint = doc["token_endpoint"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("discovery-unusable:no-token-endpoint")?;
    if !cloudflare_token_endpoint_is_safe(endpoint) {
        return Err("token-endpoint-not-https".into());
    }
    Ok(endpoint.to_string())
}

/// One `grant_type=refresh_token` exchange through `cloudflare_oauth::refresh`
/// against the endpoint discovery names. Errors are reason tokens only.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn perform_cloudflare_token_refresh(
    http: &dyn crate::cloudflare_oauth::HttpClient,
    base_url: &str,
    client_id: &str,
    refresh_token: &str,
) -> Result<crate::cloudflare_oauth::Bundle, String> {
    let endpoint = cloudflare_token_endpoint(http, base_url)?;
    let mut bundle = crate::cloudflare_oauth::refresh(http, &endpoint, client_id, refresh_token)
        .map_err(|e| cloudflare_refresh_failure_reason(&e))?;
    if bundle.access_token.is_empty() {
        return Err("refresh-response-unusable".into());
    }
    if bundle.refresh_token.as_deref() == Some("") {
        bundle.refresh_token = None;
    }
    Ok(bundle)
}

/// The bundle a successful refresh produces. A response without a new refresh
/// token (a server that does not rotate them) keeps the old one, per RFC 6749
/// §6; a NEW refresh token's lifetime is not reported, so it is recorded as
/// unknown rather than inherited from the old one.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_rotated_bundle(
    old: &CloudflareTokenBundle,
    resp: crate::cloudflare_oauth::Bundle,
    now: u64,
) -> CloudflareTokenBundle {
    let (refresh_token, refresh_token_expires_at) = match resp.refresh_token {
        Some(new) if !new.is_empty() => (Some(new), None),
        _ => (old.refresh_token.clone(), old.refresh_token_expires_at),
    };
    CloudflareTokenBundle {
        access_token: resp.access_token,
        expires_at: resp.expires_in.map(|s| now.saturating_add(s)),
        account_id: old.account_id.clone(),
        client_id: old.client_id.clone(),
        refresh_token,
        refresh_token_expires_at,
    }
}

/// Rotate when the access token has this long or less to live (design
/// Decision 2: `expires_at - now <= 30 min`).
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const CLOUDFLARE_ROTATION_WINDOW_SECS: u64 = 30 * 60;
/// How often the resident scheduler asks.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const CLOUDFLARE_ROTATION_CHECK_EVERY: std::time::Duration =
    std::time::Duration::from_secs(15 * 60);
/// The host-wide advisory lock every Cloudflare rotation takes.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub const CLOUDFLARE_ROTATION_LOCK: &str = "cloudflare-token-rotation";

/// What one Cloudflare due-check did. Every variant is a verdict.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloudflareDueCheck {
    /// Rotated; the new access token's expiry when Cloudflare reported one.
    Rotated {
        expires_at: Option<u64>,
    },
    NotDue {
        expires_at: u64,
    },
    /// A stored token whose lifetime was never reported: never rotated on a
    /// guess.
    ExpiryUnknown,
    NoToken,
    NoRefreshToken,
    /// A forge never rotates: no forge policy can read either path, and a
    /// second rotating process would race the host's.
    RefusedInForge,
}

#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
impl CloudflareDueCheck {
    pub fn verdict(&self) -> String {
        match self {
            CloudflareDueCheck::Rotated {
                expires_at: Some(e),
            } => format!("ok:cloudflare-token-rotation:rotated:expires_at={e}"),
            CloudflareDueCheck::Rotated { expires_at: None } => {
                "ok:cloudflare-token-rotation:rotated:expiry-unknown".into()
            }
            CloudflareDueCheck::NotDue { expires_at } => {
                format!("ok:cloudflare-token-rotation:not-due:expires_at={expires_at}")
            }
            CloudflareDueCheck::ExpiryUnknown => {
                "ok:cloudflare-token-rotation:expiry-unknown".into()
            }
            CloudflareDueCheck::NoToken => "ok:cloudflare-token-rotation:no-token".into(),
            CloudflareDueCheck::NoRefreshToken => {
                "ok:cloudflare-token-rotation:no-refresh-token".into()
            }
            CloudflareDueCheck::RefusedInForge => "skip:cloudflare-token-rotation:forge".into(),
        }
    }
}

/// Is a token that expires at `expires_at` due for rotation at `now`?
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn cloudflare_token_rotation_due(expires_at: u64, now: u64) -> bool {
    expires_at.saturating_sub(now) <= CLOUDFLARE_ROTATION_WINDOW_SECS
}

/// What the operator does about a failed rotation, by reason.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_rotation_remedy(reason: &str) -> &'static str {
    if reason.starts_with("refresh-record-write-failed") {
        "the new sign-in could not be stored in Vault and the old refresh token is spent: bring Vault up with `tillandsias --init`, then run `tillandsias --cloudflare-login`"
    } else if reason.starts_with("token-record-write-failed") {
        "the new refresh token IS stored; the access-token write is retried automatically"
    } else if reason.starts_with("refresh-refused:") && reason.ends_with(":invalid_grant") {
        "Cloudflare no longer accepts the stored sign-in: run `tillandsias --cloudflare-login`; both stored records were left untouched"
    } else if reason.starts_with("read:") {
        "Vault is unreachable, sealed or refused the host's token: run `tillandsias --init`; retried automatically"
    } else if reason == "lock" {
        "another rotation holds the host lock; retried automatically"
    } else {
        "nothing was written; retried automatically with backoff"
    }
}

/// The named failure verdict: `cloudflare-token-rotation-failed:<reason>` plus
/// the remedy. Callers print it as `blocked:<this>`.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn cloudflare_rotation_failure(reason: &str) -> String {
    format!(
        "cloudflare-token-rotation-failed:{reason} (remedy: {})",
        cloudflare_rotation_remedy(reason)
    )
}

/// The Cloudflare sibling of [`rotate_github_token_locked`]: take the
/// exclusive host-wide lock, THEN read the stored bundle, decide, and exchange
/// only when it is inside the window.
///
/// THE DECISION IS MADE UNDER THE LOCK: a second concurrent check waits, reads
/// the winner's new `expires_at`, and finds nothing due, so a refresh token is
/// spent once per window. Nothing is written before the exchange succeeds, so
/// a refused exchange leaves both records exactly as they were.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn rotate_cloudflare_token_locked(
    store: &dyn CloudflareTokenStore,
    refresh: &dyn Fn(&str, &str) -> Result<crate::cloudflare_oauth::Bundle, String>,
    now: u64,
    lock_name: &str,
    lock_timeout: std::time::Duration,
    debug: bool,
) -> Result<CloudflareDueCheck, String> {
    let _lock = crate::resource_lock::acquire(lock_name, lock_timeout, debug)
        .map_err(|_| cloudflare_rotation_failure("lock"))?;
    let Some(bundle) = store
        .read_bundle()
        .map_err(|e| cloudflare_rotation_failure(&format!("read:{e}")))?
    else {
        return Ok(CloudflareDueCheck::NoToken);
    };
    let Some(old_refresh) = bundle.refresh_token.as_deref().filter(|s| !s.is_empty()) else {
        return Ok(CloudflareDueCheck::NoRefreshToken);
    };
    let Some(expires_at) = bundle.expires_at else {
        return Ok(CloudflareDueCheck::ExpiryUnknown);
    };
    if !cloudflare_token_rotation_due(expires_at, now) {
        return Ok(CloudflareDueCheck::NotDue { expires_at });
    }
    let resp =
        refresh(&bundle.client_id, old_refresh).map_err(|e| cloudflare_rotation_failure(&e))?;
    let rotated = cloudflare_rotated_bundle(&bundle, resp, now);
    store_cloudflare_token_bundle(store, &rotated).map_err(|e| cloudflare_rotation_failure(&e))?;
    Ok(CloudflareDueCheck::Rotated {
        expires_at: rotated.expires_at,
    })
}

/// The due-check: a forge refuses BEFORE touching the lock or the store;
/// anywhere else, [`rotate_cloudflare_token_locked`]. `lock_name` is a
/// parameter so tests never contend with a live tray's scheduler.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn rotate_cloudflare_token_if_due(
    store: &dyn CloudflareTokenStore,
    refresh: &dyn Fn(&str, &str) -> Result<crate::cloudflare_oauth::Bundle, String>,
    now: u64,
    host_is_forge: bool,
    lock_name: &str,
    lock_timeout: std::time::Duration,
    debug: bool,
) -> Result<CloudflareDueCheck, String> {
    if host_is_forge {
        return Ok(CloudflareDueCheck::RefusedInForge);
    }
    rotate_cloudflare_token_locked(store, refresh, now, lock_name, lock_timeout, debug)
}

/// `TILLANDSIAS_HOST_KIND=forge` means this process runs inside a forge.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn host_kind_is_forge(host_kind: Option<&str>) -> bool {
    host_kind == Some("forge")
}

/// The live due-check: Vault, the token endpoint discovery names at
/// `TILLANDSIAS_CLOUDFLARE_BASE_URL` (default dash.cloudflare.com), the real
/// clock, and the host kind from the environment.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn cloudflare_token_due_check_live(debug: bool) -> Result<CloudflareDueCheck, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| cloudflare_rotation_failure("clock"))?
        .as_secs();
    let forge = host_kind_is_forge(std::env::var("TILLANDSIAS_HOST_KIND").ok().as_deref());
    let store = VaultCloudflareTokenStore { debug };
    let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
    let base_url = crate::cloudflare_oauth::base_url();
    rotate_cloudflare_token_if_due(
        &store,
        &|client_id, refresh_token| {
            perform_cloudflare_token_refresh(&http, &base_url, client_id, refresh_token)
        },
        now,
        forge,
        CLOUDFLARE_ROTATION_LOCK,
        std::time::Duration::from_secs(60),
        debug,
    )
}

/// The regular interval after a verdict; after a failure, 1 min doubling,
/// capped at the interval.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn cloudflare_rotation_next_delay(
    failed: bool,
    prev_backoff: std::time::Duration,
) -> std::time::Duration {
    if !failed {
        return CLOUDFLARE_ROTATION_CHECK_EVERY;
    }
    let next = if prev_backoff.is_zero() {
        std::time::Duration::from_secs(60)
    } else {
        prev_backoff * 2
    };
    next.min(CLOUDFLARE_ROTATION_CHECK_EVERY)
}

/// The accountability event for every automatic rotation. `outcome` is
/// `rotated` or `failed` — never a reason string that could carry data.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn audit_cloudflare_token_auto_rotation(outcome: &'static str) {
    tracing::info!(
        accountability = true,
        category = "secrets",
        spec = "cloudflare-auth",
        operation = "cloudflare_token_auto_rotation",
        secret_name = "cloudflare-token",
        outcome = outcome,
        "Cloudflare token auto-rotation: {outcome}"
    );
}

/// One Cloudflare scheduler per process (the tray and every lane launch both
/// call the spawn). Returns true exactly once per process.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
fn claim_cloudflare_rotation_scheduler_slot() -> bool {
    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    !STARTED.swap(true, std::sync::atomic::Ordering::SeqCst)
}

/// Start the resident Cloudflare rotation scheduler on its own thread: a check
/// at start, then per [`cloudflare_rotation_next_delay`]. Idempotent per
/// process. Called from the SAME three entry points as
/// [`spawn_github_token_rotation_scheduler`] — the Linux tray at start, every
/// lane launch (`ensure_enclave_for_project`) and the guest listener
/// (`maybe_spawn_vsock_listener`) — pinned by
/// scripts/test-cloudflare-token-rotation.sh arm 6. Never effective in a
/// forge (the check refuses and the thread ends).
///
/// A failure prints `blocked:cloudflare-token-rotation-failed:<reason> (remedy:
/// ...)` when it first appears or changes (every time under `--debug`), is
/// audited every time, and is retried with backoff.
#[cfg_attr(not(any(feature = "tray", feature = "listen-vsock")), allow(dead_code))]
pub fn spawn_cloudflare_token_rotation_scheduler(debug: bool) {
    if !claim_cloudflare_rotation_scheduler_slot() {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("cloudflare-token-rotation".into())
        .spawn(move || {
            let mut backoff = std::time::Duration::ZERO;
            let mut last_failure: Option<String> = None;
            loop {
                let out = cloudflare_token_due_check_live(debug);
                match &out {
                    Ok(CloudflareDueCheck::RefusedInForge) => return,
                    Ok(v @ CloudflareDueCheck::Rotated { .. }) => {
                        audit_cloudflare_token_auto_rotation("rotated");
                        eprintln!("[tillandsias] {}", v.verdict());
                        last_failure = None;
                    }
                    Ok(v) => {
                        if debug {
                            eprintln!("[tillandsias] {}", v.verdict());
                        }
                        last_failure = None;
                    }
                    Err(e) => {
                        audit_cloudflare_token_auto_rotation("failed");
                        if debug || last_failure.as_deref() != Some(e.as_str()) {
                            eprintln!("[tillandsias] blocked:{e}");
                        }
                        last_failure = Some(e.clone());
                    }
                }
                let delay = cloudflare_rotation_next_delay(out.is_err(), backoff);
                backoff = if out.is_err() {
                    delay
                } else {
                    std::time::Duration::ZERO
                };
                std::thread::sleep(delay);
            }
        });
    if spawned.is_err() {
        eprintln!(
            "[tillandsias] blocked:cloudflare-token-rotation-failed:thread-spawn (remedy: restart tillandsias; nothing rotates the Cloudflare token in this process)"
        );
    }
}

/// In-container address of the Vault TLS listener. The Vault server listens on
/// the container loopback at :8200; `podman exec` does NOT inherit the
/// entrypoint's environment, so every exec'd `vault` CLI call must set this (and
/// the token + skip-verify) explicitly or it fails with a TLS "unknown
/// authority" error against the self-signed cert.
const VAULT_EXEC_ADDR: &str = "https://127.0.0.1:8200";

/// Build a `podman exec` Command that runs the in-container `vault` CLI with the
/// environment the CLI needs but `podman exec` does not inherit:
/// - `VAULT_ADDR`        — the loopback TLS listener (the entrypoint sets this; exec does not)
/// - `VAULT_SKIP_VERIFY` — the cert is self-signed; the request never leaves the
///   container loopback, so verification is moot here (not a network hop)
/// - `VAULT_TOKEN`       — auth; delivered on STDIN and exported by a one-line
///   `sh` shim INSIDE the container, so it never appears in the exec argv (not
///   visible in `ps`) and never depends on the podman process's environment
///   reaching the container.
///
/// WHY STDIN, AND NOT THE NAME-ONLY `-e VAULT_TOKEN` PASS-THROUGH THIS USED TO
/// BE. Inside the tillandsias-builder toolbox — the namespace `./build.sh
/// --ci-full` runs in — `podman` is a wrapper that runs the HOST binary through
/// flatpak-spawn, which forwards stdio, cwd and the exit code but NOT the
/// caller's environment. Measured on macuahuitl 2026-09-18: `FOO=x podman exec
/// -e FOO … env` printed nothing inside the container while `-e FOO=explicit`
/// arrived intact. So the pass-through delivered no token, every vault read
/// from the release gate answered 403, and the forge launch died at
/// `opencode_auth_content_available` — the three forge-lane reds of the
/// v56.9.18.1 ci4 run. stdin crosses that boundary; the environment does not.
///
/// Without VAULT_ADDR/VAULT_SKIP_VERIFY, `vault kv get` fails first with a TLS
/// error and then a missing-client-token error — which silently broke every
/// host-side credential read after the move from the HTTP Vault client to
/// `podman exec`.
///
/// `discard_stdout` drops the CLI's stdout INSIDE the container, so a
/// presence-only probe never lets a secret's value reach launcher memory.
///
/// @trace spec:tillandsias-vault, plan/issues/vault-exec-env-regression-2026-06-27.md
fn vault_exec_command(
    vault_args: &[&str],
    discard_stdout: bool,
) -> tillandsias_podman::SyncPodmanCommand {
    let mut cmd = podman_cmd_sync();
    cmd.args([
        "exec",
        "-i",
        "-e",
        &format!("VAULT_ADDR={VAULT_EXEC_ADDR}"),
        "-e",
        "VAULT_SKIP_VERIFY=true",
        VAULT_CONTAINER_NAME,
        "sh",
        "-c",
        if discard_stdout {
            VAULT_STDIN_TOKEN_SHIM_QUIET
        } else {
            VAULT_STDIN_TOKEN_SHIM
        },
        "sh",
    ]);
    cmd.args(vault_args);
    cmd
}

/// The in-container shim: read the token line from stdin, export it, exec the
/// CLI with the remaining argv. `IFS=` and `-r` keep the token byte-exact.
const VAULT_STDIN_TOKEN_SHIM: &str =
    "IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && exec vault \"$@\"";
/// Same, with the CLI's stdout dropped inside the container (presence probes).
const VAULT_STDIN_TOKEN_SHIM_QUIET: &str =
    "IFS= read -r VAULT_TOKEN && export VAULT_TOKEN && exec vault \"$@\" >/dev/null";

/// Run the in-container `vault` CLI with the root token on stdin, bounded by
/// the container operation budget. Every host-side vault read goes through here.
fn vault_exec_output(
    root_token: &str,
    vault_args: &[&str],
    discard_stdout: bool,
) -> std::io::Result<std::process::Output> {
    let mut input = Vec::with_capacity(root_token.len() + 1);
    input.extend_from_slice(root_token.as_bytes());
    input.push(b'\n');
    vault_exec_command(vault_args, discard_stdout).output_bounded_with_stdin(
        &input,
        tillandsias_podman::OperationKind::Container.default_budget(),
    )
}

/// Fast presence-only check: returns `true` iff `secret/github/token` exists
/// in the running Vault container, without surfacing the token value to the host.
///
/// Uses `podman exec` so no HTTP port to Vault is needed on the host. Intended
/// for high-frequency poll loops (e.g. 120× at 1s intervals during login).
/// For a definitive auth validation that proves the credential works, use
/// `remote_projects::is_github_logged_in` instead.
///
/// @trace spec:tillandsias-vault, spec:tray-minimal-ux
/// Order 235 (R7): shared vault-stability lock for every exec-based Vault
/// accessor. Holders require only that the vault container REMAINS STABLE
/// while they run; a recreate (ensure_vault_running's exclusive lock on the
/// same resource) waits for them to drain, and they wait out a recreate
/// instead of hitting "container is stopped" / stale state. 120s bound: long
/// enough to sit out a container relaunch, loud on a wedged recreate.
fn vault_stability_lease(debug: bool) -> Result<crate::resource_lock::ResourceLockGuard, String> {
    crate::resource_lock::acquire_shared("vault", Duration::from_secs(120), debug)
}

// Only caller today is the order-230 login probe inside the listen-vsock-gated
// listener, so the default feature set sees this as dead.
#[allow(dead_code)]
pub(crate) fn is_github_key_present() -> bool {
    // Order 235: skip the probe (presence unknown ≈ absent) rather than read
    // through a recreate window.
    let Ok(_stability) = vault_stability_lease(false) else {
        return false;
    };
    if !vault_data_volume_exists() {
        return false;
    }
    if !container_running(VAULT_CONTAINER_NAME) {
        return false;
    }
    // The exec'd `vault` CLI needs VAULT_ADDR/TOKEN/skip-verify; without the root
    // token the call always fails and the poll loop never observes the token.
    let Ok(root_token) = read_and_handover_root_token(false) else {
        return false;
    };
    // Presence only: stdout is dropped inside the container (discard_stdout).
    vault_exec_output(
        &root_token,
        &["kv", "get", "-field=token", "secret/github/token"],
        true,
    )
    .map(|output| output.status.success())
    .unwrap_or(false)
}

/// Read a Vault KV secret field by exec-ing into the running Vault container.
///
/// Replaces all host-side HTTP Vault client reads for steady-state secret
/// access. No port publish (`-p`) is required on the host — the host reaches
/// Vault only through `podman exec`. The value is in host process memory
/// transiently during injection; it never transits a network socket.
///
/// @trace spec:tillandsias-vault
pub(crate) fn vault_kv_get_via_exec(
    secret_path: &str,
    field: &str,
    debug: bool,
) -> Result<String, String> {
    // Order 235 (R7): wait out any in-flight recreate instead of racing it.
    let _stability = vault_stability_lease(debug)?;
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err(format!("{VAULT_CONTAINER_NAME} is not running"));
    }
    // `podman exec` does not inherit the entrypoint env, so the `vault` CLI needs
    // VAULT_ADDR/TOKEN/skip-verify supplied explicitly (see vault_exec_command).
    let root_token = read_and_handover_root_token(debug)?;
    let field_arg = format!("-field={field}");
    let output = vault_exec_output(&root_token, &["kv", "get", &field_arg, secret_path], false)
        .map_err(|e| format!("podman exec {VAULT_CONTAINER_NAME} vault kv get: {e}"))?;
    if output.status.success() {
        let val = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if debug {
            eprintln!(
                "[tillandsias] vault kv get {secret_path}: ok ({} bytes)",
                val.len()
            );
        }
        Ok(val)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("vault kv get {secret_path}: {}", stderr.trim()))
    }
}

// ─── OpenCode auth-document storage ─────────────────────────────────────────
// OpenCode's undocumented OPENCODE_AUTH_CONTENT contract consumes the same JSON
// object it would otherwise read from $XDG_DATA_HOME/opencode/auth.json. Keep
// the existing Gemini key producer/path and assemble that object in memory;
// launch argv never contains the key or the derived document.
// @trace spec:tillandsias-vault, spec:default-image
pub(crate) const OPENCODE_AUTH_VAULT_PATH: &str = "secret/gemini/api-key";
pub(crate) const OPENCODE_AUTH_VAULT_FIELD: &str = "key";

/// Return whether Vault currently holds the Gemini source used for OpenCode.
///
/// Missing content is the supported credential-free lane. Other Vault failures
/// remain errors so a configured credential cannot silently disappear because
/// the availability probe itself degraded.
pub(crate) fn opencode_auth_content_available(debug: bool) -> Result<bool, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Ok(false);
    }
    let _stability = vault_stability_lease(debug)?;
    let root_token = read_and_handover_root_token(debug)?;
    let field_arg = format!("-field={OPENCODE_AUTH_VAULT_FIELD}");
    // Presence only: stdout is dropped INSIDE the container so the Gemini key
    // never enters launcher memory. The scoped forge reads it later.
    let output = vault_exec_output(
        &root_token,
        &["kv", "get", &field_arg, OPENCODE_AUTH_VAULT_PATH],
        true,
    )
    .map_err(|error| format!("OpenCode Vault auth availability command failed: {error}"))?;
    if output.status.success() {
        return Ok(true);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("No value found")
        || stderr.contains("secret not found")
        || stderr.contains("field not present")
    {
        Ok(false)
    } else {
        Err(format!(
            "OpenCode Vault auth availability check failed (status {})",
            output.status
        ))
    }
}

// ─── LLM provider API key storage ───────────────────────────────────────────
// Vault secret schema:  secret/<provider>/api-key  { "key": "<api-key>" }
// Supported providers: anthropic, openai, gemini
// @trace plan/issues/forge-harness-auth-vault-proxy-2026-06-27.md

/// LLM provider identifier for Vault key storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderId {
    Anthropic,
    Openai,
    Gemini,
}

impl ProviderId {
    /// Stable Vault path segment (`secret/<segment>/api-key`).
    pub fn vault_segment(self) -> &'static str {
        match self {
            ProviderId::Anthropic => "anthropic",
            ProviderId::Openai => "openai",
            ProviderId::Gemini => "gemini",
        }
    }

    /// Human-readable name for log messages.
    pub fn display_name(self) -> &'static str {
        match self {
            ProviderId::Anthropic => "Anthropic",
            ProviderId::Openai => "OpenAI",
            ProviderId::Gemini => "Gemini",
        }
    }

    /// The environment variable name that the provider's CLI reads.
    ///
    /// NOTE (order 430): OpenAI maps to `CODEX_API_KEY`, not `OPENAI_API_KEY`.
    /// The CLI we run for the OpenAI provider is Codex, and Codex **ignores**
    /// `OPENAI_API_KEY` entirely. Verified empirically against codex-cli
    /// 0.144.4 with bogus keys and an empty `CODEX_HOME`:
    ///
    ///   OPENAI_API_KEY -> "Missing bearer or basic authentication in header"
    ///                     (the key is never sent — no auth header at all)
    ///   CODEX_API_KEY  -> "Incorrect API key provided: sk-bogus*****-111"
    ///                     (the key is used)
    ///
    /// Injecting `OPENAI_API_KEY` was worse than a no-op: the Codex entrypoint
    /// gated its Vault OAuth restore on that variable being empty, so setting
    /// it ALSO suppressed the restore, leaving the lane with no credential at
    /// all. Do not "fix" this back without re-running that experiment.
    ///
    /// `CODEX_API_KEY` is honoured only by `codex exec` — it is deliberately
    /// disabled in the TUI upstream.
    pub fn env_var(self) -> &'static str {
        match self {
            ProviderId::Anthropic => "ANTHROPIC_API_KEY",
            ProviderId::Openai => "CODEX_API_KEY",
            ProviderId::Gemini => "GEMINI_API_KEY",
        }
    }
}

fn provider_vault_path(provider: ProviderId) -> String {
    format!("secret/{}/api-key", provider.vault_segment())
}

/// Write a provider API key to Vault. Idempotent — re-running with the same
/// key is a no-op. Returns `Err` if Vault cannot be brought up or the write
/// fails.
#[allow(dead_code)]
pub fn write_provider_api_key(provider: ProviderId, key: &str, debug: bool) -> Result<(), String> {
    if key.is_empty() {
        return Err(format!(
            "{} API key must not be empty",
            provider.display_name()
        ));
    }
    if !container_running(VAULT_CONTAINER_NAME) {
        if debug {
            eprintln!(
                "[tillandsias-vault] Vault not running; bringing up before {} key write",
                provider.display_name()
            );
        }
        ensure_vault_running(debug).map_err(|e| {
            format!(
                "could not bring Vault up to store {} API key: {e}",
                provider.display_name()
            )
        })?;
    }
    // Order 235 (R7): shared AFTER the on-demand ensure (see
    // write_github_token_to_vault for the self-deadlock rationale).
    let _stability = vault_stability_lease(debug)?;
    let rt = tokio_runtime()?;
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    let path = provider_vault_path(provider);

    rt.block_on(client.write_secret(&path, serde_json::json!({ "key": key })))
        .map_err(|e| format!("vault write_secret {} failed: {e}", path))?;

    let read_back = rt
        .block_on(client.read_secret(&path))
        .map_err(|e| format!("vault read_secret verification for {} failed: {e}", path))?;
    if read_back["key"].as_str() != Some(key) {
        return Err(format!(
            "vault read-back for {} did not match written key",
            provider.display_name()
        ));
    }
    if debug {
        eprintln!(
            "[tillandsias] {} API key stored in Vault at {}",
            provider.display_name(),
            path
        );
    }
    Ok(())
}

/// Read a provider API key via `podman exec` into the Vault container.
///
/// Returns `Ok("")` if the key path exists but is empty; returns `Err` if
/// Vault is not running or the exec fails. Does not use the host Vault HTTP
/// client — no port publish needed.
///
/// @trace spec:tillandsias-vault, plan/issues/vault-credential-host-exposure-audit-2026-06-27.md
#[allow(dead_code)]
pub(crate) fn read_provider_api_key(provider: ProviderId, debug: bool) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Ok(String::new());
    }
    let path = provider_vault_path(provider);
    vault_kv_get_via_exec(&path, "key", debug).or_else(|e| {
        if e.contains("No value found") || e.contains("secret not found") {
            Ok(String::new())
        } else {
            Err(e)
        }
    })
}

/// Returns `true` iff a non-empty API key for the given provider is stored in
/// Vault. Uses `podman exec` (exit-code only) — the key value is never read
/// into the host process.
#[allow(dead_code)]
pub(crate) fn is_provider_logged_in(provider: ProviderId, debug: bool) -> bool {
    if !vault_data_volume_exists() {
        return false;
    }
    if !container_running(VAULT_CONTAINER_NAME)
        && let Err(e) = ensure_vault_running(debug)
    {
        if debug {
            eprintln!(
                "[tillandsias] is_provider_logged_in({}): vault bring-up failed: {e}",
                provider.display_name()
            );
        }
        return false;
    }
    let path = provider_vault_path(provider);
    podman_cmd_sync()
        .args([
            "exec",
            VAULT_CONTAINER_NAME,
            "vault",
            "kv",
            "get",
            "-field=key",
            &path,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status_bounded(tillandsias_podman::OperationKind::Container.default_budget())
        .map(|s| s.success())
        .unwrap_or(false)
}

// ─────────────────────────────────────────────────────────────────────────────

/// True iff the persistent Vault data volume exists. Cheap: a single
/// `podman volume exists` with no Vault bring-up, so it can gate the more
/// expensive on-demand launch in `is_github_key_present` and `ensure_vault_running`.
#[allow(dead_code)]
fn vault_data_volume_exists() -> bool {
    let dir = crate::init_cache_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("vault-data");
    dir.exists()
}

/// Persist the in-VM credential fallback files.
///
/// Inside the VM there is no OS keychain, so these files are the only durable
/// record that `operator init` completed and the host-visible handover was
/// produced. Each value is written only when present: a caller that has the
/// token but not the share writes only the token, which keeps a genuine
/// partial init detectable (694-mhz8).
///
/// Best-effort by design — a failure here must not abort a successful init;
/// the worst case is the pre-694 behavior.
/// 701-se6x criterion 2. Both writes used to be `let _ = fs::write(...)`.
///
/// That is a credential-destroying silence, not a cosmetic one. The share file
/// is the ONLY evidence inside the guest that `operator init` ever completed —
/// `has_shamir_share_in_keyring` consults an OS keychain the guest does not
/// have, then this file — and its answer is what the partial-init WIPE turns
/// on. So a single failed 30-byte write (ENOSPC, a non-writable cache dir, a
/// write lost to an unclean VM stop) leaves the predicate false with a healthy
/// Vault on disk, and the next launch wipes it, taking the stored GitHub token
/// with it. That is exactly the 694-mhz8 failure, re-armed by an error nobody
/// looked at. 694 removed the PERMANENT failure; it did not make the remaining
/// single point of evidence robust or loud.
///
/// Returns Err naming every artifact that failed, so callers can surface it.
/// BOTH writes are always ATTEMPTED — a token failure must never skip the
/// share, because the share is the half that arms the wipe.
fn write_vm_credential_fallbacks(
    cache_dir: &std::path::Path,
    token: Option<&str>,
    share_b64: Option<&str>,
) -> std::io::Result<()> {
    let mut failures: Vec<String> = Vec::new();

    if let Some(token) = token
        && let Err(e) = fs::write(cache_dir.join("fallback_vault-root-token-v1"), token)
    {
        failures.push(format!("fallback_vault-root-token-v1: {e}"));
    }

    // Deliberately NOT an early return above: see the doc comment.
    if let Some(share_b64) = share_b64
        && let Err(e) = fs::write(
            cache_dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}")),
            share_b64,
        )
    {
        failures.push(format!("fallback_{VAULT_SHAMIR_SHARE_V1}: {e}"));
    }

    if failures.is_empty() {
        return Ok(());
    }
    Err(std::io::Error::other(failures.join("; ")))
}

/// The one place that turns a failed fallback write into something a human or a
/// log scraper can act on. Kept as a helper so the two call sites cannot drift
/// into reporting it differently — which is how the original asymmetry between
/// them arose in the first place (694-mhz8 fixed one site, 701-se6x the other).
#[cfg(feature = "vault")]
fn report_fallback_write_failure(context: &str, detail: &str) {
    eprintln!("[tillandsias-vault] CREDENTIAL FALLBACK WRITE FAILED ({context}): {detail}");
    eprintln!(
        "[tillandsias-vault]   the Shamir share may not be on disk. \
         has_shamir_share_in_keyring() will then read false, and the NEXT launch \
         can classify this initialized Vault as a crashed partial init and WIPE it \
         (694-mhz8 / 701-se6x). Free space / fix permissions on the cache dir before relaunching."
    );
}

/// True iff the host keychain holds a valid (32-byte, base64-encoded) Shamir
/// unseal share. Used to distinguish a subsequent-boot launch (data volume
/// contains a fully-initialized Vault the host can re-unseal) from a
/// partial-init failure (init started, process crashed before the host
/// captured the handover, so the volume and the keyring are out of sync).
#[cfg(feature = "vault")]
fn has_shamir_share_in_keyring() -> bool {
    use base64::Engine;
    let try_decode = |encoded: &str| {
        !encoded.is_empty()
            && base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map(|v| v.len() == 32)
                .unwrap_or(false)
    };

    // Primary: OS keychain
    if let Ok(entry) = Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1)
        && let Ok(encoded) = with_keyring_timeout(move || entry.get_password())
        && try_decode(&encoded)
    {
        return true;
    }

    // Fallback: file (populated by keychain_set_blocking when keyring unavailable,
    // e.g. in a VM guest or headless environment without D-Bus)
    if let Ok(cache_dir) = crate::init_cache_dir() {
        return fallback_share_counts(&cache_dir);
    }
    false
}

/// What the OS keychain can say about the unseal share (order 1437-qza3).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyringShare {
    /// The keychain answered and holds a valid 32-byte share.
    Present,
    /// The keychain answered and has no valid share.
    Absent,
    /// The keychain could not be asked: no secret service, a locked keyring,
    /// or a timeout. These cannot be told apart from here (1265-8qr6).
    Unreachable,
}

/// Ask the keychain, and ONLY the keychain, for the unseal share. Unlike
/// [`has_shamir_share_in_keyring`] this never consults the fallback file and
/// keeps "no entry" apart from "could not ask", because the reset decision
/// (see [`reset_vault_disposition`]) turns on exactly that difference.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[cfg(feature = "vault")]
pub fn probe_keyring_share() -> KeyringShare {
    use base64::Engine;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let answer = match Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1) {
            Err(_) => KeyringShare::Unreachable,
            Ok(entry) => match entry.get_password() {
                Ok(encoded) => {
                    let valid = base64::engine::general_purpose::STANDARD
                        .decode(encoded.trim())
                        .map(|v| v.len() == 32)
                        .unwrap_or(false);
                    if valid {
                        KeyringShare::Present
                    } else {
                        KeyringShare::Absent
                    }
                }
                Err(keyring::Error::NoEntry) => KeyringShare::Absent,
                Err(_) => KeyringShare::Unreachable,
            },
        };
        let _ = tx.send(answer);
    });
    rx.recv_timeout(Duration::from_secs(2))
        .unwrap_or(KeyringShare::Unreachable)
}

/// The reset's Vault disposition, one of the three named tokens in
/// host-state-lifecycle (order 1437-qza3, aligned to 1443-bs9z). The tokens
/// are an INTERFACE: fixtures and the tray read them, so do not respell them.
///
/// A SOFT reset never deletes the store under ANY disposition. The
/// disposition only decides what the reset ANNOUNCES; for
/// `AbsentReinitAtInit` the next `--init`'s partial-init guard is what
/// re-initialises the store, with its own loud line.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResetVaultDisposition {
    /// `Verified:KEEP` — the keyring answered and holds a 32-byte share.
    VerifiedKeep,
    /// `Unverified:KEEP` — the keyring could not be asked. Not evidence of an
    /// absent share, so the store is kept unverified (operator 2026-09-27:
    /// "Unverified:KEEP is ok for a soft reset").
    UnverifiedKeep,
    /// `Absent:REINIT-AT-INIT` — the keyring answered and holds no share, so
    /// the store cannot be unsealed and is re-initialised at the next init.
    AbsentReinitAtInit,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl ResetVaultDisposition {
    /// The token, exactly as the spec spells it.
    pub fn token(self) -> &'static str {
        match self {
            Self::VerifiedKeep => "Verified:KEEP",
            Self::UnverifiedKeep => "Unverified:KEEP",
            Self::AbsentReinitAtInit => "Absent:REINIT-AT-INIT",
        }
    }

    /// The announcement line, verbatim from the host-state-lifecycle table.
    pub fn announcement(self) -> &'static str {
        match self {
            Self::VerifiedKeep => {
                "reset: Vault store kept (Verified:KEEP) — share vault-shamir-share-v1 present"
            }
            Self::UnverifiedKeep => {
                "reset: keyring unreachable — Vault store kept unverified (Unverified:KEEP); it \
                 unseals at next init if the share is there, else init re-initialises it and \
                 says so"
            }
            Self::AbsentReinitAtInit => {
                "reset: no unlocking keyring holds vault-shamir-share-v1 — the Vault store cannot \
                 survive this reset and will be re-initialised at next init"
            }
        }
    }
}

/// Operator ruling 2026-09-27: "the presence of an unlocking keyring should be
/// a requirement to survive the vault store." Decided by asking the keyring
/// alone: an unreachable keyring is not evidence of an absent share.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn reset_vault_disposition(keyring: KeyringShare) -> ResetVaultDisposition {
    match keyring {
        KeyringShare::Present => ResetVaultDisposition::VerifiedKeep,
        KeyringShare::Unreachable => ResetVaultDisposition::UnverifiedKeep,
        KeyringShare::Absent => ResetVaultDisposition::AbsentReinitAtInit,
    }
}

/// The FALLBACK half of has_shamir_share_in_keyring: the whole predicate inside
/// a guest, which has no keychain. Split out (1200-ih38 review) so a test can
/// assert it hermetically: on a host whose own keyring holds a share, the full
/// predicate is already true and a test through it proves nothing.
#[cfg(feature = "vault")]
fn fallback_share_counts(cache_dir: &Path) -> bool {
    use base64::Engine;
    fs::read_to_string(cache_dir.join(format!("fallback_{}", VAULT_SHAMIR_SHARE_V1)))
        .map(|encoded| {
            let encoded = encoded.trim();
            !encoded.is_empty()
                && base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .map(|v| v.len() == 32)
                    .unwrap_or(false)
        })
        .unwrap_or(false)
}

/// UNREACHABLE BY CONSTRUCTION — and this comment is the point (701-iu9b).
///
/// TRAP 2 asked whether this stub could ship and make the partial-init WIPE
/// unconditional: `has_shamir_share_in_keyring() == false` turns
/// `vault_data_volume_exists() && !has_shamir_share_in_keyring()` into "always
/// a partial init", i.e. wipe a healthy Vault on every boot. That was REFUTED,
/// twice over:
///
///   1. `mod vault_bootstrap;` is itself `#[cfg(feature = "vault")]`
///      (main.rs:101-103), so with vault OFF this module — and therefore this
///      item — is never compiled at all.
///   2. `compile_error!` (main.rs:94-99) fails the build outright for
///      `listen-vsock` without `vault`, so the dangerous combination cannot be
///      produced even by accident. The guest build path passes
///      `--features listen-vsock` while keeping default features, and
///      `default = ["vault"]`.
///
/// The criterion asked for "a test [that] exercises the wipe predicate under
/// the stub cfg and documents the intended behaviour THERE". The test half is
/// UNACHIEVABLE — no test can reach an item that is never compiled — but the
/// documentation half was genuinely undone: the rationale lived only in
/// main.rs and in the ledger, so a reader arriving HERE, at the item that looks
/// dangerous, found nothing. Now they do.
///
/// NOT DELETED, deliberately. Ten sibling `cfg(not(feature = "vault"))` items
/// in this file are dead for the same reason, and removing eleven items to
/// tidy one is a larger regression surface than the tidiness is worth while
/// the compile_error! guard makes the whole class unreachable. Recorded rather
/// than swept.
#[cfg(not(feature = "vault"))]
fn has_shamir_share_in_keyring() -> bool {
    false
}

/// Mint a fresh AppRole token for a container of the given `role` (e.g.
/// `"git-mirror"`). The returned `(token, secret_name)` is registered in
/// the in-process revocation registry so shutdown can revoke it. The
/// secret name embeds the container instance so concurrent containers
/// don't collide; the token bytes themselves are written into the named
/// podman secret as the value.
pub async fn mint_approle_token_for_container(
    role: &str,
    container_instance: &str,
    debug: bool,
) -> Result<(String, String), String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    let token = client
        .issue_approle_token(role)
        .await
        .map_err(|e| format!("vault issue_approle_token failed: {e}"))?;

    let secret_name = format!("tillandsias-vault-token-{role}-{container_instance}");
    create_token_podman_secret(&secret_name, &token, debug)?;
    if let Ok(mut reg) = revocation_registry().lock() {
        reg.insert(secret_name.clone(), token.clone());
    }
    Ok((token, secret_name))
}

/// Issue bounded-reuse AppRole material for a long-running container's Agent.
///
/// Unlike [`mint_approle_token_for_container`], this does not perform the
/// AppRole login on the host. The role ID and secret ID cross the container
/// boundary together in one Podman secret and never appear in argv or the
/// environment. Vault Agent owns client-token renewal and re-authentication;
/// shutdown destroys the secret ID through its accessor.
///
/// @trace spec:tillandsias-vault, spec:git-mirror-service
pub async fn mint_approle_auto_auth_for_container(
    role: &str,
    container_instance: &str,
    owning_container: Option<&str>,
    debug: bool,
) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    let credentials = client
        .issue_approle_credentials(role)
        .await
        .map_err(|e| format!("vault issue_approle_credentials failed: {e}"))?;
    let secret_id_accessor = credentials.secret_id_accessor().to_string();
    // A same-process lane relaunch reuses `<project>-<pid>`. Keep every
    // reusable-within-48h SecretID under an issuance-unique Podman name so registry
    // insertion cannot overwrite and orphan the previous accessor.
    let secret_name = next_approle_auto_auth_secret_name(role, container_instance);
    // Serialize borrowed fields directly into the one buffer we can zeroize;
    // constructing a serde_json::Value here would allocate a second,
    // non-zeroizing SecretID copy.
    let mut payload = serde_json::to_string(&AppRoleAutoAuthDocument {
        role_id: credentials.role_id(),
        secret_id: credentials.secret_id(),
    })
    .map_err(|e| format!("serialize AppRole auto-auth material: {e}"))?;

    let create_result = create_token_podman_secret(&secret_name, &payload, debug);
    payload.zeroize();
    if let Err(error) = create_result {
        let _ = client
            .destroy_approle_secret_id_accessor(role, &secret_id_accessor)
            .await;
        return Err(error);
    }

    let registration = AppRoleAutoAuthRegistration {
        role: role.to_string(),
        secret_id_accessor,
        owning_container: owning_container.map(str::to_string),
    };
    match approle_auto_auth_registry().lock() {
        Ok(mut registry) => {
            registry.insert(secret_name.clone(), registration);
        }
        Err(_) => {
            let _ = client
                .destroy_approle_secret_id_accessor(
                    &registration.role,
                    &registration.secret_id_accessor,
                )
                .await;
            let _ = podman_cmd_sync()
                .args(["secret", "rm", &secret_name])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status_bounded(tillandsias_podman::OperationKind::Secret.default_budget());
            return Err("AppRole auto-auth revocation registry is poisoned".into());
        }
    }
    Ok(secret_name)
}

/// ORDER 1313-prin. Mint a host's AppRole document to a PLAIN FILE, 0600.
///
/// The container path above writes a podman secret, which a host process
/// cannot read. A host that mints its push certificate on demand needs the
/// role_id/secret_id pair on its own filesystem.
///
/// WHY A PLAIN FILE IS THE RIGHT ANSWER HERE AND NOT A RETREAT. The operator's
/// requirement for this whole design is the KEYRING OFF THE HOT PATH. This
/// function runs at provision time, where the launcher has already read the
/// root token once; the file it writes is then read by `git push` with no
/// secret-service call at all. Putting this material in the keyring instead
/// would reintroduce exactly the per-push read the design exists to remove,
/// and on this fleet that read can abort gnome-keyring 50 (1265-8qr6).
///
/// WHAT THIS MATERIAL CAN DO, so the tradeoff is legible: it authenticates as
/// one AppRole whose single policy permits exactly
/// `ssh-client-signer/sign/host-<host>`. It cannot read secret/github/token,
/// cannot sign for any other host, and cannot sign a HOST certificate. A
/// stolen copy mints push certs for this host until the SecretID is revoked —
/// which is why it is 0600 in the user's own config dir and never in the repo.
pub async fn mint_host_approle_document(
    role: &str,
    dest: &Path,
    debug: bool,
) -> Result<(), String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    let credentials = client
        .issue_approle_credentials(role)
        .await
        .map_err(|e| format!("vault issue_approle_credentials for {role} failed: {e}"))?;

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    // Write 0600 BEFORE the content exists, not after: a create-then-chmod
    // leaves a window where the document is world-readable, and on a
    // multi-user host that window is the whole vulnerability.
    let tmp = dest.with_extension("tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        use std::io::Write as _;
        let mut fh = opts
            .open(&tmp)
            .map_err(|e| format!("cannot open {}: {e}", tmp.display()))?;
        let body = format!(
            "{{\"role_id\":\"{}\",\"secret_id\":\"{}\"}}\n",
            credentials.role_id(),
            credentials.secret_id()
        );
        fh.write_all(body.as_bytes())
            .map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    }
    fs::rename(&tmp, dest).map_err(|e| format!("cannot install {}: {e}", dest.display()))?;
    if debug {
        eprintln!(
            "[tillandsias-vault] host AppRole document written to {}",
            dest.display()
        );
    }
    Ok(())
}

/// Short-lived podman-secret mount for a synchronous container command.
///
/// The underlying Vault token remains in the revocation registry and is
/// revoked during normal shutdown. Dropping this lease immediately removes
/// the podman secret so subsequent containers cannot reuse it.
#[allow(dead_code)]
pub struct AppRoleSecretLease {
    secret_name: String,
}

impl AppRoleSecretLease {
    #[allow(dead_code)]
    pub fn secret_name(&self) -> &str {
        &self.secret_name
    }
}

impl Drop for AppRoleSecretLease {
    fn drop(&mut self) {
        let _ = podman_cmd_sync()
            .args(["secret", "rm", &self.secret_name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status_bounded(tillandsias_podman::OperationKind::Secret.default_budget());
    }
}

/// Mint a scoped AppRole token and expose it as a lease for a synchronous
/// one-shot container command.
#[allow(dead_code)]
pub fn mint_approle_secret_lease(
    role: &str,
    container_instance: &str,
    debug: bool,
) -> Result<AppRoleSecretLease, String> {
    // Hold Vault stable only across token mint + Podman-secret creation. The
    // returned secret can outlive this bounded operation, but its idle lane
    // must not starve an exclusive ensure/heal for the lane's whole lifetime.
    let _stability = vault_stability_lease(debug)?;
    let runtime = tokio_runtime()?;
    let (_token, secret_name) = runtime.block_on(mint_approle_token_for_container(
        role,
        container_instance,
        debug,
    ))?;
    Ok(AppRoleSecretLease { secret_name })
}

/// Drain and revoke every per-container token recorded in the in-process
/// registry. Also removes the matching podman secret so the on-disk
/// artifact (a short-lived random byte string) doesn't survive shutdown.
///
/// Best-effort: errors are logged and continued past so a partial failure
/// doesn't deadlock the shutdown path. The Vault container itself is
/// preserved on disk (matches the `<cache>/vault-data` host directory
/// contract).
pub async fn revoke_pending_container_tokens(debug: bool) {
    let token_entries: Vec<(String, String)> = match revocation_registry().lock() {
        Ok(mut reg) => reg.drain().collect(),
        Err(_) => Vec::new(),
    };
    let auto_auth_entries: Vec<(String, AppRoleAutoAuthRegistration)> =
        match approle_auto_auth_registry().lock() {
            Ok(mut reg) => reg.drain().collect(),
            Err(_) => Vec::new(),
        };
    if token_entries.is_empty() && auto_auth_entries.is_empty() {
        return;
    }
    let base_url = vault_api_base_url();
    let client = match read_and_handover_root_token(debug) {
        Ok(root_token) => match vault_client(&base_url, &root_token, debug) {
            Ok(client) => Some(client),
            Err(e) => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] revoke: cannot build TLS client: {e}; \
                         removing Podman secrets without server-side revocation"
                    );
                }
                None
            }
        },
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] revoke: cannot read root token: {e}; \
                     removing Podman secrets without server-side revocation"
                );
            }
            None
        }
    };

    for (secret_name, token) in token_entries {
        if let Some(client) = &client
            && let Err(e) = client.revoke_token(&token).await
            && debug
        {
            eprintln!("[tillandsias-vault] revoke token for {secret_name} failed: {e}");
        }
        let _ = podman_cmd_sync()
            .args(["secret", "rm", &secret_name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status_bounded(tillandsias_podman::OperationKind::Secret.default_budget());
    }

    // Order 828-k3mq: REFCOUNT THE CREDENTIAL THE WAY THE CONTAINER IS ALREADY
    // REFCOUNTED. `cleanup_shared_stack_if_no_running_forge` keeps a mirror
    // alive whenever a sibling lane is live (and on any listing error), so a
    // lane exiting into a live sibling deliberately LEAVES the mirror running.
    // Destroying its SecretID here anyway left that mirror renewing a client
    // token it could no longer replace: at max_ttl the Agent re-login failed
    // "invalid role or secret ID", the retries tripped Vault's user-lockout,
    // and every forge push was rejected by the relay gate while clones kept
    // working. Measured on yolanda 2026-08-18, exactly 24h after the lane
    // exited.
    let (auto_auth_entries, kept) =
        partition_auto_auth_entries(auto_auth_entries, owning_container_state);
    for (secret_name, container, state) in kept {
        match state {
            OwningContainerState::Running => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] keeping AppRole material {secret_name} alive; \
                         its container {container} is still running (order 828-k3mq)"
                    );
                }
            }
            // Loud, not debug-gated: this is the leak-not-destroy arm and the
            // operator should be able to see it happen.
            OwningContainerState::Unknown => eprintln!(
                "[tillandsias-vault] could not determine whether {container} is running; \
                 keeping its AppRole material {secret_name} rather than risk destroying a \
                 live mirror's credential (leak-not-destroy, order 828-k3mq). The role's \
                 48h SecretID TTL bounds this."
            ),
            // partition_auto_auth_entries never returns Gone as kept.
            OwningContainerState::Gone => {}
        }
    }

    for (secret_name, registration) in auto_auth_entries {
        if let Some(client) = &client
            && let Err(e) = client
                .destroy_approle_secret_id_accessor(
                    &registration.role,
                    &registration.secret_id_accessor,
                )
                .await
            && debug
        {
            eprintln!("[tillandsias-vault] destroy AppRole accessor for {secret_name} failed: {e}");
        }
        let _ = podman_cmd_sync()
            .args(["secret", "rm", &secret_name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status_bounded(tillandsias_podman::OperationKind::Secret.default_budget());
    }
}

fn build_vault_image(debug: bool) -> Result<String, String> {
    let version = crate::VERSION.trim();
    let root = crate::resolve_runtime_asset_root(version, debug)?;
    let build_args = std::collections::BTreeMap::new();
    let dependency_digests = std::collections::BTreeMap::new();
    let identity = crate::runtime_assets::image_identity(
        &root,
        "vault",
        version,
        build_args.clone(),
        dependency_digests,
    )?;

    // Order 253: --init pre-builds vault into this same identity tag, so the
    // login path is zero-build on an initialized runtime. Skipping here also
    // stops every login from re-invoking `podman build` (the repeated-login
    // rebuild observed in the order-245 audit). The build below stays as the
    // fail-soft fallback for runtimes that skipped --init.
    if tillandsias_podman::image_exists_sync(&identity.canonical_tag) {
        if debug {
            eprintln!(
                "[tillandsias-vault] image {} already built; skipping build",
                identity.canonical_tag
            );
        }
        return Ok(identity.canonical_tag);
    }
    eprintln!(
        "[tillandsias-vault] vault image missing — building on demand; run `tillandsias --init` to pre-build it (order 253)"
    );

    let cache_dir = crate::init_cache_dir()?;
    let log_file = if debug {
        Some(cache_dir.join("tillandsias-init-vault.log"))
    } else {
        None
    };

    crate::build_image_with_logging(&root, "vault", &identity, &build_args, &log_file, debug)?;

    Ok(identity.canonical_tag)
}

#[cfg(feature = "vault")]
/// ORDER 1286-4437. Clear the HOST-HELD vault credentials, preserving the
/// installation anchor. This is the same rule
/// `scripts/clear-vault-host-credentials.sh` implements, and the coordinator's
/// 2026-09-20 ruling makes the BINARY the implementation the installers call,
/// because `install.sh` is a standalone published artifact that fetches the
/// binary and nothing else and cannot invoke a repo script.
///
/// PRESERVES `installation-uuid-v1` deliberately and permanently: the in-guest
/// Vault derives its master key from it, so clearing it makes the next vault
/// UNDERIVABLE rather than re-initialised (order 803-49re). Every platform's
/// equivalent anchor is preserved for the same reason —
/// `tillandsias-vm-uuid` on Windows, `INSTALL_ANCHOR_V1` on macOS.
///
/// Returns the list of things it CLEARED and the list it COULD NOT, so the
/// caller can refuse rather than warn: 1284-jf86 is the row about a clearer
/// that printed "the room is NOT cold" and exited 0.
/// Linux-only, matching its single caller `run_reset_state`: it clears a
/// host-held credential set whose locations (the Secret Service keychain, the
/// `~/.cache/tillandsias` fallbacks, the subuid-owned `vault-data`) are Linux
/// shapes, and it reaches for `podman unshare` and `libc::getuid`, neither of
/// which exists on `x86_64-pc-windows-gnu`. The Windows and macOS equivalents
/// clear Credential Manager and the keychain from their own trays.
///
/// UNINSTALL-ONLY (order 1437-qza3, operator directive 2026-09-27). No reset
/// may call this: the store and the unseal material are operator data that
/// survive every destructive reset (tillandsias-vault, host-state-lifecycle).
/// Its caller is `--uninstall`, which lands with 1437-evzi; until then it has
/// none, which is why dead code is allowed here rather than the function being
/// deleted and rewritten. `scripts/test-reset-state-contract.sh` ARM 8 fails if
/// a reset body calls it.
#[cfg(target_os = "linux")]
#[allow(dead_code)]
pub fn clear_host_vault_credentials(debug: bool) -> (Vec<String>, Vec<String>) {
    let mut cleared: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();

    // The root-token attr has no constant in this module (only the share and
    // the anchor do); the name is the one scripts/clear-vault-host-credentials.sh
    // clears, kept literal here so the two cannot drift apart silently.
    for attr in [VAULT_SHAMIR_SHARE_V1, "vault-root-token-v1"] {
        let a = attr.to_string();
        // Classified INSIDE the closure (1371-a7w2): with_keyring_timeout
        // stringifies the error, and keyring::Error::NoEntry displays as "No
        // matching entry found in secure storage", which a text match missed.
        let res = with_keyring_timeout(move || {
            classify_keyring_delete(
                Entry::new(KEYCHAIN_SERVICE, &a).and_then(|e| e.delete_credential()),
            )
        });
        match res {
            Ok(true) => cleared.push(format!("keychain:{attr}")),
            Ok(false) => cleared.push(format!("keychain:{attr} (already absent)")),
            Err(e) => failed.push(format!("keychain:{attr}: {e}")),
        }
    }

    let (c, f) = clear_vault_store_and_fallbacks();
    cleared.extend(c);
    failed.extend(f);

    if debug {
        eprintln!("[tillandsias] cleared: {}", cleared.join(" "));
        if !failed.is_empty() {
            eprintln!("[tillandsias] FAILED: {}", failed.join(" "));
        }
    }
    (cleared, failed)
}

/// The store half of the clear: the two fallback files and `<cache>/vault-data`,
/// and NOTHING in the keychain. Split out (order 1437-qza3) because a reset on
/// a keyring-less host clears exactly this set, per the operator ruling of
/// 2026-09-27, while the keychain entries are cleared only by uninstall.
#[cfg(target_os = "linux")]
pub fn clear_vault_store_and_fallbacks() -> (Vec<String>, Vec<String>) {
    let mut cleared: Vec<String> = Vec::new();
    let mut failed: Vec<String> = Vec::new();
    let cache = match crate::init_cache_dir() {
        Ok(c) => c,
        Err(e) => {
            failed.push(format!("cache dir unavailable: {e}"));
            return (cleared, failed);
        }
    };
    for name in [
        format!("fallback_{VAULT_SHAMIR_SHARE_V1}"),
        "fallback_vault-root-token-v1".to_string(),
    ] {
        let f = cache.join(&name);
        if !f.exists() {
            cleared.push(format!("file:{name} (already absent)"));
            continue;
        }
        match fs::remove_file(&f) {
            Ok(()) => cleared.push(format!("file:{name}")),
            Err(e) => failed.push(format!("file:{name}: {e}")),
        }
    }

    // vault-data is written from INSIDE A CONTAINER UNDER A SUBUID, so a
    // plain remove as the invoking uid is refused on every subdirectory.
    // Measured twice on pirria 2026-09-19 (orders 1284-jf86): owner 524388,
    // subdirectories mode 700. `podman unshare` runs in the user namespace
    // where that subuid maps to root and is the one context able to remove
    // what the product wrote. Tried only AFTER the plain remove, so a host
    // whose directory is owned by the invoking user never needs a container
    // runtime for this.
    let vd = cache.join("vault-data");
    if !vd.exists() {
        cleared.push("dir:vault-data (already absent)".to_string());
    } else if fs::remove_dir_all(&vd).is_ok() && !vd.exists() {
        cleared.push("dir:vault-data".to_string());
    } else {
        // Bounded, not bare (order 714-4r6w): a synchronous podman call with no
        // deadline is indistinguishable from slow work when the substrate is
        // wedged, and `podman unshare` takes the storage lock. Container's
        // budget is the right class — this removes a data tree, not an image —
        // and it is a deadlock detector, not a performance target.
        let unshared = podman_cmd_sync()
            .args(["unshare", "rm", "-rf"])
            .arg(&vd)
            .status_bounded(tillandsias_podman::OperationKind::Container.default_budget())
            .map(|st| st.success())
            .unwrap_or(false);
        if unshared && !vd.exists() {
            cleared.push("dir:vault-data (via podman unshare — subuid-owned)".to_string());
        } else {
            failed.push(format!(
                "dir:vault-data: refused as uid {} and `podman unshare rm -rf` did not resolve it",
                unsafe { libc::getuid() }
            ));
        }
    }

    (cleared, failed)
}

/// A missing entry is CLEARED, not failed — the post-condition is absence, and
/// an already-absent item satisfies it. `Ok(true)` = deleted, `Ok(false)` =
/// already absent; any other error is a real failure and passes through.
#[cfg(target_os = "linux")]
fn classify_keyring_delete(res: Result<(), keyring::Error>) -> Result<bool, keyring::Error> {
    match res {
        Ok(()) => Ok(true),
        Err(keyring::Error::NoEntry) => Ok(false),
        Err(e) => Err(e),
    }
}

fn with_keyring_timeout<F, T, E>(f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, E> + Send + 'static,
    T: Send + 'static,
    E: std::fmt::Display + Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let res = f().map_err(|e| e.to_string());
        let _ = tx.send(res);
    });
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(res) => res,
        Err(_) => Err("keyring operation timed out after 2s".to_string()),
    }
}

/// Retrieve the versioned unseal key from the host OS keychain, or derive
/// and store it if missing.
///
/// @trace spec:tillandsias-vault
#[cfg(feature = "vault")]
fn ensure_unseal_key(debug: bool) -> Result<[u8; 32], String> {
    use base64::Engine;

    if is_running_in_vm()
        && let Some(cell) = IN_VM_CREDENTIALS.get()
        && let Ok(guard) = cell.lock()
        && let Some(creds) = &*guard
    {
        if let Some(encoded) = &creds.unseal_share_b64
            && let Ok(key_vec) = base64::engine::general_purpose::STANDARD.decode(encoded)
            && key_vec.len() == 32
        {
            if debug {
                eprintln!(
                    "[tillandsias-vault] recovered Shamir unseal share from host-delivered credentials (v1, base64)"
                );
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&key_vec);
            return Ok(key);
        }
        // Host didn't deliver a Shamir share. Try the local fallback file before
        // deriving the dummy key — the fallback was written during the initial
        // vault-init run and lets the headless self-recover when the Windows tray
        // hasn't received the GetVaultHandover handover yet.
        let cache_dir = crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
        let fallback_file = cache_dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"));
        if fallback_file.is_file()
            && let Ok(encoded) = fs::read_to_string(&fallback_file).map(|s| s.trim().to_string())
            && let Ok(key_vec) = base64::engine::general_purpose::STANDARD.decode(&encoded)
            && key_vec.len() == 32
        {
            if debug {
                eprintln!("[tillandsias-vault] recovered Shamir share from VM fallback file");
            }
            let mut key = [0u8; 32];
            key.copy_from_slice(&key_vec);
            return Ok(key);
        }
        // No fallback share found — derive a first-boot dummy key. The vault
        // container will generate the real share during init.
        if debug {
            eprintln!(
                "[tillandsias-vault] Shamir share not present in host credentials; deriving first-boot dummy key K"
            );
        }
        let machine_id = read_machine_id()?;
        let dummy_key = auto_unseal::derive_unseal_key(
            machine_id.as_bytes(),
            creds.installation_uuid.as_bytes(),
        );
        return Ok(dummy_key);
    }

    // 1. Try to get the Shamir share from the keychain
    let entry = Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1)
        .map_err(|e| format!("keyring entry for shamir share: {e}"))?;

    let encoded_res = with_keyring_timeout(move || entry.get_password());
    let encoded = match encoded_res {
        Ok(encoded) => encoded,
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] keyring Shamir share get failed/timed out ({e}); checking file fallback"
                );
            }
            let cache_dir =
                crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
            let fallback_file = cache_dir.join(format!("fallback_{}", VAULT_SHAMIR_SHARE_V1));
            if fallback_file.is_file() {
                fs::read_to_string(&fallback_file)
                    .map(|s| s.trim().to_string())
                    .unwrap_or_default()
            } else {
                String::new()
            }
        }
    };

    if !encoded.is_empty()
        && let Ok(key_vec) = base64::engine::general_purpose::STANDARD.decode(&encoded)
        && key_vec.len() == 32
    {
        if debug {
            eprintln!(
                "[tillandsias-vault] recovered Shamir unseal share from host keychain or fallback (v1, base64)"
            );
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&key_vec);
        return Ok(key);
    }

    // 2. Not in keychain (first boot). Return a dummy/filler unseal key derived from machine-id.
    // The container will generate the real Shamir share during init, which the host will capture later.
    if debug {
        eprintln!("[tillandsias-vault] Shamir share not found; deriving first-boot dummy key K");
    }

    let machine_id = read_machine_id()?;

    // Get or generate the installation anchor (UUID) from the keychain
    let anchor_entry = Entry::new(KEYCHAIN_SERVICE, INSTALL_ANCHOR_V1)
        .map_err(|e| format!("keyring anchor entry: {e}"))?;

    let anchor = match with_keyring_timeout(move || anchor_entry.get_password()) {
        Ok(a) => a,
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] keyring anchor get failed/timed out ({e}); checking file fallback"
                );
            }
            let cache_dir =
                crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
            let fallback_file = cache_dir.join("installation_anchor");
            let mut loaded = None;
            if fallback_file.is_file()
                && let Ok(a) = fs::read_to_string(&fallback_file)
            {
                let trimmed = a.trim().to_string();
                if !trimmed.is_empty() {
                    if debug {
                        eprintln!(
                            "[tillandsias-vault] loaded installation anchor from file fallback"
                        );
                    }
                    loaded = Some(trimmed);
                }
            }
            match loaded {
                Some(a) => a,
                None => {
                    // Generate a new one
                    let new_anchor = uuid::Uuid::new_v4().to_string();
                    if let Err(write_err) = fs::write(&fallback_file, &new_anchor) {
                        if debug {
                            eprintln!(
                                "[tillandsias-vault] failed to write installation anchor fallback: {write_err}"
                            );
                        }
                    } else {
                        #[cfg(unix)]
                        {
                            use std::os::unix::fs::PermissionsExt;
                            let _ = fs::set_permissions(
                                &fallback_file,
                                fs::Permissions::from_mode(0o600),
                            );
                        }
                    }
                    // Try to set in keyring asynchronously (best effort, don't hang if it blocks)
                    if let Ok(anchor_entry_clone) = Entry::new(KEYCHAIN_SERVICE, INSTALL_ANCHOR_V1)
                    {
                        let new_anchor_clone = new_anchor.clone();
                        let _ = std::thread::spawn(move || {
                            let _ = anchor_entry_clone.set_password(&new_anchor_clone);
                        });
                    }
                    new_anchor
                }
            }
        }
    };

    let dummy_key = auto_unseal::derive_unseal_key(machine_id.as_bytes(), anchor.as_bytes());
    Ok(dummy_key)
}

/// Fallback for non-vault builds.
#[cfg(not(feature = "vault"))]
fn ensure_unseal_key(_debug: bool) -> Result<[u8; 32], String> {
    Err("vault feature not compiled".into())
}

/// Sanitize the host OS keychain by removing stale unseal keys or anchors
/// from older versions.
#[cfg(feature = "vault")]
fn sanitize_keychain(debug: bool) {
    // Delete the legacy unseal key v1 (which held the derived HKDF key rather than the Shamir share)
    if let Ok(entry) = Entry::new(KEYCHAIN_SERVICE, "vault-unseal-v1") {
        let delete_res = with_keyring_timeout(move || entry.delete_credential());
        match delete_res {
            Err(e) => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] sanitize: failed/timed out deleting legacy vault-unseal-v1: {e}"
                    );
                }
            }
            Ok(_) => {
                if debug {
                    eprintln!("[tillandsias-vault] sanitize: deleted legacy vault-unseal-v1");
                }
            }
        }
    }
}

fn read_machine_id() -> Result<String, String> {
    let mut s = String::new();
    fs::File::open("/etc/machine-id")
        .map_err(|e| format!("open /etc/machine-id: {e}"))?
        .read_to_string(&mut s)
        .map_err(|e| format!("read /etc/machine-id: {e}"))?;
    let trimmed = s.trim().to_string();
    if trimmed.len() < 16 {
        return Err(format!(
            "/etc/machine-id too short ({} chars); refuse to derive unseal key",
            trimmed.len()
        ));
    }
    Ok(trimmed)
}

fn create_unseal_secret(key: &[u8; 32], debug: bool) -> Result<(), String> {
    // Atomic replace, NOT rm+create. A separate `secret rm` then `secret create`
    // races when two vault bootstraps run concurrently (e.g. `--init` while a
    // forge launch also calls ensure_vault_running): process B's rm can land
    // between A's rm and A's create, then A's create fails "secret name in use"
    // — a spurious bootstrap failure observed on Silverblue under concurrent
    // forge activity. `--replace` is server-side atomic + idempotent.
    // @trace spec:ephemeral-secret-refresh
    // @trace plan/issues/vault-secret-refresh-concurrent-race-2026-07-04.md
    if debug {
        eprintln!(
            "[tillandsias-vault] creating podman secret {VAULT_UNSEAL_SECRET} (32 bytes from HKDF)"
        );
    }
    let out = podman_cmd_sync()
        .args([
            "secret",
            "create",
            "--replace",
            "--driver=file",
            VAULT_UNSEAL_SECRET,
            "-",
        ])
        .output_bounded_with_stdin(
            key,
            tillandsias_podman::OperationKind::Secret.default_budget(),
        )
        .map_err(|e| format!("wait podman secret create: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "podman secret create failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

/// True iff the podman secret holding the vault unseal key already exists.
///
/// Presence — not content — gates the verify-before-persist reuse path in
/// `ensure_vault_running`: an existing secret is NEVER speculatively
/// replaced, because it may be the only key that unseals the existing
/// storage (the 2026-07-17 restart self-wedge).
/// @trace plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md
fn unseal_secret_exists() -> bool {
    podman_cmd_sync()
        .args(["secret", "inspect", VAULT_UNSEAL_SECRET])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status_bounded(tillandsias_podman::OperationKind::Secret.default_budget())
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Read the raw bytes of the existing unseal podman secret (file driver).
///
/// Returns `None` unless exactly 32 key bytes could be recovered — the
/// recovery seam refuses to overwrite a secret it cannot first read back,
/// because a failed recovery candidate could then not be restored away
/// (the secret would be left in an unknown mutated state).
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn read_unseal_secret_bytes() -> Option<Vec<u8>> {
    let out = podman_cmd_sync()
        .args([
            "secret",
            "inspect",
            "--showsecret",
            "--format",
            "{{.SecretData}}",
            VAULT_UNSEAL_SECRET,
        ])
        .output_bounded(tillandsias_podman::OperationKind::Secret.default_budget())
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let mut data = out.stdout;
    // The Go template writer appends exactly one newline after the entry;
    // strip only that one so a key whose final byte happens to be 0x0a
    // survives the round-trip.
    if data.last() == Some(&b'\n') {
        data.pop();
    }
    if data.len() == 32 { Some(data) } else { None }
}

/// Create (or replace) a podman secret holding the supplied token bytes.
/// Mode `0400`, file driver. Used for per-container AppRole tokens.
fn create_token_podman_secret(name: &str, token: &str, debug: bool) -> Result<(), String> {
    // Atomic replace, not the racy rm+create (see create_unseal_secret).
    // @trace spec:ephemeral-secret-refresh
    // @trace plan/issues/vault-secret-refresh-concurrent-race-2026-07-04.md
    if debug {
        eprintln!(
            "[tillandsias-vault] creating podman secret {name} ({} chars)",
            token.len()
        );
    }
    let out = podman_cmd_sync()
        .args(["secret", "create", "--replace", "--driver=file", name, "-"])
        .output_bounded_with_stdin(
            token.as_bytes(),
            tillandsias_podman::OperationKind::Secret.default_budget(),
        )
        .map_err(|e| format!("wait podman secret create: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "podman secret create {name} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

pub(crate) fn create_file_podman_secret(
    name: &str,
    path: &std::path::Path,
    debug: bool,
) -> Result<(), String> {
    let contents =
        fs::read(path).map_err(|e| format!("read podman secret source {}: {e}", path.display()))?;
    // Atomic replace, not the racy rm+create (see create_unseal_secret).
    // @trace plan/issues/vault-secret-refresh-concurrent-race-2026-07-04.md
    if debug {
        eprintln!(
            "[tillandsias-vault] refreshing podman secret {name} from {}",
            path.display()
        );
    }
    let out = podman_cmd_sync()
        .args(["secret", "create", "--replace", "--driver=file", name, "-"])
        .output_bounded_with_stdin(
            &contents,
            tillandsias_podman::OperationKind::Secret.default_budget(),
        )
        .map_err(|e| format!("wait podman secret create {name}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "podman secret create {name} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

fn refresh_vault_tls_secrets(certs_dir: &std::path::Path, debug: bool) -> Result<(), String> {
    create_file_podman_secret(VAULT_TLS_CERT_SECRET, &vault_tls_cert(certs_dir), debug)?;
    create_file_podman_secret(VAULT_TLS_KEY_SECRET, &vault_tls_key(certs_dir), debug)?;
    create_file_podman_secret(
        VAULT_TLS_CA_SECRET,
        &certs_dir.join("intermediate.crt"),
        debug,
    )
}

/// The `--volume` argument that persists Vault's file audit device (order
/// 749-8iw4, design T9).
///
/// Extracted so the CONTRACT is testable without podman (order 753-ii5f). The
/// first pin for this fix was five greps over the source, and an in-forge review
/// pointed out the obvious hole: a refactor can keep every grep green while
/// persistence breaks — most plausibly by moving the host directory somewhere
/// the container's `vault` user cannot write, since `vault audit list` reports a
/// healthy device either way. That blindness IS the original defect (V12); a
/// gate that cannot see it is not pinning the fix.
///
/// Three things are load-bearing and each has a test below:
///   * the destination is exactly `/vault/audit` — where
///     `images/vault/entrypoint.sh` enables the file device;
///   * the mount carries `:U`, because a userns mapping shift would otherwise
///     leave it owned by a uid `vault` cannot write, and an audit device that
///     cannot write is FATAL to Vault (every request fails once nothing can
///     record it);
///   * the host side is the caller's directory verbatim, so a change to
///     `init_cache_dir()` shows up as a changed argument rather than silently
///     relocating the records.
fn vault_audit_volume_arg(host_dir: &std::path::Path) -> String {
    format!("{}:/vault/audit:U", host_dir.display())
}

fn canonical_vault_launch_tag(image_tag: &str) -> Result<&str, String> {
    let digest = image_tag
        .strip_prefix("localhost/tillandsias-vault:sha256-")
        .ok_or_else(|| {
            format!(
                "refusing to launch Vault from non-canonical image tag {image_tag}; expected localhost/tillandsias-vault:sha256-<digest>"
            )
        })?;
    if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!(
            "refusing to launch Vault from malformed canonical image tag {image_tag}"
        ));
    }
    Ok(image_tag)
}

/// SELinux module name reported by `semodule -l` after the CIL below loads.
#[cfg(feature = "vault")]
const VAULT_SELINUX_MODULE: &str = "vault_container";

/// Minimal CIL declaring `vault_container_t` so the podman `label=type:` on the
/// vault launch is a valid type on an enforcing guest. See the asset header.
#[cfg(feature = "vault")]
const VAULT_SELINUX_CIL: &str = include_str!("../../../images/selinux/vault_container.cil");

/// Decide the `--security-opt label=...` VALUE for the vault container, or `None`
/// to use podman's default (`container_t`).
///
/// The custom confined type `vault_container_t` is ONLY a valid label when it is
/// actually loaded in the running SELinux policy. Loading it requires root
/// (`semodule -i`) — which headless has INSIDE the guest VM but NOT on a rootless
/// native-Linux host (Fedora Silverblue). If the type is neither loaded nor
/// loadable, we MUST NOT pass it: crun rejects an undefined type with EINVAL on
/// `/proc/self/attr/keycreate` and the container exits 126 — the P0 that broke
/// `tillandsias --init` on Silverblue for release v0.3.260702.2. In that case we
/// fall back to podman's default `container_t`, which is enforcing-safe and is
/// exactly how every other tillandsias container already runs on that host.
/// @trace plan/issues/selinux-vault-container-policy-phase3d-2026-06-30.md
/// @trace plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md
#[cfg(feature = "vault")]
fn vault_selinux_label_opt(debug: bool) -> Option<String> {
    // SELinux off/absent -> no MAC label needed; podman default is fine. On a
    // Disabled system `getenforce` prints "Disabled" or is missing.
    let enforcing_or_permissive = match Command::new("getenforce").output() {
        Ok(out) => {
            let s = String::from_utf8_lossy(&out.stdout);
            let s = s.trim();
            s.eq_ignore_ascii_case("Enforcing") || s.eq_ignore_ascii_case("Permissive")
        }
        Err(_) => false,
    };
    if !enforcing_or_permissive {
        // ASK IN THE RIGHT NAMESPACE (release gate, 2026-09-18).
        //
        // `getenforce` describes the namespace it RUNS IN; the container we are
        // about to launch is labelled by the HOST's policy. Those differ, and
        // the release gate runs inside the `tillandsias-builder` toolbox:
        //
        //     host                        getenforce -> Enforcing, /sys/fs/selinux/enforce = 1
        //     inside tillandsias-builder  getenforce -> Disabled,  selinuxfs NOT mounted
        //
        // So on an Enforcing host the probe concluded "SELinux is off", returned
        // None, and podman applied its DEFAULT container_t — the one outcome the
        // fallback below exists to avoid. Measured on the failed container:
        // SecurityOpt was [no-new-privileges] with NO label, ProcessLabel
        // container_t:s0:c317,c827, and vault exited 1 on boot with
        //
        //     AVC denied { read } comm="vault" name="_seal-config"
        //       scontext=system_u:system_r:container_t:s0:c317,c827
        //       tcontext=unconfined_u:object_r:cache_home_t:s0
        //
        // which is exactly root cause (1) of
        // plan/issues/vault-rootless-container-exits-immediately-2026-07-03.md
        // arriving through a path that issue's fix does not cover.
        //
        // DISCRIMINATED, not assumed. On ~/.cache/tillandsias/vault-data, which
        // is drwxr-xr-x so UNIX permits any uid to list it:
        //     podman default label   -> DENIED
        //     --security-opt label=disable -> LIST OK
        // (An earlier comparison used --userns=keep-id and the image's default
        // user; both arms then failed on UNIX perms on the 0700 core/ dir, so it
        // could not discriminate the label at all. Probe a path where the
        // confounder is neutral.)
        //
        // A CONTAINER WITHOUT selinuxfs CANNOT SEE THE HOST'S STATE, so its
        // "Disabled" is not evidence about the host. Treat it as UNKNOWN and pick
        // the option correct in BOTH regimes: label=disable is a no-op when
        // SELinux really is off, and is the documented fleet default when it is
        // on (spec:podman-container-spec lists it as a standard hardening
        // default). None is the only choice that can fail, so it must require
        // POSITIVE evidence — an unmounted selinuxfs inside a container is not
        // that.
        let containerized =
            Path::new("/run/.containerenv").exists() || Path::new("/.dockerenv").exists();
        let selinuxfs_visible = Path::new("/sys/fs/selinux/enforce").exists();
        if containerized && !selinuxfs_visible {
            if debug {
                eprintln!(
                    "[tillandsias-vault] getenforce reports not-enforcing but selinuxfs is not \
                     mounted in this container — the HOST's state is unknown from here; using \
                     label=disable, which is correct whether or not the host enforces"
                );
            }
            return Some("label=disable".to_string());
        }
        return None;
    }

    // Use the custom confined type only after loading the bundled CIL for this
    // exact binary. Existing VMs may have an older `vault_container` module
    // loaded; trusting presence alone preserves stale policy and keeps denying
    // the no-new-privileges transition.
    if try_load_vault_selinux_module(debug) && vault_container_type_loaded() {
        return Some("label=type:vault_container_t".to_string());
    }
    // Rootless native host (e.g. Fedora Silverblue): the custom type is not
    // loadable. Fall back to `label=disable`, NOT the default `container_t`.
    // Reason: the persistent vault data volume was created under an earlier
    // `label=disable` regime, so its files carry an unconfined SELinux label;
    // under `container_t` the vault process is DENIED access to /vault/data and
    // exits immediately on boot — the container vanishes before `podman wait
    // --condition=healthy` (seen on Silverblue as "no such container", status
    // 125). `label=disable` runs the vault container unconfined on the host —
    // the pre-Phase-3c behavior that worked on Silverblue. The confined
    // vault_container_t path still applies inside the guest VM (root).
    // @trace plan/issues/vault-rootless-container-exits-immediately-2026-07-03.md
    if debug {
        eprintln!(
            "[tillandsias-vault] vault_container_t not loadable (rootless host?); \
             using label=disable for the vault container (unconfined on host)"
        );
    }
    Some("label=disable".to_string())
}

/// True iff `semodule -l` confirms the `vault_container` module is loaded.
/// Conservative: any failure (semodule absent, not readable on a rootless host)
/// returns false so the caller falls back to the default label.
#[cfg(feature = "vault")]
fn vault_container_type_loaded() -> bool {
    matches!(
        Command::new("semodule").arg("-l").output(),
        Ok(out) if out.status.success()
            && String::from_utf8_lossy(&out.stdout)
                .lines()
                .any(|l| l.trim() == VAULT_SELINUX_MODULE)
    )
}

/// Best-effort load of the minimal `vault_container_t` CIL (root only). Returns
/// whether `semodule -i` succeeded. Stages the CIL to a WRITABLE temp dir — NOT
/// `/run`, which is not user-writable on a rootless host (the `os error 13`
/// staging failure seen on Silverblue).
#[cfg(feature = "vault")]
fn try_load_vault_selinux_module(debug: bool) -> bool {
    let cil_path = std::env::temp_dir().join(format!("{VAULT_SELINUX_MODULE}.cil"));
    if fs::write(&cil_path, VAULT_SELINUX_CIL).is_err() {
        return false;
    }
    let loaded = matches!(
        Command::new("semodule")
            .arg("-i")
            .arg(&cil_path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status(),
        Ok(s) if s.success()
    );
    let _ = fs::remove_file(&cil_path);
    if debug && loaded {
        eprintln!("[tillandsias-vault] loaded SELinux module {VAULT_SELINUX_MODULE} (permissive)");
    }
    loaded
}

/// Stub for builds without the `vault` feature so the call site compiles.
#[cfg(not(feature = "vault"))]
fn vault_selinux_label_opt(_debug: bool) -> Option<String> {
    None
}

/// The one line printed before the partial-init guard wipes the store
/// (order 1437-qza3): the store path, the missing share's name, and that every
/// credential in it is lost.
fn partial_init_wipe_line(vault_dir: &std::path::Path) -> String {
    format!(
        "[tillandsias-vault] WIPING {}: the unseal share {VAULT_SHAMIR_SHARE_V1} is in neither \
         the keyring nor its fallback file, so this store cannot be opened; every credential \
         stored in it is lost and Vault will be initialised afresh",
        vault_dir.display()
    )
}

fn launch_vault_container(image_tag: &str, debug: bool) -> Result<(), String> {
    let image_tag = canonical_vault_launch_tag(image_tag)?;
    let host_publish_arg = vault_host_publish_arg(is_running_in_vm());

    // Tear down any previous container with the same name (idempotent).
    let _ = podman_cmd_sync()
        .args(["rm", "-f", VAULT_CONTAINER_NAME])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output_bounded(tillandsias_podman::OperationKind::Container.default_budget());

    // Only wipe the data volume in the partial-init scenario: the volume
    // exists but the host keychain has no Shamir unseal share, meaning a
    // prior bootstrap started Vault's `operator init` but crashed before
    // the host captured the handover. In that state the volume holds a Vault
    // initialized with an unknown key, so wiping and re-initializing is the
    // only safe recovery.
    //
    // When the keychain already has the Shamir share the volume contains a
    // fully-initialized Vault we can re-unseal on the next launch.
    // Wiping it would destroy the stored GitHub token and all other secrets,
    // forcing the operator to re-authenticate — which is exactly the bug this
    // guard fixes. @trace spec:tillandsias-vault
    let is_partial_init = vault_data_volume_exists() && !has_shamir_share_in_keyring();
    if is_partial_init {
        let vault_dir = crate::init_cache_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("vault-data");
        // Order 1437-qza3: ALWAYS say this, not only under --debug. Since no
        // reset clears the share any more, reaching this branch means the
        // share went missing some other way, and the wipe below destroys every
        // stored sign-in. The operator must be able to see that it happened.
        eprintln!("{}", partial_init_wipe_line(&vault_dir));
        let _ = std::fs::remove_dir_all(vault_dir);
    } else if debug && vault_data_volume_exists() {
        eprintln!(
            "[tillandsias-vault] preserving existing data volume (Shamir share present in keychain)"
        );
    }

    // Vault must join the enclave bridge network so (a) `--network-alias vault`
    // is valid — rootless podman's DEFAULT network is pasta/slirp4netns, not
    // bridge, and aliases/static-ip are bridge-only ("networks and static
    // ip/mac address can only be used with Bridge mode networking"); and
    // (b) enclave containers can reach Vault by its alias. Idempotent — short-
    // circuits when the network already exists (it normally does, created
    // during `run_init`, but ensure here so the bootstrap is self-sufficient).
    crate::ensure_enclave_network(debug)?;

    // Phase 3d: `--security-opt label=type:vault_container_t` is only a VALID
    // label when that type is loaded in the policy (guest VM, root). On a
    // rootless native host it cannot be loaded, so we fall back to the default
    // container_t rather than crash crun with an undefined type (EINVAL, exit
    // 126). See vault_selinux_label_opt.
    // @trace plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md
    let selinux_label = vault_selinux_label_opt(debug);

    if debug {
        match &host_publish_arg {
            Some(publish) => eprintln!(
                "[tillandsias-vault] launching container {VAULT_CONTAINER_NAME} (alias {VAULT_NETWORK_ALIAS}:8200, native compatibility publish {publish})"
            ),
            None => eprintln!(
                "[tillandsias-vault] launching container {VAULT_CONTAINER_NAME} (alias {VAULT_NETWORK_ALIAS}:8200, no host publish)"
            ),
        }
    }

    let secret_arg = VAULT_UNSEAL_SECRET.to_string();
    let tls_cert_arg = VAULT_TLS_CERT_SECRET.to_string();
    let tls_key_arg = VAULT_TLS_KEY_SECRET.to_string();
    let tls_ca_arg = VAULT_TLS_CA_SECRET.to_string();
    // `:U` makes podman recursively chown the named volume to the container
    // process's mapped uid/gid (the image's `vault` user) on every launch.
    // Without it, a userns mapping shift between launches — which Fedora
    // Silverblue/ostree updates and `podman system reset` routinely cause —
    // leaves `/vault/data` owned by a uid the `vault` user can no longer
    // write, so the server dies on boot with "permission denied" on
    // /vault/data/core/_migration and `--github-login` then reports Vault as
    // not running. `:U` re-asserts ownership and self-repairs that drift.
    // @trace spec:tillandsias-vault
    let vault_dir = crate::init_cache_dir()
        .map_err(|e| e.to_string())?
        .join("vault-data");
    std::fs::create_dir_all(&vault_dir)
        .map_err(|e| format!("failed to create vault data dir: {}", e))?;
    let volume_arg = format!("{}:/vault/data:U", vault_dir.display());
    // Order 749-8iw4 (design T9). `images/vault/entrypoint.sh` enables a FILE
    // audit device at /vault/audit/audit.json, but nothing mounted /vault/audit
    // — so it was a container-layer directory (V12) and every audit record died
    // with the container. D11's third attribution channel therefore did not
    // exist in practice, and §4a row M6 ("the audit records carry project, lane,
    // principal, fingerprint, serial and refs AND survive a mirror/Vault
    // container recreation") could not pass however well the other rungs landed.
    //
    // The device was enabled and writing the whole time, which is what made this
    // easy to miss: `vault audit list` shows a healthy file device, and the
    // records are really there — until the container is recreated.
    //
    // `:U` for the same reason as /vault/data above: a userns mapping shift
    // between launches would otherwise leave the directory owned by a uid the
    // `vault` user cannot write, and an audit device that cannot write is FATAL
    // to Vault — every request fails once no audit device can record it.
    let vault_audit_dir = crate::init_cache_dir()
        .map_err(|e| e.to_string())?
        .join("vault-audit");
    std::fs::create_dir_all(&vault_audit_dir)
        .map_err(|e| format!("failed to create vault audit dir: {}", e))?;
    let audit_volume_arg = vault_audit_volume_arg(&vault_audit_dir);
    let mut run_args: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        // Order 387: a crashed/exited vault container holding the name must
        // not block relaunch with exit-125; --replace atomically removes it
        // (mirrors order 314/378/387 across the enclave stack).
        "--replace".into(),
        "--name".into(),
        VAULT_CONTAINER_NAME.into(),
        "--hostname".into(),
        VAULT_NETWORK_ALIAS.into(),
        // Bridge network for the alias + enclave reachability (see
        // launch_vault_container preamble). Must precede --network-alias.
        "--network".into(),
        crate::ENCLAVE_NET.into(),
        "--network-alias".into(),
        VAULT_NETWORK_ALIAS.into(),
        "--secret".into(),
        secret_arg,
        "--secret".into(),
        tls_cert_arg,
        "--secret".into(),
        tls_key_arg,
        "--secret".into(),
        tls_ca_arg,
        "--volume".into(),
        volume_arg,
        "--volume".into(),
        audit_volume_arg,
        "--tmpfs".into(),
        "/run/vault-handover:size=1m,mode=0777".into(),
        // NOTE: intentionally NO `--rm`. If vault crashes on boot (e.g. an
        // SELinux denial on /vault/data), `--rm` would delete the container
        // before we can read its logs — the "no such container" blindness seen
        // on Silverblue. The exited container is cleaned up by the `podman rm -f`
        // at the top of the next launch, so persisting it is safe and lets
        // wait_for_vault_ready dump `podman logs` on failure.
        "--cap-drop".into(),
        "ALL".into(),
        "--cap-add".into(),
        "IPC_LOCK".into(),
        "--security-opt".into(),
        "no-new-privileges".into(),
    ];
    // Custom SELinux label only when the type is actually loaded; otherwise
    // podman applies the default container_t (enforcing-safe).
    if let Some(label) = &selinux_label {
        run_args.push("--security-opt".into());
        run_args.push(label.clone());
    }
    run_args.extend(["--userns".into(), "keep-id".into()]);
    if let Some(publish) = host_publish_arg {
        run_args.extend(["-p".into(), publish]);
    }
    run_args.push(image_tag.to_string());
    let status = podman_cmd_sync()
        .args(&run_args)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status_bounded(tillandsias_podman::OperationKind::Container.default_budget())
        .map_err(|e| format!("spawn podman run: {e}"))?;
    if !status.success() {
        return Err(format!("podman run vault failed: {}", status));
    }
    Ok(())
}

/// On a failed health wait, surface WHY the vault container is unhealthy/gone.
/// Since the launch no longer passes `--rm`, a crashed container persists and
/// `podman logs` reveals the boot error (e.g. an SELinux denial on /vault/data).
#[cfg(feature = "vault")]
fn dump_vault_failure_diagnostics() {
    let ps = podman_cmd_sync()
        .args([
            "ps",
            "-a",
            "--filter",
            &format!("name={VAULT_CONTAINER_NAME}"),
            "--format",
            "{{.Names}} status={{.Status}} exit={{.ExitCode}}",
        ])
        .output_bounded(tillandsias_podman::OperationKind::Container.default_budget());
    if let Ok(out) = ps {
        let s = String::from_utf8_lossy(&out.stdout);
        let s = s.trim();
        if !s.is_empty() {
            eprintln!("[tillandsias-vault] container state: {s}");
        }
    }
    let logs = podman_cmd_sync()
        .args(["logs", "--tail", "40", VAULT_CONTAINER_NAME])
        .output_bounded(tillandsias_podman::OperationKind::Logs.default_budget());
    if let Ok(out) = logs {
        let combined = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let combined = combined.trim();
        if !combined.is_empty() {
            eprintln!("[tillandsias-vault] --- vault container logs (last 40 lines) ---");
            for line in combined.lines() {
                eprintln!("[tillandsias-vault] | {line}");
            }
            eprintln!("[tillandsias-vault] --- end vault container logs ---");
        }
    }
}

fn wait_for_vault_ready(
    rt: &crate::RuntimeOrHandle,
    base_url: &str,
    debug: bool,
) -> Result<String, String> {
    if debug {
        eprintln!("[tillandsias-vault] waiting for podman health status=healthy");
    }
    // Order 235 (R7): "container is stopped" / "no such container" during the
    // recreate window is TRANSIENT — the old container is being replaced
    // (observed on Silverblue, see the launch_vault_container --rm note).
    // Bounded retry (3 attempts, 2s apart) before treating it as the
    // permanent crash it usually is outside that window.
    let mut wait_result = Ok(());
    for attempt in 1..=3 {
        wait_result = rt.block_on(PodmanClient::new().wait_healthy(VAULT_CONTAINER_NAME));
        match &wait_result {
            Ok(()) => break,
            Err(e) => {
                let msg = e.to_string();
                let transient =
                    msg.contains("container is stopped") || msg.contains("no such container");
                if !transient || attempt == 3 {
                    break;
                }
                if debug {
                    eprintln!(
                        "[tillandsias-vault] health wait transient ({msg}); retry {attempt}/3"
                    );
                }
                // Inter-attempt backoff only — readiness detection itself
                // stays delegated to podman's wait_healthy above (the
                // vault_ready_wait_uses_podman_health pin forbids local
                // readiness sleep-POLLING; this bounded backoff between
                // wait_healthy attempts is not a readiness poll).
                //
                // The Sleep must be constructed inside block_on: creating it
                // as the argument runs on this (non-runtime) thread and
                // panics with "there is no reactor running" (live repro,
                // macOS guest list-cloud-projects 2026-07-16).
                rt.block_on(async { tokio::time::sleep(Duration::from_secs(2)).await });
            }
        }
    }
    if let Err(e) = wait_result {
        // The container likely crashed on boot. With no `--rm` it still exists,
        // so dump its logs + last state to make the failure diagnosable instead
        // of the opaque "no such container" / "did not report healthy".
        dump_vault_failure_diagnostics();
        return Err(format!("vault container did not report healthy: {e}"));
    }

    // Update /etc/hosts now that the container has a stable IP.
    update_etc_hosts_vault(debug);

    let client = vault_client(base_url, "", debug)?; // health doesn't need a token
    match wait_for_vault_api_ready(rt, &client, debug) {
        Ok(h) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] vault healthy (initialized={} sealed={} v={})",
                    h.initialized, h.sealed, h.version
                );
            }
            validated_root_token(rt, base_url, debug)
        }
        Err(e) => Err(format!("vault podman health is healthy but {e}")),
    }
}

// ─── Unseal-secret one-shot recovery seam ────────────────────────────────────
// Restart self-wedge fix (2026-07-17): a pre-existing unseal secret that the
// vault entrypoint PROVES does not unseal the initialized storage gets exactly
// one recovery attempt from the fail-loud share stores; every dead end emits
// the attended-recovery verdict ONCE and stops — no regeneration loop, storage
// untouched. Mirrors the order-383 `validated_root_token`/`heal_stale_root_token`
// discipline: escalate only on a positive, specific failure signal, and never
// touch on-disk/volume state while healing.
// @trace plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md

/// Entrypoint log markers the key-rejection classifier keys on. Pinned
/// against `images/vault/entrypoint.sh` by a test — update both together.
const UNSEAL_LOG_SUBSEQUENT_BOOT: &str = "subsequent boot: using unseal key from secret";
const UNSEAL_LOG_ATTEMPT: &str = "unsealing vault";
const UNSEAL_LOG_WRONG_KEY: &str = "FATAL: unseal request returned HTTP 400: wrong key";
const UNSEAL_LOG_SUCCESS: &str = "vault unsealed (sealed=false)";
const UNSEAL_LOG_ALREADY: &str = "vault already unsealed";

/// Combined stdout+stderr tail of the vault container, for the key-rejection
/// classifier. Empty when the container (or podman) is unavailable — which
/// classifies as NOT a key rejection.
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn vault_container_logs_tail() -> String {
    match podman_cmd_sync()
        .args(["logs", "--tail", "80", VAULT_CONTAINER_NAME])
        .output_bounded(tillandsias_podman::OperationKind::Logs.default_budget())
    {
        Ok(out) => format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
        Err(_) => String::new(),
    }
}

/// POSITIVE key-rejection classifier: true only when the entrypoint provably
/// reached the unseal step on INITIALIZED storage ("subsequent boot" — the
/// vault itself reported initialized=true), attempted the unseal, never
/// logged success, and the container has since died. Everything else —
/// empty logs, a still-running container, a first-boot init, a crash before
/// the unseal step, the order-235 transient recreate window — is NOT
/// evidence the key is wrong and must not trigger secret recovery.
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn unseal_failure_is_key_rejection(entrypoint_logs: &str, container_still_running: bool) -> bool {
    if container_still_running {
        return false;
    }
    entrypoint_logs.contains(UNSEAL_LOG_SUBSEQUENT_BOOT)
        && entrypoint_logs.contains(UNSEAL_LOG_ATTEMPT)
        && entrypoint_logs.contains(UNSEAL_LOG_WRONG_KEY)
        && !entrypoint_logs.contains(UNSEAL_LOG_SUCCESS)
        && !entrypoint_logs.contains(UNSEAL_LOG_ALREADY)
}

/// Pure gate for the one-shot recovery WRITE. A candidate key may be offered
/// to existing storage only when (a) the current (just-rejected) secret bytes
/// were read back, so a failed candidate can be restored away, and (b) the
/// candidate actually differs from those rejected bytes — a byte-identical
/// candidate PROVABLY fails to unseal and must never be written (exit
/// criterion: a unseal secret that fails to unseal existing storage is never
/// written/kept).
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn unseal_recovery_write_decision(
    candidate: &[u8; 32],
    rejected_existing: Option<&[u8]>,
) -> Result<(), &'static str> {
    match rejected_existing {
        None => Err(
            "the current unseal secret's bytes could not be read back for a safe \
             compare-and-restore (podman secret inspect --showsecret failed)",
        ),
        Some(prev) if prev == &candidate[..] => {
            Err("the only recoverable share is byte-identical to the secret vault just rejected")
        }
        Some(_) => Ok(()),
    }
}

/// One-shot guard for the unseal recovery seam (the order-281 `healed`-flag
/// pattern): set the moment an attempt is consumed, cleared only by a
/// verified successful unseal. While set, the seam re-states a compact
/// verdict and never writes the secret again, so a liveness re-ensure cycle
/// cannot become the 2026-07-17 self-sustaining regeneration wedge.
#[cfg(feature = "vault")]
static UNSEAL_RECOVERY_ATTEMPTED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Build (and loudly print, exactly once per process — every caller sits
/// behind the one-shot guard) the attended-recovery verdict for an unseal
/// secret that cannot be self-healed. Mirrors the order-383
/// `heal_stale_root_token` messaging: actionable, and explicit that storage
/// was preserved.
#[cfg(feature = "vault")]
fn attended_unseal_verdict(reason: &str) -> String {
    let cache_hint = crate::init_cache_dir()
        .map(|d| d.display().to_string())
        .unwrap_or_else(|_| "<tillandsias cache dir>".to_string());
    let msg = format!(
        "OPERATOR ACTION REQUIRED: the vault unseal secret does not unseal the existing \
         vault storage and self-recovery is not possible ({reason}). Vault storage was left \
         untouched — it may hold real operator secrets. Recover the correct 32-byte Shamir \
         share (OS keychain entry '{VAULT_SHAMIR_SHARE_V1}', or \
         {cache_hint}/fallback_{VAULT_SHAMIR_SHARE_V1}; the matching share's mtime equals \
         the vault-data init time), restore it with `base64 -d share.b64 | podman secret \
         create --replace --driver=file {VAULT_UNSEAL_SECRET} -`, then restart tillandsias. \
         Do NOT wipe the vault-data volume."
    );
    eprintln!("[tillandsias-vault] {msg}");
    msg
}

/// One-shot recovery for a pre-existing unseal secret that failed the launch.
///
/// Entered from `ensure_vault_running` ONLY when the launch reused an
/// already-existing podman secret and `wait_for_vault_ready` failed. The
/// seam: (1) requires the positive key-rejection signal from the container's
/// own entrypoint logs — every other failure class propagates unchanged;
/// (2) consumes the process-wide one-shot guard; (3) sources a candidate
/// exclusively from the fail-loud share readers (`read_shamir_share_b64` —
/// never the machine-id dummy derivation); (4) writes it only when the pure
/// decision proves it differs from the rejected bytes AND those bytes were
/// captured for restore; (5) on a second unseal failure restores the prior
/// bytes and emits the attended verdict. Storage is never touched on any
/// path.
#[cfg(feature = "vault")]
fn recover_rejected_unseal_secret_once(
    rt: &crate::RuntimeOrHandle,
    base_url: &str,
    image_tag: &str,
    wait_err: &str,
    debug: bool,
) -> Result<String, String> {
    use base64::Engine;
    use std::sync::atomic::Ordering;

    // (1) Positive signal only. The order-235 bounded retry inside
    // wait_for_vault_ready already absorbed genuine recreate-window
    // transients before we got here; anything that is not a proven key
    // rejection keeps its original error.
    let logs = vault_container_logs_tail();
    if !unseal_failure_is_key_rejection(&logs, container_running(VAULT_CONTAINER_NAME)) {
        return Err(wait_err.to_string());
    }

    eprintln!(
        "[tillandsias-vault] existing unseal secret was REJECTED by the initialized vault \
         storage (the entrypoint reached the unseal step and failed it)"
    );

    // (2) One shot per process.
    if UNSEAL_RECOVERY_ATTEMPTED.swap(true, Ordering::SeqCst) {
        return Err(
            "vault unseal secret still fails to unseal the existing storage; attended \
             recovery required (the one-shot recovery attempt and its OPERATOR ACTION \
             REQUIRED verdict were already emitted — this process will not regenerate \
             the unseal secret again)"
                .to_string(),
        );
    }

    // (3) Candidate from the fail-loud share stores only.
    let share_b64 = match read_shamir_share_b64(debug) {
        Ok(s) => s,
        Err(e) => {
            return Err(attended_unseal_verdict(&format!(
                "no recoverable Shamir share is available ({e})"
            )));
        }
    };
    let mut candidate_vec = base64::engine::general_purpose::STANDARD
        .decode(share_b64.trim())
        .map_err(|e| format!("recovered Shamir share is not valid base64: {e}"))?;
    if candidate_vec.len() != 32 {
        let n = candidate_vec.len();
        candidate_vec.zeroize();
        return Err(attended_unseal_verdict(&format!(
            "recovered Shamir share decodes to {n} bytes, want 32"
        )));
    }
    let mut candidate = [0u8; 32];
    candidate.copy_from_slice(&candidate_vec);
    candidate_vec.zeroize();

    // (4) Write only what can still be undone and is not proven-failing.
    let mut existing = read_unseal_secret_bytes();
    if let Err(reason) = unseal_recovery_write_decision(&candidate, existing.as_deref()) {
        candidate.zeroize();
        if let Some(prev) = existing.as_mut() {
            prev.zeroize();
        }
        return Err(attended_unseal_verdict(reason));
    }

    eprintln!(
        "[tillandsias-vault] one-shot recovery: offering the keychain/fallback share to \
         the existing storage (the rejected bytes are held for restore)"
    );
    let write_res = create_unseal_secret(&candidate, debug);
    candidate.zeroize();
    write_res?;
    launch_vault_container(image_tag, debug)?;
    match wait_for_vault_ready(rt, base_url, debug) {
        Ok(token) => {
            if let Some(prev) = existing.as_mut() {
                prev.zeroize();
            }
            eprintln!(
                "[tillandsias-vault] recovery succeeded: the recovered share unseals the \
                 existing storage; podman secret {VAULT_UNSEAL_SECRET} repaired"
            );
            // Verified healed — re-arm so a future, distinct wedge (after
            // this proven-working state) gets its own single attempt.
            UNSEAL_RECOVERY_ATTEMPTED.store(false, Ordering::SeqCst);
            Ok(token)
        }
        Err(second_err) => {
            // (5) The candidate did not unseal either — it must not be KEPT.
            // Restore the prior bytes so the secret is not left in an
            // unknown mutated state, then fail loud exactly once.
            if let Some(prev) = existing.as_mut() {
                let mut prev_key = [0u8; 32];
                prev_key.copy_from_slice(prev);
                prev.zeroize();
                if let Err(e) = create_unseal_secret(&prev_key, debug) {
                    eprintln!(
                        "[tillandsias-vault] WARN: could not restore the prior unseal \
                         secret bytes after the failed recovery attempt: {e}"
                    );
                }
                prev_key.zeroize();
            }
            Err(attended_unseal_verdict(&format!(
                "the recovered share also failed to unseal ({second_err})"
            )))
        }
    }
}

/// Stub for builds without the `vault` feature: those builds never reuse an
/// existing secret (the gate is `cfg!(feature = "vault")`-qualified), so the
/// original wait error simply propagates.
#[cfg(not(feature = "vault"))]
fn recover_rejected_unseal_secret_once(
    _rt: &crate::RuntimeOrHandle,
    _base_url: &str,
    _image_tag: &str,
    wait_err: &str,
    _debug: bool,
) -> Result<String, String> {
    Err(wait_err.to_string())
}

/// Resolve the current vault container IP and update /etc/hosts so the
/// process-local hostname `vault` always points to it. The headless process
/// is not inside any podman network so aardvark-dns doesn't reach it; only
/// /etc/hosts does.
#[cfg(feature = "vault")]
fn update_etc_hosts_vault(debug: bool) {
    #[cfg(unix)]
    let is_root = unsafe { libc::geteuid() == 0 };
    #[cfg(not(unix))]
    let is_root = false;

    if !is_root {
        if debug {
            eprintln!("[tillandsias-vault] skipping /etc/hosts update: not root");
        }
        return;
    }

    let out = match podman_cmd_sync()
        .args([
            "inspect",
            VAULT_CONTAINER_NAME,
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}\n{{end}}",
        ])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
    {
        Ok(o) => o,
        Err(e) => {
            eprintln!("[tillandsias-vault] /etc/hosts update skipped: podman inspect failed: {e}");
            return;
        }
    };
    if !out.status.success() {
        eprintln!(
            "[tillandsias-vault] /etc/hosts update skipped: podman inspect exit {}",
            out.status
        );
        return;
    }
    let ip = match String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(str::to_owned)
    {
        Some(ip) => ip,
        None => {
            eprintln!("[tillandsias-vault] /etc/hosts update skipped: no IP from podman inspect");
            return;
        }
    };
    let hosts = fs::read_to_string("/etc/hosts").unwrap_or_default();
    let mut new_content: String = hosts
        .lines()
        .filter(|l| !l.split_whitespace().any(|w| w == "vault"))
        .collect::<Vec<_>>()
        .join("\n");
    if !new_content.ends_with('\n') && !new_content.is_empty() {
        new_content.push('\n');
    }
    new_content.push_str(&format!("{ip} vault\n"));
    if let Err(e) = fs::write("/etc/hosts", &new_content) {
        eprintln!("[tillandsias-vault] /etc/hosts update failed: {e}");
        return;
    }
    if debug {
        eprintln!("[tillandsias-vault] /etc/hosts: vault → {ip}");
    }
}

/// Read a single handover file from the running Vault container's tmpfs.
/// Returns `None` when the file is absent (a subsequent boot — the entrypoint
/// only writes the handover on a fresh `operator init`) or empty.
#[cfg(feature = "vault")]
fn read_handover_file(name: &str) -> Option<String> {
    let out = podman_cmd_sync()
        .args([
            "exec",
            VAULT_CONTAINER_NAME,
            "cat",
            &format!("/run/vault-handover/{name}"),
        ])
        .output_bounded(tillandsias_podman::OperationKind::Container.default_budget())
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if value.is_empty() { None } else { Some(value) }
}

/// Write (or overwrite) a host keychain entry, isolating the (potentially
/// blocking, runtime-using) secret-service call on its own thread.
#[cfg(feature = "vault")]
fn keychain_set_blocking(user: &str, value: &str) -> Result<(), String> {
    let entry =
        Entry::new(KEYCHAIN_SERVICE, user).map_err(|e| format!("keyring entry {user}: {e}"))?;
    let value = value.to_string();
    let value_clone = value.clone();
    match with_keyring_timeout(move || entry.set_password(&value_clone)) {
        Ok(()) => Ok(()),
        Err(e) => {
            eprintln!(
                "[tillandsias-vault] note: OS keyring unavailable for {user} ({e}); \
                 using fallback file (expected in VM guest and headless environments)"
            );
            let cache_dir =
                crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
            let fallback_file = cache_dir.join(format!("fallback_{}", user));
            fs::write(&fallback_file, &value)
                .map_err(|err| format!("write fallback file: {err}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(&fallback_file, fs::Permissions::from_mode(0o600));
            }
            Ok(())
        }
    }
}

/// Outcome of one post-heal reachability probe, collapsed from
/// [`VaultError`] for the order-383 classifier.
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
#[derive(Debug, Clone, PartialEq, Eq)]
enum ProbeOutcome {
    /// The path answered with the token — reachable and permitted.
    Reachable,
    /// 404 — the path is permitted but holds nothing yet (empty AppRole
    /// backend, github token not stored). Healthy for a fresh vault.
    Absent,
    /// 401/403 — the token/storage skew is deeper than the root token
    /// (the 2026-07-17 Windows wrinkle).
    Denied,
    /// Transport/sealed/other — reachability could not be proven.
    Failed(String),
}

#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn probe_outcome<T>(res: Result<T, VaultError>) -> ProbeOutcome {
    match res {
        Ok(_) => ProbeOutcome::Reachable,
        Err(VaultError::NotFound(_)) => ProbeOutcome::Absent,
        Err(VaultError::Unauthorized(_)) => ProbeOutcome::Denied,
        Err(e) => ProbeOutcome::Failed(e.to_string()),
    }
}

/// Order 383 post-heal verdict: a generate-root heal may only report
/// success when the fresh root token demonstrably reaches the token
/// store, the AppRole backend, AND the KV mount. The third live repro
/// (Windows, 2026-07-17) minted a fresh root token whose `policy list`
/// worked while approle list + KV get still 403'd — reporting success on
/// lookup-self alone would have hidden exactly that skew.
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn classify_post_heal(
    lookup: &ProbeOutcome,
    approle: &ProbeOutcome,
    kv: &ProbeOutcome,
) -> Result<(), String> {
    let mut failures = Vec::new();
    if *lookup != ProbeOutcome::Reachable {
        failures.push(format!("token lookup-self: {lookup:?}"));
    }
    for (name, outcome) in [("approle role list", approle), ("KV secret read", kv)] {
        match outcome {
            ProbeOutcome::Reachable | ProbeOutcome::Absent => {}
            other => failures.push(format!("{name}: {other:?}")),
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

/// A first-boot handover pair may be persisted to the host keychain only
/// when it is structurally plausible: a Vault service token (`hvs.` — or
/// legacy `s.` — prefix) plus a base64 32-byte Shamir share. Live repro
/// 2026-07-17 (macuahuitl): a litmus run with a mocked podman backend fed
/// `mock-exec-output` through this path and OVERWROTE the operator's real
/// keychain credentials, wedging the real vault (order 383's linux
/// variant). Garbage must fail loud here, never be persisted.
#[cfg_attr(not(feature = "vault"), allow(dead_code))]
fn handover_pair_is_persistable(token: &str, share_b64: &str) -> bool {
    use base64::Engine;
    let token = token.trim();
    let token_ok = token.starts_with("hvs.") || token.starts_with("s.");
    let share_ok = base64::engine::general_purpose::STANDARD
        .decode(share_b64.trim())
        .map(|v| v.len() == 32)
        .unwrap_or(false);
    token_ok && share_ok
}

/// Read the stored Shamir unseal share (base64, 32 bytes decoded) from
/// host-delivered VM credentials, the OS keychain, or the fallback file —
/// the same precedence `ensure_unseal_key` uses, but failing loud instead
/// of deriving a machine-id dummy: the heal path must never feed a
/// fabricated share into `generate-root`.
#[cfg(feature = "vault")]
fn read_shamir_share_b64(debug: bool) -> Result<String, String> {
    let mut candidates = shamir_share_candidates();
    if candidates.is_empty() {
        return Err(
            "no valid 32-byte base64 Shamir share in VM credentials, host keychain, or fallback file"
                .to_string(),
        );
    }
    let (source, share) = candidates.remove(0);
    if debug {
        eprintln!("[tillandsias-vault] heal: using Shamir share from {source}");
    }
    Ok(share)
}

/// Append `encoded` to `list` iff it is a valid 32-byte base64 share not
/// already present under another source label.
#[cfg(feature = "vault")]
fn push_share_candidate(
    list: &mut Vec<(&'static str, String)>,
    label: &'static str,
    encoded: String,
) {
    use base64::Engine;
    let valid = !encoded.is_empty()
        && base64::engine::general_purpose::STANDARD
            .decode(&encoded)
            .map(|v| v.len() == 32)
            .unwrap_or(false);
    if valid && !list.iter().any(|(_, existing)| *existing == encoded) {
        list.push((label, encoded));
    }
}

/// Ordered, validated, deduplicated Shamir-share candidates for the
/// generate-root self-heal: the guest's OWN podman secret first, then
/// host-delivered credentials, host keychain, and the guest-local fallback
/// file. The sources can legitimately disagree after a storage re-init — e.g.
/// the host keychain pinned to a previous vault-data epoch while the guest
/// fallback file tracks the current one (the 2026-07-28 Windows login wedge) —
/// so the heal must be able to fall through to the next source when
/// generate-root rejects one.
///
/// WHY THE PODMAN SECRET LEADS (order 803-49re, operator incident 2026-08-17).
/// Every host-derived source can be stale against the live storage, and on that
/// incident all three of them were: the operator's login failed for an hour
/// while the self-heal retried three shares that could not authenticate. The
/// share that WOULD have worked was sitting in this guest's own
/// `tillandsias-vault-unseal` podman secret — the key the vault entrypoint had
/// already unsealed this very storage with, in the same boot
/// ("unseal key material loaded (32 bytes)", "vault unsealed (sealed=false)").
/// The heal never consulted it, and told the operator to "recover the correct
/// share or perform an attended storage-preserving re-init" for a vault that
/// was healthy and unsealed the whole time.
///
/// It leads rather than trails because it is the only source with direct
/// evidence for the CURRENT storage epoch: it is not a copy of a key that
/// unsealed something once, it is the key this running vault unsealed with.
/// Ordering is otherwise behaviour-preserving — every candidate is still tried
/// until one authenticates, and two candidates that both authenticate against
/// one storage epoch are necessarily the same key.
/// The ORDER, and nothing else — pure so a test can assert the real ordering
/// rather than a hand-written copy of it.
///
/// Order 803-49re. A test that rebuilds the candidate list itself pins only the
/// author's intent: the production order could be changed underneath it and the
/// test would stay green. Every caller of this ordering goes through here.
#[cfg(feature = "vault")]
fn assemble_share_candidates(
    guest_podman_secret: Option<String>,
    host_delivered: Option<String>,
    host_keychain: Option<String>,
    fallback_file: Option<String>,
) -> Vec<(&'static str, String)> {
    let mut candidates: Vec<(&'static str, String)> = Vec::new();
    for (label, value) in [
        ("guest podman secret", guest_podman_secret),
        ("host-delivered credentials", host_delivered),
        ("host keychain", host_keychain),
        ("fallback file", fallback_file),
    ] {
        if let Some(v) = value {
            push_share_candidate(&mut candidates, label, v.trim().to_string());
        }
    }
    candidates
}

#[cfg(feature = "vault")]
fn shamir_share_candidates() -> Vec<(&'static str, String)> {
    // The guest's own unseal secret, base64-encoded to match the other sources.
    // `read_unseal_secret_bytes` already refuses anything that is not exactly 32
    // recovered key bytes, and `push_share_candidate` validates and dedupes, so
    // a podman that is absent, errors, or short-reads simply contributes no
    // candidate — it can never displace a working one.
    let guest_podman_secret = read_unseal_secret_bytes().map(|bytes| {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(bytes)
    });

    let host_delivered = if is_running_in_vm() {
        IN_VM_CREDENTIALS.get().and_then(|cell| {
            cell.lock()
                .ok()
                .and_then(|g| g.as_ref()?.unseal_share_b64.clone())
        })
    } else {
        None
    };

    let host_keychain = Entry::new(KEYCHAIN_SERVICE, VAULT_SHAMIR_SHARE_V1)
        .ok()
        .and_then(|entry| with_keyring_timeout(move || entry.get_password()).ok());

    let fallback_file = crate::init_cache_dir().ok().and_then(|dir| {
        fs::read_to_string(dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"))).ok()
    });

    assemble_share_candidates(
        guest_podman_secret,
        host_delivered,
        host_keychain,
        fallback_file,
    )
}

/// Persist a freshly minted (healed) root token to the same stores the
/// first-boot handover uses, so every later `read_and_handover_root_token`
/// sees the healed value.
#[cfg(feature = "vault")]
fn persist_healed_root_token(token: &str, share_b64: &str, debug: bool) -> Result<(), String> {
    if is_running_in_vm() {
        let cell = PENDING_HANDOVER.get_or_init(|| Mutex::new(None));
        if let Ok(mut guard) = cell.lock() {
            *guard = Some(PendingHandover {
                unseal_share_b64: Some(share_b64.to_string()),
                root_token: Some(token.to_string()),
            });
        }
        let creds_cell = IN_VM_CREDENTIALS.get_or_init(|| Mutex::new(None));
        if let Ok(mut guard) = creds_cell.lock() {
            if let Some(creds) = guard.as_mut() {
                creds.root_token = Some(token.to_string());
                // The winning share just authenticated generate-root against
                // the current storage epoch; replace any stale delivered
                // share so later heals in this process start from it.
                creds.unseal_share_b64 = Some(share_b64.to_string());
            } else {
                *guard = Some(InVmCredentials {
                    unseal_share_b64: Some(share_b64.to_string()),
                    installation_uuid: String::new(),
                    root_token: Some(token.to_string()),
                });
            }
        }
        let cache_dir = crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
        let fallback_file = cache_dir.join("fallback_vault-root-token-v1");
        fs::write(&fallback_file, token).map_err(|err| format!("write fallback file: {err}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&fallback_file, fs::Permissions::from_mode(0o600));
        }
        // Persist the winning share alongside the token so the next boot's
        // partial-init check and self-heal read the storage-matching share
        // even if it originally came from a host-delivered source.
        let share_file = cache_dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"));
        fs::write(&share_file, share_b64)
            .map_err(|err| format!("write share fallback file: {err}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&share_file, fs::Permissions::from_mode(0o600));
        }
        if debug {
            eprintln!("[tillandsias-vault] heal: persisted fresh root token to VM stores");
        }
        return Ok(());
    }
    keychain_set_blocking("vault-root-token-v1", token)?;
    if debug {
        eprintln!("[tillandsias-vault] heal: persisted fresh root token to host keychain");
    }
    Ok(())
}

/// Order 383: mint a fresh root token from the stored Shamir share via
/// `vault operator generate-root` — healing a stale/rotated cached root
/// token WITHOUT touching vault storage, which may hold real operator
/// secrets. Three live repros (macOS, linux/macuahuitl, Windows) hit this
/// skew: the data volume is healthy but every cached-root-token write
/// path fails `permission denied`.
///
/// This function NEVER wipes or re-initializes storage. Every failure
/// path surfaces a loud OPERATOR ACTION REQUIRED verdict and leaves the
/// vault-data volume untouched.
#[cfg(feature = "vault")]
fn heal_stale_root_token(
    rt: &crate::RuntimeOrHandle,
    base_url: &str,
    debug: bool,
) -> Result<String, String> {
    let candidates = shamir_share_candidates();
    if candidates.is_empty() {
        return Err(
            "OPERATOR ACTION REQUIRED: vault rejects the cached root token and no valid \
             Shamir share is available to self-heal (no valid 32-byte base64 Shamir share in \
             the guest podman secret, VM credentials, host keychain, or fallback file). Vault \
             storage was left untouched — it may hold real secrets. Recover the share, or \
             perform an attended storage-preserving re-init. Do NOT wipe the vault-data volume."
                .to_string(),
        );
    }

    eprintln!(
        "[tillandsias-vault] running `generate-root` self-heal from the stored Shamir share (order 383)"
    );
    let anon = vault_client(base_url, "", debug)?;
    // The share sources can disagree after a storage re-init (stale host
    // keychain vs current guest fallback file); try each candidate until
    // one authenticates generate-root against the current storage epoch.
    let mut rejections: Vec<String> = Vec::new();
    for (source, share_b64) in &candidates {
        // A stale half-finished attempt keeps its nonce but never re-reveals
        // its OTP; cancel unconditionally so we always own a fresh attempt.
        let _ = rt.block_on(anon.generate_root_cancel());
        let attempt = rt
            .block_on(anon.generate_root_start())
            .map_err(|e| format!("generate-root start failed: {e}"))?;
        if attempt.required > 1 {
            return Err(format!(
                "OPERATOR ACTION REQUIRED: this vault needs {} unseal key shares for generate-root \
                 but the host stores exactly one. Complete `vault operator generate-root` manually \
                 with the remaining shares. Storage untouched.",
                attempt.required
            ));
        }
        let progress = match rt.block_on(anon.generate_root_update(share_b64, &attempt.nonce)) {
            Ok(progress) => progress,
            Err(e) => {
                eprintln!(
                    "[tillandsias-vault] heal: {source} Shamir share rejected by generate-root \
                     ({e}); trying next share source"
                );
                rejections.push(format!("{source}: {e}"));
                continue;
            }
        };
        if !progress.complete {
            return Err(
                "OPERATOR ACTION REQUIRED: generate-root accepted the share but did not complete \
                 (more shares required than the host stores). Storage untouched."
                    .to_string(),
            );
        }
        let encoded = progress
            .encoded_token
            .ok_or("generate-root completed but returned no encoded token")?;
        let token = tillandsias_vault_client::decode_generated_root_token(&encoded, &attempt.otp)
            .map_err(|e| format!("generate-root token decode failed: {e}"))?;

        // The 2026-07-17 Windows wrinkle: a fresh root token whose `policy
        // list` works can still 403 on approle + KV. Verify actual
        // reachability before reporting success.
        let healed = vault_client(base_url, &token, debug)?;
        let lookup = probe_outcome(rt.block_on(healed.token_lookup_self()));
        let approle = probe_outcome(rt.block_on(healed.list_approle_roles()));
        let kv = probe_outcome(rt.block_on(healed.read_secret("secret/github/token")));
        classify_post_heal(&lookup, &approle, &kv).map_err(|reason| {
            format!(
                "OPERATOR ACTION REQUIRED: generate-root minted a fresh root token but the vault is \
                 still not fully reachable ({reason}). The token/storage skew is deeper than the \
                 root token. Storage was left untouched — KV data (including any operator github \
                 token) is intact but unreadable until an attended storage-preserving re-init. \
                 Do NOT wipe the vault-data volume."
            )
        })?;

        persist_healed_root_token(&token, share_b64, debug)?;
        eprintln!(
            "[tillandsias-vault] generate-root self-heal succeeded: fresh root token minted, \
             verified (lookup-self + approle + KV), and persisted (share source: {source})"
        );
        return Ok(token);
    }

    Err(format!(
        "OPERATOR ACTION REQUIRED: generate-root rejected the stored Shamir share ({}). \
         The share no longer matches vault storage. Storage was left untouched — recover \
         the correct share or perform an attended storage-preserving re-init. Do NOT wipe \
         the vault-data volume.",
        rejections.join("; ")
    ))
}

#[cfg(not(feature = "vault"))]
fn heal_stale_root_token(
    _rt: &crate::RuntimeOrHandle,
    _base_url: &str,
    _debug: bool,
) -> Result<String, String> {
    Err("vault feature not compiled".into())
}

/// Order 383 detect-and-heal seam: resolve the root token, prove the
/// token store actually accepts it, and self-heal via
/// [`heal_stale_root_token`] when it is stale. Both vault bring-up paths
/// (already-running probe and post-launch readiness) route through here
/// so a token/storage skew can never wedge the bootstrap silently again.
fn validated_root_token(
    rt: &crate::RuntimeOrHandle,
    base_url: &str,
    debug: bool,
) -> Result<String, String> {
    match read_and_handover_root_token(debug) {
        Ok(token) => {
            let client = vault_client(base_url, &token, debug)?;
            match rt.block_on(client.token_lookup_self()) {
                Ok(()) => Ok(token),
                Err(VaultError::Unauthorized(detail)) => {
                    eprintln!(
                        "[tillandsias-vault] cached root token rejected by the token store \
                         ({detail}); attempting generate-root self-heal (order 383)"
                    );
                    heal_stale_root_token(rt, base_url, debug)
                }
                Err(e) => {
                    // Transport/sealed failures are not evidence of a stale
                    // token — do not mint a new root over a network blip;
                    // the first real use will surface the true error.
                    if debug {
                        eprintln!(
                            "[tillandsias-vault] token lookup-self probe inconclusive ({e}); \
                             proceeding with cached token"
                        );
                    }
                    Ok(token)
                }
            }
        }
        Err(read_err) => {
            // No usable cached token at all. A valid share can still mint
            // one without touching storage — strictly better than the old
            // "reset the volume" guidance.
            eprintln!(
                "[tillandsias-vault] no usable cached root token ({read_err}); attempting \
                 generate-root self-heal (order 383)"
            );
            heal_stale_root_token(rt, base_url, debug).map_err(|heal_err| {
                format!("{read_err}; generate-root self-heal also failed: {heal_err}")
            })
        }
    }
}

/// Read the root token, capturing a fresh first-boot handover when present.
///
/// CRITICAL ORDERING: the container tmpfs handover (`/run/vault-handover/`) is
/// written ONLY when the entrypoint runs a fresh `operator init` — i.e. the
/// data volume was just created. Whenever those artifacts exist we MUST capture
/// them and OVERWRITE the keychain, even if a stale token/share from a previous
/// (now-discarded) volume still lives there. The previous version returned early
/// on any keychain root token and so never refreshed the share — re-initializing
/// the data volume (Silverblue userns drift, `podman volume rm`, a reset) left
/// the keychain pinned to the OLD share, and every later boot then failed to
/// unseal the NEW volume ("cipher: message authentication failed", HTTP 400) —
/// an unrecoverable brick. Capturing handover-first makes a fresh init always
/// re-pair the keychain with the live volume.
#[cfg(feature = "vault")]
fn read_and_handover_root_token(debug: bool) -> Result<String, String> {
    // 1. Fresh-init handover takes precedence over any stale keychain state.
    if let Some(token) = read_handover_file("root.token") {
        let share_b64 = read_handover_file("unseal.key").ok_or(
            "vault wrote a handover root token but no Shamir share — refusing to \
             persist an unusable keychain pairing",
        )?;
        if !handover_pair_is_persistable(&token, &share_b64) {
            // Live repro 2026-07-17 (macuahuitl): a mocked-podman litmus fed
            // `mock-exec-output` through this path and overwrote the
            // operator's REAL keychain credentials. Malformed handover
            // artifacts must fail loud, never be persisted.
            return Err(format!(
                "vault handover files are present but malformed (token prefix {:?}, share \
                 {} chars) — refusing to overwrite possibly-good keychain credentials. If \
                 this run used a mocked podman backend, the harness must isolate the \
                 keychain too.",
                token.chars().take(4).collect::<String>(),
                share_b64.len()
            ));
        }
        if debug {
            eprintln!(
                "[tillandsias-vault] fresh-init handover present; capturing root token + Shamir share into keychain (overwriting any stale entries)"
            );
        }
        // Restart self-wedge fix: at this moment the podman secret still holds
        // the FIRST-BOOT dummy key — the entrypoint ignored it when it ran the
        // fresh init and generated the real share itself. Re-pair the podman
        // secret with that just-generated share NOW, while it is correct for
        // this storage by construction, so the next restart reuses a matching
        // secret instead of crashing into the one-shot unseal recovery seam.
        // Best-effort-loud: on failure that seam self-heals at the next launch.
        // @trace plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md
        {
            use base64::Engine;
            if let Ok(mut key_vec) =
                base64::engine::general_purpose::STANDARD.decode(share_b64.trim())
                && key_vec.len() == 32
            {
                let mut key = [0u8; 32];
                key.copy_from_slice(&key_vec);
                key_vec.zeroize();
                if let Err(e) = create_unseal_secret(&key, debug) {
                    eprintln!(
                        "[tillandsias-vault] WARN: could not re-pair podman secret \
                         {VAULT_UNSEAL_SECRET} with the fresh-init share ({e}); the next \
                         restart will go through the one-shot unseal recovery seam"
                    );
                }
                key.zeroize();
            }
        }
        if is_running_in_vm() {
            if debug {
                eprintln!(
                    "[tillandsias-vault] running in VM; storing fresh-init handover in memory for host query"
                );
            }
            let cell = PENDING_HANDOVER.get_or_init(|| Mutex::new(None));
            if let Ok(mut guard) = cell.lock() {
                *guard = Some(PendingHandover {
                    unseal_share_b64: Some(share_b64.clone()),
                    root_token: Some(token.clone()),
                });
            }

            // Also proactively update the fallback files so child processes (like
            // GithubLogin) running right after init can use the fresh credentials
            // before the host re-delivers them.
            //
            // 694-mhz8: the SHARE write is not a convenience — it is what keeps the
            // next bootstrap from destroying this Vault. `has_shamir_share_in_keyring`
            // decides `is_partial_init` (see the wipe branch below) by looking for an
            // OS keychain entry and then this file. Inside the VM there is no OS
            // keychain, so this file is the ONLY evidence that the share was ever
            // captured. Writing only the token — as this block did until now — left
            // the predicate permanently false, so every subsequent bootstrap
            // classified a healthy initialized Vault as a crashed partial init and
            // wiped it, taking the stored GitHub token with it. Observed live on
            // macOS 2026-08-11: `--github-login` succeeded and verified its own
            // Vault write, and the secret was 404 on the next boot.
            //
            // Writing it here (rather than relaxing the predicate) preserves the
            // genuine partial-init case: if init crashes before reaching this line,
            // the file is absent, the predicate is false, and the wipe still fires —
            // which is exactly what it is for.
            // 701-se6x criterion 2: this site had the same discarded error. It
            // is the MORE dangerous of the two, because it runs immediately
            // after `operator init` — the moment the share exists and nothing
            // else on the host has a copy.
            match crate::init_cache_dir() {
                Ok(cache_dir) => {
                    if let Err(e) =
                        write_vm_credential_fallbacks(&cache_dir, Some(&token), Some(&share_b64))
                    {
                        report_fallback_write_failure("in-VM fresh init", &e.to_string());
                    }
                }
                Err(e) => {
                    report_fallback_write_failure(
                        "in-VM fresh init",
                        &format!("cache dir unavailable: {e}"),
                    );
                }
            }

            // Update in-memory credentials so the current process has the new token.
            let creds_cell = IN_VM_CREDENTIALS.get_or_init(|| Mutex::new(None));
            if let Ok(mut guard) = creds_cell.lock() {
                if let Some(creds) = guard.as_mut() {
                    creds.root_token = Some(token.clone());
                    creds.unseal_share_b64 = Some(share_b64.clone());
                } else {
                    *guard = Some(InVmCredentials {
                        unseal_share_b64: Some(share_b64.clone()),
                        installation_uuid: String::new(),
                        root_token: Some(token.clone()),
                    });
                }
            }
        } else {
            keychain_set_blocking("vault-root-token-v1", &token)?;
            keychain_set_blocking(VAULT_SHAMIR_SHARE_V1, &share_b64)?;
        }

        // @trace spec:tillandsias-vault — Secure Artifact Cleanup
        // @trace plan/issues/security-audit-zero-trust-2026-07-01.md (P1-1)
        // SHRED, don't just unlink. `rm` alone returns the tmpfs pages to the
        // kernel WITHOUT zeroing them, so the root token can linger in freed RAM
        // (readable via a forensic memory scrape or a page-reuse race) after the
        // host has consumed it. Overwrite each file in place with zeros of its
        // own length FIRST, then unlink — both in a single exec so the files are
        // never left truncated-but-present. Remove the files (not the mount dir)
        // so the unprivileged exec user can't trip on the root-owned tmpfs mount
        // point. Best-effort: a failure here must not abort a successful init.
        let _ = podman_cmd_sync()
            .args([
                "exec",
                VAULT_CONTAINER_NAME,
                "sh",
                "-c",
                "for f in /run/vault-handover/root.token /run/vault-handover/unseal.key; do \
                   [ -f \"$f\" ] && dd if=/dev/zero of=\"$f\" bs=1 count=\"$(wc -c < \"$f\")\" conv=notrunc 2>/dev/null; \
                 done; \
                 rm -f /run/vault-handover/root.token /run/vault-handover/unseal.key",
            ])
            .status_bounded(tillandsias_podman::OperationKind::Container.default_budget());

        if debug {
            eprintln!(
                "[tillandsias-vault] root token + Shamir share handover complete (shredded from tmpfs)"
            );
        }
        return Ok(token);
    }

    // 2. Subsequent boot (no fresh handover): use the keychain root token.
    if is_running_in_vm() {
        if let Some(cell) = IN_VM_CREDENTIALS.get()
            && let Ok(guard) = cell.lock()
            && let Some(creds) = &*guard
            && let Some(token) = &creds.root_token
        {
            if debug {
                eprintln!(
                    "[tillandsias-vault] recovered root token from host-delivered credentials"
                );
            }
            return Ok(token.clone());
        }
        // Host didn't deliver a root token. Try the local fallback file
        // (written by the vault-init bootstrap on first run and by any
        // explicit `--store-vault-root-token` path). This keeps the headless
        // self-sufficient when the Windows tray's Credential Manager hasn't
        // received the handover yet (e.g. after a GetVaultHandover failure).
        let cache_dir = crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
        let fallback_file = cache_dir.join("fallback_vault-root-token-v1");
        if fallback_file.is_file()
            && let Ok(t) = fs::read_to_string(&fallback_file).map(|s| s.trim().to_string())
            && !t.is_empty()
        {
            if debug {
                eprintln!("[tillandsias-vault] recovered root token from VM fallback file");
            }
            return Ok(t);
        }
        return Err("running in VM but no root token delivered from host".to_string());
    }

    let entry_token = Entry::new(KEYCHAIN_SERVICE, "vault-root-token-v1")
        .map_err(|e| format!("keyring entry for root token: {e}"))?;
    let token_res = with_keyring_timeout(move || entry_token.get_password());
    let token = match token_res {
        Ok(t) => t,
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] keyring root token get failed/timed out ({e}); checking file fallback"
                );
            }
            let cache_dir =
                crate::init_cache_dir().map_err(|err| format!("init cache dir: {err}"))?;
            let fallback_file = cache_dir.join("fallback_vault-root-token-v1");
            if fallback_file.is_file() {
                fs::read_to_string(&fallback_file)
                    .map(|s| s.trim().to_string())
                    .unwrap_or_default()
            } else {
                String::new()
            }
        }
    };
    if !token.is_empty() {
        if debug {
            eprintln!("[tillandsias-vault] recovered root token from host keychain or fallback");
        }
        return Ok(token);
    }

    Err(
        "vault is initialized but no first-boot handover is present and the host \
         keychain has no root token or fallback — the keychain and the data directory are out of \
         sync. Reset by removing the `<cache>/vault-data` directory (this loses every credential) \
         and re-run `tillandsias --init` to re-bootstrap."
            .to_string(),
    )
}

#[cfg(not(feature = "vault"))]
fn read_and_handover_root_token(_debug: bool) -> Result<String, String> {
    Err("vault feature not compiled".into())
}

pub(crate) fn container_exit_state(name: &str) -> Option<(String, i64)> {
    let out = podman_cmd_sync()
        .args([
            "inspect",
            "--format",
            "{{.State.Status}} {{.State.ExitCode}}",
            name,
        ])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut parts = raw.split_whitespace();
    let status = parts.next()?.to_string();
    let code = parts.next()?.parse::<i64>().ok()?;
    Some((status, code))
}

pub(crate) fn container_running(name: &str) -> bool {
    let out = podman_cmd_sync()
        .args(["inspect", "--format", "{{.State.Running}}", name])
        .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget());
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "true",
        _ => false,
    }
}

/// Runtime seam for the sync bootstrap entry points.
///
/// Was a raw current-thread `Runtime` — which PANICS ("Cannot start a
/// runtime from within a runtime") whenever the bootstrap is reached from
/// an async context, e.g. publish_local_service → ensure_service_catalog →
/// dependency graph → Service::Vault (ci-full tray-contract repro
/// 2026-07-16, third member of the day's nested-runtime family after the
/// tray tools/call and the order-235 backoff sleep). `RuntimeOrHandle`
/// (crate root) resolves both worlds: a Handle + block_in_place inside a
/// multi-thread runtime, an owned Runtime outside any.
fn tokio_runtime() -> Result<crate::RuntimeOrHandle, String> {
    crate::podman_runtime()
}

/// Push the four shipped policy bodies into Vault. Idempotent.
async fn load_policies(client: &VaultClient, debug: bool) -> Result<(), String> {
    for policy in Policy::all() {
        if debug {
            eprintln!("[tillandsias-vault] writing policy {}", policy.name());
        }
        client
            .write_policy(policy.name(), policy.hcl())
            .await
            .map_err(|e| format!("write_policy {}: {e}", policy.name()))?;
    }
    Ok(())
}

/// Enable AppRole and provision one role per shipped policy.
///
/// Role names are the policy name without the `-policy` suffix
/// (`git-mirror-policy` → `git-mirror`). Tokens default to 1h TTL with a
/// 24h ceiling; the underlying secret-id is single-use and expires after
/// 30s, so a stolen secret-id is worthless past container launch. The one
/// explicit exception is `git-mirror-agent`: it maps to the same narrow
/// git-mirror policy but keeps a reusable 48h SecretID so Vault Agent can log
/// in again after max_ttl. Host-side accessor destruction normally bounds that
/// credential to the Tillandsias session; the server TTL bounds SIGKILL and
/// host-crash orphans when process memory cannot run teardown.
pub async fn provision_approle_roles(client: &VaultClient, debug: bool) -> Result<(), String> {
    client
        .enable_approle()
        .await
        .map_err(|e| format!("enable_approle: {e}"))?;
    for policy in Policy::all() {
        let role = policy_role_name(policy);
        if debug {
            eprintln!(
                "[tillandsias-vault] provisioning AppRole role {role} -> {}",
                policy.name()
            );
        }
        client
            .create_approle_role(
                role,
                &[policy.name()],
                APPROLE_TOKEN_TTL_SECS,
                APPROLE_TOKEN_MAX_TTL_SECS,
            )
            .await
            .map_err(|e| format!("create_approle_role {role}: {e}"))?;
    }
    if debug {
        eprintln!(
            "[tillandsias-vault] provisioning long-running AppRole role {} -> {}",
            GIT_MIRROR_AGENT_ROLE,
            Policy::GitMirror.name()
        );
    }
    client
        .create_approle_agent_role(
            GIT_MIRROR_AGENT_ROLE,
            &[Policy::GitMirror.name()],
            APPROLE_TOKEN_TTL_SECS,
            APPROLE_TOKEN_MAX_TTL_SECS,
        )
        .await
        .map_err(|e| format!("create_approle_agent_role {GIT_MIRROR_AGENT_ROLE}: {e}"))?;
    Ok(())
}

/// Map a policy to its short AppRole role name. Stable across releases —
/// containers wire `VAULT_ROLE=<this string>` into their launch env so
/// `vault-cli` knows which login to perform when the secret-id is
/// rotated.
pub fn policy_role_name(policy: &Policy) -> &'static str {
    match policy {
        Policy::GitMirror => "git-mirror",
        Policy::Forge => "forge",
        Policy::Tray => "tray",
        Policy::Inference => "inference",
        Policy::GithubLogin => "github-login",
        Policy::ClaudeLogin => "claude-login",
        Policy::CodexLogin => "codex-login",
        Policy::CodexForge => "codex-forge",
        Policy::ClaudeForge => "claude-forge",
        Policy::AntigravityForge => "antigravity-forge",
        Policy::AntigravityLogin => "antigravity-login",
        Policy::OpenCodeForge => "opencode-forge",
    }
}

// ---------------------------------------------------------------------------
// Per-project mirror service identity (order 606-bvnp)
//
// Design: plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md — D13
// (opaque mirror-id), §2.3 (exact per-project SSH signer roles), D12/§4 T2
// (policies MINTED at provision, never a static wildcard file). Every
// per-project artifact — certificate principal, client/host signer role,
// minted policy, opaque hostname — is keyed by one opaque token minted here.
// ---------------------------------------------------------------------------

/// Vault mount of the client (user-cert) SSH CA. Two mounts, not one with two
/// roles: independent signing keys are independent blast radii (design D1).
pub const SSH_CLIENT_SIGNER_MOUNT: &str = "ssh-client-signer";
/// Vault mount of the host-cert SSH CA (design D1).
pub const SSH_HOST_SIGNER_MOUNT: &str = "ssh-host-signer";
/// KV-v2 prefix persisting each project's opaque mirror identity (D13).
/// Written ONCE at first mirror provision, read on every later launch.
/// No forge-reachable policy may read `secret/data/mirror-identity/*`.
pub const MIRROR_IDENTITY_KV_PREFIX: &str = "secret/mirror-identity";
/// Raw entropy of a mirror-id: 12 bytes from the host CSPRNG (D13).
const MIRROR_ID_BYTES: usize = 12;
/// Encoded length: 12 bytes → ceil(96/5) = 20 base32hex characters.
pub const MIRROR_ID_LEN: usize = 20;

/// RFC 4648 base32hex, lowercase, no padding.
///
/// Chosen over base32 because base32hex sorts like the bytes it encodes, and
/// over base64/hex because the output must be a valid DNS label fragment
/// (`git-<mirror-id>` is assigned as a podman `--network-alias`): lowercase
/// alphanumeric only, no `+/=` and no case-sensitivity hazards. Hand-rolled
/// (~15 lines) rather than a new crate dependency.
fn base32hex_lowercase_nopad(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"0123456789abcdefghijklmnopqrstuv";
    let mut out = String::with_capacity(bytes.len().div_ceil(5) * 8);
    let mut acc: u32 = 0;
    let mut acc_bits: u32 = 0;
    for &byte in bytes {
        acc = (acc << 8) | u32::from(byte);
        acc_bits += 8;
        while acc_bits >= 5 {
            acc_bits -= 5;
            out.push(ALPHABET[((acc >> acc_bits) & 0x1f) as usize] as char);
        }
    }
    if acc_bits > 0 {
        out.push(ALPHABET[((acc << (5 - acc_bits)) & 0x1f) as usize] as char);
    }
    out
}

/// Mint a fresh opaque mirror-id: 12 CSPRNG bytes, base32hex lowercase, no
/// padding — 20 chars (design D13).
///
/// Minted RANDOM, never derived: a hash of the project name (salted or not,
/// if the salt is shared) is enumerable by any tenant that can guess project
/// names, and project names are chosen by humans to be guessable. Randomness
/// is the only derivation with nothing to guess from.
pub fn mint_mirror_id() -> Result<String, String> {
    let mut bytes = [0u8; MIRROR_ID_BYTES];
    getrandom::fill(&mut bytes)
        .map_err(|e| format!("host CSPRNG unavailable for mirror-id mint: {e}"))?;
    Ok(base32hex_lowercase_nopad(&bytes))
}

/// Grammar check for a stored mirror-id: exactly 20 base32hex-lowercase
/// chars. A stored identity that fails this was not written by the mint path
/// and must be treated as corruption, never silently re-minted over —
/// existing roles, policies, and certificates may reference it.
pub fn mirror_id_is_valid(mirror_id: &str) -> bool {
    mirror_id.len() == MIRROR_ID_LEN
        && mirror_id
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'v'))
}

/// KV-v2 path persisting one project's mirror identity (D13).
pub fn mirror_identity_kv_path(project: &str) -> String {
    format!("{MIRROR_IDENTITY_KV_PREFIX}/{project}")
}

/// The one certificate principal a project's lane certs may carry (D3):
/// authorization lives in the principal, identity lives in the key. Opaque —
/// never the plaintext project name, which would leak cross-tenant into the
/// other project's sshd log on a rejected cert.
pub fn mirror_push_principal(mirror_id: &str) -> String {
    format!("til:forge-push:{mirror_id}")
}

/// ORDER 1313-prin. The HOST push principal, distinct from the forge's.
///
/// A certificate that names WHO is pushing is what the audit trail is for, and
/// revoking one identity must not take the other with it. A host pushing under
/// `til:forge-push:<mirror-id>` would be indistinguishable from a lane
/// container in the mirror's log, and revoking the host would revoke every
/// forge.
pub fn host_push_principal(host: &str) -> String {
    format!("til:host-push:{host}")
}

/// Minted per-host push policy: `update` on the exact
/// `ssh-client-signer/sign/host-<host>` path and nothing else (D12 shape).
pub fn host_push_policy_name(host: &str) -> String {
    format!("ssh-host-push-{host}")
}

/// The per-host client-signer ROLE name, deliberately the same string as its
/// policy, for the same one-role-one-policy visibility the lane side uses.
pub fn host_push_role_name(host: &str) -> String {
    host_push_policy_name(host)
}

/// Render the per-host push policy for ONE host.
pub fn render_host_push_policy_hcl(host: &str) -> String {
    format!(
        "# Minted at host-push provision (order 1313-prin). ONE host's push\n\
         # identity: sign-only, exact path, wildcards refused.\n\
         path \"{SSH_CLIENT_SIGNER_MOUNT}/sign/host-{host}\" {{\n  capabilities = [\"update\"]\n}}\n"
    )
}

/// Per-host client-signer role config, mirroring
/// [`build_client_signer_role_config`] with ONE difference: the principal.
///
/// WHY A SEPARATE ROLE AND NOT A WIDENED ONE. `allowed_users` is an exact list
/// with no globbing (V3/D3). Adding the host principal to the forge's role
/// would let that ONE role mint EITHER identity, which is exactly the
/// cross-identity grant the distinct-principal design exists to prevent.
///
/// `source-address` IS THE ENCLAVE SUBNET, THE SAME AS THE FORGE'S, and this
/// was measured rather than assumed. A host connects through the rootless
/// published port, and podman SNATs it onto the container network: the mirror's
/// sshd logs `Connection from 10.0.42.14`, an enclave peer, in
/// /tmp/tillandsias-sshd/sshd.err. An earlier draft of this narrowed it to
/// 127.0.0.1/32 on the strength of a line read from the WRONG log — the git
/// daemon's healthcheck output in the container log — and that cert would have
/// been refused at authentication for every host push, reading as a bad key.
/// The host and forge certs have the SAME address scope because they arrive
/// the same way.
pub fn build_host_push_signer_role_config(host: &str, enclave_subnet: &str) -> serde_json::Value {
    serde_json::json!({
        "key_type": "ca",
        "allow_user_certificates": true,
        "allowed_users": host_push_principal(host),
        "default_user": "git",
        // A stolen host key+cert still cannot open a shell, forward a port, or
        // forward an agent (D4).
        "allowed_extensions": "",
        "default_extensions": {},
        "default_critical_options": {
            "force-command": "/usr/local/bin/tillandsias-receive",
            "source-address": enclave_subnet,
        },
        "ttl": "30m",
        "max_ttl": "1h",
        "key_id_format": "{{role_name}}|{{token_display_name}}",
    })
}

/// Opaque per-project mirror hostname `git-<mirror-id>` (24 chars, a single
/// valid DNS label). The DNS swap point itself is
/// `git_mirror_service_identity` (main.rs, order 659-8faj); this derivation
/// exists so the Vault-side artifacts (host role `allowed_domains`, host-cert
/// principal) name exactly the hostname that function will emit once the
/// opaque identity is wired through it.
pub fn mirror_service_hostname(mirror_id: &str) -> String {
    format!("git-{mirror_id}")
}

/// Client-signer role name on [`SSH_CLIENT_SIGNER_MOUNT`]: the bare
/// mirror-id (§2.3 — `roles/<mirror-id>`).
pub fn mirror_client_signer_role(mirror_id: &str) -> String {
    mirror_id.to_string()
}

/// Host-signer role name on [`SSH_HOST_SIGNER_MOUNT`]: `host-<mirror-id>`
/// (§2.3 — the shared `roles/mirror-host` with alias domains is withdrawn).
pub fn mirror_host_signer_role(mirror_id: &str) -> String {
    format!("host-{mirror_id}")
}

/// Name of the minted per-project lane-signer policy (D12).
pub fn mirror_lane_signer_policy_name(mirror_id: &str) -> String {
    format!("ssh-lane-signer-{mirror_id}")
}

/// Name of the minted per-project host-signer policy (D12).
pub fn mirror_host_signer_policy_name(mirror_id: &str) -> String {
    format!("ssh-host-signer-{mirror_id}")
}

/// Render the lane-signer policy for ONE project: `update` on the exact
/// `ssh-client-signer/sign/<mirror-id>` path and nothing else (D12).
///
/// This template lives HERE, in Rust next to `provision_approle_roles`, and
/// not under `images/vault/policies/`, precisely so the static-file lanes
/// (`Containerfile` COPY list, entrypoint `load_policy`, `Policy::all()`,
/// the embedded-HCL parity test) are not in play — no wildcard policy file
/// ever ships, so there is no wildcard to forget to remove (§4 T2).
pub fn render_lane_signer_policy_hcl(mirror_id: &str) -> String {
    format!(
        "# Minted at mirror provision (order 606-bvnp). The per-lane ssh-agent\n\
         # sidecar of ONE project: sign-only, exact path, wildcards refused.\n\
         path \"{SSH_CLIENT_SIGNER_MOUNT}/sign/{mirror_id}\" {{\n  capabilities = [\"update\"]\n}}\n"
    )
}

/// Render the host-signer policy for ONE project's mirror: `update` on the
/// exact `ssh-host-signer/sign/host-<mirror-id>` path and nothing else (D12).
pub fn render_host_signer_policy_hcl(mirror_id: &str) -> String {
    format!(
        "# Minted at mirror provision (order 606-bvnp). The mirror of ONE\n\
         # project: sign-only, exact path, wildcards refused.\n\
         path \"{SSH_HOST_SIGNER_MOUNT}/sign/host-{mirror_id}\" {{\n  capabilities = [\"update\"]\n}}\n"
    )
}

/// Refuse to write any policy containing a `sign/*` wildcard to the server.
///
/// The earlier design draft shipped a static policy with
/// `path "ssh-client-signer/sign/*"` — cross-project signing authority: a
/// project-A sidecar could request a project-B certificate. That wildcard is
/// withdrawn (amendment 2026-08-10, 606-bvnp), and this guard is the
/// server-side enforcement: no policy body containing `sign/*` may ever
/// reach `sys/policies/acl`, whatever future template produces it.
fn reject_sign_wildcard(policy_name: &str, hcl: &str) -> Result<(), String> {
    if hcl.contains("sign/*") {
        return Err(format!(
            "refusing to write policy {policy_name}: body contains a sign/* wildcard, \
             which is cross-project signing authority (606-bvnp, design D12)"
        ));
    }
    Ok(())
}

/// Client-signer role config (§2.3): exact principal, no extensions, two
/// critical options, 30m/1h TTLs (D3/D4/D7).
///
/// `enclave_subnet` must be the EFFECTIVE enclave subnet
/// (`TILLANDSIAS_ENCLAVE_SUBNET` override honored), or `source-address`
/// locks every lane out. The subnet is enclave-WIDE: it contributes nothing
/// to inter-project separation (both projects' forges sit inside it) and
/// stays in the certificate purely as defense-in-depth against use from
/// outside the enclave.
pub fn build_client_signer_role_config(mirror_id: &str, enclave_subnet: &str) -> serde_json::Value {
    serde_json::json!({
        "key_type": "ca",
        "allow_user_certificates": true,
        // V3: allowed_users is an exact list with no globbing — one opaque
        // principal, never the project name (D3).
        "allowed_users": mirror_push_principal(mirror_id),
        "default_user": "git",
        // V4: an empty allowed_extensions makes Vault REFUSE a permit-pty
        // request — a stolen key+cert cannot open a shell, forward a port,
        // or forward an agent (D4).
        "allowed_extensions": "",
        "default_extensions": {},
        "default_critical_options": {
            "force-command": "/usr/local/bin/tillandsias-receive",
            "source-address": enclave_subnet,
        },
        "ttl": "30m",
        "max_ttl": "1h",
        // V5: no per-request key_id; only {{role_name}} and
        // {{token_display_name}} substitute.
        "key_id_format": "{{role_name}}|{{token_display_name}}",
    })
}

/// Host-signer role config (§2.3): exactly one allowed domain — the opaque
/// per-project hostname. The legacy shared aliases are never certified (D9).
pub fn build_host_signer_role_config(mirror_id: &str) -> serde_json::Value {
    serde_json::json!({
        "key_type": "ca",
        "allow_host_certificates": true,
        "allowed_domains": mirror_service_hostname(mirror_id),
        "allow_bare_domains": true,
        "allow_subdomains": false,
        "ttl": "24h",
        "max_ttl": "48h",
    })
}

/// Ensure the two SSH CA mounts + both roles + both minted policies for one
/// project's mirror-id. Idempotent throughout: mounts/CAs squash the
/// already-exists 400, role and policy writes are overwrites.
///
/// Mount/CA ensure duplicates the vault image entrypoint's T1 boot-time work
/// on purpose: the entrypoint provisions on FIRST boot only (subsequent
/// boots exit before the token-authenticated section), so a vault volume
/// initialized before these engines existed would never gain them —
/// D13's migration story ("first launch after upgrade: kv path absent →
/// mint, store, proceed") requires the host-side ensure.
///
/// Deliberately NOT provisioned here: the `ssh-lane-signer-<mirror-id>`
/// AppRole (D6) — that is sidecar wiring (§4 T8), provisioned per lane by
/// [`provision_lane_signer_approle`] (order 749-6uby).
pub async fn provision_mirror_ssh_roles(
    client: &VaultClient,
    mirror_id: &str,
    enclave_subnet: &str,
    debug: bool,
) -> Result<(), String> {
    if debug {
        eprintln!(
            "[tillandsias-vault] ensuring SSH signer mounts + per-project roles for mirror-id {mirror_id}"
        );
    }
    for mount in [SSH_CLIENT_SIGNER_MOUNT, SSH_HOST_SIGNER_MOUNT] {
        client
            .enable_secrets_engine(mount, "ssh")
            .await
            .map_err(|e| format!("enable ssh secrets engine {mount}: {e}"))?;
        client
            .configure_ssh_ca_generate(mount)
            .await
            .map_err(|e| format!("generate in-vault CA for {mount}: {e}"))?;
    }
    client
        .write_ssh_role(
            SSH_CLIENT_SIGNER_MOUNT,
            &mirror_client_signer_role(mirror_id),
            build_client_signer_role_config(mirror_id, enclave_subnet),
        )
        .await
        .map_err(|e| format!("write client-signer role {mirror_id}: {e}"))?;
    client
        .write_ssh_role(
            SSH_HOST_SIGNER_MOUNT,
            &mirror_host_signer_role(mirror_id),
            build_host_signer_role_config(mirror_id),
        )
        .await
        .map_err(|e| format!("write host-signer role host-{mirror_id}: {e}"))?;
    for (name, hcl) in [
        (
            mirror_lane_signer_policy_name(mirror_id),
            render_lane_signer_policy_hcl(mirror_id),
        ),
        (
            mirror_host_signer_policy_name(mirror_id),
            render_host_signer_policy_hcl(mirror_id),
        ),
    ] {
        reject_sign_wildcard(&name, &hcl)?;
        client
            .write_policy(&name, &hcl)
            .await
            .map_err(|e| format!("mint policy {name}: {e}"))?;
    }
    Ok(())
}

/// AppRole name for one lane's ssh-agent sidecar (D6). Deliberately the SAME
/// string as [`mirror_lane_signer_policy_name`]: the design names both the
/// auth binding and the policy `ssh-lane-signer-<mirror-id>`, and a shared
/// name makes the one-role-one-policy pairing visible in every Vault listing.
pub fn mirror_lane_signer_role_name(mirror_id: &str) -> String {
    mirror_lane_signer_policy_name(mirror_id)
}

/// Provision the per-lane sidecar AppRole (design T8/D6, order 749-6uby):
/// an AGENT role (Vault Agent auto-auth — reusable SecretID within its
/// bounded window, unlimited-use client tokens) bound to EXACTLY the one
/// minted lane-signer policy, which permits exactly the one
/// `ssh-client-signer/sign/<mirror-id>` path (D12). Signing through any
/// other mirror's path returns 403 — §4a M2's exactness comes from this
/// single-policy binding, so this function refuses to accept extra policies
/// by construction (it takes none).
///
/// Idempotent: role writes are overwrites, and
/// [`provision_mirror_ssh_roles`] has already minted the policy this role
/// names (policy-before-role ordering means a half-provisioned lane fails
/// CLOSED at login rather than open at sign time).
pub async fn provision_lane_signer_approle(
    client: &VaultClient,
    mirror_id: &str,
    debug: bool,
) -> Result<String, String> {
    let role = mirror_lane_signer_role_name(mirror_id);
    if debug {
        eprintln!(
            "[tillandsias-vault] provisioning lane-signer AppRole {role} -> {}",
            mirror_lane_signer_policy_name(mirror_id)
        );
    }
    client
        .enable_approle()
        .await
        .map_err(|e| format!("enable_approle: {e}"))?;
    client
        .create_approle_agent_role(
            &role,
            &[&mirror_lane_signer_policy_name(mirror_id)],
            APPROLE_TOKEN_TTL_SECS,
            APPROLE_TOKEN_MAX_TTL_SECS,
        )
        .await
        .map_err(|e| format!("create_approle_agent_role {role}: {e}"))?;
    Ok(role)
}

/// Launch-path wrapper for [`provision_lane_signer_approle`]: builds the
/// root-token client the same way the other launch-time mints do.
pub async fn provision_lane_signer_approle_for_launch(
    mirror_id: &str,
    debug: bool,
) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    provision_lane_signer_approle(&client, mirror_id, debug).await
}

/// AppRole name for one mirror's HOST-certificate signing identity (D6/D12).
/// Deliberately the SAME string as [`mirror_host_signer_policy_name`], for the
/// same reason the lane side does it: a shared name makes the one-role-one-
/// policy pairing visible in every Vault listing.
pub fn mirror_host_signer_role_name(mirror_id: &str) -> String {
    mirror_host_signer_policy_name(mirror_id)
}

/// Provision the per-mirror HOST-signer AppRole (order 1313-prin, closing the
/// gap 1288-5qpn's dogfooding found).
///
/// THE DEFECT THIS EXISTS TO FIX. `provision_mirror_ssh_roles` MINTED
/// `ssh-host-signer-<mid>` and nothing was ever bound to it: the lane side had
/// both halves (`provision_lane_signer_approle`), the host side had the mint
/// only. So the mirror authenticated with the GLOBAL `git-mirror-agent` role,
/// whose token carries `["default","git-mirror-policy"]`, and every
/// `ssh-host-signer/sign/host-<mid>` request answered 403 permission denied.
/// MEASURED on lenovinha 2026-09-20 by `auth/token/lookup-self` from inside the
/// mirror with the token it already held, and by grep: one operative reference
/// to the policy name, and it was the mint.
///
/// WHY NOT THE SMALLER FIX, recorded because it is the one a reader reaches for.
/// Adding the per-mirror policy to `GIT_MIRROR_AGENT_ROLE` would attach it in
/// three lines. That role is GLOBAL — one role for every project's mirror — so
/// with two projects up, project A's mirror token would carry project B's
/// `ssh-host-signer-<B>` policy: cross-project HOST-CERTIFICATE SIGNING. That is
/// the authority the 2026-08-10 amendment withdrew (D12), and
/// [`reject_sign_wildcard`] cannot see it, because no policy BODY contains a
/// wildcard — the same authority granted by a different route, past a guard
/// watching the wrong door. The only test that distinguishes the two fixes is
/// the exactness arm: sign answers 200 for this mirror's id and 403 for another's.
///
/// ONE TOKEN NEVER CARRIES BOTH AUTHORITIES: the mirror uses this identity for
/// SIGNING ONLY and keeps `git-mirror-agent` for everything else.
///
/// Refuses extra policies by construction (it takes none), exactly as the lane
/// side does. Idempotent: role writes are overwrites, and the policy this role
/// names is minted by `provision_mirror_ssh_roles` first — policy-before-role
/// ordering means a half-provisioned mirror fails CLOSED at login rather than
/// open at sign time.
pub async fn provision_host_signer_approle(
    client: &VaultClient,
    mirror_id: &str,
    debug: bool,
) -> Result<String, String> {
    let role = mirror_host_signer_role_name(mirror_id);
    if debug {
        eprintln!(
            "[tillandsias-vault] provisioning host-signer AppRole {role} -> {}",
            mirror_host_signer_policy_name(mirror_id)
        );
    }
    client
        .enable_approle()
        .await
        .map_err(|e| format!("enable_approle: {e}"))?;
    client
        .create_approle_agent_role(
            &role,
            &[&mirror_host_signer_policy_name(mirror_id)],
            APPROLE_TOKEN_TTL_SECS,
            APPROLE_TOKEN_MAX_TTL_SECS,
        )
        .await
        .map_err(|e| format!("create_approle_agent_role {role}: {e}"))?;
    Ok(role)
}

/// Launch-path wrapper for [`provision_host_signer_approle`], built the same
/// way [`provision_lane_signer_approle_for_launch`] is.
pub async fn provision_host_signer_approle_for_launch(
    mirror_id: &str,
    debug: bool,
) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    provision_host_signer_approle(&client, mirror_id, debug).await
}

/// ORDER 1313-prin. Provision ONE host's push identity: the ssh role, its
/// minted policy, and the AppRole bound to exactly that policy.
///
/// THREE THINGS, IN THIS ORDER, and the order is the safety property:
/// ssh role, then policy, then AppRole. Policy-before-role means a
/// half-provisioned host fails CLOSED at login rather than open at sign time —
/// the same ordering `provision_mirror_ssh_roles` and
/// `provision_lane_signer_approle` already rely on.
///
/// SEPARATE FROM THE FORGE'S ROLE, NOT A WIDENING OF IT. `allowed_users` is an
/// exact list with no globbing (V3/D3), so adding `til:host-push:<host>` to the
/// forge role would let that ONE role mint EITHER identity — the cross-identity
/// grant the distinct-principal design exists to prevent. A host and a lane
/// must be distinguishable in the mirror's log, and revoking one must not
/// revoke the other.
pub async fn provision_host_push_identity(
    client: &VaultClient,
    host: &str,
    enclave_subnet: &str,
    debug: bool,
) -> Result<String, String> {
    let role = host_push_role_name(host);
    if debug {
        eprintln!(
            "[tillandsias-vault] provisioning host-push identity {role} -> {}",
            host_push_principal(host)
        );
    }
    client
        .write_ssh_role(
            SSH_CLIENT_SIGNER_MOUNT,
            &format!("host-{host}"),
            build_host_push_signer_role_config(host, enclave_subnet),
        )
        .await
        .map_err(|e| format!("write host-push ssh role host-{host}: {e}"))?;

    let hcl = render_host_push_policy_hcl(host);
    reject_sign_wildcard(&host_push_policy_name(host), &hcl)?;
    client
        .write_policy(&host_push_policy_name(host), &hcl)
        .await
        .map_err(|e| format!("mint policy {}: {e}", host_push_policy_name(host)))?;

    client
        .enable_approle()
        .await
        .map_err(|e| format!("enable_approle: {e}"))?;
    client
        .create_approle_agent_role(
            &role,
            &[&host_push_policy_name(host)],
            APPROLE_TOKEN_TTL_SECS,
            APPROLE_TOKEN_MAX_TTL_SECS,
        )
        .await
        .map_err(|e| format!("create_approle_agent_role {role}: {e}"))?;
    Ok(role)
}

/// Launch-path wrapper for [`provision_host_push_identity`], built the same way
/// the other launch-time mints are.
pub async fn provision_host_push_identity_for_launch(
    host: &str,
    enclave_subnet: &str,
    debug: bool,
) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    provision_host_push_identity(&client, host, enclave_subnet, debug).await
}

/// Read the host-signer CA public key (T10: the forge's `@cert-authority`
/// known_hosts line must carry this, delivered read-only — `~/.ssh` in the
/// forge is an empty tmpfs by design, D9).
pub async fn read_mirror_host_ca_public_key(debug: bool) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    client
        .read_ssh_ca_public_key(SSH_HOST_SIGNER_MOUNT)
        .await
        .map_err(|e| format!("read {SSH_HOST_SIGNER_MOUNT} CA public key: {e}"))
}

/// Mint-or-read a project's opaque mirror identity (D13) and ensure its
/// Vault-side SSH substrate (roles + minted policies, §2.3/T2).
///
/// The kv entry at `secret/mirror-identity/<project>` is the COMMIT MARKER:
/// it is written last, only after roles and policies landed, so its presence
/// implies a completed provision and the read path can return without any
/// further Vault writes. Two concurrent first-provisions are resolved by the
/// kv-v2 `cas=0` create-only write: the loser re-reads and adopts the
/// winner's identity (its own freshly written roles/policies are unreferenced
/// orphans keyed by an id nothing will ever use — harmless, and cleaned up
/// by the same `--reset-guest` that wipes Vault).
pub async fn provision_mirror_identity(
    client: &VaultClient,
    project: &str,
    enclave_subnet: &str,
    debug: bool,
) -> Result<String, String> {
    let kv_path = mirror_identity_kv_path(project);
    let read_stored_id = |data: serde_json::Value| -> Result<String, String> {
        let id = data
            .get("mirror_id")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| {
                format!("stored mirror identity at {kv_path} has no mirror_id field: corrupt entry")
            })?
            .to_string();
        if !mirror_id_is_valid(&id) {
            // Fail loud: certificates/roles may already reference this id;
            // silently re-minting would orphan them (D13 — identity is
            // written once and stable across mirror-volume recreation).
            return Err(format!(
                "stored mirror identity at {kv_path} fails the id grammar \
                 (want {MIRROR_ID_LEN} base32hex chars): corrupt entry, refusing to re-mint over it"
            ));
        }
        Ok(id)
    };
    match client.read_secret(&kv_path).await {
        Ok(data) => {
            let id = read_stored_id(data)?;
            if debug {
                eprintln!(
                    "[tillandsias-vault] mirror identity for {project} already provisioned ({id})"
                );
            }
            return Ok(id);
        }
        Err(VaultError::NotFound(_)) => {}
        Err(e) => return Err(format!("read mirror identity {kv_path}: {e}")),
    }

    let minted = mint_mirror_id()?;
    if debug {
        eprintln!("[tillandsias-vault] minting mirror identity for {project}: {minted}");
    }
    provision_mirror_ssh_roles(client, &minted, enclave_subnet, debug).await?;
    let created = client
        .write_secret_if_absent(
            &kv_path,
            serde_json::json!({
                "mirror_id": minted,
                // The project ⇄ mirror-id join (D3/D13): the kv entry is keyed
                // by project; recording it in the body too keeps the mapping
                // self-describing when the entry is read by path listing.
                "project": project,
                "minted_at": chrono::Utc::now().to_rfc3339(),
            }),
        )
        .await
        .map_err(|e| format!("persist mirror identity {kv_path}: {e}"))?;
    if created {
        return Ok(minted);
    }
    // A concurrent first-provision won the cas=0 race. Adopt its identity —
    // kv presence implies its roles/policies are already in place.
    let winner = client
        .read_secret(&kv_path)
        .await
        .map_err(|e| format!("re-read mirror identity {kv_path} after cas conflict: {e}"))?;
    let id = read_stored_id(winner)?;
    if debug {
        eprintln!(
            "[tillandsias-vault] concurrent provision won the identity race for {project}; \
             adopting {id} (locally minted {minted} is an unreferenced orphan)"
        );
    }
    Ok(id)
}

/// Launcher entry point: resolve (mint-or-read) a project's mirror identity
/// against the running Vault using the root bootstrap token.
///
/// Called from the mirror CREATE path only — the running-mirror reuse path
/// never touches Vault for this, and when the kv entry exists this is a
/// single kv read (cheap by construction, order 606-bvnp scope rule).
pub async fn ensure_mirror_identity_provisioned(
    project: &str,
    enclave_subnet: &str,
    debug: bool,
) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let base_url = vault_api_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    provision_mirror_identity(&client, project, enclave_subnet, debug).await
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- 1383-5hpk: GitHub App token rotation ------------------------------

    /// A fake Vault: records every write in order, can fail a chosen path.
    struct FakeStore {
        records: std::cell::RefCell<std::collections::BTreeMap<String, serde_json::Value>>,
        writes: std::cell::RefCell<Vec<String>>,
        fail_path: Option<&'static str>,
    }

    impl FakeStore {
        fn with_bundle(b: &GitHubTokenBundle, fail_path: Option<&'static str>) -> Self {
            let mut m = std::collections::BTreeMap::new();
            m.insert(GITHUB_TOKEN_PATH.to_string(), github_token_record(b));
            if let Some(r) = github_refresh_record(b) {
                m.insert(GITHUB_REFRESH_PATH.to_string(), r);
            }
            Self {
                records: std::cell::RefCell::new(m),
                writes: std::cell::RefCell::new(Vec::new()),
                fail_path,
            }
        }
        fn snapshot(&self) -> std::collections::BTreeMap<String, serde_json::Value> {
            self.records.borrow().clone()
        }
    }

    impl GitHubTokenStore for FakeStore {
        fn read_bundle(&self) -> Result<Option<GitHubTokenBundle>, String> {
            let m = self.records.borrow();
            let Some(t) = m.get(GITHUB_TOKEN_PATH) else {
                return Ok(None);
            };
            let r = m.get(GITHUB_REFRESH_PATH);
            Ok(Some(GitHubTokenBundle {
                token: t["token"].as_str().unwrap_or_default().to_string(),
                refresh_token: r
                    .and_then(|r| r["refresh_token"].as_str())
                    .map(String::from),
                expires_at: t["expires_at"].as_u64(),
                refresh_token_expires_at: r.and_then(|r| r["refresh_token_expires_at"].as_u64()),
                client_id: t["client_id"].as_str().map(String::from),
            }))
        }
        fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
            self.writes.borrow_mut().push(path.to_string());
            if self.fail_path == Some(path) {
                return Err("simulated vault write failure".into());
            }
            self.records.borrow_mut().insert(path.to_string(), value);
            Ok(())
        }
    }

    fn old_bundle() -> GitHubTokenBundle {
        GitHubTokenBundle {
            token: "ghu_OLDACCESS".into(),
            refresh_token: Some("ghr_OLDREFRESH".into()),
            expires_at: Some(100),
            refresh_token_expires_at: Some(1_000_000),
            client_id: Some("Iv23liddVkg9ME6OB1K1".into()),
        }
    }

    fn good_refresh(_: &str, old: &str) -> Result<GitHubRefreshResponse, String> {
        assert_eq!(
            old, "ghr_OLDREFRESH",
            "the rotation must spend the stored refresh token"
        );
        Ok(GitHubRefreshResponse {
            access_token: "ghu_NEWACCESS".into(),
            refresh_token: "ghr_NEWREFRESH".into(),
            expires_in: 28800,
            refresh_token_expires_in: 15_811_200,
        })
    }

    /// Criterion 4: the new pair is in Vault BEFORE rotation hands it out, the
    /// refresh record (single-use) first, then the token record.
    #[test]
    fn rotation_stores_the_refresh_record_first_then_the_token() {
        let store = FakeStore::with_bundle(&old_bundle(), None);
        let (outcome, rotated) = rotate_github_token(&store, &good_refresh, 1000).unwrap();
        assert_eq!(outcome, RotationOutcome::Rotated);
        assert_eq!(
            *store.writes.borrow(),
            vec![
                GITHUB_REFRESH_PATH.to_string(),
                GITHUB_TOKEN_PATH.to_string()
            ]
        );
        let stored = store.read_bundle().unwrap().unwrap();
        assert_eq!(
            Some(stored),
            rotated,
            "what rotation returns is exactly what Vault holds"
        );
        assert_eq!(
            store.snapshot()[GITHUB_TOKEN_PATH]["expires_at"],
            1000 + 28800
        );
    }

    /// Criterion 4: a failed write of the refresh record leaves the OLD bundle
    /// intact and never attempts the token write.
    #[test]
    fn a_failed_refresh_write_keeps_the_old_bundle_intact() {
        let store = FakeStore::with_bundle(&old_bundle(), Some(GITHUB_REFRESH_PATH));
        let before = store.snapshot();
        let err = rotate_github_token(&store, &good_refresh, 1000).unwrap_err();
        assert!(err.contains("refresh token"), "{err}");
        assert_eq!(
            store.snapshot(),
            before,
            "no record may change on a failed rotation"
        );
        assert_eq!(
            *store.writes.borrow(),
            vec![GITHUB_REFRESH_PATH.to_string()]
        );
        assert!(
            !err.contains("ghr_") && !err.contains("ghu_"),
            "no token in the error: {err}"
        );
    }

    /// Criterion 4: the rotation runs under an exclusive lock. While another
    /// holder has it, a rotation refuses and never calls GitHub.
    #[cfg(unix)]
    #[test]
    fn rotation_refuses_while_another_holds_the_rotation_lock() {
        let _held = crate::resource_lock::acquire(
            GITHUB_ROTATION_LOCK,
            std::time::Duration::from_secs(5),
            false,
        )
        .expect("test must be able to take the lock");
        let store = FakeStore::with_bundle(&old_bundle(), None);
        let called = std::cell::Cell::new(false);
        let refresh = |c: &str, r: &str| {
            called.set(true);
            good_refresh(c, r)
        };
        let err = rotate_github_token_locked(
            std::time::Duration::from_millis(300),
            &store,
            &refresh,
            1000,
            false,
        )
        .unwrap_err();
        assert!(err.contains("lock"), "{err}");
        assert!(!called.get(), "GitHub must not be called without the lock");
        assert!(store.writes.borrow().is_empty());
    }

    /// A missing refresh token is its own outcome (the CLI maps it to a
    /// non-zero exit), and GitHub is never called.
    #[test]
    fn no_refresh_token_is_reported_and_github_is_not_called() {
        let mut b = old_bundle();
        b.refresh_token = None;
        let store = FakeStore::with_bundle(&b, None);
        let refresh = |_: &str, _: &str| -> Result<GitHubRefreshResponse, String> {
            panic!("must not refresh without a refresh token")
        };
        let (outcome, _) = rotate_github_token(&store, &refresh, 1000).unwrap();
        assert_eq!(outcome, RotationOutcome::NoRefreshToken);
        assert!(store.writes.borrow().is_empty());
    }

    /// Criterion 2: a response with a fresh access token but no refresh token
    /// produces an error with NO substring of the body. The old code formatted
    /// the whole body, fresh token included, into the printed error.
    #[test]
    fn a_refresh_response_error_never_contains_the_body() {
        let body = serde_json::json!({
            "access_token": "ghu_FAKEFRESHTOKEN0123456789",
            "expires_in": 28800,
            "token_type": "bearer"
        });
        let err = parse_github_refresh_response(&body).unwrap_err();
        assert!(!err.contains("ghu_"), "error leaks the token: {err}");
        assert!(
            !err.contains("bearer") && !err.contains("28800"),
            "error quotes the body: {err}"
        );
        assert!(
            err.contains("refresh_token"),
            "error names the missing field: {err}"
        );

        let refused = serde_json::json!({
            "error": "bad_refresh_token",
            "error_description": "The refresh token passed is incorrect or expired. ghu_SNEAKY"
        });
        let err = parse_github_refresh_response(&refused).unwrap_err();
        assert!(err.contains("bad_refresh_token"));
        assert!(!err.contains("ghu_") && !err.contains("incorrect"), "{err}");

        let hostile = serde_json::json!({ "error": "ghu_TOKEN_IN_THE_CODE_FIELD" });
        let err = parse_github_refresh_response(&hostile).unwrap_err();
        assert!(
            !err.contains("ghu_"),
            "an error code that is not an identifier is not echoed: {err}"
        );
    }

    // ── 1461-8tyy: the resident due-check (github_token_auto_rotation_*) ──

    /// A Send + Sync store for the concurrency arm (FakeStore is RefCell).
    struct SharedStore {
        records: std::sync::Mutex<std::collections::BTreeMap<String, serde_json::Value>>,
        writes: std::sync::Mutex<Vec<String>>,
    }

    impl SharedStore {
        fn with(b: &GitHubTokenBundle) -> Self {
            let mut m = std::collections::BTreeMap::new();
            m.insert(GITHUB_TOKEN_PATH.to_string(), github_token_record(b));
            if let Some(r) = github_refresh_record(b) {
                m.insert(GITHUB_REFRESH_PATH.to_string(), r);
            }
            Self {
                records: std::sync::Mutex::new(m),
                writes: std::sync::Mutex::new(Vec::new()),
            }
        }
        fn snapshot(&self) -> std::collections::BTreeMap<String, serde_json::Value> {
            self.records.lock().unwrap().clone()
        }
    }

    impl GitHubTokenStore for SharedStore {
        fn read_bundle(&self) -> Result<Option<GitHubTokenBundle>, String> {
            let m = self.records.lock().unwrap();
            let Some(t) = m.get(GITHUB_TOKEN_PATH) else {
                return Ok(None);
            };
            let r = m.get(GITHUB_REFRESH_PATH);
            Ok(Some(GitHubTokenBundle {
                token: t["token"].as_str().unwrap_or_default().to_string(),
                refresh_token: r
                    .and_then(|r| r["refresh_token"].as_str())
                    .map(String::from),
                expires_at: t["expires_at"].as_u64(),
                refresh_token_expires_at: r.and_then(|r| r["refresh_token_expires_at"].as_u64()),
                client_id: t["client_id"].as_str().map(String::from),
            }))
        }
        fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
            self.writes.lock().unwrap().push(path.to_string());
            self.records.lock().unwrap().insert(path.to_string(), value);
            Ok(())
        }
    }

    const NOW: u64 = 1_000_000;

    fn bundle_expiring_at(expires_at: u64) -> GitHubTokenBundle {
        GitHubTokenBundle {
            expires_at: Some(expires_at),
            ..old_bundle()
        }
    }

    /// A lock name no live process uses, unique per test.
    fn test_lock(tag: &str) -> String {
        format!("gh-rotation-test-{tag}-{}", std::process::id())
    }

    fn fresh_pair(_: &str, _: &str) -> Result<GitHubRefreshResponse, String> {
        Ok(GitHubRefreshResponse {
            access_token: "ghu_NEWACCESS".into(),
            refresh_token: "ghr_NEWREFRESH".into(),
            expires_in: 28_800,
            refresh_token_expires_in: 15_811_200,
        })
    }

    /// Arm 1: 20 minutes left -> ONE exchange, a later expiry, and the refresh
    /// record written before the token record.
    #[test]
    fn github_token_auto_rotation_due_token_rotates_once_refresh_first() {
        let store = SharedStore::with(&bundle_expiring_at(NOW + 20 * 60));
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let out = rotate_github_token_if_due(
            &store,
            &|c, r| {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                fresh_pair(c, r)
            },
            NOW,
            false,
            &test_lock("arm1"),
            std::time::Duration::from_secs(5),
            false,
        )
        .expect("a due token rotates");
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert_eq!(
            out,
            DueCheck::Rotated {
                expires_at: NOW + 28_800,
                refresh_expires_at: Some(NOW + 15_811_200),
            }
        );
        assert_eq!(
            *store.writes.lock().unwrap(),
            vec![
                GITHUB_REFRESH_PATH.to_string(),
                GITHUB_TOKEN_PATH.to_string()
            ],
            "the scarce refresh token is persisted first"
        );
        assert_eq!(
            store.snapshot()[GITHUB_TOKEN_PATH]["token"],
            "ghu_NEWACCESS"
        );
    }

    /// Arm 2: two concurrent due-checks spend the single-use refresh token
    /// ONCE — the decision is made under the lock, so the loser sees the
    /// winner's new expiry.
    #[test]
    fn github_token_auto_rotation_concurrent_checks_exchange_once() {
        let store = std::sync::Arc::new(SharedStore::with(&bundle_expiring_at(NOW + 60)));
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let lock = test_lock("arm2");
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let store = std::sync::Arc::clone(&store);
                let calls = std::sync::Arc::clone(&calls);
                let lock = lock.clone();
                std::thread::spawn(move || {
                    rotate_github_token_if_due(
                        &*store,
                        &|c, r| {
                            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                            // Widen the window a racing reader would slip into.
                            std::thread::sleep(std::time::Duration::from_millis(200));
                            fresh_pair(c, r)
                        },
                        NOW,
                        false,
                        &lock,
                        std::time::Duration::from_secs(10),
                        false,
                    )
                })
            })
            .collect();
        let outs: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "exactly one exchange: {outs:?}"
        );
        let rotated = outs
            .iter()
            .filter(|o| matches!(o, Ok(DueCheck::Rotated { .. })))
            .count();
        let not_due = outs
            .iter()
            .filter(|o| matches!(o, Ok(DueCheck::NotDue { .. })))
            .count();
        assert_eq!((rotated, not_due), (1, 1), "{outs:?}");
    }

    /// Arm 3, NEGATIVE CONTROL: two hours left -> no exchange at all.
    #[test]
    fn github_token_auto_rotation_not_due_makes_no_exchange() {
        let store = SharedStore::with(&bundle_expiring_at(NOW + 2 * 3600));
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let out = rotate_github_token_if_due(
            &store,
            &|c, r| {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                fresh_pair(c, r)
            },
            NOW,
            false,
            &test_lock("arm3"),
            std::time::Duration::from_secs(5),
            false,
        )
        .unwrap();
        assert_eq!(
            out,
            DueCheck::NotDue {
                expires_at: NOW + 2 * 3600,
                refresh_expires_at: Some(1_000_000),
            }
        );
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert!(store.writes.lock().unwrap().is_empty());
        // The window boundary itself: exactly 30 min left is due, 30 min + 1 s is not.
        assert!(github_token_rotation_due(NOW + 30 * 60, NOW));
        assert!(!github_token_rotation_due(NOW + 30 * 60 + 1, NOW));
    }

    /// Arm 4: GitHub rejects the refresh token -> the old records are intact
    /// and the error names github-token-rotation-failed.
    #[test]
    fn github_token_auto_rotation_rejected_refresh_keeps_the_old_pair() {
        let store = SharedStore::with(&bundle_expiring_at(NOW + 60));
        let before = store.snapshot();
        let err = rotate_github_token_if_due(
            &store,
            &|_, _| Err("GitHub refused the token refresh (bad_refresh_token)".into()),
            NOW,
            false,
            &test_lock("arm4"),
            std::time::Duration::from_secs(5),
            false,
        )
        .unwrap_err();
        assert!(err.starts_with("github-token-rotation-failed:"), "{err}");
        assert!(err.contains("bad_refresh_token"), "{err}");
        assert_eq!(store.snapshot(), before, "a failed exchange writes nothing");
        assert!(!err.contains("ghr_") && !err.contains("ghu_"), "{err}");
    }

    /// Arm 5: the due-check needs no desktop session (it takes no session
    /// input and consults none — the gate stays on the explicit command), and
    /// it refuses inside a forge without touching the store.
    #[test]
    fn github_token_auto_rotation_needs_no_session_and_refuses_in_a_forge() {
        let store = SharedStore::with(&bundle_expiring_at(NOW + 60));
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let refuse = rotate_github_token_if_due(
            &store,
            &|c, r| {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                fresh_pair(c, r)
            },
            NOW,
            true,
            &test_lock("arm5f"),
            std::time::Duration::from_secs(5),
            false,
        )
        .unwrap();
        assert_eq!(refuse, DueCheck::RefusedInForge);
        assert_eq!(refuse.verdict(), "skip:github-token-rotation:forge");
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        // Same store, bare metal, no session anywhere in the call: it rotates.
        let ok = rotate_github_token_if_due(
            &store,
            &|c, r| {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                fresh_pair(c, r)
            },
            NOW,
            false,
            &test_lock("arm5b"),
            std::time::Duration::from_secs(5),
            false,
        )
        .unwrap();
        assert!(matches!(ok, DueCheck::Rotated { .. }));
        // The scheduler's own path never consults the session gate.
        let src = include_str!("vault_bootstrap.rs");
        let start = src
            .find(&["pub fn github_token_due_check_", "live("].concat())
            .unwrap();
        let body = &src[start..start + src[start..].find("\n}\n").unwrap()];
        assert!(!body.contains(&["github_refresh_", "gate"].concat()));
        assert!(!body.contains(&["has_graphical_", "session"].concat()));
    }

    /// One scheduler per process: the tray and every lane launch call the
    /// spawn, and only the first may start a thread.
    #[test]
    fn github_token_auto_rotation_scheduler_starts_once_per_process() {
        let first = claim_github_rotation_scheduler_slot();
        let second = claim_github_rotation_scheduler_slot();
        assert!(
            first,
            "the first claim in this process starts the scheduler"
        );
        assert!(!second, "a later claim must not start a second thread");
        // And every lane launch reaches it: the call sits in the enclave
        // funnel both the tray and the CLI lanes go through.
        let main_src = include_str!("main.rs");
        let start = main_src
            .find(&["pub(crate) fn ensure_enclave_", "for_project("].concat())
            .unwrap();
        let body = &main_src[start..start + main_src[start..].find("\n}\n").unwrap()];
        assert!(body.contains(&["spawn_github_token_", "rotation_scheduler("].concat()));
    }

    /// The 14-day refresh-expiry warning: fires inside the window (not
    /// outside), says "expired" at zero, names the remedy, and fires at most
    /// once per day however often the scheduler asks.
    #[test]
    fn github_token_auto_rotation_refresh_expiry_warns_once_a_day() {
        let day = 86_400;
        assert_eq!(
            github_refresh_expiry_warning(Some(NOW + 15 * day), NOW),
            None
        );
        assert_eq!(
            github_refresh_expiry_warning(Some(NOW + 14 * day), NOW),
            Some(14)
        );
        assert_eq!(
            github_refresh_expiry_warning(Some(NOW + 3 * day + 5), NOW),
            Some(3)
        );
        assert_eq!(github_refresh_expiry_warning(Some(NOW - 1), NOW), Some(0));
        assert_eq!(github_refresh_expiry_warning(None, NOW), None);
        assert!(github_refresh_expiry_message(3).contains("tillandsias --github-login"));
        assert!(github_refresh_expiry_message(0).contains("EXPIRED"));
        let mut last = None;
        assert!(should_warn_today(&mut last, NOW));
        assert!(
            !should_warn_today(&mut last, NOW + 15 * 60),
            "same day: silent"
        );
        assert!(
            should_warn_today(&mut last, NOW + day),
            "next day: warns again"
        );
    }

    /// The scheduler backs off after a failure (1 min doubling, capped) and
    /// returns to the regular interval after a verdict.
    #[test]
    fn github_token_auto_rotation_backoff_is_bounded() {
        use std::time::Duration;
        let fail: Result<DueCheck, String> = Err("x".into());
        let d1 = github_rotation_next_delay(&fail, Duration::ZERO);
        let d2 = github_rotation_next_delay(&fail, d1);
        assert_eq!(
            (d1, d2),
            (Duration::from_secs(60), Duration::from_secs(120))
        );
        assert_eq!(
            github_rotation_next_delay(&fail, Duration::from_secs(3600)),
            GITHUB_ROTATION_CHECK_EVERY
        );
        assert_eq!(
            github_rotation_next_delay(&Ok(DueCheck::NoToken), d2),
            GITHUB_ROTATION_CHECK_EVERY
        );
    }

    /// Criterion 7, the other half: the token record the git-mirror service can
    /// read never carries the refresh token.
    #[test]
    fn the_token_record_never_carries_the_refresh_token() {
        let rec = github_token_record(&old_bundle());
        assert!(rec.get("refresh_token").is_none());
        assert!(!rec.to_string().contains("ghr_"));
        assert!(
            github_refresh_record(&old_bundle())
                .unwrap()
                .to_string()
                .contains("ghr_")
        );
    }

    /// 1371-a7w2: an already-absent keychain entry is CLEARED, not failed.
    /// The old text match missed keyring's "No matching entry found in secure
    /// storage", so --reset-state refused on every clean host.
    #[cfg(target_os = "linux")]
    #[test]
    fn keyring_delete_no_entry_is_already_absent_and_platform_failure_fails() {
        // Premise: the pre-fix text match cannot see NoEntry's display.
        let shown = keyring::Error::NoEntry.to_string().to_lowercase();
        assert!(
            !shown.contains("no entry") && !shown.contains("not found"),
            "{shown}"
        );
        assert!(matches!(classify_keyring_delete(Ok(())), Ok(true)));
        assert!(matches!(
            classify_keyring_delete(Err(keyring::Error::NoEntry)),
            Ok(false)
        ));
        let platform = keyring::Error::PlatformFailure("dbus gone".into());
        assert!(classify_keyring_delete(Err(platform)).is_err());
    }

    // ---- order 803-49re: the self-heal's Shamir share sources ----

    /// The guest's own podman secret must LEAD the candidate list, and a stale
    /// host copy must never displace it.
    ///
    /// THE INCIDENT THIS PINS (operator, 2026-08-17). GitHub login failed for an
    /// hour. The self-heal retried three host-derived shares — delivered
    /// credentials, host keychain, fallback file — and every one was stale
    /// against the live storage ("cipher: message authentication failed"). The
    /// share that would have worked was in this guest's own
    /// `tillandsias-vault-unseal` podman secret: the key the vault entrypoint
    /// had already unsealed that same storage with, in that same boot. The heal
    /// never consulted it and told the operator to consider an attended re-init
    /// of a vault that was healthy and unsealed throughout.
    ///
    /// Ordering is the property, not mere membership: every candidate is tried
    /// until one authenticates, so a trailing podman secret would still have
    /// healed — after three failures and their log noise. Leading, it is tried
    /// first, because it is the only source with direct evidence for the
    /// CURRENT storage epoch rather than a copy of a key that unsealed
    /// something once.
    #[test]
    #[cfg(feature = "vault")]
    fn the_guest_podman_secret_leads_the_shamir_candidates() {
        use base64::Engine;
        let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);

        let live = [7u8; 32]; // what the running vault actually unsealed with
        let stale = [9u8; 32]; // the host's copy, from a previous storage epoch

        // Drives the REAL assembly function, so the order asserted below is the
        // order production uses. A hand-built list would pin only intent.
        let list =
            assemble_share_candidates(Some(b64(&live)), Some(b64(&stale)), None, Some(b64(&stale)));

        assert_eq!(
            list.first().map(|(label, _)| *label),
            Some("guest podman secret"),
            "the only source with evidence for the current storage epoch must be tried first"
        );
        // The stale share is still PRESENT — dropping it would be a different
        // and worse bug, since a host copy is right whenever the guest secret
        // is absent. It simply no longer goes first.
        assert_eq!(list.len(), 2, "identical stale copies dedupe: {list:?}");
        assert_eq!(list[1].1, b64(&stale));

        // A podman secret identical to the host copy must not produce two
        // entries — the heal would otherwise burn a generate-root attempt
        // proving the same key twice.
        let same = assemble_share_candidates(Some(b64(&live)), None, Some(b64(&live)), None);
        assert_eq!(same.len(), 1, "one key must yield one candidate: {same:?}");

        // A podman that is absent, errors, or short-reads contributes NOTHING
        // and cannot displace a working host share. This is why the read is
        // allowed to fail silently at the call site.
        let degraded = assemble_share_candidates(
            Some(b64(&[1u8; 16])), // short read: not 32 key bytes
            None,
            Some(b64(&stale)),
            None,
        );
        assert!(
            assemble_share_candidates(Some(String::new()), None, None, None).is_empty(),
            "an empty podman read must contribute no candidate"
        );
        assert_eq!(
            degraded.len(),
            1,
            "a missing or short podman secret must not shadow a usable host share: {degraded:?}"
        );
        assert_eq!(degraded[0].0, "host keychain");
    }

    // ---- order 828-k3mq: the credential drain's keep/destroy decision ----

    /// A RUNNING container's material must survive the drain.
    ///
    /// This is the whole defect. `cleanup_shared_stack_if_no_running_forge` is
    /// refcounted and deliberately leaves a mirror up when a sibling lane is
    /// live; destroying its SecretID anyway left that mirror renewing a token
    /// it could never replace, and 24h later every forge push was rejected.
    #[test]
    fn running_owner_is_never_destroyed() {
        assert_eq!(
            classify_owning_container_output(true, "true\n", ""),
            OwningContainerState::Running
        );
    }

    /// The control, without which "keep everything" would pass the test above.
    /// Material whose container has exited MUST still be destroyed, or the fix
    /// degrades into a blanket credential leak.
    #[test]
    fn exited_owner_is_still_destroyed() {
        assert_eq!(
            classify_owning_container_output(true, "false\n", ""),
            OwningContainerState::Gone
        );
        assert_eq!(
            classify_owning_container_output(
                false,
                "",
                "Error: no such container tillandsias-git-demo"
            ),
            OwningContainerState::Gone
        );
    }

    // ---- order 828-k3mq: the DRAIN's keep/destroy behaviour ----------------
    //
    // The three tests above pin the CLASSIFIER. These pin the drain, which is
    // what the packet's closure actually asks for: "mint AppRole auto-auth
    // material for a container, leave that container RUNNING, run the CLI-lane
    // credential drain, and assert the SecretID accessor still authenticates".
    // The accessor cannot be authenticated without a Vault, so the assertion
    // is made one step earlier and equivalently: the drain must not select
    // that material for destruction at all.

    fn reg(container: Option<&str>) -> AppRoleAutoAuthRegistration {
        AppRoleAutoAuthRegistration {
            role: GIT_MIRROR_AGENT_ROLE.to_string(),
            secret_id_accessor: "accessor-1".to_string(),
            owning_container: container.map(str::to_string),
        }
    }

    /// THE CLOSURE. A mirror order 443 kept running must keep its credential.
    #[test]
    fn drain_keeps_material_whose_container_is_still_running() {
        let entries = vec![("secret-a".to_string(), reg(Some("tillandsias-git-demo")))];
        let (destroy, kept) =
            partition_auto_auth_entries(entries, |_| OwningContainerState::Running);
        assert!(
            destroy.is_empty(),
            "a running mirror's SecretID must never be selected for destruction"
        );
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].1, "tillandsias-git-demo");
    }

    /// THE CONTROL. Without it, a drain that destroys nothing would satisfy
    /// every other test here while leaking a credential per lane exit.
    #[test]
    fn drain_destroys_material_whose_container_has_exited() {
        let entries = vec![("secret-a".to_string(), reg(Some("tillandsias-git-demo")))];
        let (destroy, kept) = partition_auto_auth_entries(entries, |_| OwningContainerState::Gone);
        assert_eq!(destroy.len(), 1, "an exited owner's material must still go");
        assert_eq!(destroy[0].0, "secret-a");
        assert!(kept.is_empty());
    }

    /// Leak-not-destroy: an unreadable owner state is treated as alive.
    #[test]
    fn drain_keeps_material_when_owner_state_is_unreadable() {
        let entries = vec![("secret-a".to_string(), reg(Some("tillandsias-git-demo")))];
        let (destroy, kept) =
            partition_auto_auth_entries(entries, |_| OwningContainerState::Unknown);
        assert!(destroy.is_empty());
        assert_eq!(kept[0].2, OwningContainerState::Unknown);
    }

    /// PRE-828 PARITY. Material with no named owner is still destroyed —
    /// starting to keep it would be a credential leak wearing this fix's
    /// clothes, and the probe must not even be consulted for it.
    #[test]
    fn drain_destroys_material_with_no_owning_container() {
        let entries = vec![("secret-a".to_string(), reg(None))];
        let mut probed = false;
        let (destroy, kept) = partition_auto_auth_entries(entries, |_| {
            probed = true;
            OwningContainerState::Running
        });
        assert_eq!(destroy.len(), 1);
        assert!(kept.is_empty());
        assert!(
            !probed,
            "an unowned registration must not consult the probe"
        );
    }

    /// A mixed drain resolves each entry independently — the realistic shape,
    /// since one lane exit drains every registration the process accumulated.
    #[test]
    fn drain_resolves_a_mixed_batch_per_entry() {
        let entries = vec![
            ("live".to_string(), reg(Some("container-live"))),
            ("dead".to_string(), reg(Some("container-dead"))),
            ("unowned".to_string(), reg(None)),
        ];
        let (destroy, kept) = partition_auto_auth_entries(entries, |c| match c {
            "container-live" => OwningContainerState::Running,
            _ => OwningContainerState::Gone,
        });
        let destroyed: Vec<&str> = destroy.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(destroyed, vec!["dead", "unowned"]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].0, "live");
    }

    /// An inspect that could not ANSWER is not evidence the container is gone.
    ///
    /// `container_running` collapses this case to `false`; reusing it here
    /// would mean a transient podman failure destroys a live mirror's
    /// credential — the same outage through a different door. Leak-not-destroy
    /// instead, bounded by the role's 48h server-side SecretID TTL.
    #[test]
    fn unreadable_owner_state_keeps_the_material() {
        assert_eq!(
            classify_owning_container_output(false, "", "connection refused"),
            OwningContainerState::Unknown
        );
        assert_eq!(
            classify_owning_container_output(false, "", ""),
            OwningContainerState::Unknown
        );
    }

    /// 701-se6x. The HOST-DELIVERED share must be persisted too, not just the
    /// host-delivered root token.
    ///
    /// A well-formed 32-byte share (bytes 1..=32), for tests that must deliver one.
    const VALID_TEST_SHARE_B64: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";

    // ---- order 1200-ih38: validate a delivered share before persisting it ----

    #[test]
    fn delivered_share_check_decides_every_branch() {
        let own: Vec<u8> = (1..=32).collect();
        let other: Vec<u8> = (2..=33).collect();
        assert_eq!(
            check_delivered_share(None, Some(&own)),
            DeliveredShareCheck::NoShare
        );
        assert_eq!(
            check_delivered_share(Some("  "), Some(&own)),
            DeliveredShareCheck::NoShare
        );
        assert!(matches!(
            check_delivered_share(Some("not base64!!"), None),
            DeliveredShareCheck::Malformed(_)
        ));
        assert!(matches!(
            check_delivered_share(Some("ZGVsaXZlcmVk"), None),
            DeliveredShareCheck::Malformed(ref w) if w.contains("9 bytes")
        ));
        assert_eq!(
            check_delivered_share(Some(VALID_TEST_SHARE_B64), Some(&own)),
            DeliveredShareCheck::MatchesOwnSecret
        );
        assert_eq!(
            check_delivered_share(Some(VALID_TEST_SHARE_B64), Some(&other)),
            DeliveredShareCheck::DiffersFromOwnSecret
        );
        assert_eq!(
            check_delivered_share(Some(VALID_TEST_SHARE_B64), None),
            DeliveredShareCheck::Unverifiable
        );
    }

    /// Runs `set_in_vm_credentials` against a scratch cache with the given own
    /// secret, and returns (outcome, whether the share file was written).
    fn deliver_with_own_secret(
        share: &str,
        own: Option<Vec<u8>>,
        tag: u32,
    ) -> (DeliverCredentialsOutcome, bool) {
        let _serialized = crate::test_support::env_lock();
        let cache_root =
            std::env::temp_dir().join(format!("tillandsias-1200-{}-{}", std::process::id(), tag));
        let _ = std::fs::remove_dir_all(&cache_root);
        std::fs::create_dir_all(&cache_root).expect("temp cache root");
        // SAFETY: env mutation is serialized by crate::test_support::env_lock() for the whole call.
        unsafe { std::env::set_var("XDG_CACHE_HOME", &cache_root) };
        TEST_OWN_UNSEAL_SECRET.with(|s| *s.borrow_mut() = own);
        let outcome = set_in_vm_credentials(
            Some(share.to_string()),
            "test-installation".to_string(),
            Some("s.token".to_string()),
        );
        let written = cache_root
            .join("tillandsias")
            .join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"))
            .is_file();
        TEST_OWN_UNSEAL_SECRET.with(|s| *s.borrow_mut() = None);
        unsafe { std::env::remove_var("XDG_CACHE_HOME") };
        let _ = std::fs::remove_dir_all(&cache_root);
        (outcome, written)
    }

    /// 1200-ih38 REVIEW (data-loss path). A share that differs from the own
    /// secret must still be STORED: the guest's wipe predicate counts only the
    /// fallback share file, so refusing to write it made a guest with a missing
    /// share file WIPE vault-data on its next launch; in the 2026-08-17 shape a
    /// healthy vault. PRE-FIX RESULT (756e30a90): FAILS: Rejected, not written,
    /// predicate false.
    #[test]
    fn a_mismatched_share_keeps_the_wipe_predicate_true() {
        let _serialized = crate::test_support::env_lock();
        let cache_root = std::env::temp_dir().join(format!(
            "tillandsias-1200-wipe-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_dir_all(&cache_root);
        std::fs::create_dir_all(&cache_root).expect("temp cache root");
        // SAFETY: env mutation is serialized by crate::test_support::env_lock() for the whole test.
        unsafe { std::env::set_var("XDG_CACHE_HOME", &cache_root) };
        // The GUEST's predicate is the fallback half alone (no keychain in a
        // guest); asserting through the full predicate was vacuous on a host
        // whose own keyring holds a share. PREMISE: no share file yet.
        let dir = cache_root.join("tillandsias");
        let before = fallback_share_counts(&dir);
        TEST_OWN_UNSEAL_SECRET.with(|s| *s.borrow_mut() = Some((2..=33).collect()));
        let outcome = set_in_vm_credentials(
            Some(VALID_TEST_SHARE_B64.to_string()),
            "test-installation".to_string(),
            Some("s.token".to_string()),
        );
        let after = fallback_share_counts(&dir);
        TEST_OWN_UNSEAL_SECRET.with(|s| *s.borrow_mut() = None);
        unsafe { std::env::remove_var("XDG_CACHE_HOME") };
        let _ = std::fs::remove_dir_all(&cache_root);
        assert!(
            !before,
            "premise: the wipe predicate was already true; this test proves nothing here"
        );
        assert_eq!(outcome, DeliverCredentialsOutcome::Accepted);
        assert!(
            after,
            "a mismatched share must not re-arm the vault-data wipe"
        );
    }

    /// A MALFORMED share is refused, and that opens no wipe path: the predicate
    /// only counts a file decoding to exactly 32 bytes, so a malformed share
    /// never kept a vault alive.
    #[test]
    fn a_malformed_rejection_leaves_the_wipe_predicate_as_it_was() {
        let (outcome, written) = deliver_with_own_secret("ZGVsaXZlcmVk", None, line!());
        assert!(matches!(
            outcome,
            DeliverCredentialsOutcome::Rejected { .. }
        ));
        assert!(!written);
    }

    #[test]
    fn a_malformed_share_is_rejected_and_not_stored() {
        let own: Vec<u8> = (1..=32).collect();
        let (outcome, written) = deliver_with_own_secret("ZGVsaXZlcmVk", Some(own), line!());
        match outcome {
            DeliverCredentialsOutcome::Rejected { reason } => {
                assert!(reason.contains("malformed"), "{reason}")
            }
            other => panic!("expected Rejected, got {other:?}"),
        }
        assert!(!written);
    }

    /// NEGATIVE CONTROL: a share that matches the own secret is still Accepted
    /// and persisted, and with NO readable own secret a well-formed share is
    /// accepted unverified — never a rejection manufactured out of an absent
    /// check (888-miiy's class).
    #[test]
    fn a_matching_share_and_an_unverifiable_share_are_accepted_and_stored() {
        let own: Vec<u8> = (1..=32).collect();
        let (m, mw) = deliver_with_own_secret(VALID_TEST_SHARE_B64, Some(own), line!());
        assert_eq!(m, DeliverCredentialsOutcome::Accepted);
        assert!(mw);
        let (u, uw) = deliver_with_own_secret(VALID_TEST_SHARE_B64, None, line!());
        assert_eq!(u, DeliverCredentialsOutcome::Accepted);
        assert!(uw);
    }

    /// `set_in_vm_credentials` is the tray's delivery path into a running guest.
    /// It wrote `fallback_vault-root-token-v1` and dropped the share — the exact
    /// asymmetry 694-mhz8 fixed at the fresh-init site, surviving at this one.
    /// The consequence is not cosmetic: a guest that has lost only its share
    /// file gets handed a good share by the host, uses it in memory, still fails
    /// `has_shamir_share_in_keyring`, and has its intact Vault WIPED on the next
    /// launch. The host held the evidence and the guest discarded it.
    ///
    /// Exercised through `set_in_vm_credentials` ITSELF, not through the shared
    /// writer. An earlier version of this test called the writer directly and
    /// was VACUOUS: reverting the call site to pass `None` for the share left it
    /// passing, because it never touched the code being fixed. That is this
    /// project's named recurring failure — "verified where it was written is not
    /// verified where it runs" — reproduced in the test for the fix against it.
    #[test]
    fn host_delivered_share_is_persisted_not_only_the_token() {
        let _serialized = crate::test_support::env_lock();

        let cache_root = std::env::temp_dir().join(format!(
            "tillandsias-701-delivered-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&cache_root).expect("temp cache root");
        // SAFETY: env mutation is serialized by crate::test_support::env_lock() for the whole test.
        unsafe { std::env::set_var("XDG_CACHE_HOME", &cache_root) };

        set_in_vm_credentials(
            // 1200-ih38: a delivered share must now be a well-formed 32-byte
            // key, so the placeholder ("delivered", 9 bytes) became one.
            Some(VALID_TEST_SHARE_B64.to_string()),
            "test-installation".to_string(),
            Some("s.delivered-token".to_string()),
        );

        let dir = cache_root.join("tillandsias");
        let share = dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"));
        assert!(
            dir.join("fallback_vault-root-token-v1").is_file(),
            "the token half must still be delivered (pre-701 behavior preserved)"
        );
        assert!(
            share.is_file(),
            "the DELIVERED share must be recorded where the wipe predicate reads, or \
             the next launch destroys an intact Vault the host could have saved. \
             This assertion must fail if set_in_vm_credentials stops passing the share."
        );
        assert_eq!(
            std::fs::read_to_string(&share)
                .expect("share readable")
                .trim(),
            VALID_TEST_SHARE_B64,
            "a corrupted share cannot unseal, so it must round-trip verbatim"
        );

        unsafe { std::env::remove_var("XDG_CACHE_HOME") };
        let _ = std::fs::remove_dir_all(&cache_root);
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik) for the test above, and the reason
    /// this fix is not "always write a share file". The partial-init wipe must
    /// still fire when NO share was ever captured — a Vault initialized with an
    /// unknown key can never unseal, and preserving it strands the guest
    /// permanently. A delivery carrying only a token must therefore leave the
    /// share file absent.
    /// 701-se6x criterion 2. A FAILED share write must be SURFACED, not
    /// discarded. This is the assertion that makes the difference observable:
    /// before the fix the helper returned `()`, so there was no value a test
    /// could look at and no way for a caller to know the wipe had been re-armed.
    ///
    /// The failure is induced portably by making the destination an existing
    /// DIRECTORY — `fs::write` cannot clobber one on any platform — rather than
    /// by chmod games, which root ignores and which behave differently across
    /// the fleet's three host kinds.
    #[test]
    fn a_failed_share_fallback_write_is_reported_not_discarded() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701se6x-loud-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        // Occupy the share path with a directory so the write must fail.
        std::fs::create_dir_all(dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}")))
            .expect("occupy the share path");

        let res = write_vm_credential_fallbacks(&dir, Some("s.roottoken"), Some("c2hhcmU="));

        assert!(
            res.is_err(),
            "a share-fallback write that FAILED must be reported. Discarding it leaves \
             has_shamir_share_in_keyring() false with a healthy Vault on disk, and the next \
             launch wipes it (694-mhz8 re-armed)."
        );
        let msg = res.unwrap_err().to_string();
        assert!(
            msg.contains(VAULT_SHAMIR_SHARE_V1),
            "the report must NAME the artifact that failed so an operator knows the wipe is \
             armed; got: {msg}"
        );

        // The token half must still have been ATTEMPTED and succeeded — a
        // failure on one artifact must not skip the other.
        assert!(
            dir.join("fallback_vault-root-token-v1").is_file(),
            "the token write must still happen when the share write fails"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// NEGATIVE CONTROL for the test above. Without this, a helper that simply
    /// returned `Err` unconditionally would satisfy every assertion there while
    /// making the loud path fire on every healthy boot — an alarm that is always
    /// on is one nobody reads, and it would push operators to ignore the one
    /// message that means their Vault is about to be wiped.
    #[test]
    fn a_successful_fallback_write_reports_success() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701se6x-quiet-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");

        let res = write_vm_credential_fallbacks(&dir, Some("s.roottoken"), Some("c2hhcmU="));

        assert!(
            res.is_ok(),
            "the healthy path must stay silent — an always-firing alarm trains operators to \
             ignore the wipe warning; got: {res:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 701-se6x criterion 2, the ORDERING property. The share is the half that
    /// arms the wipe, so a token write that fails must not prevent it from being
    /// attempted. An early return after the token — the obvious way to write
    /// this with `?` — would pass both tests above and silently reintroduce the
    /// bug for the exact host whose disk is already misbehaving.
    #[test]
    fn a_failed_token_write_still_attempts_the_share() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701se6x-order-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        // Occupy the TOKEN path so its write fails first.
        std::fs::create_dir_all(dir.join("fallback_vault-root-token-v1"))
            .expect("occupy the token path");

        let res = write_vm_credential_fallbacks(&dir, Some("s.roottoken"), Some("c2hhcmU="));

        assert!(res.is_err(), "the token failure must still be reported");
        assert!(
            dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"))
                .is_file(),
            "the SHARE must be written even though the token write failed — it is the half \
             that decides whether the next launch wipes an initialized Vault"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delivery_without_a_share_leaves_the_wipe_predicate_able_to_fire() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-701-tokenonly-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");

        // 701-se6x: assert the write succeeded rather than discarding the
        // Result. Silencing it with `let _ =` here would reintroduce, in the
        // tests, precisely the habit this packet removed from the product.
        write_vm_credential_fallbacks(&dir, Some("s.delivered-token"), None)
            .expect("fallback write must succeed on a writable temp dir");

        assert!(
            dir.join("fallback_vault-root-token-v1").is_file(),
            "the token half of the delivery is still recorded"
        );
        assert!(
            !dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"))
                .is_file(),
            "a share that was never delivered must NOT be recorded as captured — \
             otherwise a genuine partial init is preserved and Vault can never unseal"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 694-mhz8. In-VM init must persist BOTH credential fallbacks. The share
    /// file is the only evidence, inside a VM, that `operator init` completed:
    /// `has_shamir_share_in_keyring` consults an OS keychain (absent in the
    /// guest) and then this file, and its answer decides whether the next
    /// bootstrap treats the data volume as a crashed partial init and WIPES it.
    /// Writing only the token — the pre-694 behavior — made that predicate
    /// permanently false in the guest, so every boot destroyed a healthy Vault
    /// and the stored GitHub token with it.
    #[test]
    fn in_vm_init_persists_both_credential_fallbacks() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-694-both-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");

        write_vm_credential_fallbacks(&dir, Some("s.roottoken"), Some("c2hhcmU="))
            .expect("fallback write must succeed on a writable temp dir");

        let share = dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"));
        let token = dir.join("fallback_vault-root-token-v1");
        assert!(
            token.is_file(),
            "root-token fallback must still be written (pre-694 behavior preserved)"
        );
        assert!(
            share.is_file(),
            "SHAMIR SHARE fallback must be written — without it the next bootstrap \
             classifies this initialized Vault as a partial init and wipes it (694-mhz8)"
        );
        assert_eq!(
            std::fs::read_to_string(&share)
                .expect("share readable")
                .trim(),
            "c2hhcmU=",
            "the share must round-trip verbatim; a corrupted share cannot unseal"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// NEGATIVE CONTROL (bar-raise 634-39ik) for the test above. The wipe branch
    /// this fix protects must still fire on a GENUINE partial init — an init that
    /// crashed before the share was ever captured. If the fix had instead relaxed
    /// the predicate (or if this helper wrote a share unconditionally), a Vault
    /// initialized with an unknown key would be preserved and could never unseal.
    /// So: no share in hand => no share file => partial init stays detectable.
    #[test]
    fn absent_share_writes_no_share_file_so_partial_init_stays_detectable() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-694-partial-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");

        // Init got far enough to mint a root token, then crashed before the
        // Shamir handover — exactly the case the wipe exists to recover.
        write_vm_credential_fallbacks(&dir, Some("s.roottoken"), None)
            .expect("fallback write must succeed on a writable temp dir");

        assert!(
            dir.join("fallback_vault-root-token-v1").is_file(),
            "token was captured in this scenario"
        );
        assert!(
            !dir.join(format!("fallback_{VAULT_SHAMIR_SHARE_V1}"))
                .is_file(),
            "a share that was never captured must NOT be recorded as captured — \
             otherwise a genuine partial init is preserved and Vault can never unseal"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn empty_handover_reply_does_not_close_first_boot_retry_window() {
        assert!(!handover_reply_delivers_unseal_share(None));
        assert!(!handover_reply_delivers_unseal_share(Some("  ")));
        assert!(handover_reply_delivers_unseal_share(Some(
            "c2hhbWlyLXNoYXJl"
        )));
    }

    #[test]
    fn policy_role_names_match_spec() {
        assert_eq!(policy_role_name(&Policy::GitMirror), "git-mirror");
        assert_eq!(policy_role_name(&Policy::Forge), "forge");
        assert_eq!(policy_role_name(&Policy::Tray), "tray");
        assert_eq!(policy_role_name(&Policy::Inference), "inference");
        assert_eq!(policy_role_name(&Policy::GithubLogin), "github-login");
        assert_eq!(policy_role_name(&Policy::ClaudeLogin), "claude-login");
        assert_eq!(policy_role_name(&Policy::CodexLogin), "codex-login");
        assert_eq!(policy_role_name(&Policy::CodexForge), "codex-forge");
        assert_eq!(policy_role_name(&Policy::OpenCodeForge), "opencode-forge");
        assert_eq!(
            policy_role_name(&Policy::AntigravityLogin),
            "antigravity-login"
        );
    }

    #[test]
    fn existing_vault_requires_both_newest_policy_and_agent_role_migrations() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let ensure = source
            .split("pub fn ensure_vault_running(")
            .nth(1)
            .expect("ensure_vault_running source");
        let opencode_probe = ["approle_role_exists(", "\"opencode-forge\"", ")"].concat();
        let agent_probe = ["approle_role_exists(", "GIT_MIRROR_AGENT_ROLE", ")"].concat();
        let combined_gate = [
            "if opencode_role_exists ",
            "&& git_mirror_agent_role_exists",
        ]
        .concat();
        assert!(
            ensure.contains(&opencode_probe)
                && ensure.contains(&agent_probe)
                && ensure.contains(&combined_gate),
            "an existing volume may skip provisioning only after both order-431's \
             newest Policy role and order-424's dedicated Agent role exist"
        );
    }

    #[test]
    fn git_mirror_agent_role_and_secret_issuances_are_distinct() {
        assert_eq!(GIT_MIRROR_AGENT_ROLE, "git-mirror-agent");
        let first = next_approle_auto_auth_secret_name(GIT_MIRROR_AGENT_ROLE, "alpha-1234");
        let second = next_approle_auto_auth_secret_name(GIT_MIRROR_AGENT_ROLE, "alpha-1234");
        assert_ne!(
            first, second,
            "same-process lane relaunches must not overwrite a prior reusable SecretID accessor"
        );
        for name in [first, second] {
            assert!(
                name.starts_with("tillandsias-vault-approle-git-mirror-agent-alpha-1234-"),
                "unexpected auto-auth secret name: {name}"
            );
        }
    }

    #[test]
    fn provisioning_keeps_agent_role_separate_from_one_shot_roles() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("pub async fn provision_approle_roles(")
            .nth(1)
            .expect("provision_approle_roles source")
            .split("\n///")
            .next()
            .unwrap();
        assert!(
            window.contains(".create_approle_role(")
                && window.contains(".create_approle_agent_role(")
                && window.contains("GIT_MIRROR_AGENT_ROLE")
                && window.contains("Policy::GitMirror.name()"),
            "ordinary one-shot roles and the reusable mirror-agent role must be provisioned separately"
        );
    }

    #[test]
    fn vault_exec_command_sets_required_env_and_hides_token() {
        // `podman exec` does not inherit the entrypoint env, so the exec'd vault
        // CLI must get VAULT_ADDR + VAULT_SKIP_VERIFY or it fails with a
        // self-signed-cert TLS error. The token must reach the container on
        // STDIN, read by the in-container shim: never on argv (visible in `ps`)
        // and never as a name-only `-e VAULT_TOKEN` pass-through, which the
        // builder toolbox's flatpak-spawn podman wrapper drops on the floor
        // (measured 2026-09-18; the v56.9.18.1 ci4 forge-lane reds). Regression
        // guard for the HTTP→podman-exec credential-read move and for that one.
        // @trace plan/issues/vault-exec-env-regression-2026-06-27.md
        let cmd = vault_exec_command(&["kv", "get", "secret/x"], false);

        let args: Vec<String> = cmd
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(
            args.contains(&format!("VAULT_ADDR={VAULT_EXEC_ADDR}")),
            "missing VAULT_ADDR; args={args:?}"
        );
        assert!(
            args.contains(&"VAULT_SKIP_VERIFY=true".to_string()),
            "missing VAULT_SKIP_VERIFY; args={args:?}"
        );
        // stdin must be attached for the shim to read the token line.
        assert!(
            args.contains(&"-i".to_string()),
            "missing -i; args={args:?}"
        );
        // The shim reads the token from stdin inside the container...
        assert!(
            args.iter().any(|a| a.contains("read -r VAULT_TOKEN")),
            "missing the stdin token shim; args={args:?}"
        );
        // ...and the broken pass-through form is gone: no bare `VAULT_TOKEN`
        // argv entry, and no VAULT_TOKEN in the podman process environment.
        assert!(
            !args.iter().any(|a| a == "VAULT_TOKEN"),
            "name-only -e VAULT_TOKEN pass-through must not be used; args={args:?}"
        );
        assert!(
            !cmd.get_envs()
                .any(|(k, _)| k == std::ffi::OsStr::new("VAULT_TOKEN")),
            "VAULT_TOKEN must not be set in the podman process env"
        );
        // The vault argv follows the shim's `sh` $0 placeholder intact.
        let tail: Vec<&str> = args.iter().rev().take(3).map(String::as_str).collect();
        assert_eq!(
            tail,
            ["secret/x", "get", "kv"],
            "vault argv order; args={args:?}"
        );
        // Presence probes drop stdout inside the container, not at the host.
        let quiet = vault_exec_command(&["kv", "get", "secret/x"], true);
        assert!(
            quiet
                .get_args()
                .any(|a| a.to_string_lossy().ends_with(">/dev/null")),
            "discard_stdout must redirect inside the container"
        );
    }

    #[test]
    #[cfg(not(target_os = "linux"))]
    fn host_base_url_targets_loopback() {
        let url = host_base_url();
        assert!(url.starts_with("https://127.0.0.1:"), "got {url}");
        assert!(url.ends_with(&VAULT_HOST_PORT.to_string()));
    }

    #[test]
    fn vault_api_base_url_honors_env_override() {
        let _guard = crate::test_support::env_lock();
        unsafe {
            std::env::set_var(VAULT_API_BASE_URL_ENV, vault_service_base_url());
        }
        assert_eq!(vault_api_base_url(), vault_service_base_url());
        unsafe {
            std::env::remove_var(VAULT_API_BASE_URL_ENV);
        }
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn in_vm_vault_endpoint_has_no_loopback_publish_dependency() {
        assert_eq!(linux_vault_api_base_url(true), "https://vault:8200");
        assert_eq!(vault_host_publish_arg(true), None);

        assert_eq!(
            linux_vault_api_base_url(false),
            format!("https://127.0.0.1:{VAULT_HOST_PORT}")
        );
        assert_eq!(
            vault_host_publish_arg(false),
            Some(format!("127.0.0.1:{VAULT_HOST_PORT}:8200"))
        );
    }

    #[test]
    fn vault_tls_leaf_san_includes_service_dns() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        assert!(
            source.contains("DNS:vault"),
            "Vault TLS leaf must cover the Podman service DNS name"
        );
        assert!(
            source.contains("vault_tls_leaf_has_service_identity"),
            "existing Vault certs without the service DNS SAN must be refreshed"
        );
    }

    #[test]
    fn vault_launch_uses_network_alias_without_singleton_ip() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("fn launch_vault_container(")
            .nth(1)
            .expect("launch_vault_container source");
        assert!(
            window.contains("\"--network-alias\"") && window.contains("VAULT_NETWORK_ALIAS"),
            "Vault must publish the service-discovery alias on the enclave network"
        );
        assert!(
            !window.contains("\"--ip\""),
            "Vault service discovery should not depend on a singleton enclave IP"
        );
    }

    #[test]
    fn vault_secret_create_uses_atomic_replace_not_racy_rm_create() {
        // Regression guard for the concurrent-init secret race: a `secret rm`
        // then `secret create` is NOT atomic — a second concurrent vault
        // bootstrap can create the secret between this process's rm and create,
        // making create fail "secret name in use" (spurious --init failure under
        // concurrent forge activity, seen on Silverblue). Each of the three
        // secret-create helpers must use `podman secret create --replace` and
        // must NOT carry a racy `["secret", "rm", …]` preamble in its own body.
        // @trace plan/issues/vault-secret-refresh-concurrent-race-2026-07-04.md
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        for func in [
            "fn create_unseal_secret(",
            "fn create_token_podman_secret(",
            "fn create_file_podman_secret(",
        ] {
            let after = source.split(func).nth(1).unwrap_or_else(|| {
                panic!("{func} must exist");
            });
            // Window = this function body up to the next top-level `fn `.
            let window = after.split("\nfn ").next().unwrap_or(after);
            assert!(
                window.contains("\"--replace\""),
                "{func} must create its podman secret with --replace (atomic idempotent)"
            );
            assert!(
                !window.contains("[\"secret\", \"rm\""),
                "{func} must NOT do a racy `secret rm` before `secret create` — use --replace"
            );
        }
    }

    /// Order 387: the vault container `podman run` must include `--replace` so a
    /// crashed/exited vault holding the name does not block relaunch with a
    /// Permanent exit-125 (mirrors the proxy/git/router/inference builders).
    #[test]
    fn vault_run_args_use_replace_for_idempotency() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("fn launch_vault_container(")
            .nth(1)
            .expect("launch_vault_container source must exist");
        assert!(
            window.contains("\"--replace\""),
            "vault container run args must include --replace so relaunch is \
             idempotent (order 387): launch_vault_container body missing --replace"
        );
    }

    /// Order 383: the post-heal classifier may report success only when
    /// lookup-self is reachable AND approle + KV are reachable-or-absent.
    /// A Denied on approle/KV with a working lookup-self is exactly the
    /// 2026-07-17 Windows wrinkle and must escalate.
    #[test]
    fn post_heal_classifier_escalates_deep_skew() {
        use ProbeOutcome::{Absent, Denied, Failed, Reachable};
        // Fully reachable — healed.
        assert!(classify_post_heal(&Reachable, &Reachable, &Reachable).is_ok());
        // Fresh-but-empty vault: absent approle roles + absent KV is healthy.
        assert!(classify_post_heal(&Reachable, &Absent, &Absent).is_ok());
        // The Windows wrinkle: lookup-self fine, approle/KV denied → escalate.
        let err =
            classify_post_heal(&Reachable, &Denied, &Denied).expect_err("deep skew must escalate");
        assert!(err.contains("approle"), "reason must name the probe: {err}");
        // KV alone denied → escalate.
        assert!(classify_post_heal(&Reachable, &Reachable, &Denied).is_err());
        // Fresh token that itself fails lookup-self → escalate.
        assert!(classify_post_heal(&Denied, &Reachable, &Reachable).is_err());
        // Unverifiable (transport failure) is not success.
        assert!(classify_post_heal(&Reachable, &Failed("timeout".into()), &Reachable).is_err());
    }

    /// Order 383 (macuahuitl live repro): a mocked-podman litmus returned
    /// `mock-exec-output` for the handover files and this path persisted it
    /// over the operator's REAL keychain credentials. The persist guard
    /// must reject anything that is not a vault service token + 32-byte
    /// base64 share pair.
    #[test]
    fn handover_persist_guard_rejects_garbage() {
        use base64::Engine;
        let real_share = base64::engine::general_purpose::STANDARD.encode([7u8; 32]);
        // The exact live-repro garbage.
        assert!(!handover_pair_is_persistable(
            "mock-exec-output",
            "mock-exec-output"
        ));
        // Plausible token, garbage share.
        assert!(!handover_pair_is_persistable("hvs.abc123", "not-base64!"));
        // Wrong share length (16 bytes).
        let short = base64::engine::general_purpose::STANDARD.encode([7u8; 16]);
        assert!(!handover_pair_is_persistable("hvs.abc123", &short));
        // Garbage token, real share.
        assert!(!handover_pair_is_persistable(
            "mock-exec-output",
            &real_share
        ));
        // Real-shaped pairs pass (current hvs. and legacy s. prefixes).
        assert!(handover_pair_is_persistable("hvs.abc123", &real_share));
        assert!(handover_pair_is_persistable("s.abc123", &real_share));
    }

    /// Order 383: the heal path must NEVER wipe or re-initialize vault
    /// storage — it may hold real operator secrets. Source-shape pin: no
    /// volume removal, system reset, or re-init inside the heal seam.
    #[test]
    fn root_token_heal_never_wipes_storage() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        for func in ["fn heal_stale_root_token(", "fn validated_root_token("] {
            let after = source
                .split(func)
                .nth(1)
                .unwrap_or_else(|| panic!("{func} must exist"));
            // Truncate at the next fn OR the next doc comment — the
            // following function's doc prose may legitimately mention
            // storage commands it exists to prevent.
            let window = after.split("\nfn ").next().unwrap_or(after);
            let window = window.split("\n///").next().unwrap_or(window);
            for forbidden in [
                "volume\", \"rm",
                "volume rm",
                "system reset",
                "operator init",
            ] {
                assert!(
                    !window.contains(forbidden),
                    "{func} must never touch vault storage (found {forbidden:?})"
                );
            }
        }
    }

    /// Order 383: both vault bring-up paths must route their root token
    /// through the detect-and-heal seam, not the raw keychain read — a
    /// stale token must trigger generate-root instead of wedging every
    /// downstream write with `permission denied`.
    #[test]
    fn vault_bringup_routes_through_root_token_heal_seam() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        for func in ["fn ensure_vault_running(", "fn wait_for_vault_ready("] {
            let after = source
                .split(func)
                .nth(1)
                .unwrap_or_else(|| panic!("{func} must exist"));
            let window = after.split("\nfn ").next().unwrap_or(after);
            assert!(
                window.contains("validated_root_token("),
                "{func} must resolve its root token via validated_root_token (order 383)"
            );
        }
    }

    #[test]
    fn handover_token_is_shredded_before_unlink() {
        // P1-1: the first-boot root-token handover must be OVERWRITTEN in tmpfs
        // before it is unlinked — `rm` alone frees the RAM pages without zeroing,
        // leaving the token recoverable. Assert the shred path zeros with dd
        // (conv=notrunc, in place) and only then rm -f.
        // @trace plan/issues/security-audit-zero-trust-2026-07-01.md (P1-1)
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("fn read_and_handover_root_token(")
            .nth(1)
            .expect("read_and_handover_root_token source");
        let dd_at = window
            .find("dd if=/dev/zero")
            .expect("handover cleanup must overwrite the token with zeros (dd), not just unlink");
        assert!(
            window[dd_at..].contains("conv=notrunc"),
            "the overwrite must be in place (conv=notrunc), not a truncation"
        );
        let rm_at = window
            .find("rm -f /run/vault-handover/root.token")
            .expect("handover cleanup must still unlink the files");
        assert!(
            dd_at < rm_at,
            "the token must be overwritten (shredded) BEFORE it is unlinked"
        );
    }

    #[test]
    fn vault_launch_selinux_label_is_conditional_not_unconditional() {
        // Regression guard for the v0.3.260702.2 Silverblue crash: the launch
        // must NOT hard-code `--security-opt label=type:vault_container_t`. That
        // type is undefined on a rootless native host (semodule needs root), so
        // an unconditional label makes crun EINVAL on keycreate (exit 126). The
        // label must come from vault_selinux_label_opt (which returns None ->
        // default container_t when the type is not loadable).
        // @trace plan/issues/vault-selinux-label-rootless-crash-2026-07-02.md
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("fn launch_vault_container(")
            .nth(1)
            .expect("launch_vault_container source");
        // The launch body must gate the label on vault_selinux_label_opt, not
        // push a bare vault_container_t label string.
        assert!(
            window.contains("vault_selinux_label_opt(debug)"),
            "launch must derive the SELinux label from vault_selinux_label_opt"
        );
        assert!(
            !window.contains("\"label=type:vault_container_t\""),
            "launch must NOT hard-code the vault_container_t label (rootless EINVAL)"
        );

        // vault_selinux_label_opt must fall back (return None) when the type is
        // not loaded/loadable, and only use the custom type when confirmed.
        let opt = source
            .split("fn vault_selinux_label_opt(")
            .nth(1)
            .expect("vault_selinux_label_opt source");
        assert!(
            opt.contains("vault_container_type_loaded()") && opt.contains("return None"),
            "the label helper must confirm the type is loaded and fall back to None otherwise"
        );

        // The embedded CIL still declares the type for the guest-VM (root) path.
        let cil = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../images/selinux/vault_container.cil"
        ));
        assert!(
            cil.contains("(type vault_container_t)"),
            "vault_container.cil must declare vault_container_t"
        );

        // Declaring the type is not enough: launch checks are charged to the
        // SOURCE domain container_runtime_t, which stays enforcing (the
        // typepermissive only covers vault_container_t-sourced checks). The
        // CIL must grant the runtime→vault transition family — plain
        // `transition` (EACCES on the entrypoint exec without it) and
        // `nnp_transition` (EPERM; the vault run sets no-new-privileges) —
        // and container_domain membership so container-selinux's own
        // runtime↔container rules apply. AVCs observed on the enforcing
        // Fedora 44 VZ guest, 2026-07-02.
        assert!(
            cil.contains("(typeattributeset container_domain (vault_container_t))"),
            "vault_container.cil must join container_domain (container-selinux runtime rules)"
        );
        assert!(
            cil.contains("(allow container_runtime_t vault_container_t (process (transition"),
            "vault_container.cil must allow the runtime→vault process transition"
        );
        assert!(
            cil.contains("(allow container_runtime_t vault_container_t (process2 (nnp_transition nosuid_transition)))"),
            "vault_container.cil must allow nnp/nosuid transition from container_runtime_t (no-new-privileges is set on the vault run)"
        );
    }

    /// Restart self-wedge (2026-07-17): `ensure_vault_running` must NEVER
    /// speculatively `--replace` an existing unseal secret. The live Windows
    /// repro wedged a previously-healthy vault exactly there — a routine
    /// restart re-ensured, recovered a NON-matching share, and the
    /// unconditional `create_unseal_secret` overwrote the working podman
    /// secret; the container then crash-looped on unseal and every liveness
    /// cycle regenerated the secret again. The create call must be gated on
    /// `unseal_secret_exists()` (create only when NO secret exists — true
    /// first boot), and a reused secret's launch failure must route through
    /// the one-shot recovery seam instead of a blind regenerate.
    /// @trace plan/issues/vault-unseal-secret-regenerated-on-reensure-2026-07-17.md
    #[test]
    fn ensure_never_speculatively_replaces_existing_unseal_secret() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let after = source
            .split("pub fn ensure_vault_running(")
            .nth(1)
            .expect("ensure_vault_running source");
        let window = after.split("\nfn ").next().unwrap_or(after);
        let exists_at = window.find("unseal_secret_exists()").expect(
            "ensure_vault_running must gate unseal-secret creation on prior secret \
             existence (verify-before-persist; 2026-07-17 restart self-wedge)",
        );
        let create_at = window
            .find("create_unseal_secret(")
            .expect("first-boot secret creation must still exist");
        assert!(
            exists_at < create_at,
            "the existence gate must precede the create call so an existing secret \
             is never speculatively replaced"
        );
        assert!(
            window.contains("recover_rejected_unseal_secret_once("),
            "a reused secret's launch failure must route through the one-shot \
             unseal recovery seam, never a blind regenerate"
        );
    }

    /// The recovery seam may fire only on the POSITIVE key-rejection signal
    /// from the container's own entrypoint logs — never on a transient
    /// recreate window, a first-boot init, a pre-unseal crash, or a
    /// still-running container. Markers are pinned to the shipped
    /// entrypoint so a rewording there fails here instead of silently
    /// disarming the classifier.
    #[test]
    fn unseal_key_rejection_classifier_requires_positive_signal() {
        let entrypoint = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../images/vault/entrypoint.sh"
        ));
        for marker in [
            UNSEAL_LOG_SUBSEQUENT_BOOT,
            UNSEAL_LOG_ATTEMPT,
            UNSEAL_LOG_WRONG_KEY,
            UNSEAL_LOG_SUCCESS,
            UNSEAL_LOG_ALREADY,
        ] {
            assert!(
                entrypoint.contains(marker),
                "classifier marker {marker:?} must match images/vault/entrypoint.sh — \
                 update both together"
            );
        }

        // The 2026-07-17 incident shape: initialized storage, unseal
        // attempted, HTTP 400 (curl 22), container dead — a key rejection.
        let base = "2026-07-17T12:00:00Z [vault-entrypoint] subsequent boot: using unseal key from secret\n\
                    2026-07-17T12:00:01Z [vault-entrypoint] unsealing vault\n";
        let rejected = format!("{base}{UNSEAL_LOG_WRONG_KEY}\n");
        assert!(unseal_failure_is_key_rejection(&rejected, false));
        let unclassified_400 = format!("{base}curl: (22) The requested URL returned error: 400\n");
        assert!(!unseal_failure_is_key_rejection(&unclassified_400, false));

        // Container still running → possibly mid-unseal; not a rejection.
        assert!(!unseal_failure_is_key_rejection(&rejected, true));
        // Unseal succeeded → whatever failed, it was not the key.
        let unsealed_ok = format!("{base}[vault-entrypoint] vault unsealed (sealed=false)\n");
        assert!(!unseal_failure_is_key_rejection(&unsealed_ok, false));
        let already = format!("{base}[vault-entrypoint] vault already unsealed\n");
        assert!(!unseal_failure_is_key_rejection(&already, false));
        // First boot (operator init path) — never a key rejection even when
        // the unseal step also appears and fails.
        let first_boot = "[vault-entrypoint] first boot: running vault operator init\n\
                          [vault-entrypoint] unsealing vault\n";
        assert!(!unseal_failure_is_key_rejection(first_boot, false));
        // Empty logs (order-235 recreate window, "no such container").
        assert!(!unseal_failure_is_key_rejection("", false));
        // Crash before the unseal step (e.g. API never came up).
        assert!(!unseal_failure_is_key_rejection(
            "[vault-entrypoint] FATAL: vault API never came up\n",
            false
        ));
    }

    #[test]
    fn approle_secret_lease_does_not_hold_vault_lock_while_lane_is_idle() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let lease = source
            .split("pub struct AppRoleSecretLease {")
            .nth(1)
            .expect("AppRoleSecretLease source")
            .split('}')
            .next()
            .expect("AppRoleSecretLease body");
        assert!(
            !lease.contains("ResourceLockGuard"),
            "an idle lane's secret lease must not retain the shared Vault lock"
        );

        let mint = source
            .split("pub fn mint_approle_secret_lease(")
            .nth(1)
            .expect("mint_approle_secret_lease source")
            .split("\n}")
            .next()
            .expect("mint_approle_secret_lease body");
        assert!(
            mint.contains("let _stability = vault_stability_lease(debug)?;"),
            "token minting must remain protected by the shared Vault lock"
        );
    }

    /// Exit-criterion litmus: a unseal secret that fails to unseal existing
    /// storage is never written/kept. The pure write-decision forbids the
    /// one-shot recovery write when the candidate is byte-identical to the
    /// just-rejected secret (it PROVABLY fails) and when the rejected bytes
    /// could not be read back (a failed candidate could not be restored
    /// away, leaving the secret in an unknown mutated state).
    #[test]
    fn unseal_recovery_write_decision_never_writes_a_proven_failing_key() {
        let candidate = [7u8; 32];
        // Identical to the just-rejected secret → provably fails → no write.
        let identical = [7u8; 32];
        assert!(unseal_recovery_write_decision(&candidate, Some(&identical[..])).is_err());
        // Unreadable current secret → no restore possible → no write.
        assert!(unseal_recovery_write_decision(&candidate, None).is_err());
        // A genuinely different candidate gets the single verify attempt.
        let different = [9u8; 32];
        assert!(unseal_recovery_write_decision(&candidate, Some(&different[..])).is_ok());
    }

    /// The unseal recovery seam must never touch vault storage, never derive
    /// a machine-id dummy key for real storage, and must stay a guarded
    /// one-shot (no regeneration loop). Same window technique as
    /// `root_token_heal_never_wipes_storage`.
    #[test]
    fn unseal_recovery_seam_is_one_shot_and_never_touches_storage() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let after = source
            .split("fn recover_rejected_unseal_secret_once(")
            .nth(1)
            .expect("recovery seam must exist");
        let window = after.split("\nfn ").next().unwrap_or(after);
        let window = window.split("\n///").next().unwrap_or(window);
        for forbidden in [
            "volume\", \"rm",
            "volume rm",
            "system reset",
            "operator init",
            "remove_dir_all",
            "ensure_unseal_key(",
        ] {
            assert!(
                !window.contains(forbidden),
                "the recovery seam must never touch storage or derive a dummy key \
                 (found {forbidden:?})"
            );
        }
        assert!(
            window.contains("unseal_failure_is_key_rejection("),
            "recovery may run only on the positive key-rejection signal"
        );
        assert!(
            window.contains("UNSEAL_RECOVERY_ATTEMPTED"),
            "recovery must consume the one-shot guard (no regeneration loop)"
        );
        assert!(
            window.contains("read_shamir_share_b64("),
            "the candidate must come from the fail-loud share readers"
        );
        assert!(
            window.contains("unseal_recovery_write_decision("),
            "the secret write must be gated by the pure never-write-a-failing-key decision"
        );
        assert!(
            window.contains("attended_unseal_verdict("),
            "dead ends must surface the attended-recovery verdict"
        );
        // The verdict itself is loud and storage-preserving.
        assert!(
            source.contains(
                "OPERATOR ACTION REQUIRED: the vault unseal secret does not unseal the existing"
            ),
            "the attended verdict must carry the loud OPERATOR ACTION REQUIRED grammar"
        );
        assert!(
            source.contains("Do NOT wipe the vault-data volume"),
            "the attended verdict must forbid wiping storage"
        );
    }

    /// Order 259: the cold-VM first-login name-in-use race is closed by TWO
    /// invariants that must both hold: (a) every vault bring-up serializes
    /// behind the order-232 exclusive flock BEFORE the running-check (so the
    /// loser observes the winner's container and early-returns instead of
    /// racing `podman run`), and (b) the launch replaces any exited/created
    /// name-holder (`podman rm -f` preamble) instead of erroring on it.
    #[test]
    fn vault_launch_serializes_and_replaces_stale_name_holder() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let ensure = source
            .split("pub fn ensure_vault_running(")
            .nth(1)
            .expect("ensure_vault_running source");
        let lock_idx = ensure
            .find("resource_lock::acquire(\"vault\"")
            .expect("ensure_vault_running must take the order-232 vault flock");
        let running_check_idx = ensure
            .find("container_running(VAULT_CONTAINER_NAME)")
            .expect("ensure_vault_running must early-return on a running vault");
        assert!(
            lock_idx < running_check_idx,
            "the exclusive vault flock must be held BEFORE the running-check (order 259)"
        );
        let launch = source
            .split("fn launch_vault_container(")
            .nth(1)
            .expect("launch_vault_container source");
        let rm_idx = launch
            .find("[\"rm\", \"-f\", VAULT_CONTAINER_NAME]")
            .expect("launch must rm -f any stale name-holder before podman run (order 259)");
        let run_idx = launch
            .find("podman run")
            .or_else(|| launch.find("run_args"))
            .expect("launch must run the vault container");
        assert!(
            rm_idx < run_idx,
            "stale-name replacement must precede the run (order 259)"
        );
    }

    #[test]
    fn vault_ready_wait_uses_podman_health() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        // BOUNDED TO THE FUNCTION BODY (1461-8tyy). This window used to run to
        // the END OF THE FILE, so any `thread::sleep` anywhere below the
        // function failed an assertion that is about this function only —
        // the GitHub token rotation scheduler's between-checks sleep did.
        let after = source
            .split("fn wait_for_vault_ready(")
            .nth(1)
            .expect("wait_for_vault_ready source");
        let window = &after[..after.find("\n}\n").expect("end of wait_for_vault_ready")];
        assert!(
            window.contains("PodmanClient::new().wait_healthy(VAULT_CONTAINER_NAME)"),
            "Vault readiness must use the idiomatic podman health layer"
        );
        assert!(
            !window.contains("thread::sleep"),
            "Vault readiness must not use a local polling sleep loop"
        );
        // Order 235: the transient-error retry around wait_healthy must stay
        // BOUNDED (attempt cap present) — readiness detection remains
        // delegated to podman; only the inter-attempt backoff may sleep, and
        // never unboundedly.
        assert!(
            window.contains("attempt == 3"),
            "transient health-wait retry must keep its bounded attempt cap"
        );
    }

    #[test]
    fn approle_ttl_constants_match_spec() {
        // tillandsias-vault.invariant.token-ttl-1h
        assert_eq!(APPROLE_TOKEN_TTL_SECS, 3_600);
        // 24h ceiling matches the spec's max_ttl guidance.
        assert_eq!(APPROLE_TOKEN_MAX_TTL_SECS, 86_400);
    }

    // -----------------------------------------------------------------------
    // Order 749-8iw4 / 753-ii5f — the audit volume contract, testable without podman
    // -----------------------------------------------------------------------
    #[test]
    fn audit_volume_targets_the_path_the_entrypoint_writes_to() {
        // images/vault/entrypoint.sh enables a file audit device at
        // /vault/audit/audit.json. If the destination here drifts, the device
        // writes to a container layer again and dies on recreate — while
        // `vault audit list` keeps reporting it healthy. That is V12 exactly.
        let arg = vault_audit_volume_arg(std::path::Path::new(
            "/home/u/.cache/tillandsias/vault-audit",
        ));
        assert!(
            arg.contains(":/vault/audit:"),
            "audit volume must target /vault/audit, got {arg}"
        );
    }

    #[test]
    fn audit_volume_is_relabelled_for_userns_drift() {
        // Without :U a userns mapping shift leaves the directory owned by a uid
        // `vault` cannot write. An audit device that cannot write is fatal to
        // Vault: every request fails once nothing can record it.
        let arg = vault_audit_volume_arg(std::path::Path::new("/tmp/x"));
        assert!(arg.ends_with(":U"), "audit volume must carry :U, got {arg}");
    }

    #[test]
    fn audit_volume_uses_the_supplied_host_dir_verbatim() {
        // Pins the host side to the caller's directory, so a change to
        // init_cache_dir() surfaces as a changed argument instead of silently
        // relocating the audit records somewhere unwritable.
        let arg = vault_audit_volume_arg(std::path::Path::new("/some/where/vault-audit"));
        assert_eq!(arg, "/some/where/vault-audit:/vault/audit:U");
    }

    #[test]
    fn audit_volume_is_distinct_from_the_data_volume() {
        // A single mount cannot serve both: /vault/data holds Vault's storage
        // and /vault/audit holds the audit log. Collapsing them would make the
        // grep-level pins pass while persistence semantics changed.
        let audit = vault_audit_volume_arg(std::path::Path::new("/c/vault-audit"));
        let data = format!("{}:/vault/data:U", "/c/vault-data");
        assert_ne!(audit, data);
        assert!(!audit.contains("/vault/data"));
    }

    #[test]
    fn vault_launch_requires_the_content_addressed_image_tag() {
        let digest = "a".repeat(64);
        let canonical = format!("localhost/tillandsias-vault:sha256-{digest}");
        assert_eq!(
            canonical_vault_launch_tag(&canonical).expect("canonical tag"),
            canonical
        );
        assert!(canonical_vault_launch_tag("localhost/tillandsias-vault:latest").is_err());
        assert!(canonical_vault_launch_tag("localhost/tillandsias-vault:sha256-short").is_err());
    }

    // -----------------------------------------------------------------------
    // Order 606-bvnp — opaque mirror identity + exact SSH signer substrate
    // -----------------------------------------------------------------------

    #[test]
    fn base32hex_encoder_matches_rfc4648_vectors() {
        // RFC 4648 §10 base32hex vectors, lowercased and unpadded.
        for (input, expected) in [
            (&b""[..], ""),
            (&b"f"[..], "co"),
            (&b"fo"[..], "cpng"),
            (&b"foo"[..], "cpnmu"),
            (&b"foob"[..], "cpnmuog"),
            (&b"fooba"[..], "cpnmuoj1"),
            (&b"foobar"[..], "cpnmuoj1e8"),
        ] {
            assert_eq!(base32hex_lowercase_nopad(input), expected);
        }
    }

    #[test]
    fn minted_mirror_ids_are_20_char_base32hex_unique_and_dns_safe() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..64 {
            let id = mint_mirror_id().expect("host CSPRNG");
            assert_eq!(id.len(), MIRROR_ID_LEN, "12 bytes must encode to 20 chars");
            assert!(
                mirror_id_is_valid(&id),
                "grammar rejects its own mint: {id}"
            );
            assert!(
                id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'v')),
                "outside the base32hex lowercase alphabet: {id}"
            );
            assert!(seen.insert(id), "96 random bits collided within 64 mints");
        }
        // The derived hostname must be one valid DNS label (24 chars),
        // assignable as a podman --network-alias (D13).
        let hostname = mirror_service_hostname("0123456789abcdefghij");
        assert_eq!(hostname, "git-0123456789abcdefghij");
        assert_eq!(hostname.len(), 24);
        assert!(hostname.len() <= 63, "must stay a single DNS label");
        assert!(
            hostname
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
            "hostname must be lowercase alphanumeric/hyphen: {hostname}"
        );

        // Grammar rejects everything that is not the mint output.
        assert!(!mirror_id_is_valid("0123456789abcdefghi")); // 19 chars
        assert!(!mirror_id_is_valid("0123456789abcdefghijk")); // 21 chars
        assert!(!mirror_id_is_valid("0123456789ABCDEFGHIJ")); // uppercase
        assert!(!mirror_id_is_valid("0123456789abcdefghiw")); // 'w' > 'v'
        assert!(!mirror_id_is_valid("myproject-mirror-idx")); // guessable name shape
    }

    #[test]
    fn mirror_identity_derivations_are_exact() {
        let id = "0123456789abcdefghij";
        assert_eq!(
            mirror_push_principal(id),
            "til:forge-push:0123456789abcdefghij"
        );
        assert_eq!(mirror_client_signer_role(id), id);
        assert_eq!(mirror_host_signer_role(id), "host-0123456789abcdefghij");
        assert_eq!(
            mirror_lane_signer_policy_name(id),
            "ssh-lane-signer-0123456789abcdefghij"
        );
        assert_eq!(
            mirror_host_signer_policy_name(id),
            "ssh-host-signer-0123456789abcdefghij"
        );
        assert_eq!(
            mirror_identity_kv_path("alpha"),
            "secret/mirror-identity/alpha"
        );
        assert_eq!(SSH_CLIENT_SIGNER_MOUNT, "ssh-client-signer");
        assert_eq!(SSH_HOST_SIGNER_MOUNT, "ssh-host-signer");
    }

    #[test]
    fn minted_policies_grant_exact_sign_paths_and_never_a_wildcard() {
        let id = "0123456789abcdefghij";
        let lane = render_lane_signer_policy_hcl(id);
        let host = render_host_signer_policy_hcl(id);
        // The exact per-project paths, capabilities update-only (D12).
        assert!(
            lane.contains("path \"ssh-client-signer/sign/0123456789abcdefghij\""),
            "lane policy must name the exact client sign path:\n{lane}"
        );
        assert!(
            host.contains("path \"ssh-host-signer/sign/host-0123456789abcdefghij\""),
            "host policy must name the exact host sign path:\n{host}"
        );
        for hcl in [&lane, &host] {
            assert!(
                hcl.contains("capabilities = [\"update\"]"),
                "sign policies are update-only:\n{hcl}"
            );
            // THE guard of the 2026-08-10 amendment: no rendered policy may
            // ever contain the withdrawn cross-project wildcard.
            assert!(
                !hcl.contains("sign/*"),
                "sign/* wildcard is cross-project signing authority (D12):\n{hcl}"
            );
            // Neither policy may touch the CA config or role enumeration
            // (verified enforced, V6 — but never granted in the first place).
            assert!(!hcl.contains("config/ca"));
            assert!(!hcl.contains("roles/"));
        }
        // The runtime write-guard refuses a wildcard body outright.
        assert!(
            reject_sign_wildcard("bad", "path \"ssh-client-signer/sign/*\" {}").is_err(),
            "a sign/* body must be refused before it reaches sys/policies/acl"
        );
        assert!(reject_sign_wildcard("good", &lane).is_ok());
    }

    #[test]
    fn every_minted_policy_write_passes_the_sign_wildcard_guard() {
        // Source guard (§4 T2): the ONLY path that writes these minted
        // policies must run every body through reject_sign_wildcard before
        // write_policy. A future template edit cannot skip the guard without
        // failing here.
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("pub async fn provision_mirror_ssh_roles(")
            .nth(1)
            .expect("provision_mirror_ssh_roles source")
            .split("\npub async fn ")
            .next()
            .unwrap();
        let guard_idx = window
            .find("reject_sign_wildcard(&name, &hcl)?")
            .expect("minted policy writes must call reject_sign_wildcard");
        let write_idx = window
            .find(".write_policy(&name, &hcl)")
            .expect("provision_mirror_ssh_roles must write the minted policies");
        assert!(
            guard_idx < write_idx,
            "the sign/* guard must run before the policy reaches the server"
        );
    }

    #[test]
    fn client_signer_role_config_matches_design() {
        let cfg = build_client_signer_role_config("0123456789abcdefghij", "10.0.42.0/24");
        assert_eq!(cfg["key_type"], "ca");
        assert_eq!(cfg["allow_user_certificates"], true);
        // V3: exact principal list, no glob, never the project name (D3).
        assert_eq!(cfg["allowed_users"], "til:forge-push:0123456789abcdefghij");
        assert_eq!(cfg["default_user"], "git");
        // V4/D4: no extensions may be requested; two critical options ride
        // in every issued certificate.
        assert_eq!(cfg["allowed_extensions"], "");
        assert_eq!(cfg["default_extensions"], serde_json::json!({}));
        assert_eq!(
            cfg["default_critical_options"]["force-command"],
            "/usr/local/bin/tillandsias-receive"
        );
        assert_eq!(
            cfg["default_critical_options"]["source-address"],
            "10.0.42.0/24"
        );
        // D7 TTLs: 30-minute lane certs, 1h ceiling.
        assert_eq!(cfg["ttl"], "30m");
        assert_eq!(cfg["max_ttl"], "1h");
        assert_eq!(cfg["key_id_format"], "{{role_name}}|{{token_display_name}}");
        // The effective subnet flows through — an operator override must not
        // be silently replaced by the default (§2.3 lockout hazard).
        let overridden = build_client_signer_role_config("0123456789abcdefghij", "10.9.0.0/16");
        assert_eq!(
            overridden["default_critical_options"]["source-address"],
            "10.9.0.0/16"
        );
    }

    #[test]
    fn host_signer_role_config_certifies_exactly_one_opaque_hostname() {
        let cfg = build_host_signer_role_config("0123456789abcdefghij");
        assert_eq!(cfg["key_type"], "ca");
        assert_eq!(cfg["allow_host_certificates"], true);
        // D9: exactly the opaque per-project hostname; the retired shared
        // aliases are never certified.
        assert_eq!(cfg["allowed_domains"], "git-0123456789abcdefghij");
        assert_eq!(cfg["allow_bare_domains"], true);
        assert_eq!(cfg["allow_subdomains"], false);
        assert_eq!(cfg["ttl"], "24h");
        assert_eq!(cfg["max_ttl"], "48h");
        for retired in ["tillandsias-git", "git-service"] {
            assert_ne!(
                cfg["allowed_domains"], *retired,
                "shared alias {retired} must never re-enter the host CA"
            );
        }
    }

    /// ORDER 1313-prin. The host-signer AppRole must pair one-to-one with its
    /// minted policy, exactly as the lane-signer role does. The shared NAME is
    /// the visible half of that pairing in every Vault listing.
    #[test]
    fn host_signer_role_name_equals_its_policy_name() {
        let mid = "kvs69tkis9dfnbejbatg";
        assert_eq!(
            mirror_host_signer_role_name(mid),
            mirror_host_signer_policy_name(mid),
            "the host-signer role and its policy share a name so the one-role-one-policy \
             pairing is visible in a Vault listing, as the lane side already does"
        );
        assert_eq!(
            mirror_host_signer_role_name(mid),
            format!("ssh-host-signer-{mid}")
        );
        // PER-MIRROR, not global. This is the whole point: a shared role
        // carrying per-mirror policies would grant project A's mirror the
        // authority to sign project B's host certificates (D12, withdrawn
        // 2026-08-10), past reject_sign_wildcard, which only inspects policy
        // BODIES and would see no wildcard to refuse.
        assert_ne!(
            mirror_host_signer_role_name("aaa"),
            mirror_host_signer_role_name("bbb"),
            "the host-signer role must be PER-MIRROR; one shared role carrying every mirror's \
             policy is cross-project host-certificate signing with no wildcard anywhere"
        );
    }

    /// ORDER 1313-prin. The host push identity is DISTINCT from the forge's,
    /// and its role is separate so neither can mint the other's principal.
    #[test]
    fn host_push_identity_is_distinct_from_the_forge() {
        assert_eq!(host_push_principal("lenovinha"), "til:host-push:lenovinha");
        assert_ne!(
            host_push_principal("lenovinha"),
            mirror_push_principal("kvs69tkis9dfnbejbatg"),
            "a host pushing under the forge principal is indistinguishable from a lane in the \
             mirror's log, and revoking one would revoke the other"
        );
        assert_eq!(
            host_push_role_name("lenovinha"),
            host_push_policy_name("lenovinha")
        );
        assert_ne!(
            host_push_role_name("lenovinha"),
            host_push_role_name("yoga"),
            "the push role is PER-HOST; one shared role would let any host mint any host's cert"
        );
        let hcl = render_host_push_policy_hcl("lenovinha");
        assert!(reject_sign_wildcard("ssh-host-push-lenovinha", &hcl).is_ok());
    }

    /// ORDER 1313-prin. REGRESSION GUARD FOR A RETRACTED CHANGE. An earlier
    /// draft narrowed the host cert's source-address to 127.0.0.1/32, on the
    /// strength of a line read from the WRONG log — the git daemon's
    /// healthcheck output in the container log rather than sshd's own
    /// /tmp/tillandsias-sshd/sshd.err. sshd actually logs
    /// `Connection from 10.0.42.14`, an ENCLAVE peer, because rootless podman
    /// SNATs the published-port connection onto the container network. That
    /// cert would have been refused at authentication for every host push,
    /// reading as a bad key — the exact failure it claimed to prevent.
    #[test]
    fn host_push_role_keeps_the_enclave_source_address() {
        let cfg = build_host_push_signer_role_config("lenovinha", "10.0.42.0/24");
        let src = cfg["default_critical_options"]["source-address"]
            .as_str()
            .expect("source-address");
        assert_eq!(
            src, "10.0.42.0/24",
            "the host cert must carry the ENCLAVE subnet: a host arrives through the rootless \
             published port and sshd sees an enclave peer, so 127.0.0.1/32 would refuse every \
             host push at authentication"
        );
        assert_eq!(
            cfg["allowed_users"].as_str(),
            Some("til:host-push:lenovinha")
        );
        assert_eq!(
            cfg["allowed_extensions"].as_str(),
            Some(""),
            "a stolen host cert must not be able to open a shell or forward anything"
        );
        assert_eq!(
            cfg["default_critical_options"]["force-command"].as_str(),
            Some("/usr/local/bin/tillandsias-receive")
        );
    }

    /// ORDER 1313-prin. Source-level, because the property is "takes no other
    /// policy BY CONSTRUCTION" and a behavioural test would need a live Vault.
    /// The lane side documents the same invariant; this pins that the host side
    /// was built the same way rather than by widening a shared role.
    #[test]
    fn host_signer_approle_binds_exactly_one_policy() {
        let src = include_str!("vault_bootstrap.rs");
        let body = src
            .split("pub async fn provision_host_signer_approle(")
            .nth(1)
            .expect("provision_host_signer_approle source");
        let window = &body[..body.find("\n}\n").unwrap_or(body.len())];
        assert!(
            window.contains("&[&mirror_host_signer_policy_name(mirror_id)]"),
            "the host-signer role must be created with EXACTLY its own minted policy; got:\n{window}"
        );
        assert!(
            !window.contains("GIT_MIRROR_AGENT_ROLE"),
            "the host-signer authority must NOT be attached to the global git-mirror-agent role \
             — that is the cross-project grant D12 withdrew, reachable with no wildcard in any \
             policy body; got:\n{window}"
        );
    }

    #[tokio::test]
    async fn provision_mirror_identity_reads_existing_id_without_any_write() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        // Only the kv read is mounted. Any write attempt hits wiremock's
        // default 404 and would fail the call — the passing test IS the
        // proof that the already-provisioned path performs exactly one read
        // (the hot-path cheapness rule of the 606-bvnp scope).
        Mock::given(method("GET"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "data": { "mirror_id": "0123456789abcdefghij", "project": "alpha" },
                    "metadata": { "version": 1 }
                }
            })))
            .expect(1)
            .mount(&server)
            .await;
        let client = VaultClient::new(server.uri(), "root");
        let id = provision_mirror_identity(&client, "alpha", "10.0.42.0/24", false)
            .await
            .expect("stored identity must be returned as-is");
        assert_eq!(id, "0123456789abcdefghij", "re-reads must be stable");
    }

    #[tokio::test]
    async fn provision_mirror_identity_refuses_a_corrupt_stored_id() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "data": { "mirror_id": "NOT-A-VALID-MIRROR-ID" },
                    "metadata": { "version": 1 }
                }
            })))
            .mount(&server)
            .await;
        let client = VaultClient::new(server.uri(), "root");
        let err = provision_mirror_identity(&client, "alpha", "10.0.42.0/24", false)
            .await
            .expect_err("a corrupt stored identity must fail loud, never re-mint");
        assert!(err.contains("refusing to re-mint"), "got: {err}");
    }

    #[tokio::test]
    async fn first_provision_mints_roles_policies_and_persists_with_cas() {
        use wiremock::matchers::{body_partial_json, method, path, path_regex};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        // kv absent → the mint path runs.
        Mock::given(method("GET"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "errors": []
            })))
            .mount(&server)
            .await;
        // T1 migration ensure: both mounts; the 400 exercises the
        // already-mounted squash.
        for mount in ["ssh-client-signer", "ssh-host-signer"] {
            Mock::given(method("POST"))
                .and(path(format!("/v1/sys/mounts/{mount}")))
                .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                    "errors": ["path is already in use at ssh-client-signer/"]
                })))
                .expect(1)
                .mount(&server)
                .await;
            Mock::given(method("POST"))
                .and(path(format!("/v1/{mount}/config/ca")))
                .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                    "data": { "public_key": "ssh-ed25519 AAAA..." }
                })))
                .expect(1)
                .mount(&server)
                .await;
        }
        // Exact per-project roles, named by the (random) minted id.
        Mock::given(method("POST"))
            .and(path_regex(r"^/v1/ssh-client-signer/roles/[0-9a-v]{20}$"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/v1/ssh-host-signer/roles/host-[0-9a-v]{20}$"))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        // Both minted policies via sys/policies/acl (T2 — never a static file).
        Mock::given(method("POST"))
            .and(path_regex(
                r"^/v1/sys/policies/acl/ssh-lane-signer-[0-9a-v]{20}$",
            ))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(
                r"^/v1/sys/policies/acl/ssh-host-signer-[0-9a-v]{20}$",
            ))
            .respond_with(ResponseTemplate::new(204))
            .expect(1)
            .mount(&server)
            .await;
        // The commit marker is create-only: options.cas = 0 (D13 — written
        // ONCE), and it must be the LAST write.
        Mock::given(method("POST"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .and(body_partial_json(
                serde_json::json!({ "options": { "cas": 0 } }),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": { "version": 1 }
            })))
            .expect(1)
            .mount(&server)
            .await;

        let client = VaultClient::new(server.uri(), "root");
        let id = provision_mirror_identity(&client, "alpha", "10.0.42.0/24", false)
            .await
            .expect("first provision must mint and persist");
        assert!(
            mirror_id_is_valid(&id),
            "minted id fails its own grammar: {id}"
        );
        server.verify().await;
    }

    #[tokio::test]
    async fn losing_the_cas_race_adopts_the_winning_identity() {
        use wiremock::matchers::{method, path, path_regex};
        use wiremock::{Mock, MockServer, ResponseTemplate};
        let server = MockServer::start().await;
        // First read: absent (this process starts a mint). Second read,
        // after the cas conflict: the concurrent winner's identity.
        Mock::given(method("GET"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
                "errors": []
            })))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "data": {
                    "data": { "mirror_id": "vvvvvvvvvvvvvvvvvvvv", "project": "alpha" },
                    "metadata": { "version": 1 }
                }
            })))
            .mount(&server)
            .await;
        for pattern in [
            r"^/v1/sys/mounts/ssh-(client|host)-signer$",
            r"^/v1/ssh-(client|host)-signer/config/ca$",
            r"^/v1/ssh-client-signer/roles/[0-9a-v]{20}$",
            r"^/v1/ssh-host-signer/roles/host-[0-9a-v]{20}$",
            r"^/v1/sys/policies/acl/ssh-(lane|host)-signer-[0-9a-v]{20}$",
        ] {
            Mock::given(method("POST"))
                .and(path_regex(pattern))
                .respond_with(ResponseTemplate::new(204))
                .mount(&server)
                .await;
        }
        // The create-only write loses: Vault rejects a cas=0 write over an
        // existing version with 400 + a check-and-set error.
        Mock::given(method("POST"))
            .and(path("/v1/secret/data/mirror-identity/alpha"))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "errors": ["check-and-set parameter did not match the current version"]
            })))
            .mount(&server)
            .await;

        let client = VaultClient::new(server.uri(), "root");
        let id = provision_mirror_identity(&client, "alpha", "10.0.42.0/24", false)
            .await
            .expect("cas loser must adopt the winner, not error");
        assert_eq!(
            id, "vvvvvvvvvvvvvvvvvvvv",
            "two concurrent first-provisions must converge on ONE identity"
        );
    }

    #[test]
    fn vault_entrypoint_mounts_both_ssh_signer_engines_and_generates_cas() {
        // T1 boot half: the image entrypoint must ensure both SSH CA engines
        // and generate both in-Vault CAs, in the same idempotent
        // enable_endpoint style as approle/kv2/audit. (The host-side
        // provision_mirror_ssh_roles covers vaults initialized before this
        // shipped — the entrypoint only provisions on first boot.)
        let entrypoint = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../images/vault/entrypoint.sh"
        ));
        for needle in [
            "/v1/sys/mounts/ssh-client-signer",
            "/v1/sys/mounts/ssh-host-signer",
            "/v1/ssh-client-signer/config/ca",
            "/v1/ssh-host-signer/config/ca",
        ] {
            assert!(
                entrypoint.contains(needle),
                "images/vault/entrypoint.sh must ensure {needle} (606-bvnp T1)"
            );
        }
        assert!(
            entrypoint.contains("\"generate_signing_key\":true"),
            "the CA keypair must be generated INSIDE Vault (design D2)"
        );
        // The dynamic per-project artifacts must NOT be baked into the boot
        // path — roles are provision-time (amended T1).
        assert!(
            !entrypoint.contains("ssh-client-signer/roles/")
                && !entrypoint.contains("ssh-host-signer/roles/"),
            "per-project roles are created at mirror provision, never at boot"
        );
        assert!(
            !entrypoint.contains("sign/*"),
            "no sign/* wildcard may appear anywhere in the vault entrypoint"
        );
    }

    /// Order 1437-qza3: the partial-init wipe names the store, the missing
    /// share and the loss, so the one path that still destroys credentials is
    /// never silent.
    #[test]
    fn partial_init_wipe_line_names_store_share_and_loss() {
        let line = partial_init_wipe_line(std::path::Path::new("/c/tillandsias/vault-data"));
        assert!(line.contains("/c/tillandsias/vault-data"), "{line}");
        assert!(line.contains(VAULT_SHAMIR_SHARE_V1), "{line}");
        assert!(line.contains("every credential"), "{line}");
    }

    /// The line is printed unconditionally, not behind --debug: a source pin
    /// on the guard, since the branch needs a real store to reach.
    #[test]
    fn partial_init_wipe_line_is_not_debug_gated() {
        let src = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let start = src.find("if is_partial_init {").expect("guard");
        let guard = &src[start..start + 900];
        let print = guard
            .find("partial_init_wipe_line(&vault_dir)")
            .expect("the guard prints the line");
        let wipe = guard.find("remove_dir_all(vault_dir)").expect("the wipe");
        assert!(print < wipe, "announce before wiping");
        assert!(
            !guard[..print].contains("if debug"),
            "the wipe line must not be gated on --debug"
        );
    }

    /// Order 1437-qza3 aligned to 1443-bs9z: the keyring answer maps to
    /// exactly one named disposition, and each token and line is the spec's,
    /// verbatim. The tokens are an interface: this test fails on a respelling.
    #[test]
    fn reset_disposition_follows_the_keyring_ruling_and_spec_tokens() {
        use KeyringShare::*;
        use ResetVaultDisposition::*;
        assert_eq!(reset_vault_disposition(Present), VerifiedKeep);
        assert_eq!(reset_vault_disposition(Unreachable), UnverifiedKeep);
        assert_eq!(reset_vault_disposition(Absent), AbsentReinitAtInit);
        assert_eq!(VerifiedKeep.token(), "Verified:KEEP");
        assert_eq!(UnverifiedKeep.token(), "Unverified:KEEP");
        assert_eq!(AbsentReinitAtInit.token(), "Absent:REINIT-AT-INIT");
        for d in [VerifiedKeep, UnverifiedKeep, AbsentReinitAtInit] {
            assert!(d.announcement().starts_with("reset: "), "{d:?}");
            assert!(
                d.announcement().contains(d.token()) || d == AbsentReinitAtInit,
                "{d:?}"
            );
        }
        // The spec file carries each line verbatim, so a respelling on either
        // side fails here instead of drifting.
        let spec = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../openspec/specs/host-state-lifecycle/spec.md"
        ));
        let spec_flat = spec.split_whitespace().collect::<Vec<_>>().join(" ");
        for d in [VerifiedKeep, UnverifiedKeep, AbsentReinitAtInit] {
            let line = d
                .announcement()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            assert!(
                spec_flat.contains(&line),
                "not in the spec verbatim: {line}"
            );
        }
    }
}

// ── Order 1505-iysn: Cloudflare bundle + rotation (cloudflare_token_rotation_*) ──
//
// Every test here uses an in-memory store (no Vault) and either an injected
// refresh closure or the real `tillandsias-fake-cloudflare` over loopback (no
// real Cloudflare). The fake-driven tests are `#[ignore]`d so a plain
// `cargo test` needs no fake binary; scripts/test-cloudflare-token-rotation.sh
// builds the fake and runs them by name.
#[cfg(test)]
mod cloudflare_token_rotation_tests {
    use super::*;
    use std::collections::{BTreeMap, HashMap};
    use std::io::{BufRead, BufReader, Write as _};
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    const NOW: u64 = 1_000_000;
    const ACCOUNT: &str = "0123456789abcdef0123456789abcdef";
    const REDIRECT_URI: &str = "http://127.0.0.1:48631/tillandsias/cloudflare/callback";

    // ── the in-memory Vault seam ──────────────────────────────────────────

    /// Send + Sync fake Vault: records every write in order, can fail the
    /// next N writes of a path, can widen the read window, and counts every
    /// touch (the forge arm asserts zero).
    #[derive(Default)]
    struct MemStore {
        records: Mutex<BTreeMap<String, serde_json::Value>>,
        writes: Mutex<Vec<String>>,
        fail_next: Mutex<HashMap<String, u32>>,
        read_delay: Duration,
        touched: AtomicUsize,
    }

    impl MemStore {
        fn with(b: &CloudflareTokenBundle) -> Self {
            let s = MemStore::default();
            {
                let mut m = s.records.lock().unwrap();
                m.insert(CLOUDFLARE_TOKEN_PATH.into(), cloudflare_token_record(b));
                if let Some(r) = cloudflare_refresh_record(b) {
                    m.insert(CLOUDFLARE_REFRESH_PATH.into(), r);
                }
                m.insert(
                    "secret/cloudflare/mesh".into(),
                    serde_json::json!({ "client_id": "mesh-id", "team_name": "t" }),
                );
            }
            s
        }
        fn failing(self, path: &str, times: u32) -> Self {
            self.fail_next.lock().unwrap().insert(path.into(), times);
            self
        }
        fn delayed(mut self, d: Duration) -> Self {
            self.read_delay = d;
            self
        }
        fn snapshot(&self) -> BTreeMap<String, serde_json::Value> {
            self.records.lock().unwrap().clone()
        }
        fn writes(&self) -> Vec<String> {
            self.writes.lock().unwrap().clone()
        }
    }

    impl CloudflareTokenStore for MemStore {
        fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            let out = {
                let m = self.records.lock().unwrap();
                let Some(t) = m.get(CLOUDFLARE_TOKEN_PATH) else {
                    return Ok(None);
                };
                let r = m.get(CLOUDFLARE_REFRESH_PATH);
                CloudflareTokenBundle {
                    access_token: t["access_token"].as_str().unwrap_or_default().into(),
                    expires_at: t["expires_at"].as_u64(),
                    account_id: t["account_id"].as_str().map(String::from),
                    client_id: t["client_id"].as_str().unwrap_or_default().into(),
                    refresh_token: r
                        .and_then(|r| r["refresh_token"].as_str())
                        .map(String::from),
                    refresh_token_expires_at: r
                        .and_then(|r| r["refresh_token_expires_at"].as_u64()),
                }
            };
            std::thread::sleep(self.read_delay);
            Ok(Some(out))
        }
        fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            self.writes.lock().unwrap().push(path.into());
            let mut f = self.fail_next.lock().unwrap();
            if let Some(n) = f.get_mut(path)
                && *n > 0
            {
                *n -= 1;
                return Err("simulated-vault-write-failure".into());
            }
            self.records.lock().unwrap().insert(path.into(), value);
            Ok(())
        }
        fn delete_record(&self, path: &str) -> Result<(), String> {
            self.touched.fetch_add(1, Ordering::SeqCst);
            self.records.lock().unwrap().remove(path);
            Ok(())
        }
    }

    fn bundle(access: &str, refresh: &str, expires_at: u64) -> CloudflareTokenBundle {
        CloudflareTokenBundle {
            access_token: access.into(),
            expires_at: Some(expires_at),
            account_id: Some(ACCOUNT.into()),
            client_id: "fake-client".into(),
            refresh_token: Some(refresh.into()),
            refresh_token_expires_at: None,
        }
    }

    fn test_lock(tag: &str) -> String {
        format!("cf-rotation-test-{tag}-{}", std::process::id())
    }

    /// Every token string a test planted or the fake issued must be absent
    /// from `text`.
    fn assert_no_token_bytes(text: &str, tokens: &[&str]) {
        for t in tokens {
            assert!(t.len() >= 8, "probe token too short to mean anything: {t}");
            assert!(!text.contains(t), "token bytes leaked into output: {text}");
        }
    }

    // ── the real fake Cloudflare over loopback ────────────────────────────

    struct FakeServer {
        child: Child,
        base_url: String,
        ledger_path: PathBuf,
    }

    impl Drop for FakeServer {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn start_fake(name: &str) -> FakeServer {
        let bin = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../target/debug/tillandsias-fake-cloudflare")
            });
        assert!(
            bin.exists(),
            "fake-cloudflare binary not found at {bin:?}; run scripts/test-cloudflare-token-rotation.sh"
        );
        let dir =
            std::env::temp_dir().join(format!("cf-token-rotation-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("work dir");
        let ledger_path = dir.join("ledger.jsonl");
        let mut child = Command::new(&bin)
            .arg("--ledger")
            .arg(&ledger_path)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn fake-cloudflare");
        let mut line = String::new();
        BufReader::new(child.stdout.take().expect("stdout"))
            .read_line(&mut line)
            .expect("port line");
        let port: u16 = line.trim().parse().expect("fake printed a port");
        FakeServer {
            child,
            base_url: format!("http://127.0.0.1:{port}"),
            ledger_path,
        }
    }

    /// `grant_type=refresh_token` requests the fake received.
    fn refresh_exchanges(ledger: &Path) -> usize {
        std::fs::read_to_string(ledger)
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str::<serde_json::Value>(l).expect("ledger JSON"))
            .filter(|e| {
                e["path"]
                    .as_str()
                    .unwrap_or("")
                    .starts_with("/oauth2/token")
                    && e["body"]
                        .as_str()
                        .unwrap_or("")
                        .contains("grant_type=refresh_token")
            })
            .count()
    }

    /// The operator's click, test-only: GET the authorize URL with
    /// `auto=approve` and read the redirect's `Location` without following it.
    fn approve(authorize_url: &str) -> (String, String) {
        let url = format!("{authorize_url}&auto=approve");
        let rest = url.strip_prefix("http://").expect("http url");
        let (authority, path) = rest.split_once('/').expect("path");
        let mut s = std::net::TcpStream::connect(authority).expect("connect fake");
        write!(
            s,
            "GET /{path} HTTP/1.1\r\nHost: {authority}\r\nConnection: close\r\n\r\n"
        )
        .expect("write");
        let mut buf = String::new();
        s.read_to_string(&mut buf).expect("read");
        let loc = buf
            .lines()
            .find_map(|l| {
                l.strip_prefix("Location: ")
                    .or_else(|| l.strip_prefix("location: "))
            })
            .expect("Location header")
            .trim()
            .to_string();
        let q = loc
            .split_once('?')
            .map(|(_, q)| q)
            .unwrap_or("")
            .to_string();
        let get = |k: &str| {
            q.split('&')
                .find_map(|p| {
                    p.split_once('=')
                        .filter(|(kk, _)| *kk == k)
                        .map(|(_, v)| v.to_string())
                })
                .expect("query param")
        };
        (get("code"), get("state"))
    }

    /// A real pair issued by the fake, stored as a bundle expiring at `exp`.
    fn logged_in_bundle(server: &FakeServer, exp: u64) -> CloudflareTokenBundle {
        let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
        let pending = crate::cloudflare_oauth::begin(
            &http,
            &server.base_url,
            "fake-client",
            REDIRECT_URI,
            &[],
        )
        .expect("begin");
        let (code, state) = approve(&pending.authorize_url);
        let b =
            crate::cloudflare_oauth::exchange(&http, &pending, &state, &code).expect("exchange");
        CloudflareTokenBundle {
            access_token: b.access_token,
            expires_at: Some(exp),
            account_id: Some(ACCOUNT.into()),
            client_id: "fake-client".into(),
            refresh_token: b.refresh_token,
            refresh_token_expires_at: None,
        }
    }

    type RefreshFn<'a> = dyn Fn(&str, &str) -> Result<crate::cloudflare_oauth::Bundle, String> + 'a;

    /// The PRODUCTION refresh path (`perform_cloudflare_token_refresh`) aimed
    /// at the fake.
    fn fake_refresh(
        base: String,
    ) -> impl Fn(&str, &str) -> Result<crate::cloudflare_oauth::Bundle, String> {
        move |client_id, refresh_token| {
            perform_cloudflare_token_refresh(
                &crate::cloudflare_oauth::ReqwestHttpClient::default(),
                &base,
                client_id,
                refresh_token,
            )
        }
    }

    fn due_check(
        store: &dyn CloudflareTokenStore,
        refresh: &RefreshFn<'_>,
        forge: bool,
        lock: &str,
    ) -> Result<CloudflareDueCheck, String> {
        rotate_cloudflare_token_if_due(
            store,
            refresh,
            NOW,
            forge,
            lock,
            Duration::from_secs(20),
            false,
        )
    }

    // ── ARM 1: 20 min left -> exactly one exchange, refresh record first ──
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_due_token_rotates_once_refresh_first() {
        let server = start_fake("arm1");
        let old = logged_in_bundle(&server, NOW + 20 * 60);
        let store = MemStore::with(&old);
        let mesh_before = store.snapshot()["secret/cloudflare/mesh"].clone();
        assert_eq!(refresh_exchanges(&server.ledger_path), 0);
        let out = due_check(
            &store,
            &fake_refresh(server.base_url.clone()),
            false,
            &test_lock("arm1"),
        )
        .expect("a due token rotates");
        assert_eq!(
            refresh_exchanges(&server.ledger_path),
            1,
            "exactly one grant_type=refresh_token exchange at the fake"
        );
        assert_eq!(
            out,
            CloudflareDueCheck::Rotated {
                expires_at: Some(NOW + 3600)
            }
        );
        assert_eq!(
            store.writes(),
            vec![
                CLOUDFLARE_REFRESH_PATH.to_string(),
                CLOUDFLARE_TOKEN_PATH.to_string()
            ],
            "the refresh record is written first"
        );
        let new = store.read_bundle().unwrap().unwrap();
        assert_ne!(new.access_token, old.access_token);
        assert_ne!(new.refresh_token, old.refresh_token);
        assert!(
            new.expires_at.unwrap() > old.expires_at.unwrap(),
            "later expiry"
        );
        assert_eq!(new.account_id, old.account_id, "account_id carried over");
        assert_eq!(
            store.snapshot()["secret/cloudflare/mesh"],
            mesh_before,
            "rotation never touches the mesh credential"
        );
        assert!(
            store.snapshot()[CLOUDFLARE_TOKEN_PATH]
                .get("refresh_token")
                .is_none(),
            "the token record never carries the refresh token"
        );
    }

    // ── ARM 2: two concurrent due-checks -> ONE exchange at the fake ──────
    fn concurrent_run(
        tag: &str,
        shared_lock: bool,
    ) -> (usize, Vec<Result<CloudflareDueCheck, String>>) {
        let server = start_fake(tag);
        let store = std::sync::Arc::new(
            MemStore::with(&logged_in_bundle(&server, NOW + 60))
                .delayed(Duration::from_millis(300)),
        );
        let handles: Vec<_> = (0..2)
            .map(|i| {
                let store = std::sync::Arc::clone(&store);
                let base = server.base_url.clone();
                let lock = if shared_lock {
                    test_lock(tag)
                } else {
                    test_lock(&format!("{tag}-{i}"))
                };
                std::thread::spawn(move || due_check(&*store, &fake_refresh(base), false, &lock))
            })
            .collect();
        let outs = handles.into_iter().map(|h| h.join().unwrap()).collect();
        (refresh_exchanges(&server.ledger_path), outs)
    }

    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_concurrent_checks_exchange_once() {
        let (n, outs) = concurrent_run("arm2", true);
        assert_eq!(n, 1, "one lock -> exactly one exchange: {outs:?}");
        let rotated = outs
            .iter()
            .filter(|o| matches!(o, Ok(CloudflareDueCheck::Rotated { .. })))
            .count();
        let not_due = outs
            .iter()
            .filter(|o| matches!(o, Ok(CloudflareDueCheck::NotDue { .. })))
            .count();
        assert_eq!((rotated, not_due), (1, 1), "{outs:?}");
        // NEGATIVE CONTROL: without mutual exclusion (distinct lock names) the
        // same two checks both spend the refresh token, and the ledger count
        // sees it — the count discriminates, and the LOCK is what makes it one.
        let (n_ctl, outs_ctl) = concurrent_run("arm2ctl", false);
        assert_eq!(
            n_ctl, 2,
            "control: unserialised checks exchange twice: {outs_ctl:?}"
        );
    }

    // ── ARM 3: 2 h left -> no exchange, no write ─────────────────────────
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_not_due_makes_no_exchange() {
        let server = start_fake("arm3");
        let store = MemStore::with(&logged_in_bundle(&server, NOW + 2 * 3600));
        let before = store.snapshot();
        let out = due_check(
            &store,
            &fake_refresh(server.base_url.clone()),
            false,
            &test_lock("arm3"),
        )
        .unwrap();
        assert_eq!(
            out,
            CloudflareDueCheck::NotDue {
                expires_at: NOW + 2 * 3600
            }
        );
        assert_eq!(
            out.verdict(),
            format!(
                "ok:cloudflare-token-rotation:not-due:expires_at={}",
                NOW + 7200
            )
        );
        assert_eq!(refresh_exchanges(&server.ledger_path), 0);
        assert!(store.writes().is_empty());
        assert_eq!(store.snapshot(), before);
        // The window boundary: exactly 30 min left is due, 30 min + 1 s is not.
        assert!(cloudflare_token_rotation_due(NOW + 30 * 60, NOW));
        assert!(!cloudflare_token_rotation_due(NOW + 30 * 60 + 1, NOW));
    }

    // ── ARM 4: the fake refuses the refresh -> both old records intact ────
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_refused_refresh_keeps_both_records() {
        let server = start_fake("arm4");
        // A refresh token the fake never issued: it answers 400 invalid_grant.
        let old = bundle(
            "cf-access-OLD-0123456789",
            "cf-refresh-NEVER-ISSUED-0123456789",
            NOW + 60,
        );
        let store = MemStore::with(&old);
        let before = store.snapshot();
        let err = due_check(
            &store,
            &fake_refresh(server.base_url.clone()),
            false,
            &test_lock("arm4"),
        )
        .unwrap_err();
        assert_eq!(
            refresh_exchanges(&server.ledger_path),
            1,
            "the arm must REACH the fake's refusal, not fail before it"
        );
        assert!(
            err.starts_with(
                "cloudflare-token-rotation-failed:refresh-refused:http-400:invalid_grant"
            ),
            "{err}"
        );
        assert!(
            err.contains("remedy:") && err.contains("--cloudflare-login"),
            "{err}"
        );
        assert_eq!(
            store.snapshot(),
            before,
            "a refused exchange writes nothing"
        );
        assert!(store.writes().is_empty());
        assert_no_token_bytes(
            &format!("blocked:{err}"),
            &[
                "cf-access-OLD-0123456789",
                "cf-refresh-NEVER-ISSUED-0123456789",
            ],
        );
    }

    // ── ARM 5: a forge never rotates (and never touches store or fake) ───
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_forge_never_rotates() {
        let server = start_fake("arm5");
        let store = MemStore::with(&logged_in_bundle(&server, NOW + 60));
        let touched_after_setup = store.touched.load(Ordering::SeqCst);
        let out = due_check(
            &store,
            &fake_refresh(server.base_url.clone()),
            true,
            &test_lock("arm5f"),
        )
        .unwrap();
        assert_eq!(out, CloudflareDueCheck::RefusedInForge);
        assert_eq!(out.verdict(), "skip:cloudflare-token-rotation:forge");
        assert_eq!(
            store.touched.load(Ordering::SeqCst),
            touched_after_setup,
            "a forge never reads or writes Vault"
        );
        assert_eq!(refresh_exchanges(&server.ledger_path), 0);
        // CONTROL: the same due store on bare metal DOES rotate.
        let ok = due_check(
            &store,
            &fake_refresh(server.base_url.clone()),
            false,
            &test_lock("arm5b"),
        )
        .unwrap();
        assert!(matches!(ok, CloudflareDueCheck::Rotated { .. }), "{ok:?}");
        assert_eq!(refresh_exchanges(&server.ledger_path), 1);
        // TILLANDSIAS_HOST_KIND=forge is exactly what sets the flag live.
        assert!(host_kind_is_forge(Some("forge")));
        for other in [None, Some(""), Some("host"), Some("Forge"), Some("forge ")] {
            assert!(!host_kind_is_forge(other), "{other:?}");
        }
        let src = include_str!("vault_bootstrap.rs");
        let start = src
            .find(&["pub fn cloudflare_token_due_check_", "live("].concat())
            .unwrap();
        let body = &src[start..start + src[start..].find("\n}\n").unwrap()];
        assert!(
            body.contains(
                &[
                    "host_kind_is_forge(std::env::var(\"TILLANDSIAS_",
                    "HOST_KIND\")"
                ]
                .concat()
            ),
            "the live check derives the forge flag from TILLANDSIAS_HOST_KIND"
        );
        assert!(
            body.contains("        forge,\n"),
            "the live check passes the flag through"
        );
    }

    // ── Crash between the two writes: nothing is lost ────────────────────
    #[test]
    #[ignore = "drives tillandsias-fake-cloudflare; run via scripts/test-cloudflare-token-rotation.sh"]
    fn cloudflare_token_rotation_fake_crash_between_writes_loses_nothing() {
        let server = start_fake("crash");
        let old = logged_in_bundle(&server, NOW + 60);
        let store = MemStore::with(&old).failing(CLOUDFLARE_TOKEN_PATH, 1);
        let base = server.base_url.clone();
        let err = due_check(
            &store,
            &fake_refresh(base.clone()),
            false,
            &test_lock("crash1"),
        )
        .unwrap_err();
        assert!(
            err.starts_with("cloudflare-token-rotation-failed:token-record-write-failed:"),
            "{err}"
        );
        let mid = store
            .read_bundle()
            .unwrap()
            .expect("a bundle is still stored");
        assert_eq!(
            mid.access_token, old.access_token,
            "old access token still stored"
        );
        assert!(
            mid.refresh_token.is_some() && mid.refresh_token != old.refresh_token,
            "the NEW refresh token is persisted (the old one is spent at the fake)"
        );
        // The next check (Vault healthy again) recovers with the persisted
        // refresh token: the fake accepts it, which it would refuse had the
        // stored token been the spent one (arm 2's control shows that refusal).
        let ok =
            due_check(&store, &fake_refresh(base), false, &test_lock("crash2")).expect("recovers");
        assert!(matches!(ok, CloudflareDueCheck::Rotated { .. }), "{ok:?}");
        assert_eq!(refresh_exchanges(&server.ledger_path), 2);
        assert_no_token_bytes(
            &err,
            &[
                old.access_token.as_str(),
                old.refresh_token.as_deref().unwrap(),
                mid.refresh_token.as_deref().unwrap(),
            ],
        );
    }

    // ── non-ignored unit arms (no fake, no network) ───────────────────────

    /// No token bytes in Debug, verdicts or reasons. CONTROL: the substring
    /// check itself sees a leak when one is planted, so its silence below is
    /// not the silence of a check that cannot fire. (This control used to be
    /// the core `cloudflare_oauth::Bundle`'s DERIVED Debug, which printed the
    /// token; 1505-kc5f's prerequisite replaced it with a redacting impl, and
    /// the core Bundle is now asserted leak-free here too.)
    #[test]
    fn cloudflare_token_rotation_never_prints_a_token() {
        const A: &str = "cf-access-SECRET-abcdef012345";
        const R: &str = "cf-refresh-SECRET-abcdef012345";
        let b = bundle(A, R, NOW);
        let dbg = format!("{b:?} {b:#?}");
        assert_no_token_bytes(&dbg, &[A, R]);
        assert!(
            dbg.contains("<redacted>") && dbg.contains("fake-client"),
            "{dbg}"
        );
        let core = crate::cloudflare_oauth::Bundle {
            access_token: A.into(),
            refresh_token: Some(R.into()),
            expires_in: None,
            token_type: None,
        };
        assert_no_token_bytes(&format!("{core:?} {core:#?}"), &[A, R]);
        let planted = format!("a line that does carry {A}");
        assert!(
            std::panic::catch_unwind(|| assert_no_token_bytes(&planted, &[A])).is_err(),
            "control: the substring check must fire on a planted token"
        );
        // Hostile core errors: a serde type error quoting a token, a token in
        // the OAuth error field, a transport error naming a URL.
        let hostile = [
            (
                format!("refused:cloudflare-login:token-response-parse:invalid type: string `{R}`"),
                "refresh-response-unusable",
            ),
            (
                format!("refused:cloudflare-login:token-exchange-http-400:{R}"),
                "refresh-refused:http-400:unrecognised-error-code",
            ),
            (
                "refused:cloudflare-login:token-exchange-http-400:invalid_grant".to_string(),
                "refresh-refused:http-400:invalid_grant",
            ),
            (
                format!("cloudflare_oauth: POST https://x/?t={R}: timeout"),
                "refresh-transport",
            ),
        ];
        for (raw, want) in hostile {
            let r = cloudflare_refresh_failure_reason(&raw);
            assert_eq!(r, want);
            assert_no_token_bytes(&cloudflare_rotation_failure(&r), &[R]);
        }
        for v in [
            CloudflareDueCheck::Rotated {
                expires_at: Some(1),
            },
            CloudflareDueCheck::Rotated { expires_at: None },
            CloudflareDueCheck::NotDue { expires_at: 1 },
            CloudflareDueCheck::ExpiryUnknown,
            CloudflareDueCheck::NoToken,
            CloudflareDueCheck::NoRefreshToken,
            CloudflareDueCheck::RefusedInForge,
        ] {
            assert!(
                v.verdict().contains(":cloudflare-token-rotation:"),
                "{}",
                v.verdict()
            );
        }
    }

    /// The two records hold exactly the spec's fields; the token record never
    /// carries the refresh token; a bundle without `expires_at` is never
    /// rotated on a guess.
    #[test]
    fn cloudflare_token_rotation_records_keep_refresh_off_the_token_path() {
        assert_eq!(CLOUDFLARE_TOKEN_PATH, "secret/cloudflare/token");
        assert_eq!(CLOUDFLARE_REFRESH_PATH, "secret/cloudflare/refresh");
        let b = bundle("A-access-token-xyz", "R-refresh-token-xyz", 42);
        let t = cloudflare_token_record(&b);
        let keys: std::collections::BTreeSet<_> = t.as_object().unwrap().keys().cloned().collect();
        assert_eq!(
            keys.iter().map(String::as_str).collect::<Vec<_>>(),
            vec!["access_token", "account_id", "client_id", "expires_at"]
        );
        assert!(!t.to_string().contains("R-refresh-token-xyz"));
        let r = cloudflare_refresh_record(&b).unwrap();
        let keys: std::collections::BTreeSet<_> = r.as_object().unwrap().keys().cloned().collect();
        assert_eq!(
            keys.iter().map(String::as_str).collect::<Vec<_>>(),
            vec!["client_id", "refresh_token"]
        );
        let mut unknown = b.clone();
        unknown.expires_at = None;
        assert!(
            cloudflare_token_record(&unknown)
                .get("expires_at")
                .is_none()
        );
        let store = MemStore::with(&unknown);
        let out = due_check(
            &store,
            &|_, _| panic!("never refresh on a guessed expiry"),
            false,
            &test_lock("noexp"),
        )
        .unwrap();
        assert_eq!(out, CloudflareDueCheck::ExpiryUnknown);
        assert!(store.writes().is_empty());
    }

    /// The refresh-record write is retried, and when it keeps failing the old
    /// pair is intact and the verdict tells the operator the sign-in is spent.
    #[test]
    fn cloudflare_token_rotation_refresh_write_failure_keeps_old_pair() {
        let rotated = || crate::cloudflare_oauth::Bundle {
            access_token: "NEW-access-0123456789".into(),
            refresh_token: Some("NEW-refresh-0123456789".into()),
            expires_in: Some(3600),
            token_type: None,
        };
        // Transient: one failure, then success.
        let store = MemStore::with(&bundle(
            "OLD-access-0123456789",
            "OLD-refresh-0123456789",
            NOW + 60,
        ))
        .failing(CLOUDFLARE_REFRESH_PATH, 1);
        let ok = due_check(&store, &|_, _| Ok(rotated()), false, &test_lock("rw1")).unwrap();
        assert!(matches!(ok, CloudflareDueCheck::Rotated { .. }));
        assert_eq!(
            store.snapshot()[CLOUDFLARE_REFRESH_PATH]["refresh_token"],
            "NEW-refresh-0123456789"
        );
        // Persistent: every attempt fails -> nothing changed, never the token write.
        let store = MemStore::with(&bundle(
            "OLD-access-0123456789",
            "OLD-refresh-0123456789",
            NOW + 60,
        ))
        .failing(CLOUDFLARE_REFRESH_PATH, CLOUDFLARE_REFRESH_WRITE_ATTEMPTS);
        let before = store.snapshot();
        let err = due_check(&store, &|_, _| Ok(rotated()), false, &test_lock("rw2")).unwrap_err();
        assert!(
            err.starts_with("cloudflare-token-rotation-failed:refresh-record-write-failed:"),
            "{err}"
        );
        assert!(err.contains("--cloudflare-login"), "{err}");
        assert_eq!(store.snapshot(), before);
        assert!(!store.writes().contains(&CLOUDFLARE_TOKEN_PATH.to_string()));
        assert_no_token_bytes(
            &err,
            &[
                "NEW-refresh-0123456789",
                "OLD-refresh-0123456789",
                "NEW-access-0123456789",
            ],
        );
    }

    /// A discovery document naming a plain-http, non-loopback token endpoint
    /// is refused BEFORE the refresh token is sent anywhere.
    #[test]
    fn cloudflare_token_rotation_token_endpoint_must_be_https() {
        struct Http {
            token_endpoint: &'static str,
            posts: AtomicUsize,
        }
        impl crate::cloudflare_oauth::HttpClient for Http {
            fn get(&self, _: &str) -> Result<crate::cloudflare_oauth::HttpResponse, String> {
                Ok(crate::cloudflare_oauth::HttpResponse {
                    status: 200,
                    body: serde_json::json!({
                        "authorization_endpoint": "https://a/auth",
                        "token_endpoint": self.token_endpoint,
                    })
                    .to_string(),
                })
            }
            fn post_form(
                &self,
                _: &str,
                _: &[(&str, &str)],
            ) -> Result<crate::cloudflare_oauth::HttpResponse, String> {
                self.posts.fetch_add(1, Ordering::SeqCst);
                Ok(crate::cloudflare_oauth::HttpResponse {
                    status: 200,
                    body: r#"{"access_token":"n","expires_in":10}"#.into(),
                })
            }
        }
        for bad in [
            "http://evil.example/oauth2/token",
            "http://127.0.0.1@evil.example/t",
            "ftp://x/t",
        ] {
            let http = Http {
                token_endpoint: bad,
                posts: AtomicUsize::new(0),
            };
            let err = perform_cloudflare_token_refresh(&http, "https://dash", "c", "R-secret")
                .unwrap_err();
            assert_eq!(err, "token-endpoint-not-https", "{bad}");
            assert_eq!(
                http.posts.load(Ordering::SeqCst),
                0,
                "{bad}: the refresh token was sent"
            );
        }
        // CONTROL: https and loopback http do reach the POST.
        for good in [
            "https://dash.cloudflare.com/oauth2/token",
            "http://127.0.0.1:4000/oauth2/token",
            "http://localhost/t",
            "http://[::1]:9/t",
        ] {
            let http = Http {
                token_endpoint: good,
                posts: AtomicUsize::new(0),
            };
            perform_cloudflare_token_refresh(&http, "https://dash", "c", "R").expect(good);
            assert_eq!(http.posts.load(Ordering::SeqCst), 1, "{good}");
        }
    }

    /// One scheduler per process; the failure backoff is bounded.
    #[test]
    fn cloudflare_token_rotation_scheduler_once_and_backoff_bounded() {
        assert!(claim_cloudflare_rotation_scheduler_slot());
        assert!(!claim_cloudflare_rotation_scheduler_slot());
        let d1 = cloudflare_rotation_next_delay(true, Duration::ZERO);
        let d2 = cloudflare_rotation_next_delay(true, d1);
        assert_eq!(
            (d1, d2),
            (Duration::from_secs(60), Duration::from_secs(120))
        );
        assert_eq!(
            cloudflare_rotation_next_delay(true, Duration::from_secs(3600)),
            CLOUDFLARE_ROTATION_CHECK_EVERY
        );
        assert_eq!(
            cloudflare_rotation_next_delay(false, d2),
            CLOUDFLARE_ROTATION_CHECK_EVERY
        );
    }

    // ── Criterion 2: no forge policy grants anything under secret/data/cloudflare/ ──

    /// `(path pattern, capabilities)` per stanza; `#` comments dropped.
    fn stanzas(hcl: &str) -> Vec<(String, Vec<String>)> {
        let text: String = hcl
            .lines()
            .map(|l| l.split('#').next().unwrap_or(""))
            .collect::<Vec<_>>()
            .join("\n");
        let mut out = Vec::new();
        let mut rest = text.as_str();
        while let Some(i) = rest.find("path \"") {
            let after = &rest[i + 6..];
            let end = after.find('"').expect("closing quote");
            let pattern = after[..end].to_string();
            let body_start = after.find('{').expect("stanza body");
            let body_end = after[body_start..].find('}').expect("stanza end") + body_start;
            let body = &after[body_start..body_end];
            let caps = body
                .split_once('[')
                .and_then(|(_, r)| r.split_once(']'))
                .map(|(c, _)| {
                    c.split(',')
                        .map(|s| s.trim().trim_matches('"').to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_default();
            out.push((pattern, caps));
            rest = &after[body_end..];
        }
        out
    }

    /// Vault path-pattern match: `+` is one segment, a trailing `*` a prefix.
    fn pattern_matches(pattern: &str, path: &str) -> bool {
        let (pat, glob) = match pattern.strip_suffix('*') {
            Some(p) => (p, true),
            None => (pattern, false),
        };
        let ps: Vec<&str> = pat.split('/').collect();
        let xs: Vec<&str> = path.split('/').collect();
        if (!glob && ps.len() != xs.len()) || ps.len() > xs.len() {
            return false;
        }
        ps.iter().enumerate().all(|(i, p)| {
            if *p == "+" {
                true
            } else if glob && i == ps.len() - 1 {
                xs[i].starts_with(p)
            } else {
                *p == xs[i]
            }
        })
    }

    fn audit_policy_dir(dir: &Path) -> Vec<String> {
        const PROBES: &[&str] = &[
            "secret/data/cloudflare/token",
            "secret/data/cloudflare/refresh",
            "secret/data/cloudflare/mesh",
            "secret/data/cloudflare/anything",
            "secret/metadata/cloudflare/token",
            "secret/metadata/cloudflare/refresh",
        ];
        let mut violations = Vec::new();
        let mut files: Vec<_> = std::fs::read_dir(dir)
            .expect("policy dir")
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "hcl"))
            .collect();
        files.sort();
        assert!(
            files.len() >= 12,
            "population: expected every shipped policy, found {} in {dir:?}",
            files.len()
        );
        let mut saw_tray = false;
        let mut saw_mirror = false;
        for f in &files {
            let name = f.file_name().unwrap().to_string_lossy().to_string();
            let st = stanzas(&std::fs::read_to_string(f).unwrap());
            if name == "tray.hcl" {
                saw_tray = true;
                for need in [
                    "secret/data/cloudflare/token",
                    "secret/data/cloudflare/refresh",
                ] {
                    if !st
                        .iter()
                        .any(|(p, c)| pattern_matches(p, need) && c.iter().any(|c| c == "read"))
                    {
                        violations.push(format!("tray.hcl (host resident) cannot read {need}"));
                    }
                }
                continue;
            }
            if name == "git-mirror.hcl" {
                saw_mirror = true;
                let want = vec![
                    (
                        "secret/data/github/token".to_string(),
                        vec!["read".to_string()],
                    ),
                    (
                        "secret/metadata/github/token".to_string(),
                        vec!["read".to_string()],
                    ),
                ];
                if st != want {
                    violations.push(format!("git-mirror.hcl grants changed: {st:?}"));
                }
            }
            for probe in PROBES {
                for (p, caps) in &st {
                    if pattern_matches(p, probe) && caps.iter().any(|c| c != "deny") {
                        violations.push(format!(
                            "{name} grants {caps:?} on {probe} via path \"{p}\""
                        ));
                    }
                }
            }
        }
        if !saw_tray || !saw_mirror {
            violations.push("tray.hcl or git-mirror.hcl missing from the policy dir".into());
        }
        violations
    }

    #[test]
    fn cloudflare_token_rotation_policies_keep_forges_out() {
        // Test-only: the fixture's negative control points this at a mutated
        // COPY of the policy dir. Production never reads this variable.
        let dir = std::env::var("TILLANDSIAS_TEST_POLICY_AUDIT_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../images/vault/policies")
            });
        // The matcher itself, both ways.
        assert!(pattern_matches("secret/*", "secret/data/cloudflare/token"));
        assert!(pattern_matches(
            "secret/+/cloudflare/*",
            "secret/data/cloudflare/refresh"
        ));
        assert!(pattern_matches(
            "secret/data/cloud*",
            "secret/data/cloudflare/token"
        ));
        assert!(!pattern_matches(
            "secret/data/github/token",
            "secret/data/cloudflare/token"
        ));
        assert!(!pattern_matches(
            "secret/data/ca/proxy-cert",
            "secret/data/cloudflare/token"
        ));
        let v = audit_policy_dir(&dir);
        assert!(v.is_empty(), "policy violations:\n{}", v.join("\n"));
    }
}
