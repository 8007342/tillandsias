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

/// Path of the NDJSON MCP tool socket served for in-forge agents (order
/// 363). Lives in its OWN subdirectory so the directory — not the socket
/// file — can be bind-mounted into forge containers: a tray restart
/// re-binds the socket inode, and a file bind-mount would go stale while
/// a directory mount picks the fresh socket up.
///
/// This is deliberately NOT `control.sock`. The control socket speaks
/// postcard-framed `ControlEnvelope`s and carries the whole host control
/// plane (VmShutdownRequest, IssueWebSession, …); the repo — including the
/// wire format — is checked out inside every forge, so exposing it would
/// hand agent code the full control plane. The MCP socket carries ONLY the
/// JSON-RPC tool surface, and the project label is derived host-side from
/// SO_PEERCRED, never from the request.
///
/// @trace spec:host-browser-mcp, spec:tray-host-control-socket
fn mcp_socket_path() -> PathBuf {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })));
    runtime_dir.join("tillandsias/mcp/mcp.sock")
}

// Env var that overrides the default Linux-native host project root.
// Linux native (the tray running on the user's desktop, not in-VM)
// resolves projects from the host filesystem — convention is
// `$HOME/src` unless the user pins something else. (Orphaned doc: the
// const it documented moved; kept as prose for the next reader.)

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
    stream.write_all(&(payload.len() as u32).to_be_bytes())?;
    stream.write_all(&payload)?;
    stream.flush()
}

fn broadcast_control_envelope(subscribers: &ControlSubscribers, envelope: &ControlEnvelope) {
    let mut subscribers = subscribers.lock().expect("control subscribers lock");
    subscribers.retain(|subscriber| {
        let Ok(mut stream) = subscriber.lock() else {
            return false;
        };
        write_control_envelope(&mut stream, envelope).is_ok()
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

/// Resolve the peer's project label from its process environment:
/// SO_PEERCRED → `/proc/<pid>/environ` → `TILLANDSIAS_PROJECT`. Works for
/// in-forge peers because `--userns=keep-id` maps the forge uid onto the
/// tray's host uid, so the environ file is readable. Returns `None` when
/// the peer cannot be attributed to a project — callers must deny, loudly.
///
/// @trace spec:host-browser-mcp
fn resolve_peer_project(stream: &UnixStream) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        // SO_PEERCRED via nix (std's UCred::pid() is behind the unstable
        // peer_credentials_unix_socket feature — broke the all-features/
        // tray builds on stable Rust).
        let cred = nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
            .ok()?;
        let pid = cred.pid();
        if pid <= 0 {
            return None;
        }
        let env_str = std::fs::read_to_string(format!("/proc/{}/environ", pid as u32)).ok()?;
        env_str.split('\0').find_map(|kv| {
            let mut parts = kv.splitn(2, '=');
            if parts.next() == Some("TILLANDSIAS_PROJECT") {
                parts.next().map(String::from)
            } else {
                None
            }
        })
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = stream;
        None
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
fn handle_mcp_jsonrpc(project_label: &str, req: &serde_json::Value) -> Option<serde_json::Value> {
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
        "tools/list" => serde_json::json!({
            "result": {
                "tools": [
                    {
                        "name": "publish_local",
                        "description": "Publish this project's WEB service on the local reverse proxy and return its www.<project>.localhost URL. Idempotent: re-publishing replaces the running container and keeps the same URL.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "category": { "type": "string", "enum": ["WEB"] }
                            },
                            "required": ["category"]
                        }
                    },
                    {
                        "name": "service_status",
                        "description": "Report the state of this project's published local service.",
                        "inputSchema": { "type": "object", "properties": {} }
                    },
                    {
                        "name": "service_stop",
                        "description": "Stop this project's published local service and remove its route.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "category": { "type": "string", "enum": ["WEB"] }
                            },
                            "required": ["category"]
                        }
                    }
                ]
            }
        }),
        "tools/call" => {
            let tool_name = req["params"]["name"].as_str().unwrap_or("");
            let args = req["params"]["arguments"].as_object();

            // MULTI-thread runtime is load-bearing: the publish path re-enters
            // podman_runtime()'s RuntimeOrHandle::block_on, which uses
            // tokio::task::block_in_place — a PANIC on current-thread runtimes
            // ("can call blocking only when running on the multi-threaded
            // runtime"; live repro 2026-07-16, first tray publish_local killed
            // its connection thread). The deny/handshake paths never hit it,
            // so only a live publish exposes a regression here.
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();

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
/// per line out (notifications get no line). An unattributed peer gets a
/// single loud deny naming the project gate, then the connection closes —
/// the same fail-closed contract as the envelope arm.
///
/// @trace spec:host-browser-mcp
fn serve_mcp_connection(stream: UnixStream, project_label: Option<String>) {
    use std::io::{BufRead, BufReader};

    let mut writer = stream;

    let Some(project_label) = project_label else {
        let deny = serde_json::json!({
            "jsonrpc": "2.0",
            "id": serde_json::Value::Null,
            "error": {
                "code": -32000,
                "message": "Missing or unresolvable TILLANDSIAS_PROJECT in peer environment",
            }
        });
        let _ = writeln!(writer, "{deny}");
        return;
    };

    let Ok(read_half) = writer.try_clone() else {
        return;
    };
    for line in BufReader::new(read_half).lines() {
        let Ok(line) = line else {
            return;
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let resp = match serde_json::from_str::<serde_json::Value>(line) {
            Ok(req) => handle_mcp_jsonrpc(&project_label, &req),
            Err(_) => Some(serde_json::json!({
                "jsonrpc": "2.0",
                "id": serde_json::Value::Null,
                "error": {
                    "code": -32700,
                    "message": "Parse error: expected one JSON-RPC object per line",
                }
            })),
        };
        if let Some(resp) = resp
            && writeln!(writer, "{resp}").is_err()
        {
            return;
        }
    }
}

/// Bind the NDJSON MCP tool socket and serve it from detached threads,
/// mirroring `start_control_socket_server`'s std::thread shape. The socket
/// is 0600 — with `--userns=keep-id` the forge peer maps to the tray's own
/// uid, so in-forge agents can connect while other host users cannot.
///
/// @trace spec:host-browser-mcp, spec:tray-host-control-socket
fn start_mcp_socket_server() -> Result<(), String> {
    let socket_path = mcp_socket_path();
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create mcp socket directory: {err}"))?;
    }
    if socket_path.exists() {
        fs::remove_file(&socket_path)
            .map_err(|err| format!("failed to remove stale mcp socket: {err}"))?;
    }

    let listener = UnixListener::bind(&socket_path)
        .map_err(|err| format!("failed to bind mcp socket: {err}"))?;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|err| format!("failed to chmod mcp socket: {err}"))?;

    std::thread::spawn(move || {
        for incoming in listener.incoming() {
            match incoming {
                Ok(stream) => {
                    std::thread::spawn(move || {
                        let project = resolve_peer_project(&stream);
                        serve_mcp_connection(stream, project);
                    });
                }
                Err(err) => warn!(error = %err, "mcp socket accept failed"),
            }
        }
    });

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
                        },
                    };
                    if write_control_envelope(&mut stream, &ack).is_err() {
                        return;
                    }
                    subscribers
                        .lock()
                        .expect("control subscribers lock")
                        .push(Arc::new(Mutex::new(stream)));
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
                ControlMessage::EnumerateLocalProjects { seq } => {
                    // Linux-native EnumerateLocalProjects handler (Q4
                    // answer of the convergence packet). Mirrors the
                    // vsock-side `enumerate_local_projects` but points
                    // at the host filesystem (default `$HOME/src`)
                    // instead of the in-VM bind-mount root.
                    //
                    // @trace spec:host-shell-architecture
                    // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
                    let entries = crate::local_projects::scan_project_root(
                        &crate::local_projects::host_project_root(),
                    );
                    let reply = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::LocalProjectsReply {
                            seq_in_reply_to: seq,
                            entries,
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &reply);
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
                    let projects = crate::cloud_projects::fetch_cloud_projects(None);
                    let reply = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::CloudRefreshReply {
                            seq_in_reply_to: seq,
                            projects,
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
                ControlMessage::McpFrame {
                    session_id: in_session_id,
                    payload,
                } => {
                    // Project label comes from the SESSION (peer attribution
                    // via SO_PEERCRED), never from the request. Shared with
                    // the NDJSON mcp.sock transport — the two paths dispatch
                    // through the same `handle_mcp_jsonrpc` so they can
                    // never disagree on the tool surface.
                    //
                    // @trace spec:host-browser-mcp
                    let Some(project_label) = resolve_peer_project(&stream) else {
                        let err = ControlEnvelope {
                            wire_version: WIRE_VERSION,
                            seq: first.seq,
                            body: ControlMessage::Error {
                                seq_in_reply_to: Some(first.seq),
                                code: ErrorCode::Unsupported,
                                message: "Missing or unresolvable TILLANDSIAS_PROJECT in peer environment".to_string(),
                            },
                        };
                        let _ = write_control_envelope(&mut stream, &err);
                        return;
                    };

                    let Ok(req_str) = std::str::from_utf8(&payload) else {
                        return;
                    };

                    let Ok(req) = serde_json::from_str::<serde_json::Value>(req_str) else {
                        return;
                    };

                    // Notifications get no reply frame (JSON-RPC 2.0).
                    let Some(resp) = handle_mcp_jsonrpc(&project_label, &req) else {
                        return;
                    };

                    let reply = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: first.seq,
                        body: ControlMessage::McpFrame {
                            session_id: in_session_id,
                            payload: serde_json::to_vec(&resp).unwrap(),
                        },
                    };
                    let _ = write_control_envelope(&mut stream, &reply);
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
}

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

    fn project_by_name(&self, name: &str) -> Option<ProjectEntry> {
        self.snapshot()
            .projects
            .into_iter()
            .find(|project| project.name == name)
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
    let ca_cert = PathBuf::from("/tmp/tillandsias-ca/intermediate.crt");
    let no_proxy = enclave_no_proxy();

    let mut spec = ContainerSpec::new(image.to_string())
        .name(format!(
            "tillandsias-{}-{}",
            project_name,
            action_slug(kind)
        ))
        .hostname(super::sanitize_hostname(&format!("forge-{project_name}")))
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
        .env("no_proxy", no_proxy.clone())
        .env("NO_PROXY", no_proxy)
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
    launch_in_terminal("Tillandsias - Root", "podman", &spec.build_run_argv())
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
    Local,
    Cloud,
}

const LOCAL_BASE_LO: i32 = 0x1000_0000;
const LOCAL_BASE_HI: i32 = 0x5000_0000;
const CLOUD_BASE_LO: i32 = 0x5000_0000;
const CLOUD_BASE_HI: i32 = 0x7FFF_FFF0;
const LOADING_LOCAL_ID: i32 = 0x7FFF_FFFD;
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

fn project_base(name: &str, scope: ProjectScope) -> i32 {
    use std::hash::Hash;
    use std::hash::Hasher;
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut hash);
    let (lo, hi) = match scope {
        ProjectScope::Local => (LOCAL_BASE_LO, LOCAL_BASE_HI),
        ProjectScope::Cloud => (CLOUD_BASE_LO, CLOUD_BASE_HI),
    };
    // Quantise to multiples of 16 so leaf offsets (0..=5) never overflow
    // into the next project's base.
    let span = ((hi - lo) / 16) as u32;
    let raw = (hash.finish() as u32) % span.max(1);
    lo + (raw as i32) * 16
}

fn local_project_base(name: &str) -> i32 {
    project_base(name, ProjectScope::Local)
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
    for project in &state.projects {
        let base = local_project_base(&project.name);
        if id >= base && id < base + PROJECT_LEAF_COUNT {
            return Some((
                project.name.clone(),
                ProjectScope::Local,
                LeafAction::from_offset(id - base),
            ));
        }
        if id == base + PROJECT_SUBMENU_OFFSET {
            return Some((project.name.clone(), ProjectScope::Local, None));
        }
    }
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
fn build_project_submenu(
    state: &TrayUiState,
    project: &ProjectEntry,
    scope: ProjectScope,
) -> MenuNode {
    let base = match scope {
        ProjectScope::Local => local_project_base(&project.name),
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

/// Build the `~/src >` submenu listing every discovered local project.
///
/// When the project list is empty (still loading, or genuinely empty
/// `~/src`), a single disabled `(loading…)` child is emitted so the
/// submenu chevron doesn't dead-end.
fn build_local_projects_submenu(state: &TrayUiState) -> MenuNode {
    let mut children: Vec<OwnedValue> = state
        .projects
        .iter()
        .map(|p| child(build_project_submenu(state, p, ProjectScope::Local)))
        .collect();
    if children.is_empty() {
        children.push(child(node(
            LOADING_LOCAL_ID,
            props(vec![
                ("label".to_string(), ov_str("(loading\u{2026})")),
                ("enabled".to_string(), ov(Value::from(false))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }
    node(
        21,
        props(vec![
            ("label".to_string(), ov_str("\u{1F3E0} ~/src")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
            ("children-display".to_string(), ov_str("submenu")),
        ]),
        children,
    )
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
/// @trace spec:tray-ux, spec:remote-projects
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
    // The label includes the *total* count so the user knows how many repos
    // are hidden. Clicking dumps the full list to stderr (see
    // `event` dispatch on `CLOUD_OVERFLOW_ID`).
    //
    // TODO(@tray-overflow): replace the stderr dump with a GtkWindow-based
    // project picker once the headless binary grows GTK plumbing. The
    // current tray module is pure StatusNotifierItem/DBusMenu over zbus —
    // adding a window would require a new GTK application thread, GResource
    // setup, and a theming hook, none of which exist here today. The cap +
    // overflow item is the standard pattern for native indicator menus and
    // resolves the user-visible clipping bug on its own.
    if total > visible_count {
        let label = format!("\u{2026} All cloud projects ({})\u{2026}", total);
        children.push(child(node(
            CLOUD_OVERFLOW_ID,
            props(vec![
                ("label".to_string(), ov_str(label)),
                ("enabled".to_string(), ov(Value::from(true))),
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

// @trace spec:tray-minimal-ux, spec:tray-ux, spec:tray-progress-and-icon-states
/// Build the minimal tray menu.
///
/// ## Final shape (top to bottom)
///
/// ```text
/// 1. Status (disabled, live-updating)            id=1
/// 2. 🔑 GitHubLogin                              id=20  (visible iff NOT authenticated)
///    OR
///    🏠 ~/src >                                  id=21  (visible iff authenticated)
///    ☁️ Cloud >                                  id=22  (visible iff authenticated)
/// 3. ─── separator ───                           id=29
/// 4. v<full-version> — By Tlatoāni              id=30  (disabled)
/// 5. ❌ Quit Tillandsias                         id=31
/// ```
///
/// ## Item-count contract
///
/// | Authenticated? | Visible top-level items |
/// |----------------|-------------------------|
/// | No             | 5: status + login + separator + version + quit |
/// | Yes            | 6: status + ~/src + Cloud + separator + version + quit |
///
/// ## Podman-unavailable degradation
///
/// When `state.podman_available == false`, *every* per-project leaf is
/// emitted with `enabled=false` and the status line is replaced with
/// `❌ Podman not available`. The top-level shape is unchanged so the menu
/// remains stable across the failure boundary.
fn build_menu(state: &TrayUiState) -> MenuNode {
    let mut children = Vec::new();

    // (1) Status element — always visible, always disabled.
    let status_text = if state.podman_available {
        state.status_text.clone()
    } else {
        status_label(&TrayStatusStage::PodmanMissing)
    };
    children.push(child(node(
        1,
        props(vec![
            ("label".to_string(), ov_str(status_text)),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    // (2) Auth-gated row. Exactly one of {GitHubLogin} OR {~/src, Cloud}
    //     is emitted, never both.
    if state.is_authenticated {
        children.push(child(build_local_projects_submenu(state)));
        children.push(child(build_cloud_projects_submenu(state)));
    } else {
        children.push(child(node(
            20,
            props(vec![
                ("label".to_string(), ov_str("\u{1F511} GitHubLogin")),
                ("enabled".to_string(), ov(Value::from(true))),
                ("visible".to_string(), ov(Value::from(true))),
            ]),
            Vec::new(),
        )));
    }

    // (3) Separator.
    children.push(child(build_separator_item(29)));

    // (4) Version + attribution. Always disabled.
    children.push(child(node(
        30,
        props(vec![
            (
                "label".to_string(),
                ov_str(format!("v{} \u{2014} By Tlatoa\u{0304}ni", state.version)),
            ),
            ("enabled".to_string(), ov(Value::from(false))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

    // (5) Quit.
    children.push(child(node(
        31,
        props(vec![
            ("label".to_string(), ov_str("\u{274C} Quit Tillandsias")),
            ("enabled".to_string(), ov(Value::from(true))),
            ("visible".to_string(), ov(Value::from(true))),
        ]),
        Vec::new(),
    )));

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

    async fn about_to_show(&self, id: i32) -> fdo::Result<(bool, bool)> {
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
        Ok((false, false))
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
            21 | 22 | 29 | 30 => {
                // submenu container, separator, or version label — no-op.
            }
            CLOUD_OVERFLOW_ID => {
                // Cloud overflow leaf — dump the full project list to stderr
                // as the documented fallback for "no GtkWindow picker yet".
                // See TODO(@tray-overflow) in `build_cloud_projects_submenu`.
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
                            ProjectScope::Local => {
                                if let Some(project_entry) = self.0.project_by_name(&project_name) {
                                    handle_launch_project(self.0.clone(), project_entry, kind);
                                }
                            }
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
                if crate::remote_projects::is_github_logged_in(debug) {
                    {
                        let mut state = state_handle.lock().expect("tray state lock");
                        if !state.is_authenticated {
                            state.is_authenticated = true;
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

        // Find any Z-state (zombie) children currently parented to us.
        fn has_zombie_children() -> bool {
            let me = std::process::id();
            let Ok(entries) = std::fs::read_dir("/proc") else {
                return false;
            };
            for entry in entries.flatten() {
                let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
                    continue;
                };
                if pid == me {
                    continue;
                }
                let stat = std::fs::read_to_string(entry.path().join("stat")).unwrap_or_default();
                // /proc/<pid>/stat: "pid (comm) state ..." — state is char 3.
                if let Some(state) = stat.split_whitespace().nth(2) {
                    if state.starts_with('Z') {
                        // Confirm it is actually our child via /proc/<pid>/status PPid.
                        let status = std::fs::read_to_string(entry.path().join("status"))
                            .unwrap_or_default();
                        for line in status.lines() {
                            if line.starts_with("PPid:") {
                                if line.split_whitespace().nth(1) == Some(&me.to_string()) {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
            false
        }

        // Precondition: a clean slate.
        assert!(
            !has_zombie_children(),
            "test harness started with stray zombies"
        );

        for _ in 0..8 {
            let cmd = Command::new("/bin/true");
            spawn_terminal_and_reap(cmd).expect("spawn must succeed");
        }

        // Give the reaping threads time to wait() the exited children.
        std::thread::sleep(std::time::Duration::from_millis(500));
        assert!(
            !has_zombie_children(),
            "fast-exiting children must be reaped, not left as zombies"
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
                // Order 363: McpFrame on the unix socket is now HANDLED, but
                // gated on the peer's TILLANDSIAS_PROJECT (SO_PEERCRED →
                // /proc/<pid>/environ). This test process has no project env,
                // so the deny must name the project gate — a caller that
                // cannot be attributed to a project gets refused, loudly.
                assert!(
                    message.contains("TILLANDSIAS_PROJECT"),
                    "McpFrame deny must name the project gate; got {message:?}"
                );
            }
            other => panic!("expected Error variant, got {other:?}"),
        }
    }

    /// Order 363: the MCP method surface a real client needs. `initialize`
    /// and `tools/list` answer without podman, the advertised tool family
    /// is exactly the publish trio, and notifications are absorbed without
    /// a reply (JSON-RPC 2.0). The project label is a function parameter —
    /// NOT process env — so this cannot race the project-gate test above.
    ///
    /// @trace spec:host-browser-mcp
    #[test]
    fn mcp_initialize_and_tools_list_advertise_publish_tool_family() {
        let init =
            serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}});
        let resp = handle_mcp_jsonrpc("demo", &init).expect("initialize replies");
        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 1);
        assert_eq!(
            resp["result"]["serverInfo"]["name"],
            "tillandsias-host-services"
        );

        let list = serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"});
        let resp = handle_mcp_jsonrpc("demo", &list).expect("tools/list replies");
        let tools: Vec<&str> = resp["result"]["tools"]
            .as_array()
            .expect("tools array")
            .iter()
            .map(|t| t["name"].as_str().expect("tool name"))
            .collect();
        assert_eq!(
            tools,
            vec!["publish_local", "service_status", "service_stop"]
        );

        let note = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
        assert!(
            handle_mcp_jsonrpc("demo", &note).is_none(),
            "notifications get no reply"
        );
    }

    /// Order 363 exit criterion: a non-WEB category is refused host-side
    /// with an actionable JSON-RPC error. The deny happens BEFORE any
    /// podman call — this test runs without podman.
    ///
    /// @trace spec:host-browser-mcp, spec:subdomain-routing-via-reverse-proxy
    #[test]
    fn mcp_tools_call_non_web_category_denied_loud() {
        let call = serde_json::json!({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "publish_local", "arguments": {"category": "DATABASE"}}
        });
        let resp = handle_mcp_jsonrpc("demo", &call).expect("deny replies");
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
        let resp = handle_mcp_jsonrpc("demo", &forged).expect("unknown tool replies");
        assert_eq!(resp["error"]["code"], -32601);
    }

    /// The NDJSON mcp.sock transport: a peer that cannot be attributed to
    /// a project gets ONE loud deny line naming the gate, then EOF. Same
    /// fail-closed contract as the envelope arm.
    ///
    /// @trace spec:host-browser-mcp
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
        assert!(
            deny["error"]["message"]
                .as_str()
                .unwrap_or("")
                .contains("TILLANDSIAS_PROJECT"),
            "deny must name the project gate; got {deny_line:?}"
        );
        assert!(lines.next().is_none(), "connection closes after the deny");
        server.join().expect("server thread joined");
    }

    /// The NDJSON transport round-trips the MCP handshake for an attributed
    /// peer — one JSON-RPC object per line, replies in order. This is the
    /// exact byte protocol the in-forge socat bridge
    /// (`config-overlay/mcp/host-browser.sh`) carries.
    ///
    /// @trace spec:host-browser-mcp
    #[test]
    fn mcp_ndjson_connection_round_trips_handshake() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixStream;

        let (server_side, client_side) =
            UnixStream::pair().expect("UnixStream::pair available on linux");
        let server =
            std::thread::spawn(move || serve_mcp_connection(server_side, Some("demo".to_string())));

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
        assert_eq!(resp["result"]["tools"].as_array().expect("tools").len(), 3);

        drop(writer);
        drop(lines);
        server.join().expect("server thread joined");
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
                enclave_status: self.enclave_status,
                revision: 1,
                projects_hash,
            }
        }
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn minimal_menu_has_5_top_level_items_when_unauthenticated() {
        // When `is_authenticated == false`, the top-level menu is exactly:
        //   1. Status (id=1)
        //   2. GitHubLogin (id=20)
        //   3. Separator (id=29)
        //   4. Version + attribution (id=30)
        //   5. Quit (id=31)
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
            label_list.iter().any(|l| l.contains("GitHubLogin")),
            "Missing GitHubLogin entry"
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

        // No ~/src / Cloud at this auth stage.
        assert!(!label_list.iter().any(|l| l.contains("~/src")));
        assert!(!label_list.iter().any(|l| l.contains("Cloud")));
    }

    // @trace spec:tray-minimal-ux
    #[test]
    fn menu_expands_when_authenticated() {
        // When `is_authenticated == true` the GitHubLogin row is replaced by
        // the `~/src` + `Cloud` pair, giving 6 top-level items.
        let state = TrayStateBuilder::new()
            .forge_available(true)
            .enclave_status(EnclaveStatus::AllHealthy)
            .authenticated(true)
            .build();
        let menu = build_menu(&state);

        let top_level = &menu.2;
        assert_eq!(
            top_level.len(),
            6,
            "Expected 6 top-level items when authenticated, got {}",
            top_level.len()
        );

        let label_list = labels(&menu);
        assert!(
            label_list.iter().any(|l| l.contains("~/src")),
            "Missing ~/src submenu. labels={:?}",
            label_list
        );
        assert!(
            label_list.iter().any(|l| l.contains("Cloud")),
            "Missing Cloud submenu"
        );
        assert!(
            !label_list.iter().any(|l| l.contains("GitHubLogin")),
            "GitHubLogin must not appear when authenticated"
        );
        // The default local project from `TrayStateBuilder` is "test-project".
        assert!(
            label_list.contains(&"test-project".to_string()),
            "Local project submenu missing when authenticated"
        );
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
        let label_list = labels(&cloud_node);
        let overflow_label = label_list
            .iter()
            .find(|l| l.contains("All cloud projects"))
            .expect("Overflow item with label 'All cloud projects (N)…' must be present");
        assert!(
            overflow_label.contains("50"),
            "Overflow label must include the total project count (50), got {:?}",
            overflow_label
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

        assert_eq!(
            result,
            (false, false),
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
        assert_eq!(after.2.len(), 6);

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
        assert_eq!(top_level.len(), 6, "Failure must preserve menu shape");

        let label_list = labels(&menu);
        // labels()[0] is the root menu container ("Tillandsias");
        // [1] is the Status row.
        let status_line = &label_list[1];
        assert!(
            status_line.contains("\u{274C}"),
            "Status must show the failure marker, got {:?}",
            status_line
        );
        assert!(label_list.iter().any(|l| l.contains("~/src")));
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
        let submenu = build_project_submenu(&state, &project, ProjectScope::Local);

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
        let submenu = build_project_submenu(&state, &project, ProjectScope::Local);

        let mut flat = Vec::new();
        flatten_layout(&submenu, &mut flat);
        for (id, props) in flat.iter() {
            // Skip the submenu container itself.
            if *id == local_project_base(&project.name) + PROJECT_SUBMENU_OFFSET {
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
        assert!(label_list.iter().any(|l| l.contains("GitHubLogin")));
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
        assert_eq!(menu.2.len(), 6, "Top-level must keep 6 rows on failure");

        let label_list = labels(&menu);
        // labels()[0] is the root menu container ("Tillandsias");
        // [1] is the Status row.
        assert!(
            label_list[1].contains("\u{274C}"),
            "Status row must show the failure marker, got {:?}",
            label_list[1]
        );
        assert!(label_list.iter().any(|l| l.contains("~/src")));
        assert!(label_list.iter().any(|l| l.contains("Cloud")));
        assert!(label_list.contains(&"project-beta".to_string()));
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
}
