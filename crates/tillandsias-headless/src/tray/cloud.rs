// @trace spec:tray-ux, spec:remote-projects, spec:gh-auth-script
//! TTL-cached GitHub repo fetcher for the `☁️ Cloud >` submenu.
//!
//! The tray populates [`TrayUiState::cloud_projects`] by calling the shared
//! remote-project discovery helper in `tillandsias-core`. The fetch is
//! event-driven (tray launch, GitHubLogin success, AboutToShow on the Cloud
//! submenu) and gated by a 5-minute TTL so repeated menu opens don't re-hit
//! the GitHub API.
//!
//! Failure policy: if the containerized `gh` flow fails, the user isn't
//! authenticated, the network is down, or the JSON is malformed, the *previous*
//! list is kept and a warning is logged. We do NOT clear `cloud_projects` on
//! transient failures — the menu must stay usable when the laptop goes offline.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tillandsias_core::remote_projects;
use tracing::warn;

use super::{ProjectEntry, TrayUiState};

/// How long a successful fetch stays fresh before the next AboutToShow is
/// allowed to refetch.
pub(super) const CLOUD_TTL: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CloudRefreshOutcome {
    SkippedFresh,
    SkippedInFlight,
    UpdatedMenu,
    RefreshedUnchanged,
}

impl CloudRefreshOutcome {
    pub(super) fn menu_changed(self) -> bool {
        matches!(self, Self::UpdatedMenu)
    }
}

pub(super) fn cloud_refresh_due(state: &TrayUiState, force: bool) -> bool {
    if state.cloud_refresh_in_flight {
        return false;
    }
    force
        || state
            .last_fetched
            .map(|t| t.elapsed() >= CLOUD_TTL)
            .unwrap_or(true)
}

fn github_projects_to_entries(projects: Vec<remote_projects::GitHubProject>) -> Vec<ProjectEntry> {
    let mut entries: Vec<ProjectEntry> = projects
        .into_iter()
        .map(|project| ProjectEntry {
            name: project.name.clone(),
            path: PathBuf::new(),
            full_name: Some(format!("{}/{}", project.owner, project.name)),
        })
        .collect();
    entries.sort_by(|a, b| {
        a.full_name
            .as_deref()
            .unwrap_or(&a.name)
            .cmp(b.full_name.as_deref().unwrap_or(&b.name))
    });
    entries
}

/// Refresh `state.cloud_projects` if the TTL has expired (or `force` is set).
///
/// Returns a [`CloudRefreshOutcome`] on success or when no work was done;
/// returns `Err(reason)` only when the containerized gh invocation failed and
/// the caller should surface it. Either way `cloud_projects` is left untouched
/// on failure so the menu doesn't flicker into `(no repos)`.
pub(super) fn refresh_cloud_projects_if_stale(
    state: Arc<Mutex<TrayUiState>>,
    force: bool,
    debug: bool,
) -> Result<CloudRefreshOutcome, String> {
    {
        let mut guard = state
            .lock()
            .map_err(|err| format!("state lock poisoned: {err}"))?;
        if guard.cloud_refresh_in_flight {
            if debug {
                warn!("cloud refresh skipped: refresh already in flight");
            }
            return Ok(CloudRefreshOutcome::SkippedInFlight);
        }
        if !cloud_refresh_due(&guard, force) {
            if debug {
                warn!("cloud refresh skipped: TTL fresh");
            }
            return Ok(CloudRefreshOutcome::SkippedFresh);
        }
        guard.cloud_refresh_in_flight = true;
    }

    let result = remote_projects::discover_github_projects_result_with_debug(debug);
    let entries = match result {
        Ok(projects) => {
            // Successful fetch -> reset the one-shot "no secret" warning so
            // the next time the user logs out / rotates the token we'll
            // re-warn cleanly. @trace spec:remote-projects
            if let Ok(mut guard) = state.lock() {
                guard.cloud_no_secret_warned = false;
            }
            github_projects_to_entries(projects)
        }
        Err(err) => {
            clear_cloud_refresh_in_flight(&state);
            // Friendly path for the "no podman secret" case which fires
            // every time on first launch before `tillandsias --github-login`
            // has been run. AboutToShow can refresh from several entry
            // points (initial fetch, root-menu, Cloud submenu) — gate the
            // user-facing line behind a per-session one-shot flag so the
            // stderr isn't spammed.
            //
            // We match on the secret *name* rather than the full podman
            // error text because podman's exact wording has churned
            // ("no secret with name or id", "no such secret", etc.) but the
            // name `tillandsias-github-token` is stable.
            //
            // @trace spec:remote-projects, spec:tray-ux
            if err.contains("tillandsias-github-token") {
                let should_warn = match state.lock() {
                    Ok(mut guard) => {
                        let first = !guard.cloud_no_secret_warned;
                        guard.cloud_no_secret_warned = true;
                        first
                    }
                    Err(_) => true,
                };
                if should_warn {
                    eprintln!(
                        "[tillandsias] cloud refresh: no GitHub credentials yet — \
                         run `tillandsias --github-login` to enable cloud projects"
                    );
                }
                // Keep tracing channel intact for log scrapers but stay
                // off stderr so the user gets exactly one helpful line.
                warn!(
                    error = %err,
                    "cloud refresh: github secret missing; preserving cached list"
                );
                return Err(err);
            }
            eprintln!("[tillandsias] cloud refresh: gh invocation failed: {err}");
            warn!(
                error = %err,
                "cloud refresh: gh invocation failed; preserving cached list"
            );
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
    let menu_changed = guard.last_fetched.is_none() || guard.cloud_projects != entries;
    guard.cloud_projects = entries;
    guard.last_fetched = Some(Instant::now());
    guard.cloud_refresh_in_flight = false;
    if menu_changed {
        guard.bump_revision();
        Ok(CloudRefreshOutcome::UpdatedMenu)
    } else {
        Ok(CloudRefreshOutcome::RefreshedUnchanged)
    }
}

fn clear_cloud_refresh_in_flight(state: &Arc<Mutex<TrayUiState>>) {
    if let Ok(mut guard) = state.lock() {
        guard.cloud_refresh_in_flight = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration as StdDuration;

    fn fixture_state(
        cloud: Vec<ProjectEntry>,
        last_fetched: Option<Instant>,
    ) -> Arc<Mutex<TrayUiState>> {
        let mut state = TrayUiState::new(
            std::path::PathBuf::from("/tmp/tillandsias-cloud-test"),
            "0.0.0".to_string(),
            Vec::new(),
        );
        state.cloud_projects = cloud;
        state.last_fetched = last_fetched;
        state.cloud_refresh_in_flight = false;
        Arc::new(Mutex::new(state))
    }

    #[test]
    fn cloud_projects_map_into_menu_entries() {
        let projects = vec![remote_projects::GitHubProject {
            name: "forge".to_string(),
            owner: "8007342".to_string(),
            description: None,
            url: "https://github.com/8007342/forge".to_string(),
            archived: false,
        }];
        let entries = github_projects_to_entries(projects);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "forge");
        assert_eq!(entries[0].full_name.as_deref(), Some("8007342/forge"));
        assert!(entries[0].path.as_os_str().is_empty());
    }

    #[test]
    fn cloud_refresh_skips_when_ttl_fresh() {
        let cached = vec![ProjectEntry {
            name: "cached".to_string(),
            path: PathBuf::new(),
            full_name: Some("user/cached".to_string()),
        }];
        let fresh = Instant::now() - StdDuration::from_secs(10);
        let state = fixture_state(cached.clone(), Some(fresh));

        let result = refresh_cloud_projects_if_stale(state.clone(), false, false);
        assert_eq!(result, Ok(CloudRefreshOutcome::SkippedFresh));

        let guard = state.lock().expect("test state lock");
        assert_eq!(guard.cloud_projects.len(), 1);
        assert_eq!(guard.cloud_projects[0].name, "cached");
        assert_eq!(guard.last_fetched, Some(fresh));
        assert!(!guard.cloud_refresh_in_flight);
    }

    #[test]
    fn cloud_refresh_skips_when_refresh_already_in_flight() {
        let state = fixture_state(Vec::new(), None);
        {
            let mut guard = state.lock().expect("test state lock");
            guard.cloud_refresh_in_flight = true;
        }

        let result = refresh_cloud_projects_if_stale(state.clone(), false, false);
        assert_eq!(result, Ok(CloudRefreshOutcome::SkippedInFlight));

        let guard = state.lock().expect("test state lock");
        assert!(guard.cloud_refresh_in_flight);
    }
}
