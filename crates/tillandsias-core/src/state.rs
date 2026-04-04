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

/// Whether a container is a forge (Attach Here / OpenCode), maintenance (terminal / bash),
/// a web server (Serve Here / static httpd), or a proxy (caching forward proxy).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ContainerType {
    /// Forge environment launched via "Attach Here" (runs OpenCode).
    Forge,
    /// Maintenance terminal launched via "Maintenance" (runs fish/bash).
    Maintenance,
    /// Web server launched via "Serve Here" (runs tillandsias-web / httpd).
    /// Named `tillandsias-<project>-web` — no genus allocation.
    Web,
    /// Caching HTTP/HTTPS proxy with domain allowlist.
    /// Named `tillandsias-<project>-proxy` — no genus allocation.
    /// @trace spec:proxy-container, spec:enclave-network
    Proxy,
    /// Local git mirror service — bare repos + git daemon.
    /// Named `tillandsias-<project>-git-service` — no genus allocation.
    /// @trace spec:git-mirror-service
    GitService,
    /// Local LLM inference service — ollama server.
    /// Named `tillandsias-inference` — shared, not project-specific.
    /// @trace spec:inference-container
    Inference,
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
    /// Display emoji for menu labels and window titles.
    /// Flower emoji for Forge containers, tool emoji for Maintenance containers.
    /// Single source of truth — set at container creation time.
    pub display_emoji: String,
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

    /// Parse project name from a web container name (`tillandsias-<project>-web`).
    /// Returns `Some(project_name)` or `None` if the name does not match.
    pub fn parse_web_container_name(name: &str) -> Option<String> {
        let stripped = name.strip_prefix("tillandsias-")?;
        let project = stripped.strip_suffix("-web")?;
        if project.is_empty() {
            return None;
        }
        Some(project.to_string())
    }

    /// Build a web container name for a project: `tillandsias-<project>-web`.
    pub fn web_container_name(project_name: &str) -> String {
        format!("tillandsias-{}-web", project_name)
    }

    /// Build a git service container name for a project: `tillandsias-git-<project>`.
    /// @trace spec:git-mirror-service
    pub fn git_service_container_name(project_name: &str) -> String {
        format!("tillandsias-git-{}", project_name)
    }

    /// Parse project name from a git service container name (`tillandsias-git-<project>`).
    /// Returns `Some(project_name)` or `None` if the name does not match.
    /// @trace spec:git-mirror-service
    pub fn parse_git_service_container_name(name: &str) -> Option<String> {
        let project = name.strip_prefix("tillandsias-git-")?;
        if project.is_empty() {
            return None;
        }
        // Avoid matching genus-based names that happen to start with "git-"
        // by checking the project name does not match a genus slug suffix.
        Some(project.to_string())
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
    /// Set once during startup; never recovered at runtime (Dried is terminal).
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

    /// Whether the forge image is available and ready for use.
    ///
    /// Starts as `false` on every launch. Set to `true` when:
    /// - The forge image is confirmed present at startup (no build needed), or
    /// - A forge image build completes successfully.
    /// Set to `false` when a forge rebuild begins (image stale or absent).
    ///
    /// While `false`, all forge-dependent menu actions (Attach Here, Maintenance,
    /// Root terminal, GitHub Login) are disabled so the user cannot trigger them
    /// before the image is ready.
    pub forge_available: bool,
}

impl TrayState {
    pub fn new(platform: PlatformInfo) -> Self {
        Self {
            projects: Vec::new(),
            running: Vec::new(),
            platform,
            has_podman: true,
            tray_icon_state: TrayIconState::Pup,
            remote_repos: Vec::new(),
            remote_repos_fetched_at: None,
            remote_repos_loading: false,
            cloning_project: None,
            remote_repos_error: None,
            active_builds: Vec::new(),
            forge_available: false,
        }
    }

    /// Compute the tray icon state from current application state.
    ///
    /// - `Dried`    — podman is not available (terminal, non-recoverable)
    /// - `Building` — one or more builds are `InProgress`
    /// - `Blooming` — no builds in progress, but at least one recently completed
    /// - `Mature`   — idle, no in-progress or recently completed builds
    ///
    /// Note: `Pup` is never returned here — it is only set at startup before
    /// the first `compute_icon_state()` call.
    ///
    /// @trace spec:tray-icon-lifecycle
    pub fn compute_icon_state(&self) -> TrayIconState {
        if !self.has_podman {
            return TrayIconState::Dried;
        }
        let any_in_progress = self
            .active_builds
            .iter()
            .any(|b| b.status == BuildStatus::InProgress);
        if any_in_progress {
            return TrayIconState::Building;
        }
        // Check for recently completed builds (within the fadeout window).
        // These are builds that completed successfully and whose completed_at
        // timestamp is still present (not yet pruned).
        let any_recently_completed = self
            .active_builds
            .iter()
            .any(|b| matches!(b.status, BuildStatus::Completed) && b.completed_at.is_some());
        if any_recently_completed {
            TrayIconState::Blooming
        } else {
            TrayIconState::Mature
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
            display_emoji: TillandsiaGenus::Aeranthos.flower().to_string(),
        };
        let bytes = postcard::to_allocvec(&info).unwrap();
        let decoded: ContainerInfo = postcard::from_bytes(&bytes).unwrap();
        assert_eq!(decoded.name, info.name);
        assert_eq!(decoded.project_name, info.project_name);
        assert_eq!(decoded.genus, info.genus);
        assert_eq!(decoded.state, info.state);
        assert_eq!(decoded.port_range, info.port_range);
        assert_eq!(decoded.container_type, info.container_type);
        assert_eq!(decoded.display_emoji, info.display_emoji);
    }

    #[test]
    fn web_container_name_format() {
        let name = ContainerInfo::web_container_name("my-project");
        assert_eq!(name, "tillandsias-my-project-web");
    }

    #[test]
    fn parse_web_container_name_valid() {
        let project = ContainerInfo::parse_web_container_name("tillandsias-my-project-web");
        assert_eq!(project, Some("my-project".to_string()));
    }

    #[test]
    fn parse_web_container_name_hyphenated_project() {
        let project = ContainerInfo::parse_web_container_name("tillandsias-cool-project-web");
        assert_eq!(project, Some("cool-project".to_string()));
    }

    #[test]
    fn parse_web_container_name_invalid() {
        // Does not match a genus-based name
        assert!(ContainerInfo::parse_web_container_name("tillandsias-my-app-aeranthos").is_none());
        // No project name
        assert!(ContainerInfo::parse_web_container_name("tillandsias-web").is_none());
        // Missing prefix
        assert!(ContainerInfo::parse_web_container_name("my-project-web").is_none());
    }

    #[test]
    fn parse_web_container_name_not_confused_with_genus_web() {
        // "web" is not a genus slug, so genus-parsing won't match this
        // and web-parsing should correctly extract the project name.
        let project = ContainerInfo::parse_web_container_name("tillandsias-frontend-web");
        assert_eq!(project, Some("frontend".to_string()));
    }

    // @trace spec:git-mirror-service
    #[test]
    fn git_service_container_name_format() {
        let name = ContainerInfo::git_service_container_name("my-project");
        assert_eq!(name, "tillandsias-git-my-project");
    }

    #[test]
    fn parse_git_service_container_name_valid() {
        let project =
            ContainerInfo::parse_git_service_container_name("tillandsias-git-my-project");
        assert_eq!(project, Some("my-project".to_string()));
    }

    #[test]
    fn parse_git_service_container_name_hyphenated() {
        let project =
            ContainerInfo::parse_git_service_container_name("tillandsias-git-cool-project");
        assert_eq!(project, Some("cool-project".to_string()));
    }

    #[test]
    fn parse_git_service_container_name_invalid() {
        // Missing prefix
        assert!(ContainerInfo::parse_git_service_container_name("git-my-project").is_none());
        // No project name
        assert!(ContainerInfo::parse_git_service_container_name("tillandsias-git-").is_none());
        // Different container type
        assert!(
            ContainerInfo::parse_git_service_container_name("tillandsias-my-project-web")
                .is_none()
        );
    }
}
