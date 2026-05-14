// Tests for scripts/generate-repo-key.sh deploy mode.
// @trace spec:gh-auth-script, spec:secrets-management, spec:native-secrets-store

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root")
        .to_path_buf()
}

fn ssh_keygen_available() -> bool {
    Command::new("ssh-keygen")
        .arg("-h")
        .output()
        .map(|_| true)
        .unwrap_or(false)
}

/// Run the script in dry-run mode and assert it does not write anything.
#[test]
fn deploy_mode_dry_run_is_noop() {
    if !ssh_keygen_available() {
        eprintln!("skipping: ssh-keygen not available");
        return;
    }
    let tmp = TempDir::new().expect("tempdir");
    let project_dir = tmp.path().join("demo");
    fs::create_dir_all(&project_dir).expect("mkdir");

    let root = repo_root();
    let script = root.join("scripts/generate-repo-key.sh");
    assert!(script.exists(), "script must exist at {}", script.display());

    let output = Command::new("bash")
        .arg(&script)
        .arg("--mode=deploy")
        .arg("--dry-run")
        .arg("--project=demo")
        .current_dir(&project_dir)
        .output()
        .expect("run script");

    assert!(
        output.status.success(),
        "dry-run should succeed; stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );

    // No config file written
    assert!(
        !project_dir.join(".tillandsias/config.toml").exists(),
        "dry-run must not write .tillandsias/config.toml"
    );
}

/// End-to-end: generate the key, store via fake secret-tool, verify config.
#[test]
fn deploy_mode_generates_key_and_writes_config() {
    if !ssh_keygen_available() {
        eprintln!("skipping: ssh-keygen not available");
        return;
    }

    let tmp = TempDir::new().expect("tempdir");
    let project_dir = tmp.path().join("demo");
    fs::create_dir_all(&project_dir).expect("mkdir");

    let root = repo_root();
    let script = root.join("scripts/generate-repo-key.sh");
    let fake = root.join("scripts/test-support/secret-tool-fake.sh");
    assert!(fake.exists(), "fake secret-tool helper must exist");

    // Build a PATH shim so the script picks up our fake secret-tool first.
    let bin = tmp.path().join("bin");
    fs::create_dir_all(&bin).expect("mkdir bin");
    let shim = bin.join("secret-tool");
    fs::copy(&fake, &shim).expect("copy fake");
    // (no chmod needed: bash invokes via #! and the script is rx in repo)

    let keystore = tmp.path().join("keystore");
    let path_env = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());

    let output = Command::new("bash")
        .arg(&script)
        .arg("--mode=deploy")
        .arg("--project=demo")
        .current_dir(&project_dir)
        .env("PATH", &path_env)
        .env("LITMUS_SECRET_TOOL_STORE", keystore.display().to_string())
        .output()
        .expect("run script");

    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    assert!(
        output.status.success(),
        "deploy mode should succeed; stderr={}\nstdout={}",
        stderr,
        stdout
    );

    // The config file landed and contains the fingerprint + keyring pointer.
    let config_path = project_dir.join(".tillandsias/config.toml");
    assert!(config_path.exists(), ".tillandsias/config.toml not created");
    let config = fs::read_to_string(&config_path).expect("read config");
    assert!(
        config.contains("[deploy_key]"),
        "config must contain [deploy_key] section: {}",
        config
    );
    assert!(
        config.contains("algorithm = \"ed25519\""),
        "config must record algorithm"
    );
    assert!(
        config.contains("keyring_service = \"tillandsias\""),
        "config must reference the tillandsias keyring service"
    );
    assert!(
        config.contains("keyring_account = \"tillandsias-deploy-key:demo\""),
        "config must reference the per-project keyring account"
    );
    assert!(
        config.contains("@trace spec:gh-auth-script"),
        "config must @trace spec:gh-auth-script"
    );
    assert!(
        config.contains("public_key = \"ssh-ed25519 "),
        "config must record the public key"
    );

    // The fake keystore must contain the private key.
    assert!(keystore.is_dir(), "fake keystore directory missing");
    let entries: Vec<_> = fs::read_dir(&keystore)
        .expect("read keystore")
        .filter_map(|e| e.ok())
        .collect();
    assert_eq!(entries.len(), 1, "expected exactly one secret in keystore");
    let stored = fs::read_to_string(entries[0].path()).expect("read stored secret");
    assert!(
        stored.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"),
        "stored secret must be an OpenSSH private key, got: {:.80}",
        stored
    );

    // The private key must NOT be in any file inside the project tree.
    fn assert_no_private_key(dir: &Path) {
        for entry in fs::read_dir(dir).expect("readdir") {
            let entry = entry.expect("entry");
            let path = entry.path();
            if path.is_dir() {
                assert_no_private_key(&path);
            } else if let Ok(contents) = fs::read_to_string(&path) {
                assert!(
                    !contents.contains("BEGIN OPENSSH PRIVATE KEY"),
                    "private key found in {} — forge tree must never see it",
                    path.display()
                );
            }
        }
    }
    assert_no_private_key(&project_dir);
}

/// The script's mode dispatcher rejects unknown modes with exit code 2.
#[test]
fn deploy_mode_rejects_unknown_mode() {
    let root = repo_root();
    let script = root.join("scripts/generate-repo-key.sh");

    let output = Command::new("bash")
        .arg(&script)
        .arg("--mode=banana")
        .output()
        .expect("run script");

    assert!(!output.status.success(), "unknown mode should fail");
    // Exit code 2 from _die "...unsupported..." 2
    assert_eq!(
        output.status.code(),
        Some(2),
        "unknown mode should exit with code 2"
    );
}

/// Script declares the right @trace annotations.
#[test]
fn generate_repo_key_traces_secrets_specs() {
    let root = repo_root();
    let src = fs::read_to_string(root.join("scripts/generate-repo-key.sh")).expect("read script");

    for trace in [
        "spec:gh-auth-script",
        "spec:secrets-management",
        "spec:native-secrets-store",
    ] {
        assert!(
            src.contains(trace),
            "script must @trace {}",
            trace
        );
    }
}

/// The github-credential-tools cheatsheet documents the deploy-key flow.
#[test]
fn github_credential_tools_documents_deploy_key_flow() {
    let root = repo_root();
    let src = fs::read_to_string(root.join("docs/cheatsheets/github-credential-tools.md"))
        .expect("read cheatsheet");

    for needle in [
        "generate-repo-key.sh",
        "deploy",
        "Secret Service",
        "keyring",
        "forge never",
    ] {
        assert!(
            src.to_lowercase().contains(&needle.to_lowercase()),
            "github-credential-tools.md should document `{}`",
            needle
        );
    }
}
