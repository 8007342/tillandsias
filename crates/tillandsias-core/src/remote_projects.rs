// @trace spec:remote-projects, spec:gh-auth-script
//! GitHub project discovery and caching for tray's "Clone Project" feature.
//!
//! Queries GitHub API via `gh` inside the git image, filters projects based on
//! access, and caches results in memory with a 5-minute TTL to avoid repeated
//! container launches.

use serde::{Deserialize, Serialize};
use std::env;
use std::path::Path;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::{debug, warn};

/// Cached GitHub project metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitHubProject {
    pub name: String,
    pub owner: String,
    pub description: Option<String>,
    pub url: String,
    pub archived: bool,
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

fn run_git_image_shell(script: &str, extra_args: &[&str]) -> Result<String, String> {
    let image = git_image_tag();
    let mut command = Command::new("podman");
    command.args([
        "run",
        "--rm",
        "--secret",
        "tillandsias-github-token",
        "--entrypoint",
        "/bin/sh",
        &image,
        "-ceu",
        script,
        "gh",
    ]);
    command.args(extra_args);

    let output = command
        .output()
        .map_err(|err| format!("failed to spawn containerized gh: {err}"))?;

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

fn fetch_github_projects() -> Result<Vec<GitHubProject>, String> {
    let script = r#"
set -eu
export GH_PAGER=cat
cat /run/secrets/tillandsias-github-token 2>/dev/null | gh auth login --hostname github.com --with-token >/dev/null 2>&1
exec gh api user/repos?per_page=100\&sort=pushed\&type=owner
"#;

    let stdout = run_git_image_shell(script, &[])?;
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

fn discover_github_projects_inner() -> Result<Vec<GitHubProject>, String> {
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

    let projects = fetch_github_projects()?;
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
    match discover_github_projects_inner() {
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
    discover_github_projects_inner()
}

/// Clear the cached remote project list.
pub fn invalidate_github_projects_cache() {
    if let Ok(mut guard) = cache().lock() {
        *guard = None;
    }
}

/// Clone a project from a GitHub repository URL to a target directory.
///
/// Uses the git image so clone/auth flows remain inside the container that
/// owns GitHub credentials.
pub fn clone_project_from_github(repo_url: &str, target_path: &Path) -> Result<(), String> {
    if let Some(parent) = target_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create parent dir: {}", err))?;
    }

    let image = git_image_tag();
    let repo_dir = target_path.to_string_lossy().to_string();
    let script = r#"
set -eu
export GH_PAGER=cat
cat /run/secrets/tillandsias-github-token 2>/dev/null | gh auth login --hostname github.com --with-token >/dev/null 2>&1
exec gh repo clone "$1" "$2"
"#;

    let output = Command::new("podman")
        .args([
            "run",
            "--rm",
            "--secret",
            "tillandsias-github-token",
            "--entrypoint",
            "/bin/sh",
            &image,
            "-ceu",
            script,
            "gh",
            repo_url,
            &repo_dir,
        ])
        .output()
        .map_err(|err| format!("git clone failed: {}", err))?;

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
        invalidate_github_projects_cache();

        let projects = discover_github_projects_result().expect("containerized gh fetch");
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name, "forge");
        assert_eq!(projects[0].owner, "8007342");
        assert!(!projects[0].archived);

        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        }
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
        invalidate_github_projects_cache();
    }

    #[test]
    fn clone_project_uses_containerized_gh() {
        let _guard = TEST_LOCK.lock().expect("test lock");
        let podman_dir = install_podman_mock();
        let original_path = std::env::var_os("PATH");
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
        unsafe { std::env::remove_var("TILLANDSIAS_GIT_IMAGE") };
    }
}
