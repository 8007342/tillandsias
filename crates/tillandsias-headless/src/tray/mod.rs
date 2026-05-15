// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle, spec:security-privacy-isolation, spec:browser-isolation-tray-integration, spec:host-browser-mcp, spec:runtime-logging, spec:logging-levels, spec:remote-projects
// @trace spec:podman-container-spec, spec:podman-orchestration
// @trace spec:browser-daemon-tracking, spec:browser-tray-notifications, spec:tray-projects-rename
//! Native Linux tray service backed by StatusNotifierItem and DBusMenu.
//!
//! The tray owns the Linux menu/icon surface. Menu actions launch the repo's
//! existing container entrypoints so the tray stays thin.

pub mod profiler;

use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

use image::GenericImageView;
use tracing::{Level, info, span, warn};
use zbus::object_server::SignalContext;
use zbus::{Connection, ConnectionBuilder, fdo, interface};
use zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::ENCLAVE_NO_PROXY;
use tillandsias_core::config::{self, SelectedAgent};
use tillandsias_core::genus::TrayIconState;
use tillandsias_core::remote_projects;
use tillandsias_podman::{ContainerSpec, MountMode};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/Menu";
const WATCHER_PATH: &str = "/StatusNotifierWatcher";
const WATCHER_NAME: &str = "org.kde.StatusNotifierWatcher";

/// @trace spec:tray-progress-and-icon-states, spec:tray-app
/// Enclave health state machine — independent of app lifecycle.
/// Tracks container readiness progression: Verifying → [ProxyReady] → [GitReady] → AllHealthy or Failed.
///
/// # State Diagram
///
/// ```text
/// Verifying ──► ProxyReady ──► GitReady ──► AllHealthy
///     │            │             │              │
///     └────────────┴─────────────┴──────────────┤
///                                                │
///                                                ▼
///                                             Failed
/// ```
///
/// # Valid Transitions
///
/// - `Verifying` → `ProxyReady` — Proxy container healthy
/// - `Verifying` → `Failed` — Probe failed or podman unavailable
/// - `ProxyReady` → `GitReady` — Git service container healthy
/// - `ProxyReady` → `Failed` — Probe failed
/// - `GitReady` → `AllHealthy` — All containers healthy
/// - `GitReady` → `Failed` — Probe failed
/// - `AllHealthy` → `Failed` — Container died or health check failed (degrades to failure state)
/// - **Any** → `Verifying` — Reset on new verification attempt (fallback)
///
/// # Semantics
///
/// - **Verifying**: Initial state. Checking for podman and dependencies.
/// - **ProxyReady**: Proxy container confirmed online.
/// - **GitReady**: Proxy + Git service confirmed online.
/// - **AllHealthy**: Complete enclave operational (proxy, git, inference all healthy).
/// - **Failed**: Unrecoverable enclave state. Requires manual rebuild or podman restart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EnclaveStatus {
    Verifying,
    ProxyReady,
    GitReady,
    AllHealthy,
    Failed,
}

// @trace spec:tray-progress-and-icon-states, spec:tray-app
impl EnclaveStatus {
    /// Validate a transition from this state to the next.
    /// @trace spec:tray-progress-and-icon-states
    fn can_transition_to(&self, next: EnclaveStatus) -> bool {
        match (*self, next) {
            // From Verifying: can probe probe stages or fail
            (Self::Verifying, Self::ProxyReady) => true,
            (Self::Verifying, Self::Failed) => true,
            // From ProxyReady: continue building or fail
            (Self::ProxyReady, Self::GitReady) => true,
            (Self::ProxyReady, Self::Failed) => true,
            // From GitReady: complete or fail
            (Self::GitReady, Self::AllHealthy) => true,
            (Self::GitReady, Self::Failed) => true,
            // From AllHealthy: only fails on container death
            (Self::AllHealthy, Self::Failed) => true,
            // From Failed: can retry (resets to Verifying implicitly)
            (Self::Failed, Self::Verifying) => true,
            // Any state can reset/retry to Verifying
            (_, Self::Verifying) => true,
            // Self-loop allowed for health checks
            (state, same) if state == same => true,
            // All other transitions invalid
            _ => false,
        }
    }

    fn status_text(self) -> &'static str {
        match self {
            EnclaveStatus::Verifying => "☐ Verifying environment...",
            EnclaveStatus::ProxyReady => "☐🌐 Building enclave...",
            EnclaveStatus::GitReady => "☐🌐🪞 Building git mirror...",
            EnclaveStatus::AllHealthy => "✓ Environment OK",
            EnclaveStatus::Failed => "🥀 Unhealthy environment",
        }
    }
}

#[derive(Debug, Clone)]
struct ProjectEntry {
    name: String,
    path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaunchKind {
    OpenCode,
    OpenCodeWeb,
    Claude,
    Maintenance,
}

// @trace spec:tray-minimal-ux
#[derive(Debug, Clone)]
struct TrayUiState {
    root: PathBuf,
    version: String,
    status_text: String,
    tray_icon_state: TrayIconState,
    projects: Vec<ProjectEntry>,
    selected_agent: SelectedAgent,
    forge_available: bool,
    podman_available: bool,
    enclave_status: EnclaveStatus,
    revision: u32,
    /// Hash of projects list to detect when menu needs rebuild
    projects_hash: u64,
}

type IconPixmap = (i32, i32, Vec<u8>);

type MenuNode = (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>);
type GroupProperties = Vec<(i32, HashMap<String, OwnedValue>)>;

// @trace gap:TR-005
/// Async task executor for offloading long-running operations from the GTK event loop.
/// Prevents UI blocking by spawning tasks in a dedicated thread pool.
#[derive(Debug)]
struct AsyncTaskExecutor {
    /// Send channel for queueing tasks
    sender: mpsc::SyncSender<Box<dyn Fn() + Send>>,
    /// Flag indicating if the executor thread is still running
    is_running: Arc<AtomicBool>,
}

impl AsyncTaskExecutor {
    /// Create a new async task executor with a bounded queue.
    /// @trace gap:TR-005
    fn new(queue_size: usize) -> Self {
        let (sender, receiver) = mpsc::sync_channel(queue_size);
        let is_running = Arc::new(AtomicBool::new(true));
        let is_running_clone = is_running.clone();

        // Spawn executor thread
        std::thread::spawn(move || {
            let span = span!(Level::TRACE, "async_task_executor");
            let _guard = span.enter();

            while is_running_clone.load(Ordering::Relaxed) {
                match receiver.recv_timeout(std::time::Duration::from_millis(100)) {
                    Ok(task) => {
                        task();
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        // Continue waiting
                        continue;
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        // Sender dropped, exit executor
                        break;
                    }
                }
            }
        });

        Self { sender, is_running }
    }

    /// Spawn a non-blocking task. Returns error if queue is full.
    /// @trace gap:TR-005
    fn spawn_task<F>(&self, task: F) -> Result<(), mpsc::SendError<Box<dyn Fn() + Send>>>
    where
        F: Fn() + Send + 'static,
    {
        self.sender.try_send(Box::new(task))
    }
}

impl Drop for AsyncTaskExecutor {
    fn drop(&mut self) {
        self.is_running.store(false, Ordering::Release);
    }
}

#[derive(Debug)]
struct TrayService {
    state: Mutex<TrayUiState>,
    connection: OnceLock<Connection>,
    item_path: String,
    menu_path: String,
    service_name: String,
    /// @trace gap:TR-005: Async executor for offloading blocking tasks
    task_executor: AsyncTaskExecutor,
}

#[derive(Clone)]
struct StatusNotifierItemIface(Arc<TrayService>);

#[derive(Clone)]
struct DbusMenuIface(Arc<TrayService>);

impl TrayUiState {
    fn new(root: PathBuf, version: String, projects: Vec<ProjectEntry>) -> Self {
        let podman_available = podman_available();
        let selected_agent = config::load_global_config().agent.selected;
        let forge_image = format!("tillandsias-forge:v{version}");
        let forge_available = podman_available && image_exists(&forge_image);

        let enclave_status = if !podman_available {
            EnclaveStatus::Failed
        } else if forge_available {
            EnclaveStatus::AllHealthy
        } else {
            EnclaveStatus::Verifying
        };

        // @trace spec:tray-icon-lifecycle
        // Map enclave status to icon state for consistent lifecycle representation
        let tray_icon_state = enclave_status_to_icon(enclave_status);
        let status_text = enclave_status.status_text().to_string();

        // Compute hash of projects list for change detection
        let projects_hash = Self::hash_projects(&projects);

        Self {
            root,
            version,
            status_text,
            tray_icon_state,
            projects,
            selected_agent,
            forge_available,
            podman_available,
            enclave_status,
            revision: 1,
            projects_hash,
        }
    }

    fn bump_revision(&mut self) -> u32 {
        self.revision = self.revision.saturating_add(1);
        self.revision
    }

    /// Simple hash of projects list for detecting menu-relevant changes
    fn hash_projects(projects: &[ProjectEntry]) -> u64 {
        let mut hash = 0u64;
        for (i, project) in projects.iter().enumerate() {
            hash = hash
                .wrapping_mul(31)
                .wrapping_add((i as u64) ^ (project.name.len() as u64));
        }
        hash
    }

    /// Check if projects list has changed since last menu build
    fn projects_changed(&self, new_projects: &[ProjectEntry]) -> bool {
        Self::hash_projects(new_projects) != self.projects_hash
    }
}

impl TrayService {
    fn new(state: TrayUiState) -> Self {
        let pid = std::process::id();
        // @trace gap:TR-005: Initialize async task executor with bounded queue (100 pending tasks)
        let task_executor = AsyncTaskExecutor::new(100);
        Self {
            state: Mutex::new(state),
            connection: OnceLock::new(),
            item_path: ITEM_PATH.to_string(),
            menu_path: MENU_PATH.to_string(),
            service_name: format!("org.freedesktop.StatusNotifierItem-{pid}-1"),
            task_executor,
        }
    }

    fn attach_connection(&self, connection: Connection) {
        let _ = self.connection.set(connection);
    }

    fn connection(&self) -> &Connection {
        self.connection
            .get()
            .expect("tray connection should be attached before use")
    }

    fn snapshot(&self) -> TrayUiState {
        self.state.lock().expect("tray state lock poisoned").clone()
    }

    fn with_state<T>(&self, f: impl FnOnce(&mut TrayUiState) -> T) -> T {
        let mut state = self.state.lock().expect("tray state lock poisoned");
        f(&mut state)
    }

    fn refresh_snapshot(&self) -> TrayUiState {
        self.snapshot()
    }

    async fn emit_refresh(&self, include_menu: bool) -> zbus::Result<()> {
        let item_ctxt = SignalContext::new(self.connection(), self.item_path.as_str())?;
        StatusNotifierItemIface::new_icon(&item_ctxt).await?;
        StatusNotifierItemIface::new_status(&item_ctxt).await?;
        StatusNotifierItemIface::new_tool_tip(&item_ctxt).await?;

        if include_menu {
            let revision = self.refresh_snapshot().revision;
            let menu_ctxt = SignalContext::new(self.connection(), self.menu_path.as_str())?;
            DbusMenuIface::layout_updated(&menu_ctxt, revision, 0).await?;
        }

        Ok(())
    }

    async fn rebuild_after_state_change(&self) -> zbus::Result<()> {
        self.emit_refresh(true).await
    }

    /// @trace spec:tray-icon-lifecycle
    /// Update icon to reflect current enclave status.
    /// Called whenever enclave status changes.
    fn update_icon_from_status(&self, status: EnclaveStatus) {
        let new_icon = enclave_status_to_icon(status);
        self.with_state(|state| {
            if state.tray_icon_state != new_icon {
                info!(
                    "icon_transition enclave_status={:?} icon={:?}→{:?}",
                    status, state.tray_icon_state, new_icon
                );
                state.tray_icon_state = new_icon;
                state.bump_revision();
            }
        });
    }

    /// @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle
    /// Update tray status text, icon, and optionally forge availability.
    /// Enclave status transitions to AllHealthy when forge becomes available.
    /// Valid transitions:
    /// - Verifying → AllHealthy (when forge_available becomes true)
    /// - Any → Invalid (invalid transitions are silently ignored)
    async fn set_status(
        &self,
        text: impl Into<String>,
        icon: TrayIconState,
        forge_available: Option<bool>,
    ) -> zbus::Result<()> {
        let mut status_changed = false;
        self.with_state(|state| {
            state.status_text = text.into();
            state.tray_icon_state = icon;
            if let Some(value) = forge_available {
                let previous_available = state.forge_available;
                state.forge_available = value;

                // @trace spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle
                // Wire forge_available=true transition to update status and trigger menu rebuild
                // Valid state transitions:
                // - Verifying → AllHealthy (initial forge availability)
                // - Failed → AllHealthy (recovery after failure)
                if !previous_available && value {
                    // Transition from unavailable to available: go directly to healthy
                    if state
                        .enclave_status
                        .can_transition_to(EnclaveStatus::AllHealthy)
                    {
                        state.enclave_status = EnclaveStatus::AllHealthy;
                        state.status_text = "✓ Environment OK".to_string();
                        status_changed = true;
                    }
                } else if value && state.enclave_status == EnclaveStatus::Verifying {
                    // Already in Verifying, still becoming available: transition to healthy
                    if state
                        .enclave_status
                        .can_transition_to(EnclaveStatus::AllHealthy)
                    {
                        state.enclave_status = EnclaveStatus::AllHealthy;
                        state.status_text = "✓ Environment OK".to_string();
                        status_changed = true;
                    }
                }
            }
            state.bump_revision();
        });

        // Update icon if status changed
        if status_changed {
            let status = self.snapshot().enclave_status;
            self.update_icon_from_status(status);
        }

        self.rebuild_after_state_change().await
    }

    fn selected_agent(&self) -> SelectedAgent {
        self.snapshot().selected_agent
    }

    fn update_selected_agent(&self, agent: SelectedAgent) {
        self.with_state(|state| {
            state.selected_agent = agent;
            state.bump_revision();
        });
    }

    fn project_by_name(&self, name: &str) -> Option<ProjectEntry> {
        self.snapshot()
            .projects
            .into_iter()
            .find(|project| project.name == name)
    }

    fn launch_selected_agent_for_project(&self, _project: &ProjectEntry) -> LaunchKind {
        match self.selected_agent() {
            SelectedAgent::OpenCode => LaunchKind::OpenCode,
            SelectedAgent::Claude => LaunchKind::Claude,
            SelectedAgent::OpenCodeWeb => LaunchKind::OpenCodeWeb,
        }
    }
}

/// @trace spec:tray-icon-lifecycle
/// Map enclave health state to tray icon lifecycle state.
/// Reflects the plant lifecycle metaphor:
/// - Verifying → Pup (initializing, green sprout)
/// - ProxyReady → Pup (still initializing)
/// - GitReady → Pup (still initializing)
/// - AllHealthy → Mature (full plant, healthy)
/// - Failed → Dried (error, wilted)
fn enclave_status_to_icon(status: EnclaveStatus) -> TrayIconState {
    match status {
        EnclaveStatus::Verifying => TrayIconState::Pup,
        EnclaveStatus::ProxyReady => TrayIconState::Pup,
        EnclaveStatus::GitReady => TrayIconState::Pup,
        EnclaveStatus::AllHealthy => TrayIconState::Mature,
        EnclaveStatus::Failed => TrayIconState::Dried,
    }
}

fn podman_available() -> bool {
    Command::new("podman")
        .arg("--version")
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn image_exists(image_tag: &str) -> bool {
    Command::new("podman")
        .args(["image", "exists", image_tag])
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn discover_projects() -> Vec<ProjectEntry> {
    let home = match std::env::var("HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => return Vec::new(),
    };
    let src = home.join("src");
    let mut projects = Vec::new();
    let entries = match std::fs::read_dir(&src) {
        Ok(entries) => entries,
        Err(_) => return Vec::new(),
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|s| s.to_string())
        else {
            continue;
        };
        projects.push(ProjectEntry { name, path });
    }

    projects.sort_by(|a, b| a.name.cmp(&b.name));
    projects
}

fn action_slug(kind: LaunchKind) -> &'static str {
    match kind {
        LaunchKind::OpenCode => "opencode",
        LaunchKind::OpenCodeWeb => "opencode-web",
        LaunchKind::Claude => "claude",
        LaunchKind::Maintenance => "terminal",
    }
}

fn ov(value: Value<'_>) -> OwnedValue {
    OwnedValue::try_from(value).expect("value should serialize")
}

fn ov_str(value: impl Into<String>) -> OwnedValue {
    ov(Value::from(value.into()))
}

fn props(pairs: Vec<(String, OwnedValue)>) -> HashMap<String, OwnedValue> {
    pairs.into_iter().collect()
}

fn node(id: i32, props: HashMap<String, OwnedValue>, children: Vec<OwnedValue>) -> MenuNode {
    (id, props, children)
}

fn child(node: MenuNode) -> OwnedValue {
    OwnedValue::try_from(Value::from(node)).expect("dbusmenu child should serialize")
}

fn icon_pixmaps(state: TrayIconState) -> Vec<IconPixmap> {
    let png = tillandsias_core::icons::tray_icon_png(state);
    let image = image::load_from_memory_with_format(png, image::ImageFormat::Png)
        .expect("tray PNG should decode");
    let (width, height) = image.dimensions();
    let rgba = image.into_rgba8();
    let mut argb = Vec::with_capacity(rgba.len());
    for pixel in rgba.as_raw().chunks_exact(4) {
        argb.extend_from_slice(&[pixel[3], pixel[0], pixel[1], pixel[2]]);
    }
    vec![(width as i32, height as i32, argb)]
}

fn tray_icon_status(state: TrayIconState) -> &'static str {
    match state {
        TrayIconState::Dried => "NeedsAttention",
        _ => "Active",
    }
}

fn tray_icon_tooltip(snapshot: &TrayUiState) -> (String, Vec<IconPixmap>, String, String) {
    (
        "Tillandsias".to_string(),
        icon_pixmaps(snapshot.tray_icon_state),
        snapshot.status_text.clone(),
        "Tillandsias".to_string(),
    )
}

fn build_launch_spec(project: &ProjectEntry, kind: LaunchKind, image: &str) -> ContainerSpec {
    let project_name = &project.name;
    let project_path = project
        .path
        .canonicalize()
        .unwrap_or_else(|_| project.path.clone());
    let ca_cert = PathBuf::from("/tmp/tillandsias-ca/intermediate.crt");

    let mut spec = ContainerSpec::new(image.to_string())
        .name(format!(
            "tillandsias-{}-{}",
            project_name,
            action_slug(kind)
        ))
        .hostname(format!("forge-{project_name}"))
        .network("tillandsias-enclave")
        .pids_limit(512)
        .volume(
            project_path.display().to_string(),
            format!("/home/forge/src/{project_name}"),
            MountMode::ReadWrite,
        )
        .env("HOME", "/home/forge")
        .env("USER", "forge")
        .env("PROJECT", project_name)
        .env("http_proxy", "http://proxy:3128")
        .env("https_proxy", "http://proxy:3128")
        .env("HTTP_PROXY", "http://proxy:3128")
        .env("HTTPS_PROXY", "http://proxy:3128")
        .env("no_proxy", ENCLAVE_NO_PROXY)
        .env("NO_PROXY", ENCLAVE_NO_PROXY)
        .env("PATH", "/usr/local/bin:/usr/bin");

    if ca_cert.exists() {
        spec = spec.bind_mount(
            ca_cert.display().to_string(),
            "/etc/tillandsias/ca.crt",
            true,
        );
    }

    match kind {
        LaunchKind::OpenCode => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-forge-opencode.sh"),
        LaunchKind::OpenCodeWeb => spec
            .detached()
            .persistent()
            .entrypoint("/usr/local/bin/entrypoint-forge-opencode-web.sh"),
        LaunchKind::Claude => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-forge-claude.sh"),
        LaunchKind::Maintenance => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-terminal.sh"),
    }
}

fn launch_in_terminal(title: &str, executable: &str, args: &[String]) -> Result<(), String> {
    for candidate in ["gnome-terminal", "konsole", "xterm"] {
        if terminal_present(candidate) {
            let mut child = Command::new(candidate);
            match candidate {
                "gnome-terminal" => {
                    child.args(["--title", title, "--", executable]);
                    child.args(args);
                }
                "konsole" => {
                    child.args([
                        "--new-tab",
                        "-p",
                        &format!("tabtitle={title}"),
                        "-e",
                        executable,
                    ]);
                    child.args(args);
                }
                "xterm" => {
                    child.args(["-T", title, "-e", executable]);
                    child.args(args);
                }
                _ => {}
            }
            child
                .spawn()
                .map_err(|e| format!("failed to launch terminal: {e}"))?;
            return Ok(());
        }
    }

    let status = Command::new(executable)
        .args(args)
        .status()
        .map_err(|e| format!("failed to run command: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("command exited with {status}"))
    }
}

fn terminal_present(candidate: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };

    for dir in env::split_paths(&path) {
        let candidate_path = dir.join(candidate);
        if !candidate_path.exists() {
            continue;
        }
        #[cfg(unix)]
        {
            if let Ok(metadata) = fs::metadata(&candidate_path)
                && metadata.permissions().mode() & 0o111 == 0
            {
                continue;
            }
        }
        return true;
    }

    false
}

fn launch_project_action(
    project: ProjectEntry,
    kind: LaunchKind,
    version: String,
) -> Result<(), String> {
    match kind {
        LaunchKind::OpenCodeWeb => {
            let project_path = project.path.display().to_string();
            super::run_opencode_web_mode(&project_path, None, false)
        }
        _ => {
            let image = format!("tillandsias-forge:v{}", version);
            let spec = build_launch_spec(&project, kind, &image);
            let args = spec.build_run_argv();
            launch_in_terminal(
                &format!("Tillandsias - {} - {}", project.name, action_slug(kind)),
                "podman",
                &args,
            )
        }
    }
}

fn run_init_action() -> Result<(), String> {
    super::run_init(false, false)
}

fn run_root_terminal(root: &Path, version: &str) -> Result<(), String> {
    let image = format!("tillandsias-forge:v{}", version);
    let project = ProjectEntry {
        name: root
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("tillandsias")
            .to_string(),
        path: root.to_path_buf(),
    };
    let spec = build_launch_spec(&project, LaunchKind::Maintenance, &image);
    launch_in_terminal("Tillandsias - Root", "podman", &spec.build_run_argv())
}

fn handle_select_agent(service: Arc<TrayService>, agent: SelectedAgent) {
    service.update_selected_agent(agent);
    config::save_selected_agent(agent);
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload UI refresh to async executor (non-blocking)
    if let Err(_) = service.task_executor.spawn_task(move || {
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    }) {
        warn!("task queue full: skipping agent selection UI refresh");
    }
}

fn handle_launch_project(service: Arc<TrayService>, project: ProjectEntry, kind: LaunchKind) {
    let version = service.snapshot().version.clone();
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload project launch and UI refresh to async executor (non-blocking)
    if let Err(_) = service.task_executor.spawn_task(move || {
        let result = launch_project_action(project, kind, version);
        if let Err(err) = result {
            warn!("project launch failed: {err}");
        }
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    }) {
        warn!("task queue full: skipping project launch");
    }
}

fn handle_init(service: Arc<TrayService>) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload initialization and UI updates to async executor (non-blocking)
    if let Err(_) = service.task_executor.spawn_task(move || {
        let _ = futures::executor::block_on(service_for_emit.set_status(
            "⏳ Building images ...",
            TrayIconState::Building,
            None,
        ));
        let result = run_init_action();
        let (text, icon, forge_available) = if result.is_ok() {
            ("✅ Ready", TrayIconState::Mature, Some(true))
        } else {
            ("🥀 Setup failed", TrayIconState::Dried, Some(false))
        };
        if let Err(err) = result {
            warn!("initialization failed: {err}");
        }
        let _ =
            futures::executor::block_on(service_for_emit.set_status(text, icon, forge_available));
    }) {
        warn!("task queue full: skipping initialization");
    }
}

fn handle_github_login(service: Arc<TrayService>) {
    // @trace spec:gh-auth-script, spec:tray-app, gap:TR-005
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload GitHub login terminal launch to async executor (non-blocking)
    if let Err(_) = service.task_executor.spawn_task(move || {
        let args = vec!["--github-login".to_string()];
        if let Err(err) = launch_in_terminal("GitHub Login", "tillandsias", &args) {
            warn!("GitHub login terminal spawn failed: {err}");
        }
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    }) {
        warn!("task queue full: skipping GitHub login");
    }
}

// @trace spec:remote-projects, gap:TR-005
fn handle_clone_project(service: Arc<TrayService>, repo_url: String, repo_name: String) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload project cloning to async executor (non-blocking)
    if let Err(_) = service.task_executor.spawn_task(move || {
        let home = match std::env::var("HOME") {
            Ok(h) => PathBuf::from(h),
            Err(_) => {
                warn!("clone_project: HOME not set");
                return;
            }
        };
        let target_path = home.join("src").join(&repo_name);

        // Update status to show cloning
        let _ = futures::executor::block_on(service_for_emit.set_status(
            format!("⏳ Cloning {} ...", repo_name),
            TrayIconState::Building,
            None,
        ));

        // Clone the project
        match remote_projects::clone_project_from_github(&repo_url, &target_path) {
            Ok(()) => {
                info!(
                    "clone_project: successfully cloned {} to {:?}",
                    repo_name, target_path
                );
                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("✓ Cloned {}", repo_name),
                    TrayIconState::Mature,
                    None,
                ));
            }
            Err(err) => {
                warn!("clone_project: failed to clone {}: {}", repo_name, err);
                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("🥀 Clone failed: {}", err),
                    TrayIconState::Dried,
                    None,
                ));
            }
        }

        // Refresh menu after a short delay to show results
        std::thread::sleep(std::time::Duration::from_secs(2));
        let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
    }) {
        warn!("task queue full: skipping project clone");
    }
}

// @trace spec:tray-minimal-ux
fn build_separator_item(id: i32) -> MenuNode {
    node(
        id,
        props(vec![
            ("type".to_string(), ov_str("separator")),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )
}

// @trace spec:tray-minimal-ux
fn build_seedlings_submenu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();
    for agent in [
        SelectedAgent::OpenCodeWeb,
        SelectedAgent::OpenCode,
        SelectedAgent::Claude,
    ] {
        let item_props = props(vec![
            ("label".to_string(), ov_str(agent.display_name())),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("toggle-type".to_string(), ov_str("checkmark")),
            (
                "toggle-state".to_string(),
                ov(Value::from(if state.selected_agent == agent {
                    1i32
                } else {
                    0i32
                })),
            ),
        ]);
        children.push(child(node(
            match agent {
                SelectedAgent::OpenCodeWeb => 1001,
                SelectedAgent::OpenCode => 1002,
                SelectedAgent::Claude => 1003,
            },
            item_props,
            Vec::new(),
        )));
    }

    node(
        10,
        props(vec![
            ("label".to_string(), ov_str("Seedlings")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

// @trace spec:remote-projects
fn build_clone_project_submenu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();
    let clone_enabled = state.forge_available && state.podman_available;

    // Discover GitHub projects (cached)
    let projects = remote_projects::discover_github_projects();

    // Show top 5 projects
    for (idx, project) in projects.iter().take(5).enumerate() {
        let item_id = 2000 + idx as i32;
        let label = format!("{} {}", &project.owner, &project.name);
        children.push(child(node(
            item_id,
            props(vec![
                ("label".to_string(), ov_str(label)),
                ("enabled".to_string(), ov(Value::from(clone_enabled))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    // If no projects, show placeholder
    if projects.is_empty() {
        children.push(child(node(
            2100,
            props(vec![
                ("label".to_string(), ov_str("(No projects discovered)")),
                ("enabled".to_string(), ov(Value::from(false))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    node(
        20,
        props(vec![
            ("label".to_string(), ov_str("Clone Project")),
            ("enabled".to_string(), ov(Value::from(clone_enabled))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

// @trace spec:tray-ux, spec:tray-minimal-ux
/// Build a project submenu with runtime state detection.
/// Menu items: "Attach Here", "Maintenance", and optionally "Stop" if web container is running.
/// All items are enabled only when forge_available AND podman_available.
fn build_project_submenu(state: &TrayUiState, project: &ProjectEntry) -> MenuNode {
    build_project_submenu_with_running(state, project, podman_running_web_container(&project.name))
}

// @trace spec:tray-ux, spec:tray-minimal-ux
/// Build a project submenu with explicit running state.
/// Visibility rules:
/// - "Attach Here": enabled if forge_available AND podman_available
/// - "Maintenance": enabled if forge_available AND podman_available
/// - "Stop": only shown if running_web=true (no disabled state)
fn build_project_submenu_with_running(
    state: &TrayUiState,
    project: &ProjectEntry,
    running_web: bool,
) -> MenuNode {
    let mut children = Vec::new();
    let attach_enabled = state.forge_available && state.podman_available;
    let maintenance_enabled = state.forge_available && state.podman_available;

    children.push(child(node(
        stable_project_item_id(&project.name, "attach-here"),
        props(vec![
            ("label".to_string(), ov_str("Attach Here")),
            ("enabled".to_string(), ov(Value::from(attach_enabled))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    children.push(child(node(
        stable_project_item_id(&project.name, "maintenance"),
        props(vec![
            ("label".to_string(), ov_str("Maintenance")),
            ("enabled".to_string(), ov(Value::from(maintenance_enabled))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    if running_web {
        children.push(child(node(
            stable_project_item_id(&project.name, "stop"),
            props(vec![
                ("label".to_string(), ov_str("Stop")),
                ("enabled".to_string(), ov(Value::from(true))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    node(
        stable_project_item_id(&project.name, "submenu"),
        props(vec![
            ("label".to_string(), ov_str(project.name.clone())),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

fn podman_running_web_container(project_name: &str) -> bool {
    let output = Command::new("podman")
        .args(["ps", "--format", "{{.Names}}"])
        .output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let prefix = format!("tillandsias-{project_name}-forge");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|line| line.trim() == prefix)
}

fn stable_project_item_id(project: &str, suffix: &str) -> i32 {
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    use std::hash::Hash;
    use std::hash::Hasher;
    project.hash(&mut hash);
    suffix.hash(&mut hash);
    let value = (hash.finish() & 0x7fff_ffff) as i32;
    if value == 0 { 1 } else { value }
}

// @trace spec:tray-minimal-ux, spec:tray-ux, spec:tray-progress-and-icon-states
/// Build the tray menu following minimal explicit UX pattern.
///
/// ## Menu Structure
///
/// ### Static Base Items (always visible)
/// 1. Status element (id=1) — disabled, shows current enclave status with emoji
/// 2. Separator (id=2) — visual divider
/// 3. Version/Attribution (id=30) — disabled, shows "Tillandsias v{version}"
/// 4. Quit button (id=31) — enabled, closes the application
///
/// ### Dynamic Region (shown only when forge_available=true AND enclave_status != Failed)
/// When the dynamic region is hidden (forge unavailable or enclave failed), only the 4 base items appear.
/// When visible, adds:
/// 1. Seedlings submenu (id=10) — agent selector with checkmark
/// 2. Project submenus (one per project) — each with Attach/Maintenance/Stop items
/// 3. Clone Project submenu (id=20) — GitHub project discovery
/// 4. GitHub Login button (id=22) — for authentication setup
///
/// ## Visibility Rules
/// - Static items are ALWAYS visible and never disabled
/// - Dynamic items are completely hidden (not disabled) when forge unavailable
/// - This ensures clean "cold start" experience with 4 items, expanding to full menu when ready
/// - Failed state collapses dynamic region to show user the error without distraction
///
/// ## Minimal UX Principle
/// No surprises. Menu items appear only when the system is ready to use them.
/// Users never see disabled items that can't do anything.
fn build_menu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();

    // @trace spec:tray-minimal-ux
    // Always visible: Status element (id=1)
    // Shows current enclave state with emoji indicators
    children.push(child(node(
        1,
        props(vec![
            ("label".to_string(), ov_str(state.status_text.clone())),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    // @trace spec:tray-minimal-ux
    // Always visible: Divider (id=2)
    children.push(child(build_separator_item(2)));

    // @trace spec:tray-minimal-ux
    // Always visible: Version + Attribution (id=30)
    // Shows Tillandsias version number for user reference and attribution
    children.push(child(node(
        30,
        props(vec![
            (
                "label".to_string(),
                ov_str(format!("Tillandsias v{}", state.version)),
            ),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    // @trace spec:tray-minimal-ux
    // Always visible: Quit button (id=31)
    // Only actionable menu item in the base section
    children.push(child(node(
        31,
        props(vec![
            ("label".to_string(), ov_str("Quit Tillandsias")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    // @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states
    // Dynamic region: shown only when forge is available AND enclave is not failed
    // When forge is unavailable (cold start) or enclave has failed, only show the 4 base items
    // This implements "no surprises" by hiding entire feature set until system is ready
    if state.forge_available && state.enclave_status != EnclaveStatus::Failed {
        // @trace spec:tray-ux
        // Seedlings submenu: agent selector
        // Always visible when forge_available (main project launcher UI)
        children.push(child(build_seedlings_submenu(state)));

        // @trace spec:tray-ux
        // Project submenus: one per discovered local project
        // Each project shows: Attach Here, Maintenance, Stop (if running)
        for project in &state.projects {
            children.push(child(build_project_submenu(state, project)));
        }

        // @trace spec:tray-ux, spec:remote-projects
        // Clone Project submenu: GitHub project discovery and cloning
        // Shows top 5 recent GitHub projects for quick access
        children.push(child(build_clone_project_submenu(state)));

        // @trace spec:tray-ux, spec:gh-auth-script
        // GitHub Login button: credentials setup
        // Enabled only if podman is available (can't run without container support)
        children.push(child(node(
            22,
            props(vec![
                ("label".to_string(), ov_str("GitHub Login")),
                (
                    "enabled".to_string(),
                    ov(Value::from(state.podman_available)),
                ),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    node(
        0,
        props(vec![
            ("label".to_string(), ov_str("Tillandsias")),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        children,
    )
}

#[interface(name = "org.kde.StatusNotifierItem")]
impl StatusNotifierItemIface {
    #[zbus(property)]
    fn category(&self) -> String {
        "ApplicationStatus".to_string()
    }

    #[zbus(property)]
    fn id(&self) -> String {
        "tillandsias".to_string()
    }

    #[zbus(property)]
    fn title(&self) -> String {
        "Tillandsias".to_string()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        tray_icon_status(self.0.snapshot().tray_icon_state).to_string()
    }

    #[zbus(property)]
    fn window_id(&self) -> u32 {
        0
    }

    #[zbus(property)]
    fn icon_theme_path(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn icon_pixmap(&self) -> Vec<IconPixmap> {
        icon_pixmaps(self.0.snapshot().tray_icon_state)
    }

    #[zbus(property)]
    fn attention_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn attention_icon_pixmap(&self) -> Vec<IconPixmap> {
        Vec::new()
    }

    #[zbus(property)]
    fn attention_movie_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn menu(&self) -> OwnedObjectPath {
        OwnedObjectPath::try_from(self.0.menu_path.as_str()).expect("menu object path")
    }

    #[zbus(property)]
    fn item_is_menu(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn menu_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn menu_overlay_icon_name(&self) -> String {
        String::new()
    }

    #[zbus(property)]
    fn tooltip(&self) -> (String, Vec<IconPixmap>, String, String) {
        tray_icon_tooltip(&self.0.snapshot())
    }

    #[zbus(property)]
    fn protocol_version(&self) -> u32 {
        0
    }

    async fn activate(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        if self.0.snapshot().tray_icon_state == TrayIconState::Blooming {
            self.0.with_state(|state| {
                state.tray_icon_state = TrayIconState::Mature;
                state.bump_revision();
            });
            StatusNotifierItemIface::new_icon(&ctxt)
                .await
                .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        }
        Ok(())
    }

    async fn context_menu(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        if self.0.snapshot().tray_icon_state == TrayIconState::Blooming {
            self.0.with_state(|state| {
                state.tray_icon_state = TrayIconState::Mature;
                state.bump_revision();
            });
            StatusNotifierItemIface::new_icon(&ctxt)
                .await
                .map_err(|e| fdo::Error::Failed(e.to_string()))?;
        }
        Ok(())
    }

    async fn secondary_activate(
        &self,
        _x: i32,
        _y: i32,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
    ) -> fdo::Result<()> {
        self.context_menu(_x, _y, ctxt).await
    }

    async fn scroll(&self, _delta: i32, _orientation: &str, _x: i32, _y: i32) -> fdo::Result<()> {
        Ok(())
    }

    #[zbus(signal)]
    async fn new_icon(ctxt: &SignalContext<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_status(ctxt: &SignalContext<'_>) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn new_tool_tip(ctxt: &SignalContext<'_>) -> zbus::Result<()>;
}

#[interface(name = "com.canonical.dbusmenu")]
impl DbusMenuIface {
    #[zbus(property)]
    fn version(&self) -> u32 {
        3
    }

    #[zbus(property)]
    fn text_direction(&self) -> String {
        "none".to_string()
    }

    #[zbus(property)]
    fn status(&self) -> String {
        "normal".to_string()
    }

    async fn get_layout(
        &self,
        _parent_id: i32,
        _recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> fdo::Result<(u32, MenuNode)> {
        let state = self.0.snapshot();
        Ok((state.revision, build_menu(&state)))
    }

    async fn get_group_properties(
        &self,
        ids: Vec<i32>,
        property_names: Vec<String>,
    ) -> fdo::Result<GroupProperties> {
        let state = self.0.snapshot();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        let requested: Option<std::collections::HashSet<String>> = if property_names.is_empty() {
            None
        } else {
            Some(property_names.into_iter().collect())
        };

        let mut out = Vec::new();
        for id in ids {
            if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
                let selected = props
                    .iter()
                    .filter(|(name, _)| {
                        requested
                            .as_ref()
                            .map(|wanted| wanted.contains(*name))
                            .unwrap_or(true)
                    })
                    .map(|(name, value)| {
                        (
                            name.clone(),
                            value.try_clone().expect("dbusmenu property should clone"),
                        )
                    })
                    .collect();
                out.push((id, selected));
            }
        }
        Ok(out)
    }

    async fn get_property(&self, id: i32, property_name: &str) -> fdo::Result<OwnedValue> {
        let state = self.0.snapshot();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
            props.get(property_name).map_or_else(
                || Err(fdo::Error::UnknownProperty(property_name.to_string())),
                |value| {
                    value
                        .try_clone()
                        .map_err(|e| fdo::Error::Failed(e.to_string()))
                },
            )
        } else {
            Err(fdo::Error::UnknownObject(format!("unknown menu item {id}")))
        }
    }

    async fn about_to_show(&self, _id: i32) -> fdo::Result<(bool, bool)> {
        Ok((true, false))
    }

    async fn event(
        &self,
        id: i32,
        event_id: &str,
        _data: OwnedValue,
        _timestamp: u32,
    ) -> fdo::Result<(i32, bool)> {
        if event_id != "clicked" && event_id != "opened" && event_id != "activate" {
            return Ok((0, false));
        }

        let state = self.0.snapshot();
        let mut flat = Vec::new();
        flatten_layout(&build_menu(&state), &mut flat);

        if let Some((_, props)) = flat.iter().find(|(item_id, _)| *item_id == id) {
            if let Some(label) = props.get("label") {
                let label = String::try_from(
                    label
                        .try_clone()
                        .map_err(|e| fdo::Error::Failed(e.to_string()))?,
                )
                .unwrap_or_default();
                match label.as_str() {
                    "Initialize images" => handle_init(self.0.clone()),
                    "GitHub Login" => handle_github_login(self.0.clone()),
                    "Root Terminal" => {
                        let snapshot = self.0.snapshot();
                        if snapshot.forge_available && snapshot.podman_available {
                            let service = self.0.clone();
                            let executor = &service.task_executor;
                            // @trace gap:TR-005: Offload terminal launch to async executor (non-blocking)
                            let _ = executor.spawn_task(move || {
                                if let Err(err) =
                                    run_root_terminal(&snapshot.root, &snapshot.version)
                                {
                                    warn!("root terminal launch failed: {err}");
                                }
                                let _ = futures::executor::block_on(
                                    service.rebuild_after_state_change(),
                                );
                            });
                        }
                    }
                    "Quit Tillandsias" => {
                        std::process::exit(0);
                    }
                    "Attach Here" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            if let Some(project_entry) = self.0.project_by_name(&project) {
                                let kind = self.0.launch_selected_agent_for_project(&project_entry);
                                handle_launch_project(self.0.clone(), project_entry, kind);
                            }
                        }
                    }
                    "Maintenance" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            if let Some(project_entry) = self.0.project_by_name(&project) {
                                handle_launch_project(
                                    self.0.clone(),
                                    project_entry,
                                    LaunchKind::Maintenance,
                                );
                            }
                        }
                    }
                    "Stop" => {
                        if let Some((project, _)) = project_from_id(&state, id) {
                            let service = self.0.clone();
                            // @trace gap:TR-005: Offload container stop to async executor (non-blocking)
                            let _ = service.task_executor.spawn_task(move || {
                                let _ = Command::new("podman")
                                    .args(["stop", &format!("tillandsias-{}-forge", project)])
                                    .status();
                                let _ = futures::executor::block_on(
                                    service.rebuild_after_state_change(),
                                );
                            });
                        }
                    }
                    "OpenCode Web" | "OpenCode" | "Claude" => {
                        if let Some(agent) = parse_seedling_label(&label) {
                            handle_select_agent(self.0.clone(), agent);
                        }
                    }
                    _ => {
                        // Check if this is a clone project item (format: "owner repo-name")
                        // Clone project items have IDs in range 2000-2099
                        if id >= 2000 && id < 2100 {
                            // Parse the label to get owner and repo name
                            let parts: Vec<&str> = label.split_whitespace().collect();
                            if parts.len() >= 2 {
                                let owner = parts[0];
                                let repo_name = parts[1];
                                let repo_url =
                                    format!("https://github.com/{}/{}", owner, repo_name);
                                handle_clone_project(
                                    self.0.clone(),
                                    repo_url,
                                    repo_name.to_string(),
                                );
                            }
                        }
                    }
                }
            }
        }

        Ok((0, true))
    }

    async fn event_group(
        &self,
        ids: Vec<i32>,
        event_id: &str,
        _data: OwnedValue,
        timestamp: u32,
    ) -> fdo::Result<Vec<(i32, i32, bool)>> {
        let mut out = Vec::new();
        for id in ids {
            let (result, handled) = self
                .event(id, event_id, ov(Value::from(0u32)), timestamp)
                .await?;
            out.push((id, result, handled));
        }
        Ok(out)
    }

    #[zbus(signal)]
    async fn layout_updated(
        ctxt: &SignalContext<'_>,
        revision: u32,
        parent: i32,
    ) -> zbus::Result<()>;
}

fn flatten_layout(node: &MenuNode, out: &mut Vec<(i32, HashMap<String, OwnedValue>)>) {
    let props = node
        .1
        .iter()
        .map(|(key, value)| {
            (
                key.clone(),
                value.try_clone().expect("dbusmenu property should clone"),
            )
        })
        .collect();
    out.push((node.0, props));
    for child in &node.2 {
        if let Ok(Value::Structure(structure)) = Value::try_from(child) {
            let fields = structure.fields();
            if fields.len() == 3 {
                let id = i32::try_from(
                    Value::try_from(&fields[0]).unwrap_or_else(|_| Value::from(0i32)),
                )
                .unwrap_or_default();
                let props = HashMap::<String, OwnedValue>::try_from(
                    fields[1]
                        .try_clone()
                        .unwrap_or_else(|_| Value::from(HashMap::<String, OwnedValue>::new())),
                )
                .unwrap_or_default();
                let children = Vec::<OwnedValue>::try_from(
                    fields[2]
                        .try_clone()
                        .unwrap_or_else(|_| Value::from(Vec::<OwnedValue>::new())),
                )
                .unwrap_or_default();
                let child_node = (id, props, children);
                flatten_layout(&child_node, out);
            }
        }
    }
}

fn project_from_id(state: &TrayUiState, id: i32) -> Option<(String, String)> {
    for project in &state.projects {
        let attach = stable_project_item_id(&project.name, "attach-here");
        let maintenance = stable_project_item_id(&project.name, "maintenance");
        let stop = stable_project_item_id(&project.name, "stop");
        if id == attach {
            return Some((project.name.clone(), "attach-here".to_string()));
        }
        if id == maintenance {
            return Some((project.name.clone(), "maintenance".to_string()));
        }
        if id == stop {
            return Some((project.name.clone(), "stop".to_string()));
        }
    }
    None
}

fn parse_seedling_label(label: &str) -> Option<SelectedAgent> {
    match label {
        "OpenCode Web" => Some(SelectedAgent::OpenCodeWeb),
        "OpenCode" => Some(SelectedAgent::OpenCode),
        "Claude" => Some(SelectedAgent::Claude),
        _ => None,
    }
}

async fn build_connection(service: Arc<TrayService>) -> Result<Connection, String> {
    let conn = ConnectionBuilder::session()
        .map_err(|e| e.to_string())?
        .name(service.service_name.as_str())
        .map_err(|e| e.to_string())?
        .serve_at(ITEM_PATH, StatusNotifierItemIface(service.clone()))
        .map_err(|e| e.to_string())?
        .serve_at(MENU_PATH, DbusMenuIface(service.clone()))
        .map_err(|e| e.to_string())?
        .build()
        .await
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

async fn register_with_watcher(connection: &Connection, service_name: &str) {
    let name = service_name.to_string();
    let result = async {
        let proxy = zbus::Proxy::new(
            connection,
            WATCHER_NAME,
            WATCHER_PATH,
            "org.kde.StatusNotifierWatcher",
        )
        .await
        .map_err(|e| e.to_string())?;
        proxy
            .call_method("RegisterStatusNotifierItem", &name)
            .await
            .map_err(|e| e.to_string())?;
        Ok::<(), String>(())
    }
    .await;
    if let Err(err) = result {
        warn!("StatusNotifierWatcher registration skipped: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_state(selected_agent: SelectedAgent, forge_available: bool) -> TrayUiState {
        let enclave_status = if forge_available {
            EnclaveStatus::AllHealthy
        } else {
            EnclaveStatus::Verifying
        };
        let projects = vec![ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
        }];
        let projects_hash = TrayUiState::hash_projects(&projects);
        TrayUiState {
            root: PathBuf::from("/tmp/tillandsias-test-root"),
            version: "0.1.260506.6".to_string(),
            status_text: enclave_status.status_text().to_string(),
            tray_icon_state: if forge_available {
                TrayIconState::Mature
            } else {
                TrayIconState::Pup
            },
            projects,
            selected_agent,
            forge_available,
            podman_available: true,
            enclave_status,
            revision: 1,
            projects_hash,
        }
    }

    fn labels(node: &MenuNode) -> Vec<String> {
        let mut flat = Vec::new();
        flatten_layout(node, &mut flat);
        flat.into_iter()
            .filter_map(|(_, props)| {
                props
                    .get("label")
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| String::try_from(value).ok())
            })
            .collect()
    }

    // @trace spec:tray-minimal-ux
    /// Test harness builder for simulating state transitions
    struct TrayStateBuilder {
        agent: SelectedAgent,
        forge_available: bool,
        enclave_status: EnclaveStatus,
        projects: Vec<ProjectEntry>,
    }

    impl TrayStateBuilder {
        fn new() -> Self {
            Self {
                agent: SelectedAgent::OpenCodeWeb,
                forge_available: false,
                enclave_status: EnclaveStatus::Verifying,
                projects: vec![ProjectEntry {
                    name: "test-project".to_string(),
                    path: std::path::PathBuf::from("/tmp/test-project"),
                }],
            }
        }

        fn forge_available(mut self, available: bool) -> Self {
            self.forge_available = available;
            // Don't auto-set enclave_status here; use enclave_status() method for explicit control
            // This allows tests to independently set forge_available and enclave_status
            self
        }

        fn enclave_status(mut self, status: EnclaveStatus) -> Self {
            self.enclave_status = status;
            self
        }

        fn projects(mut self, projects: Vec<ProjectEntry>) -> Self {
            self.projects = projects;
            self
        }

        fn build(self) -> TrayUiState {
            let status_text = self.enclave_status.status_text().to_string();
            let projects_hash = TrayUiState::hash_projects(&self.projects);
            // @trace spec:tray-icon-lifecycle
            // Icon should reflect enclave status, not just forge_available
            let tray_icon_state = enclave_status_to_icon(self.enclave_status);
            TrayUiState {
                root: std::path::PathBuf::from("/tmp/tillandsias-test-root"),
                version: "0.1.260506.6".to_string(),
                status_text,
                tray_icon_state,
                projects: self.projects,
                selected_agent: self.agent,
                forge_available: self.forge_available,
                podman_available: true,
                enclave_status: self.enclave_status,
                revision: 1,
                projects_hash,
            }
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn minimal_menu_has_exactly_4_items_at_launch() {
        // When forge_available = false (cold start), menu should have exactly 4 items:
        // 1. Status element
        // 2. Divider
        // 3. Version
        // 4. Quit button
        let state = test_state(SelectedAgent::OpenCodeWeb, false);
        let menu = build_menu(&state);

        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        // Filter out root node (id=0), count remaining items
        let items: Vec<_> = flat.iter().filter(|(id, _)| *id != 0).collect();
        assert_eq!(
            items.len(),
            4,
            "Expected exactly 4 items at launch (when forge_available=false), got {}. Items: {:?}",
            items.len(),
            items
                .iter()
                .map(|(_, p)| p.get("label"))
                .collect::<Vec<_>>()
        );

        // Verify the items are status, divider, version, quit
        let labels = labels(&menu);
        assert!(
            labels.contains(&"☐ Verifying environment...".to_string()),
            "Missing status element"
        );
        assert!(
            labels.contains(&"Tillandsias v0.1.260506.6".to_string()),
            "Missing version"
        );
        assert!(
            labels.contains(&"Quit Tillandsias".to_string()),
            "Missing quit button"
        );

        // Verify separator is present (no label, has "type": "separator")
        let has_separator = flat.iter().any(|(_, props)| {
            props
                .get("type")
                .and_then(|v| v.try_clone().ok())
                .and_then(|v| String::try_from(v).ok())
                == Some("separator".to_string())
        });
        assert!(has_separator, "Missing separator divider");
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn menu_expands_when_forge_available() {
        // When forge_available = true, menu should expand beyond 4 items to include:
        // - Seedlings submenu
        // - Project submenus
        // - GitHub login button
        let state = test_state(SelectedAgent::OpenCodeWeb, true);
        let menu = build_menu(&state);

        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        // Should have more than 4 items now
        let items: Vec<_> = flat.iter().filter(|(id, _)| *id != 0).collect();
        assert!(
            items.len() >= 6,
            "Expected >=6 items when forge_available=true, got {}",
            items.len()
        );

        // Verify seedlings submenu appears
        let labels = labels(&menu);
        assert!(
            labels.contains(&"Seedlings".to_string()),
            "Seedlings submenu missing when forge_available=true"
        );
        assert!(
            labels.contains(&"alpha".to_string()),
            "Project submenu missing when forge_available=true"
        );
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn status_text_reflects_enclave_status() {
        // Verify status text matches EnclaveStatus values
        let verifying = test_state(SelectedAgent::OpenCodeWeb, false);
        assert_eq!(
            verifying.status_text, "☐ Verifying environment...",
            "Status text should match Verifying state"
        );
        assert_eq!(
            verifying.enclave_status,
            EnclaveStatus::Verifying,
            "Enclave status should be Verifying when forge_available=false"
        );

        let ready = test_state(SelectedAgent::OpenCodeWeb, true);
        assert_eq!(
            ready.status_text, "✓ Environment OK",
            "Status text should match AllHealthy state"
        );
        assert_eq!(
            ready.enclave_status,
            EnclaveStatus::AllHealthy,
            "Enclave status should be AllHealthy when forge_available=true"
        );
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn state_transition_forge_false_to_true() {
        // Simulate the forge becoming available (transition from Verifying → AllHealthy)
        let initial = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .build();

        let menu_before = build_menu(&initial);
        let mut flat_before = Vec::new();
        flatten_layout(&menu_before, &mut flat_before);
        let items_before: Vec<_> = flat_before.iter().filter(|(id, _)| *id != 0).collect();

        // Should have exactly 4 items before
        assert_eq!(
            items_before.len(),
            4,
            "Should have 4 items when forge_available=false"
        );

        // Transition to forge_available=true
        let transitioned = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .build();

        let menu_after = build_menu(&transitioned);
        let mut flat_after = Vec::new();
        flatten_layout(&menu_after, &mut flat_after);
        let items_after: Vec<_> = flat_after.iter().filter(|(id, _)| *id != 0).collect();

        // Should expand to 6+ items after
        assert!(
            items_after.len() >= 6,
            "Should have >=6 items when forge_available=true, got {}",
            items_after.len()
        );

        // Status text should change
        assert_ne!(
            initial.status_text, transitioned.status_text,
            "Status text should change on transition"
        );
        assert!(
            transitioned.status_text.contains("✓"),
            "Status should have checkmark in AllHealthy state"
        );
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn enclave_status_all_states() {
        // Verify all EnclaveStatus states have correct emoji prefixes
        assert!(EnclaveStatus::Verifying.status_text().contains("☐"));
        assert!(EnclaveStatus::ProxyReady.status_text().contains("☐"));
        assert!(EnclaveStatus::ProxyReady.status_text().contains("🌐"));
        assert!(EnclaveStatus::GitReady.status_text().contains("☐"));
        assert!(EnclaveStatus::GitReady.status_text().contains("🌐"));
        assert!(EnclaveStatus::GitReady.status_text().contains("🪞"));
        assert!(EnclaveStatus::AllHealthy.status_text().contains("✓"));
        assert!(EnclaveStatus::Failed.status_text().contains("🥀"));
    }

    #[test]
    fn failed_state_collapses_dynamic_region() {
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::Failed)
            .build();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        let items: Vec<_> = flat.iter().filter(|(id, _)| *id != 0).collect();
        let item_labels: Vec<String> = items
            .iter()
            .filter_map(|(_, props)| {
                props
                    .get("label")
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| String::try_from(value).ok())
            })
            .collect();

        assert_eq!(item_labels[0], "🥀 Unhealthy environment");
        assert!(item_labels.contains(&"Tillandsias v0.1.260506.6".to_string()));
        assert!(item_labels.contains(&"Quit Tillandsias".to_string()));
        assert!(!item_labels.contains(&"Seedlings".to_string()));
        assert!(!item_labels.contains(&"OpenCode Web".to_string()));
        assert!(!item_labels.contains(&"OpenCode".to_string()));
        assert!(!item_labels.contains(&"Claude".to_string()));
        assert!(!item_labels.contains(&"GitHub Login".to_string()));
        assert!(!item_labels.contains(&"Attach Here".to_string()));
        assert!(!item_labels.contains(&"Maintenance".to_string()));
        assert!(!item_labels.contains(&"Stop".to_string()));

        assert_eq!(items.len(), 4);
    }

    #[test]
    fn seedlings_menu_keeps_default_order_and_active_choice() {
        let state = test_state(SelectedAgent::OpenCodeWeb, true);
        let menu = build_seedlings_submenu(&state);
        let item_labels = labels(&menu);

        assert_eq!(item_labels[0], "Seedlings");
        assert!(item_labels.contains(&"OpenCode Web".to_string()));
        assert!(item_labels.contains(&"OpenCode".to_string()));
        assert!(item_labels.contains(&"Claude".to_string()));

        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        let active = flat
            .into_iter()
            .find(|(_, props)| {
                props
                    .get("label")
                    .and_then(|value| value.try_clone().ok())
                    .and_then(|value| String::try_from(value).ok())
                    .as_deref()
                    == Some("OpenCode Web")
            })
            .and_then(|(_, props)| {
                props
                    .get("toggle-state")
                    .and_then(|value| value.try_clone().ok())
            })
            .and_then(|value| i32::try_from(value).ok())
            .unwrap_or_default();
        assert_eq!(active, 1);
    }

    #[test]
    fn project_menu_only_shows_stop_when_web_is_running() {
        let state = test_state(SelectedAgent::OpenCodeWeb, true);
        let project = state.projects[0].clone();

        let running = build_project_submenu_with_running(&state, &project, true);
        let stopped = build_project_submenu_with_running(&state, &project, false);

        assert!(labels(&running).contains(&"Stop".to_string()));
        assert!(!labels(&stopped).contains(&"Stop".to_string()));
    }

    #[test]
    fn launch_command_targets_the_forge_image_and_project_mount() {
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
        };
        let spec = build_launch_spec(
            &project,
            LaunchKind::Claude,
            "tillandsias-forge:v0.1.260506.6",
        );
        let args = spec.build_run_argv();

        assert_eq!(args[0], "run");
        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--name".to_string()));
        assert!(args.contains(&"tillandsias-alpha-claude".to_string()));
        assert!(args.contains(&"--hostname".to_string()));
        assert!(args.contains(&"forge-alpha".to_string()));
        assert!(args.contains(&"--entrypoint".to_string()));
        assert!(args.contains(&"/usr/local/bin/entrypoint-forge-claude.sh".to_string()));
        assert!(args.contains(&"tillandsias-forge:v0.1.260506.6".to_string()));
    }

    #[test]
    fn launch_command_opencode_web_is_detached_and_persistent() {
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
        };
        let spec = build_launch_spec(
            &project,
            LaunchKind::OpenCodeWeb,
            "tillandsias-forge:v0.1.260506.6",
        );
        let args = spec.build_run_argv();

        assert_eq!(args[0], "run");
        assert!(args.contains(&"-d".to_string()));
        assert!(!args.contains(&"--rm".to_string()));
        assert!(!args.contains(&"--interactive".to_string()));
        assert!(!args.contains(&"--tty".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--entrypoint".to_string()));
        assert!(args.contains(&"/usr/local/bin/entrypoint-forge-opencode-web.sh".to_string()));
        assert!(args.contains(&"--security-opt=label=disable".to_string()));
        assert!(args.contains(&"tillandsias-forge:v0.1.260506.6".to_string()));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_verifying_to_proxy_ready() {
        let state = EnclaveStatus::Verifying;
        assert!(state.can_transition_to(EnclaveStatus::ProxyReady));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_proxy_ready_to_git_ready() {
        let state = EnclaveStatus::ProxyReady;
        assert!(state.can_transition_to(EnclaveStatus::GitReady));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_git_ready_to_all_healthy() {
        let state = EnclaveStatus::GitReady;
        assert!(state.can_transition_to(EnclaveStatus::AllHealthy));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_any_to_failed() {
        // Can transition to Failed from any state
        assert!(EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::ProxyReady.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::GitReady.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::AllHealthy.can_transition_to(EnclaveStatus::Failed));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_failed_to_verifying_retry() {
        let state = EnclaveStatus::Failed;
        assert!(state.can_transition_to(EnclaveStatus::Verifying));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_transition_any_to_verifying_reset() {
        // Can reset to Verifying from any state
        assert!(EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::Verifying));
        assert!(EnclaveStatus::ProxyReady.can_transition_to(EnclaveStatus::Verifying));
        assert!(EnclaveStatus::GitReady.can_transition_to(EnclaveStatus::Verifying));
        assert!(EnclaveStatus::AllHealthy.can_transition_to(EnclaveStatus::Verifying));
        assert!(EnclaveStatus::Failed.can_transition_to(EnclaveStatus::Verifying));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_valid_self_loop() {
        // Health checks allow self-loops (idempotent)
        assert!(EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::Verifying));
        assert!(EnclaveStatus::ProxyReady.can_transition_to(EnclaveStatus::ProxyReady));
        assert!(EnclaveStatus::GitReady.can_transition_to(EnclaveStatus::GitReady));
        assert!(EnclaveStatus::AllHealthy.can_transition_to(EnclaveStatus::AllHealthy));
        assert!(EnclaveStatus::Failed.can_transition_to(EnclaveStatus::Failed));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_invalid_transition_skips_stages() {
        // Cannot skip stages: Verifying → GitReady (must go through ProxyReady)
        assert!(!EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::GitReady));
        // Cannot skip: Verifying → AllHealthy
        assert!(!EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::AllHealthy));
        // Cannot skip: ProxyReady → AllHealthy
        assert!(!EnclaveStatus::ProxyReady.can_transition_to(EnclaveStatus::AllHealthy));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_invalid_transition_backward_in_healthy_chain() {
        // Cannot skip backward in the healthy progression chain
        // (but can reset to Verifying from anywhere, so only test direct backward moves)
        assert!(!EnclaveStatus::GitReady.can_transition_to(EnclaveStatus::ProxyReady));
        assert!(!EnclaveStatus::AllHealthy.can_transition_to(EnclaveStatus::GitReady));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_text_includes_emoji() {
        assert!(EnclaveStatus::Verifying.status_text().contains("☐"));
        assert!(EnclaveStatus::ProxyReady.status_text().contains("🌐"));
        assert!(EnclaveStatus::GitReady.status_text().contains("🪞"));
        assert!(EnclaveStatus::AllHealthy.status_text().contains("✓"));
        assert!(EnclaveStatus::Failed.status_text().contains("🥀"));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_full_progression() {
        // Simulate a full healthy progression
        let mut status = EnclaveStatus::Verifying;

        // Verifying → ProxyReady
        assert!(status.can_transition_to(EnclaveStatus::ProxyReady));
        status = EnclaveStatus::ProxyReady;

        // ProxyReady → GitReady
        assert!(status.can_transition_to(EnclaveStatus::GitReady));
        status = EnclaveStatus::GitReady;

        // GitReady → AllHealthy
        assert!(status.can_transition_to(EnclaveStatus::AllHealthy));
        status = EnclaveStatus::AllHealthy;

        // AllHealthy → Failed (container dies)
        assert!(status.can_transition_to(EnclaveStatus::Failed));
        status = EnclaveStatus::Failed;

        // Failed → Verifying (retry)
        assert!(status.can_transition_to(EnclaveStatus::Verifying));
    }

    // @trace spec:tray-progress-and-icon-states, spec:tray-app
    #[test]
    fn enclave_status_failure_from_any_stage() {
        // Can fail at any stage
        assert!(EnclaveStatus::Verifying.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::ProxyReady.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::GitReady.can_transition_to(EnclaveStatus::Failed));
        assert!(EnclaveStatus::AllHealthy.can_transition_to(EnclaveStatus::Failed));

        // All failures can retry
        assert!(EnclaveStatus::Failed.can_transition_to(EnclaveStatus::Verifying));
    }

    // @trace spec:tray-icon-lifecycle
    #[test]
    fn icon_transitions_on_enclave_status_change() {
        // Verifying should map to Pup
        assert_eq!(
            enclave_status_to_icon(EnclaveStatus::Verifying),
            TrayIconState::Pup
        );
        // ProxyReady should map to Pup
        assert_eq!(
            enclave_status_to_icon(EnclaveStatus::ProxyReady),
            TrayIconState::Pup
        );
        // GitReady should map to Pup
        assert_eq!(
            enclave_status_to_icon(EnclaveStatus::GitReady),
            TrayIconState::Pup
        );
        // AllHealthy should map to Mature
        assert_eq!(
            enclave_status_to_icon(EnclaveStatus::AllHealthy),
            TrayIconState::Mature
        );
        // Failed should map to Dried
        assert_eq!(
            enclave_status_to_icon(EnclaveStatus::Failed),
            TrayIconState::Dried
        );
    }

    // @trace spec:tray-icon-lifecycle
    #[test]
    fn icon_reflects_enclave_status_on_init() {
        // When forge_available=false (Verifying), icon should be Pup
        let verifying_state = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::Verifying)
            .forge_available(false)
            .build();
        assert_eq!(verifying_state.tray_icon_state, TrayIconState::Pup);

        // When forge_available=true (AllHealthy), icon should be Mature
        let healthy_state = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::AllHealthy)
            .forge_available(true)
            .build();
        assert_eq!(healthy_state.tray_icon_state, TrayIconState::Mature);

        // When podman unavailable (Failed), icon should be Dried
        let failed_state = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::Failed)
            .forge_available(false)
            .build();
        assert_eq!(failed_state.tray_icon_state, TrayIconState::Dried);
    }

    // @trace spec:tray-icon-lifecycle
    #[test]
    fn icon_matches_enclave_status_through_progression() {
        // Simulate progression: Verifying → ProxyReady → GitReady → AllHealthy
        let verifying = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::Verifying)
            .build();
        assert_eq!(verifying.tray_icon_state, TrayIconState::Pup);

        let proxy_ready = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::ProxyReady)
            .build();
        assert_eq!(proxy_ready.tray_icon_state, TrayIconState::Pup);

        let git_ready = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::GitReady)
            .build();
        assert_eq!(git_ready.tray_icon_state, TrayIconState::Pup);

        let all_healthy = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::AllHealthy)
            .forge_available(true)
            .build();
        assert_eq!(all_healthy.tray_icon_state, TrayIconState::Mature);
    }

    // @trace spec:tray-icon-lifecycle
    #[test]
    fn icon_transitions_to_dried_on_failure() {
        // Start healthy
        let healthy = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::AllHealthy)
            .forge_available(true)
            .build();
        assert_eq!(healthy.tray_icon_state, TrayIconState::Mature);

        // Fail
        let failed = TrayStateBuilder::new()
            .enclave_status(EnclaveStatus::Failed)
            .forge_available(true)
            .build();
        assert_eq!(failed.tray_icon_state, TrayIconState::Dried);
    }

    // @trace spec:tray-icon-lifecycle
    #[test]
    fn icon_mapping_is_deterministic() {
        // Same status should always map to same icon
        for _ in 0..5 {
            assert_eq!(
                enclave_status_to_icon(EnclaveStatus::AllHealthy),
                TrayIconState::Mature
            );
            assert_eq!(
                enclave_status_to_icon(EnclaveStatus::Failed),
                TrayIconState::Dried
            );
            assert_eq!(
                enclave_status_to_icon(EnclaveStatus::Verifying),
                TrayIconState::Pup
            );
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn menu_hides_dynamic_region_when_forge_unavailable() {
        // When forge_available=false, menu should have exactly 4 items
        // (status, separator, version, quit) and NO dynamic items
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .projects(vec![ProjectEntry {
                name: "project-alpha".to_string(),
                path: PathBuf::from("/tmp/project-alpha"),
            }])
            .build();

        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        // Filter to non-root items
        let items: Vec<_> = flat.iter().filter(|(id, _)| *id != 0).collect();

        // Should have exactly 4 items
        assert_eq!(
            items.len(),
            4,
            "Expected 4 items when forge unavailable, got {}. Items: {:?}",
            items.len(),
            items
                .iter()
                .filter_map(|(_, p)| p.get("label"))
                .collect::<Vec<_>>()
        );

        let labels = labels(&menu);

        // Should NOT contain any dynamic items
        assert!(!labels.contains(&"Seedlings".to_string()));
        assert!(!labels.contains(&"project-alpha".to_string()));
        assert!(!labels.contains(&"Clone Project".to_string()));
        assert!(!labels.contains(&"GitHub Login".to_string()));
    }

    // @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states
    #[test]
    fn menu_collapses_on_failed_enclave_status() {
        // When enclave_status=Failed, menu should hide dynamic region
        // even if forge_available=true
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::Failed)
            .projects(vec![ProjectEntry {
                name: "project-beta".to_string(),
                path: PathBuf::from("/tmp/project-beta"),
            }])
            .build();

        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        let items: Vec<_> = flat.iter().filter(|(id, _)| *id != 0).collect();

        // Should have exactly 4 items (status, separator, version, quit)
        assert_eq!(
            items.len(),
            4,
            "Expected 4 items in Failed state, got {}",
            items.len()
        );

        let labels = labels(&menu);

        // Status should show failed state
        assert!(labels.contains(&"🥀 Unhealthy environment".to_string()));

        // No dynamic items
        assert!(!labels.contains(&"Seedlings".to_string()));
        assert!(!labels.contains(&"project-beta".to_string()));
        assert!(!labels.contains(&"GitHub Login".to_string()));
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn no_disabled_items_in_dynamic_region() {
        // When dynamic region is visible, all items in it should be enabled
        // (not disabled)
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .projects(vec![ProjectEntry {
                name: "test-proj".to_string(),
                path: PathBuf::from("/tmp/test-proj"),
            }])
            .build();

        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        // Check that no non-base items are disabled
        for (id, props) in flat.iter() {
            // Skip root (id=0) and base items (1, 2, 30, 31)
            if matches!(id, 0 | 1 | 2 | 30 | 31) {
                continue;
            }

            // All dynamic items should be visible (in the menu)
            assert_eq!(
                props
                    .get("visible")
                    .and_then(|v| v.try_clone().ok())
                    .and_then(|v| bool::try_from(v).ok()),
                Some(true),
                "Item {} should be visible in dynamic region",
                id
            );
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn menu_items_match_current_status() {
        // Verify that status text in menu matches current enclave status
        let test_cases = vec![
            (EnclaveStatus::Verifying, "☐ Verifying environment..."),
            (EnclaveStatus::ProxyReady, "☐🌐 Building enclave..."),
            (EnclaveStatus::GitReady, "☐🌐🪞 Building git mirror..."),
            (EnclaveStatus::AllHealthy, "✓ Environment OK"),
            (EnclaveStatus::Failed, "🥀 Unhealthy environment"),
        ];

        for (status, expected_text) in test_cases {
            let state = TrayStateBuilder::new()
                .enclave_status(status)
                .forge_available(status == EnclaveStatus::AllHealthy)
                .build();

            let menu = build_menu(&state);
            let labels = labels(&menu);

            assert!(
                labels.contains(&expected_text.to_string()),
                "Expected status text '{}' for {:?}, got labels: {:?}",
                expected_text,
                status,
                labels
            );
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn base_items_never_disabled() {
        // Verify the 4 base items (status, separator, version, quit)
        // are never disabled across any state
        let states = vec![
            TrayStateBuilder::new()
                .forge_available(false)
                .enclave_status(EnclaveStatus::Verifying)
                .build(),
            TrayStateBuilder::new()
                .forge_available(true)
                .enclave_status(EnclaveStatus::AllHealthy)
                .build(),
            TrayStateBuilder::new()
                .forge_available(true)
                .enclave_status(EnclaveStatus::Failed)
                .build(),
        ];

        for state in states {
            let menu = build_menu(&state);
            let mut flat = Vec::new();
            flatten_layout(&menu, &mut flat);

            for (id, props) in flat.iter() {
                match id {
                    1 => {
                        // Status: always disabled (informational)
                        assert_eq!(
                            props
                                .get("enabled")
                                .and_then(|v| v.try_clone().ok())
                                .and_then(|v| bool::try_from(v).ok()),
                            Some(false),
                            "Status (id=1) should be disabled"
                        );
                    }
                    2 => {
                        // Separator: check it exists
                    }
                    30 => {
                        // Version: always disabled (informational)
                        assert_eq!(
                            props
                                .get("enabled")
                                .and_then(|v| v.try_clone().ok())
                                .and_then(|v| bool::try_from(v).ok()),
                            Some(false),
                            "Version (id=30) should be disabled"
                        );
                    }
                    31 => {
                        // Quit: always enabled
                        assert_eq!(
                            props
                                .get("enabled")
                                .and_then(|v| v.try_clone().ok())
                                .and_then(|v| bool::try_from(v).ok()),
                            Some(true),
                            "Quit (id=31) should be enabled"
                        );
                    }
                    _ => {}
                }
            }
        }
    }

    // @trace gap:TR-005: Unit tests for AsyncTaskExecutor non-blocking behavior
    #[test]
    fn async_executor_spawn_task_non_blocking() {
        // @trace gap:TR-005: Verify task spawning returns immediately (< 1ms)
        let executor = AsyncTaskExecutor::new(10);

        let start = std::time::Instant::now();
        for _ in 0..5 {
            let _ = executor.spawn_task(|| {
                std::thread::sleep(std::time::Duration::from_secs(1));
            });
        }
        let elapsed = start.elapsed();

        // Task spawning should return almost immediately (< 5ms even with 5 tasks)
        assert!(
            elapsed.as_millis() < 5,
            "Task spawn should be non-blocking, took {}ms",
            elapsed.as_millis()
        );
    }

    #[test]
    fn async_executor_respects_bounded_queue() {
        // @trace gap:TR-005: Verify queue is bounded and rejects when full
        let executor = AsyncTaskExecutor::new(2);

        // First two tasks should succeed (fill the queue)
        assert!(
            executor
                .spawn_task(|| {
                    std::thread::sleep(std::time::Duration::from_secs(10));
                })
                .is_ok()
        );
        assert!(
            executor
                .spawn_task(|| {
                    std::thread::sleep(std::time::Duration::from_secs(10));
                })
                .is_ok()
        );

        // Third task should fail (queue full)
        assert!(executor.spawn_task(|| {}).is_err());
    }

    #[test]
    fn async_executor_completes_tasks() {
        // @trace gap:TR-005: Verify tasks actually execute (not dropped)
        let executor = AsyncTaskExecutor::new(10);
        let counter = Arc::new(std::sync::atomic::AtomicUsize::new(0));

        for _ in 0..5 {
            let counter_clone = counter.clone();
            executor
                .spawn_task(move || {
                    counter_clone.fetch_add(1, std::sync::atomic::Ordering::Release);
                })
                .unwrap();
        }

        // Give executor thread time to process all tasks
        std::thread::sleep(std::time::Duration::from_millis(200));

        let final_count = counter.load(std::sync::atomic::Ordering::Acquire);
        assert_eq!(final_count, 5, "All 5 tasks should have executed");
    }

    #[test]
    fn async_executor_drop_graceful_shutdown() {
        // @trace gap:TR-005: Verify executor shuts down cleanly when dropped
        {
            let executor = AsyncTaskExecutor::new(10);
            let _ = executor.spawn_task(|| {
                std::thread::sleep(std::time::Duration::from_millis(100));
            });
            // executor dropped here
        }

        // Should not panic or deadlock
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    #[test]
    fn tray_service_owns_executor() {
        // @trace gap:TR-005: Verify TrayService initializes AsyncTaskExecutor
        let state = test_state(SelectedAgent::OpenCode, true);
        let service = TrayService::new(state);

        // Should be able to spawn a task
        let result = service.task_executor.spawn_task(|| {});
        assert!(result.is_ok(), "TrayService executor should be ready");
    }
}

/// Run native tray mode using a pure D-Bus StatusNotifierItem path.
///
/// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle
pub fn run_tray_mode(config_path: Option<String>) -> Result<(), String> {
    let root = super::find_checkout_root()?;
    let version = super::VERSION.trim().to_string();
    let state = TrayUiState::new(root.clone(), version.clone(), discover_projects());
    let service = Arc::new(TrayService::new(state));

    if let Some(path) = config_path {
        info!("Tray started with config path: {path}");
    }

    let runtime =
        tokio::runtime::Runtime::new().map_err(|e| format!("failed to create runtime: {e}"))?;
    let _connection = runtime.block_on(async {
        let conn = build_connection(service.clone()).await?;
        service.attach_connection(conn.clone());
        register_with_watcher(&conn, &service.service_name).await;
        Ok::<Connection, String>(conn)
    })?;
    runtime.block_on(async move {
        let item_ctxt = SignalContext::new(service.connection(), service.item_path.as_str())
            .map_err(|e| e.to_string())?;
        let menu_ctxt = SignalContext::new(service.connection(), service.menu_path.as_str())
            .map_err(|e| e.to_string())?;
        let _ = StatusNotifierItemIface::new_icon(&item_ctxt).await;
        let _ = StatusNotifierItemIface::new_status(&item_ctxt).await;
        let _ = StatusNotifierItemIface::new_tool_tip(&item_ctxt).await;
        let _ = DbusMenuIface::layout_updated(&menu_ctxt, service.snapshot().revision, 0).await;

        futures::future::pending::<()>().await;
        #[allow(unreachable_code)]
        Ok::<(), String>(())
    })?;

    Ok(())
}
