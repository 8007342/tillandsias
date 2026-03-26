use std::time::Instant;

use crate::event::ContainerState;
use crate::genus::{PlantLifecycle, TillandsiaGenus, TrayIconState};
use crate::project::Project;

/// Status of an image or maintenance build tracked in the tray menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildStatus {
    /// Build is currently in progress.
    InProgress,
    /// Build completed successfully.
    Completed,
    /// Build failed with the given reason.
    Failed(String),
}

/// Tracks an active or recently completed image/maintenance build for menu display.
///
/// Entries are pruned from `TrayState::active_builds` when they have been
/// `Completed` for more than 10 seconds. Failed entries persist until a new
/// build attempt begins for the same image.
#[derive(Debug, Clone)]
pub struct BuildProgress {
    /// Short name displayed in the menu chip (e.g. `"forge"` or `"Maintenance"`).
    pub image_name: String,
    /// Current status.
    pub status: BuildStatus,
    /// When the build was started.
    pub started_at: Instant,
    /// When the build completed (success or failure). `None` while in progress.
    pub completed_at: Option<Instant>,
}

/// Whether a container is a forge (Attach Here / OpenCode) or maintenance (terminal / bash).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ContainerType {
    /// Forge environment launched via "Attach Here" (runs OpenCode).
    Forge,
    /// Maintenance terminal launched via "Maintenance" (runs fish/bash).
    Maintenance,
}

/// Info about a running container environment.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ContainerInfo {
    /// Full container name: tillandsias-<project>-<genus>
    pub name: String,
    /// Project this environment belongs to
    pub project_name: String,
    /// Assigned tillandsia genus
    pub genus: TillandsiaGenus,
    /// Current container state
    pub state: ContainerState,
    /// Allocated port range (start, end inclusive)
    pub port_range: (u16, u16),
    /// Whether this is a forge or maintenance container.
    pub container_type: ContainerType,
}

impl ContainerInfo {
    /// Build container name from project and genus.
    pub fn container_name(project_name: &str, genus: TillandsiaGenus) -> String {
        format!("tillandsias-{}-{}", project_name, genus.slug())
    }

    /// Parse project name and genus from a container name.
    pub fn parse_container_name(name: &str) -> Option<(String, TillandsiaGenus)> {
        let stripped = name.strip_prefix("tillandsias-")?;
        // Find the last hyphen-delimited segment that matches a genus slug.
        // Genus slugs can contain hyphens (e.g., "caput-medusae"), so try
        // matching from longest suffix first.
        for genus in TillandsiaGenus::ALL {
            let slug = genus.slug();
            if let Some(project) = stripped.strip_suffix(&format!("-{slug}"))
                && !project.is_empty()
            {
                return Some((project.to_string(), *genus));
            }
        }
        None
    }

    /// Current plant lifecycle state for icon rendering.
    pub fn lifecycle(&self) -> PlantLifecycle {
        PlantLifecycle::from_container_state(&self.state)
    }
}

/// Platform detection for cross-platform behavior.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PlatformInfo {
    pub os: Os,
    pub has_podman: bool,
    pub has_podman_machine: bool,
    pub gpu_devices: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Os {
    Linux,
    MacOS,
    Windows,
}

impl Os {
    pub fn detect() -> Self {
        if cfg!(target_os = "linux") {
            Self::Linux
        } else if cfg!(target_os = "macos") {
            Self::MacOS
        } else {
            Self::Windows
        }
    }

    pub fn needs_podman_machine(&self) -> bool {
        matches!(self, Self::MacOS | Self::Windows)
    }
}

/// Lightweight remote repo info for menu display.
/// Kept in core so TrayState can hold it; actual fetching lives in the tray crate.
#[derive(Debug, Clone)]
pub struct RemoteRepoInfo {
    /// Simple repository name (e.g., "tillandsias").
    pub name: String,
    /// Full owner/name (e.g., "8007342/tillandsias").
    pub full_name: String,
}

/// Cache TTL for remote repository list (5 minutes).
const REMOTE_REPOS_TTL_SECS: u64 = 300;

/// Full tray state rebuilt on every event.
#[derive(Debug, Clone)]
pub struct TrayState {
    pub projects: Vec<Project>,
    pub running: Vec<ContainerInfo>,
    pub platform: PlatformInfo,

    /// Whether podman was reachable at launch.
    /// Set once during startup; never recovered at runtime (Decay is terminal).
    pub has_podman: bool,

    /// Current tray icon state — updated by `compute_icon_state()`.
    pub tray_icon_state: TrayIconState,

    /// Cached list of remote GitHub repos (fetched via `gh repo list`).
    pub remote_repos: Vec<RemoteRepoInfo>,
    /// When the remote repo list was last fetched.
    pub remote_repos_fetched_at: Option<Instant>,
    /// True while a background fetch is in progress.
    pub remote_repos_loading: bool,
    /// If a clone is in progress, holds the repo name being cloned.
    pub cloning_project: Option<String>,
    /// Error message from the last fetch attempt, if any.
    pub remote_repos_error: Option<String>,

    /// Active or recently completed image/maintenance builds shown as menu chips.
    /// Completed entries are pruned after 10 seconds; failed entries persist until
    /// a new build for the same image begins.
    pub active_builds: Vec<BuildProgress>,
}

impl TrayState {
    pub fn new(platform: PlatformInfo) -> Self {
        Self {
            projects: Vec::new(),
            running: Vec::new(),
            platform,
            has_podman: true,
            tray_icon_state: TrayIconState::Base,
            remote_repos: Vec::new(),
            remote_repos_fetched_at: None,
            remote_repos_loading: false,
            cloning_project: None,
            remote_repos_error: None,
            active_builds: Vec::new(),
        }
    }

    /// Compute the tray icon state from current application state.
    ///
    /// - `Decay`    — podman is not available (terminal, non-recoverable)
    /// - `Building` — one or more builds are `InProgress`
    /// - `Base`     — idle, no in-progress builds
    pub fn compute_icon_state(&self) -> TrayIconState {
        if !self.has_podman {
            return TrayIconState::Decay;
        }
        let any_in_progress = self
            .active_builds
            .iter()
            .any(|b| b.status == BuildStatus::InProgress);
        if any_in_progress {
            TrayIconState::Building
        } else {
            TrayIconState::Base
        }
    }

    /// Returns true if the remote repos cache is stale (older than 5 minutes) or empty.
    pub fn remote_repos_cache_stale(&self) -> bool {
        match self.remote_repos_fetched_at {
            Some(fetched_at) => fetched_at.elapsed().as_secs() >= REMOTE_REPOS_TTL_SECS,
            None => true,
        }
    }

    /// Invalidate the remote repos cache (e.g., after GitHub login).
    pub fn invalidate_remote_repos_cache(&mut self) {
        self.remote_repos_fetched_at = None;
        self.remote_repos.clear();
        self.remote_repos_error = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::genus::TillandsiaGenus;

    #[test]
    fn container_name_format() {
        let name = ContainerInfo::container_name("my-app", TillandsiaGenus::Aeranthos);
        assert_eq!(name, "tillandsias-my-app-aeranthos");
    }

    #[test]
    fn parse_container_name_simple() {
        let (project, genus) =
            ContainerInfo::parse_container_name("tillandsias-my-app-aeranthos").unwrap();
        assert_eq!(project, "my-app");
        assert_eq!(genus, TillandsiaGenus::Aeranthos);
    }

    #[test]
    fn parse_container_name_hyphenated_genus() {
        let (project, genus) =
            ContainerInfo::parse_container_name("tillandsias-cool-project-caput-medusae").unwrap();
        assert_eq!(project, "cool-project");
        assert_eq!(genus, TillandsiaGenus::CaputMedusae);
    }

    #[test]
    fn parse_container_name_invalid() {
        assert!(ContainerInfo::parse_container_name("random-container").is_none());
        assert!(ContainerInfo::parse_container_name("tillandsias-").is_none());
    }

    #[test]
    fn postcard_roundtrip_container_info() {
        let info = ContainerInfo {
            name: "tillandsias-my-app-aeranthos".to_string(),
            project_name: "my-app".to_string(),
            genus: TillandsiaGenus::Aeranthos,
            state: crate::event::ContainerState::Running,
            port_range: (3000, 3019),
            container_type: ContainerType::Forge,
        };
        let bytes = postcard::to_allocvec(&info).unwrap();
        let decoded: ContainerInfo = postcard::from_bytes(&bytes).unwrap();
        assert_eq!(decoded.name, info.name);
        assert_eq!(decoded.project_name, info.project_name);
        assert_eq!(decoded.genus, info.genus);
        assert_eq!(decoded.state, info.state);
        assert_eq!(decoded.port_range, info.port_range);
        assert_eq!(decoded.container_type, info.container_type);
    }
}
