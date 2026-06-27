// @trace spec:remote-projects, spec:gh-auth-script
// @cheatsheet runtime/hashicorp-vault-tillandsias.md
//! GitHub project discovery and caching for tray's "Clone Project" feature.
//!
//! Queries GitHub API via `gh` inside the git image, filters projects based on
//! access, and caches results in memory with a 5-minute TTL to avoid repeated
//! container launches.

use serde::{Deserialize, Serialize};
use std::env;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tracing::{debug, warn};

/// Hard ceiling on a single containerized `gh` invocation. Cold container
/// create + Vault read + `gh auth login` + the GitHub API call realistically
/// finishes in a few seconds; anything past this is a stall (DNS/proxy/GitHub
/// hang). Without a bound, `command.output()` blocks the worker forever and —
/// because the tray latches `cloud_refresh_in_flight` for the duration — the
/// ☁️ Cloud submenu wedges on `(loading…)` and never refreshes again.
/// @trace spec:remote-projects, spec:tray-ux
const GH_INVOCATION_TIMEOUT: Duration = Duration::from_secs(25);

/// Cached GitHub project metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubProject {
    pub name: String,
    pub owner: String,
    pub description: Option<String>,
    pub url: String,
    pub archived: bool,
}

impl GitHubProject {
    /// Canonical `owner/name` form (a.k.a. GitHub "name with owner" / NWO).
    ///
    /// This is the form accepted by `gh repo clone`. Note that
    /// [`Self::url`] is whatever the `gh api user/repos` JSON populated —
    /// for the `user/repos` endpoint that is the *API* URL
    /// (`https://api.github.com/repos/<owner>/<name>`), which `gh repo
    /// clone` cannot consume directly. Always prefer `nwo()` when invoking
    /// `gh repo clone`.
    pub fn nwo(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheEntry {
    projects: Vec<GitHubProject>,
    cached_at: u64,
}

#[derive(Debug, Clone, Deserialize)]
struct GhRepoOwner {
    login: String,
}

#[derive(Debug, Clone, Deserialize)]
struct GhRepo {
    name: String,
    owner: GhRepoOwner,
    description: Option<String>,
    url: String,
    archived: bool,
}

const CACHE_TTL_SECS: u64 = 300;

static REMOTE_PROJECT_CACHE: OnceLock<Mutex<Option<CacheEntry>>> = OnceLock::new();

fn cache() -> &'static Mutex<Option<CacheEntry>> {
    REMOTE_PROJECT_CACHE.get_or_init(|| Mutex::new(None))
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn is_cache_valid(cached_at: u64) -> bool {
    now_secs().saturating_sub(cached_at) < CACHE_TTL_SECS
}

const RUNTIME_VERSION: &str = include_str!("../../../VERSION");

fn git_image_tag() -> String {
    env::var("TILLANDSIAS_GIT_IMAGE").unwrap_or_else(|_| {
        // Fully-qualified, versioned tag matching what `tillandsias --init`
        // produces. A bare short name like `tillandsias-git:latest` would fail
        // under podman's `short-name-mode=enforcing` (e.g. Fedora Silverblue)
        // because there's no TTY to prompt for registry selection and no
        // `:latest` tag is ever produced.
        format!("localhost/tillandsias-git:v{}", RUNTIME_VERSION.trim())
    })
}

/// Truncate a script body to a single-line preview suitable for an
/// `eprintln!` debug trace. Keeps roughly 80 chars so the diagnostic stays
/// glanceable.
fn debug_script_preview(script: &str) -> String {
    let flat: String = script.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.len() > 80 {
        // Walk back to the nearest char boundary so we never split a
        // multi-byte UTF-8 sequence. Our scripts are ASCII today, but
        // logs surface user-supplied target paths which can be UTF-8.
        let mut cut = 80;
        while cut > 0 && !flat.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("{}…", &flat[..cut])
    } else {
        flat
    }
}

/// Print a redacted summary of a podman invocation. We never print the
/// token itself — only the secret *name* (which is fine to log) and a
/// truncated script preview. Extra args are echoed as-is.
fn debug_log_podman_invocation(
    op: &str,
    image: &str,
    secret_mounted: bool,
    script: &str,
    extra_args: &[&str],
) {
    eprintln!(
        "[tillandsias] gh: {op} image={image} secret_mounted={secret_mounted} script={:?}",
        debug_script_preview(script)
    );
    if !extra_args.is_empty() {
        // Args here are the positional `gh repo clone "$1" "$2"` arguments
        // (owner/name + target dir). Neither is sensitive.
        eprintln!("[tillandsias] gh: args={extra_args:?}");
    }
}

fn debug_log_podman_result(op: &str, status: &std::process::ExitStatus, stderr: &[u8]) {
    if status.success() {
        eprintln!("[tillandsias] gh: {op} ok status={status}");
    } else {
        let preview = String::from_utf8_lossy(stderr);
        let trimmed = if preview.len() > 400 {
            let mut cut = 400;
            while cut > 0 && !preview.is_char_boundary(cut) {
                cut -= 1;
            }
            format!("{}…", &preview[..cut])
        } else {
            preview.to_string()
        };
        eprintln!(
            "[tillandsias] gh: {op} FAILED status={status} stderr={:?}",
            trimmed.trim()
        );
    }
}

struct RemoteVaultLease {
    secret_name: String,
    #[cfg(feature = "vault")]
    _lease: Option<crate::vault_bootstrap::AppRoleSecretLease>,
}

impl RemoteVaultLease {
    fn acquire(debug: bool) -> Result<Self, String> {
        #[cfg(test)]
        {
            let _ = debug;
            return Ok(Self {
                secret_name: "test-vault-token".to_string(),
                #[cfg(feature = "vault")]
                _lease: None,
            });
        }
        #[cfg(all(not(test), feature = "vault"))]
        {
            // Ensure Vault is online before minting the lease. Without this, a
            // Cloud-submenu open that lands before the tray's background vault
            // probe has finished would hit "Vault container is not running" and
            // surface a misleading "run --github-login" hint. @trace spec:remote-projects
            crate::vault_bootstrap::ensure_vault_running(debug)?;
            let instance = format!("remote-projects-{}", std::process::id());
            let lease =
                crate::vault_bootstrap::mint_approle_secret_lease("git-mirror", &instance, debug)?;
            let secret_name = lease.secret_name().to_string();
            Ok(Self {
                secret_name,
                _lease: Some(lease),
            })
        }
        #[cfg(all(not(test), not(feature = "vault")))]
        {
            let _ = debug;
            Err("vault feature not compiled; remote GitHub projects require Vault".to_string())
        }
    }

    fn mount_arg(&self) -> String {
        // uid/gid ownership is load-bearing — see GIT_VAULT_TOKEN_SECRET_OPTS:
        // without it the git user can't read the root-owned 0400 secret and the
        // containerized `gh` fetch gets no GitHub token. @trace spec:remote-projects
        format!(
            "{},{}",
            self.secret_name,
            crate::GIT_VAULT_TOKEN_SECRET_OPTS
        )
    }
}

/// Run a `Command` to completion but abort if it outruns `timeout`.
///
/// stdout/stderr are drained on dedicated threads so a large `gh api` response
/// (≈100 repos of JSON can exceed the OS pipe buffer) can't deadlock the wait
/// loop. On timeout the child is killed and reaped so we never leak a hung
/// `podman run`.
fn run_command_with_timeout(mut command: Command, timeout: Duration) -> Result<Output, String> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|err| format!("failed to spawn containerized gh: {err}"))?;

    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();
    let out_handle = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(pipe) = stdout_pipe.as_mut() {
            let _ = pipe.read_to_end(&mut buf);
        }
        buf
    });
    let err_handle = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(pipe) = stderr_pipe.as_mut() {
            let _ = pipe.read_to_end(&mut buf);
        }
        buf
    });

    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stdout = out_handle.join().unwrap_or_default();
                let stderr = err_handle.join().unwrap_or_default();
                return Ok(Output {
                    status,
                    stdout,
                    stderr,
                });
            }
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(format!(
                        "containerized gh timed out after {}s (killed)",
                        timeout.as_secs()
                    ));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(format!("failed to wait on containerized gh: {err}")),
        }
    }
}

fn run_git_image_shell(script: &str, extra_args: &[&str], debug: bool) -> Result<String, String> {
    let image = git_image_tag();
    let vault_lease = RemoteVaultLease::acquire(debug)?;
    let vault_mount = vault_lease.mount_arg();
    if debug {
        debug_log_podman_invocation("run_git_image_shell", &image, true, script, extra_args);
    }
    let mut command = tillandsias_podman::podman_cmd_sync();
    command.args([
        "run",
        "--rm",
        "--secret",
        &vault_mount,
        "--network",
        // Dual-homed: enclave leg (internal DNS) + managed egress leg for the
        // direct GitHub push. `tillandsias-egress` is created at init alongside
        // the enclave network; the old `bridge` name never resolved on a clean
        // rootless runtime. See main.rs ENCLAVE_EGRESS_NETS / ensure_egress_network.
        "tillandsias-enclave,tillandsias-egress",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--security-opt=label=disable",
        "--userns=keep-id",
        "--env",
        "VAULT_ADDR=https://vault:8200",
        "--env",
        "CURL_CA_BUNDLE=/etc/tillandsias/ca.crt",
        "--volume",
        "/tmp/tillandsias-ca/intermediate.crt:/etc/tillandsias/ca.crt:ro",
        "--entrypoint",
        "/bin/sh",
        &image,
        "-ceu",
        script,
        "gh",
    ]);
    command.args(extra_args);

    let output = run_command_with_timeout(command, GH_INVOCATION_TIMEOUT)?;

    if debug {
        debug_log_podman_result("run_git_image_shell", &output.status, &output.stderr);
    }

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "containerized gh exited with status {}: {}",
            output.status,
            stderr.trim()
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Probe GitHub auth end-to-end inside a container. Returns the GitHub login
/// name on success. Proves both that the token is present in Vault AND that it
/// is accepted by the GitHub API — a key-existence check alone cannot do this.
///
/// Uses the same containerized pattern as `fetch_github_projects` but hits only
/// `gh api user` (fast, ~1s) rather than the full repos endpoint.
///
/// @trace spec:tillandsias-vault, plan/issues/vault-credential-host-exposure-audit-2026-06-27.md
pub fn probe_github_username(debug: bool) -> Option<String> {
    let script = r#"
set -eu
vault-cli read -field=token secret/github/token | gh auth login --hostname github.com --with-token >/dev/null 2>&1
gh api user --jq .login
"#;
    match run_git_image_shell(script, &[], debug) {
        Ok(out) => {
            let name = out.trim().to_string();
            if name.is_empty() { None } else { Some(name) }
        }
        Err(e) => {
            if debug {
                eprintln!("[tillandsias] probe_github_username failed: {e}");
            }
            None
        }
    }
}

/// Definitive auth check: returns `true` iff the GitHub token in Vault is
/// present and accepted by the GitHub API. Launches a short-lived container —
/// use `vault_bootstrap::is_github_key_present` for high-frequency poll loops.
///
/// @trace spec:tillandsias-vault, spec:tray-minimal-ux
pub fn is_github_logged_in(debug: bool) -> bool {
    probe_github_username(debug).is_some()
}

fn fetch_github_projects(debug: bool) -> Result<Vec<GitHubProject>, String> {
    let script = r#"
set -eu
export GH_PAGER=cat
vault-cli read -field=token secret/github/token | gh auth login --hostname github.com --with-token >/dev/null 2>&1
exec gh api user/repos?per_page=100\&sort=pushed\&type=owner
"#;

    let stdout = run_git_image_shell(script, &[], debug)?;
    let repos: Vec<GhRepo> =
        serde_json::from_str(&stdout).map_err(|err| format!("invalid gh JSON: {err}"))?;

    Ok(repos
        .into_iter()
        .filter(|repo| !repo.archived)
        .map(|repo| GitHubProject {
            name: repo.name,
            owner: repo.owner.login,
            description: repo.description,
            url: repo.url,
            archived: repo.archived,
        })
        .collect())
}

fn discover_github_projects_inner(debug: bool) -> Result<Vec<GitHubProject>, String> {
    if let Ok(guard) = cache().lock()
        && let Some(entry) = guard.as_ref()
        && is_cache_valid(entry.cached_at)
    {
        debug!(
            "github_projects: loaded from in-memory cache ({} projects)",
            entry.projects.len()
        );
        return Ok(entry.projects.clone());
    }

    let projects = fetch_github_projects(debug)?;
    debug!("github_projects: discovered {} projects", projects.len());

    if let Ok(mut guard) = cache().lock() {
        *guard = Some(CacheEntry {
            projects: projects.clone(),
            cached_at: now_secs(),
        });
    }

    Ok(projects)
}

/// Discover GitHub projects using `gh` inside the git image.
///
/// Queries authenticated repositories, filters out archived repos, and
/// returns top projects by recent activity. Results are cached in memory with
/// a 5-minute TTL.
pub fn discover_github_projects() -> Vec<GitHubProject> {
    match discover_github_projects_inner(false) {
        Ok(projects) => projects,
        Err(err) => {
            warn!("github_projects: containerized gh failed: {}", err);
            Vec::new()
        }
    }
}

/// Discover GitHub projects and preserve the fetch error for callers that
/// need to surface it in the UI.
pub fn discover_github_projects_result() -> Result<Vec<GitHubProject>, String> {
    discover_github_projects_inner(false)
}

/// Same as [`discover_github_projects_result`] but emits `[tillandsias] gh:`
/// stderr breadcrumbs for every podman invocation when `debug == true`.
/// Token contents are NEVER logged — only secret names, the resolved image
/// tag, a truncated script preview, exit status, and (on failure) the first
/// 400 bytes of stderr.
pub fn discover_github_projects_result_with_debug(
    debug: bool,
) -> Result<Vec<GitHubProject>, String> {
    discover_github_projects_inner(debug)
}

/// Clear the cached remote project list.
pub fn invalidate_github_projects_cache() {
    if let Ok(mut guard) = cache().lock() {
        *guard = None;
    }
}

/// Normalize a GitHub repo identifier to the canonical `owner/name` form
/// (a.k.a. NWO — "name with owner") that `gh repo clone` accepts.
///
/// Accepts:
/// - `owner/name` — returned as-is.
/// - `https://github.com/owner/name(.git)?` — strips the host.
/// - `https://api.github.com/repos/owner/name` — the *API* URL form
///   emitted by `gh api user/repos`. Strips `/repos/` prefix. This is the
///   form that caused the original bug: it ends up with the literal path
///   `/repos/<owner>/<name>` after `gh` strips the host, which fails with
///   `invalid path: /repos/<owner>/<name>`.
///
/// Returns the input unchanged when it doesn't match any known shape so
/// callers that already pass a sane form aren't surprised.
fn normalize_repo_identifier(repo: &str) -> String {
    // API URL: https://api.github.com/repos/<owner>/<name>
    if let Some(rest) = repo
        .strip_prefix("https://api.github.com/repos/")
        .or_else(|| repo.strip_prefix("http://api.github.com/repos/"))
    {
        return rest.trim_end_matches('/').to_string();
    }
    // Web URL: https://github.com/<owner>/<name>(.git)?
    if let Some(rest) = repo
        .strip_prefix("https://github.com/")
        .or_else(|| repo.strip_prefix("http://github.com/"))
    {
        let stripped = rest.trim_end_matches('/').trim_end_matches(".git");
        return stripped.to_string();
    }
    repo.to_string()
}

/// Clone a project from a GitHub repository URL to a target directory.
///
/// Uses the git image so clone/auth flows remain inside the container that
/// owns GitHub credentials.
pub fn clone_project_from_github(repo_url: &str, target_path: &Path) -> Result<(), String> {
    clone_project_from_github_with_debug(repo_url, target_path, false)
}

/// Same as [`clone_project_from_github`] but emits `[tillandsias] gh:`
/// stderr breadcrumbs for the podman invocation when `debug == true`.
/// Token contents are NEVER logged — only the resolved image tag, secret
/// mount status, a truncated script preview, the normalized `owner/name`,
/// the exit status, and (on failure) the first 400 bytes of stderr.
pub fn clone_project_from_github_with_debug(
    repo_url: &str,
    target_path: &Path,
    debug: bool,
) -> Result<(), String> {
    // The container needs to write `target_path` from inside its own
    // filesystem. Without a bind-mount, `gh repo clone owner/name
    // /home/<user>/src/<repo>` fails with "could not create leading
    // directories ... Permission denied" because that host path doesn't
    // exist inside the container. We identity-map the *parent* directory
    // (e.g. `/home/<user>/src`) so the clone destination resolves to a
    // writable, host-shared path. Combined with `--userns=keep-id`, the
    // in-container UID 1000 == host UID 1000, so the cloned tree is owned
    // by the host user directly with no chown needed.
    let parent = target_path
        .parent()
        .ok_or_else(|| format!("target path {target_path:?} has no parent dir"))?;
    std::fs::create_dir_all(parent)
        .map_err(|err| format!("failed to create parent dir: {}", err))?;
    let parent_str = parent.to_string_lossy().to_string();
    let bind_mount = format!("{parent_str}:{parent_str}:rw");

    let nwo = normalize_repo_identifier(repo_url);
    let image = git_image_tag();
    let repo_dir = target_path.to_string_lossy().to_string();
    let script = r#"
set -eu
export GH_PAGER=cat
vault-cli read -field=token secret/github/token | gh auth login --hostname github.com --with-token >/dev/null 2>&1
exec gh repo clone "$1" "$2"
"#;
    let vault_lease = RemoteVaultLease::acquire(debug)?;
    let vault_mount = vault_lease.mount_arg();

    if debug {
        if nwo != repo_url {
            eprintln!("[tillandsias] gh: normalized repo identifier {repo_url:?} -> {nwo:?}");
        }
        eprintln!(
            "[tillandsias] gh: clone bind-mount {parent_str:?} (identity-mapped, rw) target={repo_dir:?}"
        );
        debug_log_podman_invocation(
            "clone_project_from_github",
            &image,
            true,
            script,
            &[nwo.as_str(), repo_dir.as_str()],
        );
    }

    let output = tillandsias_podman::podman_cmd_sync()
        .args([
            "run",
            "--rm",
            "--secret",
            &vault_mount,
            "--network",
            // Dual-homed egress leg — see run_git_image_shell above and
            // main.rs ENCLAVE_EGRESS_NETS; `bridge` never resolved on clean rootless.
            "tillandsias-enclave,tillandsias-egress",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--env",
            "VAULT_ADDR=https://vault:8200",
            "--env",
            "CURL_CA_BUNDLE=/etc/tillandsias/ca.crt",
            "--volume",
            "/tmp/tillandsias-ca/intermediate.crt:/etc/tillandsias/ca.crt:ro",
            "--security-opt=label=disable",
            "--userns=keep-id",
            "-v",
            &bind_mount,
            "--entrypoint",
            "/bin/sh",
            &image,
            "-ceu",
            script,
            "gh",
            &nwo,
            &repo_dir,
        ])
        .output()
        .map_err(|err| format!("git clone failed: {}", err))?;

    if debug {
        debug_log_podman_result("clone_project_from_github", &output.status, &output.stderr);
    }

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "containerized gh repo clone exited with status {}: {}",
            output.status,
            stderr.trim()
        ));
    }

    let tillandsias_dir = target_path.join(".tillandsias");
    std::fs::create_dir_all(&tillandsias_dir)
        .map_err(|err| format!("failed to create .tillandsias dir: {}", err))?;

    let config_path = tillandsias_dir.join("config.toml");
    let config_content = r#"# Tillandsias project configuration
[runtime]
# Agent selection: opencode, opencode-web, or claude
agent = "opencode-web"

[container]
# Container image to use (usually tillandsias-forge)
image = "tillandsias-forge"
"#;

    std::fs::write(&config_path, config_content)
        .map_err(|err| format!("failed to write config.toml: {}", err))?;

    debug!(
        "github_project_clone: cloned {} to {:?}",
        repo_url, target_path
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::sync::Mutex;
    use tempfile::tempdir;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn install_podman_mock() -> tempfile::TempDir {
        let dir = tempdir().expect("tempdir");
        #[cfg(unix)]
        {
            let mock = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../scripts/test-support/podman-mock.sh");
            symlink(&mock, dir.path().join("podman")).expect("podman symlink");
        }
        dir
    }

    #[test]
    fn git_image_tag_defaults_to_fully_qualified_versioned_tag() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        // Ensure no override is leaking from a previous test.
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
        let tag = git_image_tag();
        // Fully qualified to dodge podman's short-name resolution prompt on
        // hosts (e.g. Silverblue) that enforce short-name-mode without a TTY.
        assert!(
            tag.starts_with("localhost/tillandsias-git:v"),
            "expected fully-qualified versioned git image tag, got {tag}"
        );
        // Versioned: must match what `tillandsias --init` produces.
        assert_ne!(tag, "localhost/tillandsias-git:v", "missing version suffix");
        assert_ne!(tag, "tillandsias-git:latest", "regressed to short name");
    }

    #[test]
    fn test_is_cache_valid() {
        let now = now_secs();
        assert!(is_cache_valid(now));
        assert!(is_cache_valid(now - 100));
        assert!(!is_cache_valid(now - 600));
    }

    #[test]
    fn test_cache_invalidation() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        invalidate_github_projects_cache();
        let mut guard = cache().lock().expect("cache lock");
        *guard = Some(CacheEntry {
            projects: vec![GitHubProject {
                name: "cached".to_string(),
                owner: "owner".to_string(),
                description: None,
                url: "https://github.com/owner/cached".to_string(),
                archived: false,
            }],
            cached_at: now_secs(),
        });
        drop(guard);

        invalidate_github_projects_cache();
        assert!(cache().lock().expect("cache lock").is_none());
    }

    #[test]
    fn discover_projects_uses_containerized_gh() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let podman_dir = install_podman_mock();
        let original_path = std::env::var_os("PATH");
        let original_bin = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        let mock_path = format!(
            "{}:{}",
            podman_dir.path().display(),
            original_path
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default()
        );
        unsafe { std::env::set_var("PATH", mock_path) };
        unsafe { std::env::set_var("TILLANDSIAS_GIT_IMAGE", "mock-image") };
        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        invalidate_github_projects_cache();

        let projects = discover_github_projects_result().expect("containerized gh fetch");
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name, "forge");
        assert_eq!(projects[0].owner, "8007342");
        assert!(!projects[0].archived);

        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        }
        if let Some(bin) = original_bin {
            unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", bin) };
        } else {
            unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        }
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
        invalidate_github_projects_cache();
    }

    #[test]
    fn clone_project_uses_containerized_gh() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let podman_dir = install_podman_mock();
        let original_path = std::env::var_os("PATH");
        let original_bin = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        let mock_path = format!(
            "{}:{}",
            podman_dir.path().display(),
            original_path
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default()
        );
        unsafe { std::env::set_var("PATH", mock_path) };
        unsafe { std::env::set_var("TILLANDSIAS_GIT_IMAGE", "mock-image") };
        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };

        let clone_root = tempdir().expect("clone tempdir");
        let target = clone_root.path().join("forge");
        clone_project_from_github("https://github.com/8007342/forge", &target)
            .expect("containerized clone");

        assert!(
            target.join(".git").exists(),
            "mock clone should create .git"
        );
        assert!(target.join(".tillandsias/config.toml").exists());

        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        }
        if let Some(bin) = original_bin {
            unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", bin) };
        } else {
            unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        }
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
    }

    #[test]
    fn normalize_repo_identifier_handles_known_shapes() {
        // API URL (the bug-causing case from `gh api user/repos`)
        assert_eq!(
            normalize_repo_identifier("https://api.github.com/repos/8007342/lakanoa"),
            "8007342/lakanoa"
        );
        // Web URL with and without .git
        assert_eq!(
            normalize_repo_identifier("https://github.com/8007342/forge"),
            "8007342/forge"
        );
        assert_eq!(
            normalize_repo_identifier("https://github.com/8007342/forge.git"),
            "8007342/forge"
        );
        // Trailing slash
        assert_eq!(
            normalize_repo_identifier("https://github.com/8007342/forge/"),
            "8007342/forge"
        );
        // Already-canonical owner/name passes through.
        assert_eq!(normalize_repo_identifier("8007342/forge"), "8007342/forge");
    }

    #[test]
    fn github_project_nwo_returns_owner_slash_name() {
        let project = GitHubProject {
            name: "lakanoa".to_string(),
            owner: "8007342".to_string(),
            description: None,
            // Intentionally an API URL — this is what `gh api user/repos`
            // returns, and what triggered the original `invalid path:
            // /repos/8007342/lakanoa` error.
            url: "https://api.github.com/repos/8007342/lakanoa".to_string(),
            archived: false,
        };
        assert_eq!(project.nwo(), "8007342/lakanoa");
    }

    /// The original bug: `gh api user/repos` emits API URLs like
    /// `https://api.github.com/repos/<owner>/<name>`. Passing that to
    /// `gh repo clone` produced `invalid path: /repos/<owner>/<name>`.
    /// This test pins the fix: whatever shape the caller hands in, the
    /// `podman run … gh repo clone` invocation must receive the canonical
    /// `owner/name` form.
    #[test]
    fn clone_normalizes_api_url_to_owner_name() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let podman_dir = install_podman_mock();
        let state_dir = tempdir().expect("state tempdir");
        let original_path = std::env::var_os("PATH");
        let original_state = std::env::var_os("LITMUS_PODMAN_STATE_DIR");
        let original_bin = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        let mock_path = format!(
            "{}:{}",
            podman_dir.path().display(),
            original_path
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default()
        );
        unsafe { std::env::set_var("PATH", mock_path) };
        unsafe { std::env::set_var("TILLANDSIAS_GIT_IMAGE", "mock-image") };
        unsafe { std::env::set_var("LITMUS_PODMAN_STATE_DIR", state_dir.path()) };
        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };

        let clone_root = tempdir().expect("clone tempdir");
        let target = clone_root.path().join("lakanoa");
        clone_project_from_github("https://api.github.com/repos/8007342/lakanoa", &target)
            .expect("containerized clone with API URL");

        let captured_repo = std::fs::read_to_string(state_dir.path().join("last_clone_repo_arg"))
            .expect("mock should record repo arg");
        assert_eq!(
            captured_repo.trim(),
            "8007342/lakanoa",
            "gh repo clone must receive owner/name, not the API URL"
        );

        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        }
        if let Some(state) = original_state {
            unsafe { std::env::set_var("LITMUS_PODMAN_STATE_DIR", state) };
        } else {
            unsafe { std::env::remove_var("LITMUS_PODMAN_STATE_DIR") };
        }
        if let Some(bin) = original_bin {
            unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", bin) };
        } else {
            unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        }
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
    }

    /// Regression test for the "Permission denied" failure on Silverblue
    /// v0.2.260522.5: `gh repo clone owner/name /home/<user>/src/<repo>`
    /// failed inside the container with `could not create leading
    /// directories ... Permission denied` because the host path wasn't
    /// bind-mounted. Fix: identity-map the *parent* of the target into
    /// the container with `-v <parent>:<parent>:rw` and align UIDs with
    /// `--userns=keep-id`. SELinux relabeling is disabled via
    /// `--security-opt=label=disable` to match the other enclave
    /// containers (`build_git_run_args` and friends).
    #[test]
    fn clone_uses_host_parent_bindmount() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let podman_dir = install_podman_mock();
        let state_dir = tempdir().expect("state tempdir");
        let original_path = std::env::var_os("PATH");
        let original_state = std::env::var_os("LITMUS_PODMAN_STATE_DIR");
        let original_bin = std::env::var_os("TILLANDSIAS_PODMAN_BIN");
        let mock_path = format!(
            "{}:{}",
            podman_dir.path().display(),
            original_path
                .as_ref()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default()
        );
        unsafe { std::env::set_var("PATH", mock_path) };
        unsafe { std::env::set_var("TILLANDSIAS_GIT_IMAGE", "mock-image") };
        unsafe { std::env::set_var("LITMUS_PODMAN_STATE_DIR", state_dir.path()) };
        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };

        let clone_root = tempdir().expect("clone tempdir");
        let target = clone_root.path().join("lakanoa");
        let parent = clone_root.path().to_string_lossy().to_string();
        let expected_bind = format!("{parent}:{parent}:rw");

        clone_project_from_github("8007342/lakanoa", &target)
            .expect("containerized clone with bind-mount");

        let captured_args = std::fs::read_to_string(state_dir.path().join("last_clone_run_args"))
            .expect("mock should record full arg vector");
        let args: Vec<&str> = captured_args.lines().collect();

        assert!(
            args.contains(&"--userns=keep-id"),
            "podman run must pass --userns=keep-id so in-container UID 1000 == host UID; got args: {args:?}"
        );
        assert!(
            args.contains(&"--security-opt=label=disable"),
            "podman run must disable SELinux label relabeling on the bind-mount; got args: {args:?}"
        );
        // `-v` is followed by the bind-mount spec as the next arg.
        let v_index = args.iter().position(|a| *a == "-v").unwrap_or_else(|| {
            panic!("podman run must include `-v` bind-mount flag; got args: {args:?}")
        });
        let bind_spec = args
            .get(v_index + 1)
            .unwrap_or_else(|| panic!("`-v` must be followed by a mount spec; got args: {args:?}"));
        assert_eq!(
            *bind_spec, expected_bind,
            "bind-mount must identity-map the host parent dir as rw"
        );
        // Sanity: the positional clone target still comes through unchanged
        // and is *inside* the bind-mounted parent.
        let captured_target =
            std::fs::read_to_string(state_dir.path().join("last_clone_target_arg"))
                .expect("mock should record target arg");
        assert_eq!(captured_target.trim(), target.to_string_lossy().as_ref());

        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        }
        if let Some(state) = original_state {
            unsafe { std::env::set_var("LITMUS_PODMAN_STATE_DIR", state) };
        } else {
            unsafe { std::env::remove_var("LITMUS_PODMAN_STATE_DIR") };
        }
        if let Some(bin) = original_bin {
            unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", bin) };
        } else {
            unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        }
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
    }

    #[test]
    fn debug_log_helpers_redact_token_but_show_shape() {
        // Sanity check: the script preview compresses whitespace and caps
        // length so the auth-login `vault-cli read ...` line is visible
        // without dumping a multi-line block to stderr.
        let preview = debug_script_preview(
            "
set -eu
export GH_PAGER=cat
	vault-cli read -field=token secret/github/token | gh auth login --hostname github.com --with-token >/dev/null 2>&1
exec gh repo clone \"$1\" \"$2\"
",
        );
        // Compressed to single-line; UTF-8 ellipsis appended if truncated.
        assert!(!preview.contains('\n'));
        // 80-byte slice + 3-byte UTF-8 ellipsis = at most 83 bytes.
        assert!(
            preview.len() <= 83,
            "script preview should be glanceable: got {} bytes",
            preview.len()
        );
        // Always shows the *name* (safe to log) — the token contents live
        // inside the file, never in the script string.
        assert!(preview.contains("secret/github/token"));
    }
}
