// @trace spec:tillandsias-vault, spec:secrets-management
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
//!
//! The legacy keyring path (`scripts/create-secrets.sh`,
//! `create_github_podman_secret`) is still reachable via
//! `tillandsias --legacy-keyring-secrets`. It will be removed in v0.3.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use tillandsias_vault_client::{Policy, VaultClient, auto_unseal};
use zeroize::Zeroize;

const VAULT_IMAGE_TAG: &str = "tillandsias-vault:latest";
const VAULT_CONTAINER_NAME: &str = "tillandsias-vault";
const VAULT_VOLUME: &str = "tillandsias-vault-data";
const VAULT_UNSEAL_SECRET: &str = "tillandsias-vault-unseal";
const VAULT_NETWORK_ALIAS: &str = "vault";
// Loopback port we publish for the host-process to reach vault during the
// POC (Linux host == VM). In Phase 4/5 the host shell will use vsock
// instead of publishing a port.
pub const VAULT_HOST_PORT: u16 = 8201;
const VAULT_USER_UID: u32 = 100;
const VAULT_GROUP_GID: u32 = 1000;

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
    format!("http://127.0.0.1:{VAULT_HOST_PORT}")
}

/// Public entry point: bring Vault up as part of the standard init flow.
///
/// Idempotent — skips work when the container is already running and
/// healthy. Called automatically from `run_init`; the previous `--with-vault`
/// opt-in is now a no-op.
pub fn ensure_vault_running(debug: bool) -> Result<(), String> {
    if container_running(VAULT_CONTAINER_NAME) {
        // Already up. Probe health to make sure it's serving.
        let rt = tokio_runtime()?;
        let base_url = host_base_url();
        let client = VaultClient::new(&base_url, "");
        match rt.block_on(client.health()) {
            Ok(h) if h.initialized && !h.sealed => {
                if debug {
                    eprintln!(
                        "[tillandsias-vault] container already running and unsealed (v={})",
                        h.version
                    );
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

    eprintln!("[tillandsias-vault] bootstrap starting (Phase 6 default)");

    build_vault_image(debug)?;
    let installation_uuid = ensure_installation_uuid()?;
    if debug {
        eprintln!(
            "[tillandsias-vault] installation-uuid: {} (len={})",
            installation_uuid,
            installation_uuid.len()
        );
    }
    let machine_id = read_machine_id()?;
    let mut unseal_key =
        auto_unseal::derive_unseal_key(machine_id.as_bytes(), installation_uuid.as_bytes());
    create_unseal_secret(&unseal_key, debug)?;
    unseal_key.zeroize();
    launch_vault_container(debug)?;

    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = wait_for_vault_ready(&rt, &base_url, debug)?;
    let client = VaultClient::new(&base_url, &root_token);

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
    ensure_vault_running(debug)?;
    // Best-effort migrate any pre-existing keyring podman secret into vault
    // so legacy installs keep working through the switchover.
    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = read_root_token()?;
    let client = VaultClient::new(&base_url, &root_token);
    if let Err(e) = rt.block_on(migrate_legacy_github_token(&client, debug))
        && debug
    {
        eprintln!("[tillandsias-vault] legacy migration skipped: {e}");
    }
    Ok(())
}

/// Write the GitHub token directly to Vault at `secret/github/token`.
///
/// Used by the new (Phase 6) `tillandsias --github-login` flow. Returns
/// `Err` if Vault is not running or the write fails.
pub fn write_github_token_to_vault(token: &str, debug: bool) -> Result<(), String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err(
            "Vault container is not running. Run `tillandsias --init` to bring it up, \
             or pass `--legacy-keyring-secrets` to fall back to the deprecated keyring flow."
                .into(),
        );
    }
    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = read_root_token()?;
    let client = VaultClient::new(&base_url, &root_token);

    if debug {
        eprintln!(
            "[tillandsias-vault] writing GitHub token ({} chars) to secret/github/token",
            token.len()
        );
    }
    rt.block_on(client.write_secret(
        "secret/github/token",
        serde_json::json!({ "token": token }),
    ))
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

/// Mint a fresh AppRole token for a container of the given `role` (e.g.
/// `"git-mirror"`). The returned `(token, secret_name)` is registered in
/// the in-process revocation registry so shutdown can revoke it. The
/// secret name embeds the container instance so concurrent containers
/// don't collide; the token bytes themselves are written into the named
/// podman secret as the value.
pub fn mint_approle_token_for_container(
    role: &str,
    container_instance: &str,
    debug: bool,
) -> Result<(String, String), String> {
    if !container_running(VAULT_CONTAINER_NAME) {
        return Err("Vault container is not running".into());
    }
    let rt = tokio_runtime()?;
    let base_url = host_base_url();
    let root_token = read_root_token()?;
    let client = VaultClient::new(&base_url, &root_token);
    let token = rt
        .block_on(client.issue_approle_token(role))
        .map_err(|e| format!("vault issue_approle_token failed: {e}"))?;

    let secret_name = format!("tillandsias-vault-token-{role}-{container_instance}");
    create_token_podman_secret(&secret_name, &token, debug)?;
    if let Ok(mut reg) = revocation_registry().lock() {
        reg.insert(secret_name.clone(), token.clone());
    }
    Ok((token, secret_name))
}

/// Drain and revoke every per-container token recorded in the in-process
/// registry. Also removes the matching podman secret so the on-disk
/// artifact (a short-lived random byte string) doesn't survive shutdown.
///
/// Best-effort: errors are logged and continued past so a partial failure
/// doesn't deadlock the shutdown path. The Vault container itself is
/// preserved on disk (matches the `tillandsias-vault-data` volume
/// contract).
pub fn revoke_pending_container_tokens(debug: bool) {
    let entries: Vec<(String, String)> = match revocation_registry().lock() {
        Ok(mut reg) => reg.drain().collect(),
        Err(_) => return,
    };
    if entries.is_empty() {
        return;
    }
    let rt = match tokio_runtime() {
        Ok(rt) => rt,
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] revoke: could not build tokio runtime: {e}; skipping"
                );
            }
            return;
        }
    };
    let base_url = host_base_url();
    let root_token = match read_root_token() {
        Ok(t) => t,
        Err(e) => {
            if debug {
                eprintln!(
                    "[tillandsias-vault] revoke: cannot read root token: {e}; skipping"
                );
            }
            return;
        }
    };
    let client = VaultClient::new(&base_url, &root_token);
    for (secret_name, token) in entries {
        if let Err(e) = rt.block_on(client.revoke_token(&token))
            && debug
        {
            eprintln!(
                "[tillandsias-vault] revoke {} failed: {e}",
                secret_name
            );
        }
        let _ = Command::new("podman")
            .args(["secret", "rm", &secret_name])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn build_vault_image(debug: bool) -> Result<(), String> {
    let script = repo_script("build-image.sh");
    if debug {
        eprintln!("[tillandsias-vault] running {} vault", script.display());
    }
    let status = Command::new(&script)
        .arg("vault")
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("failed to spawn {}: {e}", script.display()))?;
    if !status.success() {
        return Err(format!("build-image.sh vault exited with {}", status));
    }
    Ok(())
}

fn repo_script(name: &str) -> PathBuf {
    // The headless binary lives in <repo>/target/.../tillandsias. The build
    // hash detection in build-image.sh is git-aware, so we run from
    // CARGO_MANIFEST_DIR's grandparent (the repo root) via the absolute
    // path baked at build time.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.join("scripts").join(name))
        .unwrap_or_else(|| PathBuf::from(format!("scripts/{name}")))
}

fn ensure_installation_uuid() -> Result<String, String> {
    let cfg_dir = dirs::config_dir()
        .ok_or("no config dir")?
        .join("tillandsias");
    fs::create_dir_all(&cfg_dir).map_err(|e| format!("mkdir {cfg_dir:?}: {e}"))?;
    let uuid_path = cfg_dir.join("installation-uuid");
    if let Ok(existing) = fs::read_to_string(&uuid_path) {
        let trimmed = existing.trim().to_string();
        if !trimmed.is_empty() {
            return Ok(trimmed);
        }
    }
    // Generate a new UUIDv4 and write at mode 0600.
    let new_uuid = uuid::Uuid::new_v4().to_string();
    let mut f = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&uuid_path)
        .map_err(|e| format!("open {uuid_path:?}: {e}"))?;
    f.write_all(new_uuid.as_bytes())
        .map_err(|e| format!("write uuid: {e}"))?;
    let mut perm = fs::metadata(&uuid_path)
        .map_err(|e| format!("stat uuid: {e}"))?
        .permissions();
    perm.set_mode(0o600);
    fs::set_permissions(&uuid_path, perm).map_err(|e| format!("chmod uuid: {e}"))?;
    Ok(new_uuid)
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
    let _ = Command::new("podman")
        .args(["secret", "rm", VAULT_UNSEAL_SECRET])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if debug {
        eprintln!(
            "[tillandsias-vault] creating podman secret {VAULT_UNSEAL_SECRET} (32 bytes from HKDF)"
        );
    }
    let mut child = Command::new("podman")
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
    let _ = Command::new("podman")
        .args(["secret", "rm", name])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if debug {
        eprintln!("[tillandsias-vault] creating podman secret {name} ({} chars)", token.len());
    }
    let mut child = Command::new("podman")
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

fn launch_vault_container(debug: bool) -> Result<(), String> {
    // Tear down any previous container with the same name (idempotent).
    let _ = Command::new("podman")
        .args(["rm", "-f", VAULT_CONTAINER_NAME])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    if debug {
        eprintln!(
            "[tillandsias-vault] launching container {VAULT_CONTAINER_NAME} (publish 127.0.0.1:{VAULT_HOST_PORT}:8200)"
        );
    }

    let secret_arg = format!(
        "{},mode=0400,uid={},gid={}",
        VAULT_UNSEAL_SECRET, VAULT_USER_UID, VAULT_GROUP_GID
    );
    let volume_arg = format!("{}:/vault/data", VAULT_VOLUME);
    let port_arg = format!("127.0.0.1:{}:8200", VAULT_HOST_PORT);
    let status = Command::new("podman")
        .args([
            "run",
            "-d",
            "--name",
            VAULT_CONTAINER_NAME,
            "--hostname",
            VAULT_NETWORK_ALIAS,
            "--network-alias",
            VAULT_NETWORK_ALIAS,
            "--secret",
            &secret_arg,
            "--volume",
            &volume_arg,
            "--cap-add",
            "IPC_LOCK",
            "-p",
            &port_arg,
            VAULT_IMAGE_TAG,
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
    let deadline = Instant::now() + Duration::from_secs(60);
    let client = VaultClient::new(base_url, ""); // health doesn't need a token
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
            return Err("vault did not become healthy within 60s".to_string());
        }
        std::thread::sleep(Duration::from_secs(2));
    }
    read_root_token()
}

fn read_root_token() -> Result<String, String> {
    let out = Command::new("podman")
        .args([
            "exec",
            VAULT_CONTAINER_NAME,
            "cat",
            "/vault/data/root.token",
        ])
        .output()
        .map_err(|e| format!("podman exec root.token: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "could not read root token: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn container_running(name: &str) -> bool {
    let out = Command::new("podman")
        .args(["inspect", "--format", "{{.State.Running}}", name])
        .output();
    match out {
        Ok(o) if o.status.success() => {
            String::from_utf8_lossy(&o.stdout).trim() == "true"
        }
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
    }
}

/// Best-effort migration from the legacy `tillandsias-github-token` podman
/// secret into the new Vault path. Invoked when running `--with-vault`
/// (now deprecated) so older installs upgrade in place; not run as part
/// of the regular bootstrap.
#[allow(dead_code)]
async fn migrate_legacy_github_token(client: &VaultClient, debug: bool) -> Result<(), String> {
    let out = Command::new("podman")
        .args([
            "run",
            "--rm",
            "--secret",
            "tillandsias-github-token,mode=0400",
            "docker.io/library/alpine:3.20",
            "sh",
            "-c",
            "cat /run/secrets/tillandsias-github-token 2>/dev/null || true",
        ])
        .output()
        .map_err(|e| format!("read existing token: {e}"))?;
    let token_bytes = out.stdout;
    let token = String::from_utf8_lossy(&token_bytes).trim().to_string();
    if token.is_empty() {
        return Err("tillandsias-github-token secret is empty or missing".to_string());
    }
    if debug {
        eprintln!(
            "[tillandsias-vault] migrating github token ({} chars) into vault at secret/github/token",
            token.len()
        );
    }
    client
        .write_secret(
            "secret/github/token",
            serde_json::json!({ "token": token }),
        )
        .await
        .map_err(|e| format!("vault write_secret: {e}"))?;
    let read_back = client
        .read_secret("secret/github/token")
        .await
        .map_err(|e| format!("vault read_secret: {e}"))?;
    if read_back["token"].as_str() != Some(token.as_str()) {
        return Err("vault read-back did not match written token".to_string());
    }
    let _ = Command::new("podman")
        .args(["secret", "rm", "tillandsias-github-token"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    eprintln!(
        "[tillandsias-vault] github token migrated to vault (old podman secret removed)"
    );
    Ok(())
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
    }

    #[test]
    fn host_base_url_targets_loopback() {
        let url = host_base_url();
        assert!(url.starts_with("http://127.0.0.1:"), "got {url}");
        assert!(url.ends_with(&VAULT_HOST_PORT.to_string()));
    }

    #[test]
    fn approle_ttl_constants_match_spec() {
        // tillandsias-vault.invariant.token-ttl-1h
        assert_eq!(APPROLE_TOKEN_TTL_SECS, 3_600);
        // 24h ceiling matches the spec's max_ttl guidance.
        assert_eq!(APPROLE_TOKEN_MAX_TTL_SECS, 86_400);
    }
}
