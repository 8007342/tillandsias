//! `--listen-vsock` mode: bind the control wire to a vsock listener instead
//! of the Linux Unix socket, so an in-VM tillandsias can serve the host-side
//! tray on Windows / macOS over virtio-vsock.
//!
//! Mirrors the Unix-socket handler in `tray::mod::handle_control_connection`:
//! reads the first frame as `Hello`, replies with `HelloAck`, then keeps the
//! connection open for VM-lifecycle / cloud-refresh request frames.
//!
//! Phase-2 scope is the handshake + a small request/reply set
//! (`VmStatusRequest`, `CloudRefreshRequest`, `VmShutdownRequest`). Full
//! menu-state propagation lands in Phase 3+. (`EnumerateLocalProjects` was
//! removed with the local-projects surface in 997-e4v2 step 3.)
//!
//! Linux-only, gated behind `feature = "listen-vsock"`.
//!
//! @trace spec:vsock-transport, spec:host-shell-architecture

use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tillandsias_control_wire::transport::{
    AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Listener, Transport, bind, control_frame_codec,
};
use tillandsias_control_wire::{
    CAP_PTY_ATTACH_V1, CAP_PTY_HEARTBEAT_V1, CAP_PTY_HEARTBEAT_V2, CloudProjectEntry,
    CloudRefreshOutcome, ContainerMetricWire, ControlEnvelope, ControlMessage, ErrorCode,
    MAX_MESSAGE_BYTES, MetricsSnapshotWire, MountIoMetricWire, VmPhase, WIRE_VERSION, decode,
    encode,
};
use tillandsias_secure_channel::{HopId, channel_psk, server_handshake_or_reclaim};
#[cfg(test)]
use tokio::io::AsyncReadExt;
use tokio::io::AsyncWriteExt;
use tokio::sync::{broadcast, mpsc, watch};
use tracing::{debug, info, warn};

#[cfg(unix)]
use crate::pty_handler::PtySessionStore;

const SERVER_NAME: &str = "tillandsias-in-vm";

fn client_supports_pty_heartbeat(capabilities: &[String]) -> bool {
    capabilities
        .iter()
        .any(|capability| capability == CAP_PTY_HEARTBEAT_V1 || capability == CAP_PTY_HEARTBEAT_V2)
}

/// Order 723-2yb3. A v2 client gets `PtyHeartbeat` frames carrying the input
/// state; everyone else keeps the v1 empty-`PtyData` heartbeat.
///
/// Checked SEPARATELY from v1 rather than as a version ladder: a client may
/// advertise v2 alone, and treating v2 as implying v1 (or the reverse) is how
/// a negotiation grows a case nobody tests. Both tokens are independent facts
/// about what the peer can decode.
fn client_supports_pty_heartbeat_v2(capabilities: &[String]) -> bool {
    capabilities
        .iter()
        .any(|capability| capability == CAP_PTY_HEARTBEAT_V2)
}

/// Guard so vault bootstrap runs at most once per process even if multiple
/// tray connections deliver credentials concurrently.
#[cfg(feature = "vault")]
static VAULT_BOOTSTRAP_DONE: AtomicBool = AtomicBool::new(false);

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

/// Wrap `stream` per the secure-control-wire `mode`: `Off` passes the
/// plaintext stream through, `On` runs the version-bound Noise responder
/// handshake and returns the encrypted stream.
///
/// The mode is a PARAMETER (resolved by the caller via
/// [`secure_control_wire_mode`]) rather than read here: the env gate caches
/// through a `OnceLock`, so a unit test could never exercise the gated-ON
/// path without process-wide env mutation if this function consulted the
/// gate itself (order 137, vsock-exec-chain-authn-authz).
///
/// A FAILED gated-ON handshake RETURNS the raw stream with the error
/// (`server_handshake_or_reclaim`): the order-137 cutover contract ("send
/// Error{code: Unauthorized} and close",
/// plan/issues/encrypted-channel-vsock-cutover-2026-07-02.md) needs the
/// still-plaintext connection for the rejection notice, and giving the
/// stream back keeps every value owned — no borrow reaches across the
/// caller's success/failure split.
#[allow(clippy::type_complexity)]
async fn maybe_secure_stream(
    mode: SecureControlWireMode,
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
) -> Result<
    Box<dyn AsyncReadWrite + Unpin + Send>,
    (Box<dyn AsyncReadWrite + Unpin + Send>, io::Error),
> {
    match mode {
        SecureControlWireMode::Off => Ok(stream),
        SecureControlWireMode::On => {
            let psk = channel_psk(
                tillandsias_secure_channel::workspace_version(),
                WIRE_VERSION,
                HopId::HostGuest,
            );
            match server_handshake_or_reclaim(stream, &psk).await {
                Ok(secure) => Ok(Box::new(secure)),
                Err((raw, err)) => Err((raw, err)),
            }
        }
    }
}

/// Hot paths sampled for per-mount I/O on every `MetricsSnapshotRequest`
/// (order 333, deliverable
/// `plan/issues/guest-container-metrics-over-control-wire-2026-07-13.md`):
/// the forge worktree, the pull cache, the cheatsheet overlay, the git-mirror
/// store, and the proxy cache. A path whose backing device is not visible in
/// `/proc/diskstats` (tmpfs, virtiofs, overlay) reports `error: unavailable:
/// <fstype>` rather than a fabricated zero — that is the point of naming them
/// explicitly instead of sampling whatever happens to be mounted.
const METRICS_MOUNT_PATHS: &[&str] = &[
    "/home/forge/src",
    "/var/cache/tillandsias",
    "/opt/cheatsheets",
    "/srv/git",
    "/var/spool/squid",
];

/// Convert sampler types into their wire counterparts (order 333). The wire
/// crate deliberately owns standalone structs so sidecar consumers need no
/// dependency on `tillandsias-metrics`; this is the one place the two shapes
/// meet, and it is a pure field-for-field move — `None` and `error` travel
/// through unchanged, so the no-fabrication contract cannot be lost in
/// translation.
fn metrics_snapshot_wire(
    containers: Vec<tillandsias_metrics::ContainerMetric>,
    mounts: Vec<tillandsias_metrics::MountIoMetric>,
) -> MetricsSnapshotWire {
    MetricsSnapshotWire {
        sampled_at_unix: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        containers: containers
            .into_iter()
            .map(|c| ContainerMetricWire {
                name: c.name,
                cpu_usec: c.cpu_usec,
                memory_current_bytes: c.memory_current_bytes,
                blkio_read_bytes: c.blkio_read_bytes,
                blkio_write_bytes: c.blkio_write_bytes,
                blkio_read_ops: c.blkio_read_ops,
                blkio_write_ops: c.blkio_write_ops,
                error: c.error,
            })
            .collect(),
        mounts: mounts
            .into_iter()
            .map(|m| MountIoMetricWire {
                path: m.path,
                device: m.device,
                read_bytes: m.read_bytes,
                write_bytes: m.write_bytes,
                read_ops: m.read_ops,
                write_ops: m.write_ops,
                error: m.error,
            })
            .collect(),
    }
}

/// Bound on the best-effort plaintext `Unauthorized` notice written to a
/// peer that failed the secure-channel handshake (order 137). Best-effort by
/// design: a peer that never reads must not be able to pin this handler —
/// the notice is a courtesy diagnostic, the fail-closed `return` is the
/// contract.
const UNAUTHORIZED_NOTICE_TIMEOUT: Duration = Duration::from_millis(500);

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
    /// Monotonic counter for the `seq` field carried inside each push
    /// message (distinct from the per-request `ControlEnvelope.seq`, which
    /// pushes don't have a request to reply to). Shared across all push
    /// topics so the host can totally order pushes from this headless.
    push_seq: Arc<std::sync::atomic::AtomicU64>,
    /// Last event message.
    last_event: Arc<RwLock<String>>,
    /// Order 690-xeda: waker for the steady-state probe loops. The periodic
    /// login-state and local-projects tasks PARK (no timer at all) while
    /// they have zero subscribers; `subscribe_login_state` /
    /// `subscribe_local_projects` fire this so a parked loop wakes when the
    /// first listener arrives. `notify_waiters` carries no stored permit, so
    /// a subscribe landing between a loop's gate check and its `notified()`
    /// await can be missed — every parked loop therefore pairs the wait with
    /// a bounded backstop timeout rather than trusting the wake alone.
    subscriber_nudge: Arc<tokio::sync::Notify>,
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
        Self {
            phase: Arc::new(RwLock::new(VmPhase::Starting)),
            podman_socket: PathBuf::from(IN_VM_PODMAN_SOCKET_DEFAULT),
            vm_status_tx,
            login_state_tx,
            login_state: Arc::new(RwLock::new(None)),
            cloud_projects_tx,
            cloud_projects: Arc::new(RwLock::new(None)),
            push_seq: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            last_event: Arc::new(RwLock::new(SERVER_NAME.to_string())),
            subscriber_nudge: Arc::new(tokio::sync::Notify::new()),
        }
    }

    /// Order 690-xeda: clone of the subscriber-arrival waker. Probe loops
    /// that are subscriber-gated park on `notified()` (with a bounded
    /// backstop) instead of ticking on a timer nobody is listening to.
    pub fn subscriber_nudge(&self) -> Arc<tokio::sync::Notify> {
        Arc::clone(&self.subscriber_nudge)
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
    /// Order 690-xeda: also wakes the parked login-state probe loop so the
    /// first subscriber gets a fresh observation without waiting out the
    /// backstop.
    pub fn subscribe_login_state(&self) -> broadcast::Receiver<ControlMessage> {
        let rx = self.login_state_tx.subscribe();
        self.subscriber_nudge.notify_waiters();
        rx
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
        F: FnOnce() -> (Vec<CloudProjectEntry>, CloudRefreshOutcome) + Send + 'static,
    {
        let flipped_in = self.set_login_state(logged_in, handle);
        if flipped_in {
            let (projects, outcome) = tokio::task::spawn_blocking(fetch).await.unwrap_or_default();
            // 731-eupn: a login transition must not publish an UNCONFIRMED
            // list. This is the post-login fetch, and it is exactly the moment
            // the tray first renders the cloud submenu — so pushing an empty
            // list here because `gh` was not ready yet is what produced
            // "(no repos)" for accounts with hundreds of them. On a failed
            // fetch, leave the previous list alone; the periodic refresh will
            // publish once it has something to say.
            if outcome.is_confirmed() {
                self.set_cloud_projects(projects);
            } else {
                debug!(
                    spec = "host-shell-architecture",
                    ?outcome,
                    "login transition: cloud fetch unconfirmed; keeping previous list"
                );
            }
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
            // ORDER 690-xeda. This was a 250 ms sleep loop: 4 wakeups/second
            // for the entire life of every VM, attached or not. Measured on a
            // fully idle guest before the change: ~4 wakeups/s (79 context
            // switches in 20 s).
            //
            // The flag stays the source of truth and is re-read on every wake,
            // so this cannot observe a stale value. SHUTDOWN_BACKSTOP is a
            // deliberate, justified timer rather than a bare `notified().await`:
            // the setter is an atomic store reachable from signal handlers and
            // several call sites, and if any one of them ever forgets to notify,
            // a pure event wait would hang shutdown forever. A missed notify
            // here costs at most one backstop interval instead of a wedged VM.
            // 250 ms -> 30 s is a 120x reduction in idle wakeups while keeping
            // the failure mode bounded.
            tokio::select! {
                _ = shutdown_notify().notified() => {}
                _ = tokio::time::sleep(SHUTDOWN_BACKSTOP) => {}
            }
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
    // 798-q4m9 criterion 3: THE BIND MOMENT MUST BE OBSERVABLE, or the packet's
    // own exit criterion cannot be met by anyone.
    //
    // The `info!` below has no subscriber in the guest — measured 2026-08-18:
    // there is no `tillandsias.log` anywhere in the guest filesystem and no
    // vsock-transport line in `journalctl -u tillandsias-headless`. So the one
    // event the criterion asks to time left no trace at all, and an attempt to
    // measure it instead timed the vsock PREFLIGHT line, which marks when the
    // listener task was SPAWNED. That is the wrong quantity: `tokio::spawn`
    // only enqueues, so issuing five spawns costs microseconds and the before/
    // after readings were 6.624 ms and 6.605 ms — indistinguishable, and
    // measuring nothing about when the listener actually became reachable.
    //
    // eprintln! rather than fixing the tracing subscriber: stderr from this
    // unit demonstrably reaches the journal with a monotonic timestamp (the
    // preflight line proves the path), so this is the smallest change that
    // makes the criterion measurable. Deliberately one line, at the exact
    // instant `bind` returns, so the timestamp means the listener is reachable
    // and nothing else.
    eprintln!("[tillandsias] vsock listener bound port={port}");
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

/// How long an idle waiter parks before re-reading the shutdown flag anyway
/// (order 690-xeda).
///
/// A bare `notified().await` would be the pure event form, and it is
/// deliberately NOT what this uses. The flag is an `AtomicBool` written from
/// signal handlers and several call sites; if any one of them ever stores
/// without notifying, a pure wait hangs shutdown forever. This bounds that
/// failure to one interval while still removing 99%+ of the idle wakeups:
/// 250 ms -> 30 s is 120x fewer.
const SHUTDOWN_BACKSTOP: Duration = Duration::from_secs(30);

/// Process-wide shutdown wakeup. Paired with the existing `AtomicBool`, which
/// stays the source of truth — this only says "go look again", so a spurious
/// or missed notification is never a correctness problem.
fn shutdown_notify() -> &'static tokio::sync::Notify {
    static NOTIFY: std::sync::OnceLock<tokio::sync::Notify> = std::sync::OnceLock::new();
    NOTIFY.get_or_init(tokio::sync::Notify::new)
}

/// Wake every task parked on the shutdown signal (order 690-xeda).
///
/// This exists because there IS now a caller: `wait_for_shutdown_signal` awaits
/// SIGTERM/SIGINT through `tokio::signal::unix` and calls this on the edge, so
/// the waiters below are woken by the signal itself rather than by their
/// backstop. An earlier attempt shipped this helper with no caller and it was
/// deleted as decorative; it is back only because the event source is real.
///
/// The `AtomicBool` remains the source of truth and every waiter re-reads it
/// on wake, so a missed or spurious wake is never a correctness problem.
pub fn wake_shutdown_waiters() {
    shutdown_notify().notify_waiters();
}

// HISTORY worth keeping: for one cycle there was NO caller that woke The shutdown flag is set
// by `signal_hook::flag::register`, a C signal handler that writes the atomic
// directly, and no Rust code path runs on that edge. So today the waiters below
// are woken by SHUTDOWN_BACKSTOP, not by an event — this is a 250 ms -> 30 s
// reduction in idle wakeups, NOT the event-driven form the doctrine asks for.
//
// A `signal_shutdown()` helper that stored-and-notified was written here and
// then deleted: nothing could call it, and an API whose only property is
// looking event-driven is worse than an honest timer. The Notify stays because
// the waiters already select on it, so the day a Rust-side setter exists (or
// signal-hook-tokio delivers signals asynchronously) it becomes event-driven
// by adding one call — but until then, no comment in this file should claim it
// already is.

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
        // ORDER 690-xeda. This raced accept() against a 250 ms timer purely to
        // re-read the shutdown flag — a second 4-wakeups/second source on an
        // idle guest. Now the loop parks in accept() and is woken by the
        // shutdown signal itself, with the same justified backstop as the
        // watcher above so a missed notify cannot strand the listener.
        let accepted = tokio::select! {
            r = listener.accept() => Some(r),
            _ = shutdown_notify().notified() => None,
            _ = tokio::time::sleep(SHUTDOWN_BACKSTOP) => None,
        };
        match accepted {
            Some(Ok(stream)) => {
                tokio::spawn(handle_connection(
                    stream,
                    state.clone(),
                    connection_shutdown_rx.clone(),
                ));
            }
            Some(Err(err)) => {
                warn!(spec = "vsock-transport", error = %err, "vsock accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            None => {
                // Woken by the shutdown signal (or the backstop): loop and
                // re-read the flag, which remains the source of truth.
            }
        }
    }
}

async fn handle_connection(
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    state: VmStateHandle,
    shutdown: watch::Receiver<bool>,
) {
    // The gate is resolved HERE (OnceLock-cached env read) and passed down so
    // the gated-ON body stays unit-testable without env mutation (order 137).
    handle_connection_with_mode(secure_control_wire_mode(), stream, state, shutdown).await
}

async fn handle_connection_with_mode(
    mode: Result<SecureControlWireMode, String>,
    raw_stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    state: VmStateHandle,
    mut shutdown: watch::Receiver<bool>,
) {
    let mode = match mode {
        Ok(mode) => mode,
        Err(err) => {
            // Misconfigured gate (unknown flag value): fail closed without
            // serving anything. No Unauthorized notice here — the parse error
            // is an operator misconfiguration, not a peer-authorization
            // verdict.
            warn!(
                spec = "vsock-transport",
                error = %err,
                "secure control wire misconfigured; closing connection"
            );
            return;
        }
    };
    // Every value stays OWNED across the success/failure split: a failed
    // gated-ON handshake hands the raw stream BACK (server_handshake_or_reclaim),
    // so no borrow of it has to span this match — the earlier borrowing
    // draft was NLL-rejected (E0499, drop-liveness of the Ok box).
    let handshake = tokio::select! {
        result = maybe_secure_stream(mode, raw_stream) => result,
        _ = connection_shutdown(&mut shutdown) => return,
    };
    let (mut refused_stream, err) = match handshake {
        Ok(stream) => {
            if mode == SecureControlWireMode::On {
                info!(
                    spec = "vsock-transport",
                    "secure control wire handshake succeeded (TILLANDSIAS_SECURE_CONTROL_WIRE=on)"
                );
            }
            serve_ready_stream(stream, state, shutdown).await;
            return;
        }
        Err((raw, err)) => (raw, err),
    };
    // Reached only when a gated-ON handshake FAILED (Off cannot fail).
    // Order-137 cutover contract: "send Error{code: Unauthorized} and
    // close", never a silent close. Best-effort and time-bounded: the write
    // result is ignored so an unauthenticated peer that never reads cannot
    // pin this handler.
    // @trace plan/issues/encrypted-channel-vsock-cutover-2026-07-02.md
    if mode == SecureControlWireMode::On {
        let unauthorized = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 0,
            body: ControlMessage::Error {
                seq_in_reply_to: None,
                code: ErrorCode::Unauthorized,
                message: "secure control wire required: the version-bound \
                          secure-channel handshake failed; plaintext or \
                          mismatched-version peers are not served"
                    .to_string(),
            },
        };
        let _ = tokio::time::timeout(
            UNAUTHORIZED_NOTICE_TIMEOUT,
            write_envelope(&mut refused_stream, &unauthorized),
        )
        .await;
    }
    warn!(spec = "vsock-transport", error = %err, "secure control wire handshake failed");
}

/// The post-handshake serving loop — everything after a connection is
/// cleared to be served (the plaintext stream when the secure control wire
/// is Off, the encrypted stream when On). Factored out of
/// `handle_connection_with_mode` (order 137) so the success path can
/// consume the secured stream inside its own match arm while the failure
/// path keeps the reclaimed raw stream for the Unauthorized notice.
async fn serve_ready_stream(
    stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    state: VmStateHandle,
    mut shutdown: watch::Receiver<bool>,
) {
    // Order 795-5itp. ONE owner of the read buffer for the whole
    // connection: the Hello, the HelloAck and every subsequent frame go
    // through this `Framed`, and the split below splits the FRAMED, never
    // the raw stream. Wrapping for the handshake and then reclaiming the
    // stream would discard whatever the codec had already buffered — a
    // pipelined Subscribe riding in behind the Hello would vanish with no
    // error and no log. Pinned by
    // `pipelined_hello_and_subscribe_both_survive_the_handoff`.
    //
    // The codec comes from the shared constructor so `max_frame_length`
    // cannot drift from MAX_MESSAGE_BYTES; `LengthDelimitedCodec::new()`
    // defaults to 8 MiB, 128x looser than every reader on this wire.
    let mut framed = tokio_util::codec::Framed::new(stream, control_frame_codec());

    let first = match tokio::select! {
        result = read_framed_envelope(&mut framed) => result,
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
                "CloudRefreshRequest".into(),
                "VmShutdownRequest".into(),
                "GithubLoginStatusRequest".into(),
                // Order 333: advertise guest metrics so a tray can feature-
                // detect instead of probing a version table.
                "MetricsSnapshotRequest".into(),
                // Order 795-zshi: advertise that this guest accepts a
                // verbatim argv vector, so a host can stop flattening argv
                // into a shell string — and can tell whether THIS guest
                // supports it rather than guessing from a version.
                tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR.into(),
                // Order 795-zshi slice 4: advertise that THIS guest heals a
                // widened CA key mode on ensure_proxy_running's already-running
                // early-return path, so a host can drop the `chmod 600` from its
                // exec preamble. Separate from ExecArgvVector deliberately —
                // they shipped in different commits, so the argv cap does not
                // imply the heal. See CAP_PROXY_CA_KEY_HEAL's doc comment.
                tillandsias_control_wire::CAP_PROXY_CA_KEY_HEAL.into(),
                // Order 925-eofi: advertise that this guest understands an
                // explicit end-of-stdin frame. A host MUST feature-detect on
                // this before sending PtyStdinEof — a guest predating it
                // rejects the unknown variant and the SESSION dies, which is
                // strictly worse than the hang the frame exists to fix
                // (924-eof7).
                tillandsias_control_wire::CAP_PTY_STDIN_EOF.into(),
                // Order 926-bin4: advertise that this guest can open a DATA
                // session (child fd 0 on a pipe), so a host can send binary
                // stdin without the line discipline eating control bytes.
                tillandsias_control_wire::CAP_PTY_DATA_SESSION.into(),
                CAP_PTY_ATTACH_V1.into(),
                CAP_PTY_HEARTBEAT_V1.into(),
            ],
            // Report the workspace VERSION (repo-root VERSION file), NOT this
            // crate's CARGO_PKG_VERSION. The host tray displays + compares
            // against workspace_version() (menu "(Update Pending)" gate,
            // menu_state.rs); reporting the per-crate version here (e.g.
            // "0.3.260721" vs the host's "0.3.260721.1") produced a permanent
            // spurious version-skew. Both ends must speak the one product version.
            build_version: Some(tillandsias_secure_channel::workspace_version().to_string()),
        },
    };
    if let Err(err) = write_framed_envelope(&mut framed, &ack).await {
        warn!(spec = "vsock-transport", error = %err, "failed to write HelloAck");
        return;
    }

    // Split the FRAMED, not the raw stream (order 795-5itp): `futures::StreamExt`
    // hands back a sink and a stream that share one codec and therefore one read
    // buffer, so anything already decoded during the handshake is still there for
    // the reader task. `tokio::io::split(stream)` on the underlying transport
    // would silently strip it. The read side is owned by a dedicated task so it
    // is never a `select!` branch — cancellation cannot interrupt it mid-frame,
    // which is the 795-57y6 desync this split was introduced to fix.
    let (mut write_half, read_half) = futures::StreamExt::split(framed);

    // Spawn a dedicated reader task that owns the read half. The read is
    // never a select! branch, so cancellation cannot interrupt it mid-frame.
    // Completed envelopes are sent through the channel to the main loop.
    let (inbound_tx, mut inbound_rx) = mpsc::channel::<io::Result<ControlEnvelope>>(8);
    tokio::spawn(async move {
        let mut reader = read_half;
        loop {
            let result = read_framed_envelope(&mut reader).await;
            let is_err = result.is_err();
            if inbound_tx.send(result).await.is_err() {
                break; // main loop dropped the receiver
            }
            if is_err {
                break; // EOF or parse error — reader is done
            }
        }
    });

    // Per-connection PTY session store (l3: control-wire-pty-attach Tasks 4.x).
    // The pump tasks for each PTY session push envelopes into `pty_outbound`;
    // the main read loop interleaves those writes with normal request/reply
    // traffic via tokio::select!. When this function returns, dropping
    // `pty_store` cascades into `shutdown_all` so children are reaped on
    // disconnect.
    let (pty_tx, mut pty_rx) = mpsc::channel::<ControlEnvelope>(PTY_OUTBOUND_CAPACITY);
    #[cfg(unix)]
    let mut pty_store = if client_supports_pty_heartbeat(&client_capabilities) {
        PtySessionStore::new_with_heartbeat(
            pty_tx.clone(),
            client_supports_pty_heartbeat_v2(&client_capabilities),
        )
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

    'connection: loop {
        tokio::select! {
            _ = connection_shutdown(&mut shutdown) => {
                // Drop the write half so the peer sees EOF; the reader
                // task will exit when its read half errors or the stream
                // closes.
                drop(write_half);
                break 'connection;
            }
            // Outbound PTY frame (PtyData{ToHost} from a pump or PtyClose
            // from child reap).
            Some(env) = pty_rx.recv() => {
                if write_envelope_with_shutdown(&mut write_half, &env, &mut shutdown).await.is_err() {
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
                        if write_envelope_with_shutdown(&mut write_half, &env, &mut shutdown).await.is_err() {
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
                        if write_envelope_with_shutdown(&mut write_half, &env, &mut shutdown).await.is_err() {
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
                        if write_envelope_with_shutdown(&mut write_half, &env, &mut shutdown).await.is_err() {
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
            // Inbound frame — received from the dedicated reader task via
            // channel. The reader owns the read half and never appears in a
            // select! branch, so cancellation cannot interrupt it mid-frame
            // (795-57y6).
            result = inbound_rx.recv() => {
                let env = match result {
                    Some(Ok(env)) => env,
                    Some(Err(err)) => {
                        debug!(spec = "vsock-transport", error = %err, "vsock connection closed");
                        break 'connection;
                    }
                    None => {
                        // Reader task exited (stream closed or dropped).
                        debug!(spec = "vsock-transport", "inbound reader task exited; closing connection");
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
                        if write_envelope_with_shutdown(&mut write_half, &err, &mut shutdown).await.is_err() {
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
                        if write_envelope_with_shutdown(&mut write_half, &err, &mut shutdown).await.is_err() {
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
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown).await.is_err() {
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
                let ack = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::SubscribeAck,
                };
                if write_envelope_with_shutdown(&mut write_half, &ack, &mut shutdown).await.is_err() {
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
                // A panicked/cancelled blocking task defaults to
                // (empty, Unknown) — NOT (empty, Ok). The tuple's Default
                // derives from CloudRefreshOutcome's, which is Unknown by
                // design (731-eupn), so a join failure also fails closed
                // rather than announcing a confirmed-empty account.
                let (projects, outcome) = tokio::task::spawn_blocking(fetch_cloud_projects)
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
                        outcome,
                    },
                };
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown).await.is_err() {
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
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown).await.is_err() {
                    break 'connection;
                }
            }
            ControlMessage::MetricsSnapshotRequest { seq } => {
                // Order 333: per-container cgroup counters + per-mount I/O,
                // sampled in the GUEST and returned over the control wire so
                // macOS/Windows trays never need a TCP path into the VM.
                // spawn_blocking because the samplers read /sys and /proc and
                // shell out to `podman ps` (bounded).
                //
                // The no-fabrication contract rides in the DATA, not in the
                // control flow: a failed sample travels as `error` with the
                // values `None` (spec:observability-metrics), so this arm
                // always replies — an empty-but-healthy-looking snapshot is
                // exactly what the packet forbids, and the samplers never
                // produce one.
                let snapshot = tokio::task::spawn_blocking(|| {
                    let containers = tillandsias_metrics::sample_containers();
                    let mounts = tillandsias_metrics::sample_mount_io(METRICS_MOUNT_PATHS);
                    (containers, mounts)
                })
                .await;
                let (containers, mounts) = match snapshot {
                    Ok(sampled) => sampled,
                    Err(err) => {
                        // The blocking pool itself failed — report it as a
                        // sample-level error rather than an empty snapshot.
                        warn!(
                            spec = "observability-metrics",
                            error = %err,
                            "metrics sampling task failed"
                        );
                        (
                            vec![tillandsias_metrics::ContainerMetric::error_only(
                                "sampler",
                                format!("metrics sampling task failed: {err}"),
                            )],
                            Vec::new(),
                        )
                    }
                };
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::MetricsSnapshotReply {
                        seq_in_reply_to: seq,
                        snapshot: metrics_snapshot_wire(containers, mounts),
                    },
                };
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown)
                    .await
                    .is_err()
                {
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
                    if write_envelope_with_shutdown(&mut write_half, &err_env, &mut shutdown).await.is_err() {
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
                // Bounded enqueue (audit D6): never blocks past the 250ms
                // control-plane fairness deadline — a wedged session is
                // killed by the store instead (kill-not-drop).
                pty_store.write_to_guest(session_id, bytes).await;
            }
            #[cfg(unix)]
            ControlMessage::PtyOpenData {
                session_id,
                rows,
                cols,
                argv,
                env: pty_env,
                cwd,
            } => {
                // Order 926-bin4: identical to PtyOpen except the child's fd 0
                // is a pipe, so stdin crosses no line discipline. Shares the
                // same failure reporting; only the stdin wiring differs.
                if let Err(err) = pty_store
                    .open_with_stdin_kind(session_id, rows, cols, argv, pty_env, cwd, true)
                    .await
                {
                    let err_env = ControlEnvelope {
                        wire_version: WIRE_VERSION,
                        seq: env.seq,
                        body: ControlMessage::Error {
                            seq_in_reply_to: Some(env.seq),
                            code: ErrorCode::Internal,
                            message: format!("PtyOpenData failed: {err}"),
                        },
                    };
                    if write_envelope_with_shutdown(&mut write_half, &err_env, &mut shutdown)
                        .await
                        .is_err()
                    {
                        break 'connection;
                    }
                }
            }
            #[cfg(unix)]
            ControlMessage::PtyStdinEof { session_id } => {
                // Order 925-eofi. Same bounded queue as the input bytes, so an
                // EOF cannot overtake the data it terminates. What actually
                // reaches the child is decided in the writer task, which can
                // see the termios state — see PtyWriteCommand::StdinEof.
                pty_store.stdin_eof(session_id).await;
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
                // Routed through the same per-session queue as PtyData so
                // TIOCSWINSZ keeps its arrival order relative to input
                // bytes (audit D6); enqueue is deadline-bounded like the
                // data path.
                pty_store.resize(session_id, rows, cols).await;
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
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown).await.is_err() {
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
                    // Slowdown audit 2026-07-23: only the FIRST request per
                    // process may poll (genuine first-boot window). After a
                    // handover reply has been delivered once, every later
                    // fresh connection is steady state — the old
                    // unconditional loop slept its full 8s on EVERY connect
                    // (8.1s per --status-once; the tray start paid it twice
                    // serially).
                    if result.0.is_none()
                        && !crate::vault_bootstrap::handover_already_delivered()
                    {
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
                let delivered_unseal_share =
                    crate::vault_bootstrap::handover_reply_delivers_unseal_share(
                        unseal_share_b64.as_deref(),
                    );
                crate::vault_bootstrap::clear_pending_handover(delivered_unseal_share);

                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::VaultHandoverReply {
                        seq_in_reply_to: seq,
                        unseal_share_b64,
                        root_token,
                    },
                };
                if write_envelope_with_shutdown(&mut write_half, &reply, &mut shutdown).await.is_err() {
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
                if write_envelope_with_shutdown(&mut write_half, &err, &mut shutdown).await.is_err() {
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

/// Read one envelope from a `Framed` control wire (order 795-5itp).
///
/// The error surface is deliberately IDENTICAL to `read_envelope`'s, because
/// the callers and tests here have always seen those exact strings. The codec
/// reports its own bound violation as "frame size too big"; that is remapped
/// to `inbound control frame too large` rather than allowed to leak, so a
/// migration cannot be detected from the outside by the shape of a failure.
async fn read_framed_envelope<S>(framed: &mut S) -> io::Result<ControlEnvelope>
where
    S: futures::Stream<Item = Result<bytes::BytesMut, io::Error>> + Unpin,
{
    use futures::StreamExt;
    let body = match framed.next().await {
        Some(Ok(body)) => body,
        Some(Err(err)) if err.kind() == io::ErrorKind::InvalidData => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "control frame too large",
            ));
        }
        Some(Err(err)) => return Err(err),
        // A clean EOF. The hand-rolled reader surfaced this as the
        // `read_exact` UnexpectedEof it got from the socket; `Framed` reports
        // it as `None`, so it is restated here in the caller's vocabulary.
        None => {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "control wire closed",
            ));
        }
    };
    decode(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Write one envelope to a `Framed` control wire (order 795-5itp).
///
/// The oversize pre-check is kept AHEAD of the sink on purpose. The codec
/// would also refuse the frame, but with `InvalidInput` and its own message;
/// this preserves the `outbound frame too large` / `InvalidData` surface that
/// 828-r2ek established and that this module's tests assert directly.
async fn write_framed_envelope<S>(sink: &mut S, env: &ControlEnvelope) -> io::Result<()>
where
    S: futures::Sink<bytes::Bytes, Error = io::Error> + Unpin,
{
    use futures::SinkExt;
    let bytes = encode(env).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "outbound frame too large",
        ));
    }
    sink.send(bytes.into()).await?;
    sink.flush().await
}

/// HAND-ROLLED READER, KEPT DELIBERATELY AND TEST-ONLY (order 795-5itp).
///
/// Production reading moved onto `Framed` above. This copy survives as the
/// INTEROP EVIDENCE the migration rests on: the tests in this module drive
/// the framed server with a peer that decodes `u32-BE length ‖ postcard` by
/// hand, so "the codec produces the bytes the old framing produced" is
/// asserted against an independent implementation rather than against
/// itself. Delete it and the interop claim becomes a tautology.
///
/// It is therefore an EXPLICIT EXCEPTION to this packet's closure scan
/// (at most one raw length decode among PRODUCTION sites), and the reason
/// above is the entry that exception list requires.
#[cfg(test)]
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
    // Order 828-r2ek: symmetric with read_envelope's bound above. Without this
    // the guest emits a frame the host is obliged to reject, so the connection
    // dies at the reader and the writer never learns why.
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "outbound frame too large",
        ));
    }
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

async fn write_envelope_with_shutdown<S>(
    sink: &mut S,
    env: &ControlEnvelope,
    shutdown: &mut watch::Receiver<bool>,
) -> io::Result<()>
where
    S: futures::Sink<bytes::Bytes, Error = io::Error> + Unpin,
{
    tokio::select! {
        result = write_framed_envelope(sink, env) => result,
        _ = connection_shutdown(shutdown) => Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "connection shutdown requested",
        )),
    }
}

/// Resolve the in-VM project bind-mount root from the environment.
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

/// 731-eupn: returns the list AND whether it is an ANSWER.
///
/// This is the wrapper the vsock server actually calls in the VM, and the
/// `Err` arm below already had the discriminator — it was being thrown away
/// one line before the host needed it. `Err` became `Vec::new()`, identical on
/// the wire to an account with no repos, and the tray rendered a confident
/// `(no repos)` for a containerized `gh` that had failed outright.
pub(crate) fn fetch_cloud_projects() -> (Vec<CloudProjectEntry>, CloudRefreshOutcome) {
    match crate::remote_projects::discover_github_projects_result_with_debug(false) {
        Ok(projects) => (
            projects
                .into_iter()
                .map(|p| CloudProjectEntry {
                    label: format!("{}/{}", p.owner, p.name),
                    owner: p.owner,
                    repo: p.name,
                    default_branch: String::new(),
                })
                .collect(),
            // An Ok with zero entries IS an answer: the account has no visible
            // repos. That is the one case where an empty list means something.
            CloudRefreshOutcome::Ok,
        ),
        Err(e) => {
            debug!(
                spec = "host-shell-architecture",
                error = %e,
                "CloudRefreshRequest (in-VM): containerized gh fetch failed; reporting FAILED, not empty"
            );
            (
                Vec::new(),
                CloudRefreshOutcome::Failed {
                    reason: format!("in-VM gh fetch failed: {e}"),
                },
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Order 828-r2ek NEGATIVE CONTROL: the guest refuses to EMIT a frame its
    /// own reader would refuse to accept.
    ///
    /// Before this, `read_envelope` bounded inbound frames at
    /// `MAX_MESSAGE_BYTES` and `write_envelope` bounded nothing — so the guest
    /// could put a frame on the wire that every peer in the fleet is obliged
    /// to reject. The connection then died at the READER, which is the wrong
    /// end to diagnose from: the writer saw a successful write and a closed
    /// socket, with nothing linking the two.
    #[tokio::test]
    async fn write_envelope_refuses_a_frame_over_the_shared_maximum() {
        let oversize = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::PtyData {
                session_id: 1,
                direction: tillandsias_control_wire::PtyDirection::ToHost,
                bytes: vec![0xCDu8; MAX_MESSAGE_BYTES + 1],
            },
        };
        let mut sink: Vec<u8> = Vec::new();
        let err = write_envelope(&mut sink, &oversize)
            .await
            .expect_err("a frame over MAX_MESSAGE_BYTES must be refused before it is written");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(
            sink.is_empty(),
            "the refusal must happen BEFORE any byte reaches the wire, got {} byte(s)",
            sink.len()
        );

        // And the boundary is inclusive: a frame at the maximum still goes.
        let mut payload = vec![0xCDu8; MAX_MESSAGE_BYTES - 64];
        let at_limit = loop {
            let candidate = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::PtyData {
                    session_id: 1,
                    direction: tillandsias_control_wire::PtyDirection::ToHost,
                    bytes: payload.clone(),
                },
            };
            match encode(&candidate).expect("encode").len() {
                n if n == MAX_MESSAGE_BYTES => break candidate,
                n if n < MAX_MESSAGE_BYTES => payload.push(0xCD),
                _ => panic!("overshot MAX_MESSAGE_BYTES while sizing the fixture"),
            }
        };
        let mut sink: Vec<u8> = Vec::new();
        write_envelope(&mut sink, &at_limit)
            .await
            .expect("a frame exactly at MAX_MESSAGE_BYTES must still be written");
        assert_eq!(sink.len(), 4 + MAX_MESSAGE_BYTES);
    }

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

    /// Order 137 (vsock-exec-chain-authn-authz): a gated-ON responder that
    /// receives a plaintext `Hello` — an unauthenticated / legacy peer, the
    /// exact client shape `plaintext_peer_is_rejected` models in
    /// tillandsias-secure-channel — must answer with a plaintext
    /// `Error{code: Unauthorized}` envelope naming the secure-channel
    /// requirement, must NEVER send `HelloAck`, and must then close the
    /// connection (fail-closed). The mode is injected via
    /// `handle_connection_with_mode` because `secure_control_wire_mode()`
    /// caches through a OnceLock and env mutation is process-wide.
    /// @trace plan/issues/encrypted-channel-vsock-cutover-2026-07-02.md
    #[tokio::test]
    async fn gated_on_plaintext_peer_gets_unauthorized_error_not_helloack() {
        let state = VmStateHandle::new();
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let server_task = tokio::spawn(handle_connection_with_mode(
            Ok(SecureControlWireMode::On),
            Box::new(server),
            state,
            shutdown_rx,
        ));

        // A plaintext Hello: exactly what a pre-secure-channel client (or a
        // probe replaying one) opens with.
        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::Hello {
                    from: "plaintext-legacy-client".to_string(),
                    capabilities: Vec::new(),
                    build_version: None,
                },
            },
        )
        .await
        .expect("plaintext client writes Hello");

        let reply = tokio::time::timeout(Duration::from_secs(2), read_envelope(&mut client))
            .await
            .expect("gated-ON responder must answer the rejected peer, not hang")
            .expect("responder sends one well-formed plaintext envelope before closing");
        match reply.body {
            ControlMessage::Error {
                code,
                message,
                seq_in_reply_to,
            } => {
                assert_eq!(
                    code,
                    ErrorCode::Unauthorized,
                    "the rejection envelope must carry ErrorCode::Unauthorized"
                );
                assert!(
                    message.contains("secure control wire required"),
                    "the message must name the secure-channel requirement, got {message:?}"
                );
                assert_eq!(seq_in_reply_to, None, "no plaintext frame was accepted");
            }
            ControlMessage::HelloAck { .. } => {
                panic!("gated-ON responder must never HelloAck an unauthenticated peer")
            }
            other => panic!("expected Error{{Unauthorized}}, got {other:?}"),
        }

        // Fail-closed: nothing is served after the notice — the next read
        // must observe the connection closing, never a HelloAck or any
        // other envelope.
        let after = tokio::time::timeout(Duration::from_secs(2), read_envelope(&mut client))
            .await
            .expect("connection must close after the Unauthorized notice");
        assert!(
            after.is_err(),
            "no envelope may follow the Unauthorized rejection, got {after:?}"
        );

        tokio::time::timeout(Duration::from_secs(2), server_task)
            .await
            .expect("handler must exit fail-closed")
            .expect("handler must not panic");
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

    /// Order 795-5itp: PIPELINED Hello+Subscribe must both survive the
    /// handshake-to-read-loop handoff.
    ///
    /// THIS TEST CANNOT FAIL AGAINST THE HAND-ROLLED READER IT WAS WRITTEN
    /// BESIDE, and that is stated rather than hidden: `read_exact` on the raw
    /// stream buffers nothing, so bytes that arrive early simply wait in the
    /// socket. It is a pin for the MIGRATION, not a red-first reproduction.
    ///
    /// What it guards: `Framed` OWNS a read buffer and fills it opportunistically
    /// — a single `read` can pull the Subscribe frame in alongside the Hello.
    /// Building a `Framed` for the handshake and then dropping it to reclaim the
    /// stream (or calling `tokio::io::split` on the raw stream afterwards)
    /// discards whatever the buffer already holds. No error, no log: the
    /// Subscribe is simply gone, the client waits forever for a SubscribeAck,
    /// and it only happens when the peer pipelines. Hand-falsified against
    /// exactly that naive shape before this migration landed.
    ///
    /// The two frames are written in ONE `write_all` so they are guaranteed to
    /// be available to a single read, which is what makes the buffer-loss
    /// window reachable at all.
    #[tokio::test]
    async fn pipelined_hello_and_subscribe_both_survive_the_handoff() {
        let state = VmStateHandle::new();
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let _server_task = tokio::spawn(handle_connection(
            Box::new(server),
            state.clone(),
            shutdown_rx,
        ));

        let hello = encode_frame_for_test(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 1,
            body: ControlMessage::Hello {
                from: "pipelining-client".to_string(),
                capabilities: Vec::new(),
                build_version: None,
            },
        });
        let subscribe = encode_frame_for_test(&ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 2,
            body: ControlMessage::Subscribe {
                topics: vec![tillandsias_control_wire::SubscriptionTopic::VmStatus],
            },
        });

        let mut both = hello;
        both.extend_from_slice(&subscribe);
        tokio::io::AsyncWriteExt::write_all(&mut client, &both)
            .await
            .expect("pipelined write");
        tokio::io::AsyncWriteExt::flush(&mut client)
            .await
            .expect("flush");

        // HelloAck first...
        let ack = tokio::time::timeout(Duration::from_secs(2), read_envelope(&mut client))
            .await
            .expect("HelloAck did not arrive")
            .expect("HelloAck decodes");
        assert!(
            matches!(ack.body, ControlMessage::HelloAck { .. }),
            "expected HelloAck, got {:?}",
            ack.body
        );

        // ...then the SubscribeAck for the frame that rode in behind it. This
        // is the assertion the whole test exists for: a dropped read buffer
        // makes this time out rather than fail loudly.
        let sub_ack = tokio::time::timeout(Duration::from_secs(2), read_envelope(&mut client))
            .await
            .expect("SubscribeAck did not arrive — a pipelined frame was swallowed at the handshake handoff")
            .expect("SubscribeAck decodes");
        assert!(
            matches!(sub_ack.body, ControlMessage::SubscribeAck),
            "expected SubscribeAck, got {:?}",
            sub_ack.body
        );
    }

    /// Frame an envelope the way a hand-rolled peer does, for tests that must
    /// control exactly how bytes hit the wire (rather than going through
    /// `write_envelope`, which writes the length and body separately).
    fn encode_frame_for_test(env: &ControlEnvelope) -> Vec<u8> {
        let body = encode(env).expect("encode");
        let mut out = (body.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(&body);
        out
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

    #[test]
    fn empty_vault_handover_reply_keeps_later_first_boot_retry_eligible() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/vsock_server.rs"));
        let handler = source
            .split("ControlMessage::GetVaultHandover { seq } =>")
            .nth(1)
            .and_then(|tail| tail.split("ControlMessage::").next())
            .expect("GetVaultHandover handler source");
        assert!(
            handler.contains("handover_reply_delivers_unseal_share(")
                && handler.contains("unseal_share_b64.as_deref()"),
            "the handler must classify actual share delivery before closing the retry window"
        );
        assert!(
            handler.contains("clear_pending_handover(delivered_unseal_share)"),
            "an empty timeout reply must not be recorded as a delivered handover"
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

    /// Audit D6 (order 493) at the connection-handler boundary: a PTY
    /// child that never reads its slave must not wedge the connection
    /// loop. The write path only ENQUEUES, bounded by the 250ms
    /// control-plane fairness deadline (spec "PTY-traffic does not starve
    /// control-plane envelopes"); on trip the session is killed
    /// (SIGTERM → pump → PtyClose on the wire, kill-not-drop) and a
    /// VmStatusRequest sent behind the write storm is still answered
    /// within the SC-09/SC-10 500ms bound. Pre-fix, `write_to_guest`
    /// blocked inline forever and this test would time out.
    /// @trace plan/issues/guest-pty-write-wedge-2026-07-27.md
    #[cfg(unix)]
    #[tokio::test]
    async fn pty_write_wedge_kills_session_and_keeps_control_plane_responsive() {
        let state = VmStateHandle::new();
        let (mut client, server) = tokio::io::duplex(1 << 20);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
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
                    from: "wedge-client".to_string(),
                    capabilities: vec![CAP_PTY_ATTACH_V1.into()],
                    build_version: None,
                },
            },
        )
        .await
        .expect("client writes Hello");
        assert!(matches!(
            read_envelope(&mut client).await.expect("HelloAck").body,
            ControlMessage::HelloAck { .. }
        ));

        // A child that never reads its slave (hermetic HOME as in the
        // pty_handler tests, so `-l` profile sourcing stays silent).
        let hermetic_home = std::env::temp_dir()
            .join(format!("tillandsias-wedge-vsock-{}", std::process::id()))
            .to_string_lossy()
            .into_owned();
        std::fs::create_dir_all(&hermetic_home).expect("hermetic HOME creates");
        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 2,
                body: ControlMessage::PtyOpen {
                    session_id: 9,
                    rows: 24,
                    cols: 80,
                    argv: vec![
                        "/bin/bash".to_string(),
                        "-lc".to_string(),
                        "sleep 30".to_string(),
                    ],
                    env: vec![("HOME".to_string(), hermetic_home)],
                    cwd: None,
                },
            },
        )
        .await
        .expect("client writes PtyOpen");

        // Saturate with 16 KiB frames of COMPLETE LINES (a real paste):
        // n_tty only backpressures the master once the canonical buffer
        // holds pending newlines — newline-free overflow is beeped away
        // instead of blocking. 32 frames (512 KiB) comfortably exceed the
        // kernel's ~68 KiB PTY buffering plus the in-flight write plus
        // the bounded queue, guaranteeing one enqueue trips the deadline.
        let frame: Vec<u8> = std::iter::repeat_with(|| {
            let mut line = vec![b'w'; 63];
            line.push(b'\n');
            line
        })
        .take(256)
        .flatten()
        .collect(); // 256 × 64-byte lines = 16 KiB per frame
        for i in 0..32u64 {
            write_envelope(
                &mut client,
                &ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: 100 + i,
                    body: ControlMessage::PtyData {
                        session_id: 9,
                        direction: tillandsias_control_wire::PtyDirection::ToGuest,
                        bytes: frame.clone(),
                    },
                },
            )
            .await
            .expect("client writes PtyData storm");
        }

        // Control-plane frame queued behind the storm must still be
        // answered within the fairness bound (one 250ms wedge trip max).
        let started = std::time::Instant::now();
        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 200,
                body: ControlMessage::VmStatusRequest { seq: 200 },
            },
        )
        .await
        .expect("client writes VmStatusRequest");

        let mut status_latency = None;
        let mut pty_close_exit = None;
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while (status_latency.is_none() || pty_close_exit.is_none())
            && std::time::Instant::now() < deadline
        {
            let env = tokio::time::timeout(Duration::from_secs(2), read_envelope(&mut client))
                .await
                .expect("frame within budget")
                .expect("stream stays open");
            match env.body {
                ControlMessage::VmStatusReply { .. } => {
                    status_latency = Some(started.elapsed());
                }
                ControlMessage::PtyClose { session_id, exit } => {
                    assert_eq!(session_id, 9);
                    pty_close_exit = Some(exit);
                }
                // Stray child output (e.g. profile noise) is fine.
                ControlMessage::PtyData { .. } => {}
                other => panic!("unexpected frame during wedge: {other:?}"),
            }
        }
        let latency = status_latency.expect("VmStatusReply while a PTY write storm wedges");
        assert!(
            latency < Duration::from_millis(500),
            "control plane exceeded the fairness bound: {latency:?}"
        );
        let exit = pty_close_exit.expect("wedged session must be killed and emit PtyClose");
        assert!(
            exit.signal.is_some() || exit.code != 0,
            "child should have been terminated by the kill path: {exit:?}"
        );

        server_task.abort();
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
                (
                    vec![CloudProjectEntry {
                        label: "octocat/tillandsias".to_string(),
                        owner: "octocat".to_string(),
                        repo: "tillandsias".to_string(),
                        default_branch: "main".to_string(),
                    }],
                    CloudRefreshOutcome::Ok,
                )
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

    /// Order 690-xeda: a probe loop parked on `subscriber_nudge` wakes when
    /// the first subscriber arrives (both nudging topics), so parking idle
    /// loops costs no subscriber-visible latency beyond the documented
    /// backstop.
    #[tokio::test]
    async fn subscriber_nudge_wakes_parked_waiter_on_subscribe() {
        use std::time::Duration;
        // 997-e4v2 step 3: local_projects is no longer a nudging topic; the
        // property is unchanged for the topics that remain.
        for topic in ["login_state"] {
            let state = VmStateHandle::new();
            let nudge = state.subscriber_nudge();
            let parked = tokio::spawn(async move { nudge.notified().await });
            // Let the waiter actually park before nudging: notify_waiters
            // wakes only CURRENT waiters (no stored permit).
            tokio::time::sleep(Duration::from_millis(50)).await;
            let _rx = state.subscribe_login_state();
            tokio::time::timeout(Duration::from_secs(2), parked)
                .await
                .unwrap_or_else(|_| panic!("{topic} subscribe must wake the parked waiter"))
                .expect("parked waiter task must not panic");
        }
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

    /// Order 333: the sampler → wire conversion is field-for-field, and the
    /// no-fabrication contract must survive it. A failed sample arrives on
    /// the wire with its `error` intact and every counter still `None` —
    /// never rewritten into a healthy-looking zero.
    #[test]
    fn metrics_wire_conversion_preserves_errors_and_none_counters() {
        let containers = vec![
            tillandsias_metrics::ContainerMetric {
                name: "tillandsias-proxy".to_string(),
                cpu_usec: Some(1234),
                memory_current_bytes: Some(4096),
                blkio_read_bytes: Some(10),
                blkio_write_bytes: Some(20),
                blkio_read_ops: Some(1),
                blkio_write_ops: Some(2),
                error: None,
            },
            tillandsias_metrics::ContainerMetric::error_only("podman", "spawn failed"),
        ];
        let mounts = vec![tillandsias_metrics::MountIoMetric {
            path: "/opt/cheatsheets".to_string(),
            device: None,
            read_bytes: None,
            write_bytes: None,
            read_ops: None,
            write_ops: None,
            error: Some("unavailable: tmpfs".to_string()),
        }];

        let wire = metrics_snapshot_wire(containers, mounts);

        assert_eq!(wire.containers.len(), 2);
        assert_eq!(wire.containers[0].name, "tillandsias-proxy");
        assert_eq!(wire.containers[0].cpu_usec, Some(1234));
        assert_eq!(wire.containers[0].blkio_write_ops, Some(2));
        assert!(wire.containers[0].error.is_none());

        let failed = &wire.containers[1];
        assert_eq!(failed.error.as_deref(), Some("spawn failed"));
        assert!(
            failed.cpu_usec.is_none()
                && failed.memory_current_bytes.is_none()
                && failed.blkio_read_bytes.is_none()
                && failed.blkio_write_bytes.is_none()
                && failed.blkio_read_ops.is_none()
                && failed.blkio_write_ops.is_none(),
            "a failed container sample must carry NO fabricated counters: {failed:?}"
        );

        assert_eq!(wire.mounts.len(), 1);
        assert_eq!(wire.mounts[0].path, "/opt/cheatsheets");
        assert_eq!(wire.mounts[0].error.as_deref(), Some("unavailable: tmpfs"));
        assert!(
            wire.mounts[0].read_bytes.is_none() && wire.mounts[0].write_ops.is_none(),
            "an unavailable mount must carry NO fabricated counters"
        );
    }

    /// Order 333: a `MetricsSnapshotRequest` over a live duplex connection
    /// gets a `MetricsSnapshotReply` correlated to its seq. Exercises the
    /// real handler arm end to end (samplers included — on a host with no
    /// cgroup/podman visibility they return error-carrying samples, which is
    /// precisely the contract being asserted: a reply, never a hang or a
    /// silent empty).
    #[tokio::test]
    async fn metrics_snapshot_request_gets_a_correlated_reply() {
        let state = VmStateHandle::new();
        let (mut client, server) = tokio::io::duplex(256 * 1024);
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        tokio::spawn(handle_connection_with_mode(
            Ok(SecureControlWireMode::Off),
            Box::new(server),
            state,
            shutdown_rx,
        ));

        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 1,
                body: ControlMessage::Hello {
                    from: "metrics-test-client".to_string(),
                    capabilities: Vec::new(),
                    build_version: None,
                },
            },
        )
        .await
        .expect("client writes Hello");
        let ack = read_envelope(&mut client).await.expect("HelloAck");
        match ack.body {
            ControlMessage::HelloAck { server_caps, .. } => {
                assert!(
                    server_caps.iter().any(|c| c == "MetricsSnapshotRequest"),
                    "guest must advertise MetricsSnapshotRequest: {server_caps:?}"
                );
                // 795-zshi slice 4. A host may only drop the `chmod 600` from
                // its exec preamble once the guest heals a widened CA key on
                // ensure_proxy_running's already-running EARLY-RETURN path.
                assert!(
                    server_caps
                        .iter()
                        .any(|c| c == tillandsias_control_wire::CAP_PROXY_CA_KEY_HEAL),
                    "guest must advertise {} so hosts can gate the preamble chmod on the \
                     BEHAVIOUR rather than on a neighbouring capability: {server_caps:?}",
                    tillandsias_control_wire::CAP_PROXY_CA_KEY_HEAL
                );
                // THE POINT OF A SEPARATE CAPABILITY, asserted rather than
                // commented: these two are distinct strings. CAP_EXEC_ARGV_VECTOR
                // shipped in cc4bee155 and the heal in d4e12b425 — two commits —
                // so a guest built in between advertises the argv cap WITHOUT the
                // heal. If someone later collapses them into one constant to
                // "simplify", this fails and the mixed-version argument has to be
                // re-made rather than silently lost, taking 772-shi9's clamp with
                // it on exactly the builds it protects.
                assert_ne!(
                    tillandsias_control_wire::CAP_PROXY_CA_KEY_HEAL,
                    tillandsias_control_wire::CAP_EXEC_ARGV_VECTOR,
                    "the CA-key-heal capability must not be aliased to the argv one — they \
                     shipped in different commits and do not imply each other"
                );
            }
            other => panic!("expected HelloAck, got {other:?}"),
        }

        write_envelope(
            &mut client,
            &ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 7,
                body: ControlMessage::MetricsSnapshotRequest { seq: 7 },
            },
        )
        .await
        .expect("client writes MetricsSnapshotRequest");

        let reply = tokio::time::timeout(Duration::from_secs(30), read_envelope(&mut client))
            .await
            .expect("guest must answer a metrics request, not hang")
            .expect("well-formed reply envelope");
        match reply.body {
            ControlMessage::MetricsSnapshotReply {
                seq_in_reply_to,
                snapshot,
            } => {
                assert_eq!(
                    seq_in_reply_to, 7,
                    "reply must correlate to the request seq"
                );
                assert_eq!(
                    snapshot.mounts.len(),
                    METRICS_MOUNT_PATHS.len(),
                    "every named hot path is reported (available or error-carrying)"
                );
                for mount in &snapshot.mounts {
                    assert!(
                        mount.error.is_some() || mount.device.is_some(),
                        "a mount sample is either resolved or explains itself: {mount:?}"
                    );
                }
            }
            other => panic!("expected MetricsSnapshotReply, got {other:?}"),
        }
    }
}
