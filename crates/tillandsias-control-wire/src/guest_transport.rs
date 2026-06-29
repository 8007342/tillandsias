// @trace spec:host-guest-transport
//! Host↔guest transport facade (order 124).
//!
//! The single, platform-agnostic contract for reaching the guest from the host.
//! Callers ask for one of two primitives and never branch on `cfg!(target_os)`:
//!
//! - [`GuestTransport::open_stream`] — **InteractiveStream**: a long-lived
//!   bidirectional byte stream for PTY/attach sessions.
//! - [`GuestTransport::exec`] / [`GuestTransport::exec_streaming`] —
//!   **ExecOneShot**: a run-to-completion command for quick interactions and
//!   one-off reads (status probes, single secret reads, `gh api`-style calls).
//!
//! The contract (this trait + the value types below) lives in `control-wire`
//! alongside the wire protocol; the per-platform **backends** implement it where
//! the platform code lives (Linux AF_VSOCK + Unix here under the `vsock`
//! feature; macOS VZ virtio-vsock and Windows WSL/hvsock in `tillandsias-vm-layer`).
//! Both primitives ride the existing framing (`encode`/`decode`, `WIRE_VERSION`,
//! `MAX_MESSAGE_BYTES`, `Hello`/`HelloAck`) — one protocol for every transport.
//!
//! Nomenclature is canonical here: `vsock` is the protocol family; `virtio-vsock`,
//! `hvsock`, and `VZVirtioSocketDevice` are backend implementation names only —
//! they never appear in this public API.
//!
//! @trace spec:vsock-transport, spec:vm-idiomatic-layer
//! @trace plan/issues/host-guest-transport-normalization-spec-2026-06-28.md

use crate::transport::AsyncReadWrite;
use std::io;
use std::path::PathBuf;

/// Where and how to reach the guest. Constructed once at the platform boundary;
/// callers pass it to a [`GuestTransport`] without inspecting the variant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuestEndpoint {
    /// Same-host headless over a Unix socket (any OS).
    Unix(PathBuf),
    /// Linux AF_VSOCK (host → guest VM).
    Vsock { cid: u32, port: u32 },
    /// macOS Virtualization.framework virtio-vsock; the CID is resolved by the
    /// macOS backend, so only the logical `port` is carried here.
    MacVz { port: u32 },
    /// Windows WSL2; the pipe/hvsock address is resolved by the Windows backend.
    Wsl { port: u32 },
}

impl GuestEndpoint {
    /// The logical control-wire port this endpoint targets (where applicable).
    pub fn port(&self) -> Option<u32> {
        match self {
            GuestEndpoint::Unix(_) => None,
            GuestEndpoint::Vsock { port, .. } => Some(*port),
            GuestEndpoint::MacVz { port } => Some(*port),
            GuestEndpoint::Wsl { port } => Some(*port),
        }
    }
}

/// An ExecOneShot request: the argv to run in the guest, plus optional stdin.
#[derive(Debug, Clone, Default)]
pub struct ExecRequest {
    pub argv: Vec<String>,
    pub stdin: Option<Vec<u8>>,
}

impl ExecRequest {
    /// Build a request from a borrowed argv (the common call shape).
    pub fn new(argv: &[&str]) -> Self {
        ExecRequest {
            argv: argv.iter().map(|s| s.to_string()).collect(),
            stdin: None,
        }
    }

    /// Attach stdin bytes (e.g. a token piped to `gh auth login --with-token`).
    pub fn with_stdin(mut self, stdin: Vec<u8>) -> Self {
        self.stdin = Some(stdin);
        self
    }
}

/// The result of an ExecOneShot run.
#[derive(Debug, Clone, Default)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_code: i32,
}

impl ExecOutput {
    /// `true` iff the command exited 0.
    pub fn success(&self) -> bool {
        self.exit_code == 0
    }

    /// Stdout decoded lossily as UTF-8 and trimmed — the common "one-off read" path.
    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).trim().to_string()
    }
}

/// An incremental chunk delivered by [`GuestTransport::exec_streaming`].
#[derive(Debug, Clone)]
pub enum ExecChunk {
    Stdout(Vec<u8>),
    Stderr(Vec<u8>),
}

/// The platform-agnostic host→guest transport. One implementation per platform
/// backend; resolved once at the boundary and used as `Box<dyn GuestTransport>`.
#[async_trait::async_trait]
pub trait GuestTransport: Send + Sync {
    /// InteractiveStream: open a long-lived bidirectional byte stream.
    async fn open_stream(
        &self,
        ep: &GuestEndpoint,
    ) -> io::Result<Box<dyn AsyncReadWrite + Unpin + Send>>;

    /// ExecOneShot: run `req` to completion and return its output.
    async fn exec(&self, ep: &GuestEndpoint, req: ExecRequest) -> io::Result<ExecOutput>;

    /// ExecOneShot with incremental stdout/stderr delivery via `on_chunk`.
    async fn exec_streaming(
        &self,
        ep: &GuestEndpoint,
        req: ExecRequest,
        on_chunk: &mut (dyn FnMut(ExecChunk) + Send),
    ) -> io::Result<ExecOutput>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_request_builders() {
        let r = ExecRequest::new(&["gh", "api", "user"]).with_stdin(b"tok".to_vec());
        assert_eq!(r.argv, vec!["gh", "api", "user"]);
        assert_eq!(r.stdin.as_deref(), Some(&b"tok"[..]));
    }

    #[test]
    fn exec_output_helpers() {
        let mut o = ExecOutput {
            stdout: b"  hello\n".to_vec(),
            ..Default::default()
        };
        assert!(o.success());
        assert_eq!(o.stdout_text(), "hello");
        o.exit_code = 1;
        assert!(!o.success());
    }

    #[test]
    fn endpoint_port_accessor() {
        assert_eq!(GuestEndpoint::Vsock { cid: 3, port: 7 }.port(), Some(7));
        assert_eq!(GuestEndpoint::MacVz { port: 7 }.port(), Some(7));
        assert_eq!(GuestEndpoint::Wsl { port: 7 }.port(), Some(7));
        assert_eq!(GuestEndpoint::Unix(PathBuf::from("/x")).port(), None);
    }

    /// The trait must be object-safe (used as `Box<dyn GuestTransport>` at the
    /// platform boundary). This fn fails to compile if object-safety regresses.
    #[allow(dead_code)]
    fn is_object_safe(_t: &dyn GuestTransport) {}
}
