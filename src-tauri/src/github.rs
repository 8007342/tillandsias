//! GitHub remote repository discovery and cloning.
//!
//! Fetches the authenticated user's repositories using the `gh` CLI inside
//! a forge container, and clones selected repos into the scanner's watched
//! directory. All operations reuse the same security flags as other podman
//! operations.
//!
//! # Credential delivery
//!
//! These are short-lived `podman run` invocations (one shot, `--rm`). The
//! token is read from the host OS keyring on the host side, then passed to
//! the child podman process via `Command::env("GH_TOKEN", token)` — that
//! sets the variable in the *podman CLI process's* environment only, not
//! in this process's environment. Podman is then asked to forward it into
//! the container via the bare-name form `-e GH_TOKEN` (no value on the
//! command line). End result:
//!
//!   - Token never appears in `ps aux` (no value in argv)
//!   - Token never persists on the host filesystem
//!   - Token visible only in `/proc/<podman-pid>/environ` for the brief
//!     lifetime of the podman child, readable only by the same UID
//!   - Inside the container, `gh` reads `GH_TOKEN` natively (its documented
//!     non-interactive auth path) — no `gh auth login`, no on-disk hosts.yml
//!
//! The host-side `String` holding the token is wrapped in
//! `zeroize::Zeroizing<String>` so its heap allocation is wiped on Drop.
//!
//! @trace spec:remote-projects, spec:gh-auth-script, spec:native-secrets-store, spec:secrets-management

use std::path::Path;

use serde::Deserialize;
use tracing::{debug, error, info, instrument};
use zeroize::Zeroizing;

use crate::handlers::forge_image_tag;

/// A remote GitHub repository discovered via `gh repo list`.
#[derive(Debug, Clone)]
pub struct RemoteRepo {
    /// Simple repository name (e.g., "tillandsias").
    pub name: String,
    /// Full owner/name (e.g., "8007342/tillandsias").
    pub full_name: String,
}

/// JSON shape returned by `gh repo list --json name,nameWithOwner`.
#[derive(Debug, Deserialize)]
struct GhRepoEntry {
    name: String,
    #[serde(rename = "nameWithOwner")]
    name_with_owner: String,
}

/// Fetch the authenticated user's GitHub repositories.
///
/// Runs `gh repo list --json name,nameWithOwner --limit 100` inside an
/// ephemeral forge container with `GH_TOKEN` injected from the host
/// keyring (see module docs for the no-leak passing scheme). Returns the
/// parsed list or an error string.
/// @trace spec:remote-projects, spec:secrets-management
#[instrument(skip_all)]
pub async fn fetch_repos() -> Result<Vec<RemoteRepo>, String> {
    #[cfg(target_os = "windows")]
    {
        // @trace spec:cross-platform, spec:remote-projects, spec:windows-wsl-runtime
        return fetch_repos_wsl().await;
    }
    #[cfg(not(target_os = "windows"))]
    {
        fetch_repos_podman().await
    }
}

/// Fetch remote repos via the `tillandsias-git` WSL distro (Windows path).
///
/// The git distro has `gh` CLI installed (Alpine `github-cli` package). Token
/// flows from the Windows Credential Manager → stdin pipe → `env GH_TOKEN=`
/// inside the distro. The token never appears in argv. Output is JSON parsed
/// the same way as the podman path.
///
/// @trace spec:cross-platform, spec:remote-projects, spec:secrets-management
#[cfg(target_os = "windows")]
async fn fetch_repos_wsl() -> Result<Vec<RemoteRepo>, String> {
    use std::process::Stdio;
    use tokio::io::AsyncWriteExt;

    let token: Zeroizing<String> = match crate::secrets::retrieve_github_token() {
        Ok(Some(t)) => Zeroizing::new(t),
        Ok(None) => return Err("No GitHub credentials found in keyring".to_string()),
        Err(e) => return Err(format!("Keyring unavailable: {e}")),
    };

    // The shell script reads the token from stdin's first line, exports it,
    // then unsets stdin before running gh. Token never appears in argv.
    let script = "read -r GH_TOKEN; export GH_TOKEN; gh repo list --json name,nameWithOwner --limit 100 </dev/null";

    info!("Fetching remote repos via gh in tillandsias-git WSL distro");

    let mut child = {
        let mut __c = tokio::process::Command::new("wsl.exe");
        tillandsias_podman::no_window_async(&mut __c);
        __c
    }
    .args([
        "-d",
        "tillandsias-git",
        "--user",
        "git",
        "--exec",
        "/bin/sh",
        "-c",
        script,
    ])
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .map_err(|e| format!("Failed to spawn wsl.exe: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(token.as_bytes())
            .await
            .map_err(|e| format!("Failed to write token to wsl stdin: {e}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("Failed to write newline to wsl stdin: {e}"))?;
        drop(stdin);
    }

    let output = child
        .wait_with_output()
        .await
        .map_err(|e| format!("wsl.exe failed: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(stderr = %stderr, "gh repo list failed (WSL)");
        return Err(format!("gh repo list failed: {}", stderr.trim()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    debug!(raw_len = stdout.len(), "gh repo list output received");

    let entries: Vec<GhRepoEntry> = serde_json::from_str(stdout.trim())
        .map_err(|e| format!("Failed to parse gh output: {e}"))?;

    let repos = entries
        .into_iter()
        .map(|e| RemoteRepo {
            name: e.name,
            full_name: e.name_with_owner,
        })
        .collect::<Vec<_>>();

    info!(count = repos.len(), "Remote repos fetched (WSL)");
    Ok(repos)
}

#[cfg(not(target_os = "windows"))]
async fn fetch_repos_podman() -> Result<Vec<RemoteRepo>, String> {
    // Read the token (not just check existence) so we can hand it to the
    // child podman process via env. Wrap in Zeroizing so the host-side heap
    // allocation is wiped when this function returns.
    // @trace spec:native-secrets-store, spec:secrets-management
    let token: Zeroizing<String> = match crate::secrets::retrieve_github_token() {
        Ok(Some(t)) => Zeroizing::new(t),
        Ok(None) => return Err("No GitHub credentials found in keyring".to_string()),
        Err(e) => return Err(format!("Keyring unavailable: {e}")),
    };

    let args = build_gh_run_args(&[
        "gh",
        "repo",
        "list",
        "--json",
        "name,nameWithOwner",
        "--limit",
        "100",
    ]);

    info!("Fetching remote repos via gh CLI");

    // `Command::env(K, V)` puts the var in the spawned podman process's
    // environment ONLY — not in this Rust process's environment. The
    // `-e GH_TOKEN` arg (no `=value`) tells podman to forward it.
    let output = tillandsias_podman::podman_cmd()
        .env("GH_TOKEN", token.as_str())
        .arg("run")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("Failed to run podman: {e}"))?;

    if !output.status.success() {
        // gh's stderr on auth failure says e.g. "authentication required";
        // it does NOT echo GH_TOKEN — it's an env var, not a CLI arg.
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(stderr = %stderr, "gh repo list failed");
        return Err(format!("gh repo list failed: {}", stderr.trim()));
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
/// Runs `gh repo clone <full_name> <target_dir>` inside an ephemeral forge
/// container with `GH_TOKEN` injected from the host keyring (see module
/// docs for the no-leak passing scheme) and the target's parent directory
/// bind-mounted RW so the clone lands on the host filesystem.
/// @trace spec:remote-projects, spec:secrets-management
#[instrument(skip_all, fields(repo = %full_name, target = %target_dir.display()))]
pub async fn clone_repo(full_name: &str, target_dir: &Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        // @trace spec:cross-platform, spec:remote-projects, spec:windows-wsl-runtime
        return clone_repo_wsl(full_name, target_dir).await;
    }
    #[cfg(not(target_os = "windows"))]
    clone_repo_podman(full_name, target_dir).await
}

/// Clone a GitHub repo via the tillandsias-git WSL distro.
///
/// Token flows: Windows keyring → stdin pipe to wsl.exe → `read GH_TOKEN`
/// inside the distro → `gh repo clone`. Target dir is the host Windows path
/// translated to /mnt/c/... so the clone lands directly on host fs.
///
/// @trace spec:cross-platform, spec:remote-projects, spec:secrets-management,
/// spec:windows-wsl-runtime
#[cfg(target_os = "windows")]
async fn clone_repo_wsl(full_name: &str, target_dir: &Path) -> Result<(), String> {
    use std::process::Stdio;
    use tokio::io::AsyncWriteExt;

    let token: Zeroizing<String> = match crate::secrets::retrieve_github_token() {
        Ok(Some(t)) => Zeroizing::new(t),
        Ok(None) => return Err("No GitHub credentials found in keyring".to_string()),
        Err(e) => return Err(format!("Keyring unavailable: {e}")),
    };

    // Translate target_dir to /mnt/c/... so gh writes the clone on host fs.
    let target_str = target_dir.to_string_lossy();
    let bytes = target_str.as_bytes();
    let target_mnt =
        if bytes.len() >= 3 && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/') {
            let drive = (bytes[0] as char).to_ascii_lowercase();
            let rest = target_str[2..].replace('\\', "/");
            format!("/mnt/{drive}{rest}")
        } else {
            return Err(format!(
                "target_dir is not a Windows drive path: {target_str}"
            ));
        };

    info!(repo = %full_name, target = %target_mnt, "Cloning repository via WSL git distro");

    // Token is fed via stdin to a small shell script inside the distro.
    let script = format!(
        "read -r GH_TOKEN; export GH_TOKEN; gh repo clone '{full_name}' '{target_mnt}' </dev/null",
    );

    let mut child = {
        let mut __c = tokio::process::Command::new("wsl.exe");
        tillandsias_podman::no_window_async(&mut __c);
        __c
    }
    .args([
        "-d",
        "tillandsias-git",
        "--user",
        "git",
        "--exec",
        "/bin/sh",
        "-c",
        &script,
    ])
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped())
    .spawn()
    .map_err(|e| format!("Failed to spawn wsl.exe: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(token.as_bytes())
            .await
            .map_err(|e| format!("Failed to write token to wsl stdin: {e}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("Failed to write newline to wsl stdin: {e}"))?;
        drop(stdin);
    }

    let output = child
        .wait_with_output()
        .await
        .map_err(|e| format!("wsl.exe failed: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(repo = %full_name, stderr = %stderr, "Clone failed (WSL)");
        return Err(format!("Clone failed: {}", stderr.trim()));
    }

    info!(repo = %full_name, "Clone completed (WSL)");
    Ok(())
}

#[cfg(not(target_os = "windows"))]
async fn clone_repo_podman(full_name: &str, target_dir: &Path) -> Result<(), String> {
    // Ensure the parent directory exists so we can mount it
    let parent = target_dir
        .parent()
        .ok_or_else(|| "Cannot determine parent directory for clone target".to_string())?;

    let dir_name = target_dir
        .file_name()
        .ok_or_else(|| "Cannot determine directory name for clone target".to_string())?
        .to_string_lossy();

    // Read the token from the host keyring; clone needs auth for private repos
    // and rate-limit headroom for public ones.
    // @trace spec:native-secrets-store, spec:secrets-management
    let token: Zeroizing<String> = match crate::secrets::retrieve_github_token() {
        Ok(Some(t)) => Zeroizing::new(t),
        Ok(None) => return Err("No GitHub credentials found in keyring".to_string()),
        Err(e) => return Err(format!("Keyring unavailable: {e}")),
    };

    // The container mounts the parent of the target dir (e.g., ~/src)
    // and clones into /home/forge/src/<name>
    let container_target = format!("/home/forge/src/{dir_name}");

    let mut args = vec![
        "--rm".to_string(),
        "--init".to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "--security-opt=label=disable".to_string(),
    ];

    // Mount the parent directory (~/src) rw so the clone lands there
    args.push("-v".to_string());
    args.push(format!("{}:/home/forge/src", parent.display()));

    // Forward GH_TOKEN from the calling podman process's env (set below
    // via Command::env). Bare-name `-e GH_TOKEN` tells podman to inherit;
    // no value appears on the command line.
    args.push("-e".to_string());
    args.push("GH_TOKEN".to_string());

    // Override entrypoint to skip forge setup
    args.push("--entrypoint".to_string());
    args.push("gh".to_string());

    args.push(forge_image_tag());
    args.push("repo".to_string());
    args.push("clone".to_string());
    args.push(full_name.to_string());
    args.push(container_target);

    info!(repo = %full_name, "Cloning repository");

    let output = tillandsias_podman::podman_cmd()
        .env("GH_TOKEN", token.as_str())
        .arg("run")
        .args(&args)
        .output()
        .await
        .map_err(|e| format!("Failed to run podman: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        error!(repo = %full_name, stderr = %stderr, "Clone failed");
        return Err(format!("Clone failed: {}", stderr.trim()));
    }

    info!(repo = %full_name, "Clone completed");
    Ok(())
}

/// Build common podman run arguments for short-lived gh CLI operations.
///
/// Returns args for `podman run <args>` — ephemeral, security-hardened, with
/// a bare-name `-e GH_TOKEN` so podman inherits the token from the calling
/// process's environment (the caller MUST set it via `Command::env`).
/// @trace spec:secrets-management, spec:native-secrets-store
fn build_gh_run_args(command: &[&str]) -> Vec<String> {
    let mut args = vec![
        "--rm".to_string(),
        "--init".to_string(),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--userns=keep-id".to_string(),
        "--security-opt=label=disable".to_string(),
        // Forward GH_TOKEN from the calling process's env. No value here
        // means "inherit from caller" — token never appears in argv.
        "-e".to_string(),
        "GH_TOKEN".to_string(),
    ];

    // Override entrypoint to skip forge setup (opencode/openspec install)
    args.push("--entrypoint".to_string());
    args.push(command[0].to_string());

    // Image
    args.push(forge_image_tag());

    // Command arguments (skip first element, already used as entrypoint)
    for part in &command[1..] {
        args.push(part.to_string());
    }

    args
}
