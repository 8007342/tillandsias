// @trace spec:tillandsias-vault
// @cheatsheet runtime/hashicorp-vault-tillandsias.md
//
//! Phase 3 vault bootstrap path, opt-in via `tillandsias --init --with-vault`.
//!
//! On a Linux desktop this short-circuits the in-VM lifecycle (which is
//! Phase 4/5 work) and runs the vault container directly under host-rootless
//! podman, treating the host as the "VM" for the POC. The host generates a
//! per-installation UUID, reads `/etc/machine-id`, derives the unseal key
//! via HKDF, pushes it as a podman secret, then launches the vault
//! container. After healthcheck, the existing GitHub token podman secret is
//! migrated into vault at `secret/github/token` and removed.
//!
//! IMPORTANT: this path does NOT replace the existing `create_github_podman_secret`
//! flow. It runs alongside as preview. Phase 6 will retire the keyring path.

use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
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
const VAULT_HOST_PORT: u16 = 8201;
const VAULT_USER_UID: u32 = 100;
const VAULT_GROUP_GID: u32 = 1000;

/// Public entry point. Invoked from `main.rs` after the standard
/// `run_init` completes when the user passes `--with-vault`.
pub fn run_with_vault_init(debug: bool) -> Result<(), String> {
    eprintln!("[tillandsias-vault] preview bootstrap starting (--with-vault)");

    // 1. Build the vault image.
    build_vault_image(debug)?;

    // 2. Compute or load the installation UUID.
    let installation_uuid = ensure_installation_uuid()?;
    if debug {
        eprintln!(
            "[tillandsias-vault] installation-uuid: {} (len={})",
            installation_uuid,
            installation_uuid.len()
        );
    }

    // 3. Read host machine-id.
    let machine_id = read_machine_id()?;

    // 4. Derive the unseal key.
    let mut unseal_key = auto_unseal::derive_unseal_key(machine_id.as_bytes(), installation_uuid.as_bytes());

    // 5. Create or replace the podman secret.
    create_unseal_secret(&unseal_key, debug)?;
    unseal_key.zeroize();

    // 6. Launch (or re-launch) the vault container.
    launch_vault_container(debug)?;

    // 7. Poll for healthy / unsealed.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("tokio runtime build failed: {e}"))?;

    let base_url = format!("http://127.0.0.1:{}", VAULT_HOST_PORT);
    let root_token = wait_for_vault_ready(&rt, &base_url, debug)?;

    let client = VaultClient::new(&base_url, &root_token);

    // 8. Migrate the existing github token (if present).
    if let Err(e) = rt.block_on(migrate_github_token(&client, debug)) {
        eprintln!("[tillandsias-vault] WARNING: github token migration skipped: {e}");
    }

    // 9. Final report.
    eprintln!("[tillandsias-vault] preview bootstrap complete");
    eprintln!(
        "[tillandsias-vault]   container : {VAULT_CONTAINER_NAME} (network alias: {VAULT_NETWORK_ALIAS})"
    );
    eprintln!("[tillandsias-vault]   policies : {:?}", Policy::all());
    eprintln!("[tillandsias-vault]   base_url : {base_url}");
    Ok(())
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

    // Fetch the root token from the running container — written by the
    // entrypoint to /vault/data/root.token at first boot.
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

async fn migrate_github_token(client: &VaultClient, debug: bool) -> Result<(), String> {
    // Read the existing podman secret content. Podman has no `secret read`
    // for the file driver, so we fall back to inspecting and reading from
    // the file driver's path. To stay portable, we instead exec a transient
    // alpine container that mounts the secret and prints it.
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
    // Verify round-trip before removing the old secret.
    let read_back = client
        .read_secret("secret/github/token")
        .await
        .map_err(|e| format!("vault read_secret: {e}"))?;
    if read_back["token"].as_str() != Some(token.as_str()) {
        return Err("vault read-back did not match written token".to_string());
    }
    // Remove the old podman secret only after a successful round trip.
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
