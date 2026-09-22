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

use crate::remote_projects;
use tracing::warn;

use super::{ProjectEntry, TrayUiState};
use tillandsias_host_shell::menu_state as host_shell_menu;

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
    // IMPORTANT: do NOT sort alphabetically here. `gh api user/repos?sort=pushed`
    // returns the user's repos newest-activity first, which puts the user's
    // active work at the top of the menu. Re-sorting alphabetically would
    // surface stale archived repos there instead.
    //
    // The reason used to be a truncation — "the tray cap trims the *tail* of
    // this list" — and that is no longer why (2026-09-21: the menu shows every
    // project). The ORDER still matters for two reasons that survive: it decides
    // what the user reads first in a long scrolling list, and it decides what
    // lands on page one if `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` is ever set. Left
    // explicit because a rule whose stated reason expires is a rule someone
    // deletes as obsolete — correctly, by the comment, and wrongly, in fact.
    // @trace spec:tray-ux, spec:remote-projects
    projects
        .into_iter()
        .map(|project| ProjectEntry {
            name: project.name.clone(),
            path: PathBuf::new(),
            full_name: Some(format!("{}/{}", project.owner, project.name)),
        })
        .collect()
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

    // From here on, the in-flight latch is released no matter how we exit.
    let _flight = InFlightGuard {
        state: state.clone(),
    };

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
            // `_flight` (InFlightGuard) clears the latch on return.
            // Friendly path for the "no Vault credential" case which fires
            // every time on first launch before `tillandsias --github-login`
            // has been run. AboutToShow can refresh from several entry
            // points (initial fetch, root-menu, Cloud submenu) — gate the
            // user-facing line behind a per-session one-shot flag so the
            // stderr isn't spammed.
            //
            // Match the stable Vault vocabulary rather than exact transport
            // wording so unavailable Vault, missing token, and policy failures
            // all share the same one-shot login guidance.
            //
            // @trace spec:remote-projects, spec:tray-ux
            if err.to_ascii_lowercase().contains("vault") {
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
    // Surface the menu page size so the behaviour is observable from logs even
    // when the user has no GUI session.
    //
    // THIS LINE USED TO LIE, TWICE (operator measurement 2026-09-21). It read
    // "showing {cap} of {n} cloud projects (rest behind overflow item)" and was
    // printed whenever `n > 10`. Both halves were false on the shipping build:
    // the live builder is `host_shell::menu_state::build`, which since 591-33s6
    // fans the remainder out into further pages rather than putting it "behind"
    // anything, and since the flat default it shows ALL of them — while the cap
    // this line read comes from `resolved_max_cloud_projects_in_menu`, whose only
    // caller is the builder 628-p5tj retired. So the log described a truncation
    // that was not happening, using a number the menu did not consult.
    //
    // A log line is an instrument. This one would have reported "showing 10 of
    // 22" on the very run the operator used to discover the menu shows 22, and
    // anyone trusting it would have gone looking for a trim that does not exist.
    // @trace spec:tray-ux
    match host_shell_menu::resolved_cloud_page_size() {
        Some(page) if entries.len() > page => eprintln!(
            "[tillandsias] tray: paging {} cloud projects {} per level \
             (TILLANDSIAS_MAX_CLOUD_MENU_ITEMS={})",
            entries.len(),
            page,
            page
        ),
        _ => eprintln!(
            "[tillandsias] tray: showing all {} cloud projects at one level",
            entries.len()
        ),
    }
    if debug {
        warn!("cloud refresh: parsed {} repos", entries.len());
    }

    // 1031-q4pb: record these labels as the cloud half of the order-505
    // validation set. THIS SITE ONLY, and the reason is 731-eupn: every earlier
    // return from this function is an error path, so reaching here means the
    // fetch actually SUCCEEDED and `entries` is an answer rather than the empty
    // placeholder of a failed query. Persisting a failed fetch would erase the
    // known set and deny every launch on the host until the next success —
    // 731-eupn's bug with teeth rather than merely a misleading menu.
    //
    // A write failure is logged, never propagated: this is a cache that makes
    // validation possible offline, and failing the whole cloud refresh because
    // a state directory is unwritable would trade a security improvement for an
    // availability regression.
    let cloud_labels: Vec<String> = entries.iter().map(|e| e.name.clone()).collect();
    if let Err(err) = crate::local_projects::persist_cloud_labels(&cloud_labels) {
        warn!(
            "cloud refresh: could not persist {} project labels for order-505 validation: {err}",
            cloud_labels.len()
        );
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

/// RAII guard that guarantees `cloud_refresh_in_flight` is cleared on *every*
/// exit from a refresh — normal return, early `?`, error branch, or panic.
///
/// Without this, any path that sets the in-flight latch but fails to clear it
/// (e.g. a fetch that hangs, or a future early-return) permanently suppresses
/// all later refreshes (`cloud_refresh_due` returns `false` while in-flight),
/// freezing the ☁️ Cloud submenu on `(loading…)`.
/// @trace spec:tray-ux, spec:remote-projects
struct InFlightGuard {
    state: Arc<Mutex<TrayUiState>>,
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        clear_cloud_refresh_in_flight(&self.state);
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
