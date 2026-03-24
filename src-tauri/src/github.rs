//! GitHub remote repository discovery and cloning.
//!
//! Fetches the authenticated user's repositories using the `gh` CLI inside
//! a forge container, and clones selected repos into the scanner's watched
//! directory. All operations reuse the same security flags and secret mounts
//! as other podman operations.

use std::path::Path;

use serde::Deserialize;
use tracing::{debug, error, info, instrument};

use tillandsias_core::config::cache_dir;

use crate::handlers::FORGE_IMAGE_TAG;

/// A remote GitHub repository discovered via `gh repo list`.
#[derive(Debug, Clone)]
pub struct RemoteRepo {
    /// Simple repository name (e.g., "tillandsias").
    pub name: String,
    /// Full owner/name (e.g., "8007342/tillandsias").
    pub full_name: String,
}

/// JSON shape returned by `gh repo list --json name,nameWithOwner,url`.
#[derive(Debug, Deserialize)]
struct GhRepoEntry {
    name: String,
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
    #[allow(dead_code)]
    url: String,
}

/// Fetch the authenticated user's GitHub repositories.
///
/// Runs `gh repo list --json name,nameWithOwner,url --limit 100` inside a
/// forge container with GitHub credentials mounted. Returns the parsed list
/// or an error string.
#[instrument(skip_all)]
pub async fn fetch_repos() -> Result<Vec<RemoteRepo>, String> {
    let cache = cache_dir();
    let secrets_dir = cache.join("secrets");
    let gh_dir = secrets_dir.join("gh");

    // Verify credentials exist before spawning a container
    if !gh_dir.join("hosts.yml").exists() {
        return Err("No GitHub credentials found".to_string());
    }

    let args = build_gh_run_args(
        &secrets_dir,
        &[
            "gh",
            "repo",
            "list",
            "--json",
            "name,nameWithOwner,url",
            "--limit",
            "100",
        ],
    );

    info!("Fetching remote repos via gh CLI");

    let output = tokio::process::Command::new("podman")
        .arg("run")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("Failed to run podman: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(stderr = %stderr, "gh repo list failed");
        return Err(format!("gh repo list failed: {stderr}"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    debug!(raw_len = stdout.len(), "gh repo list output received");

    let entries: Vec<GhRepoEntry> =
        serde_json::from_str(&stdout).map_err(|e| format!("Failed to parse gh output: {e}"))?;

    let repos = entries
        .into_iter()
        .map(|e| RemoteRepo {
            name: e.name,
            full_name: e.name_with_owner,
        })
        .collect::<Vec<_>>();

    info!(count = repos.len(), "Remote repos fetched");
    Ok(repos)
}

/// Clone a remote repository into the target directory.
///
/// Runs `gh repo clone <full_name> <target_dir>` inside a forge container
/// with GitHub credentials and the target directory mounted.
#[instrument(skip_all, fields(repo = %full_name, target = %target_dir.display()))]
pub async fn clone_repo(full_name: &str, target_dir: &Path) -> Result<(), String> {
    let cache = cache_dir();
    let secrets_dir = cache.join("secrets");

    // Ensure the parent directory exists so we can mount it
    let parent = target_dir
        .parent()
        .ok_or_else(|| "Cannot determine parent directory for clone target".to_string())?;

    let dir_name = target_dir
        .file_name()
        .ok_or_else(|| "Cannot determine directory name for clone target".to_string())?
        .to_string_lossy();

    // The container mounts the parent of the target dir (e.g., ~/src)
    // and clones into /home/forge/src/<name>
    let container_target = format!("/home/forge/src/{dir_name}");

    let mut args = vec![
        "--rm".to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "--security-opt=label=disable".to_string(),
    ];

    // Mount the parent directory (~/src) rw so the clone lands there
    args.push("-v".to_string());
    args.push(format!("{}:/home/forge/src", parent.display()));

    // Mount GitHub credentials (read-only)
    args.push("-v".to_string());
    args.push(format!(
        "{}:/home/forge/.config/gh:ro",
        secrets_dir.join("gh").display()
    ));

    // Mount git config directory (read-only) + env var
    let git_dir = secrets_dir.join("git");
    if git_dir.exists() {
        args.push("-v".to_string());
        args.push(format!(
            "{}:/home/forge/.config/tillandsias-git:ro",
            git_dir.display()
        ));
        args.push("-e".to_string());
        args.push("GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig".to_string());
    }

    // Override entrypoint to skip forge setup
    args.push("--entrypoint".to_string());
    args.push("gh".to_string());

    args.push(FORGE_IMAGE_TAG.to_string());
    args.push("repo".to_string());
    args.push("clone".to_string());
    args.push(full_name.to_string());
    args.push(container_target);

    info!(repo = %full_name, "Cloning repository");

    let output = tokio::process::Command::new("podman")
        .arg("run")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("Failed to run podman: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(repo = %full_name, stderr = %stderr, "Clone failed");
        return Err(format!("Clone failed: {stderr}"));
    }

    info!(repo = %full_name, "Clone completed");
    Ok(())
}

/// Build common podman run arguments for short-lived gh CLI operations.
///
/// Returns args for `podman run <args>` — ephemeral, security-hardened,
/// with GitHub credentials mounted read-only. Uses `--entrypoint` to
/// bypass the forge image's default entrypoint (which installs opencode).
fn build_gh_run_args(secrets_dir: &Path, command: &[&str]) -> Vec<String> {
    let mut args = vec![
        "--rm".to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "--security-opt=label=disable".to_string(),
    ];

    // Mount GitHub CLI credentials (read-only for fetch/clone operations)
    args.push("-v".to_string());
    args.push(format!(
        "{}:/home/forge/.config/gh:ro",
        secrets_dir.join("gh").display()
    ));

    // Mount git config directory (read-only) + env var to find it
    let git_dir = secrets_dir.join("git");
    if git_dir.exists() {
        args.push("-v".to_string());
        args.push(format!(
            "{}:/home/forge/.config/tillandsias-git:ro",
            git_dir.display()
        ));
        args.push("-e".to_string());
        args.push("GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig".to_string());
    }

    // Override entrypoint to skip forge setup (opencode/openspec install)
    args.push("--entrypoint".to_string());
    args.push(command[0].to_string());

    // Image
    args.push(FORGE_IMAGE_TAG.to_string());

    // Command arguments (skip first element, already used as entrypoint)
    for part in &command[1..] {
        args.push(part.to_string());
    }

    args
}
