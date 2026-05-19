// @trace spec:tray-ux, spec:remote-projects, spec:gh-auth-script
//! TTL-cached GitHub repo fetcher for the `☁️ Cloud >` submenu.
//!
//! The tray populates [`TrayUiState::cloud_projects`] by shelling out to the
//! user's `gh` CLI. The fetch is event-driven (tray launch, GitHubLogin
//! success, AboutToShow on the Cloud submenu) and gated by a 5-minute TTL so
//! repeated menu opens don't re-hit the GitHub API.
//!
//! Failure policy: if `gh` is missing, the user isn't authenticated, the
//! network is down, or the JSON is malformed, the *previous* list is kept and
//! a warning is logged. We do NOT clear `cloud_projects` on transient
//! failures — the menu must stay usable when the laptop goes offline.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use tokio::process::Command;
use tokio::runtime::Builder;
use tokio::time::timeout;
use tracing::warn;

use super::{ProjectEntry, TrayUiState};

/// How long a successful `gh` fetch stays fresh before the next AboutToShow
/// is allowed to refetch. Matches the budget called out in the change spec.
pub(super) const CLOUD_TTL: Duration = Duration::from_secs(300);

/// Hard wall-clock cap on the `gh` invocation. Anything beyond this is treated
/// as a soft failure — the previous list survives.
const GH_TIMEOUT: Duration = Duration::from_secs(5);

/// Shape of one repo entry in `gh api user/repos`. We deserialize only the
/// fields we surface in the menu; everything else is dropped on the floor.
#[derive(Debug, Deserialize)]
struct GhRepo {
    name: String,
    full_name: String,
}

/// Refresh `state.cloud_projects` if the TTL has expired (or `force` is set).
///
/// Returns `Ok(())` on success or when the TTL is fresh and no work was done;
/// returns `Err(reason)` only when the gh invocation failed *and* the caller
/// should surface it. Either way `cloud_projects` is left untouched on
/// failure so the menu doesn't flicker into `(no repos)`.
///
/// Run this from the [`AsyncTaskExecutor`], never from the GTK / D-Bus event
/// loop — it blocks on `gh` for up to [`GH_TIMEOUT`].
pub(super) fn refresh_cloud_projects_if_stale(
    state: Arc<Mutex<TrayUiState>>,
    force: bool,
    debug: bool,
) -> Result<(), String> {
    // TTL gate — read the timestamp without holding the lock across the gh
    // shell-out.
    let needs_fetch = {
        let guard = state
            .lock()
            .map_err(|err| format!("state lock poisoned: {err}"))?;
        force
            || guard
                .last_fetched
                .map(|t| t.elapsed() >= CLOUD_TTL)
                .unwrap_or(true)
    };
    if !needs_fetch {
        if debug {
            warn!("cloud refresh skipped: TTL fresh");
        }
        return Ok(());
    }

    // Off-thread tokio runtime for the gh invocation. We deliberately spin up
    // a current-thread runtime here rather than reaching for the global tray
    // runtime to keep this helper standalone and easy to test.
    let runtime = Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| format!("failed to build tokio runtime: {err}"))?;

    let raw = match runtime.block_on(fetch_gh_repos_raw()) {
        Ok(bytes) => bytes,
        Err(err) => {
            // Surface to stderr unconditionally — the tray's global tracing
            // subscriber routes everything to a log file, so without an
            // eprintln the user sees "(loading…)" forever with no clue why.
            eprintln!("[tillandsias] cloud refresh: gh invocation failed: {err}");
            warn!(error = %err, "cloud refresh: gh invocation failed; preserving cached list");
            return Err(err);
        }
    };

    let entries = match parse_gh_repos(&raw) {
        Ok(entries) => entries,
        Err(err) => {
            eprintln!("[tillandsias] cloud refresh: failed to parse gh output: {err}");
            warn!(error = %err, "cloud refresh: failed to parse gh output; preserving cached list");
            return Err(err);
        }
    };

    eprintln!(
        "[tillandsias] cloud refresh: loaded {} repos from gh",
        entries.len()
    );
    if debug {
        warn!("cloud refresh: parsed {} repos", entries.len());
    }

    let mut guard = state
        .lock()
        .map_err(|err| format!("state lock poisoned: {err}"))?;
    guard.cloud_projects = entries;
    guard.last_fetched = Some(Instant::now());
    guard.bump_revision();
    Ok(())
}

/// Shell out to `gh api user/repos` and return raw stdout bytes. Errors out
/// on non-zero exit, timeout, or missing binary so the caller can keep the
/// cached list intact.
async fn fetch_gh_repos_raw() -> Result<Vec<u8>, String> {
    let fut = Command::new("gh")
        .args([
            "api",
            "user/repos?per_page=50&sort=pushed&type=owner",
            "--header",
            "Accept: application/vnd.github+json",
        ])
        .output();

    let output = timeout(GH_TIMEOUT, fut)
        .await
        .map_err(|_| format!("gh timed out after {}s", GH_TIMEOUT.as_secs()))?
        .map_err(|err| format!("failed to spawn gh: {err}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "gh exited with status {}: {}",
            output.status,
            stderr.trim()
        ));
    }
    Ok(output.stdout)
}

/// Parse the JSON array returned by `gh api user/repos` into the tray's
/// [`ProjectEntry`] representation. Cloud entries carry an empty `path` —
/// `handle_launch_cloud_project` synthesises `~/src/<name>` lazily.
pub(super) fn parse_gh_repos(raw: &[u8]) -> Result<Vec<ProjectEntry>, String> {
    let repos: Vec<GhRepo> =
        serde_json::from_slice(raw).map_err(|err| format!("invalid gh JSON: {err}"))?;
    Ok(repos
        .into_iter()
        .map(|r| ProjectEntry {
            name: r.name,
            path: PathBuf::new(),
            full_name: Some(r.full_name),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration as StdDuration;

    fn fixture_state(
        cloud: Vec<ProjectEntry>,
        last_fetched: Option<Instant>,
    ) -> Arc<Mutex<TrayUiState>> {
        // Reuse the production constructor so we never drift from real state
        // shape. The side-effecting probes inside it (gh auth, podman) are
        // best-effort and tolerate missing binaries.
        let mut state = TrayUiState::new(
            std::path::PathBuf::from("/tmp/tillandsias-cloud-test"),
            "0.0.0".to_string(),
            Vec::new(),
        );
        state.cloud_projects = cloud;
        state.last_fetched = last_fetched;
        Arc::new(Mutex::new(state))
    }

    #[test]
    fn cloud_fetch_parses_gh_api_output_into_project_entries() {
        let raw = br#"[
            {"name":"forge","full_name":"8007342/forge","private":false},
            {"name":"tillandsias","full_name":"8007342/tillandsias","private":false}
        ]"#;
        let entries = parse_gh_repos(raw).expect("parse should succeed");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "forge");
        assert_eq!(entries[0].full_name.as_deref(), Some("8007342/forge"));
        assert!(entries[0].path.as_os_str().is_empty());
        assert_eq!(entries[1].name, "tillandsias");
        assert_eq!(entries[1].full_name.as_deref(), Some("8007342/tillandsias"));
    }

    #[test]
    fn cloud_fetch_rejects_invalid_json() {
        // Malformed JSON must surface as Err so the caller keeps the cache.
        let raw = br#"{not json"#;
        assert!(parse_gh_repos(raw).is_err());
    }

    #[test]
    fn cloud_refresh_skips_when_ttl_fresh() {
        // A `last_fetched` that's well inside the TTL window must short-circuit
        // the entire refresh path — the cloud list and timestamp are left
        // exactly as they were.
        let cached = vec![ProjectEntry {
            name: "cached".to_string(),
            path: PathBuf::new(),
            full_name: Some("user/cached".to_string()),
        }];
        let fresh = Instant::now() - StdDuration::from_secs(10);
        let state = fixture_state(cached.clone(), Some(fresh));

        // Should be Ok(()) and a no-op. Even if `gh` isn't installed on the
        // test host we must not invoke it.
        let result = refresh_cloud_projects_if_stale(state.clone(), false, false);
        assert!(result.is_ok());

        let guard = state.lock().expect("test state lock");
        assert_eq!(guard.cloud_projects.len(), 1);
        assert_eq!(guard.cloud_projects[0].name, "cached");
        assert_eq!(guard.last_fetched, Some(fresh));
    }

    #[test]
    fn cloud_refresh_preserves_list_on_gh_failure() {
        // Point at a binary that always errors so the failure branch is
        // exercised without needing to mock `gh`. The pre-existing
        // `cloud_projects` list must survive untouched.
        let cached = vec![ProjectEntry {
            name: "kept".to_string(),
            path: PathBuf::new(),
            full_name: Some("user/kept".to_string()),
        }];
        let state = fixture_state(cached, None);

        // Force a fresh fetch with PATH stripped so `gh` isn't found. We do
        // this in a scoped block so we restore PATH for the rest of the run.
        let original_path = std::env::var_os("PATH");
        // SAFETY: unit-test only, single-threaded by virtue of cargo test
        // scheduling. We restore PATH below.
        unsafe { std::env::set_var("PATH", "/nonexistent-tillandsias-test-path") };
        let result = refresh_cloud_projects_if_stale(state.clone(), true, false);
        if let Some(path) = original_path {
            unsafe { std::env::set_var("PATH", path) };
        } else {
            unsafe { std::env::remove_var("PATH") };
        }

        assert!(result.is_err(), "gh missing must surface as Err");

        let guard = state.lock().expect("test state lock");
        assert_eq!(guard.cloud_projects.len(), 1, "cached list must survive");
        assert_eq!(guard.cloud_projects[0].name, "kept");
        assert!(
            guard.last_fetched.is_none(),
            "last_fetched must NOT advance on failure (cached state was None)"
        );
    }
}
