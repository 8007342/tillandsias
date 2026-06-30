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
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tillandsias_control_wire::transport::{
    AsyncReadWrite, CONTROL_WIRE_VSOCK_PORT, Listener, Transport, bind,
};
use tillandsias_control_wire::{
    CAP_PTY_ATTACH_V1, CloudProjectEntry, ControlEnvelope, ControlMessage, ErrorCode,
    LocalProjectEntry, MAX_MESSAGE_BYTES, VmPhase, WIRE_VERSION, decode, encode,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

#[cfg(unix)]
use crate::pty_handler::PtySessionStore;

const SERVER_NAME: &str = "tillandsias-in-vm";

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
#[derive(Debug, Clone)]
pub struct VmStateHandle {
    phase: Arc<RwLock<VmPhase>>,
    podman_socket: PathBuf,
}

impl VmStateHandle {
    /// Construct with default `Starting` phase and the conventional podman
    /// socket path. Tests and lifecycle hooks may use [`set_phase`] /
    /// [`set_podman_socket`] to drive transitions.
    pub fn new() -> Self {
        Self {
            phase: Arc::new(RwLock::new(VmPhase::Starting)),
            podman_socket: PathBuf::from(IN_VM_PODMAN_SOCKET_DEFAULT),
        }
    }

    /// Update the reported phase. The vsock handler reads this on every
    /// `VmStatusRequest`. Safe to call from any task.
    pub fn set_phase(&self, phase: VmPhase) {
        if let Ok(mut guard) = self.phase.write() {
            *guard = phase;
        }
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
    loop {
        if shutdown.load(Ordering::SeqCst) {
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
                tokio::spawn(handle_connection(stream, state.clone()));
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
    mut stream: Box<dyn AsyncReadWrite + Unpin + Send>,
    state: VmStateHandle,
) {
    let first = match read_envelope(&mut stream).await {
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

    let hello_from = match &first.body {
        ControlMessage::Hello { from, .. } => from.clone(),
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
            ],
        },
    };
    if let Err(err) = write_envelope(&mut stream, &ack).await {
        warn!(spec = "vsock-transport", error = %err, "failed to write HelloAck");
        return;
    }

    // Per-connection PTY session store (l3: control-wire-pty-attach Tasks 4.x).
    // The pump tasks for each PTY session push envelopes into `pty_outbound`;
    // the main read loop interleaves those writes with normal request/reply
    // traffic via tokio::select!. When this function returns, dropping
    // `pty_store` cascades into `shutdown_all` so children are reaped on
    // disconnect.
    let (pty_tx, mut pty_rx) = mpsc::unbounded_channel::<ControlEnvelope>();
    #[cfg(unix)]
    let mut pty_store = PtySessionStore::new(pty_tx.clone());
    // Hold a tx clone so the sender side stays open for the lifetime of
    // the connection even if `pty_store` empties (which would otherwise
    // close pty_rx).
    let _pty_tx_keepalive = pty_tx;

    loop {
        tokio::select! {
            // Outbound PTY frame (PtyData{ToHost} from a pump or PtyClose
            // from child reap).
            Some(env) = pty_rx.recv() => {
                if write_envelope(&mut stream, &env).await.is_err() {
                    debug!(spec = "vsock-transport", "vsock write failed during PTY outbound; closing connection");
                    #[cfg(unix)]
                    pty_store.shutdown_all().await;
                    return;
                }
                continue;
            }
            // Inbound frame.
            result = read_envelope(&mut stream) => {
                let env = match result {
                    Ok(env) => env,
                    Err(err) => {
                        debug!(spec = "vsock-transport", error = %err, "vsock connection closed");
                        #[cfg(unix)]
                        pty_store.shutdown_all().await;
                        return;
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
                        if write_envelope(&mut stream, &err).await.is_err() {
                            #[cfg(unix)]
                            pty_store.shutdown_all().await;
                            return;
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
                        if write_envelope(&mut stream, &err).await.is_err() {
                            #[cfg(unix)]
                            pty_store.shutdown_all().await;
                            return;
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
                        last_event: Some(SERVER_NAME.to_string()),
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
                }
            }
            ControlMessage::EnumerateLocalProjects { seq } => {
                // l4: scan the bind-mount root for real project entries.
                let entries = enumerate_local_projects();
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::LocalProjectsReply {
                        seq_in_reply_to: seq,
                        entries,
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
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
                let projects = fetch_cloud_projects();
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::CloudRefreshReply {
                        seq_in_reply_to: seq,
                        projects,
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
                }
            }
            ControlMessage::GithubLoginStatusRequest { seq } => {
                // Probe GitHub auth end-to-end inside a container — no raw
                // token is read into the vsock server process.
                let handle = crate::remote_projects::probe_github_username(false);
                let logged_in = handle.is_some();
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::GithubLoginStatusReply {
                        seq_in_reply_to: seq,
                        logged_in,
                        handle,
                    },
                };
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
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
                #[cfg(unix)]
                pty_store.shutdown_all().await;
                return;
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
                    if write_envelope(&mut stream, &err_env).await.is_err() {
                        pty_store.shutdown_all().await;
                        return;
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
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
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
                if write_envelope(&mut stream, &reply).await.is_err() {
                    return;
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
                if write_envelope(&mut stream, &err).await.is_err() {
                    #[cfg(unix)]
                    pty_store.shutdown_all().await;
                    return;
                }
            }
                }
            }
        }
    }
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
fn enumerate_local_projects() -> Vec<LocalProjectEntry> {
    let root = in_vm_project_root();
    let out = crate::local_projects::scan_project_root(&root);
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
fn fetch_cloud_projects() -> Vec<CloudProjectEntry> {
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

    // (parse_gh_repo_list tests moved to crate::cloud_projects with the
    // function itself. The vsock-side fetch_cloud_projects wrapper is
    // now a thin token-read shim, not worth a separate test target.)

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

        // SAFETY: tests in this binary may run concurrently; this env var is
        // owned by `enumerate_local_projects` only, no other test reads or
        // writes it.
        unsafe {
            std::env::set_var(IN_VM_PROJECT_ROOT_ENV, tmp.path());
        }
        let entries = enumerate_local_projects();
        unsafe {
            std::env::remove_var(IN_VM_PROJECT_ROOT_ENV);
        }

        let labels: Vec<&str> = entries.iter().map(|e| e.label.as_str()).collect();
        assert_eq!(labels, vec!["alpha", "beta"]);
    }

    #[test]
    fn enumerate_local_projects_returns_empty_when_root_missing() {
        unsafe {
            std::env::set_var(
                IN_VM_PROJECT_ROOT_ENV,
                "/this/dir/intentionally/does/not/exist/under/tillandsias",
            );
        }
        let entries = enumerate_local_projects();
        unsafe {
            std::env::remove_var(IN_VM_PROJECT_ROOT_ENV);
        }
        assert!(entries.is_empty());
    }
}
