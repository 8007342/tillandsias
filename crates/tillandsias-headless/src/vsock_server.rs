//! `--listen-vsock` mode: bind the control wire to a vsock listener instead
//! of the Linux Unix socket, so an in-VM tillandsias can serve the host-side
//! tray on Windows / macOS over virtio-vsock.
//!
//! Mirrors the Unix-socket handler in `tray::mod::handle_control_connection`:
//! reads the first frame as `Hello`, replies with `HelloAck`, then keeps the
//! connection open for VM-lifecycle / cloud-refresh request frames.
//!
//! Phase-2 scope is the handshake + a small request/reply set
//! (`VmStatusRequest`, `EnumerateLocalProjects`, `CloudRefreshRequest`,
//! `VmShutdownRequest`). Full menu-state propagation lands in Phase 3+.
//!
//! Linux-only, gated behind `feature = "listen-vsock"`.
//!
//! @trace spec:vsock-transport, spec:host-shell-architecture

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tillandsias_control_wire::transport::{
    AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Listener, Transport, bind,
};
use tillandsias_control_wire::{
    CAP_PTY_ATTACH_V1, CAP_PTY_HEARTBEAT_V1, CloudProjectEntry, ControlEnvelope, ControlMessage,
    ErrorCode, LocalProjectEntry, MAX_MESSAGE_BYTES, VmPhase, WIRE_VERSION, decode, encode,
};
use tillandsias_secure_channel::{HopId, channel_psk, server_handshake};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{broadcast, mpsc, watch};
use tracing::{debug, info, warn};

#[cfg(unix)]
use crate::pty_handler::PtySessionStore;

const SERVER_NAME: &str = "tillandsias-in-vm";

fn client_supports_pty_heartbeat(capabilities: &[String]) -> bool {
    capabilities
        .iter()
        .any(|capability| capability == CAP_PTY_HEARTBEAT_V1)
}

/// Guard so vault bootstrap runs at most once per process even if multiple
/// tray connections deliver credentials concurrently.
#[cfg(feature = "vault")]
static VAULT_BOOTSTRAP_DONE: AtomicBool = AtomicBool::new(false);

/// Env var that overrides the default in-VM project bind-mount root.
/// macOS hosts mount the user's `~/src` via virtio-fs into the Linux VM;
/// Windows hosts mount via `\\wsl$`. The convention is `/home/forge/src`
/// but operators can override with this env var.
///
/// @trace spec:host-shell-architecture
const IN_VM_PROJECT_ROOT_ENV: &str = "TILLANDSIAS_IN_VM_PROJECT_ROOT";
const IN_VM_PROJECT_ROOT_DEFAULT: &str = "/home/forge/src";

/// Default in-VM podman socket path. Used by `VmStateHandle::podman_ready`
/// to decide whether containers can actually start.
const IN_VM_PODMAN_SOCKET_DEFAULT: &str = "/run/podman/podman.sock";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SecureControlWireMode {
    Off,
    On,
}

fn parse_secure_control_wire_mode(
    raw: Result<String, std::env::VarError>,
) -> Result<SecureControlWireMode, String> {
    match raw {
        Ok(v) if v.eq_ignore_ascii_case("on") => Ok(SecureControlWireMode::On),
        Ok(v) if v.eq_ignore_ascii_case("off") || v.is_empty() => Ok(SecureControlWireMode::Off),
        Ok(v) => Err(format!(
            "TILLANDSIAS_SECURE_CONTROL_WIRE must be 'on' or 'off' (got {v:?})"
        )),
        Err(std::env::VarError::NotPresent) => Ok(SecureControlWireMode::Off),
        Err(err) => Err(format!("TILLANDSIAS_SECURE_CONTROL_WIRE: {err}")),
    }
}

fn secure_control_wire_mode() -> Result<SecureControlWireMode, String> {
    static MODE: OnceLock<Result<SecureControlWireMode, String>> = OnceLock::new();
    MODE.get_or_init(|| {
        parse_secure_control_wire_mode(std::env::var("TILLANDSIAS_SECURE_CONTROL_WIRE"))
    })
    .clone()
}

async fn maybe_secure_stream(
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>> {
    match secure_control_wire_mode().map_err(io::Error::other)? {
        SecureControlWireMode::Off => Ok(stream),
        SecureControlWireMode::On => {
            let psk = channel_psk(
                tillandsias_secure_channel::workspace_version(),
                WIRE_VERSION,
                HopId::HostGuest,
            );
            let secure = server_handshake(stream, &psk).await?;
            Ok(Box::new(secure))
        }
    }
}

/// Shared lifecycle state that the in-VM headless updates as it progresses
/// through provisioning → ready → drain. The vsock listener reads from this
/// on every `VmStatusRequest` so the host tray sees real state, not a stub.
///
/// Default is `Starting` — the headless binary has bound the listener but
/// podman is not yet reachable, so attaching project containers would fail.
/// `advance_to_ready_when_podman_up` polls the podman socket and flips to
/// `Ready` once the socket is reachable (or to `Failed` if it never is).
/// `Stopping` is set by the shutdown watcher when SIGTERM/SIGINT arrives;
/// `Draining` is set by the per-connection drain path.
///
/// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle, plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 6)
/// @trace plan/issues/vm-headless-persistent-listener-2026-07-06.md (order 153, slice 1)
#[derive(Debug, Clone)]
pub struct VmStateHandle {
    phase: Arc<RwLock<VmPhase>>,
    podman_socket: PathBuf,
    /// Broadcast fan-out for `VmStatusPush`: every subscribed connection gets
    /// its own receiver, so one slow/lagging client cannot block delivery to
    /// the others (order 153 SC-10). Bounded capacity (documented below) so a
    /// receiver that never polls just lags and drops old frames instead of
    /// growing memory unboundedly.
    vm_status_tx: broadcast::Sender<ControlMessage>,
    /// Broadcast fan-out for `LoginStatePush` (order 230). Same subscriber
    /// semantics as `vm_status_tx`.
    login_state_tx: broadcast::Sender<ControlMessage>,
    /// Last observed login state, `None` until first probed. Kept so
    /// `set_login_state` only pushes on a real transition — and so the very
    /// first observation after boot always pushes (order 230 exit criteria:
    /// no redundant push on unchanged state).
    login_state: LoginStateCell,
    /// Broadcast fan-out for `CloudProjectsPush` (order 231). Same
    /// subscriber semantics as `vm_status_tx`.
    cloud_projects_tx: broadcast::Sender<ControlMessage>,
    /// Last pushed project list, `None` until first fetched. Full-replacement
    /// compare: `set_cloud_projects` pushes only when the list differs.
    cloud_projects: Arc<RwLock<Option<Vec<CloudProjectEntry>>>>,
    /// Broadcast fan-out for `LocalProjectsPush` (order 260). Same
    /// subscriber semantics as `vm_status_tx`.
    local_projects_tx: broadcast::Sender<ControlMessage>,
    /// Last pushed VM-local project list, `None` until first scanned.
    /// Full-replacement compare (order 260): `set_local_projects` pushes
    /// only when the list differs.
    local_projects: Arc<RwLock<Option<Vec<LocalProjectEntry>>>>,
    /// Monotonic counter for the `seq` field carried inside each push
    /// message (distinct from the per-request `ControlEnvelope.seq`, which
    /// pushes don't have a request to reply to). Shared across all push
    /// topics so the host can totally order pushes from this headless.
    push_seq: Arc<std::sync::atomic::AtomicU64>,
    /// Last event message.
    last_event: Arc<RwLock<String>>,
}

/// Last observed login state shared between the handle clones: `None` until
/// first probed, then `(logged_in, handle)`.
type LoginStateCell = Arc<RwLock<Option<(bool, Option<String>)>>>;

/// Bounded capacity of the `VmStatusPush` broadcast channel. VmPhase changes
/// are infrequent (a handful over a VM's lifetime), so this only needs to
/// cover the gap between two pushes for the slowest realistic subscriber.
const VM_STATUS_PUSH_CAPACITY: usize = 16;
/// Bounded capacity of the `LoginStatePush` channel (order 230). Login
/// transitions are rarer than phase changes; the latest frame always carries
/// the full current state, so lagging only loses intermediate flips.
const LOGIN_STATE_PUSH_CAPACITY: usize = 16;
/// Bounded capacity of the `CloudProjectsPush` channel (order 231). Each
/// frame is a full-replacement list, so only the newest frame matters; a
/// small buffer bounds memory for the larger payload.
const CLOUD_PROJECTS_PUSH_CAPACITY: usize = 8;
/// Order 260: same shallow-queue rationale as CloudProjects — each push is a
/// full replacement list, so a lagged receiver skipping to latest loses
/// nothing durable.
const LOCAL_PROJECTS_PUSH_CAPACITY: usize = 8;
/// Per-connection PTY frames waiting for the wire writer. Backpressure at
/// this boundary pauses the PTY pump instead of allowing an unbounded queue to
/// consume guest memory when a host stops reading (order 153 bounded-channel
/// exit criterion).
const PTY_OUTBOUND_CAPACITY: usize = 64;

impl VmStateHandle {
    /// Construct with default `Starting` phase and the conventional podman
    /// socket path. Tests and lifecycle hooks may use [`set_phase`] /
    /// [`set_podman_socket`] to drive transitions.
    pub fn new() -> Self {
        let (vm_status_tx, _) = broadcast::channel(VM_STATUS_PUSH_CAPACITY);
        let (login_state_tx, _) = broadcast::channel(LOGIN_STATE_PUSH_CAPACITY);
        let (cloud_projects_tx, _) = broadcast::channel(CLOUD_PROJECTS_PUSH_CAPACITY);
        let (local_projects_tx, _) = broadcast::channel(LOCAL_PROJECTS_PUSH_CAPACITY);
        Self {
            phase: Arc::new(RwLock::new(VmPhase::Starting)),
            podman_socket: PathBuf::from(IN_VM_PODMAN_SOCKET_DEFAULT),
            vm_status_tx,
            login_state_tx,
            login_state: Arc::new(RwLock::new(None)),
            cloud_projects_tx,
            cloud_projects: Arc::new(RwLock::new(None)),
            local_projects_tx,
            local_projects: Arc::new(RwLock::new(None)),
            push_seq: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            last_event: Arc::new(RwLock::new(SERVER_NAME.to_string())),
        }
    }

    /// Subscribe to the `VmStatus` push topic. Each call returns an
    /// independent receiver (tokio broadcast semantics): a lagging
    /// subscriber only affects its own receiver, never other subscribers or
    /// the sender.
    pub fn subscribe_vm_status(&self) -> broadcast::Receiver<ControlMessage> {
        self.vm_status_tx.subscribe()
    }

    /// Subscribe to the `LoginState` push topic (order 230). Same
    /// independent-receiver semantics as [`subscribe_vm_status`].
    pub fn subscribe_login_state(&self) -> broadcast::Receiver<ControlMessage> {
        self.login_state_tx.subscribe()
    }

    /// Subscribe to the `CloudProjects` push topic (order 231). Same
    /// independent-receiver semantics as [`subscribe_vm_status`].
    pub fn subscribe_cloud_projects(&self) -> broadcast::Receiver<ControlMessage> {
        self.cloud_projects_tx.subscribe()
    }

    /// True when at least one connection is subscribed to `LoginState`.
    /// The periodic vault probe uses this to avoid spending a podman exec
    /// per interval when nobody is listening.
    pub fn has_login_state_subscribers(&self) -> bool {
        self.login_state_tx.receiver_count() > 0
    }

    /// Record a login-state observation and push `LoginStatePush` to all
    /// `LoginState` subscribers IFF the state actually changed. The first
    /// observation after boot always pushes (subscribers start with no
    /// baseline). Mirrors the [`set_phase`] change-only contract
    /// (order 230; no redundant push on unchanged state).
    ///
    /// Returns `true` when this observation TRANSITIONED the state into
    /// logged-in (previously logged-out or no baseline). Order 276:
    /// callers use the flip to trigger the auth-gated cloud-projects
    /// refresh exactly once per login instead of waiting for a
    /// CloudRefreshRequest that SC-07 suppresses on healthy push streams.
    pub fn set_login_state(&self, logged_in: bool, handle: Option<String>) -> bool {
        let (changed, flipped_in) = match self.login_state.write() {
            Ok(mut guard) => {
                let was_logged_in = guard.as_ref().map(|(l, _)| *l).unwrap_or(false);
                let next = Some((logged_in, handle.clone()));
                let changed = *guard != next;
                *guard = next;
                (changed, logged_in && !was_logged_in)
            }
            Err(_) => (false, false),
        };
        if changed {
            let seq = self
                .push_seq
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                + 1;
            let _ = self.login_state_tx.send(ControlMessage::LoginStatePush {
                seq,
                logged_in,
                handle,
            });
        }
        flipped_in
    }

    /// Order 276: apply a login-state observation AND, when it transitions
    /// into logged-in, refresh the auth-gated cloud project list through
    /// `fetch` and push it (change-gated in [`set_cloud_projects`]). This is
    /// the single funnel every login-state source uses — the periodic vault
    /// probe, the explicit `GithubLoginStatusRequest` handler, and the
    /// satisfier-completion sentinel — so subscribers converge on both
    /// topics without any inbound request. `fetch` is injectable so the
    /// contract is unit-testable without podman.
    pub async fn apply_login_transition<F>(&self, logged_in: bool, handle: Option<String>, fetch: F)
    where
        F: FnOnce() -> Vec<CloudProjectEntry> + Send + 'static,
    {
        let flipped_in = self.set_login_state(logged_in, handle);
        if flipped_in {
            let projects = tokio::task::spawn_blocking(fetch).await.unwrap_or_default();
            self.set_cloud_projects(projects);
        }
    }

    /// Subscribe to the `LocalProjects` push topic (order 260). Same
    /// independent-receiver semantics as [`subscribe_vm_status`].
    pub fn subscribe_local_projects(&self) -> broadcast::Receiver<ControlMessage> {
        self.local_projects_tx.subscribe()
    }

    /// True when at least one connection is subscribed to `LocalProjects`.
    /// The guest-side rescan task uses this to spend zero directory scans
    /// while nobody is listening (order 260; mirrors the login-probe gate).
    pub fn has_local_projects_subscribers(&self) -> bool {
        self.local_projects_tx.receiver_count() > 0
    }

    /// Record the latest VM-local project list and push `LocalProjectsPush`
    /// (full replacement) to all `LocalProjects` subscribers IFF the list
    /// differs from the previous one (order 260). The first scan always
    /// pushes.
    pub fn set_local_projects(&self, entries: Vec<LocalProjectEntry>) {
        let changed = match self.local_projects.write() {
            Ok(mut guard) => {
                let changed = guard.as_ref() != Some(&entries);
                if changed {
                    *guard = Some(entries.clone());
                }
                changed
            }
            Err(_) => false,
        };
        if changed {
            let seq = self
                .push_seq
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                + 1;
            let _ = self
                .local_projects_tx
                .send(ControlMessage::LocalProjectsPush { seq, entries });
        }
    }

    /// Record the latest cloud project list and push `CloudProjectsPush`
    /// (full replacement) to all `CloudProjects` subscribers IFF the list
    /// differs from the previous one (order 231). The first fetch always
    /// pushes.
    pub fn set_cloud_projects(&self, projects: Vec<CloudProjectEntry>) {
        let changed = match self.cloud_projects.write() {
            Ok(mut guard) => {
                let changed = guard.as_ref() != Some(&projects);
                if changed {
                    *guard = Some(projects.clone());
                }
                changed
            }
            Err(_) => false,
        };
        if changed {
            let seq = self
                .push_seq
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                + 1;
            let _ = self
                .cloud_projects_tx
                .send(ControlMessage::CloudProjectsPush { seq, projects });
        }
    }

    /// Update the reported phase. The vsock handler reads this on every
    /// `VmStatusRequest`. Safe to call from any task. Also pushes a
    /// `VmStatusPush` to every `VmStatus`-subscribed connection when the
    /// phase actually changes (order 153 SC-09) — a no-op write (same phase
    /// set twice) does not spam subscribers with redundant pushes.
    pub fn set_phase(&self, phase: VmPhase) {
        // Order 234 (R6): mirror every transition into the process-global
        // gate so free-function ensure/cleanup paths can refuse container
        // mutations during Draining/Stopping without threading this handle.
        // cfg(not(test)): unit tests drive set_phase(Draining/Stopping) in
        // parallel with unrelated tests that exercise ensure paths; a global
        // write here would leak refusals across test isolation boundaries
        // (observed: 4 remote_projects tests flaking). The production binary
        // always mirrors; litmus:drain-vs-self-heal audits this wiring.
        #[cfg(not(test))]
        crate::runtime_phase::set_runtime_phase(phase);
        let changed = match self.phase.write() {
            Ok(mut guard) => {
                let changed = *guard != phase;
                *guard = phase;
                changed
            }
            Err(_) => false,
        };
        if changed {
            let seq = self
                .push_seq
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                + 1;
            // No receivers is not an error — pushes are fire-and-forget to
            // whoever is currently subscribed.
            let _ = self.vm_status_tx.send(ControlMessage::VmStatusPush {
                seq,
                phase,
                podman_ready: self.podman_ready(),
                last_event: self.last_event(),
            });
        }
    }

    /// Update the last_event string and trigger a push to subscribers so the tray
    /// can surface the event text in the UI.
    pub fn set_last_event(&self, event: String) {
        let mut guard = self.last_event.write().unwrap();
        *guard = event.clone();
        drop(guard);

        let seq = self
            .push_seq
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            + 1;
        let _ = self.vm_status_tx.send(ControlMessage::VmStatusPush {
            seq,
            phase: self.current_phase(),
            podman_ready: self.podman_ready(),
            last_event: Some(event),
        });
    }

    /// Retrieve the current last_event string.
    pub fn last_event(&self) -> Option<String> {
        self.last_event.read().unwrap().clone().into()
    }

    /// Read the current phase. Falls back to `Failed` if the lock is
    /// poisoned (shouldn't happen but conservative).
    pub fn current_phase(&self) -> VmPhase {
        self.phase.read().map(|g| *g).unwrap_or(VmPhase::Failed)
    }

    /// Override the podman socket path; useful in tests or for VMs that
    /// publish podman elsewhere.
    #[allow(dead_code)]
    pub fn set_podman_socket(&mut self, path: PathBuf) {
        self.podman_socket = path;
    }

    /// Check whether podman is reachable. Cheap: just looks for the
    /// socket file. The host tray uses this to disable project-attach
    /// menu items until podman is actually up.
    pub fn podman_ready(&self) -> bool {
        self.podman_socket.exists()
    }

    /// Poll [`podman_ready`] on a fixed interval until either the socket
    /// appears (transition `Starting → Ready`) or `timeout` elapses
    /// (transition `Starting → Failed`). Intended to be `tokio::spawn`'d
    /// alongside [`run_vsock_listener`] when the in-VM headless first
    /// comes up.
    ///
    /// The check is purely filesystem-based; we do not connect to the
    /// socket here — `podman_ready` is the public contract and a probe
    /// connect would add a real-podman dependency to a unit-testable code
    /// path. Callers that need a stronger guarantee can flip Ready
    /// downstream after the first successful container operation.
    ///
    /// Already-`Ready` (or any non-`Starting` state set by a different
    /// path) is left alone — this method only advances `Starting`.
    ///
    /// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle
    pub async fn advance_to_ready_when_podman_up(
        &self,
        timeout: std::time::Duration,
        poll_interval: std::time::Duration,
    ) {
        let start = std::time::Instant::now();
        loop {
            // Bail out if a different transition (e.g. Stopping from the
            // shutdown watcher) raced us — we never demote a phase here.
            if self.current_phase() != VmPhase::Starting {
                return;
            }
            if self.podman_ready() {
                self.set_phase(VmPhase::Ready);
                return;
            }
            if start.elapsed() >= timeout {
                self.set_phase(VmPhase::Failed);
                return;
            }
            tokio::time::sleep(poll_interval).await;
        }
    }

    /// Watch `shutdown` for a flip to true and, when it does, transition
    /// the phase to `Stopping`. Idempotent and safe to spawn alongside
    /// the listener task: poll cadence is intentionally coarse (250 ms)
    /// since this only governs the lifecycle-reporting wire, not any
    /// hot-path behaviour.
    ///
    /// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle
    pub async fn watch_shutdown_and_mark_stopping(&self, shutdown: Arc<AtomicBool>) {
        while !shutdown.load(Ordering::SeqCst) {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
        // Don't clobber a terminal `Failed` if the advancer beat us to it.
        if self.current_phase() != VmPhase::Failed {
            self.set_phase(VmPhase::Stopping);
        }
    }
}

impl Default for VmStateHandle {
    fn default() -> Self {
        Self::new()
    }
}

/// Bind a vsock listener on `VMADDR_CID_ANY:port` and serve control-wire
/// connections until `shutdown` is set. `state` carries lifecycle phase +
/// podman readiness which the handler reads when answering
/// `VmStatusRequest`.
///
/// Returns once the listener loop exits (either an unrecoverable bind error
/// at startup or `shutdown` flipped to true).
///
/// @trace spec:vsock-transport
pub async fn run_vsock_listener(
    port: u32,
    shutdown: Arc<AtomicBool>,
    state: VmStateHandle,
) -> io::Result<()> {
    let transport = Transport::Vsock {
        cid: vmaddr_cid_any(),
        port,
    };
    let mut listener = bind(&transport).await?;
    info!(
        spec = "vsock-transport",
        port = port,
        "control wire listening on vsock"
    );
    serve_listener(&mut listener, shutdown, state).await;
    Ok(())
}

/// Default vsock port for the control wire. Re-exported for the CLI to use
/// without depending on `control-wire::transport` directly.
#[allow(dead_code)]
pub const DEFAULT_LISTEN_PORT: u32 = CONTROL_WIRE_VSOCK_PORT;

fn vmaddr_cid_any() -> u32 {
    // `VMADDR_CID_ANY` is `-1` cast to `u32` in the vsock crate's public API.
    // We don't re-import the crate here because tests should remain feature-gated.
    u32::MAX
}

async fn serve_listener(listener: &mut Listener, shutdown: Arc<AtomicBool>, state: VmStateHandle) {
    let (connection_shutdown_tx, connection_shutdown_rx) = watch::channel(false);
    loop {
        if shutdown.load(Ordering::SeqCst) {
            let _ = connection_shutdown_tx.send(true);
            info!(
                spec = "vsock-transport",
                "vsock listener exiting (shutdown signalled)"
            );
            return;
        }
        // accept() borrows listener mutably; race against a short timer so we
        // can re-check the shutdown flag without an extra wake mechanism.
        let accept = tokio::time::timeout(Duration::from_millis(250), listener.accept()).await;
        match accept {
            Ok(Ok(stream)) => {
                tokio::spawn(handle_connection(
                    stream,
                    state.clone(),
                    connection_shutdown_rx.clone(),
                ));
            }
            Ok(Err(err)) => {
                warn!(spec = "vsock-transport", error = %err, "vsock accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Err(_) => {
                // Timeout: loop and re-check shutdown.
            }
        }
    }
}

async fn handle_connection(
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    state: VmStateHandle,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut stream = match tokio::select! {
        result = maybe_secure_stream(stream) => result,
        _ = connection_shutdown(&mut shutdown) => return,
    } {
        Ok(secured) => {
            info!(
                spec = "vsock-transport",
                "secure control wire handshake succeeded (TILLANDSIAS_SECURE_CONTROL_WIRE=on)"
            );
            secured
        }
        Err(err) => {
            warn!(spec = "vsock-transport", error = %err, "secure control wire handshake failed");
            return;
        }
    };

    let first = match tokio::select! {
        result = read_envelope(&mut stream) => result,
        _ = connection_shutdown(&mut shutdown) => return,
    } {
        Ok(env) => env,
        Err(err) => {
            debug!(spec = "vsock-transport", error = %err, "vsock connection closed before Hello");
            return;
        }
    };

    if first.wire_version != WIRE_VERSION {
        warn!(
            spec = "vsock-transport",
            client_wire_version = first.wire_version,
            "rejecting vsock client with mismatched wire version"
        );
        return;
    }

    let (hello_from, client_capabilities) = match &first.body {
        ControlMessage::Hello {
            from,
            capabilities,
            build_version: _,
        } => (from.clone(), capabilities.clone()),
        other => {
            warn!(
                spec = "vsock-transport",
                first_frame = ?other,
                "first vsock frame was not Hello; closing"
            );
            return;
        }
    };
    debug!(spec = "vsock-transport", peer = %hello_from, "vsock client connected");

    let ack = ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: first.seq,
        body: ControlMessage::HelloAck {
            wire_version: WIRE_VERSION,
            server_caps: vec![
                "VmStatusRequest".into(),
                "EnumerateLocalProjects".into(),
                "CloudRefreshRequest".into(),
                "VmShutdownRequest".into(),
                "GithubLoginStatusRequest".into(),
                CAP_PTY_ATTACH_V1.into(),
                CAP_PTY_HEARTBEAT_V1.into(),
            ],
            build_version: Some(env!("CARGO_PKG_VERSION").to_string()),
        },
    };
    if let Err(err) = write_envelope_with_shutdown(&mut stream, &ack, &mut shutdown).await {
        warn!(spec = "vsock-transport", error = %err, "failed to write HelloAck");
        return;
    }

    // Per-connection PTY session store (l3: control-wire-pty-attach Tasks 4.x).
    // The pump tasks for each PTY session push envelopes into `pty_outbound`;
    // the main read loop interleaves those writes with normal request/reply
    // traffic via tokio::select!. When this function returns, dropping
    // `pty_store` cascades into `shutdown_all` so children are reaped on
    // disconnect.
    let (pty_tx, mut pty_rx) = mpsc::channel::<ControlEnvelope>(PTY_OUTBOUND_CAPACITY);
    #[cfg(unix)]
    let mut pty_store = if client_supports_pty_heartbeat(&client_capabilities) {
        PtySessionStore::new_with_heartbeat(pty_tx.clone())
    } else {
        PtySessionStore::new(pty_tx.clone())
    };
    // Hold a tx clone so the sender side stays open for the lifetime of
    // the connection even if `pty_store` empties (which would otherwise
    // close pty_rx).
    let _pty_tx_keepalive = pty_tx;

    // Order 153 slice 1: set once `Subscribe{VmStatus}` arrives. `None` means
    // not subscribed — the branch below is disabled entirely (never polled)
    // via the `if` guard, so an unsubscribed connection pays zero cost.
    let mut vm_status_rx: Option<broadcast::Receiver<ControlMessage>> = None;
    // Orders 230/231: LoginState + CloudProjects topics, same
    // subscribe-gated zero-cost-when-unsubscribed contract as VmStatus.
    let mut login_state_rx: Option<broadcast::Receiver<ControlMessage>> = None;
    let mut cloud_projects_rx: Option<broadcast::Receiver<ControlMessage>> = None;
    // Order 260: LocalProjects topic, same contract.
    let mut local_projects_rx: Option<broadcast::Receiver<ControlMessage>> = None;

    'connection: loop {
        tokio::select! {
            _ = connection_shutdown(&mut shutdown) => {
                break 'connection;
            }
            // Outbound PTY frame (PtyData{ToHost} from a pump or PtyClose
            // from child reap).
            Some(env) = pty_rx.recv() => {
                if write_envelope_with_shutdown(&mut stream, &env, &mut shutdown).await.is_err() {
                    debug!(spec = "vsock-transport", "vsock write failed during PTY outbound; closing connection");
                    break 'connection;
                }
                continue;
            }
            // Server-push: VmStatusPush, once subscribed. Lagged receivers
            // (a slow client that fell behind the broadcast buffer) skip the
            // missed frames and keep going rather than disconnecting — the
            // next push still carries the current phase, so no state is
            // permanently lost, just intermediate transitions (order 153
            // SC-10: a slow client never blocks or drops a fast one, since
            // each subscriber has its own independent broadcast receiver).
            push = async {
                loop {
                    match vm_status_rx.as_mut()?.recv().await {
                        Ok(msg) => return Some(msg),
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!(spec = "vsock-transport", skipped, "VmStatus push receiver lagged; skipping to latest");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => return None,
                    }
                }
            }, if vm_status_rx.is_some() => {
                match push {
                    Some(body) => {
                        let env = ControlEnvelope { wire_version: WIRE_VERSION, seq: 0, body };
                        if write_envelope_with_shutdown(&mut stream, &env, &mut shutdown).await.is_err() {
                            debug!(spec = "vsock-transport", "vsock write failed during VmStatusPush; closing connection");
                            break 'connection;
                        }
                    }
                    None => {
                        // Sender dropped (should not happen — VmStateHandle
                        // outlives connections) — stop polling this branch.
                        vm_status_rx = None;
                    }
                }
                continue;
            }
            // Server-push: LoginStatePush (order 230). Same lag-skip contract
            // as the VmStatus branch above.
            push = async {
                loop {
                    match login_state_rx.as_mut()?.recv().await {
                        Ok(msg) => return Some(msg),
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!(spec = "vsock-transport", skipped, "LoginState push receiver lagged; skipping to latest");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => return None,
                    }
                }
            }, if login_state_rx.is_some() => {
                match push {
                    Some(body) => {
                        let env = ControlEnvelope { wire_version: WIRE_VERSION, seq: 0, body };
                        if write_envelope_with_shutdown(&mut stream, &env, &mut shutdown).await.is_err() {
                            debug!(spec = "vsock-transport", "vsock write failed during LoginStatePush; closing connection");
                            break 'connection;
                        }
                    }
                    None => {
                        login_state_rx = None;
                    }
                }
                continue;
            }
            // Server-push: CloudProjectsPush (order 231). Same lag-skip
            // contract; each frame is a full replacement so skipping to the
            // latest loses nothing durable.
            push = async {
                loop {
                    match cloud_projects_rx.as_mut()?.recv().await {
                        Ok(msg) => return Some(msg),
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!(spec = "vsock-transport", skipped, "CloudProjects push receiver lagged; skipping to latest");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => return None,
                    }
                }
            }, if cloud_projects_rx.is_some() => {
                match push {
                    Some(body) => {
                        let env = ControlEnvelope { wire_version: WIRE_VERSION, seq: 0, body };
                        if write_envelope_with_shutdown(&mut stream, &env, &mut shutdown).await.is_err() {
                            debug!(spec = "vsock-transport", "vsock write failed during CloudProjectsPush; closing connection");
                            break 'connection;
                        }
                    }
                    None => {
                        cloud_projects_rx = None;
                    }
                }
                continue;
            }
            // Server-push: LocalProjectsPush (order 260). Same lag-skip
            // contract; each frame is a full replacement so skipping to the
            // latest loses nothing durable.
            push = async {
                loop {
                    match local_projects_rx.as_mut()?.recv().await {
                        Ok(msg) => return Some(msg),
                        Err(broadcast::error::RecvError::Lagged(skipped)) => {
                            warn!(spec = "vsock-transport", skipped, "LocalProjects push receiver lagged; skipping to latest");
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => return None,
                    }
                }
            }, if local_projects_rx.is_some() => {
                match push {
                    Some(body) => {
                        let env = ControlEnvelope { wire_version: WIRE_VERSION, seq: 0, body };
                        if write_envelope_with_shutdown(&mut stream, &env, &mut shutdown).await.is_err() {
                            debug!(spec = "vsock-transport", "vsock write failed during LocalProjectsPush; closing connection");
                            break 'connection;
                        }
                    }
                    None => {
                        local_projects_rx = None;
                    }
                }
                continue;
            }
            // Inbound frame.
            result = read_envelope(&mut stream) => {
                let env = match result {
                    Ok(env) => env,
                    Err(err) => {
                        debug!(spec = "vsock-transport", error = %err, "vsock connection closed");
                        break 'connection;
                    }
                };

                // Convergence packet item 3: consult `control_dispatch::
                // decide_route` for the routing decision. The matrix lives
                // in the canonical module so unix + vsock can never
                // silently disagree. Unsupported / ResponseOnly arms write
                // a precise Error and continue the loop; the existing
                // variant-match below handles the Handle case.
                //
                // @trace plan/issues/control-socket-protocol-convergence-2026-05-25.md
                //   (item 3 of 3)
                let routing = crate::control_dispatch::decide_route(
                    &env.body,
                    crate::control_dispatch::TransportKind::Vsock,
                );
                match routing {
                    crate::control_dispatch::DispatchOutcome::Unsupported => {
                        debug!(
                            spec = "vsock-transport",
                            kind = env.body.kind(),
                            "rejecting vsock frame: matrix says Unsupported"
                        );
                        let err = ControlEnvelope {
                            wire_version: WIRE_VERSION,
                            seq: env.seq,
                            body: ControlMessage::Error {
                                seq_in_reply_to: Some(env.seq),
                                code: ErrorCode::Unsupported,
                                message: format!(
                                    "variant {} not supported on the in-VM vsock transport",
                                    env.body.kind()
                                ),
                            },
                        };
                        if write_envelope_with_shutdown(&mut stream, &err, &mut shutdown).await.is_err() {
                            break 'connection;
                        }
                        continue;
                    }
                    crate::control_dispatch::DispatchOutcome::ResponseOnly => {
                        debug!(
                            spec = "vsock-transport",
                            kind = env.body.kind(),
                            "rejecting vsock frame: matrix says ResponseOnly (server-only)"
                        );
                        let err = ControlEnvelope {
                            wire_version: WIRE_VERSION,
                            seq: env.seq,
                            body: ControlMessage::Error {
                                seq_in_reply_to: Some(env.seq),
                                code: ErrorCode::Unsupported,
                                message: format!(
                                    "variant {} is a response-shape frame and cannot open a connection",
                                    env.body.kind()
                                ),
                            },
                        };
                        if write_envelope_with_shutdown(&mut stream, &err, &mut shutdown).await.is_err() {
                            break 'connection;
                        }
                        continue;
                    }
                    crate::control_dispatch::DispatchOutcome::Handle => {
                        // Fall through to the variant-match below.
                    }
                }

                match env.body {
            ControlMessage::VmStatusRequest { seq } => {
                // l4: read real lifecycle phase + check podman socket.
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::VmStatusReply {
                        seq_in_reply_to: seq,
                        phase: state.current_phase(),
                        podman_ready: state.podman_ready(),
                        last_event: state.last_event(),
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            // Order 153 slice 1 wired VmStatus; orders 230/231 wire the
            // LoginState and CloudProjects topics to their broadcast
            // sources (vault probe task + cloud refresh handler below).
            ControlMessage::Subscribe { topics } => {
                if topics.contains(&tillandsias_control_wire::SubscriptionTopic::VmStatus) {
                    vm_status_rx = Some(state.subscribe_vm_status());
                }
                if topics.contains(&tillandsias_control_wire::SubscriptionTopic::LoginState) {
                    login_state_rx = Some(state.subscribe_login_state());
                }
                if topics.contains(&tillandsias_control_wire::SubscriptionTopic::CloudProjects) {
                    cloud_projects_rx = Some(state.subscribe_cloud_projects());
                }
                if topics.contains(&tillandsias_control_wire::SubscriptionTopic::LocalProjects) {
                    local_projects_rx = Some(state.subscribe_local_projects());
                }
                let ack = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::SubscribeAck,
                };
                if write_envelope_with_shutdown(&mut stream, &ack, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::EnumerateLocalProjects { seq } => {
                // l4: scan the bind-mount root for real project entries.
                let entries = enumerate_local_projects();
                // Order 260: an explicit enumeration is also a push source —
                // fan the (possibly changed) list out to every LocalProjects
                // subscriber on OTHER connections (change-gated inside),
                // mirroring the order-231 CloudRefreshRequest contract.
                state.set_local_projects(entries.clone());
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::LocalProjectsReply {
                        seq_in_reply_to: seq,
                        entries,
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::CloudRefreshRequest { seq } => {
                // Real in-VM implementation: invoke `gh repo list --json
                // nameWithOwner,defaultBranchRef` with the mounted GitHub
                // token, parse into CloudProjectEntry. Degrades to an empty
                // list (preserving the prior stub behaviour) when gh or the
                // token are absent or the call fails, so the host tray still
                // gets a well-formed reply offline / pre-login.
                //
                // @trace spec:host-shell-architecture, spec:tillandsias-vault,
                //        plan/issues/control-socket-protocol-convergence-2026-05-25.md (Q4)
                let projects = tokio::task::spawn_blocking(fetch_cloud_projects)
                    .await
                    .unwrap_or_default();
                // Order 231: an explicit refresh is also a push source — fan
                // the (possibly changed) list out to every CloudProjects
                // subscriber on OTHER connections. The requester gets the
                // reply below either way; set_cloud_projects only pushes on
                // a real change.
                state.set_cloud_projects(projects.clone());
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::CloudRefreshReply {
                        seq_in_reply_to: seq,
                        projects,
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::GithubLoginStatusRequest { seq } => {
                // Probe GitHub auth end-to-end inside a container — no raw
                // token is read into the vsock server process.
                let handle = tokio::task::spawn_blocking(|| {
                    crate::remote_projects::probe_github_username(false)
                })
                .await
                .unwrap_or(None);
                let logged_in = handle.is_some();
                // Order 230: every explicit probe doubles as a push source so
                // LoginState subscribers on other connections converge without
                // waiting for the periodic vault probe. Change-gated inside.
                // Order 276: a logged-in flip also refreshes + pushes the
                // auth-gated cloud list through the shared transition funnel.
                state
                    .apply_login_transition(logged_in, handle.clone(), fetch_cloud_projects)
                    .await;
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::GithubLoginStatusReply {
                        seq_in_reply_to: seq,
                        logged_in,
                        handle,
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::VmShutdownRequest { .. } => {
                // l4: flip phase to Draining so any subsequent VmStatusRequest
                // observers (e.g. the host tray polling on a different
                // connection) see the right state.
                state.set_phase(VmPhase::Draining);
                info!(
                    spec = "vsock-transport",
                    "VmShutdownRequest received; phase=Draining; closing connection (drain happens via signal path)"
                );
                break 'connection;
            }
            // l3: PTY-attach variants (control-wire-pty-attach Tasks 4.x).
            // The handler module owns the PtySessionStore lifecycle; this
            // dispatch just routes inbound envelopes by variant + session
            // id. Outbound PtyData{ToHost} and child-exit PtyClose travel
            // through `pty_rx` per the select! arm above.
            #[cfg(unix)]
            ControlMessage::PtyOpen {
                session_id,
                rows,
                cols,
                argv,
                env: pty_env,
                cwd,
            } => {
                if let Err(err) = pty_store
                    .open(session_id, rows, cols, argv, pty_env, cwd)
                    .await
                {
                    let err_env = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: env.seq,
                        body: ControlMessage::Error {
                            seq_in_reply_to: Some(env.seq),
                            code: ErrorCode::Internal,
                            message: format!("PtyOpen rejected: {err}"),
                        },
                    };
                    if write_envelope_with_shutdown(&mut stream, &err_env, &mut shutdown).await.is_err() {
                        break 'connection;
                    }
                }
            }
            #[cfg(unix)]
            ControlMessage::PtyData {
                session_id,
                direction: tillandsias_control_wire::PtyDirection::ToGuest,
                bytes,
            } => {
                pty_store.write_to_guest(session_id, &bytes).await;
            }
            #[cfg(unix)]
            ControlMessage::PtyData {
                direction: tillandsias_control_wire::PtyDirection::ToHost,
                ..
            } => {
                // ToHost direction is server → host only; receiving one
                // inbound is a protocol violation, but we don't need to
                // tear down — just ignore.
                debug!(
                    spec = "vsock-transport",
                    "inbound PtyData{{ToHost}} ignored (server-only direction)"
                );
            }
            #[cfg(unix)]
            ControlMessage::PtyResize {
                session_id,
                rows,
                cols,
            } => {
                pty_store.resize(session_id, rows, cols);
            }
            #[cfg(unix)]
            ControlMessage::PtyClose { session_id, .. } => {
                // Host-initiated close: SIGTERM + 2s grace + SIGKILL.
                // The terminal PtyClose envelope back to the host is
                // emitted by the pump task on child exit.
                pty_store.close_host_initiated(session_id).await;
            }
            ControlMessage::DeliverCredentials {
                seq,
                unseal_share_b64,
                installation_uuid,
                root_token,
            } => {
                crate::vault_bootstrap::set_in_vm_credentials(
                    unseal_share_b64,
                    installation_uuid,
                    root_token,
                );
                #[cfg(feature = "vault")]
                if VAULT_BOOTSTRAP_DONE
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_ok()
                {
                    tokio::task::spawn_blocking(|| {
                        if let Err(e) = crate::vault_bootstrap::ensure_vault_running(false) {
                            eprintln!("[vsock] vault bootstrap after DeliverCredentials failed: {e}");
                        }
                    });
                }
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::DeliverCredentialsReply {
                        seq_in_reply_to: seq,
                        success: true,
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::GetVaultHandover { seq } => {
                // Poll up to ~8s for the handover to arrive. On first boot, the tray
                // may call GetVaultHandover slightly before vault operator init has
                // completed and written the handover to PENDING_HANDOVER. Returning None
                // immediately would cause the tray to skip saving the Shamir key to the
                // keychain, leaving subsequent boots unable to unseal (HTTP 400).
                let (unseal_share_b64, root_token) = {
                    let mut result = crate::vault_bootstrap::get_pending_handover();
                    if result.0.is_none() {
                        for _ in 0..8u8 {
                            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                            result = crate::vault_bootstrap::get_pending_handover();
                            if result.0.is_some() {
                                break;
                            }
                        }
                    }
                    result
                };
                crate::vault_bootstrap::clear_pending_handover();

                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::VaultHandoverReply {
                        seq_in_reply_to: seq,
                        unseal_share_b64,
                        root_token,
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            // Convergence-packet pre-filter caught Unsupported and
            // ResponseOnly above; reaching this arm means the matrix
            // says Handle but no handler exists yet. Surface the gap
            // with a descriptive Error so the missing-handler case is
            // visibly distinct from a wire-format rejection.
            other => {
                debug!(
                    spec = "vsock-transport",
                    kind = other.kind(),
                    "matrix says Handle but no handler implemented yet"
                );
                let err = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::Error {
                        seq_in_reply_to: Some(env.seq),
                        code: ErrorCode::Unsupported,
                        message: format!(
                            "variant {} is on the vsock matrix but the handler is not implemented yet \
                             (see plan/issues/control-socket-protocol-convergence-2026-05-25.md item 3)",
                            other.kind()
                        ),
                    },
                };
                if write_envelope_with_shutdown(&mut stream, &err, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
                }
            }
        }
    }

    // Every exit after the per-connection PTY store exists converges here.
    // This prevents shutdown/write failures from detaching pump tasks and
    // leaving their child processes alive.
    #[cfg(unix)]
    pty_store.shutdown_all().await;
}

async fn read_envelope<R>(stream: &mut R) -> io::Result<ControlEnvelope>
where
    R: AsyncReadExt + Unpin,
{
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "control frame too large",
        ));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    decode(&payload).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

async fn write_envelope<W>(stream: &mut W, env: &ControlEnvelope) -> io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    let bytes = encode(env).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}

async fn connection_shutdown(shutdown: &mut watch::Receiver<bool>) {
    if *shutdown.borrow() {
        return;
    }
    loop {
        if shutdown.changed().await.is_err() || *shutdown.borrow() {
            return;
        }
    }
}

async fn write_envelope_with_shutdown<W>(
    stream: &mut W,
    env: &ControlEnvelope,
    shutdown: &mut watch::Receiver<bool>,
) -> io::Result<()>
where
    W: AsyncWriteExt + Unpin,
{
    tokio::select! {
        result = write_envelope(stream, env) => result,
        _ = connection_shutdown(shutdown) => Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "connection shutdown requested",
        )),
    }
}

/// Resolve the in-VM project bind-mount root from the environment.
fn in_vm_project_root() -> PathBuf {
    PathBuf::from(
        std::env::var(IN_VM_PROJECT_ROOT_ENV)
            .unwrap_or_else(|_| IN_VM_PROJECT_ROOT_DEFAULT.to_string()),
    )
}

/// Enumerate the in-VM project bind-mount root. Thin wrapper around
/// the shared `crate::local_projects::scan_project_root` so both the
/// vsock (in-VM) and unix (Linux native) dispatchers run the same
/// directory-walk + sort + mtime logic on different roots.
///
/// @trace spec:host-shell-architecture, plan/issues/multi-host-integration-loop-2026-05-24.md l4
pub(crate) fn enumerate_local_projects() -> Vec<LocalProjectEntry> {
    let root = in_vm_project_root();
    enumerate_local_projects_at(&root)
}

fn enumerate_local_projects_at(root: &Path) -> Vec<LocalProjectEntry> {
    let out = crate::local_projects::scan_project_root(root);
    if out.is_empty() {
        debug!(
            spec = "host-shell-architecture",
            root = %root.display(),
            "EnumerateLocalProjects (in-VM): project root unreadable or empty; returning empty list"
        );
    }
    out
}

/// Fetch the user's cloud (GitHub) projects from inside the VM.
///
/// Uses the same containerized `gh api user/repos` path as `--list-cloud-projects`:
/// `vault-cli read -field=token secret/github/token | gh auth login ...` runs inside
/// the git image so neither the raw token nor `gh` is needed in the VM rootfs.
/// Results are cached with a 5-minute TTL via the remote_projects cache.
///
/// Converts `GitHubProject` → `CloudProjectEntry`; `default_branch` is left empty
/// because the wire field is not used by the host tray menu renderer.
///
/// @trace spec:host-shell-architecture, spec:tillandsias-vault
/// Order 276: cross-process completion signal from the login satisfier.
/// `--github-login` runs as its own headless invocation, so it cannot call
/// the resident server's transition funnel in-process; instead it touches
/// this sentinel after a successful token store, and the server's probe
/// loop stats it every 2s (cheap) and runs the full transition — killing
/// the up-to-60s presence-poll lag the operator hit in the 2026-07-10
/// attended smoke (F-D). A stale sentinel is harmless: the probe re-derives
/// truth and every push is change-gated.
pub(crate) fn login_transition_sentinel_path() -> std::path::PathBuf {
    let run_dir = std::path::Path::new("/run/tillandsias");
    if run_dir.is_dir() || std::fs::create_dir_all(run_dir).is_ok() {
        return run_dir.join("login-transition");
    }
    std::env::temp_dir().join("tillandsias-login-transition")
}

pub(crate) fn fetch_cloud_projects() -> Vec<CloudProjectEntry> {
    match crate::remote_projects::discover_github_projects_result_with_debug(false) {
        Ok(projects) => projects
            .into_iter()
            .map(|p| CloudProjectEntry {
                label: format!("{}/{}", p.owner, p.name),
                owner: p.owner,
                repo: p.name,
                default_branch: String::new(),
            })
            .collect(),
        Err(e) => {
            debug!(
                spec = "host-shell-architecture",
                error = %e,
                "CloudRefreshRequest (in-VM): containerized gh fetch failed; returning empty cloud list"
            );
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pty_heartbeat_requires_explicit_client_capability() {
        assert!(!client_supports_pty_heartbeat(&[]));
        assert!(!client_supports_pty_heartbeat(&[CAP_PTY_ATTACH_V1.into()]));
        assert!(client_supports_pty_heartbeat(&[
            CAP_PTY_ATTACH_V1.into(),
            CAP_PTY_HEARTBEAT_V1.into(),
        ]));
    }

    // (parse_gh_repo_list tests moved to crate::cloud_projects with the
    // function itself. The vsock-side fetch_cloud_projects wrapper is
    // now a thin token-read shim, not worth a separate token-read target.)

    /// The secure-control-wire gate must DEFAULT OFF (absent/empty/"off" =
    /// plaintext, so the flip is opt-in and off is a no-op) and must FAIL CLOSED
    /// on any unrecognized value — an unknown flag is an error, never a silent
    /// downgrade to plaintext. @trace plan/issues/secure-channel-maturity-ladder-2026-07-04.md
    #[test]
    fn secure_control_wire_flag_defaults_off_and_fails_closed() {
        use std::env::VarError;
        // default OFF paths (no behaviour change when the flag is unset/off/empty)
        assert_eq!(
            parse_secure_control_wire_mode(Err(VarError::NotPresent)).unwrap(),
            SecureControlWireMode::Off
        );
        assert_eq!(
            parse_secure_control_wire_mode(Ok("off".to_string())).unwrap(),
            SecureControlWireMode::Off
        );
        assert_eq!(
            parse_secure_control_wire_mode(Ok(String::new())).unwrap(),
            SecureControlWireMode::Off
        );
        // explicit ON (case-insensitive)
        assert_eq!(
            parse_secure_control_wire_mode(Ok("on".to_string())).unwrap(),
            SecureControlWireMode::On
        );
        assert_eq!(
            parse_secure_control_wire_mode(Ok("ON".to_string())).unwrap(),
            SecureControlWireMode::On
        );
        // FAIL CLOSED: garbage is an error, NOT a silent fallback to Off/plaintext
        assert!(parse_secure_control_wire_mode(Ok("yes".to_string())).is_err());
        assert!(parse_secure_control_wire_mode(Ok("1".to_string())).is_err());
        assert!(parse_secure_control_wire_mode(Ok("true".to_string())).is_err());
    }

    /// Default is `Starting` (gap-6 contract). The vsock listener can
    /// answer VmStatusRequest the moment it binds, but the in-VM
    /// headless must NOT advertise `Ready` until podman is reachable —
    /// otherwise the host tray would offer project-attach menu items
    /// against a podman socket that doesn't exist yet.
    #[test]
    fn vm_state_handle_defaults_to_starting() {
        let state = VmStateHandle::new();
        assert_eq!(state.current_phase(), VmPhase::Starting);
    }

    #[test]
    fn vm_state_handle_phase_is_settable() {
        let state = VmStateHandle::new();
        state.set_phase(VmPhase::Draining);
        assert_eq!(state.current_phase(), VmPhase::Draining);
    }

    #[test]
    fn vm_state_handle_clone_shares_phase() {
        // The listener spawns one connection handler per accept, cloning
        // the handle. All clones must observe the same phase updates.
        let a = VmStateHandle::new();
        let b = a.clone();
        a.set_phase(VmPhase::Stopping);
        assert_eq!(b.current_phase(), VmPhase::Stopping);
    }

    /// Order 153 slice 1 SC-09: a real phase change pushes a VmStatusPush
    /// to a subscribed receiver.
    #[tokio::test]
    async fn set_phase_pushes_vm_status_on_change() {
        let state = VmStateHandle::new();
        let mut rx = state.subscribe_vm_status();
        state.set_phase(VmPhase::Ready);
        let msg = rx.try_recv().expect("push should be immediately available");
        match msg {
            ControlMessage::VmStatusPush { phase, .. } => assert_eq!(phase, VmPhase::Ready),
            other => panic!("expected VmStatusPush, got {other:?}"),
        }
    }

    /// Setting the SAME phase twice must not spam subscribers with a
    /// redundant push — only a real transition is push-worthy.
    #[tokio::test]
    async fn set_phase_does_not_push_when_unchanged() {
        let state = VmStateHandle::new();
        state.set_phase(VmPhase::Ready);
        let mut rx = state.subscribe_vm_status();
        state.set_phase(VmPhase::Ready); // no-op: already Ready
        assert!(matches!(
            rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
    }

    /// Order 153 SC-10: multiple subscribers each get their own
    /// independent stream of pushes — one is not starved by another.
    #[tokio::test]
    async fn multiple_subscribers_each_receive_pushes() {
        let state = VmStateHandle::new();
        let mut rx_a = state.subscribe_vm_status();
        let mut rx_b = state.subscribe_vm_status();
        state.set_phase(VmPhase::Ready);
        assert!(rx_a.try_recv().is_ok());
        assert!(rx_b.try_recv().is_ok());
    }

    /// A subscriber that never polls falls behind the bounded broadcast
    /// buffer and gets `Lagged`, not a hang or a panic — the connection
    /// loop's `RecvError::Lagged` arm (see `handle_connection`'s select!)
    /// is what turns this into "skip to latest" instead of dropping the
    /// client.
    #[tokio::test]
    async fn slow_subscriber_lags_instead_of_blocking() {
        let state = VmStateHandle::new();
        let mut rx = state.subscribe_vm_status();
        // Overflow the bounded channel capacity without ever calling recv().
        for _ in 0..(VM_STATUS_PUSH_CAPACITY + 2) {
            state.set_phase(VmPhase::Starting);
            state.set_phase(VmPhase::Ready);
        }
        match rx.try_recv() {
            Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            other => panic!("expected Lagged, got {other:?}"),
        }
    }

    async fn subscribed_vm_status_test_client(
        state: &VmStateHandle,
        socket_capacity: usize,
        from: &str,
    ) -> (
        tokio::io::DuplexStream,
        tokio::task::JoinHandle<()>,
        watch::Sender<bool>,
    ) {
        let (mut client, server) = tokio::io::duplex(socket_capacity);
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let server_task = tokio::spawn(handle_connection(
            Box::new(server),
            state.clone(),
            shutdown_rx,
        ));

        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::Hello {
                    from: from.to_string(),
                    capabilities: Vec::new(),
                    build_version: None,
                },
            },
        )
        .await
        .expect("test client writes Hello");
        assert!(matches!(
            read_envelope(&mut client).await.expect("HelloAck"),
            ControlEnvelope {
                body: ControlMessage::HelloAck { .. },
                ..
            }
        ));

        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::Subscribe {
                    topics: vec![tillandsias_control_wire::SubscriptionTopic::VmStatus],
                },
            },
        )
        .await
        .expect("test client writes Subscribe");
        assert!(matches!(
            read_envelope(&mut client).await.expect("SubscribeAck"),
            ControlEnvelope {
                body: ControlMessage::SubscribeAck,
                ..
            }
        ));

        (client, server_task, shutdown_tx)
    }

    /// Order 153 shutdown criterion: a live subscribed connection must not
    /// outlive listener shutdown merely because its peer keeps the socket
    /// open and sends no more frames.
    #[tokio::test]
    async fn subscribed_connection_exits_on_shutdown_signal() {
        let state = VmStateHandle::new();
        let (_client, server_task, shutdown) = tokio::time::timeout(
            Duration::from_secs(2),
            subscribed_vm_status_test_client(&state, 4096, "shutdown-client"),
        )
        .await
        .expect("client handshake and subscription must not hang");

        shutdown.send(true).expect("connection observes shutdown");
        tokio::time::timeout(Duration::from_millis(500), server_task)
            .await
            .expect("connection handler must exit after shutdown")
            .expect("connection handler must not panic");
    }

    #[test]
    fn post_store_connection_exits_share_pty_cleanup() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/vsock_server.rs"));
        let post_store = source
            .split("let (pty_tx, mut pty_rx)")
            .nth(1)
            .and_then(|tail| tail.split("\nasync fn read_envelope").next())
            .expect("post-store handle_connection source");
        assert!(
            !post_store.contains("return;"),
            "post-store connection exits must break to shared PTY cleanup"
        );
        assert_eq!(
            post_store
                .matches("pty_store.shutdown_all().await;")
                .count(),
            1,
            "handle_connection must have exactly one post-store PTY cleanup funnel"
        );
    }

    /// Order 153 SC-10 timed criterion at the real connection-handler
    /// boundary. A subscribed wire client stops reading for 1000ms and its
    /// one-byte duplex buffer blocks `write_envelope`; a second handler must
    /// still deliver every frame in an over-capacity burst within SC-09's
    /// 500ms bound.
    #[tokio::test]
    async fn slow_client_1000ms_lag_does_not_delay_fast_client() {
        let state = VmStateHandle::new();
        let (mut slow_client, slow_server, _slow_shutdown) = tokio::time::timeout(
            Duration::from_secs(2),
            subscribed_vm_status_test_client(&state, 1, "slow-client"),
        )
        .await
        .expect("slow client handshake and subscription must not hang");
        let (mut fast_client, fast_server, _fast_shutdown) = tokio::time::timeout(
            Duration::from_secs(2),
            subscribed_vm_status_test_client(&state, 4096, "fast-client"),
        )
        .await
        .expect("fast client handshake and subscription must not hang");

        let (slow_started_tx, slow_started_rx) = tokio::sync::oneshot::channel();
        let slow_reader = tokio::spawn(async move {
            let _ = slow_started_tx.send(());
            tokio::time::sleep(Duration::from_millis(1000)).await;
            read_envelope(&mut slow_client)
                .await
                .expect("slow wire client eventually receives a push")
        });

        let burst_len = VM_STATUS_PUSH_CAPACITY + 4;
        let (fast_started_tx, fast_started_rx) = tokio::sync::oneshot::channel();
        let fast_reader = tokio::spawn(async move {
            let _ = fast_started_tx.send(());
            let mut sequences = Vec::with_capacity(burst_len);
            for _ in 0..burst_len {
                let envelope = read_envelope(&mut fast_client)
                    .await
                    .expect("fast wire client receives every push");
                match envelope.body {
                    ControlMessage::VmStatusPush { seq, .. } => sequences.push(seq),
                    other => panic!("expected VmStatusPush, got {other:?}"),
                }
            }
            sequences
        });

        slow_started_rx.await.expect("slow reader started");
        fast_started_rx.await.expect("fast reader started");
        let started = std::time::Instant::now();
        for index in 0..burst_len {
            let phase = if index % 2 == 0 {
                VmPhase::Ready
            } else {
                VmPhase::Starting
            };
            state.set_phase(phase);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }

        let fast_sequences = tokio::time::timeout(Duration::from_millis(500), fast_reader)
            .await
            .expect("fast wire client must not wait for the slow client")
            .expect("fast wire client task must not panic");
        assert!(
            started.elapsed() < Duration::from_millis(500),
            "fast wire client exceeded the 500ms push bound"
        );
        assert_eq!(
            fast_sequences,
            (1..=burst_len as u64).collect::<Vec<_>>(),
            "fast wire client must receive every sequence despite slow-peer backpressure"
        );

        let slow_message = tokio::time::timeout(Duration::from_secs(2), slow_reader)
            .await
            .expect("slow client task must finish after its simulated lag")
            .expect("slow client task must not panic");
        assert!(matches!(
            slow_message.body,
            ControlMessage::VmStatusPush {
                phase: VmPhase::Ready,
                ..
            }
        ));

        slow_server.abort();
        fast_server.abort();
    }

    // ── LoginState / CloudProjects push sources (orders 230/231) ────────────

    /// Order 230: the first login-state observation after boot pushes (no
    /// baseline), and the payload carries the observed state.
    #[tokio::test]
    async fn set_login_state_pushes_on_change() {
        let state = VmStateHandle::new();
        let mut rx = state.subscribe_login_state();
        let flipped = state.set_login_state(true, Some("octocat".to_string()));
        assert!(flipped, "first logged-in observation is a transition");
        match rx.try_recv().expect("first observation must push") {
            ControlMessage::LoginStatePush {
                logged_in, handle, ..
            } => {
                assert!(logged_in);
                assert_eq!(handle.as_deref(), Some("octocat"));
            }
            other => panic!("expected LoginStatePush, got {other:?}"),
        }
    }

    /// Order 260 exit criterion: a VM-side project list change emits
    /// LocalProjectsPush; an identical rescan does not re-push (change gate).
    #[tokio::test]
    async fn set_local_projects_pushes_on_change_only() {
        let entry = |name: &str| LocalProjectEntry {
            label: name.to_string(),
            guest_path: format!("/home/forge/src/{name}"),
            last_seen_unix: 1_752_000_000,
        };
        let state = VmStateHandle::new();
        let mut rx = state.subscribe_local_projects();
        state.set_local_projects(vec![entry("tillandsias")]);
        assert!(
            matches!(rx.try_recv(), Ok(ControlMessage::LocalProjectsPush { entries, .. }) if entries.len() == 1),
            "first scan must push"
        );
        state.set_local_projects(vec![entry("tillandsias")]);
        assert!(
            matches!(rx.try_recv(), Err(broadcast::error::TryRecvError::Empty)),
            "identical list must not push"
        );
        state.set_local_projects(vec![entry("tillandsias"), entry("zeroclaw")]);
        assert!(
            matches!(rx.try_recv(), Ok(ControlMessage::LocalProjectsPush { entries, .. }) if entries.len() == 2),
            "changed list must push"
        );
    }

    /// Order 276 exit criterion: the logged-out -> logged-in transition
    /// produces BOTH pushes (LoginStatePush + CloudProjectsPush) through the
    /// shared funnel with NO inbound request — the cloud fetch is injected,
    /// so the contract runs without podman.
    #[tokio::test]
    async fn login_transition_pushes_login_state_and_cloud_projects() {
        let state = VmStateHandle::new();
        let mut login_rx = state.subscribe_login_state();
        let mut cloud_rx = state.subscribe_cloud_projects();

        state
            .apply_login_transition(true, Some("octocat".to_string()), || {
                vec![CloudProjectEntry {
                    label: "octocat/tillandsias".to_string(),
                    owner: "octocat".to_string(),
                    repo: "tillandsias".to_string(),
                    default_branch: "main".to_string(),
                }]
            })
            .await;

        assert!(
            matches!(
                login_rx.try_recv(),
                Ok(ControlMessage::LoginStatePush {
                    logged_in: true,
                    ..
                })
            ),
            "transition must push LoginState"
        );
        assert!(
            matches!(
                cloud_rx.try_recv(),
                Ok(ControlMessage::CloudProjectsPush { projects, .. }) if projects.len() == 1
            ),
            "transition must refresh + push CloudProjects"
        );
    }

    /// Order 276: an observation that does NOT flip into logged-in must not
    /// invoke the cloud fetch at all (logged-in -> logged-in is a no-op;
    /// logged-in -> logged-out pushes LoginState only).
    #[tokio::test]
    async fn login_transition_fetches_only_on_the_logged_in_flip() {
        let state = VmStateHandle::new();
        state.set_login_state(true, Some("octocat".to_string()));
        let mut login_rx = state.subscribe_login_state();
        let mut cloud_rx = state.subscribe_cloud_projects();

        // Unchanged logged-in: no fetch, no pushes.
        state
            .apply_login_transition(true, Some("octocat".to_string()), || {
                panic!("fetch must not run without a logged-in flip")
            })
            .await;
        assert!(
            login_rx.try_recv().is_err(),
            "unchanged state must not push"
        );
        assert!(cloud_rx.try_recv().is_err(), "no flip => no cloud refresh");

        // Logged-in -> logged-out: LoginState pushes, cloud fetch still not invoked.
        state
            .apply_login_transition(false, None, || {
                panic!("fetch must not run on the logged-out transition")
            })
            .await;
        assert!(
            matches!(
                login_rx.try_recv(),
                Ok(ControlMessage::LoginStatePush {
                    logged_in: false,
                    ..
                })
            ),
            "logout must push LoginState"
        );
        assert!(
            cloud_rx.try_recv().is_err(),
            "logout must not refresh cloud"
        );
    }

    /// Order 230 exit criterion: no redundant push on unchanged state.
    #[tokio::test]
    async fn set_login_state_does_not_push_when_unchanged() {
        let state = VmStateHandle::new();
        state.set_login_state(true, Some("octocat".to_string()));
        let mut rx = state.subscribe_login_state();
        state.set_login_state(true, Some("octocat".to_string()));
        assert!(matches!(
            rx.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        // A real transition (logout) pushes again.
        state.set_login_state(false, None);
        assert!(matches!(
            rx.try_recv(),
            Ok(ControlMessage::LoginStatePush {
                logged_in: false,
                ..
            })
        ));
    }

    /// Order 231: full-replacement compare — identical list is silent,
    /// changed list pushes.
    #[tokio::test]
    async fn set_cloud_projects_pushes_on_change_only() {
        let entry = |repo: &str| CloudProjectEntry {
            label: format!("octocat/{repo}"),
            owner: "octocat".to_string(),
            repo: repo.to_string(),
            default_branch: String::new(),
        };
        let state = VmStateHandle::new();
        let mut rx = state.subscribe_cloud_projects();
        state.set_cloud_projects(vec![entry("tillandsias")]);
        assert!(
            matches!(rx.try_recv(), Ok(ControlMessage::CloudProjectsPush { projects, .. }) if projects.len() == 1),
            "first fetch must push"
        );
        state.set_cloud_projects(vec![entry("tillandsias")]);
        assert!(
            matches!(rx.try_recv(), Err(broadcast::error::TryRecvError::Empty)),
            "identical list must not push"
        );
        state.set_cloud_projects(vec![entry("tillandsias"), entry("zeroclaw")]);
        assert!(
            matches!(rx.try_recv(), Ok(ControlMessage::CloudProjectsPush { projects, .. }) if projects.len() == 2),
            "changed list must push"
        );
    }

    /// Order 230: the periodic vault probe is subscriber-gated so an idle
    /// headless spends zero podman execs on login polling.
    #[test]
    fn login_probe_gate_reflects_subscriber_count() {
        let state = VmStateHandle::new();
        assert!(!state.has_login_state_subscribers());
        let rx = state.subscribe_login_state();
        assert!(state.has_login_state_subscribers());
        drop(rx);
        assert!(!state.has_login_state_subscribers());
    }

    #[test]
    fn vm_state_handle_podman_ready_checks_socket_path() {
        let mut state = VmStateHandle::new();
        state.set_podman_socket(PathBuf::from("/this/path/does/not/exist"));
        assert!(!state.podman_ready());
    }

    /// gap-6 contract: `advance_to_ready_when_podman_up` flips
    /// `Starting → Ready` the moment `podman_ready` returns true. We
    /// stand up a real tempfile, point the state at it, and confirm the
    /// transition fires within the poll interval. Sub-second cadence so
    /// the test stays fast.
    #[tokio::test]
    async fn advance_to_ready_flips_phase_when_socket_appears() {
        use std::time::Duration;
        let tmp = tempfile::tempdir().expect("tempdir");
        let sock = tmp.path().join("podman.sock");
        let mut state = VmStateHandle::new();
        state.set_podman_socket(sock.clone());
        assert_eq!(state.current_phase(), VmPhase::Starting);

        // Spawn the advancer first, then create the file from this task
        // a few polls in. Cloned handle shares the same phase lock.
        let advancer_state = state.clone();
        let advancer = tokio::spawn(async move {
            advancer_state
                .advance_to_ready_when_podman_up(Duration::from_secs(2), Duration::from_millis(25))
                .await;
        });

        tokio::time::sleep(Duration::from_millis(75)).await;
        std::fs::File::create(&sock).expect("create podman.sock");

        advancer.await.expect("advancer join");
        assert_eq!(state.current_phase(), VmPhase::Ready);
    }

    /// gap-6 contract: when the socket never appears within `timeout`,
    /// the advancer flips `Starting → Failed`. The host tray uses this
    /// to surface a clear "VM is up but podman never came online" state
    /// instead of leaving the phase as a permanent `Starting`.
    #[tokio::test]
    async fn advance_to_ready_marks_failed_on_timeout() {
        use std::time::Duration;
        let mut state = VmStateHandle::new();
        // A path that will never exist — relies on the advancer's poll
        // interval being far shorter than the timeout to keep the test
        // bounded.
        state.set_podman_socket(PathBuf::from("/nonexistent/podman.sock"));
        state
            .advance_to_ready_when_podman_up(Duration::from_millis(60), Duration::from_millis(15))
            .await;
        assert_eq!(state.current_phase(), VmPhase::Failed);
    }

    /// gap-6 contract: a `Stopping` (or `Draining`, or `Ready`) set by
    /// another path while the advancer is polling MUST NOT be demoted.
    /// The advancer is single-purpose — it advances `Starting`, nothing
    /// else.
    #[tokio::test]
    async fn advance_to_ready_respects_concurrent_transitions() {
        use std::time::Duration;
        let state = VmStateHandle::new();
        state.set_phase(VmPhase::Stopping);

        // Even with a long timeout + non-existent socket, the advancer
        // exits immediately because the phase is no longer Starting.
        let start = std::time::Instant::now();
        state
            .advance_to_ready_when_podman_up(Duration::from_secs(60), Duration::from_millis(50))
            .await;
        assert!(start.elapsed() < Duration::from_millis(200));
        assert_eq!(state.current_phase(), VmPhase::Stopping);
    }

    /// gap-6 contract: `watch_shutdown_and_mark_stopping` flips the
    /// phase to `Stopping` when the shared shutdown atomic goes true.
    /// This is how `graceful_shutdown_async` entry shows up over the
    /// vsock control wire without having to thread the state through
    /// every shutdown call site.
    #[tokio::test]
    async fn watch_shutdown_marks_stopping_when_atomic_flips() {
        use std::time::Duration;
        let state = VmStateHandle::new();
        // Pretend the advancer already brought us to Ready.
        state.set_phase(VmPhase::Ready);
        let shutdown = Arc::new(AtomicBool::new(false));

        let watcher_state = state.clone();
        let watcher_shutdown = Arc::clone(&shutdown);
        let watcher = tokio::spawn(async move {
            watcher_state
                .watch_shutdown_and_mark_stopping(watcher_shutdown)
                .await;
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        shutdown.store(true, Ordering::SeqCst);
        watcher.await.expect("watcher join");
        assert_eq!(state.current_phase(), VmPhase::Stopping);
    }

    /// gap-6 contract: the shutdown watcher MUST NOT clobber a terminal
    /// `Failed`. If the advancer timed out before SIGTERM arrived, we
    /// want the host tray to keep seeing the diagnostic, not see it
    /// rewritten into the more innocuous-looking `Stopping`.
    #[tokio::test]
    async fn watch_shutdown_preserves_failed_state() {
        let state = VmStateHandle::new();
        state.set_phase(VmPhase::Failed);
        let shutdown = Arc::new(AtomicBool::new(true)); // already requested

        state
            .watch_shutdown_and_mark_stopping(Arc::clone(&shutdown))
            .await;
        assert_eq!(state.current_phase(), VmPhase::Failed);
    }

    #[test]
    fn enumerate_local_projects_returns_dirs_only() {
        use std::fs;
        let tmp = tempfile::tempdir().expect("tempdir");
        fs::create_dir(tmp.path().join("alpha")).unwrap();
        fs::create_dir(tmp.path().join("beta")).unwrap();
        fs::write(tmp.path().join("loose-file"), b"not a project").unwrap();
        fs::create_dir(tmp.path().join(".hidden")).unwrap();

        let entries = enumerate_local_projects_at(tmp.path());

        let labels: Vec<&str> = entries.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(labels, vec!["alpha", "beta"]);
    }

    #[test]
    fn enumerate_local_projects_returns_empty_when_root_missing() {
        let entries = enumerate_local_projects_at(Path::new(
            "/this/dir/intentionally/does/not/exist/under/tillandsias",
        ));
        assert!(entries.is_empty());
    }
}
