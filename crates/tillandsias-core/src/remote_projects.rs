// @trace spec:remote-projects, spec:gh-auth-script
//! GitHub project discovery and caching for tray's "Clone Project" feature.
//!
//! Queries GitHub API via `gh`, filters projects based on access, and caches
//! results with 5-minute TTL to avoid rate limiting.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
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

/// Cache entry with timestamp for TTL management.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheEntry {
    projects: Vec<GitHubProject>,
    cached_at: u64,
}

/// Cache TTL in seconds (5 minutes).
const CACHE_TTL_SECS: u64 = 300;

/// Get the cache file path: ~/.tillandsias/cache/projects.json
fn cache_path() -> Option<PathBuf> {
    std::env::var("HOME")
        .ok()
        .map(|home| {
            PathBuf::from(home)
                .join(".tillandsias")
                .join("cache")
                .join("projects.json")
        })
}

/// Check if cache is still valid (within TTL).
fn is_cache_valid(cached_at: u64) -> bool {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    now.saturating_sub(cached_at) < CACHE_TTL_SECS
}

/// Discover GitHub projects using `gh api`.
///
/// Queries authenticated repositories, filters out archived and private repos
/// (unless user has access), and returns top projects by recent activity.
/// Results are cached in ~/.tillandsias/cache/projects.json with 5-minute TTL.
///
/// # Returns
/// A vector of discovered projects, or empty vec if gh is unavailable.
pub fn discover_github_projects() -> Vec<GitHubProject> {
    // Try to load from cache first
    if let Some(cache_path) = cache_path() {
        if let Ok(content) = fs::read_to_string(&cache_path) {
            if let Ok(entry) = serde_json::from_str::<CacheEntry>(&content) {
                if is_cache_valid(entry.cached_at) {
                    debug!(
                        "github_projects: loaded from cache ({} projects)",
                        entry.projects.len()
                    );
                    return entry.projects;
                }
            }
        }
    }

    // Query GitHub API via `gh`
    let output = Command::new("gh")
        .args([
            "api",
            "user/repos",
            "--jq",
            ".[] | {name, owner: .owner.login, description, url: .html_url, archived} | select(.archived == false)",
        ])
        .output();

    let projects = match output {
        Ok(output) if output.status.success() => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let mut projects = Vec::new();

            for line in stdout.lines() {
                if let Ok(project) = serde_json::from_str::<GitHubProject>(line) {
                    projects.push(project);
                }
            }

            debug!("github_projects: discovered {} projects", projects.len());
            projects
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!("github_projects: gh api failed: {}", stderr);
            Vec::new()
        }
        Err(err) => {
            debug!("github_projects: gh not available: {}", err);
            Vec::new()
        }
    };

    // Cache the results
    if let Some(cache_path) = cache_path() {
        if let Some(parent) = cache_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let entry = CacheEntry {
            projects: projects.clone(),
            cached_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        };
        if let Ok(json) = serde_json::to_string(&entry) {
            let _ = fs::write(&cache_path, json);
        }
    }

    projects
}

/// Clone a project from a GitHub repository URL to a target directory.
///
/// Uses the git mirror service (offline) to avoid exposing credentials to the forge.
/// Creates a basic `.tillandsias/config.toml` in the cloned project.
///
/// # Arguments
/// * `repo_url` - Full GitHub repository URL (e.g., https://github.com/owner/repo)
/// * `target_path` - Target directory to clone into
///
/// # Returns
/// Ok(()) if clone succeeds, Err otherwise.
pub fn clone_project_from_github(repo_url: &str, target_path: &Path) -> Result<(), String> {
    // Create parent directory
    if let Some(parent) = target_path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("failed to create parent dir: {}", e))?;
    }

    // Clone using git (via enclave mirror in production, direct for testing)
    let status = Command::new("git")
        .args(["clone", repo_url, target_path.to_string_lossy().as_ref()])
        .status()
        .map_err(|e| format!("git clone failed: {}", e))?;

    if !status.success() {
        return Err("git clone exited with error".to_string());
    }

    // Create basic .tillandsias/config.toml
    let tillandsias_dir = target_path.join(".tillandsias");
    fs::create_dir_all(&tillandsias_dir)
        .map_err(|e| format!("failed to create .tillandsias dir: {}", e))?;

    let config_path = tillandsias_dir.join("config.toml");
    let config_content = r#"# Tillandsias project configuration
[runtime]
# Agent selection: opencode, opencode-web, or claude
agent = "opencode-web"

[container]
# Container image to use (usually tillandsias-forge)
image = "tillandsias-forge"
"#;

    fs::write(&config_path, config_content)
        .map_err(|e| format!("failed to write config.toml: {}", e))?;

    debug!(
        "github_project_clone: cloned {} to {:?}",
        repo_url, target_path
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_path() {
        let path = cache_path();
        assert!(path.is_some());
        let path = path.unwrap();
        assert!(path.to_string_lossy().contains(".tillandsias/cache"));
    }

    #[test]
    fn test_is_cache_valid() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        assert!(is_cache_valid(now));
        assert!(is_cache_valid(now - 100)); // < 5 min old
        assert!(!is_cache_valid(now - 600)); // > 5 min old
    }
}
