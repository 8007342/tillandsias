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
use std::time::Duration;

#[cfg(feature = "vault")]
use keyring::Entry;

use tillandsias_podman::{PodmanClient, podman_cmd_sync};
use tillandsias_vault_client::{HealthStatus, Policy, VaultClient, auto_unseal};
use zeroize::Zeroize;

const VAULT_CONTAINER_NAME: &str = "tillandsias-vault";
const VAULT_VOLUME: &str = "tillandsias-vault-data";
const VAULT_UNSEAL_SECRET: &str = "tillandsias-vault-unseal";
const VAULT_TLS_CERT_SECRET: &str = "tillandsias-vault-tls-cert";
const VAULT_TLS_KEY_SECRET: &str = "tillandsias-vault-tls-key";
const VAULT_TLS_CA_SECRET: &str = "tillandsias-vault-tls-ca";
const VAULT_NETWORK_ALIAS: &str = "vault";
const VAULT_API_BASE_URL_ENV: &str = "TILLANDSIAS_VAULT_API_BASE_URL";
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
fn vault_service_base_url() -> String {
    format!("https://{VAULT_NETWORK_ALIAS}:8200")
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
                if is_running_in_vm() {
                    vault_service_base_url()
                } else {
                    format!("https://127.0.0.1:{VAULT_HOST_PORT}")
                }
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

    let mut unseal_key = ensure_unseal_key(debug)?;
    create_unseal_secret(&unseal_key, debug)?;
    unseal_key.zeroize();
    launch_vault_container(&vault_image_tag, debug)?;

    let rt = tokio_runtime()?;
    let base_url = vault_api_base_url();
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

fn wait_for_vault_api_ready(
    rt: &tokio::runtime::Runtime,
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
/// - `VAULT_TOKEN`       — auth; forwarded via name-only `-e VAULT_TOKEN` so the
///   token rides in the podman process's environment and never appears in the
///   exec argv (i.e. not visible in `ps`)
///
/// Without these, `vault kv get` fails first with a TLS error and then a
/// missing-client-token error — which silently broke every host-side credential
/// read after the move from the HTTP Vault client to `podman exec`.
///
/// @trace spec:tillandsias-vault, plan/issues/vault-exec-env-regression-2026-06-27.md
fn vault_exec_command(root_token: &str, vault_args: &[&str]) -> std::process::Command {
    let mut cmd = podman_cmd_sync();
    // Token in the podman process env → forwarded by name-only `-e VAULT_TOKEN`,
    // so it stays out of argv.
    cmd.env("VAULT_TOKEN", root_token);
    cmd.args([
        "exec",
        "-e",
        &format!("VAULT_ADDR={VAULT_EXEC_ADDR}"),
        "-e",
        "VAULT_SKIP_VERIFY=true",
        "-e",
        "VAULT_TOKEN",
        VAULT_CONTAINER_NAME,
        "vault",
    ]);
    cmd.args(vault_args);
    cmd
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
#[allow(dead_code)]
pub(crate) fn is_github_key_present() -> bool {
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
    vault_exec_command(
        &root_token,
        &["kv", "get", "-field=token", "secret/github/token"],
    )
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::null())
    .status()
    .map(|s| s.success())
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
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err(format!("{VAULT_CONTAINER_NAME} is not running"));
    }
    // `podman exec` does not inherit the entrypoint env, so the `vault` CLI needs
    // VAULT_ADDR/TOKEN/skip-verify supplied explicitly (see vault_exec_command).
    let root_token = read_and_handover_root_token(debug)?;
    let field_arg = format!("-field={field}");
    let output = vault_exec_command(&root_token, &["kv", "get", &field_arg, secret_path])
        .output()
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
    pub fn env_var(self) -> &'static str {
        match self {
            ProviderId::Anthropic => "ANTHROPIC_API_KEY",
            ProviderId::Openai => "OPENAI_API_KEY",
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
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ─────────────────────────────────────────────────────────────────────────────

/// True iff the persistent Vault data volume exists. Cheap: a single
/// `podman volume exists` with no Vault bring-up, so it can gate the more
/// expensive on-demand launch in `is_github_key_present` and `ensure_vault_running`.
#[allow(dead_code)]
fn vault_data_volume_exists() -> bool {
    podman_cmd_sync()
        .args(["volume", "exists", VAULT_VOLUME])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
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
    if let Ok(cache_dir) = crate::init_cache_dir()
        && let Ok(encoded) =
            fs::read_to_string(cache_dir.join(format!("fallback_{}", VAULT_SHAMIR_SHARE_V1)))
    {
        return try_decode(encoded.trim());
    }
    false
}

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
    let base_url = vault_api_base_url();
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
        return None;
    }

    // Use the custom confined type only if we can CONFIRM it is loaded (or load
    // it — root only, i.e. inside the guest VM).
    if vault_container_type_loaded() {
        return Some("label=type:vault_container_t".to_string());
    }
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
        Command::new("semodule").arg("-i").arg(&cil_path).status(),
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

fn launch_vault_container(image_tag: &str, debug: bool) -> Result<(), String> {
    let image_tag = canonical_vault_launch_tag(image_tag)?;

    // Tear down any previous container with the same name (idempotent).
    let _ = podman_cmd_sync()
        .args(["rm", "-f", VAULT_CONTAINER_NAME])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output();

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
        if debug {
            eprintln!(
                "[tillandsias-vault] removing stale partial-init data volume \
                 (volume exists but no Shamir share in keychain)"
            );
        }
        let _ = podman_cmd_sync()
            .args(["volume", "rm", "-f", VAULT_VOLUME])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();
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
        eprintln!(
            "[tillandsias-vault] launching container {VAULT_CONTAINER_NAME} (alias {VAULT_NETWORK_ALIAS}:8200, publish 127.0.0.1:{VAULT_HOST_PORT}:8200)"
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
    let mut run_args: Vec<String> = vec![
        "run".into(),
        "-d".into(),
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
    run_args.extend([
        "--userns".into(),
        "keep-id".into(),
        "-p".into(),
        port_arg,
        image_tag.to_string(),
    ]);
    let status = podman_cmd_sync()
        .args(&run_args)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
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
        .output();
    if let Ok(out) = ps {
        let s = String::from_utf8_lossy(&out.stdout);
        let s = s.trim();
        if !s.is_empty() {
            eprintln!("[tillandsias-vault] container state: {s}");
        }
    }
    let logs = podman_cmd_sync()
        .args(["logs", "--tail", "40", VAULT_CONTAINER_NAME])
        .output();
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
    rt: &tokio::runtime::Runtime,
    base_url: &str,
    debug: bool,
) -> Result<String, String> {
    if debug {
        eprintln!("[tillandsias-vault] waiting for podman health status=healthy");
    }
    if let Err(e) = rt.block_on(PodmanClient::new().wait_healthy(VAULT_CONTAINER_NAME)) {
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
            read_and_handover_root_token(debug)
        }
        Err(e) => Err(format!("vault podman health is healthy but {e}")),
    }
}

/// Resolve the current vault container IP and update /etc/hosts so the
/// process-local hostname `vault` always points to it. The headless process
/// is not inside any podman network so aardvark-dns doesn't reach it; only
/// /etc/hosts does.
#[cfg(feature = "vault")]
fn update_etc_hosts_vault(debug: bool) {
    let out = match podman_cmd_sync()
        .args([
            "inspect",
            VAULT_CONTAINER_NAME,
            "--format",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}\n{{end}}",
        ])
        .output()
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
            .status();

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

pub(crate) fn container_running(name: &str) -> bool {
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

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    #[test]
    fn policy_role_names_match_spec() {
        assert_eq!(policy_role_name(&Policy::GitMirror), "git-mirror");
        assert_eq!(policy_role_name(&Policy::Forge), "forge");
        assert_eq!(policy_role_name(&Policy::Tray), "tray");
        assert_eq!(policy_role_name(&Policy::Inference), "inference");
        assert_eq!(policy_role_name(&Policy::GithubLogin), "github-login");
    }

    #[test]
    fn vault_exec_command_sets_required_env_and_hides_token() {
        // `podman exec` does not inherit the entrypoint env, so the exec'd vault
        // CLI must get VAULT_ADDR + VAULT_SKIP_VERIFY + VAULT_TOKEN or it fails
        // with a self-signed-cert TLS error and then a missing-token error. The
        // token must be forwarded by name only (-e VAULT_TOKEN) so it stays out
        // of argv. Regression guard for the HTTP→podman-exec credential-read move.
        // @trace plan/issues/vault-exec-env-regression-2026-06-27.md
        let cmd = vault_exec_command("super-secret-root-token", &["kv", "get", "secret/x"]);

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
        // Name-only passthrough: the literal "VAULT_TOKEN" appears, but the token
        // value must NOT be anywhere in argv.
        assert!(
            args.iter().any(|a| a == "VAULT_TOKEN"),
            "missing name-only -e VAULT_TOKEN; args={args:?}"
        );
        assert!(
            !args.iter().any(|a| a.contains("super-secret-root-token")),
            "token leaked into argv (visible in ps); args={args:?}"
        );

        // The token rides in the podman process environment instead.
        let token_in_env = cmd.get_envs().any(|(k, v)| {
            k == std::ffi::OsStr::new("VAULT_TOKEN")
                && v == Some(std::ffi::OsStr::new("super-secret-root-token"))
        });
        assert!(
            token_in_env,
            "token must be set in the process env, not argv"
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
        let _guard = ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap();
        unsafe {
            std::env::set_var(VAULT_API_BASE_URL_ENV, vault_service_base_url());
        }
        assert_eq!(vault_api_base_url(), vault_service_base_url());
        unsafe {
            std::env::remove_var(VAULT_API_BASE_URL_ENV);
        }
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
    }

    #[test]
    fn vault_ready_wait_uses_podman_health() {
        let source = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/vault_bootstrap.rs"
        ));
        let window = source
            .split("fn wait_for_vault_ready(")
            .nth(1)
            .expect("wait_for_vault_ready source");
        assert!(
            window.contains("PodmanClient::new().wait_healthy(VAULT_CONTAINER_NAME)"),
            "Vault readiness must use the idiomatic podman health layer"
        );
        assert!(
            !window.contains("thread::sleep"),
            "Vault readiness must not use a local polling sleep loop"
        );
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
