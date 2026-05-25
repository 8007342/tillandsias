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
    ControlEnvelope, ControlMessage, ErrorCode, LocalProjectEntry, MAX_MESSAGE_BYTES, VmPhase,
    WIRE_VERSION, decode, encode,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::{debug, info, warn};

const SERVER_NAME: &str = "tillandsias-in-vm";

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
/// Default is `Ready` (the listener is bound and serving = the VM is up).
/// Other phases are set by lifecycle hooks elsewhere in the binary.
///
/// @trace spec:vsock-transport, spec:vm-provisioning-lifecycle, plan/issues/multi-host-integration-loop-2026-05-24.md (l4)
#[derive(Debug, Clone)]
pub struct VmStateHandle {
    phase: Arc<RwLock<VmPhase>>,
    podman_socket: PathBuf,
}

impl VmStateHandle {
    /// Construct with default `Ready` phase and the conventional podman
    /// socket path. Tests and lifecycle hooks may use [`set_phase`] /
    /// [`set_podman_socket`] to drive transitions.
    pub fn new() -> Self {
        Self {
            phase: Arc::new(RwLock::new(VmPhase::Ready)),
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
    pub fn set_podman_socket(&mut self, path: PathBuf) {
        self.podman_socket = path;
    }

    /// Check whether podman is reachable. Cheap: just looks for the
    /// socket file. The host tray uses this to disable project-attach
    /// menu items until podman is actually up.
    pub fn podman_ready(&self) -> bool {
        self.podman_socket.exists()
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

async fn serve_listener(
    listener: &mut Listener,
    shutdown: Arc<AtomicBool>,
    state: VmStateHandle,
) {
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
            ],
        },
    };
    if let Err(err) = write_envelope(&mut stream, &ack).await {
        warn!(spec = "vsock-transport", error = %err, "failed to write HelloAck");
        return;
    }

    loop {
        let env = match read_envelope(&mut stream).await {
            Ok(env) => env,
            Err(err) => {
                debug!(spec = "vsock-transport", error = %err, "vsock connection closed");
                return;
            }
        };
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
                // l4 (deferred): real implementation invokes `gh repo list
                // --json owner,name,defaultBranchRef` as a subprocess.
                // The in-VM `gh` reads the GitHub token from
                // `/run/secrets/vault-token` (mounted by the host shell on
                // container launch) and the result is parsed into
                // CloudProjectEntry. Until that subprocess + token wiring is
                // in place we return an empty list with the existing schema
                // so the host tray can still issue the request and render an
                // empty cloud-projects section.
                //
                // @trace spec:host-shell-architecture, spec:tillandsias-vault, plan/issues/multi-host-integration-loop-2026-05-24.md l4
                let reply = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::CloudRefreshReply {
                        seq_in_reply_to: seq,
                        projects: Vec::new(),
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
                return;
            }
            // Per plan/issues/control-socket-protocol-convergence-2026-05-25.md:
            // unhandled variants must reply with an explicit Error frame
            // (Unsupported) instead of silently logging and continuing.
            // Clients otherwise hang waiting for a reply they will never get.
            other => {
                debug!(spec = "vsock-transport", msg = ?other, "rejecting unsupported vsock frame");
                let err = ControlEnvelope {
                    wire_version: WIRE_VERSION,
                    seq: env.seq,
                    body: ControlMessage::Error {
                        seq_in_reply_to: Some(env.seq),
                        code: ErrorCode::Unsupported,
                        message: format!(
                            "variant {:?} not handled by the in-VM vsock dispatcher",
                            std::mem::discriminant(&other),
                        ),
                    },
                };
                if write_envelope(&mut stream, &err).await.is_err() {
                    return;
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
    let bytes =
        encode(env).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
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

/// Enumerate the in-VM project bind-mount root and return one entry per
/// visible directory. Hidden entries (leading dot) and non-directories
/// are skipped. `last_seen_unix` is the directory's mtime.
///
/// Cheap by design: a single `read_dir` + per-entry `metadata`. The host
/// tray re-issues this on user-visible events, not on a tight loop.
///
/// @trace spec:host-shell-architecture, plan/issues/multi-host-integration-loop-2026-05-24.md l4
fn enumerate_local_projects() -> Vec<LocalProjectEntry> {
    let root = in_vm_project_root();
    let Ok(entries) = std::fs::read_dir(&root) else {
        debug!(
            spec = "host-shell-architecture",
            root = %root.display(),
            "EnumerateLocalProjects: project root not readable; returning empty"
        );
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let last_seen_unix = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        out.push(LocalProjectEntry {
            label: name.to_string(),
            guest_path: path.to_string_lossy().into_owned(),
            last_seen_unix,
        });
    }
    out.sort_by(|a, b| a.label.cmp(&b.label));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vm_state_handle_defaults_to_ready() {
        let state = VmStateHandle::new();
        assert_eq!(state.current_phase(), VmPhase::Ready);
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
