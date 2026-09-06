// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle, spec:security-privacy-isolation, spec:browser-isolation-tray-integration, spec:host-browser-mcp, spec:runtime-logging, spec:logging-levels, spec:remote-projects
// @trace spec:podman-container-spec, spec:podman-orchestration
// @trace spec:browser-daemon-tracking, spec:browser-tray-notifications, spec:tray-projects-rename
// @trace spec:tray-host-control-socket, spec:vm-provisioning-lifecycle, spec:signal-handling
//! Native Linux tray service backed by StatusNotifierItem and DBusMenu.
//!
//! The tray owns the Linux menu/icon surface. Menu actions launch the repo's
//! existing container entrypoints so the tray stays thin.

pub mod cloud;

use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Instant;

use image::GenericImageView;
use tracing::{Level, info, span, warn};
use zbus::object_server::SignalContext;
use zbus::{Connection, ConnectionBuilder, fdo, interface};
use zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::enclave_no_proxy;
use crate::remote_projects;
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, ErrorCode, MAX_MESSAGE_BYTES, WIRE_VERSION, decode, encode,
};
use tillandsias_core::config::{self, SelectedAgent};
use tillandsias_core::genus::TrayIconState;
use tillandsias_host_shell::menu_state as shared_menu;
use tillandsias_podman::{
    ContainerSpec, MountMode, container_exists_sync, image_exists_sync, podman_available_sync,
    stop_container_sync,
};

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
#[allow(dead_code)] // ProxyReady/GitReady stay reachable through the legacy probe path
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

    /// LEGACY: pre-minimal-ux status text. Kept only because the existing
    /// tests still cross-check the old emoji set; the live tray uses
    /// [`status_label`] keyed off [`TrayStatusStage`] instead.
    #[allow(dead_code)]
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

// @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states
/// Cumulative left-to-right emoji stack describing the enclave launch pipeline.
///
/// Each variant *adds* one emoji to the prefix produced by the previous one,
/// so the user sees the chain literally fill in as containers come online:
///
/// ```text
/// PreLaunch       ☑️ Verifying environment…
/// NetworkUp       ☑️🕸️  Network ready
/// ProxyStarting   ☑️🕸️🔌  Proxy starting…
/// GitStarting     ☑️🕸️🔌🌿  Git starting…
/// InferenceStart  ☑️🕸️🔌🌿🧠  Inference starting…
/// ForgeStarting   ☑️🕸️🔌🌿🧠🦾  Forge starting…
/// RouterStarting  ☑️🕸️🔌🌿🧠🦾🌐  Router starting…
/// AllReady        ☑️🕸️🔌🌿🧠🦾🌐 ✅ OK
/// ShuttingDown    🌵 Shutting down…
/// Failed(stage)   <prefix up to stage-1> ❌ <descriptor>
/// PodmanMissing   ❌ Podman not available
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
enum TrayStatusStage {
    PreLaunch,
    NetworkUp,
    ProxyStarting,
    GitStarting,
    InferenceStarting,
    ForgeStarting,
    RouterStarting,
    AllReady,
    /// Emitted when the user clicks Quit but the runtime is still draining.
    /// Reserved for the launch-pipeline integration (other agent).
    ShuttingDown,
    /// Failure at the given stage. `descriptor` is appended after the
    /// preserved prefix as ` ❌ <descriptor>`.
    Failed {
        stage: Box<TrayStatusStage>,
        descriptor: String,
    },
    /// Special hard-error sentinel rendered as a flat "❌ Podman not available".
    PodmanMissing,
}

/// Map a [`TrayStatusStage`] to its rendered tray status label.
///
/// The stack is cumulative: each non-failure variant returns the prefix from
/// the previous stage plus its own emoji and the human-readable suffix.
///
/// @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states
fn status_label(stage: &TrayStatusStage) -> String {
    // Emoji-only prefix produced when this stage *completes* successfully.
    // For the "Failed" / "ShuttingDown" / "PodmanMissing" variants this is
    // bypassed below.
    fn prefix(stage: &TrayStatusStage) -> String {
        match stage {
            TrayStatusStage::PreLaunch => String::from("\u{2611}\u{FE0F}"),
            TrayStatusStage::NetworkUp => {
                format!("{} \u{1F578}\u{FE0F}", prefix(&TrayStatusStage::PreLaunch))
            }
            TrayStatusStage::ProxyStarting => {
                format!("{}\u{1F50C}", prefix(&TrayStatusStage::NetworkUp))
            }
            TrayStatusStage::GitStarting => {
                format!("{}\u{1F33F}", prefix(&TrayStatusStage::ProxyStarting))
            }
            TrayStatusStage::InferenceStarting => {
                format!("{}\u{1F9E0}", prefix(&TrayStatusStage::GitStarting))
            }
            TrayStatusStage::ForgeStarting => {
                format!("{}\u{1F9BE}", prefix(&TrayStatusStage::InferenceStarting))
            }
            TrayStatusStage::RouterStarting => {
                format!("{}\u{1F310}", prefix(&TrayStatusStage::ForgeStarting))
            }
            TrayStatusStage::AllReady => prefix(&TrayStatusStage::RouterStarting),
            // The remaining variants are not reachable through the cumulative
            // chain; callers handle them in `status_label` directly.
            TrayStatusStage::ShuttingDown
            | TrayStatusStage::Failed { .. }
            | TrayStatusStage::PodmanMissing => String::new(),
        }
    }

    match stage {
        TrayStatusStage::PreLaunch => format!("{} Verifying environment\u{2026}", prefix(stage)),
        TrayStatusStage::NetworkUp => format!("{}  Network ready", prefix(stage)),
        TrayStatusStage::ProxyStarting => format!("{}  Proxy starting\u{2026}", prefix(stage)),
        TrayStatusStage::GitStarting => format!("{}  Git starting\u{2026}", prefix(stage)),
        TrayStatusStage::InferenceStarting => {
            format!("{}  Inference starting\u{2026}", prefix(stage))
        }
        TrayStatusStage::ForgeStarting => format!("{}  Forge starting\u{2026}", prefix(stage)),
        TrayStatusStage::RouterStarting => format!("{}  Router starting\u{2026}", prefix(stage)),
        TrayStatusStage::AllReady => format!("{} \u{2705} OK", prefix(stage)),
        TrayStatusStage::ShuttingDown => String::from("\u{1F335} Shutting down\u{2026}"),
        TrayStatusStage::Failed { stage, descriptor } => {
            // Keep the cumulative prefix up to the predecessor of `stage`,
            // i.e. exactly the emojis that *already* succeeded.
            let preserved = match stage.as_ref() {
                TrayStatusStage::PreLaunch => String::new(),
                TrayStatusStage::NetworkUp => prefix(&TrayStatusStage::PreLaunch),
                TrayStatusStage::ProxyStarting => prefix(&TrayStatusStage::NetworkUp),
                TrayStatusStage::GitStarting => prefix(&TrayStatusStage::ProxyStarting),
                TrayStatusStage::InferenceStarting => prefix(&TrayStatusStage::GitStarting),
                TrayStatusStage::ForgeStarting => prefix(&TrayStatusStage::InferenceStarting),
                TrayStatusStage::RouterStarting => prefix(&TrayStatusStage::ForgeStarting),
                TrayStatusStage::AllReady => prefix(&TrayStatusStage::RouterStarting),
                TrayStatusStage::ShuttingDown
                | TrayStatusStage::Failed { .. }
                | TrayStatusStage::PodmanMissing => String::new(),
            };
            // Descriptors can carry full error chains; bound them here too
            // since several call sites assign status_label() output to
            // status_text directly, bypassing set_status (order 288).
            let descriptor = sanitize_status_text(descriptor);
            if preserved.is_empty() {
                format!("\u{274C} {descriptor}")
            } else {
                format!("{preserved} \u{274C} {descriptor}")
            }
        }
        TrayStatusStage::PodmanMissing => String::from("\u{274C} Podman not available"),
    }
}

/// Hard-cap for the rendered status menu label, in characters. A status
/// item longer than one short line makes the whole menu unusable (order
/// 288: a full error chain with podman argv + container diagnostics
/// rendered as the label, spanning offscreen so even Quit was
/// unreachable). Full error text still reaches stderr via the callers'
/// eprintln — the menu shows only the first line, truncated.
const STATUS_LABEL_MAX_CHARS: usize = 120;

/// Reduce arbitrary status text (possibly a multi-KB, multi-line error
/// chain) to a single bounded menu-safe line: first line only, interior
/// whitespace collapsed, hard length cap with an ellipsis.
/// @trace spec:tray-minimal-ux
fn sanitize_status_text(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or("");
    let collapsed = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= STATUS_LABEL_MAX_CHARS {
        collapsed
    } else {
        let truncated: String = collapsed.chars().take(STATUS_LABEL_MAX_CHARS).collect();
        format!("{truncated}\u{2026}")
    }
}

/// Map the existing enclave health state machine onto the new cumulative
/// emoji stack. Coarse-grained transitions only — the per-container starting
/// states are emitted by the launch pipeline itself once it adopts the new
/// enum.
fn enclave_status_to_stage(status: EnclaveStatus) -> TrayStatusStage {
    match status {
        EnclaveStatus::Verifying => TrayStatusStage::PreLaunch,
        EnclaveStatus::ProxyReady => TrayStatusStage::GitStarting,
        EnclaveStatus::GitReady => TrayStatusStage::InferenceStarting,
        EnclaveStatus::AllHealthy => TrayStatusStage::AllReady,
        EnclaveStatus::Failed => TrayStatusStage::Failed {
            stage: Box::new(TrayStatusStage::PreLaunch),
            descriptor: "Unhealthy environment".to_string(),
        },
    }
}

// GitHub auth state is no longer derived from host `gh auth status` (which
// read the host keyring — the wrong source of truth now that the login flow
// stores the token in Vault at secret/github/token). The tray gates on
// `crate::vault_bootstrap::is_github_logged_in()` instead.
// @trace spec:tillandsias-vault — plan step `github-login-vault-native-flow`.

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProjectEntry {
    /// Short name — for local projects, the directory basename; for cloud
    /// projects, the bare repo name (e.g. `forge`). `cloud_project_by_name`
    /// indexes by this field, so it must stay unique inside its scope.
    name: String,
    path: PathBuf,
    /// Cloud-only: the GitHub `owner/repo` slug used as the menu label so the
    /// user sees the same identifier `gh` returns. `None` for local projects
    /// and for cloud entries built before the GitHub fetch landed.
    /// @trace spec:tray-ux, spec:remote-projects
    full_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaunchKind {
    OpenCode,
    OpenCodeWeb,
    Observatorium,
    Claude,
    /// Codex CLI agent — launches `entrypoint-forge-codex.sh` in the host
    /// terminal. @trace spec:tray-ux
    Codex,
    Antigravity,
    Maintenance,
}

// @trace spec:tray-minimal-ux
#[derive(Debug, Clone)]
struct TrayUiState {
    #[allow(dead_code)] // consumed by legacy `handle_root_terminal`; retained for tests
    root: PathBuf,
    version: String,
    status_text: String,
    tray_icon_state: TrayIconState,
    projects: Vec<ProjectEntry>,
    /// Cloud-side projects (e.g. GitHub repos) the user can attach to.
    /// Populated by [`cloud::refresh_cloud_projects_if_stale`] which shells
    /// out to `gh` with a 5-minute TTL.
    pub(super) cloud_projects: Vec<ProjectEntry>,
    /// Timestamp of the last *successful* `gh` fetch that populated
    /// [`Self::cloud_projects`]. `None` means we've never fetched (and the
    /// menu should render `(loading…)`); `Some` means we've fetched at least
    /// once (the list may still be empty — render `(no repos)`).
    /// @trace spec:tray-ux, spec:remote-projects
    pub(super) last_fetched: Option<Instant>,
    /// True while a `gh` refresh task is running. AboutToShow can fire for
    /// both the root menu and the Cloud submenu during one user gesture; this
    /// guard prevents duplicate refresh/layout-update races while expanding.
    /// @trace spec:no-terminal-flicker, spec:remote-projects
    pub(super) cloud_refresh_in_flight: bool,
    /// One-shot "we already told the user to run --github-login this session"
    /// guard. Cloud refresh fires from multiple paths on startup (initial
    /// fetch + AboutToShow on the root menu + AboutToShow on the Cloud
    /// submenu) and without this flag we print the same "no GitHub
    /// credentials yet" stderr line N times before the user has any chance
    /// to react. Reset on successful auth (see GitHubLogin click handler).
    /// @trace spec:tray-ux, spec:remote-projects
    pub(super) cloud_no_secret_warned: bool,
    /// True when `--debug` is set on the binary. Threaded into the cloud
    /// refresh / clone helpers so the containerized-gh subprocess shape is
    /// visible on stderr instead of disappearing behind `tracing` debug
    /// filtering. @trace spec:remote-projects
    pub(super) debug: bool,
    selected_agent: SelectedAgent,
    forge_available: bool,
    podman_available: bool,
    /// Cached result of `gh auth status`. Refreshed at tray launch and on
    /// any click of the GitHubLogin entry; never polled.
    /// @trace spec:tray-minimal-ux, spec:gh-auth-script
    is_authenticated: bool,
    /// Order 627-m3vp / 626-r7kq: has the auth probe reported AT ALL yet?
    ///
    /// `is_authenticated` is a bool, so `false` collapses two very different
    /// facts: "we have not asked yet" and "we asked and the answer was no".
    /// The launch default is `false` and the confirming probe is
    /// `is_github_logged_in` — a CONTAINER RUN — so the menu spent that whole
    /// window rendering an ENABLED sign-in row at users who were already
    /// signed in. That is the same defect the Windows and macOS trays carried
    /// through `GithubLoginState::LoggedOut` being the initial state; they got
    /// a fourth `Unknown` variant, and this flag is the Linux equivalent.
    ///
    /// Set by the background probe on BOTH outcomes — a negative observation is
    /// still an observation, and before this the probe only ever recorded
    /// success, so a genuine sign-out never became distinguishable from
    /// "still checking".
    login_observed: bool,
    /// windows-260719-2: TRUE from the instant the GitHubLogin entry is
    /// clicked (a purely local signal — no wire/probe round-trip) until the
    /// confirming Vault probe settles. Renders the login row as a disabled
    /// "Logging in…" so the menu never shows a stale actionable "GitHubLogin"
    /// mid-flow; the probe's outcome then either expands the menu (success)
    /// or falls back to the actionable login row (invalid/missing token).
    /// Only meaningful while `is_authenticated == false`.
    login_in_progress: bool,
    enclave_status: EnclaveStatus,
    revision: u32,
    /// Hash of projects list to detect when menu needs rebuild.
    #[allow(dead_code)] // retained for the project-list rebuild guard contract
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
    sender: mpsc::SyncSender<Box<dyn FnOnce() + Send>>,
    /// Flag indicating if the executor thread is still running
    is_running: Arc<AtomicBool>,
}

/// Number of worker threads draining the task queue. This MUST be > 1: a
/// single worker serializes every offloaded operation, so one slow task (a
/// containerized `gh` cloud fetch, or a multi-second enclave bring-up for an
/// agent launch) blocks all others — the menu freezes on `(loading…)` and a
/// subsequent agent-launch click never runs. A small pool keeps independent
/// menu actions responsive without unbounded thread growth.
/// @trace gap:TR-005, spec:tray-ux
const ASYNC_EXECUTOR_WORKERS: usize = 4;

impl AsyncTaskExecutor {
    /// Create a new async task executor with a bounded queue, drained by a
    /// small pool of worker threads so that one long-running task cannot stall
    /// every other queued menu action.
    /// @trace gap:TR-005
    fn new(queue_size: usize) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Box<dyn FnOnce() + Send>>(queue_size);
        let is_running = Arc::new(AtomicBool::new(true));
        // The receiver is shared across workers behind a mutex; each worker
        // briefly locks to dequeue one task, then releases the lock *before*
        // running it so peers can pick up the next task concurrently.
        let receiver = Arc::new(Mutex::new(receiver));

        for worker in 0..ASYNC_EXECUTOR_WORKERS {
            let is_running_clone = is_running.clone();
            let receiver = receiver.clone();
            std::thread::spawn(move || {
                let span = span!(Level::TRACE, "async_task_executor", worker);
                let _guard = span.enter();

                while is_running_clone.load(Ordering::Relaxed) {
                    let next = {
                        let rx = match receiver.lock() {
                            Ok(rx) => rx,
                            Err(_) => break, // poisoned — bail this worker
                        };
                        rx.recv_timeout(std::time::Duration::from_millis(100))
                    };
                    match next {
                        Ok(task) => {
                            task();
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
            });
        }

        Self { sender, is_running }
    }

    /// Spawn a non-blocking task. Returns error if queue is full.
    /// @trace gap:TR-005
    fn spawn_task<F>(&self, task: F) -> Result<(), mpsc::TrySendError<Box<dyn FnOnce() + Send>>>
    where
        F: FnOnce() + Send + 'static,
    {
        self.sender.try_send(Box::new(task))
    }
}

impl Drop for AsyncTaskExecutor {
    fn drop(&mut self) {
        self.is_running.store(false, Ordering::Release);
    }
}

type ControlSubscribers = Arc<Mutex<Vec<Arc<Mutex<UnixStream>>>>>;

fn control_socket_path() -> PathBuf {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })));
    runtime_dir.join("tillandsias/control.sock")
}

/// Base host directory holding per-lane MCP tool socket subdirectories (order 505).
/// Lives under `$XDG_RUNTIME_DIR/tillandsias/mcp` (falling back to `/run/user/<uid>/tillandsias/mcp`).
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
fn mcp_socket_base_dir() -> PathBuf {
    let runtime_dir = if let Ok(xdg) = env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg)
    } else {
        #[cfg(unix)]
        {
            let run_user = PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }));
            if run_user.is_dir() && std::fs::create_dir_all(run_user.join("tillandsias")).is_ok() {
                run_user
            } else {
                std::env::temp_dir().join("tillandsias-embedded")
            }
        }
        #[cfg(not(unix))]
        {
            std::env::temp_dir().join("tillandsias-embedded")
        }
    };
    runtime_dir.join("tillandsias/mcp")
}

/// Host directory holding the NDJSON MCP tool socket (`mcp.sock`) for a specific
/// lane `(project, instance)` (order 505).
///
/// @trace spec:mcp-tool-socket
pub fn mcp_socket_host_dir_for_lane(project: &str, instance: &str) -> PathBuf {
    let inst = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    mcp_socket_base_dir().join(format!("{project}-{inst}"))
}

/// Path of the NDJSON MCP tool socket served for in-forge agents of lane `(project, instance)`
/// (order 505). Lives in its OWN per-lane subdirectory
/// `$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock`
/// so ONLY that lane's directory — never any other lane's directory — is bind-mounted into
/// that lane's forge container.
///
/// The DIRECTORY — not the socket file — is bind-mounted into the container at
/// `/run/host/tillandsias-mcp` so a tray restart's re-bind stays visible inside an
/// already-running forge.
///
/// Attribution is kernel/filesystem-enforced: derived strictly from WHICH per-lane listener
/// accepted the connection. Process environ (/proc/<pid>/environ) is untrusted and never read.
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub fn mcp_socket_path_for_lane(project: &str, instance: &str) -> PathBuf {
    mcp_socket_host_dir_for_lane(project, instance).join("mcp.sock")
}

/// Legacy fallback socket path.
///
/// @trace spec:mcp-tool-socket
#[allow(dead_code)]
pub fn mcp_socket_path() -> PathBuf {
    mcp_socket_base_dir().join("mcp.sock")
}

// Env var that overrides the default Linux-native host project root.
// Linux native (the tray running on the user's desktop, not in-VM)
// resolves projects from the host filesystem — convention is
// `$HOME/src` unless the user pins something else. (Orphaned doc: the
// const it documented moved; kept as prose for the next reader.)

/// HAND-ROLLED FRAMING, DISPOSITIONED NOT DEFERRED (order 795-5itp).
///
/// This does not migrate to `LengthDelimitedCodec`, and the reason is
/// structural rather than effort: the tray's control socket is a BLOCKING
/// `std::os::unix::net::UnixStream` accepted with a thread per connection, and
/// the subscriber registry is `Arc<Mutex<Vec<Arc<Mutex<UnixStream>>>>>` which
/// `broadcast_control_envelope` locks and writes to synchronously. `Framed`
/// needs `tokio::io::AsyncRead + AsyncWrite`; a blocking std stream is neither,
/// so adopting it here means moving the tray's control socket onto a runtime —
/// a rewrite the packet explicitly declines.
///
/// WHAT IS AND IS NOT LEFT HERE, so nobody re-opens this expecting a safety
/// win: the bound is ALREADY the shared `MAX_MESSAGE_BYTES`, refused with the
/// same message as every other site, in both directions since 828-r2ek. The
/// packet's headline argument — nine independent bounds policies, nine chances
/// to get the maximum wrong — does not apply to this site. What remains
/// duplicated is the four lines of read_exact/from_be_bytes mechanics, which is
/// a readability cost, not a correctness one.
fn read_control_envelope(stream: &mut UnixStream) -> std::io::Result<ControlEnvelope> {
    let mut len = [0_u8; 4];
    stream.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "control frame too large",
        ));
    }
    let mut payload = vec![0_u8; len];
    stream.read_exact(&mut payload)?;
    decode(&payload).map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))
}

fn write_control_envelope(
    stream: &mut UnixStream,
    envelope: &ControlEnvelope,
) -> std::io::Result<()> {
    let payload = encode(envelope)
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))?;
    // Order 828-r2ek. The reader three lines up (:573) has always refused an
    // inbound frame over MAX_MESSAGE_BYTES; the writer never checked. An
    // oversize frame therefore went out and the PEER killed the connection,
    // so the failure surfaced at the wrong end with the sender believing it
    // had succeeded.
    //
    // LOGGED, NOT JUST RETURNED, and that is the whole point here: TEN of the
    // fifteen call sites discard this Result with
    // `let _ = write_control_envelope(...)`. A bare `?` would turn a
    // newly-refused write into a SILENT MISSING REPLY, which presents to a
    // user as a hang rather than an error — strictly worse than the unbounded
    // write it replaces. Grep the discard idiom rather than trusting a count;
    // this comment first shipped citing nine sites and a list of line numbers
    // that its own edit had already shifted (the 828-itr9 lesson, earned here).
    if payload.len() > MAX_MESSAGE_BYTES {
        warn!(
            spec = "tray-host-control-socket",
            kind = envelope.body.kind(),
            len = payload.len(),
            max = MAX_MESSAGE_BYTES,
            "refusing to write an oversize control frame; the peer would close \
             the connection on it. No reply will be sent for this message."
        );
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "outbound control frame too large",
        ));
    }
    stream.write_all(&(payload.len() as u32).to_be_bytes())?;
    stream.write_all(&payload)?;
    stream.flush()
}

/// Order 832-me6z. The write deadline every broadcast subscriber carries.
///
/// THE INVARIANT THIS EXISTS FOR: no lock covering ALL subscribers may be
/// held across an unbounded wait on ONE of them.
/// `broadcast_control_envelope` holds the subscriber-LIST lock while doing a
/// blocking `write_all` to each subscriber in turn, so a single peer that
/// stops draining fills its socket buffer and wedges every future broadcast
/// to every OTHER subscriber, forever.
///
/// THE 828-r2ek FRAME BOUND DOES NOT FIX THIS and must not be read as fixing
/// it. Capping frames at `MAX_MESSAGE_BYTES` makes the oversize path
/// unreachable, but a subscriber that merely stops reading — a wedged tray, a
/// SIGSTOPped process, a slow peer — still fills its buffer at NORMAL frame
/// sizes and produces the identical wedge. The bound removed one trigger, not
/// the mechanism.
///
/// This is `SO_SNDTIMEO`, so it bounds WRITES ONLY: the connection thread's
/// blocking `read_control_envelope` on the same stream is unaffected, which is
/// why the deadline can be applied at registration without turning idle
/// subscribers into read timeouts.
///
/// The value is a deadline, not a latency budget. A healthy local subscriber
/// on a unix socket completes a <=64 KiB write in microseconds; five seconds
/// is chosen to be far outside any legitimate scheduling delay so an expiry
/// means the peer is genuinely not draining, while still bounding the wedge to
/// something an operator experiences as a hiccup rather than a hang.
const CONTROL_SUBSCRIBER_WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Register `stream` for broadcasts, applying the write deadline FIRST.
///
/// Registration is the only place a stream enters the broadcast path, so it is
/// the one place the deadline has to be applied — a subscriber that reaches
/// `subscribers` without one reintroduces the wedge.
///
/// A stream whose deadline could not be set is REFUSED rather than registered
/// undeadlined. Dropping one subscriber costs that peer its broadcasts; a
/// single undeadlined subscriber costs EVERY peer every future broadcast, so
/// the asymmetry decides it. Returns whether the stream was registered.
fn register_control_subscriber(stream: UnixStream, subscribers: &ControlSubscribers) -> bool {
    if let Err(err) = stream.set_write_timeout(Some(CONTROL_SUBSCRIBER_WRITE_TIMEOUT)) {
        warn!(
            spec = "tray-host-control-socket",
            error = %err,
            timeout_secs = CONTROL_SUBSCRIBER_WRITE_TIMEOUT.as_secs(),
            "refusing to register a control subscriber whose write deadline could \
             not be set; an undeadlined subscriber can wedge every future broadcast"
        );
        return false;
    }
    subscribers
        .lock()
        .expect("control subscribers lock")
        .push(Arc::new(Mutex::new(stream)));
    true
}

fn broadcast_control_envelope(subscribers: &ControlSubscribers, envelope: &ControlEnvelope) {
    let mut subscribers = subscribers.lock().expect("control subscribers lock");
    subscribers.retain(|subscriber| {
        let Ok(mut stream) = subscriber.lock() else {
            return false;
        };
        match write_control_envelope(&mut stream, envelope) {
            Ok(()) => true,
            Err(err) => {
                // Order 832-me6z. `retain` already dropped a failed subscriber
                // SILENTLY. With a write deadline in place the commonest
                // failure is now a peer that stopped draining, and an operator
                // whose tray quietly stops receiving broadcasts has no way to
                // tell that from a tray that was never subscribed. WouldBlock /
                // TimedOut is the deadline expiring; anything else is the peer
                // going away.
                warn!(
                    spec = "tray-host-control-socket",
                    kind = envelope.body.kind(),
                    error = %err,
                    error_kind = ?err.kind(),
                    timeout_secs = CONTROL_SUBSCRIBER_WRITE_TIMEOUT.as_secs(),
                    "evicting a control subscriber: its broadcast write failed. \
                     A TimedOut/WouldBlock kind means the peer stopped draining \
                     and hit the write deadline."
                );
                false
            }
        }
    });
}

/// Tray-side mirror of the in-VM `VmStateHandle`. Tracks the tray
/// process's own lifecycle phase so `VmStatusRequest` over the unix
/// control socket reports the truth instead of a hardcoded value, and
/// `VmShutdownRequest` has a place to record the Draining transition.
///
/// Phase model (subset of `VmPhase` semantics applicable to the tray):
///
///   * `Starting`  — listener binding, not yet accepting.
///   * `Ready`     — accept loop running; tray serving control-socket
///     clients.
///   * `Draining`  — `VmShutdownRequest` received; tray is winding
///     down but the process is still alive.
///   * `Stopping`  — SIGTERM/SIGINT observed; tray about to exit
///     (wiring is a follow-on slice).
///   * `Failed`    — unrecoverable error during startup (reserved).
///
/// Held by the control-socket accept thread, cloned per connection
/// into `handle_control_connection`. Cheap-to-clone `Arc<RwLock>`
/// shape; reads are the hot path (every `VmStatusRequest`), writes
/// are rare (state transitions).
///
/// @trace spec:tray-host-control-socket, spec:vm-provisioning-lifecycle
/// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
#[derive(Clone)]
struct TrayPhaseHandle {
    phase: Arc<RwLock<tillandsias_control_wire::VmPhase>>,
}

impl TrayPhaseHandle {
    /// Fresh handle starting at `Starting`. Use in production
    /// construction — the tray hasn't bound its socket yet.
    fn new() -> Self {
        Self {
            phase: Arc::new(RwLock::new(tillandsias_control_wire::VmPhase::Starting)),
        }
    }

    /// Test-only constructor that skips straight to `Ready`. Used by
    /// the regression tests that exercise `handle_control_connection`
    /// directly without going through `start_control_socket_server`.
    #[cfg(test)]
    fn ready_for_test() -> Self {
        Self {
            phase: Arc::new(RwLock::new(tillandsias_control_wire::VmPhase::Ready)),
        }
    }

    fn current_phase(&self) -> tillandsias_control_wire::VmPhase {
        *self.phase.read().expect("tray phase lock")
    }

    fn set_phase(&self, next: tillandsias_control_wire::VmPhase) {
        *self.phase.write().expect("tray phase lock") = next;
    }

    /// Watch `shutdown` for a flip to true and, when it does, transition
    /// the phase to `Stopping`. Sync polling mirror of
    /// `vsock_server::VmStateHandle::watch_shutdown_and_mark_stopping` —
    /// the tray's accept loop is a `std::thread`, not a tokio task, so we
    /// poll synchronously to match. Cadence is intentionally coarse
    /// (250 ms): this only governs the lifecycle-reporting wire, not any
    /// hot-path behaviour.
    ///
    /// This is the linux-native counterpart to the vsock-side
    /// `watch_shutdown_and_mark_stopping`. The cross-host symmetry now
    /// completes Q2 of the convergence packet: windows + macOS send
    /// `VmShutdownRequest` BEFORE tearing down WSL/VZ, and the linux
    /// tray itself transitions to `Stopping` on its own SIGTERM/SIGINT,
    /// so a sibling-host client polling `VmStatusRequest` sees the
    /// lifecycle truthfully across the whole shutdown window.
    ///
    /// Idempotent. Returns once the atomic is true and the transition
    /// has been recorded.
    ///
    /// @trace spec:tray-host-control-socket, spec:vm-provisioning-lifecycle,
    ///        spec:signal-handling
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
    fn watch_shutdown_and_mark_stopping_blocking(
        &self,
        shutdown: Arc<std::sync::atomic::AtomicBool>,
    ) {
        use std::sync::atomic::Ordering;
        while !shutdown.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
        // Don't clobber a terminal Failed if some future advancer beat
        // us to it. (The tray doesn't have a Failed-producing advancer
        // today; this matches the vsock-side helper's defensive
        // pattern so the two stay symmetric.)
        if self.current_phase() != tillandsias_control_wire::VmPhase::Failed {
            self.set_phase(tillandsias_control_wire::VmPhase::Stopping);
        }
    }
}

/// Attribution identity bound to an MCP listener context (order 505).
///
/// Identity `(project, instance)` is kernel/filesystem-enforced and derived
/// from which per-lane listener accepted the connection, requiring zero `/proc`
/// reads. Process environment is untrusted and never read for attribution.
///
/// @trace spec:mcp-tool-socket
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaneIdentity {
    pub project: String,
    pub instance: String,
}

impl LaneIdentity {
    pub fn new(project: impl Into<String>, instance: impl Into<String>) -> Self {
        Self {
            project: project.into(),
            instance: instance.into(),
        }
    }
}

/// Dispatch one JSON-RPC request from an MCP client against the host-side
/// tool surface (order 363: `publish_local` / `service_status` /
/// `service_stop`). The project label comes from the SESSION (peer
/// attribution), never from the request — a forge cannot publish another
/// project's worktree by naming it.
///
/// Handles the minimum MCP method surface a real client needs:
/// `initialize`, `tools/list`, `tools/call`, and `notifications/*`
/// (silently absorbed, per JSON-RPC 2.0 notifications get no reply —
/// hence `None`). Tool-level refusals (non-WEB category, unknown tool)
/// are actionable JSON-RPC errors, not silent drops.
///
/// @trace spec:host-browser-mcp, spec:subdomain-routing-via-reverse-proxy
/// Per-LINE payload ceiling on the live per-lane NDJSON MCP socket
/// (order 779-dqsv).
///
/// Deliberately the SAME number as the retired `McpFrame` per-variant cap,
/// re-exported rather than re-invented: the payload ceiling is a property of
/// what MCP carries (screenshots, large tool results), not of which transport
/// happens to carry it. Before this, the retired path had a 4 MiB cap and the
/// LIVE path had none at all — an unbounded base64 screenshot travelled as
/// one line.
pub(crate) const MAX_MCP_LINE_BYTES: usize = tillandsias_control_wire::MAX_MCP_FRAME_BYTES;

/// Render one response line, enforcing the OUTBOUND half of the per-line cap
/// (order 779-dqsv).
///
/// This is the half with a live producer: a base64 full-page
/// `browser.screenshot` can exceed any sane line length, and writing it would
/// blow the peer's own reader instead of failing here, where the reason is
/// known and can be said. The oversized result is replaced by a typed error
/// that keeps the request's `id`, so the client still correlates the failure
/// to its call.
///
/// Pure so the replacement is testable without a tool that can actually
/// produce megabytes.
fn cap_response_line(resp: &serde_json::Value) -> String {
    let rendered = resp.to_string();
    if rendered.len() <= MAX_MCP_LINE_BYTES {
        return rendered;
    }
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": resp.get("id").cloned().unwrap_or(serde_json::Value::Null),
        "error": {
            "code": -32000,
            "message": format!(
                "ResponseTooLarge: result exceeded the {MAX_MCP_LINE_BYTES}-byte per-line cap"
            ),
        }
    })
    .to_string()
}

/// Ask the composed browser server for its tool descriptors (order 779-3trn).
///
/// Goes through `handle_request` rather than reaching into the server's
/// internals, so the advertised list is by construction the same one
/// `tools/call` dispatches against — the drift this packet exists to close
/// was precisely a dispatcher advertising a different set than it served.
fn browser_tool_descriptors(
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
) -> Vec<serde_json::Value> {
    let request = tillandsias_browser_mcp::framing::RpcRequest {
        id: Some(0),
        method: "tools/list".to_string(),
        params: serde_json::Value::Object(Default::default()),
    };
    match rt.block_on(browser.handle_request(request)) {
        tillandsias_browser_mcp::framing::RpcResponse::Success { result, .. } => result
            .get("tools")
            .and_then(|t| t.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn handle_mcp_jsonrpc(
    project_label: &str,
    req: &serde_json::Value,
    browser: &tillandsias_browser_mcp::BrowserMcpServer,
    rt: &tokio::runtime::Runtime,
) -> Option<serde_json::Value> {
    let method = req["method"].as_str().unwrap_or("");
    if method.starts_with("notifications/") {
        return None;
    }

    let debug = true; // structured logs stay on while the tunnel hardens

    let body = match method {
        "initialize" => serde_json::json!({
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": "tillandsias-host-services",
                    "version": env!("CARGO_PKG_VERSION"),
                }
            }
        }),
        // Order 779-3trn: the host-services trio PLUS the browser family.
        // The browser descriptors come from the composed server itself, so
        // what is advertised is exactly what `tools/call` will dispatch.
        "tools/list" => {
            let mut tools = vec![
                serde_json::json!({
                    "name": "publish_local",
                    "description": "Publish this project's WEB service on the local reverse proxy and return its www.<project>.localhost URL. Idempotent: re-publishing replaces the running container and keeps the same URL.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] }
                        },
                        "required": ["category"]
                    }
                }),
                serde_json::json!({
                    "name": "service_status",
                    "description": "Report the state of this project's published local service.",
                    "inputSchema": { "type": "object", "properties": {} }
                }),
                serde_json::json!({
                    "name": "service_stop",
                    "description": "Stop this project's published local service and remove its route.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "category": { "type": "string", "enum": ["WEB"] }
                        },
                        "required": ["category"]
                    }
                }),
            ];
            tools.extend(browser_tool_descriptors(browser, rt));
            serde_json::json!({ "result": { "tools": tools } })
        }
        "tools/call" => {
            let tool_name = req["params"]["name"].as_str().unwrap_or("");
            let args = req["params"]["arguments"].as_object();

            // Order 779-3trn: the browser family is served by the composed
            // BrowserMcpServer, whose project label came from the accepting
            // listener's LaneIdentity — never from this request, and never
            // from BrowserMcpServer::new()'s TILLANDSIAS_PROJECT env read.
            // Attribution stays a property of the socket (order 505).
            if tool_name.starts_with("browser.") {
                let request = tillandsias_browser_mcp::framing::RpcRequest {
                    id: req.get("id").and_then(|i| i.as_u64()),
                    method: "tools/call".to_string(),
                    params: req["params"].clone(),
                };
                let response = rt.block_on(browser.handle_request(request));
                return match response {
                    tillandsias_browser_mcp::framing::RpcResponse::Notification => None,
                    other => other
                        .to_line()
                        .ok()
                        .and_then(|line| serde_json::from_str(&line).ok()),
                };
            }

            match tool_name {
                "publish_local" => {
                    let category = args
                        .and_then(|a| a.get("category"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    match rt.block_on(crate::publish_local_service(project_label, category, debug))
                    {
                        Ok(url) => serde_json::json!({
                            "result": { "url": url, "state": "running" }
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                "service_status" => match rt.block_on(crate::service_status(project_label)) {
                    Ok(state) => serde_json::json!({
                        "result": { "state": state }
                    }),
                    Err(e) => serde_json::json!({
                        "error": { "code": -32000, "message": e }
                    }),
                },
                "service_stop" => {
                    let category = args
                        .and_then(|a| a.get("category"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    match rt.block_on(crate::service_stop(category, project_label, debug)) {
                        Ok(_) => serde_json::json!({
                            "result": { "state": "stopped" }
                        }),
                        Err(e) => serde_json::json!({
                            "error": { "code": -32000, "message": e }
                        }),
                    }
                }
                other => serde_json::json!({
                    "error": { "code": -32601, "message": format!("Unknown tool: {other}") }
                }),
            }
        }
        other => serde_json::json!({
            "error": { "code": -32601, "message": format!("Method not found: {other}") }
        }),
    };

    let mut resp = body;
    resp["jsonrpc"] = serde_json::json!("2.0");
    if let Some(id) = req.get("id") {
        resp["id"] = id.clone();
    }
    Some(resp)
}

/// Serve one NDJSON MCP connection: one JSON-RPC object per line in, one
/// per line out (notifications get no line).
///
/// Identity `(project, instance)` comes directly from the accepting listener
/// context (order 505). An unattributable peer gets a single loud deny (-32000)
/// naming the attribution gate, then the connection closes — deny loudly, then fail closed.
///
/// Project labels are validated by EQUALITY against enumerated local projects
/// before tool dispatch. Process environ is untrusted and never read.
///
/// @trace spec:mcp-tool-socket
pub fn serve_mcp_connection(stream: UnixStream, identity: Option<LaneIdentity>) {
    use std::io::{BufRead, BufReader, Write};

    let mut writer = stream;

    let Some(identity) = identity else {
        warn!(
            spec = "mcp-tool-socket",
            "unattributable MCP connection denied and closed (-32000)"
        );
        let deny = serde_json::json!({
            "jsonrpc": "2.0",
            "id": serde_json::Value::Null,
            "error": {
                "code": -32000,
                "message": "Connection cannot be attributed to a valid project lane (listener attribution required)",
            }
        });
        let _ = writeln!(writer, "{deny}");
        return;
    };

    let project_label = identity.project;

    // Validate project label by equality against the known project set (never
    // sanitize). 1031-q4pb: this site carried the INVERTED spelling of the same
    // bypass — `known.is_empty() || known.iter().any(..)` evaluates to TRUE, i.e.
    // valid, on an empty enumeration. Two spellings of one bug across four sites
    // is exactly why the check now lives in one helper that fails closed.
    //
    // This is the site that matters most: it is the MCP tool socket, so the
    // label it admits is the lane an unattributed client gets to act as.
    if let Err(reason) = crate::local_projects::validate_project_label(&project_label) {
        warn!(
            spec = "mcp-tool-socket",
            project = %project_label,
            reason = %reason,
            "MCP connection for unknown project denied and closed (-32000)"
        );
        let deny = serde_json::json!({
            "jsonrpc": "2.0",
            "id": serde_json::Value::Null,
            "error": {
                "code": -32000,
                "message": reason,
            }
        });
        let _ = writeln!(writer, "{deny}");
        return;
    }

    let Ok(read_half) = writer.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(read_half);

    // Order 779-3trn: ONE browser server and ONE runtime for the whole
    // connection.
    //
    // The label is pinned from the accepting listener's LaneIdentity, so
    // `BrowserMcpServer::new()`'s TILLANDSIAS_PROJECT env read never runs —
    // reading the environment here would reintroduce exactly the forgeable
    // attribution order 505 deleted. The per-connection instance is also
    // what makes the call semaphore mean "per session".
    //
    // MULTI-thread runtime is load-bearing and now hoisted out of the
    // per-call path (it used to be rebuilt on every tools/call): the publish
    // path re-enters podman_runtime()'s RuntimeOrHandle::block_on, which uses
    // tokio::task::block_in_place — a PANIC on current-thread runtimes ("can
    // call blocking only when running on the multi-threaded runtime"; live
    // repro 2026-07-16, first tray publish_local killed its connection
    // thread). The deny/handshake paths never hit it, so only a live publish
    // exposes a regression here.
    let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    else {
        warn!(
            spec = "mcp-tool-socket",
            "could not build the MCP connection runtime; closing"
        );
        return;
    };
    let browser = tillandsias_browser_mcp::BrowserMcpServer::with_project_label(
        tillandsias_browser_mcp::McpServerConfig::default(),
        &project_label,
        None,
    );

    loop {
        let mut raw = String::new();
        // BOUNDED read (order 779-dqsv): `.take(MAX + 1)` caps what a single
        // line can allocate. Reading the line first and measuring afterwards
        // would let a hostile or looping peer allocate without limit — the
        // exact hole this cap closes — so the ceiling is applied to the READ,
        // not to the result.
        let read = (&mut reader)
            .take(MAX_MCP_LINE_BYTES as u64 + 1)
            .read_line(&mut raw);
        let Ok(byte_count) = read else {
            return;
        };
        if byte_count == 0 {
            return; // clean EOF
        }
        if byte_count > MAX_MCP_LINE_BYTES && !raw.ends_with('\n') {
            // Oversized: drain to the next newline so the stream resyncs,
            // answer with a typed error, and keep serving. Draining is itself
            // bounded — a peer that never sends a newline just closes.
            let mut discarded = 0usize;
            loop {
                let mut sink = String::new();
                let Ok(n) = (&mut reader)
                    .take(MAX_MCP_LINE_BYTES as u64)
                    .read_line(&mut sink)
                else {
                    return;
                };
                if n == 0 {
                    return;
                }
                discarded += n;
                if sink.ends_with('\n') {
                    break;
                }
                if discarded > MAX_MCP_LINE_BYTES * 8 {
                    warn!(
                        spec = "mcp-tool-socket",
                        discarded, "peer kept sending an unterminated oversized line; closing"
                    );
                    return;
                }
            }
            warn!(
                spec = "mcp-tool-socket",
                project = %project_label,
                limit = MAX_MCP_LINE_BYTES,
                "MCP request line exceeded the per-line cap; refused"
            );
            let too_large = serde_json::json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": {
                    "code": -32000,
                    "message": format!(
                        "RequestTooLarge: one JSON-RPC object per line, at most {MAX_MCP_LINE_BYTES} bytes"
                    ),
                }
            });
            if writeln!(writer, "{too_large}").is_err() {
                return;
            }
            continue;
        }
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        let resp = match serde_json::from_str::<serde_json::Value>(line) {
            Ok(req) => handle_mcp_jsonrpc(&project_label, &req, &browser, &rt),
            Err(_) => Some(serde_json::json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": {
                    "code": -32700,
                    "message": "Parse error: expected one JSON-RPC object per line",
                }
            })),
        };
        if let Some(resp) = resp {
            let rendered = cap_response_line(&resp);
            if rendered.len() != resp.to_string().len() {
                warn!(
                    spec = "mcp-tool-socket",
                    project = %project_label,
                    limit = MAX_MCP_LINE_BYTES,
                    "MCP response exceeded the per-line cap; replaced with a typed error"
                );
            }
            if writeln!(writer, "{rendered}").is_err() {
                return;
            }
        }
    }
}

/// Global registry tracking active per-lane MCP listeners.
static ACTIVE_LANE_LISTENERS: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();

fn lane_listener_registry() -> &'static Mutex<std::collections::HashSet<String>> {
    ACTIVE_LANE_LISTENERS.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

/// Bind the NDJSON MCP tool socket for lane `(project, instance)` and serve
/// it from detached threads (order 505).
/// The socket is mode 0600 in `$XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock`.
///
/// Stale sockets from previous tray instances are unlinked before binding.
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub fn start_mcp_socket_server_for_lane(project: &str, instance: &str) -> Result<(), String> {
    let instance_clean = if instance.trim().is_empty() {
        "default"
    } else {
        instance.trim()
    };
    let lane_key = format!("{project}-{instance_clean}");
    {
        let mut reg = lane_listener_registry().lock().expect("lane registry lock");
        if reg.contains(&lane_key) {
            return Ok(());
        }
        reg.insert(lane_key);
    }

    let socket_path = mcp_socket_path_for_lane(project, instance_clean);
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create mcp socket directory: {err}"))?;
        #[cfg(unix)]
        let _ = fs::set_permissions(parent, fs::Permissions::from_mode(0o700));
    }
    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .map_err(|err| format!("failed to remove stale mcp socket: {err}"))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .map_err(|err| format!("failed to bind mcp socket: {err}"))?;
    #[cfg(unix)]
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("failed to chmod mcp socket: {err}"))?;

    let identity = LaneIdentity::new(project, instance_clean);
    std::thread::spawn(move || {
        for incoming in listener.incoming() {
            match incoming {
                Ok(stream) => {
                    let lane_id = identity.clone();
                    std::thread::spawn(move || {
                        serve_mcp_connection(stream, Some(lane_id));
                    });
                }
                Err(err) => {
                    warn!(error = %err, lane = %format!("{}-{}", identity.project, identity.instance), "mcp socket accept failed")
                }
            }
        }
    });

    Ok(())
}

/// Bind the NDJSON MCP tool sockets for all discovered local projects (order 505).
///
/// @trace spec:mcp-tool-socket, spec:tray-host-control-socket
pub fn start_mcp_socket_server() -> Result<(), String> {
    let projects = discover_projects();
    for project in &projects {
        let _ = start_mcp_socket_server_for_lane(&project.name, "default");
    }
    if projects.is_empty() {
        let _ = start_mcp_socket_server_for_lane("default", "default");
    }
    Ok(())
}

fn handle_control_connection(
    mut stream: UnixStream,
    subscribers: ControlSubscribers,
    phase_handle: TrayPhaseHandle,
) {
    let Ok(first) = read_control_envelope(&mut stream) else {
        return;
    };

    // Convergence packet item 2: consult `control_dispatch::decide_route`
    // for the routing decision. The matrix lives in the canonical module
    // so unix + vsock can never silently disagree on whether a variant
    // is supported — only one place to update when a new variant lands.
    //
    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md
    //   (item 2 of 3)
    use crate::control_dispatch::{DispatchOutcome, TransportKind, decide_route};

    let routing = decide_route(&first.body, TransportKind::UnixSocket);

    match routing {
        DispatchOutcome::Handle => {
            // The matrix says this transport handles the variant. Now
            // dispatch to the actual handler. The variant set the unix
            // path has handlers for is currently {Hello, IssueWebSession,
            // EvictProject, EnumerateLocalProjects, CloudRefreshRequest,
            // VmStatusRequest, VmShutdownRequest}; the remaining
            // matrix-Handle variants (McpFrame plus host-only stdin/pty
            // tunnel frames) need real handlers wired in follow-on
            // slices. Until those land, the inner `_` arm writes an
            // explicit Error{Unsupported} with a hint about the gap —
            // the matrix-and-handler asymmetry surfaces visibly instead
            // of silently dropping.
            match first.body {
                ControlMessage::Hello { .. } => {
                    let ack = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::HelloAck {
                            wire_version: WIRE_VERSION,
                            server_caps: vec![
                                "IssueWebSession".to_string(),
                                "EvictProject".to_string(),
                            ],
                            build_version: Some(env!("CARGO_PKG_VERSION").to_string()),
                        },
                    };
                    if write_control_envelope(&mut stream, &ack).is_err() {
                        return;
                    }
                    // Order 832-me6z: the deadline is applied HERE, at the only
                    // door into the broadcast path. See register_control_subscriber.
                    register_control_subscriber(stream, &subscribers);
                }
                ControlMessage::IssueWebSession { .. } | ControlMessage::EvictProject { .. } => {
                    // Broadcast to every registered subscriber first. This is a
                    // synchronous call: when it returns, the framed bytes have been
                    // written to each subscriber socket's send buffer, so any
                    // sidecar reading its end is guaranteed to pick the envelope up
                    // on its next poll.
                    broadcast_control_envelope(&subscribers, &first);

                    // Then ack the originator on the connection we still hold. The
                    // CLI uses this ack as the proof that the broadcast happened
                    // before it launches the browser, eliminating the OTP race that
                    // let the browser POST `/_auth/login` before the sidecar's
                    // `OtpStore` saw the cookie. The originating socket was never
                    // added to `subscribers`, so `broadcast_control_envelope` does
                    // not write to it — we have to ack it here.
                    //
                    // Ack failures are intentionally swallowed: if the originator
                    // closed early we simply have nothing to confirm to, and the
                    // broadcast has already succeeded for the real subscribers.
                    //
                    // @trace spec:opencode-web-session-otp, spec:tray-host-control-socket
                    let ack = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::IssueAck {
                            seq_acked: first.seq,
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &ack);
                }
                ControlMessage::CloudRefreshRequest { seq } => {
                    // Linux-native CloudRefreshRequest handler (Q4
                    // answer of the convergence packet). Unlike the
                    // vsock side (which fetches the GitHub token from
                    // Vault via vault-cli), the unix-side host
                    // invocation passes `token: None` and lets `gh`
                    // use the user's local auth config search path.
                    // Same wire reply shape, host-appropriate
                    // execution context.
                    //
                    // @trace spec:host-shell-architecture
                    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
                    // 731-eupn: PROPAGATE the outcome, never re-flatten it here.
                    // `fetch_cloud_projects` returns (projects, outcome) precisely
                    // so an empty list from a FAILED fetch stays distinguishable
                    // from a confirmed-empty account. Substituting
                    // `CloudRefreshOutcome::Unknown` at this seam would restore
                    // the four-outcomes-one-representation bug on the Linux lane
                    // while the macOS lane reported it correctly.
                    let (projects, outcome) = crate::cloud_projects::fetch_cloud_projects(None);
                    let reply = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::CloudRefreshReply {
                            seq_in_reply_to: seq,
                            projects,
                            outcome,
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &reply);
                }
                ControlMessage::VmStatusRequest { seq } => {
                    // Linux-native VmStatusRequest handler (Q2 answer
                    // of the convergence packet). `phase` is read
                    // from the shared `TrayPhaseHandle` which the
                    // accept thread set to `Ready` after the listener
                    // bound, and which `VmShutdownRequest` flips to
                    // `Draining`. `podman_ready` is the live check
                    // `tillandsias_podman::podman_available_sync()`.
                    //
                    // @trace spec:tray-host-control-socket
                    // @trace spec:vm-provisioning-lifecycle
                    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
                    let podman_ready = tillandsias_podman::podman_available_sync();
                    let reply = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::VmStatusReply {
                            seq_in_reply_to: seq,
                            phase: phase_handle.current_phase(),
                            podman_ready,
                            last_event: Some("linux-native-tray".to_string()),
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &reply);
                }
                ControlMessage::VmShutdownRequest {
                    seq,
                    drain_timeout_ms,
                } => {
                    // Linux-native VmShutdownRequest handler (Q2 of
                    // the convergence packet). Mirrors the in-VM
                    // vsock-side behaviour: flip phase to Draining so
                    // any concurrent VmStatusRequest observer (e.g.
                    // a separate forge or sidecar connection) sees
                    // the right state. The wire defines no
                    // VmShutdownReply variant, so we don't ack —
                    // closing the connection is the signal, same as
                    // the vsock side.
                    //
                    // Drain semantics: `drain_timeout_ms` is recorded
                    // in the structured log for operator visibility
                    // but not yet honoured by an actual drain step
                    // — the tray's real shutdown path (SIGTERM/
                    // SIGINT into the existing async-executor drain)
                    // continues to run on the signal side. Wiring
                    // `mark_stopping()` into that signal path is a
                    // follow-on slice.
                    //
                    // @trace spec:tray-host-control-socket
                    // @trace spec:vm-provisioning-lifecycle
                    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
                    phase_handle.set_phase(tillandsias_control_wire::VmPhase::Draining);
                    info!(
                        spec = "tray-host-control-socket",
                        seq,
                        drain_timeout_ms,
                        "VmShutdownRequest on unix socket; phase=Draining (drain wiring is follow-on)"
                    );
                }
                ControlMessage::McpFrame { .. } => {
                    // Postcard control.sock is NOT a per-lane socket (order 505).
                    // Environ reading is untrusted and deleted; MCP surface is served
                    // over per-lane Unix listeners. McpFrame on control.sock is refused with
                    // ErrorCode::Unsupported.
                    let err = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::Error {
                            seq_in_reply_to: Some(first.seq),
                            code: ErrorCode::Unsupported,
                            message: "Unattributable MCP frame on control socket: MCP tool surface requires per-lane socket listener".to_string(),
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &err);
                }
                other => {
                    // Matrix says Handle but no inner arm yet. Write a
                    // descriptive Error so the client knows the gap is
                    // a missing handler, not a wire-format issue.
                    let err = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::Error {
                            seq_in_reply_to: Some(first.seq),
                            code: ErrorCode::Unsupported,
                            message: format!(
                                "variant {} is on the unix-socket matrix but the handler is not implemented yet \
                                 (see plan/issues/control-socket-protocol-convergence-2026-05-25.md item 2)",
                                other.kind()
                            ),
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &err);
                }
            }
        }
        DispatchOutcome::Unsupported => {
            let err = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: first.seq,
                body: ControlMessage::Error {
                    seq_in_reply_to: Some(first.seq),
                    code: ErrorCode::Unsupported,
                    message: format!(
                        "variant {} not supported on the unix-socket transport",
                        first.body.kind()
                    ),
                },
            };
            let _ = write_control_envelope(&mut stream, &err);
        }
        DispatchOutcome::ResponseOnly => {
            // Protocol violation: a *Reply / Ack / Error / HelloAck
            // showed up as the first frame, which only the server
            // emits. Reject with a precise diagnostic so the client
            // sees the misuse.
            let err = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: first.seq,
                body: ControlMessage::Error {
                    seq_in_reply_to: Some(first.seq),
                    code: ErrorCode::Unsupported,
                    message: format!(
                        "variant {} is a response-shape frame and cannot open a connection",
                        first.body.kind()
                    ),
                },
            };
            let _ = write_control_envelope(&mut stream, &err);
        }
    }
}

/// Start the tray-owned control socket used by the router sidecar and one-shot
/// CLI publishers.
///
/// The `shutdown` atomic is the same one `install_shutdown_signal_handlers`
/// returns; we spawn a watcher thread that polls it and flips the shared
/// `TrayPhaseHandle` to `Stopping` when SIGTERM/SIGINT fires, so a
/// sibling-host client polling `VmStatusRequest` during tray exit sees the
/// real phase instead of the stale `Ready` value.
///
/// @trace spec:tray-host-control-socket, spec:opencode-web-session-otp,
///        spec:signal-handling, spec:vm-provisioning-lifecycle
/// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
fn start_control_socket_server(shutdown: Arc<std::sync::atomic::AtomicBool>) -> Result<(), String> {
    let socket_path = control_socket_path();
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create control socket directory: {err}"))?;
    }
    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .map_err(|err| format!("failed to remove stale control socket: {err}"))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .map_err(|err| format!("failed to bind control socket: {err}"))?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("failed to chmod control socket: {err}"))?;

    let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

    // The listener bound successfully — by the next line the accept
    // loop will be picking up clients, so we transition Starting ->
    // Ready. The handle is then cloned into (a) each per-connection
    // worker that needs to read/write the phase and (b) the shutdown
    // watcher below.
    //
    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
    let phase_handle = TrayPhaseHandle::new();
    phase_handle.set_phase(tillandsias_control_wire::VmPhase::Ready);

    // Shutdown watcher: when SIGTERM/SIGINT flips the shared shutdown
    // atomic, transition phase to `Stopping` so any concurrent
    // `VmStatusRequest` from a sibling host (e.g. macOS slice 20's
    // pre-VZ-stop wire shutdown or windows slice 80eceb0b's pre-WSL-
    // terminate poller) sees the truth. Sync polling matches the
    // accept loop's std::thread shape.
    //
    // @trace spec:signal-handling, spec:vm-provisioning-lifecycle
    let watcher_handle = phase_handle.clone();
    let watcher_shutdown = Arc::clone(&shutdown);
    std::thread::spawn(move || {
        watcher_handle.watch_shutdown_and_mark_stopping_blocking(watcher_shutdown);
    });

    std::thread::spawn(move || {
        for incoming in listener.incoming() {
            match incoming {
                Ok(stream) => {
                    let subscribers = subscribers.clone();
                    let phase_handle = phase_handle.clone();
                    std::thread::spawn(move || {
                        handle_control_connection(stream, subscribers, phase_handle)
                    });
                }
                Err(err) => warn!(error = %err, "control socket accept failed"),
            }
        }
    });

    Ok(())
}

#[derive(Debug)]
struct TrayService {
    /// Held behind an `Arc` so the cloud-refresh task running on the
    /// `AsyncTaskExecutor` can mutate UI state without taking the whole
    /// service by reference.
    state: Arc<Mutex<TrayUiState>>,
    connection: OnceLock<Connection>,
    item_path: String,
    menu_path: String,
    service_name: String,
    /// @trace gap:TR-005: Async executor for offloading blocking tasks
    task_executor: AsyncTaskExecutor,
    /// @trace spec:graceful-shutdown, spec:app-lifecycle
    /// Atomic flag set by the Quit handler (menu id=31) to signal graceful
    /// shutdown. The tray's main event loop polls the *signal-handler*
    /// atomic (`signal_shutdown`) instead — that one is flipped by both the
    /// Quit handler AND SIGTERM/SIGINT handlers, ensuring Quit click and
    /// external signals converge on the same exit path.
    shutdown: AtomicBool,
    /// Clone of the signal-handler atomic from
    /// `install_shutdown_signal_handlers`. Set once after construction
    /// via `attach_signal_shutdown` (which uses `OnceLock::set`) so the
    /// Quit handler can flip the same atomic the main loop polls. The
    /// main loop polls the signal-handler atomic directly — without this
    /// backlink a Quit click would set `TrayService.shutdown` but never
    /// break the main wait loop.
    signal_shutdown: OnceLock<Arc<AtomicBool>>,
    /// ORDER 944-jaef, the operator's rate-limiter directive after the sixth
    /// freeze: every state change used to emit NewIcon+NewStatus+NewToolTip+
    /// LayoutUpdated unconditionally (16 call sites), and during a forge
    /// build's status ticks with the menu OPEN each LayoutUpdated makes
    /// gnome-shell refetch the FULL layout + every property + run its
    /// unguarded GC walk — enough ticks and the session drowns for a minute
    /// at a time. Emissions are now coalesced: at most one signal group per
    /// EMIT_COOLDOWN, with a suppressed burst flagged in `emit_pending` and
    /// flushed by the 250 ms main wait loop so the FINAL state of a burst
    /// always reaches the shell.
    last_emit: std::sync::Mutex<std::time::Instant>,
    emit_pending: AtomicBool,
}

/// Minimum spacing between tray signal-emission groups (944-jaef).
/// Operator-directed: "orders of magnitude larger than the collisions,
/// probably rate limited in the order of seconds." The trailing flush in
/// the main wait loop guarantees the final state of a burst still lands,
/// so the only cost of a wide window is status-line staleness, bounded by
/// this constant.
const EMIT_COOLDOWN: std::time::Duration = std::time::Duration::from_secs(2);

#[derive(Clone)]
struct StatusNotifierItemIface(Arc<TrayService>);

#[derive(Clone)]
struct DbusMenuIface(Arc<TrayService>);

impl TrayUiState {
    #[allow(dead_code)] // retained for the cloud.rs unit-test fixture
    fn new(root: PathBuf, version: String, projects: Vec<ProjectEntry>) -> Self {
        Self::new_with_debug(root, version, projects, false)
    }

    fn new_with_debug(
        root: PathBuf,
        version: String,
        projects: Vec<ProjectEntry>,
        debug: bool,
    ) -> Self {
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
        let status_text = if !podman_available {
            status_label(&TrayStatusStage::PodmanMissing)
        } else {
            status_label(&enclave_status_to_stage(enclave_status))
        };

        // Compute hash of projects list for change detection
        let projects_hash = Self::hash_projects(&projects);

        // @trace spec:tillandsias-vault, spec:tray-minimal-ux
        // Default to false at launch — a background probe (spawned in
        // run_tray_mode_with_debug) asynchronously checks Vault and bumps
        // the menu revision when the token is confirmed. This avoids a
        // 60s Vault health timeout on the launch path.
        let is_authenticated = false;

        Self {
            root,
            version,
            status_text,
            tray_icon_state,
            projects,
            cloud_projects: Vec::new(),
            last_fetched: None,
            cloud_refresh_in_flight: false,
            cloud_no_secret_warned: false,
            debug,
            selected_agent,
            forge_available,
            podman_available,
            is_authenticated,
            // Nothing has been observed at construction time. See the field
            // doc: claiming "signed out" before asking is the defect.
            login_observed: false,
            login_in_progress: false,
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
    #[allow(dead_code)] // retained for the project-list rebuild guard contract
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
            state: Arc::new(Mutex::new(state)),
            connection: OnceLock::new(),
            item_path: ITEM_PATH.to_string(),
            menu_path: MENU_PATH.to_string(),
            service_name: format!("org.freedesktop.StatusNotifierItem-{pid}-1"),
            task_executor,
            shutdown: AtomicBool::new(false),
            signal_shutdown: OnceLock::new(),
            last_emit: std::sync::Mutex::new(
                std::time::Instant::now() - EMIT_COOLDOWN - EMIT_COOLDOWN,
            ),
            emit_pending: AtomicBool::new(false),
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

    /// Wire the signal-handler atomic so the Quit handler can flip the
    /// same atomic the main event loop polls. Must be called once before
    /// the main wait loop starts, typically right after construction in
    /// `run_tray_mode_with_debug`. Uses `OnceLock::set` so `&self` is
    /// sufficient — the `TrayService` is behind an `Arc`.
    fn attach_signal_shutdown(&self, signal: Arc<AtomicBool>) {
        let _ = self.signal_shutdown.set(signal);
    }

    fn snapshot(&self) -> TrayUiState {
        self.state.lock().expect("tray state lock poisoned").clone()
    }

    /// Cloneable handle to the shared `TrayUiState` lock. Used by the cloud
    /// fetcher so it can mutate state from the [`AsyncTaskExecutor`] without
    /// owning a reference to the whole [`TrayService`].
    fn state_handle(&self) -> Arc<Mutex<TrayUiState>> {
        self.state.clone()
    }

    fn with_state<T>(&self, f: impl FnOnce(&mut TrayUiState) -> T) -> T {
        let mut state = self.state.lock().expect("tray state lock poisoned");
        f(&mut state)
    }

    /// Re-scan `~/src` and store the result into `state.projects`.
    ///
    /// `state.projects` (the `🏠 ~/src` submenu source) is otherwise seeded
    /// only once at startup, so a freshly cloned checkout never appears in the
    /// live menu. This is the missing post-startup writer: any path that
    /// changes the on-disk `~/src` contents (clone today, fs-watch later)
    /// calls this, then `rebuild_after_state_change`, to surface the change
    /// without a tray restart.
    ///
    /// @trace spec:tray-ux, spec:remote-projects
    /// @trace plan/issues/clone-tray-ux-not-refreshed-2026-06-18.md
    fn refresh_local_projects(&self) {
        let projects = discover_projects();
        self.with_state(|state| {
            state.projects_hash = TrayUiState::hash_projects(&projects);
            state.projects = projects;
            state.bump_revision();
        });
    }

    fn refresh_snapshot(&self) -> TrayUiState {
        self.snapshot()
    }

    /// True when an emission is allowed NOW (and stamps the cooldown);
    /// false marks the burst pending for the main loop's trailing flush.
    fn emission_due(&self) -> bool {
        let mut last = self.last_emit.lock().expect("emit stamp lock");
        if last.elapsed() >= EMIT_COOLDOWN {
            *last = std::time::Instant::now();
            true
        } else {
            self.emit_pending
                .store(true, std::sync::atomic::Ordering::SeqCst);
            false
        }
    }

    /// Trailing-edge flush: called from the 250 ms main wait loop so the
    /// last state of a coalesced burst always reaches the shell.
    async fn flush_pending_emit(&self) {
        if self.emit_pending.load(std::sync::atomic::Ordering::SeqCst) && self.emission_due() {
            self.emit_pending
                .store(false, std::sync::atomic::Ordering::SeqCst);
            let _ = self.emit_refresh_now(true).await;
        }
    }

    async fn emit_refresh(&self, include_menu: bool) -> zbus::Result<()> {
        if !self.emission_due() {
            return Ok(());
        }
        self.emit_refresh_now(include_menu).await
    }

    async fn emit_refresh_now(&self, include_menu: bool) -> zbus::Result<()> {
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
            state.status_text = sanitize_status_text(&text.into());
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
                        state.status_text = status_label(&TrayStatusStage::AllReady);
                        status_changed = true;
                    }
                } else if value && state.enclave_status == EnclaveStatus::Verifying {
                    // Already in Verifying, still becoming available: transition to healthy
                    if state
                        .enclave_status
                        .can_transition_to(EnclaveStatus::AllHealthy)
                    {
                        state.enclave_status = EnclaveStatus::AllHealthy;
                        state.status_text = status_label(&TrayStatusStage::AllReady);
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

    #[allow(dead_code)]
    fn selected_agent(&self) -> SelectedAgent {
        self.snapshot().selected_agent
    }

    #[allow(dead_code)]
    fn update_selected_agent(&self, agent: SelectedAgent) {
        self.with_state(|state| {
            state.selected_agent = agent;
            state.bump_revision();
        });
    }

    /// Lookup a cloud (GitHub-sourced) project by name. Cloud projects are
    /// surfaced under the `☁️ Cloud >` submenu and may or may not exist on
    /// disk yet — `handle_launch_cloud_project` will clone if missing.
    /// @trace spec:remote-projects, spec:tray-ux
    fn cloud_project_by_name(&self, name: &str) -> Option<ProjectEntry> {
        self.snapshot()
            .cloud_projects
            .into_iter()
            .find(|project| project.name == name)
    }

    #[allow(dead_code)]
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
    podman_available_sync()
}

fn image_exists(image_tag: &str) -> bool {
    image_exists_sync(image_tag)
}

fn discover_projects() -> Vec<ProjectEntry> {
    let home = match std::env::var("HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => return Vec::new(),
    };
    discover_projects_in(&home.join("src"))
}

/// Scan a project-root directory (e.g. `~/src`) and return one
/// [`ProjectEntry`] per immediate subdirectory, sorted by name.
///
/// Factored out of [`discover_projects`] so the scan-and-sort contract that
/// backs the post-clone local refresh can be unit-tested against a temp dir
/// without mutating the process-global `HOME`.
fn discover_projects_in(src: &Path) -> Vec<ProjectEntry> {
    let mut projects = Vec::new();
    let entries = match std::fs::read_dir(src) {
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
        projects.push(ProjectEntry {
            name,
            path,
            full_name: None,
        });
    }

    projects.sort_by(|a, b| a.name.cmp(&b.name));
    projects
}

// Used by legacy `build_launch_spec` and tests; the new per-project launch
// flow goes through `super::launch_forge_agent` instead.
#[allow(dead_code)]
fn action_slug(kind: LaunchKind) -> &'static str {
    match kind {
        LaunchKind::OpenCode => "opencode",
        LaunchKind::OpenCodeWeb => "opencode-web",
        LaunchKind::Observatorium => "observatorium",
        LaunchKind::Claude => "claude",
        LaunchKind::Codex => "codex",
        LaunchKind::Antigravity => "antigravity",
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
    for pixel in rgba.as_raw().as_chunks::<4>().0 {
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

// Legacy single-container spec builder for the pre-`launch_forge_agent` flow.
// The new per-project launch path calls `super::build_forge_agent_run_argv`
// after bringing up the proxy/git/inference enclave; this helper is retained
// for the legacy `run_root_terminal` path and the build-spec unit tests.
#[allow(dead_code)]
fn build_launch_spec(project: &ProjectEntry, kind: LaunchKind, image: &str) -> ContainerSpec {
    let project_name = &project.name;
    let project_path = project
        .path
        .canonicalize()
        .unwrap_or_else(|_| project.path.clone());
    let ca_cert = PathBuf::from(tillandsias_core::ca_path::ca_dir()).join("intermediate.crt");
    let no_proxy = enclave_no_proxy();

    let mut spec = ContainerSpec::new(image.to_string())
        .name(format!(
            "tillandsias-{}-{}",
            project_name,
            action_slug(kind)
        ))
        .hostname(super::sanitize_hostname(&format!("forge-{project_name}")))
        .network("tillandsias-enclave")
        // 4096, not 512 — same 667-se87/959-fpc5 rationale as the live
        // launcher (main.rs build_forge_agent_run_args_with_vault): 512 is
        // reachable by one tool-install fork storm on floor hardware. This
        // legacy path stays value-aligned with the live one.
        .pids_limit(4096)
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
        .env("no_proxy", no_proxy.clone())
        .env("NO_PROXY", no_proxy)
        .env("PATH", "/usr/local/bin:/usr/bin");

    // Order 570: this legacy path remains reachable by the root maintenance
    // terminal and in tests. Keep its harness identity aligned with the live
    // per-project launch path; Observatorium is not an agent harness.
    spec = match kind {
        LaunchKind::OpenCode => spec.env("TILLANDSIAS_AGENT", "opencode"),
        LaunchKind::OpenCodeWeb => spec.env("TILLANDSIAS_AGENT", "opencode-web"),
        LaunchKind::Claude => spec.env("TILLANDSIAS_AGENT", "claude"),
        LaunchKind::Codex => spec.env("TILLANDSIAS_AGENT", "codex"),
        LaunchKind::Antigravity => spec.env("TILLANDSIAS_AGENT", "antigravity"),
        LaunchKind::Maintenance => spec.env("TILLANDSIAS_AGENT", "terminal"),
        LaunchKind::Observatorium => spec,
    };

    if ca_cert.exists() {
        spec = spec.bind_mount(
            ca_cert.display().to_string(),
            "/etc/tillandsias/ca.crt",
            true,
        );
    }

    let raw_instance = std::env::var("TILLANDSIAS_FORGE_INSTANCE").ok();
    let instance = raw_instance.as_deref().unwrap_or("default");
    let mcp_dir = mcp_socket_host_dir_for_lane(project_name, instance);
    if std::fs::create_dir_all(&mcp_dir).is_ok() {
        let _ = start_mcp_socket_server_for_lane(project_name, instance);
        spec = spec
            .bind_mount(
                mcp_dir.display().to_string(),
                "/run/host/tillandsias-mcp",
                true,
            )
            .env(
                "TILLANDSIAS_CONTROL_SOCKET",
                "/run/host/tillandsias-mcp/mcp.sock",
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
        LaunchKind::Observatorium => spec
            .detached()
            .persistent()
            .entrypoint("/usr/local/bin/entrypoint.sh"),
        LaunchKind::Claude => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-forge-claude.sh"),
        LaunchKind::Codex => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-forge-codex.sh"),
        LaunchKind::Antigravity => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-forge-antigravity.sh"),
        LaunchKind::Maintenance => spec
            .interactive()
            .tty()
            .entrypoint("/usr/local/bin/entrypoint-terminal.sh"),
    }
}

// Tray-initiated interactive flows (GitHub login, root maintenance shell) must
// surface in a *popup* terminal window. The tray can be started from a desktop
// shortcut with no controlling terminal at all, so we never fall back to running
// the command inline — that would either prompt in whatever terminal happened to
// launch the tray (the bug operators hit on GNOME/Fedora) or silently fail under
// a desktop shortcut. The inline path is reserved for `tillandsias --github-login`
// invoked directly from a terminal, which is handled in main.rs.
//
// Candidate order prefers the modern GNOME/Fedora default (ptyxis) and GNOME
// Console (kgx) ahead of the legacy emulators so Silverblue hosts get a real
// window instead of the inline prompt.
/// Spawn a terminal-launcher child and reap it on a detached thread.
///
/// Order 385: Ptyxis's GApplication client exits in milliseconds after
/// delegating the window to the resident `--gapplication-service`, but
/// `std::process::Child` does NOT reap on `Drop` — so a bare `.spawn()`-and-drop
/// leaks a `<defunct>` zombie parented to the tray process, one per terminal
/// launch. Move the `Child` into a detached thread that calls `wait()` so the
/// OS reclaims it. Both terminal-launch sites (`launch_in_terminal` here and
/// `launch_forge_agent` in `main.rs`) route through this helper, defined
/// ungated in `main.rs` so the non-`tray`-feature build still links.
pub(crate) fn spawn_terminal_and_reap(child: Command) -> Result<(), String> {
    crate::spawn_terminal_and_reap(child)
}

fn launch_in_terminal(title: &str, executable: &str, args: &[String]) -> Result<(), String> {
    for candidate in ["ptyxis", "gnome-terminal", "kgx", "konsole", "xterm"] {
        if terminal_present(candidate) {
            let mut child = Command::new(candidate);
            match candidate {
                // Ptyxis (GNOME/Fedora default since 47): `-- COMMAND` runs the
                // command in a fresh window with its own PTY.
                "ptyxis" => {
                    child.args(["--new-window", "-T", title, "--", executable]);
                    child.args(args);
                }
                "gnome-terminal" => {
                    child.args(["--title", title, "--", executable]);
                    child.args(args);
                }
                // GNOME Console accepts a trailing `-- COMMAND`; it has no title flag.
                "kgx" => {
                    child.args(["--", executable]);
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
            return spawn_terminal_and_reap(child);
        }
    }

    Err("no supported terminal emulator found \
         (looked for ptyxis, gnome-terminal, kgx, konsole, xterm); \
         install one to run interactive tray actions in a popup window"
        .to_string())
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
    _version: String,
    debug: bool,
) -> Result<(), String> {
    match kind {
        LaunchKind::OpenCodeWeb => {
            // OpenCode Web is already wired and brings its own enclave +
            // browser surface. Untouched per the per-project-action contract.
            let project_path = project.path.display().to_string();
            super::run_opencode_web_mode(&project_path, None, None, debug)
        }
        LaunchKind::Observatorium => {
            let project_path = project.path.display().to_string();
            super::run_observatorium_mode(&project_path, None, debug)
        }
        LaunchKind::Claude
        | LaunchKind::Codex
        | LaunchKind::OpenCode
        | LaunchKind::Antigravity
        | LaunchKind::Maintenance => {
            // @trace spec:tray-ux, spec:browser-isolation-tray-integration
            // Interactive forge launches go through the host's default
            // terminal emulator. The enclave (proxy + git + inference) is
            // brought up via the idiomatic tillandsias-podman layer, then a
            // single `podman run -it ... forge <entrypoint>` argv is handed
            // to the terminal as the user-facing TTY surface.
            let mode = match kind {
                LaunchKind::Claude => super::ForgeAgentMode::Claude,
                LaunchKind::Codex => super::ForgeAgentMode::Codex,
                LaunchKind::OpenCode => super::ForgeAgentMode::OpenCode,
                LaunchKind::Antigravity => super::ForgeAgentMode::Antigravity,
                LaunchKind::Maintenance => super::ForgeAgentMode::Maintenance,
                _ => unreachable!("non-interactive kinds branched above"),
            };
            super::launch_forge_agent(&project.name, &project.path, mode, debug)
        }
    }
}

#[allow(dead_code)]
fn run_init_action() -> Result<(), String> {
    super::run_init(false, false)
}

// Legacy root-checkout terminal launcher. The new flow launches per-project
// shells through `super::launch_forge_agent(ForgeAgentMode::Maintenance, ...)`.
#[allow(dead_code)]
fn run_root_terminal(root: &Path, version: &str) -> Result<(), String> {
    let image = format!("tillandsias-forge:v{}", version);
    let project = ProjectEntry {
        name: root
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("tillandsias")
            .to_string(),
        path: root.to_path_buf(),
        full_name: None,
    };
    let spec = build_launch_spec(&project, LaunchKind::Maintenance, &image);
    // ORDER 972-6vaj: REFUSE rather than launch. `build_run_argv` validates the
    // immutable hardening envelope in every profile now; before this it was a
    // `debug_assert!`, compiled out of release, so a root maintenance shell
    // whose argv had lost `--cap-drop=ALL` or `--userns=keep-id` would have
    // launched from a shipped binary with nothing said. This is the container
    // that least deserves a silent downgrade: it is the ROOT terminal.
    let argv = spec
        .build_run_argv()
        .map_err(|e| format!("refusing to launch the root terminal: {e}"))?;
    launch_in_terminal("Tillandsias - Root", "podman", &argv)
}

// Legacy seedling-selector handler. The new menu drives agent selection
// directly via per-project leaves; this handler is retained for tests.
#[allow(dead_code)]
fn handle_select_agent(service: Arc<TrayService>, agent: SelectedAgent) {
    service.update_selected_agent(agent);
    config::save_selected_agent(agent);
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload UI refresh to async executor (non-blocking)
    if service
        .task_executor
        .spawn_task(move || {
            let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
        })
        .is_err()
    {
        warn!("task queue full: skipping agent selection UI refresh");
    }
}

/// LIVE re-probe of a stale-negative availability snapshot.
///
/// `podman_available`/`forge_available` are captured ONCE at tray startup;
/// a tray launched during a version handover (images still building — e.g.
/// right after `./build.sh --install` bumps VERSION) caches
/// `forge_available=false`, and without this re-probe the tray refuses
/// every launch FOREVER while the top row sits at "Verifying environment…"
/// (operator dead-on-arrival repro, 2026-07-16). A positive snapshot is
/// trusted (no per-click podman cost on the happy path); a negative one is
/// re-probed, and success self-heals the status row through the existing
/// Verifying→AllHealthy transition in `set_status`.
///
/// @trace spec:tray-progress-and-icon-states, spec:menu-action-error-handling
fn recheck_environment_if_stale(
    service: &Arc<TrayService>,
    snapshot: &TrayUiState,
) -> (bool, bool) {
    let mut podman_ready = snapshot.podman_available;
    let mut forge_ready = snapshot.forge_available;
    if !(podman_ready && forge_ready) {
        podman_ready = podman_available();
        forge_ready =
            podman_ready && image_exists(&format!("tillandsias-forge:v{}", snapshot.version));
        if forge_ready {
            let _ = futures::executor::block_on(service.set_status(
                status_label(&TrayStatusStage::AllReady),
                enclave_status_to_icon(EnclaveStatus::AllHealthy),
                Some(true),
            ));
        }
    }
    (podman_ready, forge_ready)
}

/// Order 411: the actionable message shown when the forge image for the
/// running binary's version is genuinely missing and on-demand build failed.
/// It names the exact version and the remedy (`tillandsias --init`) and never
/// claims initialization is "in progress" when nothing is building.
fn forge_missing_actionable_message(version: &str, project_name: &str) -> String {
    format!(
        "forge image v{version} for project '{project_name}' is missing; run `tillandsias --init` to build it"
    )
}

/// Attempt to build the forge image for the running binary's version on
/// demand, so a tray launched after a `--install` version bump can recover
/// without a manual `tillandsias --init`. Order 411: the missing-image branch
/// must never claim initialization is "in progress" unless something is
/// actually building; this returns the real build result, and the caller
/// surfaces an actionable message only on failure.
fn try_build_forge_image_on_demand(service: &Arc<TrayService>, snapshot: &TrayUiState) -> bool {
    let msg = format!(
        "building forge image v{} (this can take several minutes)...",
        snapshot.version
    );
    eprintln!("[tillandsias] tray: {msg}");
    let _ = futures::executor::block_on(service.set_status(
        format!("🔨 {msg}"),
        TrayIconState::Building,
        None,
    ));

    let forge_tag = format!("tillandsias-forge:v{}", snapshot.version);
    let build_result =
        crate::ensure_image_exists(&snapshot.root, "forge", &forge_tag, snapshot.debug);

    match build_result {
        Ok(()) => {
            let _ = futures::executor::block_on(service.set_status(
                status_label(&TrayStatusStage::AllReady),
                enclave_status_to_icon(EnclaveStatus::AllHealthy),
                Some(true),
            ));
            true
        }
        Err(err) => {
            eprintln!("error: forge image build failed: {err}");
            false
        }
    }
}

fn handle_launch_project(service: Arc<TrayService>, project: ProjectEntry, kind: LaunchKind) {
    let snapshot = service.snapshot();
    let version = snapshot.version.clone();
    let debug = snapshot.debug;
    let service_for_emit = service.clone();
    // @trace gap:TR-005, spec:menu-action-error-handling
    // Offload project launch and UI refresh to async executor (non-blocking)

    // Always emit a click-receipt to stderr so the user sees something the
    // moment they invoke a menu item. Silent menus look broken on Fedora
    // Silverblue when nothing surfaces in the user's terminal.
    // @trace spec:tray-ux
    eprintln!(
        "[tillandsias] tray: launching {:?} for project '{}' (path={})",
        kind,
        project.name,
        project.path.display()
    );

    // Guard checks: validate preconditions before launching
    if project.name.is_empty() {
        eprintln!("error: cannot launch project with empty name");
        return;
    }

    if !project.path.exists() {
        eprintln!(
            "error: project path does not exist: {}",
            project.path.display()
        );
        return;
    }

    // Verify podman + forge image availability with a LIVE re-probe when
    // the snapshot says no (see recheck_environment_if_stale — a tray
    // started during a version handover cached false forever and every
    // launch died silently; operator dead-on-arrival repro 2026-07-16).
    let (podman_ready, mut forge_ready) = recheck_environment_if_stale(&service, &snapshot);
    if !forge_ready {
        // Order 411: a missing forge image after a `--install` version bump is
        // NOT "initialization in progress" — nothing is building on its own.
        // Try to build it on demand before refusing with an actionable message.
        forge_ready = try_build_forge_image_on_demand(&service, &snapshot);
    }
    if !forge_ready {
        let msg = forge_missing_actionable_message(&snapshot.version, &project.name);
        eprintln!("error: {msg}");
        // Refusals must be visible in the tray, not just the journal.
        // @trace spec:menu-action-error-handling, spec:tray-ux
        let _ = futures::executor::block_on(service.set_status(
            format!("🥀 {msg}"),
            TrayIconState::Dried,
            None,
        ));
        return;
    }

    if !podman_ready {
        let msg = format!(
            "podman is not available; cannot launch project '{}'",
            project.name
        );
        eprintln!("error: {msg}");
        let _ = futures::executor::block_on(service.set_status(
            format!("🥀 {msg}"),
            TrayIconState::Dried,
            None,
        ));
        return;
    }

    let project_name = project.name.clone();
    if service
        .task_executor
        .spawn_task(move || {
            let result = launch_project_action(project.clone(), kind, version, debug);
            if let Err(err) = result {
                eprintln!(
                    "error: project launch failed for '{}': {}",
                    project.name, err
                );
                // Surface the failure on the tray icon/status so the user
                // sees feedback in addition to the stderr line (which is
                // invisible when the tray is launched from a .desktop entry).
                // @trace spec:tray-ux, spec:menu-action-error-handling
                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("🥀 Launch failed: {}", err),
                    TrayIconState::Dried,
                    None,
                ));
            }
            let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
        })
        .is_err()
    {
        eprintln!(
            "error: task queue full; cannot launch project '{}' (too many concurrent operations)",
            project_name
        );
    }
}

/// Launch a cloud-side (GitHub-sourced) project: idempotent clone into
/// `~/src/<name>` then attach via `handle_launch_project`.
///
/// Flow:
/// 1. If `~/src/<name>` does not exist, clone it from the project's repo URL
///    (derived from the cloud `ProjectEntry`'s path or display name).
/// 2. If it does exist, run `git fetch` to refresh remote state. This is
///    best-effort — failure does not block the launch.
/// 3. Hand the resulting on-disk path to the standard `launch_project_action`
///    via `handle_launch_project` so all four interactive launch kinds
///    (Claude / Codex / OpenCode / Maintenance) flow through the same
///    enclave + terminal pipeline.
///
/// @trace spec:remote-projects, spec:tray-ux, spec:browser-isolation-tray-integration
fn handle_launch_cloud_project(service: Arc<TrayService>, cloud: ProjectEntry, kind: LaunchKind) {
    if cloud.name.is_empty() {
        eprintln!("error: cloud project has empty name; cannot launch");
        return;
    }

    let snapshot = service.snapshot();
    // Live re-probe on a stale-negative snapshot (same dead-on-arrival class
    // as handle_launch_project; see recheck_environment_if_stale).
    let (podman_ready, mut forge_ready) = recheck_environment_if_stale(&service, &snapshot);
    if !podman_ready {
        let msg = format!(
            "podman unavailable; cannot launch cloud project '{}'",
            cloud.name
        );
        eprintln!("error: {msg}");
        let _ = futures::executor::block_on(service.set_status(
            format!("🥀 {msg}"),
            TrayIconState::Dried,
            None,
        ));
        return;
    }
    if !forge_ready {
        // Order 411: build the forge image on demand rather than claiming init
        // is in progress; only refuse with an actionable message on failure.
        forge_ready = try_build_forge_image_on_demand(&service, &snapshot);
    }
    if !forge_ready {
        let msg = forge_missing_actionable_message(&snapshot.version, &cloud.name);
        eprintln!("error: {msg}");
        let _ = futures::executor::block_on(service.set_status(
            format!("🥀 {msg}"),
            TrayIconState::Dried,
            None,
        ));
        return;
    }

    let service_for_emit = service.clone();
    let cloud_name = cloud.name.clone();
    if service
        .task_executor
        .spawn_task(move || {
            // Resolve target on-disk path: ~/src/<name>. The cloud entry's
            // `path` is the planned clone destination if the menu agent
            // populated it; otherwise we synthesize the default.
            let target_path = if cloud.path.as_os_str().is_empty() {
                let Ok(home) = std::env::var("HOME") else {
                    eprintln!("error: HOME not set; cannot resolve clone target");
                    return;
                };
                PathBuf::from(home).join("src").join(&cloud.name)
            } else {
                cloud.path.clone()
            };

            // Ground-truth gate (fresh-checkout invariant, 2026-07-20): a
            // bare `exists()` accepted empty/partial/broken checkouts — the
            // operator deleted ~/src/<project>, relaunched from the cloud
            // icon, and the agent landed on an invalid tree
            // (plan/issues/forge-launch-must-guarantee-fresh-checkout-idempotency-2026-07-20.md).
            // Quarantine anything invalid (rename aside, never delete — the
            // dir may hold user data) so the clone below re-materializes a
            // real checkout; refuse the launch loudly if even that fails.
            // 997-e4v2: only a TRUTHFUL "this is not a checkout" may rename the
            // user's directory. An unanswerable question refuses the launch and
            // leaves the tree alone.
            if target_path.exists()
                && let verdict = crate::classify_git_checkout(&target_path)
                && verdict != crate::CheckoutVerdict::Valid
            {
                if let crate::CheckoutVerdict::Indeterminate(why) = &verdict {
                    eprintln!(
                        "error: cloud launch refused for '{}': cannot evaluate the checkout at {}: {why}. Leaving it untouched.",
                        cloud.name,
                        target_path.display()
                    );
                    let _ = futures::executor::block_on(service_for_emit.set_status(
                        format!("🥀 Cannot evaluate checkout for {}: not touched", cloud.name),
                        TrayIconState::Dried,
                        None,
                    ));
                    return;
                }
                match crate::quarantine_invalid_checkout(&target_path) {
                    Ok(aside) => eprintln!(
                        "[tillandsias] cloud: {} was not a valid git checkout; moved aside to {} and re-cloning",
                        target_path.display(),
                        aside.display()
                    ),
                    Err(err) => {
                        eprintln!("error: cloud launch refused for '{}': {err}", cloud.name);
                        let _ = futures::executor::block_on(service_for_emit.set_status(
                            format!("🥀 Invalid checkout for {}: cannot repair", cloud.name),
                            TrayIconState::Dried,
                            None,
                        ));
                        return;
                    }
                }
            }

            // Step 1: clone if missing, fetch if present.
            if !target_path.exists() {
                // The cloud entry doesn't carry the owner directly — discover
                // from the cached GitHub project list. The user contract
                // example (`8007342/forge`) lives in that cache.
                //
                // IMPORTANT: prefer `GitHubProject::nwo()` (`owner/name`).
                // `project.url` is the *API* URL from `gh api user/repos`
                // (`https://api.github.com/repos/<owner>/<name>`) and is NOT
                // a valid argument to `gh repo clone` — passing it produces
                // `invalid path: /repos/<owner>/<name>`.
                // @trace spec:remote-projects
                let projects = remote_projects::discover_github_projects();
                let repo_id = projects
                    .iter()
                    .find(|p| p.name == cloud.name)
                    .map(|p| p.nwo())
                    .unwrap_or_else(|| {
                        // Fallback: best-effort guess so empty owner cases at
                        // least surface a sane git error.
                        cloud.name.clone()
                    });

                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("⏳ Cloning {} ...", cloud.name),
                    TrayIconState::Building,
                    None,
                ));
                if let Err(err) = remote_projects::clone_project_from_github(&repo_id, &target_path)
                {
                    eprintln!("error: cloud clone failed for '{}': {}", cloud.name, err);
                    let _ = futures::executor::block_on(service_for_emit.set_status(
                        format!("🥀 Clone failed: {}", cloud.name),
                        TrayIconState::Dried,
                        None,
                    ));
                    return;
                }

                // Clone succeeded on disk. Clear the "⏳ Cloning …" status and
                // re-scan ~/src so the freshly cloned checkout appears in the
                // 🏠 ~/src submenu without a tray restart. Without this the tray
                // stays stuck on "Cloning …" and the local list goes stale —
                // see plan/issues/clone-tray-ux-not-refreshed-2026-06-18.md.
                // @trace spec:tray-ux, spec:remote-projects
                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("✓ Cloned {}", cloud.name),
                    TrayIconState::Mature,
                    None,
                ));
                service_for_emit.refresh_local_projects();
                let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
            } else {
                // Best-effort refresh — git fetch is non-fatal if it fails.
                let _ = Command::new("git")
                    .arg("-C")
                    .arg(&target_path)
                    .arg("fetch")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }

            // Step 2: hand off to the standard local launch flow so all four
            // interactive kinds flow through `launch_forge_agent`.
            let entry = ProjectEntry {
                name: cloud.name.clone(),
                path: target_path,
                full_name: cloud.full_name.clone(),
            };
            handle_launch_project(service_for_emit.clone(), entry, kind);
        })
        .is_err()
    {
        eprintln!(
            "error: task queue full; cannot launch cloud project '{}'",
            cloud_name
        );
    }
}

// @trace spec:tray-ux
/// Fallback handler for the cloud-submenu overflow leaf.
///
/// Native KSNI / GMenu indicator menus do not support a scroll widget, so we
/// cap the visible cloud-project list and surface the remainder behind a
/// single "All cloud projects (N)…" item. When that item is activated we
/// dump the *full* list of repos (with their `owner/name` slugs) to stderr
/// so the user can copy-paste a NWO into a future favourites file. This is
/// explicitly the documented fallback — see TODO(@tray-overflow) in
/// `build_cloud_projects_submenu` for the eventual GtkWindow picker design.
fn handle_cloud_overflow_click(state: &TrayUiState) {
    let total = state.cloud_projects.len();
    eprintln!(
        "[tillandsias] tray: full cloud project list ({} repos):",
        total
    );
    for project in &state.cloud_projects {
        let label = project
            .full_name
            .as_deref()
            .unwrap_or(project.name.as_str());
        eprintln!("[tillandsias] tray:   - {}", label);
    }
    eprintln!(
        "[tillandsias] tray: tip — set TILLANDSIAS_MAX_CLOUD_MENU_ITEMS=<n> \
         to raise the menu cap (default {}), or use \
         ~/.config/tillandsias/cloud-projects.toml to bookmark favourites \
         once that file lands (TODO @tray-overflow)",
        MAX_CLOUD_PROJECTS_IN_MENU
    );
}

// Legacy init handler. The new minimal-UX menu drops the "Initialize images"
// item; init is auto-triggered by the tray startup probe. Retained for tests.
#[allow(dead_code)]
fn handle_init(service: Arc<TrayService>) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload initialization and UI updates to async executor (non-blocking)
    if service
        .task_executor
        .spawn_task(move || {
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
            let _ = futures::executor::block_on(service_for_emit.set_status(
                text,
                icon,
                forge_available,
            ));
        })
        .is_err()
    {
        warn!("task queue full: skipping initialization");
    }
}

fn handle_github_login(service: Arc<TrayService>) {
    // @trace spec:gh-auth-script, spec:tray-app, gap:TR-005
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload GitHub login terminal launch to async executor (non-blocking)
    if service
        .task_executor
        .spawn_task(move || {
            let args = vec!["--github-login".to_string()];
            if let Err(err) = launch_in_terminal("GitHub Login", "tillandsias", &args) {
                warn!("GitHub login terminal spawn failed: {err}");
                // Surface to the tray UX: a desktop-shortcut launch has no
                // controlling terminal, so a log-only failure would look like
                // the click did nothing.
                let _ = futures::executor::block_on(service_for_emit.set_status(
                    format!("🥀 GitHub login: {err}"),
                    TrayIconState::Dried,
                    None,
                ));
            }
            let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
        })
        .is_err()
    {
        warn!("task queue full: skipping GitHub login");
    }
}

// @trace spec:remote-projects, gap:TR-005
// Legacy clone-project handler. The new cloud-side flow lives in
// `handle_launch_cloud_project` (clone-then-launch). Retained for callers.
#[allow(dead_code)]
fn handle_clone_project(service: Arc<TrayService>, repo_url: String, repo_name: String) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload project cloning to async executor (non-blocking)
    if service
        .task_executor
        .spawn_task(move || {
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
        })
        .is_err()
    {
        warn!("task queue full: skipping project clone");
    }
}

// Legacy root-checkout terminal handler. The new menu surfaces every project
// (including the repo root) as a per-project leaf using Maintenance mode.
#[allow(dead_code)]
fn handle_root_terminal(service: Arc<TrayService>, root: PathBuf, version: String) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005: Offload terminal launch to async executor (non-blocking)
    if service
        .task_executor
        .spawn_task(move || {
            if let Err(err) = run_root_terminal(&root, &version) {
                warn!("root terminal launch failed: {err}");
            }
            let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
        })
        .is_err()
    {
        warn!("task queue full: skipping root terminal");
    }
}

// Legacy stop handler. The new menu does not currently surface a Stop leaf;
// the action-wiring agent may resurrect it as a per-project Stop action.
#[allow(dead_code)]
fn handle_stop_project(service: Arc<TrayService>, project: String) {
    let service_for_emit = service.clone();
    // @trace gap:TR-005, spec:menu-action-error-handling
    // Offload container stop to async executor (non-blocking)
    // Guard checks: validate project name and container existence
    if project.is_empty() {
        eprintln!("error: cannot stop project with empty name");
        return;
    }

    // Verify podman is available before attempting stop
    let snapshot = service.snapshot();
    if !snapshot.podman_available {
        eprintln!(
            "error: podman is not available; cannot stop project '{}'",
            project
        );
        return;
    }

    let project_name = project.clone();
    if service
        .task_executor
        .spawn_task(move || {
            let container_name = format!("tillandsias-{}-forge", project);
            if !container_exists_sync(&container_name) {
                eprintln!(
                    "error: container '{}' not found; cannot stop",
                    container_name
                );
            } else if let Err(e) = stop_container_sync(&container_name, 10) {
                eprintln!(
                    "error: failed to stop container '{}': {}",
                    container_name, e
                );
            }

            let _ = futures::executor::block_on(service_for_emit.rebuild_after_state_change());
        })
        .is_err()
    {
        eprintln!(
            "error: task queue full; cannot stop project '{}'",
            project_name
        );
    }
}

// @trace spec:tray-minimal-ux
#[allow(dead_code)]
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
//
// # Per-project action-id namespace
//
// All per-project menu items share a unified i32 id-space organised as a
// `base + offset` scheme so the action-wiring agent can recover both
// **which project** and **which action** from any leaf id with a single
// arithmetic operation. The handler scans the project tables for `id - base`
// in `0..LeafAction::COUNT`.
//
// Reserved id ranges:
//
// | Range                     | Owner                                                     |
// |---------------------------|-----------------------------------------------------------|
// | `0..=31`                  | Static top-level items (status, login, separators, quit)  |
// | `0x1000_0000..0x5000_0000`| Local project bases (`~/src/*`)                           |
// | `0x5000_0000..0x8000_0000`| Cloud project bases (e.g. `Cloud/<repo>`)                 |
// | `0x7FFF_FFFE`             | "(loading…)" placeholder leaf for empty Cloud submenu     |
// | `0x7FFF_FFFD`             | "(loading…)" placeholder leaf for empty ~/src submenu     |
//
// Offset table (must match [`LeafAction`]):
//
// | Offset | Leaf            | Emoji   |
// |--------|-----------------|---------|
// | +0     | Claude          | 👾      |
// | +1     | Codex           | 🏗️      |
// | +2     | OpenCode        | 💻      |
// | +3     | Antigravity     | 🪐      |
// | +4     | OpenCode Web    | 📐      |
// | +5     | Observatorium   | 🔭      |
// | +6     | Maintenance     | 🔧      |
// | +7     | (submenu node)  | —       |
//
// Helpers: [`local_project_base`], [`cloud_project_base`], and
// [`project_action_from_id`] are the only place this layout is encoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LeafAction {
    Claude,
    Codex,
    OpenCode,
    Antigravity,
    OpenCodeWeb,
    Observatorium,
    Maintenance,
}

impl LeafAction {
    const ALL: [LeafAction; 7] = [
        LeafAction::Claude,
        LeafAction::Codex,
        LeafAction::OpenCode,
        LeafAction::Antigravity,
        LeafAction::OpenCodeWeb,
        LeafAction::Observatorium,
        LeafAction::Maintenance,
    ];

    fn offset(self) -> i32 {
        match self {
            LeafAction::Claude => 0,
            LeafAction::Codex => 1,
            LeafAction::OpenCode => 2,
            LeafAction::Antigravity => 3,
            LeafAction::OpenCodeWeb => 4,
            LeafAction::Observatorium => 5,
            LeafAction::Maintenance => 6,
        }
    }

    fn label(self) -> &'static str {
        match self {
            LeafAction::Claude => "\u{1F47E} Claude",
            LeafAction::Codex => "\u{1F3D7}\u{FE0F} Codex",
            LeafAction::OpenCode => "\u{1F4BB} OpenCode",
            LeafAction::Antigravity => "\u{1FA90} Antigravity",
            LeafAction::OpenCodeWeb => "\u{1F4D0} OpenCode Web",
            LeafAction::Observatorium => "\u{1F52D} Observatorium",
            LeafAction::Maintenance => "\u{1F527} Maintenance",
        }
    }

    fn from_offset(offset: i32) -> Option<LeafAction> {
        Self::ALL.iter().copied().find(|a| a.offset() == offset)
    }
}

/// Project namespace: which top-level submenu owns a given project base.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProjectScope {
    Cloud,
}

const CLOUD_BASE_LO: i32 = 0x5000_0000;
const CLOUD_BASE_HI: i32 = 0x7FFF_FFF0;
const LOADING_CLOUD_ID: i32 = 0x7FFF_FFFE;
/// Disabled leaf shown at the bottom of the `☁️ Cloud >` submenu when the
/// cloud-project list overflows [`resolved_max_cloud_projects_in_menu`].
/// Activating it currently dumps the full list to stderr (see
/// `handle_cloud_overflow_click`); a future GtkWindow picker would replace
/// that fallback in place. @trace spec:tray-ux
const CLOUD_OVERFLOW_ID: i32 = 0x7FFF_FFFC;
const PROJECT_LEAF_COUNT: i32 = 7;
const PROJECT_SUBMENU_OFFSET: i32 = 7;

/// Maximum number of cloud projects rendered as top-level entries inside the
/// `☁️ Cloud >` submenu before an overflow item replaces the tail.
///
/// Native StatusNotifierItem / GMenu indicator menus do NOT support
/// scrollbars on individual submenus — a user with 22+ cloud repos sees the
/// per-project submenu chevrons clipped off the bottom of their screen, with
/// no way to reach the OpenCode / Codex / Maintenance leaves inside. Capping
/// the visible list and overflowing into a single "All cloud projects (N)…"
/// item is the standard fix.
///
/// The cap can be overridden at runtime via the
/// `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` env var (see
/// [`resolved_max_cloud_projects_in_menu`]). Power users on tall monitors who
/// genuinely want every repo inline can set it to e.g. `999`.
///
/// @trace spec:tray-ux, spec:remote-projects
pub(super) const MAX_CLOUD_PROJECTS_IN_MENU: usize = 10;

/// Resolve the effective cap, honouring `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS`
/// when set to a positive integer. Falls back to [`MAX_CLOUD_PROJECTS_IN_MENU`].
/// @trace spec:tray-ux
pub(super) fn resolved_max_cloud_projects_in_menu() -> usize {
    std::env::var("TILLANDSIAS_MAX_CLOUD_MENU_ITEMS")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(MAX_CLOUD_PROJECTS_IN_MENU)
}

/// A UNIQUE, NEVER-ZERO id for a shared-menu id string this mapper has no
/// arm for (944-jaef, the fifth desktop freeze). The old fallback was `0` —
/// the ROOT's dbusmenu id — so the first item the shared builder grew that
/// this match didn't know shipped a layout in which the root was its own
/// child. gnome-shell's appindicator extension walks the item graph with an
/// unguarded `toTraverse.shift()` loop (dbusMenu.js `_gcItems`): a root
/// cycle makes that queue grow forever, and one tray click wedged the whole
/// Wayland session. An unknown item as a DEAD, uniquely-numbered leaf is
/// harmless (its click dispatches nowhere); an unknown item as id 0 is a
/// session killer. Range 0x0800_0000..0x1000_0000 sits below CLOUD_BASE_LO and
/// above every fixed top-level id, so it collides with nothing. (It used to be
/// described relative to LOCAL_BASE_LO, removed with the local scope in
/// 997-e4v2 step 3; the range itself is unchanged.)
fn fallback_menu_id(id_str: &str) -> i32 {
    use std::hash::Hash;
    use std::hash::Hasher;
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    id_str.hash(&mut hash);
    0x0800_0000 + (hash.finish() as u32 % 0x0800_0000u32) as i32
}

fn project_base(name: &str, scope: ProjectScope) -> i32 {
    use std::hash::Hash;
    use std::hash::Hasher;
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut hash);
    let (lo, hi) = match scope {
        ProjectScope::Cloud => (CLOUD_BASE_LO, CLOUD_BASE_HI),
    };
    // Quantise to multiples of 16 so leaf offsets (0..=5) never overflow
    // into the next project's base.
    let span = ((hi - lo) / 16) as u32;
    let raw = (hash.finish() as u32) % span.max(1);
    lo + (raw as i32) * 16
}

fn cloud_project_base(name: &str) -> i32 {
    project_base(name, ProjectScope::Cloud)
}

/// Recover `(project_name, scope, action)` from a leaf id, scanning the
/// known project tables. Returns `None` if the id is neither a per-project
/// leaf nor a per-project submenu node.
fn project_action_from_id(
    state: &TrayUiState,
    id: i32,
) -> Option<(String, ProjectScope, Option<LeafAction>)> {
    for project in &state.cloud_projects {
        let base = cloud_project_base(&project.name);
        if id >= base && id < base + PROJECT_LEAF_COUNT {
            return Some((
                project.name.clone(),
                ProjectScope::Cloud,
                LeafAction::from_offset(id - base),
            ));
        }
        if id == base + PROJECT_SUBMENU_OFFSET {
            return Some((project.name.clone(), ProjectScope::Cloud, None));
        }
    }
    None
}

// @trace spec:tray-minimal-ux
/// Build the per-project submenu (seven leaves, no nesting).
///
/// The submenu node's id is `base + PROJECT_SUBMENU_OFFSET`; each leaf is
/// `base + LeafAction::offset()`. All leaves are emitted with `enabled=true`
/// **unless** podman is unavailable, in which case every leaf is disabled.
///
/// @trace dead_code — retired by order 628-p5tj convergence; kept for
/// `project_action_from_id` which shares the `project_base` scheme.
#[allow(dead_code)]
fn build_project_submenu(
    state: &TrayUiState,
    project: &ProjectEntry,
    scope: ProjectScope,
) -> MenuNode {
    let base = match scope {
        ProjectScope::Cloud => cloud_project_base(&project.name),
    };
    let leaf_enabled = state.podman_available;

    let children = LeafAction::ALL
        .iter()
        .map(|action| {
            child(node(
                base + action.offset(),
                props(vec![
                    ("label".to_string(), ov_str(action.label())),
                    ("enabled".to_string(), ov(Value::from(leaf_enabled))),
                    ("visible".to_string(), ov(Value::from(true))),
                ]),
                Vec::new(),
            ))
        })
        .collect();

    // Cloud entries carry a `full_name` (e.g. `8007342/forge`) so the user
    // sees the same identifier `gh` returns. Local entries fall back to the
    // bare directory name.
    let label = project
        .full_name
        .clone()
        .unwrap_or_else(|| project.name.clone());

    node(
        base + PROJECT_SUBMENU_OFFSET,
        props(vec![
            ("label".to_string(), ov_str(label)),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

/// Label and clickability for the cloud-overflow row (order 591-33s6).
///
/// Pure, and separated from menu construction on purpose: the built node's
/// children are serialized `OwnedValue`s, so a test that walked the finished
/// menu would be asserting against a DBus encoding rather than against the
/// decision. The decision is what the packet is about.
#[allow(dead_code)]
fn cloud_overflow_row(total: usize, visible_count: usize) -> (String, bool) {
    let hidden = total.saturating_sub(visible_count);
    // Carries BOTH counts. The pre-existing test pinned the total, because
    // that is how a user judges the scale of what is hidden; the hidden count
    // is what they are actually missing right now. Keeping both costs a few
    // characters and loses neither.
    let label = format!(
        "\u{2026} {hidden} more of {total} (raise TILLANDSIAS_MAX_CLOUD_MENU_ITEMS, now {visible_count})"
    );
    // NOT clickable. See the long note at the call site: clicking wrote to
    // stderr, which a GUI user never sees, and closed the menu.
    (label, false)
}

/// Build the `☁️ Cloud >` submenu listing every discovered cloud project.
///
/// Population of `state.cloud_projects` is owned by
/// [`cloud::refresh_cloud_projects_if_stale`]. When the list is empty the
/// placeholder text depends on whether we've ever fetched: `(loading…)`
/// before the first fetch, `(no repos)` after a successful fetch with zero
/// results.
///
/// ## Overflow handling
///
/// Native KSNI / GMenu indicator menus cannot scroll, so we cap the visible
/// list at [`resolved_max_cloud_projects_in_menu`] entries. When the
/// underlying list is longer the tail is hidden behind a final disabled-ish
/// overflow leaf (id [`CLOUD_OVERFLOW_ID`]) whose label includes the total
/// count. Activation is handled in the StatusNotifierItem event handler.
///
/// Sort order matches whatever populated `cloud_projects` (currently
/// `gh api user/repos?sort=pushed`, i.e. newest-pushed first) so the cap
/// trims the *tail* — stale repos — rather than the user's active work.
///
/// This doc block spent time attached to `cloud_overflow_row`: 112ea637c
/// inserted that function INTO THE GAP between this comment and the function
/// it describes, and a doc comment attaches to whatever follows it. No diff
/// hunk looks wrong when that happens. It carried a spec-trace annotation
/// naming tray-ux and remote-projects, which is DELIBERATELY NOT RESTORED —
/// this function is retired below, its only callers live in the `#[cfg(test)]`
/// module, and crediting a spec to code production cannot reach relocates a
/// false attribution rather than removing it. Both specs keep live coverage
/// elsewhere in this file (39 and 53 annotations across the crates). The
/// general question — how much of the trace ledger sits on unreachable items —
/// is order 1088-e8wv. Do not re-add a spec trace here without reading it.
///
/// @trace dead_code — retired by order 628-p5tj convergence.
#[allow(dead_code)]
fn build_cloud_projects_submenu(state: &TrayUiState) -> MenuNode {
    let total = state.cloud_projects.len();
    let cap = resolved_max_cloud_projects_in_menu();
    let visible_count = total.min(cap);

    let mut children: Vec<OwnedValue> = state
        .cloud_projects
        .iter()
        .take(visible_count)
        .map(|p| child(build_project_submenu(state, p, ProjectScope::Cloud)))
        .collect();
    if children.is_empty() {
        let placeholder = if state.last_fetched.is_none() {
            "(loading\u{2026})"
        } else {
            "(no repos)"
        };
        children.push(child(node(
            LOADING_CLOUD_ID,
            props(vec![
                ("label".to_string(), ov_str(placeholder)),
                ("enabled".to_string(), ov(Value::from(false))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }
    // Overflow leaf — only emitted when the underlying list exceeds the cap.
    //
    // DISABLED, and that is the fix, not a regression (order 591-33s6).
    //
    // The comment that used to sit here claimed "the cap + overflow item is
    // the standard pattern for native indicator menus and resolves the
    // user-visible clipping bug on its own". It did not. Clicking dumped the
    // full list to STDERR — which a GUI user never sees — and the menu closed,
    // because menus close on click. From the user's side the control was a
    // no-op that also cost them their menu, and relaunching showed the same
    // collapsed list. The operator reported exactly that on 2026-08-02.
    //
    // The packet's minimum acceptable outcome is that clicking must do
    // something visible OR the item must not be clickable, because a control
    // that silently does nothing is worse than an absent one. A real picker
    // needs window plumbing this module does not have (see TODO below), so the
    // item becomes an informational, non-clickable row.
    //
    // PARITY, not preference: the macOS tray already treats its overflow row
    // as inert (`MenuAction::CloudOverflow | MenuAction::Inert => {}` in
    // action_host.rs) and the Windows tray has no such control at all. Linux
    // was the only tray shipping a dead button, so disabling it converges the
    // three rather than inventing a fourth behaviour.
    //
    // The label now carries a remedy the user can actually act on instead of a
    // promise the control does not keep.
    //
    // TODO(@tray-overflow): a real project picker still wants a GtkWindow, and
    // the current tray module is pure StatusNotifierItem/DBusMenu over zbus —
    // a window would require a GTK application thread, GResource setup and a
    // theming hook, none of which exist here. That work is this packet's
    // criteria 1 and 2 and remains open.
    if total > visible_count {
        let (label, enabled) = cloud_overflow_row(total, visible_count);
        children.push(child(node(
            CLOUD_OVERFLOW_ID,
            props(vec![
                ("label".to_string(), ov_str(label)),
                ("enabled".to_string(), ov(Value::from(enabled))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }
    node(
        22,
        props(vec![
            ("label".to_string(), ov_str("\u{2601}\u{FE0F} Cloud")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
}

// ---------------------------------------------------------------------------
// Legacy helpers preserved for now: they still feed `handle_*` callbacks that
// are part of the action-wiring agent's territory. They are not invoked from
// the new `build_menu`. They will be cleaned up by the action-wiring change.
// ---------------------------------------------------------------------------

#[allow(dead_code)]
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

#[allow(dead_code)]
// @trace spec:remote-projects
fn build_clone_project_submenu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();
    let clone_enabled = state.forge_available && state.podman_available;

    // Discover GitHub projects (cached)
    let projects = remote_projects::discover_github_projects();

    // Show top 5 projects
    for (idx, project) in projects.iter().take(5).enumerate() {
        let item_id = 2000 + idx as i32;
        let label = format!("{} {}", project.owner, project.name);
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

#[allow(dead_code)]
// @trace spec:tray-ux, spec:tray-minimal-ux
/// LEGACY (pre-minimal-ux): Build a project submenu with runtime state detection.
fn build_project_submenu_legacy(state: &TrayUiState, project: &ProjectEntry) -> MenuNode {
    build_project_submenu_with_running(state, project, podman_running_web_container(&project.name))
}

#[allow(dead_code)]
// @trace spec:tray-ux, spec:tray-minimal-ux
/// LEGACY (pre-minimal-ux): Build a project submenu with explicit running state.
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

#[allow(dead_code)]
fn podman_running_web_container(project_name: &str) -> bool {
    let container_name = format!("tillandsias-{project_name}-forge");
    container_exists_sync(&container_name)
}

#[allow(dead_code)]
fn stable_project_item_id(project: &str, suffix: &str) -> i32 {
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    use std::hash::Hash;
    use std::hash::Hasher;
    project.hash(&mut hash);
    suffix.hash(&mut hash);
    let value = (hash.finish() & 0x7fff_ffff) as i32;
    if value == 0 { 1 } else { value }
}

/// Map the Linux `TrayUiState` onto the shared portable `MenuState` so the
/// shared `build()` function can compute the menu structure.
///
/// The Linux tray's `is_authenticated` / `login_in_progress` /
/// `login_observed` triple maps onto the shared `GithubLoginState` four-state
/// enum. The cloud loading state maps `last_fetched: Option<Instant>` onto
/// `cloud_projects_loaded: bool`.
fn tray_ui_state_to_menu_state(state: &TrayUiState) -> shared_menu::MenuState {
    let login = if state.is_authenticated {
        shared_menu::GithubLoginState::LoggedIn {
            handle: String::new(),
        }
    } else if state.login_in_progress {
        shared_menu::GithubLoginState::LoggingIn
    } else if state.login_observed {
        shared_menu::GithubLoginState::LoggedOut
    } else {
        shared_menu::GithubLoginState::Unknown
    };

    let cloud_projects = state
        .cloud_projects
        .iter()
        .map(|p| shared_menu::ProjectEntry {
            name: p.name.clone(),
            path: p.path.to_string_lossy().into_owned(),
            ready: false,
            full_name: p.full_name.clone(),
        })
        .collect();

    shared_menu::MenuState {
        guest_version: None,
        status_text: state.status_text.clone(),
        version: state.version.clone(),
        login,
        cloud_projects,
        cloud_projects_loaded: state.last_fetched.is_some(),
        selected_agent: shared_menu::SelectedAgent::Claude,
        gui_passthrough_available: false,
        podman_ready: state.podman_available,
        login_runtime_ready: state.login_observed || state.is_authenticated,
        target: shared_menu::TargetSurface::LinuxTray,
        provisioning_failure: None,
    }
}

/// Fixed integer IDs for top-level menu items in the DBus protocol.
/// These must stay stable: the `event()` handler dispatches on them.
const MENU_ID_STATUS: i32 = 10;
const MENU_ID_LOGIN: i32 = 20;
// ORDER 997-e4v2 step 2: MENU_ID_LOCAL_PROJECTS = 21 is REMOVED here, and the
// NUMBER 21 IS RETIRED, NOT FREED. Until step 3 removes the local row from the
// shared id contract on the other platforms, 21 still means "local projects"
// there. Reusing it for a new row mid-migration would make two menus disagree
// about what row 21 is — the kind of split that is invisible until a client
// built against one contract talks to a host built against the other.
const MENU_ID_CLOUD_PROJECTS: i32 = 22;
const MENU_ID_SEPARATOR: i32 = 29;
const MENU_ID_VERSION: i32 = 30;
const MENU_ID_QUIT: i32 = 31;

/// Map a shared `MenuItem` to a DBus integer ID.
///
/// Top-level items get fixed IDs that match the `event()` handler.
/// Per-project submenu leaves use the same hash-based scheme the
/// `project_action_from_id` resolver expects.
fn shared_id_to_int(id: &str) -> i32 {
    match id {
        shared_menu::ids::STATUS => MENU_ID_STATUS,
        shared_menu::ids::GITHUB_LOGIN => MENU_ID_LOGIN,
        shared_menu::ids::CLOUD_PROJECTS => MENU_ID_CLOUD_PROJECTS,
        shared_menu::ids::SEPARATOR => MENU_ID_SEPARATOR,
        shared_menu::ids::VERSION => MENU_ID_VERSION,
        shared_menu::ids::QUIT => MENU_ID_QUIT,
        other => {
            // Per-project items: "project.local.<name>.<verb>" or
            // "project.cloud.<name>.<verb>" — hash the project name to
            // recover the integer base, then add the verb offset.
            if let Some(rest) = other.strip_prefix("project.") {
                let (scope_str, remainder) = rest.split_once('.').unwrap_or((rest, ""));
                let (name, verb) = remainder.rsplit_once('.').unwrap_or((remainder, ""));
                let scope = match scope_str {
                    "cloud" => ProjectScope::Cloud,
                    _ => return fallback_menu_id(other),
                };
                let base = project_base(name, scope);
                let offset = match verb {
                    "claude" => 0,
                    "codex" => 1,
                    "opencode" => 2,
                    "antigravity" => 3,
                    "opencode-web" => 4,
                    "observatorium" => 5,
                    "maintenance" => 6,
                    "" => PROJECT_SUBMENU_OFFSET,
                    _ => return fallback_menu_id(other),
                };
                base + offset
            } else if other == shared_menu::ids::CLOUD_PROJECTS_EMPTY
                || other == shared_menu::ids::CLOUD_PROJECTS_LOADING
            {
                LOADING_CLOUD_ID
            } else if other == shared_menu::ids::CLOUD_PROJECTS_OVERFLOW {
                CLOUD_OVERFLOW_ID
            } else {
                fallback_menu_id(other)
            }
        }
    }
}

/// Convert a shared `MenuItem` tree into a DBus `MenuNode` tuple. This is
/// the only place the `MenuItem` → `(i32, props, children)` translation
/// happens; the shared builder's string IDs are mapped to integer IDs via
/// [`shared_id_to_int`]. Includes children only to
/// `depth` more levels (`-1` = unlimited, `0` = none — dbusmenu's
/// GetLayout `recursionDepth` semantics). A depth-pruned submenu KEEPS its
/// `children-display=submenu` property: that property is how the client
/// knows an arrow belongs there and that a deeper GetLayout will yield the
/// children — pruning it would render submenus as dead leaves.
fn shared_menu_item_to_node_depth(item: &shared_menu::MenuItem, depth: i32) -> MenuNode {
    let id = shared_id_to_int(&item.id);

    let mut p = vec![
        ("label".to_string(), ov_str(&item.label)),
        ("enabled".to_string(), ov(Value::from(item.enabled))),
        ("visible".to_string(), ov(Value::from(true))),
    ];
    if let Some(ref reason) = item.disabled_reason {
        p.push(("tooltip".to_string(), ov_str(reason)));
    }
    if !item.children.is_empty() {
        p.push(("children-display".to_string(), ov_str("submenu")));
    }

    let children: Vec<OwnedValue> = if depth == 0 {
        Vec::new()
    } else {
        let next = if depth < 0 { -1 } else { depth - 1 };
        item.children
            .iter()
            .map(|c| child(shared_menu_item_to_node_depth(c, next)))
            .collect()
    };

    node(id, props(p), children)
}

/// The shared builder's item list with the Linux-specific podman-unavailable
/// status override applied — the single source both the full-menu path and
/// the per-subtree GetLayout path convert from.
fn shared_menu_items(state: &TrayUiState) -> Vec<shared_menu::MenuItem> {
    let mut ui_state = tray_ui_state_to_menu_state(state);
    if !state.podman_available {
        ui_state.status_text = status_label(&TrayStatusStage::PodmanMissing);
    }
    match shared_menu::build(&ui_state) {
        shared_menu::MenuStructure::Provisioning { items }
        | shared_menu::MenuStructure::Ready { items }
        | shared_menu::MenuStructure::Failed { items } => items,
    }
}

/// WIRE-BOUNDARY INVARIANT (944-jaef): no item may map to id 0 (the root's
/// id — a root cycle livelocks gnome-shell's unguarded graph walk) and no
/// two items may share an id (the client's flat item map would cross-link
/// two subtrees). Violating items are DROPPED here, loudly — a missing menu
/// leaf is an inconvenience; an emitted cycle is a dead Wayland session,
/// five times over. This runs on every layout build so a future mapper gap
/// or hash collision degrades instead of freezing.
fn enforce_unique_nonroot_ids(items: &mut Vec<shared_menu::MenuItem>) {
    fn walk(items: &mut Vec<shared_menu::MenuItem>, seen: &mut std::collections::HashSet<i32>) {
        items.retain(|item| {
            let id = shared_id_to_int(&item.id);
            if id == 0 {
                eprintln!(
                    "[tray] DROPPING menu item '{}': it mapped to dbusmenu id 0 (the root) — \
                     emitting it would hand the shell a cyclic layout (944-jaef)",
                    item.id
                );
                return false;
            }
            if !seen.insert(id) {
                eprintln!(
                    "[tray] DROPPING menu item '{}': duplicate dbusmenu id {id} — \
                     emitting it would cross-link two subtrees in the shell's item map (944-jaef)",
                    item.id
                );
                return false;
            }
            true
        });
        for item in items.iter_mut() {
            walk(&mut item.children, seen);
        }
    }
    // Root id 0 is pre-seeded: any ITEM mapping to 0 is a violation.
    let mut seen = std::collections::HashSet::new();
    seen.insert(0);
    walk(items, &mut seen);
}

/// Depth-first search for the shared item whose dbusmenu id is `id`.
fn find_shared_item(items: &[shared_menu::MenuItem], id: i32) -> Option<&shared_menu::MenuItem> {
    for item in items {
        if shared_id_to_int(&item.id) == id {
            return Some(item);
        }
        if let Some(found) = find_shared_item(&item.children, id) {
            return Some(found);
        }
    }
    None
}

/// The layout GetLayout must return: the subtree rooted at `parent_id`,
/// with children included to `recursion_depth` levels (`-1` = unlimited).
/// `None` when no node carries `parent_id` — the caller turns that into a
/// DBus error rather than guessing (944-jaef: guessing was returning the
/// root tree for EVERY id, and gnome-shell's client livelocked re-queueing
/// a reply whose root never matched what it asked for).
fn build_menu_layout(
    state: &TrayUiState,
    parent_id: i32,
    recursion_depth: i32,
) -> Option<MenuNode> {
    let mut items = shared_menu_items(state);
    enforce_unique_nonroot_ids(&mut items);
    if parent_id == 0 {
        let children: Vec<OwnedValue> = if recursion_depth == 0 {
            Vec::new()
        } else {
            let next = if recursion_depth < 0 {
                -1
            } else {
                recursion_depth - 1
            };
            items
                .iter()
                .map(|item| child(shared_menu_item_to_node_depth(item, next)))
                .collect()
        };
        return Some(node(
            0,
            props(vec![
                ("label".to_string(), ov_str("Tillandsias")),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            children,
        ));
    }
    find_shared_item(&items, parent_id)
        .map(|item| shared_menu_item_to_node_depth(item, recursion_depth))
}

// @trace spec:tray-minimal-ux, spec:tray-ux, spec:tray-progress-and-icon-states
/// Build the minimal tray menu.
///
/// ## Final shape (top to bottom)
///
/// ```text
/// 1. Status (disabled, live-updating)            id=1
/// 2. 🔑 GitHub Login                             id=20  (visible iff NOT authenticated)
///    OR
///    🏠 ~/src >                                  id=21  (visible iff authenticated)
///    ☁️ Cloud >                                  id=22  (visible iff authenticated)
/// 3. ─── separator ───                           id=29
/// 4. v<full-version> — By Tlatoāni              id=30  (disabled)
/// 5. ❌ Quit Tillandsias                         id=31
/// ```
///
/// This shape is UX-curation-governed (`openspec/specs/tray-ux/spec.md` →
/// "UX curation governance"): any addition/removal/reorder requires recorded
/// operator approval. The `Reset Guest…` leaf (id=32) was removed 2026-07-22
/// by operator order; the reset survives only as `--reset-guest` (CLI).
///
/// ## Item-count contract
///
/// | Authenticated? | Visible top-level items |
/// |----------------|-------------------------|
/// | No             | 5: status + login + separator + version + quit |
/// | Yes            | 6: status + ~/src + Cloud + separator + version + quit |
///
/// ## Convergence with the shared builder (order 628-p5tj)
///
/// This function delegates to the shared portable menu builder in
/// `tillandsias-host-shell::menu_state` and converts the result to the
/// DBus `MenuNode` format. The business logic — what items appear, their
/// labels, enabled states, and the auth-gated structure — lives in ONE
/// place: the shared `build()` function. This function handles only the
/// DBus-specific translation (string IDs → integer IDs, `MenuItem` → tuple).
///
/// ## Podman-unavailable degradation
///
/// When `state.podman_available == false`, *every* per-project leaf is
/// emitted with `enabled=false` and the status line is replaced with
/// `❌ Podman not available`. The top-level shape is unchanged so the menu
/// remains stable across the failure boundary. This status-text override is
/// the one Linux-specific deviation from the shared builder's output.
//
// RELOCATED 2026-08-26 (899-q9di cycle). This block had drifted ~200 lines
// above the function it documents, stranded when three helpers were inserted
// between them, and clippy's `empty_line_after_doc_comments` was pointing at
// real misattribution rather than style: rustdoc would have published a
// menu-shape contract as the documentation for `tray_ui_state_to_menu_state`.
// The shorter duplicate that had grown here in the meantime is folded in.
fn build_menu(state: &TrayUiState) -> MenuNode {
    build_menu_layout(state, 0, -1).expect("root layout always exists")
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

    // SNI spec: WindowId is INT32 ('i'). Exporting u32 made gnome-shell log
    // "Received property WindowId with type u does not match expected type i"
    // and busy-loop at ~100% CPU from the moment the item registered —
    // the 2026-08-30 desktop freeze, live on this host, shell CPU dropping
    // 99.5% -> 2.3% the instant the tray unit stopped. Same defect class as
    // the dbusmenu Event/EventGroup signatures (938-9yh4): a wire type the
    // watcher tolerates until it doesn't.
    #[zbus(property)]
    fn window_id(&self) -> i32 {
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

    // BOTH PARAMETERS ARE LOAD-BEARING (944-jaef, the fourth desktop
    // freeze): this handler ignored parent_id and recursion_depth and
    // returned the full root tree for every request. gnome-shell's dbusmenu
    // client asks for ONE submenu at depth 1 while opening it; a reply
    // rooted at 0 never matches, the client re-queues the whole tree and
    // asks again — an unbounded Array.shift livelock that wedged the
    // Wayland session on a single tray click. Content conformance is as
    // load-bearing as wire types.
    async fn get_layout(
        &self,
        parent_id: i32,
        recursion_depth: i32,
        _property_names: Vec<String>,
    ) -> fdo::Result<(u32, MenuNode)> {
        let state = self.0.snapshot();
        match build_menu_layout(&state, parent_id, recursion_depth) {
            Some(layout) => Ok((state.revision, layout)),
            None => Err(fdo::Error::InvalidArgs(format!(
                "no menu node with id {parent_id}"
            ))),
        }
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

    // REPLY TYPE IS LOAD-BEARING, third instance of the class (944-jaef,
    // 2026-08-30): com.canonical.dbusmenu declares AboutToShow as returning a
    // SINGLE bool — "b" (needUpdate). This returned (bool, bool) — wire
    // "(bb)" — and expanding a project submenu froze the Wayland session
    // mid-grab exactly like the Event "(ib)" incident documented below.
    // AboutToShowGroup is the variant with two return values; AboutToShow is
    // not it.
    async fn about_to_show(&self, id: i32) -> fdo::Result<bool> {
        // The ☁️ Cloud submenu (id=22) opens — refresh if our TTL expired.
        // The root menu (id=0) opens — refresh too, since many trays call
        // AboutToShow on the root rather than per-submenu. Both paths are
        // event-driven, not polled.
        // @trace spec:tray-ux, spec:remote-projects
        if (id == 22 || id == 0) && cloud::cloud_refresh_due(&self.0.snapshot(), false) {
            let service = self.0.clone();
            let service_for_task = service.clone();
            let state_handle = service.state_handle();
            let debug = service.snapshot().debug;
            if service
                .task_executor
                .spawn_task(move || {
                    match cloud::refresh_cloud_projects_if_stale(state_handle, false, debug) {
                        Ok(outcome) if outcome.menu_changed() => {
                            let _ = futures::executor::block_on(
                                service_for_task.rebuild_after_state_change(),
                            );
                        }
                        Ok(_) => {}
                        Err(_) => {}
                    }
                })
                .is_err()
            {
                warn!("task queue full: skipping cloud refresh on submenu open");
            }
        }
        // The refresh above is asynchronous. Returning "needs update" here
        // asks the shell to re-read the submenu while it is opening, which
        // causes visible flicker when the cache is already fresh.
        Ok(false)
    }

    // REPLY TYPE IS LOAD-BEARING (2026-08-29 incident): com.canonical.dbusmenu
    // declares Event as returning NOTHING — `()`. This method returned
    // `(i32, bool)` (wire type "(ib)"), and gnome-shell REJECTS a reply whose
    // signature disagrees with the spec: the operator clicked the tray icon,
    // the shell logged `Method "com.canonical.dbusmenu.Event" returned type
    // "(ib)", but expected "()"` mid menu-grab, and the Wayland session froze
    // hard enough to need a session restart. The handler's work is its side
    // effects; the reply carries no information and must carry none.
    async fn event(
        &self,
        id: i32,
        event_id: &str,
        _data: OwnedValue,
        _timestamp: u32,
    ) -> fdo::Result<()> {
        if event_id != "clicked" && event_id != "opened" && event_id != "activate" {
            return Ok(());
        }

        // Static-id dispatch covers the minimal-UX skeleton. Per-project
        // leaves are routed through `project_action_from_id` so the
        // action-wiring agent can plug in handlers in a single place.
        match id {
            31 => {
                // Quit click: flip BOTH shutdown atomics so the process
                // exits even if the main loop polls the signal-handler
                // atomic (which it does — see `run_tray_mode_with_debug`).
                // Replaces the prior `std::process::exit(0)` which bypassed
                // container cleanup.
                //
                // `shutdown` is the TrayService-local flag retained for
                // any in-process consumer that checks it.  `signal_shutdown`
                // is a clone of the signal-handler atomic from
                // `install_shutdown_signal_handlers` — the one the main
                // wait loop actually polls — so this Quit click converges
                // with SIGTERM/SIGINT on the same exit path.
                //
                // @trace spec:graceful-shutdown, spec:app-lifecycle
                self.0.with_state(|state| {
                    state.tray_icon_state = TrayIconState::Stopping;
                });
                self.0.shutdown.store(true, Ordering::SeqCst);
                if let Some(sig) = self.0.signal_shutdown.get() {
                    sig.store(true, Ordering::SeqCst);
                }
            }
            20 => {
                // windows-260719-2: flip to the transitional "Logging in…"
                // state IMMEDIATELY — a purely local signal, before the
                // terminal spawn or any Vault probe — and re-render now so
                // the user never sees a stale actionable "GitHubLogin" row
                // mid-flow. A click while already in flight is a no-op (the
                // row is disabled, but dbus may still deliver the event).
                let already_in_flight = {
                    let mut in_flight = false;
                    self.0.with_state(|state| {
                        if state.login_in_progress {
                            in_flight = true;
                        } else {
                            state.login_in_progress = true;
                            state.bump_revision();
                        }
                    });
                    in_flight
                };
                if already_in_flight {
                    return Ok(());
                }
                let _ = self.0.rebuild_after_state_change().await;
                // GitHubLogin click: launch the gh login flow AND refresh
                // the cached auth state. This is the only path that
                // re-reads `gh auth status` outside tray launch.
                handle_github_login(self.0.clone());
                let service = self.0.clone();
                let service_for_task = service.clone();
                if service
                    .task_executor
                    .spawn_task(move || {
                        // @trace spec:tillandsias-vault — gate on the Vault
                        // secret, not host `gh auth status`. The login flow
                        // stores the token in Vault, never in host gh, so the
                        // host keyring is the wrong source of truth.
                        let debug = service_for_task.snapshot().debug;
                        let mut authed = false;
                        // Poll silently — debug=false suppresses per-iteration
                        // Vault log noise during the 2-minute wait window.
                        // The login flow's own output is already on stderr.
                        for i in 0..120 {
                            // Fast presence-only check (no container launch, no value read).
                            authed = crate::vault_bootstrap::is_github_key_present();
                            if authed {
                                break;
                            }
                            if debug && i % 15 == 0 {
                                eprintln!(
                                    "[tillandsias] github-login: waiting for token in Vault ({}s elapsed)",
                                    i
                                );
                            }
                            std::thread::sleep(std::time::Duration::from_secs(1));
                        }
                        service_for_task.with_state(|state| {
                            state.is_authenticated = authed;
                            // windows-260719-2: the probe settled — clear
                            // the transitional flag. Success expands the
                            // menu; an invalid/missing token falls back to
                            // the actionable "GitHubLogin" row (never a
                            // stale logged-in or in-progress rendering).
                            state.login_in_progress = false;
                            state.bump_revision();
                        });
                        // @trace spec:tray-ux, spec:remote-projects
                        // Newly-authenticated user: force-refresh the cloud
                        // list so the submenu populates without waiting for
                        // the next AboutToShow.
                        if authed {
                            remote_projects::invalidate_github_projects_cache();
                            // The user just authenticated; reset the
                            // "we already warned about missing secrets"
                            // one-shot so future logouts re-warn cleanly.
                            service_for_task.with_state(|state| {
                                state.cloud_no_secret_warned = false;
                            });
                            let _ = cloud::refresh_cloud_projects_if_stale(
                                service_for_task.state_handle(),
                                true,
                                debug,
                            );
                        }
                        let _ = futures::executor::block_on(
                            service_for_task.rebuild_after_state_change(),
                        );
                    })
                    .is_err()
                {
                    warn!("task queue full: skipping gh auth refresh");
                }
            }
            21 | 22 | 29 | 30 | 32 => {
                // submenu container, separator, or version label — no-op.
                // id=32 is the REMOVED `Reset Guest…` leaf (operator order
                // 2026-07-22, tray-ux "UX curation governance"): the menu no
                // longer emits it, and a stale click must stay inert — the
                // reset is CLI-only (`--reset-guest`).
            }
            CLOUD_OVERFLOW_ID => {
                // The menu no longer emits this leaf as clickable (order
                // 591-33s6): it is a disabled, informational row. This arm is
                // kept because a stale or non-conforming DBusMenu client can
                // still deliver the id, and the stderr listing remains useful
                // to someone running the tray from a terminal — but it is no
                // longer presented to a GUI user as a control that works.
                handle_cloud_overflow_click(&self.0.snapshot());
            }
            _ => {
                let state = self.0.snapshot();
                if let Some((project_name, scope, Some(action))) =
                    project_action_from_id(&state, id)
                {
                    // Per-project leaf: route local-project actions through
                    // the existing launch helpers, and cloud-project actions
                    // through an idempotent clone-then-launch path.
                    {
                        let kind = match action {
                            LeafAction::Claude => LaunchKind::Claude,
                            LeafAction::OpenCode => LaunchKind::OpenCode,
                            LeafAction::Antigravity => LaunchKind::Antigravity,
                            LeafAction::OpenCodeWeb => LaunchKind::OpenCodeWeb,
                            LeafAction::Observatorium => LaunchKind::Observatorium,
                            LeafAction::Maintenance => LaunchKind::Maintenance,
                            LeafAction::Codex => LaunchKind::Codex,
                        };
                        match scope {
                            ProjectScope::Cloud => {
                                if let Some(cloud_entry) =
                                    self.0.cloud_project_by_name(&project_name)
                                {
                                    handle_launch_cloud_project(self.0.clone(), cloud_entry, kind);
                                }
                            }
                        }
                    }
                }
            }
        }

        Ok(())
    }

    async fn event_group(
        &self,
        events: Vec<(i32, String, OwnedValue, u32)>,
    ) -> fdo::Result<Vec<i32>> {
        // Spec: EventGroup(events: a(isvu)) -> idErrors: ai. Both halves were
        // wrong here (same 2026-08-29 incident class as `event` above): the
        // input was flattened parallel args (wire "aisvu") and the reply was
        // a(iib). Every event dispatches through the same handler as Event
        // (unknown ids are a handled no-op there), so the error list is
        // always empty.
        for (id, event_id, data, timestamp) in events {
            self.event(id, &event_id, data, timestamp).await?;
        }
        Ok(Vec::new())
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

#[allow(dead_code)]
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

#[allow(dead_code)]
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

    // @trace spec:singleton-guard
    // Request well-known name to enforce singleton behavior at the D-Bus level.
    let dbus_proxy = fdo::DBusProxy::new(&conn)
        .await
        .map_err(|e| format!("failed to create D-Bus proxy: {e}"))?;
    match dbus_proxy
        .request_name(
            "org.tillandsias.Launcher".try_into().unwrap(),
            fdo::RequestNameFlags::DoNotQueue.into(),
        )
        .await
    {
        Ok(fdo::RequestNameReply::PrimaryOwner) => {
            tracing::debug!("acquired D-Bus name org.tillandsias.Launcher");
        }
        Ok(_) => return Err("Another tray instance is already running (D-Bus name taken)".into()),
        Err(e) => warn!("failed to request D-Bus singleton name: {e}"),
    }

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

/// Run native tray mode using a pure D-Bus StatusNotifierItem path.
///
/// @trace spec:tray-app, spec:tray-ux, spec:tray-progress-and-icon-states, spec:tray-icon-lifecycle
#[allow(dead_code)] // kept as the no-debug shim for external callers/tests
pub fn run_tray_mode(config_path: Option<String>) -> Result<(), String> {
    run_tray_mode_with_debug(config_path, false)
}

/// Same as [`run_tray_mode`] but with the `--debug` flag plumbed through so
/// the containerized-gh / cloud-refresh paths can emit `[tillandsias] gh: …`
/// stderr breadcrumbs. @trace spec:remote-projects
pub fn run_tray_mode_with_debug(config_path: Option<String>, debug: bool) -> Result<(), String> {
    let version = super::VERSION.trim().to_string();
    let root = super::resolve_runtime_asset_root(&version, debug)?;
    let state =
        TrayUiState::new_with_debug(root.clone(), version.clone(), discover_projects(), debug);
    let service = Arc::new(TrayService::new(state));

    // Install SIGTERM/SIGINT handlers BEFORE binding the control socket
    // so the shutdown atomic exists by the time the control-socket
    // watcher thread starts polling. signal-hook intercepts SIGTERM/
    // SIGINT (they don't kill the process anymore); the main runtime
    // loop below polls the atomic and exits gracefully when it flips.
    //
    // @trace spec:signal-handling, spec:tray-host-control-socket
    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
    let shutdown = crate::install_shutdown_signal_handlers()?;
    // Wire the Quit handler to the same signal-handler atomic so the
    // Quit button click triggers the main wait loop exit (not just the
    // TrayService-local `shutdown` field).  Without this, Quit would
    // set `TrayService.shutdown` but the loop below polls `shutdown` —
    // a different atomic — so the process would never exit on Quit.
    //
    // @trace spec:graceful-shutdown, spec:app-lifecycle
    service.attach_signal_shutdown(Arc::clone(&shutdown));
    start_control_socket_server(Arc::clone(&shutdown))?;
    // Order 363: the NDJSON MCP tool socket for in-forge agents. A bind
    // failure degrades the tray to no-agent-publish rather than killing
    // it — the control socket above is load-bearing, this one is not
    // (yet), so log loud and continue.
    if let Err(err) = start_mcp_socket_server() {
        warn!(
            spec = "host-browser-mcp",
            error = %err,
            "mcp tool socket failed to start; in-forge publish_local will be unavailable"
        );
    }

    // @trace spec:tillandsias-vault, spec:tray-minimal-ux
    // Asynchronous vault probe: is_github_logged_in can trigger a 60s Vault
    // health timeout if the data volume exists but Vault isn't running (e.g.
    // first tray launch after a --github-login). Instead of blocking the
    // launch path, default is_authenticated=false and confirm in background.
    //
    // Once auth is confirmed we ALSO kick the initial cloud-projects fetch
    // from inside this same task. The previous design gated a separate init
    // fetch on `service.snapshot().is_authenticated`, but that snapshot is
    // read on the launch thread *before* this probe has flipped the flag, so
    // the gate was always false and the initial fetch was silently skipped —
    // leaving the ☁️ Cloud submenu stuck on `(loading…)` until the user
    // happened to open it twice. Chaining the fetch onto the probe removes the
    // TOCTOU: the list is populated exactly once auth is known good.
    // @trace spec:tray-ux, spec:remote-projects
    {
        let service_for_probe = service.clone();
        let state_handle = service.state_handle();
        let debug = service.snapshot().debug;
        if service
            .task_executor
            .spawn_task(move || {
                let signed_in = crate::remote_projects::is_github_logged_in(debug);
                if !signed_in {
                    // Order 627-m3vp: a NEGATIVE result is still an
                    // observation. Before this the probe only ever recorded
                    // success, so `login_observed` would never flip on a
                    // genuine sign-out and the menu would sit on "Checking
                    // your account…" forever instead of offering the login
                    // row. Record it and rebuild.
                    {
                        let mut state = state_handle.lock().expect("tray state lock");
                        if !state.login_observed {
                            state.login_observed = true;
                            state.bump_revision();
                        }
                    }
                    let _ =
                        futures::executor::block_on(service_for_probe.rebuild_after_state_change());
                }
                if signed_in {
                    {
                        let mut state = state_handle.lock().expect("tray state lock");
                        if !state.is_authenticated || !state.login_observed {
                            state.is_authenticated = true;
                            state.login_observed = true;
                            state.bump_revision();
                        }
                    }
                    let _ =
                        futures::executor::block_on(service_for_probe.rebuild_after_state_change());

                    // Prepopulate the cloud list so the submenu is ready on the
                    // user's first open instead of racing an AboutToShow.
                    match cloud::refresh_cloud_projects_if_stale(state_handle, false, debug) {
                        Ok(outcome) if outcome.menu_changed() => {
                            let _ = futures::executor::block_on(
                                service_for_probe.rebuild_after_state_change(),
                            );
                        }
                        _ => {}
                    }
                }
            })
            .is_err()
        {
            warn!("task queue full: skipping background vault probe");
        }
    }

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

        // Main wait loop: poll the SIGTERM/SIGINT atomic at 250 ms
        // cadence. Matches the control-socket watcher's poll cadence
        // (start_control_socket_server) and `vsock_server`'s 250 ms
        // shutdown poll on the in-VM side — symmetric across both
        // transports. Replaces the prior `futures::future::pending`
        // forever-await: signal-hook now intercepts SIGTERM/SIGINT, so
        // the process would otherwise never exit on those signals.
        //
        // @trace spec:signal-handling, spec:tray-host-control-socket
        use std::sync::atomic::Ordering;
        while !shutdown.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            // 944-jaef: trailing flush of a coalesced signal burst.
            service.flush_pending_emit().await;
        }
        info!(
            spec = "signal-handling",
            "tray received shutdown signal; exiting gracefully (control-socket watcher already flipped phase=Stopping)"
        );
        eprintln!("Received shutdown signal");

        // Phase 5, Task 21: Execute the graceful shutdown sequence
        // (stop containers, cleanup sockets, etc.) before exiting.
        // Time-bound so a wedged container stop or vault round-trip
        // cannot hang Quit indefinitely — if the deadline fires we
        // exit anyway.
        //
        // @trace spec:graceful-shutdown, spec:app-lifecycle
        match tokio::time::timeout(
            std::time::Duration::from_secs(45),
            crate::graceful_shutdown_async(),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(e)) => warn!("graceful shutdown failed: {e}"),
            Err(_) => warn!("graceful shutdown timed out; exiting forcefully"),
        }

        // @trace spec:tillandsias-vault — revoke per-container AppRole
        // tokens before exit so vault audit reflects clean shutdown.
        // Time-bounded for the same reason as graceful shutdown.
        #[cfg(feature = "vault")]
        {
            match tokio::time::timeout(
                std::time::Duration::from_secs(10),
                crate::vault_bootstrap::revoke_pending_container_tokens(false),
            )
            .await
            {
                Ok(()) => {}
                Err(_) => warn!("vault token revocation timed out; exiting regardless"),
            }
        }

        Ok::<(), String>(())
    })?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Order 828-r2ek NEGATIVE CONTROL, and the reason this site needed care
    /// rather than a one-line bound.
    ///
    /// `read_control_envelope` has always refused an inbound frame over
    /// `MAX_MESSAGE_BYTES`; this writer refused nothing, so the tray could emit
    /// a frame its own reader would reject. The fix cannot be a bare `?`,
    /// because nine call sites discard this Result with
    /// `let _ = write_control_envelope(...)` — a newly-failing write there
    /// becomes a silent missing reply, which a user experiences as a hang. So
    /// the refusal is BOTH returned and logged, and this test pins the
    /// returned half; the `warn!` is what makes the discarded half visible.
    #[test]
    fn write_control_envelope_refuses_a_frame_over_the_shared_maximum() {
        let (mut a, mut b) = std::os::unix::net::UnixStream::pair().expect("UnixStream::pair");

        // DRAIN THE PEER. Without this the test HANGS instead of failing when
        // the guard is removed, which is a bad test — and finding that out is
        // what surfaced 832-me6z. `write_control_envelope` does a blocking
        // `write_all` with no write timeout, so an unbounded frame fills the
        // socket buffer and blocks forever rather than erroring. Measured: the
        // falsified run reported "has been running for over 60 seconds" rather
        // than a failure. A reader here makes the falsified case fail fast and
        // for the right reason (the write SUCCEEDS, so `expect_err` panics).
        let reader = std::thread::spawn(move || {
            use std::io::Read;
            let mut sink = Vec::new();
            let _ = b.read_to_end(&mut sink);
            sink.len()
        });

        let oversize = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: tillandsias_control_wire::PtyDirection::ToHost,
                bytes: vec![0xCDu8; MAX_MESSAGE_BYTES + 1],
            },
        };
        let err = write_control_envelope(&mut a, &oversize)
            .expect_err("a frame over MAX_MESSAGE_BYTES must be refused before it is written");
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(err.to_string(), "outbound control frame too large");

        // A small envelope on the same stream still writes, so the guard is a
        // bound and not a break.
        let ok = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::SubscribeAck,
        };
        write_control_envelope(&mut a, &ok).expect("a normal envelope must still be written");

        drop(a);
        let delivered = reader.join().expect("peer reader thread");
        assert!(
            delivered > 0,
            "the small envelope must have reached the peer; only the oversize one is refused"
        );
    }

    /// Order 832-me6z, big envelope helper: a frame large enough that a
    /// handful of them fill a default unix-socket send buffer. Keeping it
    /// under MAX_MESSAGE_BYTES matters — an oversize frame is refused by the
    /// 828-r2ek writer bound and would never reach `write_all`, so a test
    /// built on one would prove nothing about the wedge.
    fn fat_broadcast_envelope() -> ControlEnvelope {
        let label = "x".repeat(MAX_MESSAGE_BYTES / 2);
        ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::IssueWebSession {
                project_label: label,
                cookie_value: [0u8; 32],
            },
        }
    }

    /// Order 832-me6z, POSITIVE CONTROL for the mechanism.
    ///
    /// Registration is the only door into the broadcast path, so this pins
    /// that the deadline is applied there rather than left to the caller.
    #[test]
    fn a_registered_control_subscriber_carries_a_write_deadline() {
        let (server_side, _peer) = UnixStream::pair().expect("UnixStream::pair");
        let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

        assert!(
            register_control_subscriber(server_side, &subscribers),
            "a healthy stream must register"
        );

        let registered = subscribers.lock().expect("subscribers lock");
        assert_eq!(
            registered.len(),
            1,
            "the stream must be in the broadcast set"
        );
        let deadline = registered[0]
            .lock()
            .expect("subscriber lock")
            .write_timeout()
            .expect("querying the write timeout must succeed");
        assert_eq!(
            deadline,
            Some(CONTROL_SUBSCRIBER_WRITE_TIMEOUT),
            "a registered subscriber with no write deadline can wedge every \
             future broadcast to every other subscriber (832-me6z)"
        );
    }

    /// Order 832-me6z, THE ARM. This is the test the packet exists for.
    ///
    /// A subscriber that stops draining fills its socket buffer at NORMAL
    /// frame sizes. Before the deadline, `broadcast_control_envelope` blocked
    /// in `write_all` while holding the subscriber-LIST lock, so this loop did
    /// not fail — it HUNG, which is exactly how 832-me6z was found (the runner
    /// reported "has been running for over 60 seconds"). With the deadline the
    /// stalled peer is evicted and the broadcast path stays open.
    ///
    /// FALSIFICATION NOTE, and why this test is shaped the way it is.
    ///
    /// The regression's signature is a HANG, not a red assertion:
    /// `write_all` blocks inside the broadcast, so an in-loop wall-clock
    /// assert can never be reached to fire. A hanging arm STALLS the gate
    /// instead of reddening it, which is barely better than no arm at all.
    /// So the broadcast runs on a WORKER thread and the test thread watches it
    /// with `recv_timeout`: the wedge becomes a clean, fast failure.
    /// Verified by mutation — replacing the deadline with `None` fails this
    /// test in ~15s where the same mutation hung a same-thread version past
    /// 300s.
    #[test]
    fn a_subscriber_that_stops_draining_is_evicted_instead_of_wedging_the_broadcast() {
        let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

        // The stalled peer: registered, and its far end NEVER read from. The
        // peer end is held alive deliberately — dropping it would close the
        // socket and produce EPIPE, which is a different eviction path and
        // would pass even with the wedge present.
        let (stalled, _stalled_peer_never_reads) = UnixStream::pair().expect("pair");
        assert!(register_control_subscriber(stalled, &subscribers));

        // A HEALTHY peer alongside it, and the reason the packet is about more
        // than one dead subscriber: the wedge's real cost is that every OTHER
        // subscriber's broadcasts queue behind the stalled one forever.
        let (healthy, healthy_peer) = UnixStream::pair().expect("pair");
        assert!(register_control_subscriber(healthy, &subscribers));
        let drainer = std::thread::spawn(move || {
            let mut peer = healthy_peer;
            let mut sink = [0u8; 8192];
            while let Ok(n) = peer.read(&mut sink) {
                if n == 0 {
                    break;
                }
            }
        });

        // Broadcast on a worker; the test thread only watches the clock.
        let (done_tx, done_rx) = mpsc::channel::<usize>();
        let broadcaster = {
            let subscribers = subscribers.clone();
            std::thread::spawn(move || {
                let envelope = fat_broadcast_envelope();
                let mut broadcasts = 0;
                // Enough iterations to overrun any plausible default send
                // buffer with MAX_MESSAGE_BYTES/2 frames.
                while subscribers.lock().expect("lock").len() > 1 && broadcasts < 64 {
                    broadcast_control_envelope(&subscribers, &envelope);
                    broadcasts += 1;
                }
                let _ = done_tx.send(broadcasts);
            })
        };

        // One deadline expiry (5s) plus scheduling slack. A wedge blows this;
        // a healthy run returns in about one expiry.
        let broadcasts = done_rx
            .recv_timeout(std::time::Duration::from_secs(60))
            .expect(
                "the broadcast loop did not finish: a stalled subscriber is \
                 wedging the broadcast path for every other subscriber (832-me6z)",
            );

        let remaining = subscribers.lock().expect("lock").len();
        assert_eq!(
            remaining, 1,
            "the stalled subscriber must be evicted, and the draining one must \
             survive; got {remaining} subscriber(s) after {broadcasts} broadcast(s)"
        );

        let _ = broadcaster.join();
        subscribers.lock().expect("lock").clear();
        let _ = drainer.join();
    }

    /// ORDER 591-33s6. The cloud overflow row must not be a clickable control
    /// that does nothing.
    ///
    /// It used to be `enabled: true`, and clicking it dumped the project list
    /// to STDERR — which a GUI user never sees — while the menu closed, because
    /// menus close on click. The operator reported it as "clicking the show
    /// more projects resets the tray menu and loses focus, and launching it
    /// again still has the collapsed project count".
    ///
    /// The packet's minimum acceptable outcome: clicking does something
    /// visible, OR the item is not clickable. A picker needs window plumbing
    /// this module does not have, so it is informational — matching the macOS
    /// tray, which already treats its overflow row as inert.
    #[test]
    fn cloud_overflow_row_is_informational_not_a_dead_button() {
        let (label, enabled) = cloud_overflow_row(23, 10);
        assert!(label.contains("23"), "the total is kept: {label}");

        assert!(
            !enabled,
            "the overflow row must not be clickable while clicking it cannot show \
             a GUI user anything — a control that silently does nothing is worse \
             than an absent one"
        );
        assert!(
            label.contains("13"),
            "it must still say how many are hidden — that is the information the \
             row exists to carry: {label}"
        );
        assert!(
            label.contains("TILLANDSIAS_MAX_CLOUD_MENU_ITEMS"),
            "and it must name a remedy the user can actually act on, rather than \
             promising a picker that does not exist: {label}"
        );
        assert!(
            !label.contains("All cloud projects"),
            "the old label promised a full listing the click never delivered: {label}"
        );
    }

    /// Order 288: a pathological multi-KB, multi-line error chain surfaced
    /// as the status label must collapse to one bounded line so the menu
    /// (including Quit) stays reachable.
    /// @trace spec:tray-minimal-ux
    #[test]
    fn status_text_is_single_bounded_line_even_for_stack_traces() {
        let argv_dump = "podman run --detach --rm --name tillandsias-router ".repeat(40);
        let pathological = format!(
            "Error: vault issue_approle_token failed: vault not found\nredacted argv: {argv_dump}\ncontainer: tillandsias-router\nstate: unknown\n{}",
            "diagnostics line\n".repeat(200)
        );
        let sanitized = sanitize_status_text(&pathological);
        assert!(!sanitized.contains('\n'), "must be a single line");
        assert!(
            sanitized.chars().count() <= STATUS_LABEL_MAX_CHARS + 1,
            "must be hard-capped (got {} chars)",
            sanitized.chars().count()
        );
        assert!(
            sanitized.starts_with("Error: vault issue_approle_token failed"),
            "must preserve the informative first line: {sanitized}"
        );
    }

    /// Order 385: a fast-exiting terminal-launcher child (the Ptyxis
    /// GApplication client pattern) must be reaped — not left as a `<defunct>`
    /// zombie under the tray process. The helper moves the `Child` into a
    /// detached `wait()` thread; after the child exits, no Z-state child of
    /// this process should remain.
    #[test]
    fn spawn_terminal_and_reap_does_not_leave_zombies() {
        use std::process::Command;

        // Order 831-wmn4. Linux-only by construction: it counts zombies by
        // reading /proc (absent on macOS, where the helper silently returns 0
        // and the assertion becomes vacuous) and it spawns the Linux terminal
        // launcher, which is not installed here — "No such file or directory".
        //
        // SKIPPED LOUDLY rather than #[cfg]-gated so it keeps compiling on
        // every target. Note the vacuity risk is the interesting half: without
        // this guard the /proc fallback would make the zombie count 0 on macOS
        // and the test could PASS while asserting nothing.
        if !cfg!(target_os = "linux") {
            eprintln!(
                "SKIP spawn_terminal_and_reap_does_not_leave_zombies: needs /proc and the \
                 Linux terminal launcher; on this target the zombie count would be vacuously 0."
            );
            return;
        }

        // Find any Z-state (zombie) children currently parented to us.
        /// Count zombie children of THIS process. The delta between two calls is
        /// attributable to what happened in between; the absolute value is not,
        /// because sibling tests in the same process spawn children too.
        fn count_zombie_children() -> usize {
            let me = std::process::id();
            let Ok(entries) = std::fs::read_dir("/proc") else {
                return 0;
            };
            let mut n = 0;
            for entry in entries.flatten() {
                let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
                    continue;
                };
                if pid == me {
                    continue;
                }
                let stat = std::fs::read_to_string(entry.path().join("stat")).unwrap_or_default();
                if let Some(state) = stat.split_whitespace().nth(2)
                    && state.starts_with('Z')
                {
                    let status =
                        std::fs::read_to_string(entry.path().join("status")).unwrap_or_default();
                    for line in status.lines() {
                        if line.starts_with("PPid:")
                            && line.split_whitespace().nth(1) == Some(&me.to_string())
                        {
                            n += 1;
                        }
                    }
                }
            }
            n
        }

        // MEASURE A DELTA, NOT AN ABSOLUTE.
        //
        // `has_zombie_children()` scans /proc for zombies of the whole PROCESS,
        // and cargo runs a binary's tests as parallel threads inside one
        // process. So any sibling test that spawns a child creates a transient
        // zombie this test can see, and an absolute precondition
        // (`assert!(!has_zombie_children(), "started with stray zombies")`)
        // fails on a neighbour's activity rather than on anything this test did.
        //
        // That is exactly what happened: `tray-contract` went red on the
        // PRECONDITION at mod.rs:4201 during a full parallel run, while the test
        // passes 6/6 in isolation. Same class as 638-ehzi — a process-global
        // assertion under a parallel harness — and the second instance found in
        // this crate.
        //
        // The claim this test actually makes is a delta one: "spawn_terminal_and_reap
        // does not leave zombies". Measuring before and after tests precisely
        // that, and is immune to whatever the neighbours are doing.
        let zombies_before = count_zombie_children();

        for _ in 0..8 {
            let cmd = Command::new("/bin/true");
            spawn_terminal_and_reap(cmd).expect("spawn must succeed");
        }

        // Give the reaping threads time to wait() the exited children.
        // BOUNDED POLL, not a fixed sleep: under the full parallel suite
        // (584 tests) 500ms was not reliably enough and the count is
        // process-wide, so a slow reap read as a zombie leak (flaked in
        // ci-full run 9, 2026-08-30; passes in isolation in 0.5s). Poll to
        // quiescence with a hard ceiling so a REAL leak still fails.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut zombies_after = count_zombie_children();
        while zombies_after > zombies_before && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(100));
            zombies_after = count_zombie_children();
        }
        assert!(
            zombies_after <= zombies_before,
            "fast-exiting children must be reaped, not left as zombies \
             (zombies before={zombies_before}, after={zombies_after}; \
             a rise is attributable to this test, a steady count is a neighbour's)"
        );
    }

    /// Short labels pass through unchanged (no truncation regression on the
    /// normal emoji status stack).
    #[test]
    fn status_text_short_labels_unchanged() {
        assert_eq!(sanitize_status_text("✅ OK"), "✅ OK");
        assert_eq!(
            sanitize_status_text("🥀 Launch failed: image missing"),
            "🥀 Launch failed: image missing"
        );
    }

    /// Order 411: the missing-forge-image path must surface an actionable
    /// message (names the version + `tillandsias --init`) and must NEVER claim
    /// initialization "may be in progress" — that wording implies silent
    /// progress that, post `--install` version bump, never happens.
    #[test]
    fn forge_missing_message_is_actionable_not_in_progress() {
        let msg = forge_missing_actionable_message("v0.3.260717.1", "myproj");
        assert!(
            msg.contains("v0.3.260717.1"),
            "message must name the exact version: {msg}"
        );
        assert!(
            msg.contains("tillandsias --init"),
            "message must name the remedy: {msg}"
        );
        assert!(
            !msg.to_lowercase().contains("may be in progress"),
            "must not imply silent in-progress init: {msg}"
        );
    }

    /// The Failed status_label arm bounds its descriptor too — several call
    /// sites assign status_label() output directly, bypassing set_status.
    #[test]
    fn failed_status_label_bounds_descriptor() {
        let label = status_label(&TrayStatusStage::Failed {
            stage: Box::new(TrayStatusStage::PreLaunch),
            descriptor: format!("boom\n{}", "x".repeat(5000)),
        });
        assert!(!label.contains('\n'));
        assert!(label.chars().count() <= STATUS_LABEL_MAX_CHARS + 8);
        assert!(label.contains("\u{274C} boom"));
    }

    /// Regression: a `ControlMessage` variant that is on the unix-socket
    /// matrix as `Handle` but does not yet have a real handler implementation
    /// (currently `McpFrame` — host-browser-mcp tunnel between forge and
    /// tray) must reply with an explicit `Error { Unsupported }` frame, not
    /// be silently dropped. Silent drops hang clients indefinitely.
    ///
    /// This test used to use `VmStatusRequest` as its example; that variant
    /// now has a real handler (Linux-native phase=Ready + live
    /// `podman_available_sync` check), so the example moved to `McpFrame`
    /// which remains matrix-Handle-but-no-handler-yet.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md,
    ///        spec:tray-host-control-socket
    #[test]
    fn unsupported_variant_on_unix_socket_replies_with_error() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        use std::sync::Mutex;
        use std::thread;

        let (server_side, mut client_side) =
            UnixStream::pair().expect("UnixStream::pair available on linux");
        let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

        let req = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 42,
            body: ControlMessage::McpFrame {
                session_id: 7,
                payload: vec![0x01, 0x02, 0x03],
            },
        };
        let payload = encode(&req).expect("encode");
        client_side
            .write_all(&(payload.len() as u32).to_be_bytes())
            .expect("write len");
        client_side.write_all(&payload).expect("write body");
        client_side.flush().expect("flush");

        let phase_handle = TrayPhaseHandle::ready_for_test();
        let server_thread = thread::spawn(move || {
            handle_control_connection(server_side, subscribers, phase_handle);
        });

        let mut len_buf = [0_u8; 4];
        client_side.read_exact(&mut len_buf).expect("read len");
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut reply_bytes = vec![0_u8; len];
        client_side
            .read_exact(&mut reply_bytes)
            .expect("read reply body");
        let reply: ControlEnvelope = decode(&reply_bytes).expect("decode reply");

        server_thread.join().expect("server thread joined");

        assert_eq!(reply.wire_version, WIRE_VERSION);
        assert_eq!(reply.seq, 42);
        match reply.body {
            ControlMessage::Error {
                seq_in_reply_to,
                code,
                message,
            } => {
                assert_eq!(seq_in_reply_to, Some(42));
                assert_eq!(code, ErrorCode::Unsupported);
                // Order 505: McpFrame on control.sock is refused because control.sock
                // is not a per-lane socket. MCP tool surface is served over per-lane
                // listeners only.
                assert!(
                    message.contains("per-lane") || message.contains("control socket"),
                    "McpFrame deny must name the refusal reason; got {message:?}"
                );
            }
            other => panic!("expected Error variant, got {other:?}"),
        }
    }

    /// Order 363 & 505: the MCP method surface a real client needs. `initialize`
    /// and `tools/list` answer without podman, the advertised tool family
    /// is exactly the publish trio, and notifications are absorbed without
    /// a reply (JSON-RPC 2.0). The project label is a function parameter —
    /// NOT process env.
    ///
    /// @trace spec:mcp-tool-socket
    /// Order 779-3trn test rigs: a hermetic composed browser server (fake
    /// launch — never spawns chromium) and its runtime. The label is pinned
    /// exactly as `serve_mcp_connection` pins it from LaneIdentity, so these
    /// tests exercise the real attribution path.
    fn test_browser() -> tillandsias_browser_mcp::BrowserMcpServer {
        tillandsias_browser_mcp::BrowserMcpServer::with_project_label_and_mode(
            tillandsias_browser_mcp::McpServerConfig::default(),
            "demo",
            None,
            true,
        )
    }

    fn test_rt() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("test runtime")
    }

    #[test]
    fn mcp_initialize_and_tools_list_advertise_publish_tool_family() {
        let init =
            serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}});
        let resp = handle_mcp_jsonrpc("demo", &init, &test_browser(), &test_rt())
            .expect("initialize replies");
        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 1);
        assert_eq!(
            resp["result"]["serverInfo"]["name"],
            "tillandsias-host-services"
        );

        let list = serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"});
        let resp = handle_mcp_jsonrpc("demo", &list, &test_browser(), &test_rt())
            .expect("tools/list replies");
        let tools: Vec<&str> = resp["result"]["tools"]
            .as_array()
            .expect("tools array")
            .iter()
            .map(|t| t["name"].as_str().expect("tool name"))
            .collect();
        // Order 779-3trn: the host-services trio still leads (unchanged
        // ordering for existing consumers), and the browser family is now
        // advertised alongside it — the wiring gap this packet closed.
        assert_eq!(
            &tools[..3],
            &["publish_local", "service_status", "service_stop"],
            "the host-services trio must keep its identity and order"
        );
        let browser_tools: Vec<&&str> =
            tools.iter().filter(|t| t.starts_with("browser.")).collect();
        assert_eq!(
            browser_tools.len(),
            8,
            "all eight browser.* tools are advertised: {tools:?}"
        );
        for expected in [
            "browser.open",
            "browser.list_windows",
            "browser.read_url",
            "browser.screenshot",
            "browser.click",
            "browser.type",
            "browser.eval",
            "browser.close",
        ] {
            assert!(
                tools.contains(&expected),
                "{expected} must be advertised: {tools:?}"
            );
        }
        assert_eq!(tools.len(), 11, "trio + browser family, nothing else");

        let note = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
        assert!(
            handle_mcp_jsonrpc("demo", &note, &test_browser(), &test_rt()).is_none(),
            "notifications get no reply"
        );
    }

    /// Order 779-3trn exit criterion: exercise the composition THROUGH THE
    /// TRANSPORT, not by calling the dispatcher directly — a real
    /// `UnixStream::pair()` driven by `serve_mcp_connection` with a pinned
    /// `LaneIdentity`. That is the only way to prove the per-connection
    /// server is built with listener-derived attribution and that the
    /// browser family is reachable by an actual client.
    ///
    /// Hermetic: `fake_launch` means no chromium is ever spawned, and the
    /// `browser.open` below carries a disallowed URL so it is refused by
    /// policy before any launch decision.
    ///
    /// @trace spec:mcp-tool-socket, spec:host-browser-mcp
    #[test]
    fn mcp_connection_serves_browser_family_over_the_socket() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_known_demo_project(|| {
            let (client, server) = UnixStream::pair().expect("socketpair");
            let handle = std::thread::spawn(move || {
                serve_mcp_connection(server, Some(LaneIdentity::new("demo", "default")));
            });

            let mut writer = client.try_clone().expect("clone client");
            let mut reader = BufReader::new(client);
            let mut read_line = || {
                let mut line = String::new();
                reader.read_line(&mut line).expect("read reply");
                serde_json::from_str::<serde_json::Value>(line.trim()).expect("reply is JSON")
            };

            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{}}}}"#
            )
            .expect("write initialize");
            let init = read_line();
            assert_eq!(
                init["result"]["serverInfo"]["name"],
                "tillandsias-host-services"
            );

            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":2,"method":"tools/list"}}"#
            )
            .expect("write tools/list");
            let list = read_line();
            let tools: Vec<&str> = list["result"]["tools"]
                .as_array()
                .expect("tools array")
                .iter()
                .map(|t| t["name"].as_str().expect("tool name"))
                .collect();
            assert_eq!(
                tools.len(),
                11,
                "over the transport: trio + eight browser tools, got {tools:?}"
            );
            assert!(tools.contains(&"browser.open") && tools.contains(&"publish_local"));

            // A disallowed URL must come back as a typed JSON-RPC error from the
            // composed server — proving browser.* actually ROUTED there rather
            // than falling through to the -32601 unknown-tool arm.
            writeln!(
            writer,
            r#"{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"browser.open","arguments":{{"url":"file:///etc/passwd"}}}}}}"#
        )
        .expect("write browser.open");
            let denied = read_line();
            assert_eq!(denied["id"], 3);
            // The browser family reports POLICY denials the MCP way — a result
            // with `isError: true` and the reason in content — whereas the
            // host-services trio uses JSON-RPC -32000 for its denials. Both are
            // correct for their layer; what matters here is that the call
            // reached the composed server at all.
            assert_eq!(
                denied["result"]["isError"], true,
                "a disallowed URL must be refused: {denied}"
            );
            let text = denied["result"]["content"][0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_string();
            assert!(
                text.contains("URL_NOT_ALLOWED"),
                "the refusal must name the URL policy: {text}"
            );
            assert!(
                denied.get("error").is_none(),
                "browser.open must route to the composed server, never the -32601 unknown-tool fallback: {denied}"
            );

            drop(writer);
            drop(reader);
            handle.join().expect("connection thread joins");
        });
    }

    /// Order 779-dqsv: the per-line cap binds on the INBOUND half. An
    /// oversized line is refused with a typed error, the stream RESYNCS at
    /// the next newline (a normal request after it still works), and the
    /// connection is not killed. Before this cap the live NDJSON path had no
    /// limit at all while the retired McpFrame path had 4 MiB.
    ///
    /// @trace spec:mcp-tool-socket, spec:host-browser-mcp
    #[test]
    fn mcp_oversized_request_line_is_refused_and_the_stream_resyncs() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_known_demo_project(|| {
            let (client, server) = UnixStream::pair().expect("socketpair");
            let handle = std::thread::spawn(move || {
                serve_mcp_connection(server, Some(LaneIdentity::new("demo", "default")));
            });

            let mut writer = client.try_clone().expect("clone client");
            let mut reader = BufReader::new(client);
            let mut read_json = || {
                let mut line = String::new();
                reader.read_line(&mut line).expect("read reply");
                serde_json::from_str::<serde_json::Value>(line.trim()).expect("reply is JSON")
            };

            // One line just past the cap: valid JSON shape, hostile size.
            let padding = "x".repeat(MAX_MCP_LINE_BYTES + 1024);
            writeln!(
            writer,
            r#"{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"publish_local","arguments":{{"category":"{padding}"}}}}}}"#
        )
        .expect("write oversized line");

            let refused = read_json();
            assert_eq!(refused["error"]["code"], -32000);
            let message = refused["error"]["message"].as_str().unwrap_or_default();
            assert!(
                message.starts_with("RequestTooLarge:"),
                "the refusal must name the cap: {message}"
            );

            // RESYNC: a normal request after the oversized one is still served —
            // the cap refuses a line, it does not poison the connection.
            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":2,"method":"tools/list"}}"#
            )
            .expect("write tools/list");
            let list = read_json();
            assert_eq!(list["id"], 2);
            assert!(
                list["result"]["tools"]
                    .as_array()
                    .is_some_and(|t| !t.is_empty()),
                "the connection still serves after an oversized line: {list}"
            );

            drop(writer);
            drop(reader);
            handle.join().expect("connection thread joins");
        });
    }

    /// Order 779-dqsv: the OUTBOUND half of the cap — the one with a live
    /// producer, since a base64 full-page `browser.screenshot` can exceed any
    /// sane line length. An oversized response is replaced by a typed error
    /// naming the cap, so the failure surfaces here (where the reason is
    /// known) instead of blowing up the peer's reader.
    #[test]
    fn mcp_oversized_response_is_replaced_with_a_typed_error() {
        // NEGATIVE CONTROL: a normal response passes through byte-identical.
        let under = serde_json::json!({"jsonrpc": "2.0", "id": 1, "result": {"ok": true}});
        assert_eq!(
            cap_response_line(&under),
            under.to_string(),
            "a response under the cap must pass through untouched"
        );

        // A screenshot-sized result IS replaced — with the id preserved, so
        // the client can still correlate the failure to its call.
        let huge = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 7,
            "result": { "content": [{ "type": "text", "text": "A".repeat(MAX_MCP_LINE_BYTES) }] }
        });
        let capped = cap_response_line(&huge);
        assert!(
            capped.len() <= MAX_MCP_LINE_BYTES,
            "the replacement itself must fit under the cap"
        );
        let parsed: serde_json::Value = serde_json::from_str(&capped).expect("replacement is JSON");
        assert_eq!(parsed["id"], 7, "the request id survives the replacement");
        assert_eq!(parsed["error"]["code"], -32000);
        assert!(
            parsed["error"]["message"]
                .as_str()
                .unwrap_or_default()
                .starts_with("ResponseTooLarge:"),
            "the error names the cap: {parsed}"
        );
        assert!(
            parsed.get("result").is_none(),
            "the oversized payload must NOT survive alongside the error"
        );
    }

    /// Order 779-dqsv: pin what the lane transport ACTUALLY enforces, now
    /// that the unreachable 16-call semaphore is gone. The loop reads one
    /// line, handles it to completion, and only then reads the next — so a
    /// second request cannot begin before the first response is written.
    /// This is the guarantee a future concurrent transport would have to
    /// deliberately break (and would then owe a real, bindable limit).
    #[test]
    fn mcp_lane_transport_serializes_one_call_at_a_time() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_known_demo_project(|| {
            let (client, server) = UnixStream::pair().expect("socketpair");
            let handle = std::thread::spawn(move || {
                serve_mcp_connection(server, Some(LaneIdentity::new("demo", "default")));
            });

            let mut writer = client.try_clone().expect("clone client");
            let mut reader = BufReader::new(client);

            // Pipeline three requests without reading anything back.
            for id in 1..=3 {
                writeln!(
                    writer,
                    r#"{{"jsonrpc":"2.0","id":{id},"method":"tools/list"}}"#
                )
                .expect("write pipelined request");
            }

            // Responses come back in request order, one per line — the
            // observable signature of a sequential handler.
            for expected in 1..=3 {
                let mut line = String::new();
                reader.read_line(&mut line).expect("read reply");
                let resp: serde_json::Value =
                    serde_json::from_str(line.trim()).expect("reply is JSON");
                assert_eq!(
                    resp["id"], expected,
                    "sequential transport answers in request order"
                );
            }

            drop(writer);
            drop(reader);
            handle.join().expect("connection thread joins");
        });
    }

    /// Order 363 exit criterion: a non-WEB category is refused host-side
    /// with an actionable JSON-RPC error. The deny happens BEFORE any
    /// podman call — this test runs without podman.
    ///
    /// @trace spec:mcp-tool-socket, spec:subdomain-routing-via-reverse-proxy
    #[test]
    fn mcp_tools_call_non_web_category_denied_loud() {
        let call = serde_json::json!({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "publish_local", "arguments": {"category": "DATABASE"}}
        });
        let resp =
            handle_mcp_jsonrpc("demo", &call, &test_browser(), &test_rt()).expect("deny replies");
        assert_eq!(resp["id"], 3);
        assert_eq!(resp["error"]["code"], -32000);
        let message = resp["error"]["message"].as_str().expect("error message");
        assert!(
            message.contains("DATABASE"),
            "deny must name the refused category; got {message:?}"
        );

        let forged = serde_json::json!({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "drop_all_containers", "arguments": {}}
        });
        let resp = handle_mcp_jsonrpc("demo", &forged, &test_browser(), &test_rt())
            .expect("unknown tool replies");
        assert_eq!(resp["error"]["code"], -32601);
    }

    /// Order 505: The NDJSON mcp.sock transport: a peer that cannot be attributed to
    /// a lane gets ONE loud deny line (-32000) naming the attribution gate, then EOF.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_ndjson_connection_denies_unattributed_peer() {
        use std::io::{BufRead, BufReader};
        use std::os::unix::net::UnixStream;

        let (server_side, client_side) =
            UnixStream::pair().expect("UnixStream::pair available on linux");
        let server = std::thread::spawn(move || serve_mcp_connection(server_side, None));

        let mut lines = BufReader::new(client_side).lines();
        let deny_line = lines.next().expect("one deny line").expect("readable");
        let deny: serde_json::Value = serde_json::from_str(&deny_line).expect("valid JSON-RPC");
        assert_eq!(deny["error"]["code"], -32000);
        assert!(
            deny["error"]["message"]
                .as_str()
                .unwrap_or("")
                .contains("attributed")
                || deny["error"]["message"]
                    .as_str()
                    .unwrap_or("")
                    .contains("lane"),
            "deny must name the attribution gate; got {deny_line:?}"
        );
        assert!(lines.next().is_none(), "connection closes after the deny");
        server.join().expect("server thread joined");
    }

    /// Pin the order-505 validation set to the KNOWN projects these tests
    /// attribute to (`demo`, `alpha`) for
    /// the tests that reach `serve_mcp_connection`'s project validation.
    ///
    /// THIS HELPER USED TO BE `with_empty_project_root`, and its own doc said
    /// what was wrong with it: "An EMPTY root is the deliberate fixture:
    /// empty-scan-is-valid is the documented open-host behavior these tests
    /// had been relying on implicitly." That behaviour was the 1031-q4pb
    /// bypass — with nothing enumerated, the validator admitted ANY label,
    /// so these tests were handshaking as `demo` only because validation was
    /// being skipped entirely. Five of them failed the moment the check
    /// started failing closed, which is the fixture doing its job on the way
    /// out: the assumption was recorded, so its removal was visible rather
    /// than silent.
    ///
    /// The root stays EMPTY on purpose. `demo` is supplied through the
    /// confirmed-cloud half of the set instead, so these tests now exercise
    /// the cloud-only end state (776-jcf3) — the arrangement every host will
    /// have once ~/src is retired — rather than a local checkout that will
    /// not exist.
    ///
    /// Both env vars are pinned for the same 638-ehzi reason the original
    /// gave: the validator reads ambient state, so without pinning these
    /// tests pass or fail based on which test mutated the env first and on
    /// whether the host's real ~/src happens to be empty.
    fn with_known_demo_project<T>(f: impl FnOnce() -> T) -> T {
        static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _guard = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-known-demo-project-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let cache = dir.join("known-cloud-projects");
        let prev_root = std::env::var_os(crate::local_projects::HOST_PROJECT_ROOT_ENV);
        let prev_cache = std::env::var_os(crate::local_projects::CLOUD_LABEL_CACHE_ENV);
        unsafe {
            std::env::set_var(crate::local_projects::HOST_PROJECT_ROOT_ENV, &dir);
            std::env::set_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV, &cache);
        }
        // `alpha` alongside `demo` because the forged-environ test attributes to
        // it: its subject is that listener attribution beats TILLANDSIAS_PROJECT,
        // which it can only demonstrate if the attributed label is servable.
        let _ =
            crate::local_projects::persist_cloud_labels(&["demo".to_string(), "alpha".to_string()]);
        let out = f();
        unsafe {
            match prev_root {
                Some(v) => std::env::set_var(crate::local_projects::HOST_PROJECT_ROOT_ENV, v),
                None => std::env::remove_var(crate::local_projects::HOST_PROJECT_ROOT_ENV),
            }
            match prev_cache {
                Some(v) => std::env::set_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV, v),
                None => std::env::remove_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV),
            }
        }
        let _ = std::fs::remove_file(&cache);
        out
    }

    /// The same fixture with NOTHING known, for the arm that must be denied.
    fn with_no_known_projects<T>(f: impl FnOnce() -> T) -> T {
        static ENV_LOCK2: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _guard = ENV_LOCK2.lock().unwrap_or_else(|p| p.into_inner());
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-no-known-projects-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let cache = dir.join("absent-cache");
        let _ = std::fs::remove_file(&cache);
        let prev_root = std::env::var_os(crate::local_projects::HOST_PROJECT_ROOT_ENV);
        let prev_cache = std::env::var_os(crate::local_projects::CLOUD_LABEL_CACHE_ENV);
        unsafe {
            std::env::set_var(crate::local_projects::HOST_PROJECT_ROOT_ENV, &dir);
            std::env::set_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV, &cache);
        }
        let out = f();
        unsafe {
            match prev_root {
                Some(v) => std::env::set_var(crate::local_projects::HOST_PROJECT_ROOT_ENV, v),
                None => std::env::remove_var(crate::local_projects::HOST_PROJECT_ROOT_ENV),
            }
            match prev_cache {
                Some(v) => std::env::set_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV, v),
                None => std::env::remove_var(crate::local_projects::CLOUD_LABEL_CACHE_ENV),
            }
        }
        out
    }

    /// 1031-q4pb: THE BYPASS, pinned so it cannot come back.
    ///
    /// A host that knows of no projects — every fresh curl-install, and every
    /// host once ~/src retires — must REFUSE an attributed lane rather than
    /// serve it. Before the fix this connection completed the handshake,
    /// because `known.is_empty() || any(..)` is true when the set is empty.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_connection_is_denied_when_the_host_knows_no_projects() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_no_known_projects(|| {
            let (server_side, client_side) =
                UnixStream::pair().expect("UnixStream::pair available on linux");
            let identity = LaneIdentity::new("demo", "default");
            let server =
                std::thread::spawn(move || serve_mcp_connection(server_side, Some(identity)));

            let mut writer = client_side.try_clone().expect("clone client side");
            let mut lines = BufReader::new(client_side).lines();
            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{}}}}"#
            )
            .expect("write initialize");

            let resp: serde_json::Value =
                serde_json::from_str(&lines.next().expect("a reply").expect("readable"))
                    .expect("valid JSON");
            assert_eq!(
                resp["error"]["code"], -32000,
                "an unknown project must be denied, not served: {resp}"
            );
            assert!(
                resp["result"].is_null(),
                "a denied connection must not carry a result: {resp}"
            );
            let _ = server.join();
        });
    }

    /// Order 505: The NDJSON transport round-trips the MCP handshake for an attributed
    /// lane peer — one JSON-RPC object per line, replies in order.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_ndjson_connection_round_trips_handshake() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_known_demo_project(|| {
            let (server_side, client_side) =
                UnixStream::pair().expect("UnixStream::pair available on linux");
            let identity = LaneIdentity::new("demo", "default");
            let server =
                std::thread::spawn(move || serve_mcp_connection(server_side, Some(identity)));

            let mut writer = client_side.try_clone().expect("clone client side");
            let mut lines = BufReader::new(client_side).lines();

            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{}}}}"#
            )
            .expect("write initialize");
            let resp: serde_json::Value =
                serde_json::from_str(&lines.next().expect("initialize reply").expect("readable"))
                    .expect("valid JSON");
            assert_eq!(resp["id"], 1);
            assert_eq!(
                resp["result"]["serverInfo"]["name"],
                "tillandsias-host-services"
            );

            writeln!(
                writer,
                r#"{{"jsonrpc":"2.0","id":2,"method":"tools/list"}}"#
            )
            .expect("write tools/list");
            let resp: serde_json::Value =
                serde_json::from_str(&lines.next().expect("tools/list reply").expect("readable"))
                    .expect("valid JSON");
            // Order 779-3trn: the host-services trio plus the eight
            // browser.* tools now compose on this socket (was 3).
            assert_eq!(resp["result"]["tools"].as_array().expect("tools").len(), 11);

            drop(writer);
            drop(lines);
            server.join().expect("server thread joined");
        });
    }
    /// Order 505: per-lane socket location and 0600 permissions.
    /// Asserts $XDG_RUNTIME_DIR/tillandsias/mcp/<project>-<instance>/mcp.sock path shape
    /// and mode 0600.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_per_lane_socket_location_and_permissions_0600() {
        use std::os::unix::fs::PermissionsExt;

        let host_dir = mcp_socket_host_dir_for_lane("alpha", "w1");
        let sock_path = mcp_socket_path_for_lane("alpha", "w1");

        assert!(
            host_dir.ends_with("tillandsias/mcp/alpha-w1"),
            "host dir must end with tillandsias/mcp/alpha-w1, got: {:?}",
            host_dir
        );
        assert!(
            sock_path.ends_with("tillandsias/mcp/alpha-w1/mcp.sock"),
            "sock path must end with tillandsias/mcp/alpha-w1/mcp.sock, got: {:?}",
            sock_path
        );

        // Order 831-wmn4: the path assertions above hold on every target and
        // keep running there. The BIND below cannot: macOS caps
        // sockaddr_un.sun_path at 104 bytes and its per-user TMPDIR is a long
        // /var/folders/<hash>/T/ path, so the derived socket path exceeds
        // SUN_LEN and bind fails with "path must be shorter than SUN_LEN".
        // That is an environment limit, not a defect in the code under test.
        //
        // SKIPPED LOUDLY rather than #[cfg]-gated, so the test still COMPILES
        // on every target — a cfg-gated test rots silently, which is the whole
        // failure this packet is about. The tray is Linux-deployed; Linux runs
        // the assertion.
        if !cfg!(target_os = "linux") {
            eprintln!(
                "SKIP mcp_per_lane_socket_location_and_permissions_0600: bind half is \
                 Linux-only (macOS SUN_LEN 104 vs this host's TMPDIR). Path assertions ran."
            );
            return;
        }

        // Test listener creation and permissions
        let res = start_mcp_socket_server_for_lane("testperlane", "w99");
        assert!(
            res.is_ok(),
            "start_mcp_socket_server_for_lane failed: {res:?}"
        );

        let created_path = mcp_socket_path_for_lane("testperlane", "w99");
        assert!(created_path.exists(), "socket file must exist");
        let meta = std::fs::metadata(&created_path).expect("metadata");
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "socket permissions must be 0600, got: {:o}",
            mode
        );
    }

    /// Order 505: Listener-derived project attribution ignores forged peer environment.
    /// When an agent in lane (alpha, w1) has TILLANDSIAS_PROJECT=beta in its environ,
    /// the call is still attributed strictly to alpha (the accepting listener).
    /// Process environ is not read or trusted.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_listener_derived_project_attribution_ignores_forged_environ() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        with_known_demo_project(|| {
            // Set a forged environment variable in the test process
            unsafe {
                std::env::set_var("TILLANDSIAS_PROJECT", "attacker-wins");
            }

            let (server_side, client_side) =
                UnixStream::pair().expect("UnixStream::pair available on linux");
            // Listener context attributes this connection to project "alpha", instance "w1"
            let identity = LaneIdentity::new("alpha", "w1");
            let server =
                std::thread::spawn(move || serve_mcp_connection(server_side, Some(identity)));

            let mut writer = client_side.try_clone().expect("clone client side");
            let mut lines = BufReader::new(client_side).lines();

            // Send tools/call for a non-WEB category
            writeln!(
            writer,
            r#"{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"publish_local","arguments":{{"category":"INVALID"}}}}}}"#
        )
        .expect("write tools/call");

            let resp: serde_json::Value =
                serde_json::from_str(&lines.next().expect("reply").expect("readable"))
                    .expect("valid JSON");

            // The error code is -32000
            assert_eq!(resp["id"], 1);
            assert_eq!(resp["error"]["code"], -32000);

            drop(writer);
            drop(lines);
            server.join().expect("server thread joined");

            // Clean up env
            unsafe {
                std::env::remove_var("TILLANDSIAS_PROJECT");
            }
        });
    }

    /// Order 505: Different lanes have isolated socket subdirectories.
    /// (alpha, w1) vs (beta, w2) vs (alpha, w2) are all separate.
    ///
    /// @trace spec:mcp-tool-socket
    #[test]
    fn mcp_different_lanes_have_isolated_socket_subdirectories() {
        let dir_a1 = mcp_socket_host_dir_for_lane("alpha", "w1");
        let dir_b2 = mcp_socket_host_dir_for_lane("beta", "w2");
        let dir_a2 = mcp_socket_host_dir_for_lane("alpha", "w2");
        let dir_adefault = mcp_socket_host_dir_for_lane("alpha", "default");

        assert_ne!(dir_a1, dir_b2);
        assert_ne!(dir_a1, dir_a2);
        assert_ne!(dir_a1, dir_adefault);
        assert_ne!(dir_b2, dir_a2);

        assert!(dir_a1.ends_with("tillandsias/mcp/alpha-w1"));
        assert!(dir_b2.ends_with("tillandsias/mcp/beta-w2"));
        assert!(dir_a2.ends_with("tillandsias/mcp/alpha-w2"));
        assert!(dir_adefault.ends_with("tillandsias/mcp/alpha-default"));
    }

    /// `VmStatusRequest` is the third matrix-Handle-but-no-handler variant
    /// migrated to a real implementation (after `EnumerateLocalProjects` and
    /// `CloudRefreshRequest`). The unix dispatcher reports `phase=Ready` —
    /// we're answering on a working socket, by definition the tray is
    /// serving — plus a live `podman_available_sync` check for the
    /// `podman_ready` field. `last_event` is a transport-tag string so a
    /// downstream client can tell unix-from-vsock replies apart.
    ///
    /// This is intentionally a minimal slice. A follow-on can add a real
    /// `TrayPhaseHandle` with Starting/Stopping/Draining transitions —
    /// mirror of the in-VM `VmStateHandle` — rooted in the tray's own
    /// shutdown path. Until then, "we're up" is the truth and `Ready` is
    /// the correct value.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2),
    ///        spec:tray-host-control-socket,
    ///        spec:vm-provisioning-lifecycle
    #[test]
    fn vm_status_request_on_unix_socket_replies_with_ready_phase() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        use std::sync::Mutex;
        use std::thread;

        let (server_side, mut client_side) =
            UnixStream::pair().expect("UnixStream::pair available on linux");
        let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

        let req = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 99,
            body: ControlMessage::VmStatusRequest { seq: 99 },
        };
        let payload = encode(&req).expect("encode");
        client_side
            .write_all(&(payload.len() as u32).to_be_bytes())
            .expect("write len");
        client_side.write_all(&payload).expect("write body");
        client_side.flush().expect("flush");

        let phase_handle = TrayPhaseHandle::ready_for_test();
        let server_thread = thread::spawn(move || {
            handle_control_connection(server_side, subscribers, phase_handle);
        });

        let mut len_buf = [0_u8; 4];
        client_side.read_exact(&mut len_buf).expect("read len");
        let len = u32::from_be_bytes(len_buf) as usize;
        let mut reply_bytes = vec![0_u8; len];
        client_side
            .read_exact(&mut reply_bytes)
            .expect("read reply body");
        let reply: ControlEnvelope = decode(&reply_bytes).expect("decode reply");

        server_thread.join().expect("server thread joined");

        assert_eq!(reply.wire_version, WIRE_VERSION);
        assert_eq!(reply.seq, 99);
        match reply.body {
            ControlMessage::VmStatusReply {
                seq_in_reply_to,
                phase,
                podman_ready: _,
                last_event,
            } => {
                assert_eq!(seq_in_reply_to, 99);
                assert!(
                    matches!(phase, tillandsias_control_wire::VmPhase::Ready),
                    "expected phase=Ready on a tray that is answering; got {phase:?}"
                );
                // `podman_ready` is environment-dependent — don't pin
                // a value, only that we returned a real bool. The
                // hard contract is the variant shape.
                assert_eq!(
                    last_event.as_deref(),
                    Some("linux-native-tray"),
                    "expected linux-native-tray transport tag in last_event"
                );
            }
            other => panic!("expected VmStatusReply variant, got {other:?}"),
        }
    }

    /// `watch_shutdown_and_mark_stopping_blocking` transitions the
    /// shared phase to `Stopping` once the shutdown atomic flips. This
    /// is the linux-native counterpart of the vsock-side
    /// `VmStateHandle::watch_shutdown_and_mark_stopping`: when the
    /// tray's SIGTERM/SIGINT handler sets the atomic, sibling-host
    /// clients polling `VmStatusRequest` see `phase=Stopping` instead
    /// of stale `Ready`.
    ///
    /// We spawn the watcher on a thread (sync poll, matches the accept
    /// loop's shape), flip the atomic from the test thread, then
    /// observe the phase transition through a separate clone of the
    /// handle. The watcher must NOT clobber a terminal `Failed` —
    /// defensive guard matches the vsock-side pattern even though the
    /// tray has no Failed-producing advancer today.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
    /// @trace spec:signal-handling, spec:vm-provisioning-lifecycle
    #[test]
    fn watch_shutdown_blocking_flips_phase_to_stopping_when_atomic_flips() {
        use std::sync::atomic::AtomicBool;
        use std::thread;
        use std::time::{Duration, Instant};

        let handle = TrayPhaseHandle::ready_for_test();
        let observer = handle.clone();
        let shutdown = Arc::new(AtomicBool::new(false));
        let watcher_shutdown = Arc::clone(&shutdown);

        let watcher = thread::spawn(move || {
            handle.watch_shutdown_and_mark_stopping_blocking(watcher_shutdown);
        });

        // Briefly confirm the watcher is parked at `Ready` (it polls
        // every 250 ms; give it well under one poll period to settle).
        thread::sleep(Duration::from_millis(50));
        assert!(matches!(
            observer.current_phase(),
            tillandsias_control_wire::VmPhase::Ready
        ));

        // Flip the atomic; the watcher should pick it up within ~250 ms.
        shutdown.store(true, Ordering::SeqCst);

        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if matches!(
                observer.current_phase(),
                tillandsias_control_wire::VmPhase::Stopping
            ) {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "watcher did not flip phase to Stopping within 2s"
            );
            thread::sleep(Duration::from_millis(25));
        }

        watcher.join().expect("watcher thread joined");
    }

    /// Defensive guard: if some future advancer set the phase to
    /// `Failed` before the shutdown watcher fires, the watcher must
    /// NOT clobber the terminal Failed state. The tray doesn't have a
    /// Failed-producing advancer today; this matches the vsock-side
    /// helper's pattern so the two stay symmetric and the contract
    /// holds when we do add one.
    ///
    /// @trace spec:vm-provisioning-lifecycle
    #[test]
    fn watch_shutdown_blocking_does_not_clobber_terminal_failed() {
        use std::sync::atomic::AtomicBool;
        use std::thread;
        use std::time::Duration;

        let handle = TrayPhaseHandle::ready_for_test();
        handle.set_phase(tillandsias_control_wire::VmPhase::Failed);
        let observer = handle.clone();
        let shutdown = Arc::new(AtomicBool::new(true));

        // Run the watcher synchronously on this thread; with shutdown
        // already true it should return after at most one poll without
        // changing the phase.
        let t = thread::spawn(move || {
            handle.watch_shutdown_and_mark_stopping_blocking(shutdown);
        });
        t.join().expect("watcher joined");

        assert!(
            matches!(
                observer.current_phase(),
                tillandsias_control_wire::VmPhase::Failed
            ),
            "watcher must not clobber a terminal Failed phase; got {:?}",
            observer.current_phase()
        );
        // Sanity: the polling sleep is at most 250 ms so this test
        // completes in well under a second even with the worst-case
        // first-poll alignment.
        let _ = Duration::from_millis(0);
    }

    /// `TrayPhaseHandle` round-trips state. Default constructor starts
    /// at `Starting`; `set_phase` mutates; `current_phase` reads;
    /// clones share state via `Arc`. This pins the cheap-to-clone
    /// contract that lets the accept loop hand a clone to every
    /// per-connection worker.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2)
    #[test]
    fn tray_phase_handle_round_trips_state_across_clones() {
        let h = TrayPhaseHandle::new();
        assert!(matches!(
            h.current_phase(),
            tillandsias_control_wire::VmPhase::Starting
        ));

        let h2 = h.clone();
        h.set_phase(tillandsias_control_wire::VmPhase::Ready);
        assert!(matches!(
            h2.current_phase(),
            tillandsias_control_wire::VmPhase::Ready
        ));

        h2.set_phase(tillandsias_control_wire::VmPhase::Draining);
        assert!(matches!(
            h.current_phase(),
            tillandsias_control_wire::VmPhase::Draining
        ));
    }

    /// `VmShutdownRequest` over the unix socket flips the shared
    /// phase handle to `Draining`. The wire defines no
    /// `VmShutdownReply` variant, so the handler closes the
    /// connection rather than acking — matching the in-VM vsock
    /// side's behaviour. We assert (a) no reply frame arrives
    /// (clean EOF on client side) and (b) the phase observed by a
    /// concurrent clone of the handle is `Draining`.
    ///
    /// @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q2),
    ///        spec:tray-host-control-socket,
    ///        spec:vm-provisioning-lifecycle
    #[test]
    fn vm_shutdown_request_on_unix_socket_flips_phase_to_draining() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        use std::sync::Mutex;
        use std::thread;

        let (server_side, mut client_side) =
            UnixStream::pair().expect("UnixStream::pair available on linux");
        let subscribers: ControlSubscribers = Arc::new(Mutex::new(Vec::new()));

        let req = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 123,
            body: ControlMessage::VmShutdownRequest {
                seq: 123,
                drain_timeout_ms: 5_000,
            },
        };
        let payload = encode(&req).expect("encode");
        client_side
            .write_all(&(payload.len() as u32).to_be_bytes())
            .expect("write len");
        client_side.write_all(&payload).expect("write body");
        client_side.flush().expect("flush");

        // Observe the post-handler phase through a separate clone of
        // the handle — same Arc, same state.
        let phase_handle = TrayPhaseHandle::ready_for_test();
        let phase_observer = phase_handle.clone();
        let server_thread = thread::spawn(move || {
            handle_control_connection(server_side, subscribers, phase_handle);
        });

        // Expect EOF, not a reply frame. read_exact on a 4-byte len
        // header should return UnexpectedEof since the handler closes
        // without writing anything.
        let mut len_buf = [0_u8; 4];
        let read_result = client_side.read_exact(&mut len_buf);
        assert!(
            read_result.is_err(),
            "expected EOF (no reply for VmShutdownRequest); got {len_buf:?}"
        );

        server_thread.join().expect("server thread joined");

        assert!(
            matches!(
                phase_observer.current_phase(),
                tillandsias_control_wire::VmPhase::Draining
            ),
            "expected phase=Draining after VmShutdownRequest; got {:?}",
            phase_observer.current_phase()
        );
    }

    fn test_state(selected_agent: SelectedAgent, forge_available: bool) -> TrayUiState {
        let enclave_status = if forge_available {
            EnclaveStatus::AllHealthy
        } else {
            EnclaveStatus::Verifying
        };
        let projects = vec![ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
            full_name: None,
        }];
        let projects_hash = TrayUiState::hash_projects(&projects);
        TrayUiState {
            root: PathBuf::from("/tmp/tillandsias-test-root"),
            version: "0.1.260506.6".to_string(),
            status_text: status_label(&enclave_status_to_stage(enclave_status)),
            tray_icon_state: if forge_available {
                TrayIconState::Mature
            } else {
                TrayIconState::Pup
            },
            projects,
            cloud_projects: Vec::new(),
            last_fetched: None,
            cloud_refresh_in_flight: false,
            cloud_no_secret_warned: false,
            debug: false,
            selected_agent,
            forge_available,
            podman_available: true,
            is_authenticated: false,
            // Existing fixtures mean "confirmed signed out", not "not asked
            // yet" — they assert the actionable login row. Defaulting to
            // observed preserves that meaning; the unobserved state has its
            // own dedicated test.
            login_observed: true,
            login_in_progress: false,
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

    #[test]
    fn tray_module_routes_all_podman_calls_through_shared_layer() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/tray/mod.rs"));

        assert!(
            !source.contains("Command::new(\"podman\")"),
            "tray module must not construct podman commands directly"
        );
        assert!(
            source.contains("podman_available_sync()"),
            "tray module must use the shared podman availability helper"
        );
        assert!(
            source.contains("image_exists_sync("),
            "tray module must use the shared podman image helper"
        );
        assert!(
            source.contains("container_exists_sync("),
            "tray module must use the shared podman container existence helper"
        );
        assert!(
            source.contains("stop_container_sync("),
            "tray module must use the shared podman stop helper"
        );
    }

    // @trace spec:tray-minimal-ux
    /// Test harness builder for simulating state transitions
    struct TrayStateBuilder {
        agent: SelectedAgent,
        forge_available: bool,
        podman_available: bool,
        is_authenticated: bool,
        login_observed: bool,
        login_in_progress: bool,
        enclave_status: EnclaveStatus,
        projects: Vec<ProjectEntry>,
        cloud_projects: Vec<ProjectEntry>,
        last_fetched: Option<Instant>,
    }

    impl TrayStateBuilder {
        fn new() -> Self {
            Self {
                agent: SelectedAgent::OpenCodeWeb,
                forge_available: false,
                podman_available: true,
                is_authenticated: false,
                // Builder states represent a CONFIRMED answer by default, so
                // `authenticated(false)` keeps meaning "signed out" in every
                // existing test rather than silently becoming "not asked yet".
                login_observed: true,
                login_in_progress: false,
                enclave_status: EnclaveStatus::Verifying,
                projects: vec![ProjectEntry {
                    name: "test-project".to_string(),
                    path: std::path::PathBuf::from("/tmp/test-project"),
                    full_name: None,
                }],
                cloud_projects: Vec::new(),
                last_fetched: None,
            }
        }

        fn forge_available(mut self, available: bool) -> Self {
            self.forge_available = available;
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

        fn authenticated(mut self, value: bool) -> Self {
            self.is_authenticated = value;
            self
        }

        fn login_in_progress(mut self, value: bool) -> Self {
            self.login_in_progress = value;
            self
        }

        fn login_observed(mut self, value: bool) -> Self {
            self.login_observed = value;
            self
        }

        #[allow(dead_code)]
        fn podman_available(mut self, value: bool) -> Self {
            self.podman_available = value;
            self
        }

        #[allow(dead_code)]
        fn cloud_projects(mut self, projects: Vec<ProjectEntry>) -> Self {
            self.cloud_projects = projects;
            self
        }

        #[allow(dead_code)]
        fn last_fetched(mut self, value: Option<Instant>) -> Self {
            self.last_fetched = value;
            self
        }

        fn build(self) -> TrayUiState {
            let status_text = if self.podman_available {
                status_label(&enclave_status_to_stage(self.enclave_status))
            } else {
                status_label(&TrayStatusStage::PodmanMissing)
            };
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
                cloud_projects: self.cloud_projects,
                last_fetched: self.last_fetched,
                cloud_refresh_in_flight: false,
                cloud_no_secret_warned: false,
                debug: false,
                selected_agent: self.agent,
                forge_available: self.forge_available,
                podman_available: self.podman_available,
                is_authenticated: self.is_authenticated,
                // See the other fixture: builder-made states represent a
                // CONFIRMED auth answer. `unobserved_login_*` sets this
                // explicitly to exercise the not-yet-asked path.
                login_observed: self.login_observed,
                login_in_progress: self.login_in_progress,
                enclave_status: self.enclave_status,
                revision: 1,
                projects_hash,
            }
        }
    }

    // @trace spec:tray-minimal-ux, spec:tray-ux
    #[test]
    fn minimal_menu_has_5_top_level_items_when_unauthenticated() {
        // When `is_authenticated == false`, the top-level menu is exactly:
        //   1. Status (id=1)
        //   2. GitHubLogin (id=20)
        //   3. Separator (id=29)
        //   4. Version + attribution (id=30)
        //   5. Quit (id=31)
        // This EXACT set is UX-curation-governed (tray-ux "UX curation
        // governance"): the unapproved Reset Guest leaf (id=32) was removed
        // by operator order 2026-07-22 and must never come back without
        // recorded approval.
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .authenticated(false)
            .build();
        let menu = build_menu(&state);

        let top_level = &menu.2;
        assert_eq!(
            top_level.len(),
            5,
            "Expected exactly 5 top-level items when unauthenticated, got {}",
            top_level.len()
        );

        let label_list = labels(&menu);
        assert!(
            label_list
                .iter()
                .any(|l| l.contains("Verifying environment")),
            "Missing status element. labels={:?}",
            label_list
        );
        assert!(
            label_list.iter().any(|l| l.contains("GitHub Login")),
            "Missing GitHub Login entry"
        );
        assert!(
            label_list
                .iter()
                .any(|l| l.contains("By Tlato") && l.contains("0.1.260506.6")),
            "Missing version + attribution. labels={:?}",
            label_list
        );
        assert!(
            label_list.iter().any(|l| l.contains("Quit Tillandsias")),
            "Missing quit button"
        );
        // ABSENCE pin (operator order 2026-07-22, tray-ux "UX curation
        // governance"): the reset-guest leaf must NOT exist on any platform;
        // the reset is CLI-only (`--reset-guest`).
        assert!(
            !label_list.iter().any(|l| l.contains("Reset Guest")),
            "Reset Guest menu leaf must be ABSENT (removed by operator order)"
        );

        // No ~/src / Cloud at this auth stage.
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(!label_list.iter().any(|l| l.contains("Cloud")));
    }

    // @trace spec:tray-minimal-ux, spec:tray-ux
    #[test]
    fn menu_expands_when_authenticated() {
        // When `is_authenticated == true` the GitHubLogin row is replaced by
        // the `Cloud` submenu, giving 5 top-level items.
        //
        // ORDER 997-e4v2 step 2: this was 6 and named the `~/src` + `Cloud`
        // PAIR. The local row is retired from the shared menu here; the native
        // scan plumbing behind it goes in step 3 with the wire.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .build();
        let menu = build_menu(&state);

        let top_level = &menu.2;
        assert_eq!(
            top_level.len(),
            5,
            "Expected 5 top-level items when authenticated, got {}",
            top_level.len()
        );

        let label_list = labels(&menu);
        // ORDER 997-e4v2 step 2: the `~/src` row is gone, so its presence
        // assertion is replaced by an ABSENCE pin. Dropping the check entirely
        // would leave the migration's own effect untested here.
        assert!(
            !label_list.iter().any(|l| l.contains("~/src")),
            "~/src submenu must be gone when authenticated. labels={:?}",
            label_list
        );
        assert!(
            label_list.iter().any(|l| l.contains("Cloud")),
            "Missing Cloud submenu"
        );
        assert!(
            !label_list.iter().any(|l| l.contains("GitHub Login")),
            "the GitHub Login row must not appear when authenticated"
        );
        // ABSENCE pin (operator order 2026-07-22, tray-ux "UX curation
        // governance"): no reset-guest leaf in the authenticated shape either.
        assert!(
            !label_list.iter().any(|l| l.contains("Reset Guest")),
            "Reset Guest menu leaf must be ABSENT (removed by operator order)"
        );
        // ORDER 997-e4v2 step 2: "test-project" is the TrayStateBuilder's
        // default LOCAL project, and local projects no longer reach the menu.
        // Pinned as absent rather than deleted, so a regression that revives
        // the local row is caught here and not only by the row count.
        assert!(
            !label_list.contains(&"test-project".to_string()),
            "local project must not appear in the menu after step 2"
        );
    }

    /// Order 627-m3vp, the Linux half of 626-r7kq's regression pin: before the
    /// auth probe has reported AT ALL, the id=20 row must be a DISABLED
    /// "Checking your account…" — never the actionable login row.
    ///
    /// `is_authenticated` is a bool defaulted false at launch, and the probe
    /// that flips it is `is_github_logged_in`, a CONTAINER RUN. For that whole
    /// window the menu used to offer an actionable sign-in to users who were
    /// already signed in — the same defect the Windows and macOS trays carried
    /// and fixed via `GithubLoginState::Unknown` (operator field log
    /// 2026-08-09T06:10:51Z).
    ///
    /// This test fails if anyone defaults `login_observed` to true in the live
    /// constructor or makes the unobserved row clickable.
    ///
    /// Order 628-p5tj: with the shared builder, the unobserved state renders
    /// "Setting up…" when the runtime is not yet ready (enclave still
    /// verifying), or "Checking your account…" when the runtime is ready but
    /// the sign-in answer is outstanding. Both are disabled.
    ///
    /// @trace spec:tray-ux, spec:tray-minimal-ux
    #[test]
    fn unobserved_login_renders_disabled_checking_row() {
        // When the enclave is still verifying, login_runtime_ready is false,
        // so the shared builder shows "Setting up…" (workspace still coming up).
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .authenticated(false)
            .login_observed(false)
            .build();
        let menu = build_menu(&state);
        let label_list = labels(&menu);
        assert!(
            label_list.iter().any(|l| l.contains("Setting up")),
            "unobserved sign-in with verifying enclave must show Setting-up row. labels={label_list:?}"
        );
        assert!(
            !label_list.iter().any(|l| l.contains("GitHub Login")),
            "an actionable sign-in must NOT be offered before the probe reports. labels={label_list:?}"
        );
        // The auth-gated body must not leak: unknown is not signed-in either.
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(!label_list.iter().any(|l| l.contains("Cloud")));

        // Disabled is the load-bearing part.
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        let (_, props) = flat
            .iter()
            .find(|(id, _)| *id == 20)
            .expect("login row id=20 must be present while unobserved");
        let enabled = props
            .get("enabled")
            .and_then(|v| v.try_clone().ok())
            .and_then(|v| bool::try_from(v).ok())
            .unwrap_or(true);
        assert!(!enabled, "the unobserved sign-in row must not be clickable");
    }

    /// Operator ruling 2026-08-09T09:04Z: "GitHub" is the canonical spelling.
    /// The Linux row read "GitHubLogin" (no space), diverging from the Windows
    /// and macOS trays AND from `locales/en.toml`'s `sign_in_github`. Pinned so
    /// the three surfaces cannot drift apart again.
    ///
    /// @trace spec:tray-ux
    #[test]
    fn confirmed_signed_out_row_uses_canonical_github_spelling() {
        let state = TrayStateBuilder::new()
            .authenticated(false)
            .login_observed(true)
            .build();
        let label_list = labels(&build_menu(&state));
        assert!(
            label_list.iter().any(|l| l.contains("GitHub Login")),
            "confirmed signed-out must offer the canonical 'GitHub Login'. labels={label_list:?}"
        );
        assert!(
            !label_list.iter().any(|l| l.contains("GitHubLogin")),
            "the un-spaced 'GitHubLogin' spelling is retired. labels={label_list:?}"
        );
    }

    /// windows-260719-2: while the login flow is in flight the id=20 row
    /// renders as a DISABLED "Logging in…" — same collapsed shape as
    /// logged-out (the project body stays auth-gated), no actionable
    /// GitHubLogin row mid-flow.
    #[test]
    fn login_in_progress_renders_disabled_logging_in_row() {
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .authenticated(false)
            .login_in_progress(true)
            .build();
        let menu = build_menu(&state);
        assert_eq!(
            menu.2.len(),
            5,
            "logging-in keeps the collapsed 5-row shape"
        );

        let label_list = labels(&menu);
        assert!(
            label_list.iter().any(|l| l.contains("Logging in")),
            "Missing the transitional Logging in… row. labels={label_list:?}"
        );
        assert!(
            !label_list.iter().any(|l| l.contains("GitHub Login")),
            "The actionable GitHub Login row must not render mid-flow"
        );
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(!label_list.iter().any(|l| l.contains("Cloud")));

        // The id=20 row itself is disabled (a second click is meaningless).
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        let (_, props) = flat
            .iter()
            .find(|(id, _)| *id == 20)
            .expect("login row id=20 must be present while logging in");
        let enabled = props
            .get("enabled")
            .and_then(|v| v.try_clone().ok())
            .and_then(|v| bool::try_from(v).ok())
            .unwrap_or(true);
        assert!(!enabled, "the Logging in… row must be disabled");
    }

    /// windows-260719-2: the three-state machine at the render level —
    /// LoggedOut shows the actionable login row; LoggingIn shows the
    /// disabled transitional row; a failed probe (login_in_progress cleared,
    /// still unauthenticated) falls back to the actionable login row; a
    /// successful probe expands the menu. Never a stale rendering.
    #[test]
    fn login_three_state_machine_renders_each_state() {
        // (1) LoggedOut: actionable GitHubLogin.
        let logged_out = TrayStateBuilder::new().authenticated(false).build();
        let labels_out = labels(&build_menu(&logged_out));
        assert!(labels_out.iter().any(|l| l.contains("GitHub Login")));

        // (2) LoggingIn: transitional row.
        let logging_in = TrayStateBuilder::new()
            .authenticated(false)
            .login_in_progress(true)
            .build();
        let labels_progress = labels(&build_menu(&logging_in));
        assert!(labels_progress.iter().any(|l| l.contains("Logging in")));

        // (3) Probe FAILED: falls back to the actionable login row.
        let probe_failed = TrayStateBuilder::new()
            .authenticated(false)
            .login_in_progress(false)
            .build();
        let labels_failed = labels(&build_menu(&probe_failed));
        assert!(
            labels_failed.iter().any(|l| l.contains("GitHub Login")),
            "a failed probe must fall back to the actionable login row"
        );
        assert!(!labels_failed.iter().any(|l| l.contains("Logging in")));

        // (4) Probe SUCCEEDED: menu expands, no login row at all.
        let logged_in = TrayStateBuilder::new()
            .authenticated(true)
            .login_in_progress(false)
            .enclave_status(EnclaveStatus::AllHealthy)
            .forge_available(true)
            .build();
        let menu_in = build_menu(&logged_in);
        let labels_in = labels(&menu_in);
        // ORDER 997-e4v2 step 2. This asserted the presence of `~/src`, but the
        // property the arm is for is "a SUCCEEDED probe EXPANDS the menu" — the
        // local row was merely the evidence, and it is retired. Assert the
        // expanded shape directly instead of through a label that no longer
        // exists: the authenticated top level, and the Cloud submenu that now
        // carries the expansion.
        assert_eq!(
            menu_in.2.len(),
            5,
            "a succeeded probe must expand to the authenticated shape. labels={labels_in:?}"
        );
        assert!(
            labels_in.iter().any(|l| l.contains("Cloud")),
            "a succeeded probe must surface the Cloud submenu. labels={labels_in:?}"
        );
        assert!(!labels_in.iter().any(|l| l.contains("~/src")));
        assert!(!labels_in.iter().any(|l| l.contains("GitHub Login")));
        assert!(!labels_in.iter().any(|l| l.contains("Logging in")));
    }

    // @trace spec:tray-ux
    #[test]
    fn cloud_menu_caps_overflow_with_50_projects() {
        // When the user has many cloud repos (the bug report mentioned 22,
        // we exaggerate to 50 to leave headroom) the `☁️ Cloud >` submenu
        // must:
        //   1. render exactly `MAX_CLOUD_PROJECTS_IN_MENU` per-project
        //      submenu entries, AND
        //   2. emit a single overflow leaf whose label encodes the total.
        //
        // Native KSNI / GMenu menus cannot scroll; this cap is what keeps
        // every project's submenu chevron on-screen so the per-project
        // launch leaves never get clipped. @trace spec:tray-ux

        let fake_projects: Vec<ProjectEntry> = (0..50)
            .map(|i| ProjectEntry {
                name: format!("repo-{i:02}"),
                path: PathBuf::new(),
                full_name: Some(format!("octocat/repo-{i:02}")),
            })
            .collect();
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .cloud_projects(fake_projects)
            .last_fetched(Some(Instant::now()))
            .build();

        let cloud_node = build_cloud_projects_submenu(&state);

        // Direct child count (per-project submenus + the single overflow
        // leaf). We assert against the runtime-resolved cap so a user with
        // `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS=999` set in the test env still
        // sees a coherent outcome — but the default ought to be 10.
        let cap = resolved_max_cloud_projects_in_menu();
        assert_eq!(
            cloud_node.2.len(),
            cap + 1,
            "Cloud submenu must show exactly `cap` projects plus one overflow leaf when total > cap; \
             children={} cap={}",
            cloud_node.2.len(),
            cap
        );

        // The overflow leaf must reference the *total* count (50), not the
        // cap. Use `labels()` to flatten the subtree and search for the
        // count.
        // ORDER 591-33s6: the label no longer says "All cloud projects", which
        // promised a full listing the click never delivered. It still carries
        // the total — that assertion is the point of this test and is kept —
        // and now also names the remedy.
        let label_list = labels(&cloud_node);
        let overflow_label = label_list
            .iter()
            .find(|l| l.contains("TILLANDSIAS_MAX_CLOUD_MENU_ITEMS"))
            .expect("Overflow row must be present and name the cap env var");
        assert!(
            overflow_label.contains("50"),
            "Overflow label must include the total project count (50), got {:?}",
            overflow_label
        );
        assert!(
            !overflow_label.contains("All cloud projects"),
            "the old label promised a listing the click never delivered: {overflow_label:?}"
        );
    }

    // @trace spec:tray-ux
    #[test]
    fn cloud_menu_omits_overflow_when_total_within_cap() {
        // Below the cap, behaviour must be unchanged: no overflow leaf.
        let cap = resolved_max_cloud_projects_in_menu();
        let n = cap.saturating_sub(1).max(1);
        let fake_projects: Vec<ProjectEntry> = (0..n)
            .map(|i| ProjectEntry {
                name: format!("repo-{i:02}"),
                path: PathBuf::new(),
                full_name: Some(format!("octocat/repo-{i:02}")),
            })
            .collect();
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .cloud_projects(fake_projects)
            .last_fetched(Some(Instant::now()))
            .build();

        let cloud_node = build_cloud_projects_submenu(&state);
        assert_eq!(
            cloud_node.2.len(),
            n,
            "Below the cap the submenu must render exactly the project list with no overflow"
        );
        let label_list = labels(&cloud_node);
        assert!(
            !label_list.iter().any(|l| l.contains("All cloud projects")),
            "Overflow label must NOT appear when total <= cap; labels={:?}",
            label_list
        );
    }

    // @trace spec:tray-ux
    #[test]
    fn cloud_menu_preserves_pushed_sort_order_under_cap() {
        // gh returns repos sorted by `pushed` (newest first). The cap must
        // trim the *tail* — i.e. the first N projects of the input list are
        // exactly the first N children of the rendered submenu (modulo the
        // overflow leaf that follows).
        let fake_projects: Vec<ProjectEntry> = (0..30)
            .map(|i| ProjectEntry {
                name: format!("recent-{i:02}"),
                path: PathBuf::new(),
                full_name: Some(format!("octocat/recent-{i:02}")),
            })
            .collect();
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .cloud_projects(fake_projects.clone())
            .last_fetched(Some(Instant::now()))
            .build();

        let cloud_node = build_cloud_projects_submenu(&state);
        let label_list = labels(&cloud_node);
        // The first project ("recent-00") must appear; the last ("recent-29")
        // must NOT (it's below the cap and hidden behind overflow).
        assert!(
            label_list.iter().any(|l| l.contains("recent-00")),
            "Newest-pushed project must be visible in the menu; labels={:?}",
            label_list
        );
        assert!(
            !label_list.iter().any(|l| l.contains("recent-29")),
            "Tail project below the cap must be hidden behind the overflow leaf; labels={:?}",
            label_list
        );
    }

    // 944-jaef, sixth freeze — emission coalescing. A burst of state
    // changes must collapse to one signal group per cooldown window, with
    // the suppressed tail flagged for the main loop's trailing flush.
    #[test]
    fn signal_emissions_coalesce_within_cooldown() {
        let state = TrayStateBuilder::new().build();
        let service = TrayService::new(state);
        assert!(service.emission_due(), "first emission passes");
        assert!(
            !service.emission_due(),
            "second emission within the cooldown is suppressed"
        );
        assert!(
            service
                .emit_pending
                .load(std::sync::atomic::Ordering::SeqCst),
            "suppressed burst is flagged for the trailing flush"
        );
    }

    // 944-jaef FIXTURE, fifth freeze — the id-0 cycle. An unknown shared-menu
    // id string used to map to dbusmenu id 0 (the root), which handed
    // gnome-shell a cyclic layout and livelocked its unguarded graph walk.
    #[test]
    fn no_layout_ever_carries_id_zero_or_duplicates() {
        // Unknown strings map to a unique nonzero fallback, never 0.
        assert_ne!(
            shared_id_to_int("agents"),
            0,
            "AGENTS must never map to root"
        );
        assert_ne!(
            shared_id_to_int("reset-guest"),
            0,
            "RESET_GUEST must never map to root"
        );
        assert_ne!(
            shared_id_to_int("agents"),
            shared_id_to_int("reset-guest"),
            "distinct unknown strings get distinct fallback ids"
        );
        assert_ne!(
            shared_id_to_int("project.bogus-scope.x.claude"),
            0,
            "unknown project scope must never map to root"
        );

        // The full authenticated layout (local + cloud projects, the shape
        // the operator's freezing click opened) contains no id 0 and no
        // duplicate ids anywhere.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .projects(vec![ProjectEntry {
                name: "tillandsias".to_string(),
                path: PathBuf::from("/home/x/src/tillandsias"),
                full_name: None,
            }])
            .cloud_projects(vec![ProjectEntry {
                name: "tillandsias".to_string(),
                path: PathBuf::new(),
                full_name: Some("owner/tillandsias".to_string()),
            }])
            .last_fetched(Some(Instant::now()))
            .build();
        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);
        assert!(flat.len() > 5, "authenticated layout is non-trivial");
        let mut seen = std::collections::HashSet::new();
        for (id, _) in &flat {
            if *id == 0 {
                // Exactly one id 0 is legal: the root itself, first in the walk.
                assert!(
                    seen.is_empty(),
                    "id 0 appeared as a NON-ROOT item — the cycle that froze five sessions"
                );
            }
            assert!(seen.insert(*id), "duplicate dbusmenu id {id} in one layout");
        }
    }

    // 944-jaef FIXTURE — the contract whose absence cost four desktop
    // sessions: GetLayout returns the subtree rooted at the REQUESTED id,
    // pruned to the REQUESTED depth. The old handler returned the id-0 full
    // tree for every request and gnome-shell's client livelocked.
    #[test]
    fn get_layout_honors_parent_id_and_recursion_depth() {
        // ORDER 997-e4v2 step 2 — REROOTED, NOT DELETED.
        //
        // This fixture was rooted at MENU_ID_LOCAL_PROJECTS, and that row is
        // retired here. The contract it pins is NOT about the local submenu: it
        // is that GetLayout returns the subtree rooted at the REQUESTED id,
        // pruned to the REQUESTED depth. That contract is untouched by this
        // migration — only the submenu it happened to exercise is going away.
        // Deleting the test would discard a pin for a defect that cost four
        // desktop sessions, for an unrelated reason. So it is rerooted onto the
        // surviving Cloud submenu and proves exactly what it did before.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .cloud_projects(vec![ProjectEntry {
                name: "tillandsias".to_string(),
                path: PathBuf::from("/home/x/src/tillandsias"),
                full_name: Some("owner/tillandsias".to_string()),
            }])
            .build();
        let service = Arc::new(TrayService::new(state));
        let iface = DbusMenuIface(service.clone());

        // Root at unlimited depth: id 0, non-empty children.
        let (_, root) =
            futures::executor::block_on(iface.get_layout(0, -1, Vec::new())).expect("root");
        assert_eq!(root.0, 0, "root request must root at 0");
        assert!(!root.2.is_empty(), "root must carry the top-level items");

        // Root at depth 0: children pruned entirely.
        let (_, shallow) =
            futures::executor::block_on(iface.get_layout(0, 0, Vec::new())).expect("depth-0 root");
        assert!(shallow.2.is_empty(), "depth 0 must prune all children");

        // Submenu request roots at the REQUESTED id — the whole 944-jaef
        // defect in one assertion.
        let submenu = MENU_ID_CLOUD_PROJECTS;
        let (_, sub) = futures::executor::block_on(iface.get_layout(submenu, 1, Vec::new()))
            .expect("submenu layout");
        assert_eq!(sub.0, submenu, "reply must be rooted at the requested id");
        assert!(!sub.2.is_empty(), "Cloud submenu has the project child");
        // Depth 1 means the project child appears but ITS children (the
        // per-agent leaves) are pruned — while children-display survives so
        // the shell still draws the arrow and asks deeper.
        for c in &sub.2 {
            let st = c
                .downcast_ref::<zbus::zvariant::Structure>()
                .expect("child is a structure");
            let fields = st.fields();
            let grandchildren = fields[2]
                .downcast_ref::<zbus::zvariant::Array>()
                .expect("children field is an array");
            assert_eq!(
                grandchildren.len(),
                0,
                "depth 1 prunes grandchildren under {:?}",
                fields[0]
            );
            let prop_str = format!("{:?}", fields[1]);
            assert!(
                prop_str.contains("children-display"),
                "pruned submenu child keeps children-display so the arrow survives"
            );
        }

        // Unknown id is an ERROR, never a guessed tree.
        let unknown = futures::executor::block_on(iface.get_layout(9999, -1, Vec::new()));
        assert!(unknown.is_err(), "unknown parent_id must error, not guess");
    }

    #[test]
    fn cloud_about_to_show_with_fresh_cache_does_not_request_immediate_relayout() {
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .cloud_projects(vec![ProjectEntry {
                name: "remote-alpha".to_string(),
                path: PathBuf::new(),
                full_name: Some("owner/remote-alpha".to_string()),
            }])
            .last_fetched(Some(Instant::now()))
            .build();
        let service = Arc::new(TrayService::new(state));
        let iface = DbusMenuIface(service);

        let result = futures::executor::block_on(iface.about_to_show(22))
            .expect("AboutToShow should succeed");

        assert!(
            !result,
            "fresh Cloud cache must not ask the shell to re-read the submenu while it opens"
        );
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn status_text_reflects_enclave_status() {
        let verifying = test_state(SelectedAgent::OpenCodeWeb, false);
        assert!(
            verifying.status_text.contains("Verifying environment"),
            "Expected Verifying label, got {:?}",
            verifying.status_text
        );
        assert_eq!(verifying.enclave_status, EnclaveStatus::Verifying);

        let ready = test_state(SelectedAgent::OpenCodeWeb, true);
        assert!(
            ready.status_text.contains("\u{2705} OK"),
            "Expected AllReady label with the OK suffix, got {:?}",
            ready.status_text
        );
        assert_eq!(ready.enclave_status, EnclaveStatus::AllHealthy);
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn state_transition_unauthenticated_to_authenticated() {
        let initial = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .authenticated(false)
            .build();
        let before = build_menu(&initial);
        assert_eq!(before.2.len(), 5);

        let after_state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .build();
        let after = build_menu(&after_state);
        // ORDER 997-e4v2 step 2. This was `assert_eq!(after.2.len(), 6)`, and
        // simply lowering it to 5 would make the test VACUOUS: `before` is also
        // 5, so a row count no longer distinguishes the two states at all, and
        // a test named "unauthenticated_to_authenticated" would pass while
        // proving nothing about the transition.
        //
        // With the local row retired, what actually changes across the
        // transition is WHICH rows are present — the GitHubLogin row is
        // replaced by the Cloud submenu — so that is what is asserted.
        assert_eq!(after.2.len(), 5);
        let before_labels = labels(&before);
        let after_labels = labels(&after);
        // NOTE the SPACE: the rendered label is "🔑 GitHub Login", pinned by
        // tillandsias-host-shell/src/lib.rs:93. Three absence-assertions in
        // this module tested `contains("GitHubLogin")` without it, which can
        // never match and therefore always passed — vacuous. Corrected under
        // 1028-3eiz; using the wrong spelling in a PRESENCE assert simply
        // fails, which is how lenovinha found it.
        //
        // ONE un-spaced assert SURVIVES on purpose, and is not the same
        // defect: the one in confirmed_signed_out_row_uses_canonical_github_
        // spelling asserts the RETIRED spelling never renders. Its subject IS
        // the un-spaced string, so it is a spelling regression pin rather than
        // a login-row absence check, and correcting it would delete the guard.
        assert!(
            before_labels.iter().any(|l| l.contains("GitHub Login")),
            "unauthenticated menu must offer login. labels={before_labels:?}"
        );
        assert!(
            !after_labels.iter().any(|l| l.contains("GitHub Login")),
            "authenticated menu must not offer login. labels={after_labels:?}"
        );
        assert!(
            after_labels.iter().any(|l| l.contains("Cloud")),
            "authenticated menu must show the Cloud submenu. labels={after_labels:?}"
        );

        // The status text moves from the verifying stack to the
        // "all ready" stack (with the OK suffix).
        assert!(initial.status_text.contains("Verifying"));
        assert!(after_state.status_text.contains("\u{2705} OK"));
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
    fn failed_enclave_status_only_changes_the_status_label() {
        // Failure no longer collapses the menu — the ~/src and Cloud rows
        // stay put. Only the Status label changes to the failure stack.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::Failed)
            .authenticated(true)
            .build();
        let menu = build_menu(&state);
        let top_level = &menu.2;
        // ORDER 997-e4v2 step 2: 6 -> 5, the local row is retired. The property
        // under test is unchanged — a failed enclave changes the STATUS LABEL
        // and nothing else about the shape.
        assert_eq!(top_level.len(), 5, "Failure must preserve menu shape");

        let label_list = labels(&menu);
        // labels()[0] is the root menu container ("Tillandsias");
        // [1] is the Status row.
        let status_line = &label_list[1];
        assert!(
            status_line.contains("\u{274C}"),
            "Status must show the failure marker, got {:?}",
            status_line
        );
        // ORDER 997-e4v2 step 2: was a PRESENCE assert on ~/src; the row is
        // retired, so it becomes an absence pin and the surviving rows keep
        // theirs. The point of this test is that failure changes only the
        // status label, so the other rows must still be asserted.
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(label_list.iter().any(|l| l.contains("Cloud")));
        assert!(label_list.iter().any(|l| l.contains("Quit Tillandsias")));
    }

    #[test]
    fn project_submenu_has_seven_leaves_in_order() {
        // Per-project submenus are 7-leaf flat menus: Claude, Codex,
        // OpenCode, Antigravity, OpenCode Web, Observatorium, Maintenance.
        // Order is locked by `LeafAction::offset`.
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
            full_name: None,
        };
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .authenticated(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .projects(vec![project.clone()])
            .build();
        let submenu = build_project_submenu(&state, &project, ProjectScope::Cloud);

        // Seven leaves, no sub-submenus.
        assert_eq!(submenu.2.len(), 7);
        let leaf_labels = labels(&submenu);
        // labels() walks the layout depth-first; index 0 is the submenu
        // container, indices 1..=7 are the leaves in offset order.
        assert_eq!(leaf_labels[0], "alpha");
        assert!(leaf_labels[1].contains("Claude"));
        assert!(leaf_labels[2].contains("Codex"));
        assert!(leaf_labels[3].contains("OpenCode") && !leaf_labels[3].contains("Web"));
        assert!(leaf_labels[4].contains("Antigravity"));
        assert!(leaf_labels[5].contains("OpenCode Web"));
        assert!(leaf_labels[6].contains("Observatorium"));
        assert!(leaf_labels[7].contains("Maintenance"));
    }

    #[test]
    fn project_leaves_disabled_when_podman_missing() {
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
            full_name: None,
        };
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .podman_available(false)
            .authenticated(true)
            .enclave_status(EnclaveStatus::Failed)
            .projects(vec![project.clone()])
            .build();
        let submenu = build_project_submenu(&state, &project, ProjectScope::Cloud);

        let mut flat = Vec::new();
        flatten_layout(&submenu, &mut flat);
        for (id, props) in flat.iter() {
            // Skip the submenu container itself.
            if *id == cloud_project_base(&project.name) + PROJECT_SUBMENU_OFFSET {
                continue;
            }
            let enabled = props
                .get("enabled")
                .and_then(|v| v.try_clone().ok())
                .and_then(|v| bool::try_from(v).ok())
                .unwrap_or(true);
            assert!(!enabled, "leaf id={} should be disabled", id);
        }
    }

    #[test]
    fn launch_command_targets_the_forge_image_and_project_mount() {
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
            full_name: None,
        };
        let spec = build_launch_spec(
            &project,
            LaunchKind::Claude,
            "tillandsias-forge:v0.1.260506.6",
        );
        let args = spec
            .build_run_argv()
            .expect("the tray launch spec must satisfy the hardening envelope (972-6vaj)");

        assert_eq!(args[0], "run");
        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--name".to_string()));
        assert!(args.contains(&"tillandsias-alpha-claude".to_string()));
        assert!(args.contains(&"TILLANDSIAS_AGENT=claude".to_string()));
        assert!(args.contains(&"--hostname".to_string()));
        assert!(args.contains(&"forge-alpha".to_string()));
        assert!(args.contains(&"--entrypoint".to_string()));
        assert!(args.contains(&"/usr/local/bin/entrypoint-forge-claude.sh".to_string()));
        assert!(args.contains(&"tillandsias-forge:v0.1.260506.6".to_string()));
    }

    // @trace spec:tray-ux, spec:browser-isolation-tray-integration
    // Regression: tray launch clicks were silently failing on Fedora
    // Silverblue because `--debug` was hardcoded `false` at every tray
    // launch-site, which suppressed every `[tillandsias] launch_forge_agent:
    // ...` log line. Once the user reported a silent failure there was no
    // log trail to debug from. Pin that:
    //   1. `launch_project_action` accepts a `debug` flag,
    //   2. `handle_launch_project` reads `snapshot.debug` and forwards it.
    #[test]
    fn tray_launch_threads_debug_flag_into_launch_helpers() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/tray/mod.rs"));

        // launch_project_action must take a debug parameter and forward it
        // into super::launch_forge_agent / run_opencode_web_mode /
        // run_observatorium_mode (not hardcoded `false`).
        assert!(
            source.contains("fn launch_project_action(") && source.contains("    debug: bool,"),
            "launch_project_action must take debug: bool"
        );
        assert!(
            source.contains("super::launch_forge_agent(&project.name, &project.path, mode, debug)"),
            "launch_project_action must forward debug to launch_forge_agent (not false)"
        );
        assert!(
            source.contains("super::run_opencode_web_mode(&project_path, None, None, debug)"),
            "launch_project_action must forward debug to run_opencode_web_mode (not false)"
        );
        assert!(
            source.contains("super::run_observatorium_mode(&project_path, None, debug)"),
            "launch_project_action must forward debug to run_observatorium_mode (not false)"
        );

        // handle_launch_project must read debug from the tray snapshot —
        // otherwise --debug on the binary never reaches the launchers.
        assert!(
            source.contains("let debug = snapshot.debug;"),
            "handle_launch_project must read debug from tray snapshot"
        );

        // Click-receipt and failure-status: the user must see SOMETHING on
        // every click and a tray-visible status when the spawn fails.
        assert!(
            source.contains("[tillandsias] tray: launching"),
            "handle_launch_project must emit a click-receipt to stderr"
        );
        assert!(
            source.contains("🥀 Launch failed:"),
            "handle_launch_project must surface launch failures via tray status"
        );
    }

    #[test]
    fn launch_command_opencode_web_is_detached_and_persistent() {
        let project = ProjectEntry {
            name: "alpha".to_string(),
            path: PathBuf::from("/tmp/alpha"),
            full_name: None,
        };
        let spec = build_launch_spec(
            &project,
            LaunchKind::OpenCodeWeb,
            "tillandsias-forge:v0.1.260506.6",
        );
        let args = spec
            .build_run_argv()
            .expect("the tray launch spec must satisfy the hardening envelope (972-6vaj)");

        assert_eq!(args[0], "run");
        assert!(args.contains(&"-d".to_string()));
        assert!(!args.contains(&"--rm".to_string()));
        assert!(!args.contains(&"--interactive".to_string()));
        assert!(!args.contains(&"--tty".to_string()));
        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--entrypoint".to_string()));
        assert!(args.contains(&"/usr/local/bin/entrypoint-forge-opencode-web.sh".to_string()));
        assert!(args.contains(&"TILLANDSIAS_AGENT=opencode-web".to_string()));
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
    fn unauthenticated_menu_excludes_local_and_cloud_submenus() {
        let state = TrayStateBuilder::new()
            .forge_available(false)
            .enclave_status(EnclaveStatus::Verifying)
            .authenticated(false)
            .projects(vec![ProjectEntry {
                name: "project-alpha".to_string(),
                path: PathBuf::from("/tmp/project-alpha"),
                full_name: None,
            }])
            .build();

        let menu = build_menu(&state);
        assert_eq!(menu.2.len(), 5, "Unauthenticated top-level must be 5 items");

        let label_list = labels(&menu);
        assert!(label_list.iter().any(|l| l.contains("GitHub Login")));
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(!label_list.iter().any(|l| l.contains("Cloud")));
        assert!(!label_list.contains(&"project-alpha".to_string()));
    }

    // @trace spec:tray-minimal-ux, spec:tray-progress-and-icon-states
    #[test]
    fn menu_collapses_on_failed_enclave_status() {
        // Failure no longer collapses the menu shape. The top-level row
        // count and the ~/src / Cloud submenus must still be there; only
        // the Status row changes label to a failure stack.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::Failed)
            .authenticated(true)
            .projects(vec![ProjectEntry {
                name: "project-beta".to_string(),
                path: PathBuf::from("/tmp/project-beta"),
                full_name: None,
            }])
            .build();

        let menu = build_menu(&state);
        // ORDER 997-e4v2 step 2: 6 -> 5, the local row is retired.
        assert_eq!(menu.2.len(), 5, "Top-level must keep 5 rows on failure");

        let label_list = labels(&menu);
        // labels()[0] is the root menu container ("Tillandsias");
        // [1] is the Status row.
        assert!(
            label_list[1].contains("\u{274C}"),
            "Status row must show the failure marker, got {:?}",
            label_list[1]
        );
        // ORDER 997-e4v2 step 2. `project-beta` is seeded as a LOCAL project by
        // this test's builder, so both it and the ~/src row it lived under are
        // now absent. Pinned as absent rather than deleted: this test's job is
        // that a failed enclave does not collapse the menu, and a regression
        // that revived the local row would otherwise pass it silently.
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(label_list.iter().any(|l| l.contains("Cloud")));
        assert!(!label_list.contains(&"project-beta".to_string()));
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn submenu_leaves_visible_when_authenticated() {
        // When ~/src and Cloud submenus are present, every leaf and every
        // submenu container must carry `visible=true`.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .projects(vec![ProjectEntry {
                name: "test-proj".to_string(),
                path: PathBuf::from("/tmp/test-proj"),
                full_name: None,
            }])
            .build();

        let menu = build_menu(&state);
        let mut flat = Vec::new();
        flatten_layout(&menu, &mut flat);

        for (id, props) in flat.iter() {
            // Root (id=0) and separator (id=29) carry no `visible` flag
            // with the same semantics; skip them.
            if matches!(id, 0 | 29) {
                continue;
            }
            assert_eq!(
                props
                    .get("visible")
                    .and_then(|v| v.try_clone().ok())
                    .and_then(|v| bool::try_from(v).ok()),
                Some(true),
                "Item {} should be visible",
                id
            );
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn menu_items_match_current_status() {
        // The menu's Status row reflects the cumulative emoji stack
        // computed by `status_label`. Each enclave status maps onto the
        // new stage enum via `enclave_status_to_stage`.
        type Predicate = fn(&str) -> bool;
        let cases: Vec<(EnclaveStatus, Predicate)> = vec![
            (EnclaveStatus::Verifying, |s| {
                s.contains("Verifying environment")
            }),
            (EnclaveStatus::AllHealthy, |s| s.contains("\u{2705} OK")),
            (EnclaveStatus::Failed, |s| s.contains("\u{274C}")),
        ];

        for (status, predicate) in cases {
            let state = TrayStateBuilder::new()
                .enclave_status(status)
                .forge_available(status == EnclaveStatus::AllHealthy)
                .authenticated(false)
                .build();

            let menu = build_menu(&state);
            let label_list = labels(&menu);
            // labels()[0] is the root menu container ("Tillandsias");
            // [1] is the Status row.
            let status_line = &label_list[1];
            assert!(
                predicate(status_line),
                "Status label mismatch for {:?}: {:?}",
                status,
                status_line
            );
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn base_items_never_disabled() {
        // Status (id=1) and version (id=30) are always informational;
        // separator (id=29) carries no `enabled` flag; quit (id=31) is
        // always enabled. Verify across multiple state combinations.
        let states = vec![
            TrayStateBuilder::new()
                .forge_available(false)
                .enclave_status(EnclaveStatus::Verifying)
                .authenticated(false)
                .build(),
            TrayStateBuilder::new()
                .forge_available(true)
                .enclave_status(EnclaveStatus::AllHealthy)
                .authenticated(true)
                .build(),
            TrayStateBuilder::new()
                .forge_available(true)
                .enclave_status(EnclaveStatus::Failed)
                .authenticated(true)
                .build(),
        ];

        for state in states {
            let menu = build_menu(&state);
            let mut flat = Vec::new();
            flatten_layout(&menu, &mut flat);

            for (id, props) in flat.iter() {
                match id {
                    1 => {
                        assert_eq!(
                            props
                                .get("enabled")
                                .and_then(|v| v.try_clone().ok())
                                .and_then(|v| bool::try_from(v).ok()),
                            Some(false),
                            "Status (id=1) should be disabled"
                        );
                    }
                    29 => {
                        // Separator: carries `type=separator`, no enabled flag.
                    }
                    30 => {
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

        // Give worker threads (4 of them) a moment to start and block on the receiver.
        std::thread::sleep(std::time::Duration::from_millis(100));

        // To fill the executor capacity completely, we need to spawn:
        // 4 (active workers) + 2 (bounded queue size) = 6 tasks.
        // All of them should be accepted.
        for _ in 0..6 {
            assert!(
                executor
                    .spawn_task(|| {
                        std::thread::sleep(std::time::Duration::from_secs(10));
                    })
                    .is_ok()
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }

        // The 7th task must fail because all workers are busy and the queue is full.
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

    /// Regression: a freshly cloned checkout must appear in `~/src` without a
    /// tray restart. `refresh_local_projects` is the post-startup writer that
    /// re-scans the project root into `state.projects`; before the fix for
    /// plan/issues/clone-tray-ux-not-refreshed-2026-06-18.md there was no such
    /// writer, so the `🏠 ~/src` submenu stayed frozen at its startup snapshot.
    ///
    /// This exercises the scan-and-store contract (`discover_projects_in` +
    /// store + revision bump) the clone-success path relies on, against a temp
    /// dir so we never mutate the process-global `HOME`.
    /// @trace spec:tray-ux, spec:remote-projects
    #[test]
    fn refresh_local_projects_picks_up_new_checkout() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let src = tmp.path();

        // Initial scan: one existing checkout.
        std::fs::create_dir(src.join("alpha")).expect("mkdir alpha");
        let initial = discover_projects_in(src);
        assert_eq!(initial.len(), 1);
        assert_eq!(initial[0].name, "alpha");

        // Seed a TrayService whose state reflects the initial scan, then
        // simulate a clone landing a second checkout on disk.
        let mut state = test_state(SelectedAgent::OpenCode, true);
        state.projects = initial;
        state.projects_hash = TrayUiState::hash_projects(&state.projects);
        let service = TrayService::new(state);
        let rev_before = service.snapshot().revision;

        std::fs::create_dir(src.join("beta")).expect("mkdir beta");

        // The runtime helper scans $HOME/src; here we replicate its body
        // against the temp root to assert the store + revision-bump contract
        // without touching HOME.
        let rescanned = discover_projects_in(src);
        service.with_state(|st| {
            st.projects_hash = TrayUiState::hash_projects(&rescanned);
            st.projects = rescanned;
            st.bump_revision();
        });

        let after = service.snapshot();
        assert_eq!(
            after
                .projects
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha", "beta"],
            "rescan must surface the newly cloned checkout, sorted"
        );
        assert!(
            after.revision > rev_before,
            "refresh must bump the menu revision so the submenu re-renders"
        );
    }

    /// Order 628-p5tj: verify that the shared builder's string IDs map to
    /// the exact integer IDs the `event()` handler dispatches on. This is
    /// the cross-platform contract — a regression here means the tray
    /// dispatches clicks to the wrong handler on Linux.
    // `base + 0` is deliberate and must stay. These assertions are a TABLE of
    // agent slot offsets — `+ 0`, `+ 1`, `+ 2` read down the page as the slot
    // numbers they encode. Collapsing the first to a bare `base_local` would
    // satisfy identity_op and hide the one fact the table exists to state:
    // that `claude` is slot ZERO. The lint is right in general and wrong here.
    #[allow(clippy::identity_op)]
    #[test]
    fn shared_id_to_int_matches_event_dispatch_contract() {
        use tillandsias_host_shell::menu_state::ids;

        assert_eq!(shared_id_to_int(ids::STATUS), 10);
        assert_eq!(shared_id_to_int(ids::GITHUB_LOGIN), 20);
        assert_eq!(shared_id_to_int(ids::CLOUD_PROJECTS), 22);
        assert_eq!(shared_id_to_int(ids::SEPARATOR), 29);
        assert_eq!(shared_id_to_int(ids::VERSION), 30);
        assert_eq!(shared_id_to_int(ids::QUIT), 31);

        // 997-e4v2 step 3: `project.local.*` no longer parses as a scope, so
        // these fall to fallback_menu_id and land in 0x0800_0000..0x1000_0000.
        //
        // NOT ZERO, AND THE DISTINCTION IS THE WHOLE POINT. My first version of
        // this assertion expected 0 on the reasoning that an unresolvable id
        // "maps to nothing". Read fallback_menu_id's docstring: id 0 is a
        // SESSION KILLER — gnome-shell's appindicator walks the item graph with
        // an unguarded queue, and an unknown item at id 0 makes a root cycle
        // that wedged an entire Wayland session on one click. Had the code
        // returned 0 my test would have PINNED that as correct. It returns a
        // dead, uniquely-numbered leaf instead, which is the behaviour that
        // exists precisely because 0 is catastrophic.
        let stale = shared_id_to_int("project.local.my-project.claude");
        assert!(
            (0x0800_0000..0x1000_0000).contains(&stale),
            "a stale local id must land in the dead-leaf fallback range, got {stale}"
        );
        assert_ne!(stale, 0, "id 0 wedges the session — see fallback_menu_id");
        assert!(
            stale < CLOUD_BASE_LO,
            "a stale local id must not collide with a cloud project base"
        );

        // Cloud projects use cloud_project_base
        let base_cloud = cloud_project_base("my-project");
        assert_eq!(
            shared_id_to_int("project.cloud.my-project.claude"),
            base_cloud + 0
        );

        // Placeholder and overflow IDs
        assert_eq!(
            shared_id_to_int(ids::CLOUD_PROJECTS_EMPTY),
            LOADING_CLOUD_ID
        );
        assert_eq!(
            shared_id_to_int(ids::CLOUD_PROJECTS_LOADING),
            LOADING_CLOUD_ID
        );
        assert_eq!(
            shared_id_to_int(ids::CLOUD_PROJECTS_OVERFLOW),
            CLOUD_OVERFLOW_ID
        );
    }
}
