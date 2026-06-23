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
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(feature = "vault")]
use keyring::Entry;

use tillandsias_podman::podman_cmd_sync;
use tillandsias_vault_client::{Policy, VaultClient, auto_unseal};
use zeroize::Zeroize;

const VAULT_CONTAINER_NAME: &str = "tillandsias-vault";
const VAULT_VOLUME: &str = "tillandsias-vault-data";
const VAULT_UNSEAL_SECRET: &str = "tillandsias-vault-unseal";
const VAULT_TLS_CERT_SECRET: &str = "tillandsias-vault-tls-cert";
const VAULT_TLS_KEY_SECRET: &str = "tillandsias-vault-tls-key";
const VAULT_TLS_CA_SECRET: &str = "tillandsias-vault-tls-ca";
const VAULT_NETWORK_ALIAS: &str = "vault";
// Loopback port we publish for the host-process to reach vault during the
// POC (Linux host == VM). In Phase 4/5 the host shell will use vsock
// instead of publishing a port.
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

#[cfg(feature = "vault")]
#[allow(dead_code)]
pub fn set_in_vm_credentials(
    unseal_share_b64: Option<String>,
    installation_uuid: String,
    root_token: Option<String>,
) {
    let cell = IN_VM_CREDENTIALS.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cell.lock() {
        *guard = Some(InVmCredentials {
            unseal_share_b64,
            installation_uuid,
            root_token,
        });
    }
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

#[cfg(feature = "vault")]
#[allow(dead_code)]
pub fn clear_pending_handover() {
    let cell = PENDING_HANDOVER.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = cell.lock() {
        *guard = None;
    }
}

#[cfg(feature = "vault")]
pub fn is_running_in_vm() -> bool {
    if let Some(cell) = IN_VM_CREDENTIALS.get()
        && let Ok(guard) = cell.lock()
    {
        return guard.is_some();
    }
    false
}

#[cfg(not(feature = "vault"))]
pub fn set_in_vm_credentials(
    _unseal_share_b64: Option<String>,
    _installation_uuid: String,
    _root_token: Option<String>,
) {
}

#[cfg(not(feature = "vault"))]
pub fn get_pending_handover() -> (Option<String>, Option<String>) {
    (None, None)
}

#[cfg(not(feature = "vault"))]
pub fn clear_pending_handover() {}

#[cfg(not(feature = "vault"))]
pub fn is_running_in_vm() -> bool {
    false
}

/// Default token TTL for per-container AppRole tokens (1h).
pub const APPROLE_TOKEN_TTL_SECS: u64 = 3_600;
/// Hard upper bound on a renewed AppRole token (24h).
pub const APPROLE_TOKEN_MAX_TTL_SECS: u64 = 86_400;

/// Process-wide registry of per-container vault tokens that should be
/// revoked on shutdown. The tray installs entries here when minting a token
/// for a container launch; `revoke_pending_container_tokens` drains the
/// registry, calling `vault token revoke` on each entry.
fn revocation_registry() -> &'static Mutex<HashMap<String, String>> {
    static REG: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Default base URL the Linux tray uses to talk to the local Vault container.
pub fn host_base_url() -> String {
    format!("https://127.0.0.1:{VAULT_HOST_PORT}")
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
        .args([
            "-subj",
            "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=vault",
            "-addext",
            "subjectAltName=DNS:vault,DNS:localhost,IP:127.0.0.1",
        ])
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
    let certs_dir = tls_material_dir(debug)?;
    ensure_vault_tls_leaf(&certs_dir, debug)?;

    if container_running(VAULT_CONTAINER_NAME) {
        // Already up. Probe health to make sure it's serving.
        let rt = tokio_runtime()?;
        let base_url = host_base_url();
        let client = vault_client(&base_url, "", debug)?;
        match rt.block_on(client.health()) {
            Ok(h) if h.initialized && !h.sealed => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] container already running and unsealed (v={})",
                        h.version
                    );
                }
                let root_token = read_and_handover_root_token(debug)?;
                let client = vault_client(&base_url, &root_token, debug)?;
                if rt
                    .block_on(client.approle_role_exists("git-mirror"))
                    .unwrap_or(false)
                {
                    if debug {
                        eprintln!(
                            "[tillandsias-vault] AppRole 'git-mirror' already exists; skipping policy and role provisioning"
                        );
                    }
                } else {
                    rt.block_on(load_policies(&client, debug))?;
                    rt.block_on(provision_approle_roles(&client, debug))?;
                }
                return Ok(());
            }
            other => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] container present but health probe returned {other:?}; relaunching"
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

    let mut unseal_key = ensure_unseal_key(debug)?;
    create_unseal_secret(&unseal_key, debug)?;
    unseal_key.zeroize();
    launch_vault_container(&vault_image_tag, debug)?;

    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = wait_for_vault_ready(&rt, &base_url, debug)?;
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
    let rt = tokio_runtime()?;
    let base_url = host_base_url();
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

/// Tray-facing source of truth for "is the user logged in to GitHub?".
///
/// Returns `true` iff a non-empty token is currently retrievable from Vault
/// at `secret/github/token`. This replaces the legacy host-side
/// `gh auth status` probe, which read the host keyring rather than Vault and
/// therefore diverged from where the login flow actually stores the token.
///
/// Honors the "no Vault running at launch" model: if the Vault data volume
/// has never been created the user has never logged in, so we answer `false`
/// immediately without paying to bring Vault up. Only when a prior login left
/// a data volume behind do we ensure Vault is running on demand (idiomatic
/// podman) and read the token back.
///
/// @trace spec:tillandsias-vault, spec:tray-minimal-ux
#[allow(dead_code)]
pub fn is_github_logged_in(debug: bool) -> bool {
    if !vault_data_volume_exists() {
        if debug {
            eprintln!(
                "[tillandsias-vault] is_logged_in: no `{VAULT_VOLUME}` volume; user has never logged in"
            );
        }
        return false;
    }
    if let Err(e) = ensure_vault_running(debug) {
        if debug {
            eprintln!("[tillandsias-vault] is_logged_in: ensure_vault_running failed: {e}");
        }
        return false;
    }
    match read_github_token_from_vault(debug) {
        Ok(token) => !token.trim().is_empty(),
        Err(e) => {
            if debug {
                eprintln!("[tillandsias-vault] is_logged_in: token read failed: {e}");
            }
            false
        }
    }
}

/// Read the GitHub token back from Vault at `secret/github/token`. Returns the
/// raw token (empty string if the key is absent); errs if Vault is not running
/// or the read fails. Mirrors the read-back in `write_github_token_to_vault`.
#[allow(dead_code)]
pub(crate) fn read_github_token_from_vault(debug: bool) -> Result<String, String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("vault container is not running".into());
    }
    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = read_and_handover_root_token(debug)?;
    let client = vault_client(&base_url, &root_token, debug)?;
    let data = rt
        .block_on(client.read_secret("secret/github/token"))
        .map_err(|e| format!("vault read_secret failed: {e}"))?;
    Ok(data["token"].as_str().unwrap_or("").to_string())
}

/// True iff the persistent Vault data volume exists. Cheap: a single
/// `podman volume exists` with no Vault bring-up, so it can gate the more
/// expensive on-demand launch in [`is_github_logged_in`].
#[allow(dead_code)]
fn vault_data_volume_exists() -> bool {
    podman_cmd_sync()
        .args(["volume", "exists", VAULT_VOLUME])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
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
    let base_url = host_base_url();
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
            .status();
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
/// preserved on disk (matches the `tillandsias-vault-data` volume
/// contract).
pub async fn revoke_pending_container_tokens(debug: bool) {
    let entries: Vec<(String, String)> = match revocation_registry().lock() {
        Ok(mut reg) => reg.drain().collect(),
        Err(_) => return,
    };
    if entries.is_empty() {
        return;
    }
    let base_url = host_base_url();
    let root_token = match read_and_handover_root_token(debug) {
        Ok(t) => t,
        Err(e) => {
            if debug {
                eprintln!("[tillandsias-vault] revoke: cannot read root token: {e}; skipping");
            }
            return;
        }
    };
    let client = match vault_client(&base_url, &root_token, debug) {
        Ok(client) => client,
        Err(e) => {
            if debug {
                eprintln!("[tillandsias-vault] revoke: cannot build TLS client: {e}; skipping");
            }
            return;
        }
    };
    for (secret_name, token) in entries {
        if let Err(e) = client.revoke_token(&token).await
            && debug
        {
            eprintln!("[tillandsias-vault] revoke {} failed: {e}", secret_name);
        }
        let _ = podman_cmd_sync()
            .args(["secret", "rm", &secret_name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
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

    if debug {
        eprintln!(
            "[tillandsias-vault] building image vault with tag {}",
            identity.canonical_tag
        );
    }

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
        // 2. Not in host credentials (first boot). Return derived dummy key from delivered installation_uuid.
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
    // Best-effort remove any prior secret.
    // @trace spec:ephemeral-secret-refresh
    let _ = podman_cmd_sync()
        .args(["secret", "rm", VAULT_UNSEAL_SECRET])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if debug {
        eprintln!(
            "[tillandsias-vault] creating podman secret {VAULT_UNSEAL_SECRET} (32 bytes from HKDF)"
        );
    }
    let mut child = podman_cmd_sync()
        .args([
            "secret",
            "create",
            "--driver=file",
            VAULT_UNSEAL_SECRET,
            "-",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn podman secret create: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or("no stdin")?
        .write_all(key)
        .map_err(|e| format!("write key bytes: {e}"))?;
    drop(child.stdin.take());
    let out = child
        .wait_with_output()
        .map_err(|e| format!("wait podman secret create: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "podman secret create failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

/// Create (or replace) a podman secret holding the supplied token bytes.
/// Mode `0400`, file driver. Used for per-container AppRole tokens.
fn create_token_podman_secret(name: &str, token: &str, debug: bool) -> Result<(), String> {
    // @trace spec:ephemeral-secret-refresh
    let _ = podman_cmd_sync()
        .args(["secret", "rm", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if debug {
        eprintln!(
            "[tillandsias-vault] creating podman secret {name} ({} chars)",
            token.len()
        );
    }
    let mut child = podman_cmd_sync()
        .args(["secret", "create", "--driver=file", name, "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn podman secret create: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or("no stdin")?
        .write_all(token.as_bytes())
        .map_err(|e| format!("write token bytes: {e}"))?;
    drop(child.stdin.take());
    let out = child
        .wait_with_output()
        .map_err(|e| format!("wait podman secret create: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "podman secret create {name} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

fn create_file_podman_secret(
    name: &str,
    path: &std::path::Path,
    debug: bool,
) -> Result<(), String> {
    let contents =
        fs::read(path).map_err(|e| format!("read podman secret source {}: {e}", path.display()))?;
    let _ = podman_cmd_sync()
        .args(["secret", "rm", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if debug {
        eprintln!(
            "[tillandsias-vault] refreshing podman secret {name} from {}",
            path.display()
        );
    }
    let mut child = podman_cmd_sync()
        .args(["secret", "create", "--driver=file", name, "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn podman secret create {name}: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or("no stdin")?
        .write_all(&contents)
        .map_err(|e| format!("write podman secret {name}: {e}"))?;
    drop(child.stdin.take());
    let out = child
        .wait_with_output()
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

fn launch_vault_container(image_tag: &str, debug: bool) -> Result<(), String> {
    let image_tag = canonical_vault_launch_tag(image_tag)?;

    // Tear down any previous container with the same name (idempotent).
    let _ = podman_cmd_sync()
        .args(["rm", "-f", VAULT_CONTAINER_NAME])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    // Vault must join the enclave bridge network so (a) `--network-alias vault`
    // is valid — rootless podman's DEFAULT network is pasta/slirp4netns, not
    // bridge, and aliases/static-ip are bridge-only ("networks and static
    // ip/mac address can only be used with Bridge mode networking"); and
    // (b) enclave containers can reach Vault by its alias. Idempotent — short-
    // circuits when the network already exists (it normally does, created
    // during `run_init`, but ensure here so the bootstrap is self-sufficient).
    crate::ensure_enclave_network(debug)?;

    if debug {
        eprintln!(
            "[tillandsias-vault] launching container {VAULT_CONTAINER_NAME} (publish 127.0.0.1:{VAULT_HOST_PORT}:8200)"
        );
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
    let volume_arg = format!("{}:/vault/data:U", VAULT_VOLUME);
    let port_arg = format!("127.0.0.1:{}:8200", VAULT_HOST_PORT);
    let status = podman_cmd_sync()
        .args([
            "run",
            "-d",
            "--name",
            VAULT_CONTAINER_NAME,
            "--hostname",
            VAULT_NETWORK_ALIAS,
            // Bridge network for the alias + enclave reachability (see
            // launch_vault_container preamble). Must precede --network-alias.
            "--network",
            crate::ENCLAVE_NET,
            "--network-alias",
            VAULT_NETWORK_ALIAS,
            "--secret",
            &secret_arg,
            "--secret",
            &tls_cert_arg,
            "--secret",
            &tls_key_arg,
            "--secret",
            &tls_ca_arg,
            "--volume",
            &volume_arg,
            "--tmpfs",
            "/run/vault-handover:size=1m,mode=0777",
            "--rm",
            "--cap-drop",
            "ALL",
            "--cap-add",
            "IPC_LOCK",
            "--security-opt",
            "no-new-privileges",
            "--security-opt",
            "label=disable",
            "--userns",
            "keep-id",
            "-p",
            &port_arg,
            image_tag,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| format!("spawn podman run: {e}"))?;
    if !status.success() {
        return Err(format!("podman run vault failed: {}", status));
    }
    Ok(())
}

fn wait_for_vault_ready(
    rt: &tokio::runtime::Runtime,
    base_url: &str,
    debug: bool,
) -> Result<String, String> {
    // 180s: native Linux resolves in ~1s; macOS VZ 4 GiB guests under cold
    // first-init resource pressure (concurrent forge image pulls + vault init)
    // can exceed 120s (order 81). WSL2 also benefits from extra headroom.
    let deadline = Instant::now() + Duration::from_secs(180);
    let client = vault_client(base_url, "", debug)?; // health doesn't need a token
    loop {
        match rt.block_on(client.health()) {
            Ok(h) if h.initialized && !h.sealed => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] vault healthy (initialized={} sealed={} v={})",
                        h.initialized, h.sealed, h.version
                    );
                }
                break;
            }
            Ok(h) if debug => eprintln!(
                "[tillandsias-vault] waiting (initialized={} sealed={})",
                h.initialized, h.sealed
            ),
            Err(e) if debug => eprintln!("[tillandsias-vault] health probe error: {e}"),
            _ => {}
        }
        if Instant::now() > deadline {
            return Err("vault did not become healthy within 180s".to_string());
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    read_and_handover_root_token(debug)
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
        .output()
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
                "[tillandsias-vault] WARNING: failed to write {user} to OS keyring ({e}); writing to fallback file"
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
        if debug {
            eprintln!(
                "[tillandsias-vault] fresh-init handover present; capturing root token + Shamir share into keychain (overwriting any stale entries)"
            );
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
                    unseal_share_b64: Some(share_b64),
                    root_token: Some(token.clone()),
                });
            }
        } else {
            keychain_set_blocking("vault-root-token-v1", &token)?;
            keychain_set_blocking(VAULT_SHAMIR_SHARE_V1, &share_b64)?;
        }

        // @trace spec:tillandsias-vault — Secure Artifact Cleanup
        // Delete the handover files from tmpfs immediately. Remove the files
        // (not the mount dir) so the unprivileged exec user can't trip on the
        // root-owned tmpfs mount point.
        let _ = podman_cmd_sync()
            .args([
                "exec",
                VAULT_CONTAINER_NAME,
                "rm",
                "-f",
                "/run/vault-handover/root.token",
                "/run/vault-handover/unseal.key",
            ])
            .status();

        if debug {
            eprintln!(
                "[tillandsias-vault] root token + Shamir share handover complete (deleted from tmpfs)"
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
         keychain has no root token or fallback — the keychain and the data volume are out of \
         sync. Reset with `podman volume rm tillandsias-vault-data` and re-run \
         `tillandsias --init` to re-bootstrap."
            .to_string(),
    )
}

#[cfg(not(feature = "vault"))]
fn read_and_handover_root_token(_debug: bool) -> Result<String, String> {
    Err("vault feature not compiled".into())
}

fn container_running(name: &str) -> bool {
    let out = podman_cmd_sync()
        .args(["inspect", "--format", "{{.State.Running}}", name])
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim() == "true",
        _ => false,
    }
}

fn tokio_runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime build failed: {e}"))
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
/// 30s, so a stolen secret-id is worthless past container launch.
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn policy_role_names_match_spec() {
        assert_eq!(policy_role_name(&Policy::GitMirror), "git-mirror");
        assert_eq!(policy_role_name(&Policy::Forge), "forge");
        assert_eq!(policy_role_name(&Policy::Tray), "tray");
        assert_eq!(policy_role_name(&Policy::Inference), "inference");
        assert_eq!(policy_role_name(&Policy::GithubLogin), "github-login");
    }

    #[test]
    fn host_base_url_targets_loopback() {
        let url = host_base_url();
        assert!(url.starts_with("https://127.0.0.1:"), "got {url}");
        assert!(url.ends_with(&VAULT_HOST_PORT.to_string()));
    }

    #[test]
    fn approle_ttl_constants_match_spec() {
        // tillandsias-vault.invariant.token-ttl-1h
        assert_eq!(APPROLE_TOKEN_TTL_SECS, 3_600);
        // 24h ceiling matches the spec's max_ttl guidance.
        assert_eq!(APPROLE_TOKEN_MAX_TTL_SECS, 86_400);
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
}
