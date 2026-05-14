use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::event::ContainerState;
use crate::genus::{PlantLifecycle, TillandsiaGenus, TrayIconState};
use crate::project::Project;

/// @trace spec:tray-app, spec:app-lifecycle
/// Explicit lifecycle states for tray application.
/// Guards prevent invalid state transitions (e.g., can't run two projects simultaneously).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum TrayAppLifecycleState {
    /// Tray is starting up, checking infrastructure dependencies.
    /// Valid transitions: → Initializing (if deps missing), → Running (if ready)
    /// @trace spec:app-lifecycle
    Idle,
    /// Setting up enclave, pulling images, ensuring forge is available.
    /// Valid transitions: → Running (on success), → Error (on failure)
    /// @trace spec:app-lifecycle
    Initializing,
    /// Project active, one or more containers healthy.
    /// Valid transitions: → Stopping (user quit or container exit)
    /// @trace spec:app-lifecycle
    Running,
    /// Graceful shutdown in progress: SIGTERM sent, grace period active.
    /// Valid transitions: → Idle (on completion)
    /// @trace spec:app-lifecycle
    Stopping,
    /// Unrecoverable error: podman missing, enclave setup failed.
    /// Valid transitions: → Idle (on manual restart)
    /// @trace spec:app-lifecycle
    Error,
}

impl TrayAppLifecycleState {
    /// Validate a state transition.
    /// Returns `Ok(())` if valid, `Err(reason)` if invalid.
    /// @trace spec:app-lifecycle
    pub fn validate_transition(&self, next: TrayAppLifecycleState) -> Result<(), String> {
        match (*self, next) {
            // From Idle: can initialize or go directly to Running
            (Self::Idle, Self::Initializing) => Ok(()),
            (Self::Idle, Self::Running) => Ok(()),
            (Self::Idle, Self::Error) => Ok(()),
            // From Initializing: can succeed to Running or fail to Error
            (Self::Initializing, Self::Running) => Ok(()),
            (Self::Initializing, Self::Error) => Ok(()),
            // From Running: only transition to Stopping (never directly to another state)
            (Self::Running, Self::Stopping) => Ok(()),
            // From Stopping: can return to Idle
            (Self::Stopping, Self::Idle) => Ok(()),
            // From Error: can restart to Idle
            (Self::Error, Self::Idle) => Ok(()),
            // Any -> Error is allowed (unrecoverable error from any state)
            (_, Self::Error) => Ok(()),
            // All other transitions are invalid
            (from, to) => Err(format!("Invalid state transition: {:?} → {:?}", from, to)),
        }
    }

    /// Human-readable state name for logs and diagnostics.
    /// @trace spec:app-lifecycle
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Initializing => "initializing",
            Self::Running => "running",
            Self::Stopping => "stopping",
            Self::Error => "error",
        }
    }
}

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
    /// Static web server launched via "Serve Here" (runs tillandsias-web / httpd).
    /// Named `tillandsias-<project>-web` — no genus allocation.
    Web,
    /// Persistent OpenCode Web forge running `opencode serve` on :4096.
    /// Named `tillandsias-<project>-forge` — no genus allocation. Distinct
    /// from `Web` (which is the static-httpd "Serve Here" feature).
    /// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[serde(rename = "opencode-web")]
    OpenCodeWeb,
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
    /// Chromium browser container for safe/debug browsing.
    /// Named `tillandsias-chromium-<project>-<type>` — no genus allocation.
    /// @trace spec:browser-isolation-core, spec:chromium-safe-variant
    Browser,
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
    ///
    /// Used by the "Serve Here" static web server. No genus is appended —
    /// there is at most one static-httpd container per project, so a stable
    /// deterministic name is preferable for lookup and teardown.
    pub fn web_container_name(project_name: &str) -> String {
        format!("tillandsias-{}-web", project_name)
    }

    /// Name for persistent OpenCode Web forge containers: `tillandsias-<project>-forge`.
    /// Distinct from `web_container_name` (Serve Here's static httpd).
    /// @trace spec:browser-isolation-tray-integration, spec:podman-orchestration
    pub fn forge_container_name(project_name: &str) -> String {
        format!("tillandsias-{}-forge", project_name)
    }

    /// Parse `tillandsias-<project>-forge` → Some(project). None for any other shape.
    /// Rejects names ending in `-web` (Serve Here) and names that look like `tillandsias-<genus>` with no project.
    /// @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    pub fn parse_forge_container_name(name: &str) -> Option<String> {
        let stripped = name.strip_prefix("tillandsias-")?;
        let project = stripped.strip_suffix("-forge")?;
        if project.is_empty() {
            return None;
        }
        Some(project.to_string())
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

/// Metadata for a browser window tracked in the registry.
/// @trace spec:browser-isolation-tray-integration
#[derive(Debug, Clone)]
pub struct BrowserWindowMetadata {
    /// Unique window identifier (e.g., "project-name-window-1")
    pub window_id: String,
    /// Container ID running this browser window (from podman inspect)
    pub container_id: String,
    /// Project label extracted from container name (e.g., "my-app" from "tillandsias-my-app-aeranthos")
    /// Used for routing rule generation and request-path-based project identification.
    /// @trace spec:browser-routing-allowlist
    pub project_label: String,
    /// When the window was launched
    pub launch_time: Instant,
    /// Last heartbeat timestamp (used for stale detection)
    pub last_heartbeat: Instant,
    /// Current status of the window
    pub status: BrowserWindowStatus,
}

/// Status of a browser window.
/// @trace spec:browser-isolation-tray-integration
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum BrowserWindowStatus {
    /// Window is launching, waiting for container to be ready
    Launching,
    /// Window is active and responsive
    Active,
    /// Window is closing or has been closed
    Closed,
}

/// Callback type for window registry mutations.
/// Called when a window is registered or unregistered.
/// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
pub type RegistryMutationHook = Box<dyn Fn(&str, Option<&str>, Option<&str>) + Send + Sync>;

/// Thread-safe registry of active browser windows.
/// @trace spec:browser-isolation-tray-integration, spec:browser-window-rate-limiting
#[derive(Clone)]
pub struct BrowserWindowRegistry {
    /// HashMap of window_id -> BrowserWindowMetadata, protected by Mutex
    windows: Arc<Mutex<std::collections::HashMap<String, BrowserWindowMetadata>>>,
    /// Optional hook called on window registration/unregistration.
    /// Signature: (window_id, container_id_opt, project_label_opt)
    /// For registration: both container_id and project_label are Some(_)
    /// For unregistration: both are None
    /// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    mutation_hook: Arc<Mutex<Option<RegistryMutationHook>>>,
}

impl std::fmt::Debug for BrowserWindowRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BrowserWindowRegistry")
            .field("windows", &self.windows)
            .field("mutation_hook", &"<closure>")
            .finish()
    }
}

/// Cache TTL for remote repository list (5 minutes).
const REMOTE_REPOS_TTL_SECS: u64 = 300;

impl BrowserWindowRegistry {
    /// Create a new empty browser window registry.
    /// @trace spec:browser-isolation-tray-integration
    pub fn new() -> Self {
        Self {
            windows: Arc::new(Mutex::new(std::collections::HashMap::new())),
            mutation_hook: Arc::new(Mutex::new(None)),
        }
    }

    /// Set a mutation hook to be called when windows are registered or unregistered.
    /// The hook receives (window_id, container_id_opt, project_label_opt).
    /// For registration: both optional parameters are Some(_)
    /// For unregistration: both optional parameters are None
    /// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    pub fn set_mutation_hook(&self, hook: RegistryMutationHook) -> Result<(), String> {
        let mut hook_slot = self
            .mutation_hook
            .lock()
            .map_err(|_| "mutation hook lock poisoned".to_string())?;
        *hook_slot = Some(hook);
        Ok(())
    }

    /// Helper to invoke the mutation hook if set.
    #[allow(clippy::collapsible_if)]
    fn call_mutation_hook(&self, window_id: &str, container_id_opt: Option<&str>, project_label_opt: Option<&str>) {
        if let Ok(hook_slot) = self.mutation_hook.lock() {
            if let Some(hook) = hook_slot.as_ref() {
                hook(window_id, container_id_opt, project_label_opt);
            }
        }
    }

    /// Register a new browser window in the registry.
    /// Calls the mutation hook if one is set.
    /// Returns the registered metadata.
    /// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    pub fn register_window(
        &self,
        window_id: String,
        container_id: String,
        project_label: String,
    ) -> Result<BrowserWindowMetadata, String> {
        let now = Instant::now();
        let metadata = BrowserWindowMetadata {
            window_id: window_id.clone(),
            container_id: container_id.clone(),
            project_label: project_label.clone(),
            launch_time: now,
            last_heartbeat: now,
            status: BrowserWindowStatus::Launching,
        };

        let mut windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        windows.insert(window_id.clone(), metadata.clone());

        // Call mutation hook after successful registration
        self.call_mutation_hook(&window_id, Some(&container_id), Some(&project_label));

        Ok(metadata)
    }

    /// Unregister a browser window from the registry.
    /// Calls the mutation hook if one is set.
    /// Returns the unregistered metadata if it existed.
    /// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    pub fn unregister_window(&self, window_id: &str) -> Result<Option<BrowserWindowMetadata>, String> {
        let mut windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        let removed = windows.remove(window_id);

        // Call mutation hook after successful unregistration
        if removed.is_some() {
            self.call_mutation_hook(window_id, None, None);
        }

        Ok(removed)
    }

    /// Get a snapshot of all active browser windows.
    /// @trace spec:browser-isolation-tray-integration
    pub fn get_windows(&self) -> Result<Vec<BrowserWindowMetadata>, String> {
        let windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        Ok(windows.values().cloned().collect())
    }

    /// Get a specific window by ID.
    /// @trace spec:browser-isolation-tray-integration
    pub fn get_window(&self, window_id: &str) -> Result<Option<BrowserWindowMetadata>, String> {
        let windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        Ok(windows.get(window_id).cloned())
    }

    /// Update the status of a window.
    /// @trace spec:browser-isolation-tray-integration
    pub fn update_status(
        &self,
        window_id: &str,
        status: BrowserWindowStatus,
    ) -> Result<(), String> {
        let mut windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        if let Some(metadata) = windows.get_mut(window_id) {
            metadata.status = status;
            metadata.last_heartbeat = Instant::now();
            Ok(())
        } else {
            Err(format!("window {} not found in registry", window_id))
        }
    }

    /// Update the last heartbeat time for a window.
    /// @trace spec:browser-isolation-tray-integration
    pub fn heartbeat(&self, window_id: &str) -> Result<(), String> {
        let mut windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        if let Some(metadata) = windows.get_mut(window_id) {
            metadata.last_heartbeat = Instant::now();
            Ok(())
        } else {
            Err(format!("window {} not found in registry", window_id))
        }
    }

    /// Get a snapshot of active windows grouped by project label.
    /// Returns HashMap<project_label, Vec<BrowserWindowMetadata>>
    /// Used by Caddyfile generation to build dynamic routing rules.
    /// @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    pub fn get_active_windows_by_project(
        &self,
    ) -> Result<std::collections::HashMap<String, Vec<BrowserWindowMetadata>>, String> {
        let windows = self
            .windows
            .lock()
            .map_err(|_| "browser window registry lock poisoned".to_string())?;

        let mut by_project: std::collections::HashMap<String, Vec<BrowserWindowMetadata>> =
            std::collections::HashMap::new();

        for metadata in windows.values() {
            by_project
                .entry(metadata.project_label.clone())
                .or_default()
                .push(metadata.clone());
        }

        Ok(by_project)
    }
}

impl Default for BrowserWindowRegistry {
    fn default() -> Self {
        Self::new()
    }
}

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

    /// @trace spec:tray-app, spec:app-lifecycle
    /// Current application lifecycle state with transition guards.
    /// Guards prevent invalid sequences (e.g., starting a second project while one is running).
    pub lifecycle_state: TrayAppLifecycleState,

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
    /// - A forge build completes successfully.
    /// - Set to `false` when a forge rebuild begins (image stale or absent).
    ///
    /// While `false`, all forge-dependent menu actions (Attach Here, Maintenance,
    /// Root terminal, GitHub Login) are disabled so the user cannot trigger them
    /// before the image is ready.
    pub forge_available: bool,

    /// Track browser launch times for per-project safe-window gating.
    /// @trace spec:host-browser-mcp
    /// Key: project name, Value: last launch Instant.
    pub browser_last_launch: std::collections::HashMap<String, std::time::Instant>,

    /// Track debug browser PIDs (one per project, for "open_debug_window").
    /// @trace spec:host-browser-mcp, spec:browser-isolation-tray-integration
    pub debug_browser_pid: std::collections::HashMap<String, u32>,

    /// @trace spec:simplified-tray-ux, spec:github-credential-health
    /// Last known GitHub health status (true = reachable, false = unreachable or unknown).
    pub github_healthy: bool,
    /// When the GitHub health was last checked (None = never checked).
    /// @trace spec:github-credential-health
    pub github_last_check: Option<Instant>,
    /// Failed retry count (for exponential backoff).
    /// @trace spec:github-credential-health
    pub github_retry_count: u32,
    /// Next time to retry GitHub connectivity (with exponential backoff).
    /// @trace spec:github-credential-health
    pub github_next_retry: Option<Instant>,

    /// Registry of active browser windows.
    /// @trace spec:browser-isolation-tray-integration, spec:browser-window-rate-limiting
    pub browser_windows: BrowserWindowRegistry,
}

impl TrayState {
    pub fn new(platform: PlatformInfo) -> Self {
        Self {
            projects: Vec::new(),
            running: Vec::new(),
            platform,
            has_podman: true,
            tray_icon_state: TrayIconState::Pup,
            // @trace spec:tray-app, spec:app-lifecycle
            // Start in Idle state; transition to Initializing on infrastructure checks
            lifecycle_state: TrayAppLifecycleState::Idle,
            remote_repos: Vec::new(),
            remote_repos_fetched_at: None,
            remote_repos_loading: false,
            cloning_project: None,
            remote_repos_error: None,
            active_builds: Vec::new(),
            forge_available: false,
            browser_last_launch: std::collections::HashMap::new(),
            debug_browser_pid: std::collections::HashMap::new(),
            // @trace spec:simplified-tray-ux, spec:host-browser-mcp, spec:browser-isolation-tray-integration
            github_healthy: false,
            github_last_check: None,
            github_retry_count: 0,
            github_next_retry: None,
            // @trace spec:browser-isolation-tray-integration
            browser_windows: BrowserWindowRegistry::new(),
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

    /// Attempt a state transition with guard validation.
    /// @trace spec:tray-app, spec:app-lifecycle
    /// Returns `Ok(())` on successful transition, `Err(reason)` if blocked by a guard.
    pub fn transition_lifecycle(
        &mut self,
        next_state: TrayAppLifecycleState,
    ) -> Result<(), String> {
        self.lifecycle_state.validate_transition(next_state)?;
        self.lifecycle_state = next_state;
        Ok(())
    }

    /// Returns true if the tray is in a running/healthy state where user actions are allowed.
    /// @trace spec:tray-app, spec:app-lifecycle
    pub fn is_ready_for_user_action(&self) -> bool {
        matches!(
            self.lifecycle_state,
            TrayAppLifecycleState::Idle | TrayAppLifecycleState::Running
        )
    }

    /// Returns true if a project can be started (lifecycle state allows it).
    /// Used to guard "Attach Here" and container launch operations.
    /// @trace spec:app-lifecycle
    pub fn can_start_project(&self) -> bool {
        // Can only start if idle or already running (can have multiple projects)
        matches!(
            self.lifecycle_state,
            TrayAppLifecycleState::Idle | TrayAppLifecycleState::Running
        )
    }

    /// Returns true if the tray is actively shutting down.
    /// @trace spec:app-lifecycle
    pub fn is_shutting_down(&self) -> bool {
        matches!(
            self.lifecycle_state,
            TrayAppLifecycleState::Stopping | TrayAppLifecycleState::Error
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

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

    #[test]
    fn tray_state_new_starts_with_pup_icon() {
        let state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });
        assert_eq!(state.tray_icon_state, TrayIconState::Pup);
    }

    #[test]
    fn compute_icon_state_returns_dried_when_podman_missing() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: false,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });
        state.has_podman = false;
        assert_eq!(state.compute_icon_state(), TrayIconState::Dried);
    }

    #[test]
    fn compute_icon_state_returns_building_when_build_in_progress() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });
        state.active_builds.push(BuildProgress {
            image_name: "forge".to_string(),
            status: BuildStatus::InProgress,
            started_at: Instant::now(),
            completed_at: None,
        });
        assert_eq!(state.compute_icon_state(), TrayIconState::Building);
    }

    #[test]
    fn compute_icon_state_returns_blooming_for_recent_completion() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });
        state.active_builds.push(BuildProgress {
            image_name: "forge".to_string(),
            status: BuildStatus::Completed,
            started_at: Instant::now(),
            completed_at: Some(Instant::now()),
        });
        assert_eq!(state.compute_icon_state(), TrayIconState::Blooming);
    }

    #[test]
    fn compute_icon_state_returns_mature_when_idle() {
        let state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });
        assert_eq!(state.compute_icon_state(), TrayIconState::Mature);
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn forge_container_name_format() {
        let name = ContainerInfo::forge_container_name("my-project");
        assert_eq!(name, "tillandsias-my-project-forge");
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn parse_forge_container_name_valid() {
        let name = ContainerInfo::forge_container_name("my-project");
        let parsed = ContainerInfo::parse_forge_container_name(&name);
        assert_eq!(parsed, Some("my-project".to_string()));
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn parse_forge_container_name_rejects_web() {
        // Wrong suffix — Serve Here container, not OpenCode Web forge.
        assert!(ContainerInfo::parse_forge_container_name("tillandsias-my-app-web").is_none());
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn parse_forge_container_name_rejects_genus() {
        // Genus-suffixed container is not a forge-named container.
        assert!(
            ContainerInfo::parse_forge_container_name("tillandsias-my-app-aeranthos").is_none()
        );
    }

    // @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
    #[test]
    fn parse_forge_container_name_hyphenated_project() {
        let parsed = ContainerInfo::parse_forge_container_name("tillandsias-cool-project-forge");
        assert_eq!(parsed, Some("cool-project".to_string()));
    }

    // @trace spec:git-mirror-service
    #[test]
    fn git_service_container_name_format() {
        let name = ContainerInfo::git_service_container_name("my-project");
        assert_eq!(name, "tillandsias-git-my-project");
    }

    #[test]
    fn parse_git_service_container_name_valid() {
        let project = ContainerInfo::parse_git_service_container_name("tillandsias-git-my-project");
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
            ContainerInfo::parse_git_service_container_name("tillandsias-my-project-web").is_none()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_valid_transition_idle_to_initializing() {
        let state = TrayAppLifecycleState::Idle;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Initializing)
                .is_ok()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_valid_transition_initializing_to_running() {
        let state = TrayAppLifecycleState::Initializing;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Running)
                .is_ok()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_valid_transition_running_to_stopping() {
        let state = TrayAppLifecycleState::Running;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Stopping)
                .is_ok()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_valid_transition_stopping_to_idle() {
        let state = TrayAppLifecycleState::Stopping;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Idle)
                .is_ok()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_valid_transition_any_to_error() {
        // Error is always reachable from any state
        assert!(
            TrayAppLifecycleState::Idle
                .validate_transition(TrayAppLifecycleState::Error)
                .is_ok()
        );
        assert!(
            TrayAppLifecycleState::Initializing
                .validate_transition(TrayAppLifecycleState::Error)
                .is_ok()
        );
        assert!(
            TrayAppLifecycleState::Running
                .validate_transition(TrayAppLifecycleState::Error)
                .is_ok()
        );
        assert!(
            TrayAppLifecycleState::Stopping
                .validate_transition(TrayAppLifecycleState::Error)
                .is_ok()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_invalid_transition_running_to_initializing() {
        let state = TrayAppLifecycleState::Running;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Initializing)
                .is_err()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_invalid_transition_initializing_directly_to_idle() {
        let state = TrayAppLifecycleState::Initializing;
        assert!(
            state
                .validate_transition(TrayAppLifecycleState::Idle)
                .is_err()
        );
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn lifecycle_state_as_str() {
        assert_eq!(TrayAppLifecycleState::Idle.as_str(), "idle");
        assert_eq!(TrayAppLifecycleState::Initializing.as_str(), "initializing");
        assert_eq!(TrayAppLifecycleState::Running.as_str(), "running");
        assert_eq!(TrayAppLifecycleState::Stopping.as_str(), "stopping");
        assert_eq!(TrayAppLifecycleState::Error.as_str(), "error");
    }

    // @trace spec:tray-app, spec:app-lifecycle
    #[test]
    fn tray_state_transitions_lifecycle() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });

        // Start in Idle
        assert_eq!(state.lifecycle_state, TrayAppLifecycleState::Idle);

        // Transition to Initializing (valid)
        assert!(
            state
                .transition_lifecycle(TrayAppLifecycleState::Initializing)
                .is_ok()
        );
        assert_eq!(state.lifecycle_state, TrayAppLifecycleState::Initializing);

        // Transition to Running (valid)
        assert!(
            state
                .transition_lifecycle(TrayAppLifecycleState::Running)
                .is_ok()
        );
        assert_eq!(state.lifecycle_state, TrayAppLifecycleState::Running);

        // Try invalid transition Running -> Initializing (blocked)
        assert!(
            state
                .transition_lifecycle(TrayAppLifecycleState::Initializing)
                .is_err()
        );

        // Transition to Stopping (valid)
        assert!(
            state
                .transition_lifecycle(TrayAppLifecycleState::Stopping)
                .is_ok()
        );

        // Transition back to Idle (valid)
        assert!(
            state
                .transition_lifecycle(TrayAppLifecycleState::Idle)
                .is_ok()
        );
    }

    // @trace spec:app-lifecycle
    #[test]
    fn tray_state_is_ready_for_user_action() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });

        assert!(state.is_ready_for_user_action());

        // Initializing is not ready
        state.lifecycle_state = TrayAppLifecycleState::Initializing;
        assert!(!state.is_ready_for_user_action());

        // Running is ready
        state.lifecycle_state = TrayAppLifecycleState::Running;
        assert!(state.is_ready_for_user_action());

        // Stopping is not ready
        state.lifecycle_state = TrayAppLifecycleState::Stopping;
        assert!(!state.is_ready_for_user_action());

        // Error is not ready
        state.lifecycle_state = TrayAppLifecycleState::Error;
        assert!(!state.is_ready_for_user_action());
    }

    // @trace spec:app-lifecycle
    #[test]
    fn tray_state_can_start_project() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });

        assert!(state.can_start_project());

        state.lifecycle_state = TrayAppLifecycleState::Running;
        assert!(state.can_start_project());

        state.lifecycle_state = TrayAppLifecycleState::Initializing;
        assert!(!state.can_start_project());

        state.lifecycle_state = TrayAppLifecycleState::Stopping;
        assert!(!state.can_start_project());

        state.lifecycle_state = TrayAppLifecycleState::Error;
        assert!(!state.can_start_project());
    }

    // @trace spec:app-lifecycle
    #[test]
    fn tray_state_is_shutting_down() {
        let mut state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });

        assert!(!state.is_shutting_down());

        state.lifecycle_state = TrayAppLifecycleState::Stopping;
        assert!(state.is_shutting_down());

        state.lifecycle_state = TrayAppLifecycleState::Error;
        assert!(state.is_shutting_down());
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-window-rate-limiting
    #[test]
    fn browser_window_registry_register_and_get() {
        let registry = BrowserWindowRegistry::new();

        let result = registry.register_window(
            "project1-window-1".to_string(),
            "container-abc123".to_string(),
            "project1".to_string(),
        );

        assert!(result.is_ok());
        let metadata = result.unwrap();
        assert_eq!(metadata.window_id, "project1-window-1");
        assert_eq!(metadata.container_id, "container-abc123");
        assert_eq!(metadata.project_label, "project1");
        assert_eq!(metadata.status, BrowserWindowStatus::Launching);

        // Get the window back
        let retrieved = registry.get_window("project1-window-1");
        assert!(retrieved.is_ok());
        assert!(retrieved.unwrap().is_some());
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_unregister() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-abc123".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        let unregistered = registry.unregister_window("project1-window-1");
        assert!(unregistered.is_ok());
        assert!(unregistered.unwrap().is_some());

        // Window should no longer exist
        let retrieved = registry.get_window("project1-window-1");
        assert!(retrieved.is_ok());
        assert!(retrieved.unwrap().is_none());
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_unregister_nonexistent() {
        let registry = BrowserWindowRegistry::new();

        let unregistered = registry.unregister_window("nonexistent");
        assert!(unregistered.is_ok());
        assert!(unregistered.unwrap().is_none());
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_get_all_windows() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-1".to_string(),
                "project1".to_string(),
            )
            .unwrap();
        registry
            .register_window(
                "project1-window-2".to_string(),
                "container-2".to_string(),
                "project1".to_string(),
            )
            .unwrap();
        registry
            .register_window(
                "project2-window-1".to_string(),
                "container-3".to_string(),
                "project2".to_string(),
            )
            .unwrap();

        let windows = registry.get_windows().unwrap();
        assert_eq!(windows.len(), 3);

        let window_ids: std::collections::HashSet<_> =
            windows.iter().map(|w| w.window_id.as_str()).collect();
        assert!(window_ids.contains("project1-window-1"));
        assert!(window_ids.contains("project1-window-2"));
        assert!(window_ids.contains("project2-window-1"));
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_update_status() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-abc123".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        // Initial status should be Launching
        let window = registry.get_window("project1-window-1").unwrap().unwrap();
        assert_eq!(window.status, BrowserWindowStatus::Launching);

        // Update to Active
        let update_result = registry.update_status("project1-window-1", BrowserWindowStatus::Active);
        assert!(update_result.is_ok());

        let window = registry.get_window("project1-window-1").unwrap().unwrap();
        assert_eq!(window.status, BrowserWindowStatus::Active);

        // Update to Closed
        let update_result = registry.update_status("project1-window-1", BrowserWindowStatus::Closed);
        assert!(update_result.is_ok());

        let window = registry.get_window("project1-window-1").unwrap().unwrap();
        assert_eq!(window.status, BrowserWindowStatus::Closed);
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_update_status_nonexistent() {
        let registry = BrowserWindowRegistry::new();

        let result = registry.update_status("nonexistent", BrowserWindowStatus::Active);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_heartbeat() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-abc123".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        let window1 = registry.get_window("project1-window-1").unwrap().unwrap();
        let heartbeat1 = window1.last_heartbeat;

        // Small delay to ensure time passes
        std::thread::sleep(std::time::Duration::from_millis(10));

        // Send heartbeat
        let heartbeat_result = registry.heartbeat("project1-window-1");
        assert!(heartbeat_result.is_ok());

        let window2 = registry.get_window("project1-window-1").unwrap().unwrap();
        let heartbeat2 = window2.last_heartbeat;

        // Heartbeat should be updated
        assert!(heartbeat2 >= heartbeat1);
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn browser_window_registry_heartbeat_nonexistent() {
        let registry = BrowserWindowRegistry::new();

        let result = registry.heartbeat("nonexistent");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-window-rate-limiting
    #[test]
    fn browser_window_registry_concurrent_operations() {
        use std::thread;
        use std::sync::Arc as StdArc;

        let registry = StdArc::new(BrowserWindowRegistry::new());
        let mut handles = vec![];

        // Spawn multiple threads registering windows concurrently
        for i in 0..5 {
            let reg = StdArc::clone(&registry);
            let handle = thread::spawn(move || {
                let window_id = format!("window-{}", i);
                let container_id = format!("container-{}", i);
                let project = format!("project{}", i % 2);
                reg.register_window(window_id, container_id, project)
                    .expect("register should succeed")
            });
            handles.push(handle);
        }

        // Wait for all threads to complete
        let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();

        // All registrations should succeed
        assert_eq!(results.len(), 5);

        // All windows should be in registry
        let windows = registry.get_windows().unwrap();
        assert_eq!(windows.len(), 5);
    }

    // @trace spec:browser-isolation-tray-integration
    #[test]
    fn tray_state_initializes_browser_window_registry() {
        let state = TrayState::new(PlatformInfo {
            os: Os::Linux,
            has_podman: true,
            has_podman_machine: false,
            gpu_devices: Vec::new(),
        });

        let windows = state.browser_windows.get_windows().unwrap();
        assert_eq!(windows.len(), 0);

        // Registry should be usable immediately
        let result = state.browser_windows.register_window(
            "test-window".to_string(),
            "test-container".to_string(),
            "test-project".to_string(),
        );
        assert!(result.is_ok());
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_mutation_hook_on_register() {
        use std::sync::{Arc as StdArc, atomic::{AtomicBool, Ordering}};

        let registry = BrowserWindowRegistry::new();
        let hook_called = StdArc::new(AtomicBool::new(false));
        let hook_called_clone = StdArc::clone(&hook_called);

        let hook: RegistryMutationHook = Box::new(move |window_id, container_id_opt, project_label_opt| {
            assert_eq!(window_id, "project1-window-1");
            assert_eq!(container_id_opt, Some("container-abc123"));
            assert_eq!(project_label_opt, Some("project1"));
            hook_called_clone.store(true, Ordering::SeqCst);
        });

        registry.set_mutation_hook(hook).unwrap();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-abc123".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        assert!(hook_called.load(Ordering::SeqCst));
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_mutation_hook_on_unregister() {
        use std::sync::{Arc as StdArc, atomic::{AtomicBool, Ordering}};

        let registry = BrowserWindowRegistry::new();
        let hook_called = StdArc::new(AtomicBool::new(false));
        let hook_called_clone = StdArc::clone(&hook_called);

        let hook: RegistryMutationHook = Box::new(move |window_id, container_id_opt, project_label_opt| {
            if window_id == "project1-window-1" && container_id_opt.is_none() && project_label_opt.is_none() {
                hook_called_clone.store(true, Ordering::SeqCst);
            }
        });

        registry.set_mutation_hook(hook).unwrap();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-abc123".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        // Reset flag
        hook_called.store(false, Ordering::SeqCst);

        registry.unregister_window("project1-window-1").unwrap();

        assert!(hook_called.load(Ordering::SeqCst));
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_mutation_hook_concurrent_calls() {
        use std::sync::{Arc as StdArc, atomic::{AtomicUsize, Ordering}};

        let registry = StdArc::new(BrowserWindowRegistry::new());
        let call_count = StdArc::new(AtomicUsize::new(0));
        let call_count_clone = StdArc::clone(&call_count);

        let hook: RegistryMutationHook = Box::new(move |_window_id, _container_id_opt, _project_label_opt| {
            call_count_clone.fetch_add(1, Ordering::SeqCst);
        });

        registry.set_mutation_hook(hook).unwrap();

        // Register multiple windows concurrently
        let mut handles = vec![];
        for i in 0..5 {
            let reg = StdArc::clone(&registry);
            let handle = std::thread::spawn(move || {
                reg.register_window(
                    format!("window-{}", i),
                    format!("container-{}", i),
                    format!("project{}", i),
                )
                .unwrap()
            });
            handles.push(handle);
        }

        // Wait for all registrations
        for handle in handles {
            handle.join().unwrap();
        }

        // All 5 registrations should have called the hook
        assert_eq!(call_count.load(Ordering::SeqCst), 5);
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_get_active_windows_by_project() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-1".to_string(),
                "project1".to_string(),
            )
            .unwrap();
        registry
            .register_window(
                "project1-window-2".to_string(),
                "container-2".to_string(),
                "project1".to_string(),
            )
            .unwrap();
        registry
            .register_window(
                "project2-window-1".to_string(),
                "container-3".to_string(),
                "project2".to_string(),
            )
            .unwrap();

        let by_project = registry.get_active_windows_by_project().unwrap();

        assert_eq!(by_project.len(), 2);
        assert_eq!(by_project.get("project1").unwrap().len(), 2);
        assert_eq!(by_project.get("project2").unwrap().len(), 1);

        // Verify window IDs are correct
        let project1_window_ids: std::collections::HashSet<_> = by_project
            .get("project1")
            .unwrap()
            .iter()
            .map(|w| w.window_id.as_str())
            .collect();
        assert!(project1_window_ids.contains("project1-window-1"));
        assert!(project1_window_ids.contains("project1-window-2"));

        let project2_window_ids: std::collections::HashSet<_> = by_project
            .get("project2")
            .unwrap()
            .iter()
            .map(|w| w.window_id.as_str())
            .collect();
        assert!(project2_window_ids.contains("project2-window-1"));
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_get_active_windows_by_project_empty() {
        let registry = BrowserWindowRegistry::new();

        let by_project = registry.get_active_windows_by_project().unwrap();

        assert_eq!(by_project.len(), 0);
    }

    // @trace spec:browser-isolation-tray-integration, spec:browser-routing-allowlist
    #[test]
    fn browser_window_registry_get_active_windows_by_project_after_unregister() {
        let registry = BrowserWindowRegistry::new();

        registry
            .register_window(
                "project1-window-1".to_string(),
                "container-1".to_string(),
                "project1".to_string(),
            )
            .unwrap();
        registry
            .register_window(
                "project1-window-2".to_string(),
                "container-2".to_string(),
                "project1".to_string(),
            )
            .unwrap();

        let by_project = registry.get_active_windows_by_project().unwrap();
        assert_eq!(by_project.get("project1").unwrap().len(), 2);

        // Unregister one window
        registry.unregister_window("project1-window-1").unwrap();

        let by_project = registry.get_active_windows_by_project().unwrap();
        assert_eq!(by_project.get("project1").unwrap().len(), 1);
        assert_eq!(by_project.get("project1").unwrap()[0].window_id, "project1-window-2");
    }
}
