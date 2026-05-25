//! Host-side PTY-over-vsock session multiplexing — cross-platform core
//! (`control-wire-pty-attach` §3). Shared / co-owned by the Windows (ConPTY)
//! and macOS (AppKit Terminal) trays.
//!
//! This module is the protocol-correct, OS-agnostic half: per-connection
//! `session_id` allocation (§D2), host→guest stdin framing capped at
//! `MAX_PTY_FRAME_BYTES` (§D5), inbound guest→host routing by `session_id`
//! with a per-session bounded channel (§3.7 / §D3), and the [`PtySession`]
//! handle that builds `PtyOpen` / `PtyData` / `PtyResize` / `PtyClose`
//! envelopes over an abstract [`PtyTransport`].
//!
//! The real OS PTY backends (Windows ConPTY in `pty::windows`, Unix
//! `openpty` in `pty::unix`) and the `pump_io` tasks that bridge a live
//! terminal master fd to [`PtySession::write_to_guest`] / [`PtySession::recv`]
//! layer on top — they are the next increment. This core is fully testable
//! with a fake transport (no real PTY, no VM).
//!
//! @trace openspec/changes/control-wire-pty-attach/proposal.md, spec:vsock-transport

#![allow(dead_code)]

/// Windows ConPTY backend (§3.3). The `windows` crate dep is target-gated.
#[cfg(windows)]
pub mod windows;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

use tillandsias_control_wire::{ControlMessage, MAX_PTY_FRAME_BYTES, PtyDirection, PtyExit};

use crate::menu_state::SelectedAgent;

/// Already-rendered error context — matches the crate's String-error idiom.
pub type PtyError = String;

/// Per-session inbound channel capacity (§D3): ~256 frames pending before the
/// host PTY reader is expected to backpressure via OS pipe semantics.
pub const SESSION_CHANNEL_CAPACITY: usize = 256;

/// Inputs to open a PTY-attached subprocess inside the VM. Mirrors the
/// `PtyOpen` wire fields; `env` REPLACES the in-VM environment (no host-env
/// leak), `cwd` sets the initial directory, `argv[0]` is the executable.
#[derive(Debug, Clone)]
pub struct PtyOpenOpts {
    pub rows: u16,
    pub cols: u16,
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<String>,
}

/// What a tray menu action wants to run in the in-VM PTY. Shared across the
/// Windows (ConPTY) and macOS (AppKit Terminal) trays so the OpenShell /
/// GitHub-login / agent commands stay identical everywhere.
///
/// PROPOSED cross-host contract (windows-next, 2026-05-25) — see
/// plan/issues/tray-convergence-coordination.md; macOS m4 should adopt or amend
/// the argv mapping rather than diverge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PtyIntent {
    /// "Open Shell" — an interactive login shell in the forge.
    Shell,
    /// "GitHub login" — the `gh` device-code flow inside the VM.
    GithubLogin,
    /// Launch the selected coding agent via the forge entrypoint.
    Agent(SelectedAgent),
}

fn agent_flag(agent: SelectedAgent) -> &'static str {
    match agent {
        SelectedAgent::Claude => "--claude",
        SelectedAgent::Codex => "--codex",
        SelectedAgent::OpenCode => "--opencode",
    }
}

/// Build the [`PtyOpenOpts`] for a tray PTY `intent` at the given terminal
/// size. `env` carries only `TERM` (the in-VM handler `env_clear`s before
/// applying it, so no host env leaks); the login shell + forge set `PATH` etc.
/// `cwd` is left to the in-VM default (the project working tree).
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md (§3, host launch mapping)
pub fn launch_spec(intent: &PtyIntent, rows: u16, cols: u16) -> PtyOpenOpts {
    let argv = match intent {
        PtyIntent::Shell => vec!["/bin/bash".to_string(), "-l".to_string()],
        PtyIntent::GithubLogin => {
            vec!["gh".to_string(), "auth".to_string(), "login".to_string()]
        }
        PtyIntent::Agent(agent) => {
            vec!["tillandsias".to_string(), agent_flag(*agent).to_string()]
        }
    };
    PtyOpenOpts {
        rows,
        cols,
        argv,
        env: vec![("TERM".to_string(), "xterm-256color".to_string())],
        cwd: None,
    }
}

/// Outbound side of the control wire: wrap `body` in a `ControlEnvelope`
/// (assigning the connection's monotonic `seq`) and send it to the in-VM
/// headless. Abstracted so the session logic is testable without a real
/// vsock connection.
pub trait PtyTransport: Send + Sync {
    fn send(&self, body: ControlMessage) -> Result<(), PtyError>;
}

/// A [`PtyTransport`] that enqueues outbound control messages onto a bounded
/// channel — the per-connection writer queue from §D3. The connection's writer
/// task drains the paired receiver and sends each via the vsock `Client`,
/// interleaving with control traffic. A full queue surfaces as a backpressure
/// error so the host PTY reader slows (rather than blocking the connection).
///
/// @trace openspec/changes/control-wire-pty-attach/proposal.md (§D3)
pub struct ChannelPtyTransport {
    tx: mpsc::Sender<ControlMessage>,
}

impl ChannelPtyTransport {
    /// Create the transport and the receiver the connection writer task drains.
    pub fn new(capacity: usize) -> (Self, mpsc::Receiver<ControlMessage>) {
        let (tx, rx) = mpsc::channel(capacity);
        (Self { tx }, rx)
    }
}

impl PtyTransport for ChannelPtyTransport {
    fn send(&self, body: ControlMessage) -> Result<(), PtyError> {
        self.tx.try_send(body).map_err(|e| match e {
            mpsc::error::TrySendError::Full(_) => {
                "pty outbound queue full (backpressure)".to_string()
            }
            mpsc::error::TrySendError::Closed(_) => "pty connection closed".to_string(),
        })
    }
}

/// Host-allocated, per-connection monotonic `session_id`s, starting at 1 (§D2).
#[derive(Debug, Default)]
pub struct SessionIdAllocator(AtomicU32);

impl SessionIdAllocator {
    pub fn new() -> Self {
        Self(AtomicU32::new(0))
    }
    /// The next session id for this connection (1, 2, 3, …).
    pub fn next_id(&self) -> u32 {
        self.0.fetch_add(1, Ordering::Relaxed) + 1
    }
}

/// An inbound event for a session: terminal output, or the terminal close.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEvent {
    /// Guest → host terminal bytes (stdout/stderr).
    Data(Vec<u8>),
    /// The in-VM child exited (or the host requested close and the guest
    /// confirmed). Terminal — no further events for this session.
    Closed(PtyExit),
}

/// Split host→guest stdin into `PtyData{ToGuest}` frames, each
/// `<= MAX_PTY_FRAME_BYTES` (§D5). Empty input yields no frames.
pub fn chunk_to_guest(session_id: u32, bytes: &[u8]) -> Vec<ControlMessage> {
    bytes
        .chunks(MAX_PTY_FRAME_BYTES.max(1))
        .map(|c| ControlMessage::PtyData {
            session_id,
            direction: PtyDirection::ToGuest,
            bytes: c.to_vec(),
        })
        .collect()
}

/// Routes inbound guest→host envelopes to per-session channels by
/// `session_id` (§3.4 / §D3). One per vsock connection.
#[derive(Default)]
pub struct PtyRouter {
    sessions: Mutex<HashMap<u32, mpsc::Sender<SessionEvent>>>,
}

impl PtyRouter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a session and return the receiver the host terminal drains.
    pub fn register(&self, session_id: u32) -> mpsc::Receiver<SessionEvent> {
        let (tx, rx) = mpsc::channel(SESSION_CHANNEL_CAPACITY);
        self.sessions.lock().unwrap().insert(session_id, tx);
        rx
    }

    /// Drop a session's routing (e.g. on host-initiated close).
    pub fn forget(&self, session_id: u32) {
        self.sessions.lock().unwrap().remove(&session_id);
    }

    /// Route one inbound message. `PtyData{ToHost}` → the session's channel;
    /// `PtyClose` → a terminal `Closed` event (and the route is removed).
    /// Returns `Err` on an oversized `PtyData` frame (protocol violation);
    /// non-PTY messages and unknown session ids are ignored.
    pub fn route(&self, msg: &ControlMessage) -> Result<(), PtyError> {
        match msg {
            ControlMessage::PtyData {
                session_id,
                direction: PtyDirection::ToHost,
                bytes,
            } => {
                if bytes.len() > MAX_PTY_FRAME_BYTES {
                    return Err(format!(
                        "inbound PtyData frame {} exceeds MAX_PTY_FRAME_BYTES {}",
                        bytes.len(),
                        MAX_PTY_FRAME_BYTES
                    ));
                }
                if let Some(tx) = self.sessions.lock().unwrap().get(session_id) {
                    // try_send: a full session channel applies backpressure to
                    // the guest via the connection reader (§D3); we never block
                    // the router on one slow session.
                    let _ = tx.try_send(SessionEvent::Data(bytes.clone()));
                }
                Ok(())
            }
            ControlMessage::PtyClose { session_id, exit } => {
                if let Some(tx) = self.sessions.lock().unwrap().remove(session_id) {
                    let _ = tx.try_send(SessionEvent::Closed(*exit));
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }
}

/// A host-side PTY session: the handle the tray drives to talk to one
/// in-VM PTY-attached subprocess. Built by [`PtySession::open`]; output +
/// close arrive via [`PtySession::recv`].
pub struct PtySession {
    pub session_id: u32,
    transport: Arc<dyn PtyTransport>,
    inbound: mpsc::Receiver<SessionEvent>,
}

impl PtySession {
    /// Allocate a session id, register inbound routing, and send `PtyOpen`
    /// (§3.1). Fails fast on an empty `argv`.
    pub fn open(
        transport: Arc<dyn PtyTransport>,
        alloc: &SessionIdAllocator,
        router: &PtyRouter,
        opts: &PtyOpenOpts,
    ) -> Result<PtySession, PtyError> {
        if opts.argv.is_empty() {
            return Err("PtyOpen requires a non-empty argv".to_string());
        }
        let session_id = alloc.next_id();
        let inbound = router.register(session_id);
        transport.send(ControlMessage::PtyOpen {
            session_id,
            rows: opts.rows,
            cols: opts.cols,
            argv: opts.argv.clone(),
            env: opts.env.clone(),
            cwd: opts.cwd.clone(),
        })?;
        Ok(PtySession {
            session_id,
            transport,
            inbound,
        })
    }

    /// Send stdin to the guest child, chunked to `MAX_PTY_FRAME_BYTES` (§D5).
    pub fn write_to_guest(&self, bytes: &[u8]) -> Result<(), PtyError> {
        for body in chunk_to_guest(self.session_id, bytes) {
            self.transport.send(body)?;
        }
        Ok(())
    }

    /// Relay a terminal resize to the guest (§3.5).
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), PtyError> {
        self.transport.send(ControlMessage::PtyResize {
            session_id: self.session_id,
            rows,
            cols,
        })
    }

    /// Host-initiated close (§3.6): tell the guest to terminate the child.
    pub fn close(&self, exit: PtyExit) -> Result<(), PtyError> {
        self.transport.send(ControlMessage::PtyClose {
            session_id: self.session_id,
            exit,
        })
    }

    /// Await the next inbound event (guest output or terminal close). Returns
    /// `None` once the router drops the session and the channel closes.
    pub async fn recv(&mut self) -> Option<SessionEvent> {
        self.inbound.recv().await
    }
}

/// A host-side PTY master (the local terminal end). The OS backends —
/// `pty::windows::ConPtyMaster` and the Unix `openpty` master — implement this
/// by yielding an async read half (local keystrokes → guest stdin) and an
/// async write half (guest output → local terminal). Splitting up front lets
/// [`pump_io`] drive both directions concurrently.
pub trait PtyMaster: Send + 'static {
    type Reader: tokio::io::AsyncRead + Send + Unpin + 'static;
    type Writer: tokio::io::AsyncWrite + Send + Unpin + 'static;
    fn split(self) -> (Self::Reader, Self::Writer);
}

/// Bridge a host PTY `master` to a `session` over vsock (§3.4):
/// - local terminal input (master reader) → `PtyData{ToGuest}` frames;
/// - inbound `PtyData{ToHost}` / `PtyClose` → master writer (terminal output).
///
/// Consumes both. Returns the join handle of the output→terminal task; it
/// completes when the session closes (guest `PtyClose`) or the connection
/// drops, at which point the input task is aborted.
pub fn pump_io<M: PtyMaster>(session: PtySession, master: M) -> tokio::task::JoinHandle<()> {
    let (mut reader, mut writer) = master.split();
    let PtySession {
        session_id,
        transport,
        mut inbound,
    } = session;

    // Input task: local keystrokes → guest stdin (chunked at MAX_PTY_FRAME_BYTES).
    let input_task = tokio::spawn(async move {
        let mut buf = vec![0u8; MAX_PTY_FRAME_BYTES];
        loop {
            match reader.read(&mut buf).await {
                Ok(0) | Err(_) => break, // EOF / closed terminal
                Ok(n) => {
                    for body in chunk_to_guest(session_id, &buf[..n]) {
                        if transport.send(body).is_err() {
                            return;
                        }
                    }
                }
            }
        }
    });

    // Output task: guest output → local terminal; terminal close ends both.
    tokio::spawn(async move {
        while let Some(ev) = inbound.recv().await {
            match ev {
                SessionEvent::Data(bytes) => {
                    if writer.write_all(&bytes).await.is_err() {
                        break;
                    }
                }
                SessionEvent::Closed(_) => break,
            }
        }
        input_task.abort();
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeTransport {
        sent: Mutex<Vec<ControlMessage>>,
    }
    impl PtyTransport for FakeTransport {
        fn send(&self, body: ControlMessage) -> Result<(), PtyError> {
            self.sent.lock().unwrap().push(body);
            Ok(())
        }
    }

    fn opts(argv: &str) -> PtyOpenOpts {
        PtyOpenOpts {
            rows: 24,
            cols: 80,
            argv: vec![argv.to_string()],
            env: vec![],
            cwd: None,
        }
    }

    #[test]
    fn session_ids_are_monotonic_from_one() {
        let a = SessionIdAllocator::new();
        assert_eq!([a.next_id(), a.next_id(), a.next_id()], [1, 2, 3]);
    }

    #[test]
    fn chunking_caps_at_max_frame() {
        assert!(chunk_to_guest(1, b"").is_empty());
        assert_eq!(chunk_to_guest(1, b"hello").len(), 1);
        let big = chunk_to_guest(7, &vec![0u8; MAX_PTY_FRAME_BYTES * 2 + 10]);
        assert_eq!(big.len(), 3, "two full frames + remainder");
        for m in &big {
            match m {
                ControlMessage::PtyData {
                    session_id,
                    direction,
                    bytes,
                } => {
                    assert_eq!(*session_id, 7);
                    assert_eq!(*direction, PtyDirection::ToGuest);
                    assert!(bytes.len() <= MAX_PTY_FRAME_BYTES);
                }
                other => panic!("expected PtyData, got {other:?}"),
            }
        }
    }

    #[test]
    fn empty_argv_is_rejected() {
        let t = Arc::new(FakeTransport::default());
        let r = PtyRouter::new();
        let a = SessionIdAllocator::new();
        let bad = PtyOpenOpts {
            rows: 24,
            cols: 80,
            argv: vec![],
            env: vec![],
            cwd: None,
        };
        assert!(PtySession::open(t, &a, &r, &bad).is_err());
    }

    /// §3.8: open / write / resize / close roundtrip over a fake transport.
    #[tokio::test]
    async fn open_write_resize_close_roundtrip() {
        let t = Arc::new(FakeTransport::default());
        let r = PtyRouter::new();
        let a = SessionIdAllocator::new();

        let mut s = PtySession::open(t.clone(), &a, &r, &opts("/bin/bash")).expect("open");
        assert_eq!(s.session_id, 1);
        s.write_to_guest(b"echo hi\n").unwrap();
        s.resize(30, 100).unwrap();

        // Guest output is routed to the session.
        r.route(&ControlMessage::PtyData {
            session_id: 1,
            direction: PtyDirection::ToHost,
            bytes: b"hi\n".to_vec(),
        })
        .unwrap();
        assert_eq!(s.recv().await, Some(SessionEvent::Data(b"hi\n".to_vec())));

        // Guest close yields a terminal Closed event.
        let exit = PtyExit {
            code: 0,
            signal: None,
        };
        r.route(&ControlMessage::PtyClose {
            session_id: 1,
            exit,
        })
        .unwrap();
        assert_eq!(s.recv().await, Some(SessionEvent::Closed(exit)));

        let sent = t.sent.lock().unwrap();
        assert!(matches!(
            sent[0],
            ControlMessage::PtyOpen { session_id: 1, .. }
        ));
        assert!(matches!(
            sent[1],
            ControlMessage::PtyData {
                session_id: 1,
                direction: PtyDirection::ToGuest,
                ..
            }
        ));
        assert!(matches!(
            sent[2],
            ControlMessage::PtyResize {
                session_id: 1,
                rows: 30,
                cols: 100
            }
        ));
    }

    /// §3.8: two concurrent sessions are routed independently by id.
    #[tokio::test]
    async fn two_sessions_interleave_by_id() {
        let t = Arc::new(FakeTransport::default());
        let r = PtyRouter::new();
        let a = SessionIdAllocator::new();
        let mut s1 = PtySession::open(t.clone(), &a, &r, &opts("/a")).unwrap();
        let mut s2 = PtySession::open(t.clone(), &a, &r, &opts("/b")).unwrap();
        assert_eq!((s1.session_id, s2.session_id), (1, 2));

        // Deliver out of order; each lands in its own session.
        r.route(&ControlMessage::PtyData {
            session_id: 2,
            direction: PtyDirection::ToHost,
            bytes: b"two".to_vec(),
        })
        .unwrap();
        r.route(&ControlMessage::PtyData {
            session_id: 1,
            direction: PtyDirection::ToHost,
            bytes: b"one".to_vec(),
        })
        .unwrap();
        assert_eq!(s1.recv().await, Some(SessionEvent::Data(b"one".to_vec())));
        assert_eq!(s2.recv().await, Some(SessionEvent::Data(b"two".to_vec())));
    }

    /// §3.8: an inbound frame larger than the cap is a protocol violation.
    #[test]
    fn oversized_inbound_frame_rejected() {
        let r = PtyRouter::new();
        let _rx = r.register(1);
        let oversized = ControlMessage::PtyData {
            session_id: 1,
            direction: PtyDirection::ToHost,
            bytes: vec![0u8; MAX_PTY_FRAME_BYTES + 1],
        };
        assert!(r.route(&oversized).is_err());
    }

    #[test]
    fn launch_spec_maps_intents_to_in_vm_argv() {
        assert_eq!(
            launch_spec(&PtyIntent::Shell, 24, 80).argv,
            vec!["/bin/bash", "-l"]
        );
        assert_eq!(
            launch_spec(&PtyIntent::GithubLogin, 24, 80).argv,
            vec!["gh", "auth", "login"]
        );
        assert_eq!(
            launch_spec(&PtyIntent::Agent(SelectedAgent::OpenCode), 24, 80).argv,
            vec!["tillandsias", "--opencode"]
        );
        assert_eq!(
            launch_spec(&PtyIntent::Agent(SelectedAgent::Claude), 24, 80).argv,
            vec!["tillandsias", "--claude"]
        );
        // Size is carried; TERM is set; cwd left to the in-VM default.
        let s = launch_spec(&PtyIntent::Shell, 30, 100);
        assert_eq!((s.rows, s.cols), (30, 100));
        assert!(
            s.env
                .iter()
                .any(|(k, v)| k == "TERM" && v == "xterm-256color")
        );
        assert!(s.cwd.is_none());
    }

    #[tokio::test]
    async fn channel_transport_enqueues_outbound_in_order() {
        let (t, mut rx) = ChannelPtyTransport::new(8);
        t.send(ControlMessage::PtyResize {
            session_id: 1,
            rows: 24,
            cols: 80,
        })
        .unwrap();
        t.send(ControlMessage::PtyClose {
            session_id: 1,
            exit: PtyExit {
                code: 0,
                signal: None,
            },
        })
        .unwrap();
        assert!(matches!(
            rx.recv().await.unwrap(),
            ControlMessage::PtyResize { session_id: 1, .. }
        ));
        assert!(matches!(
            rx.recv().await.unwrap(),
            ControlMessage::PtyClose { session_id: 1, .. }
        ));
    }

    #[tokio::test]
    async fn channel_transport_full_is_backpressure_error() {
        let (t, _rx) = ChannelPtyTransport::new(1);
        t.send(ControlMessage::PtyResize {
            session_id: 1,
            rows: 1,
            cols: 1,
        })
        .unwrap(); // fills the single slot
        let err = t
            .send(ControlMessage::PtyResize {
                session_id: 1,
                rows: 2,
                cols: 2,
            })
            .unwrap_err();
        assert!(
            err.contains("full"),
            "expected backpressure error, got: {err}"
        );
    }

    /// An unknown session id is ignored, not an error.
    #[test]
    fn unknown_session_is_ignored() {
        let r = PtyRouter::new();
        let ok = ControlMessage::PtyData {
            session_id: 999,
            direction: PtyDirection::ToHost,
            bytes: b"x".to_vec(),
        };
        assert!(r.route(&ok).is_ok());
    }

    /// Fake PTY master backed by two in-memory duplex pipes — no real terminal.
    struct FakeMaster {
        reader: tokio::io::DuplexStream,
        writer: tokio::io::DuplexStream,
    }
    impl PtyMaster for FakeMaster {
        type Reader = tokio::io::DuplexStream;
        type Writer = tokio::io::DuplexStream;
        fn split(self) -> (Self::Reader, Self::Writer) {
            (self.reader, self.writer)
        }
    }

    /// §3.4: pump_io bridges both directions and exits on guest close.
    #[tokio::test]
    async fn pump_bridges_both_directions_and_closes() {
        use std::time::Duration;

        // in_writer -> (pump reads as keystrokes); (pump writes output) -> out_reader.
        let (mut in_writer, in_reader) = tokio::io::duplex(4096);
        let (out_writer, mut out_reader) = tokio::io::duplex(4096);
        let master = FakeMaster {
            reader: in_reader,
            writer: out_writer,
        };

        let t = Arc::new(FakeTransport::default());
        let r = PtyRouter::new();
        let a = SessionIdAllocator::new();
        let session = PtySession::open(t.clone(), &a, &r, &opts("/bin/bash")).unwrap();
        let sid = session.session_id;

        let handle = pump_io(session, master);

        // Local keystrokes flow to the guest as PtyData{ToGuest}.
        in_writer.write_all(b"ls\n").await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            t.sent.lock().unwrap().iter().any(|m| matches!(
                m,
                ControlMessage::PtyData { session_id, direction: PtyDirection::ToGuest, bytes }
                    if *session_id == sid && bytes == b"ls\n"
            )),
            "keystrokes should be forwarded as ToGuest"
        );

        // Guest output flows to the local terminal.
        r.route(&ControlMessage::PtyData {
            session_id: sid,
            direction: PtyDirection::ToHost,
            bytes: b"file1\n".to_vec(),
        })
        .unwrap();
        let mut buf = [0u8; 6];
        out_reader.read_exact(&mut buf).await.unwrap();
        assert_eq!(&buf, b"file1\n");

        // Guest close ends the pump.
        r.route(&ControlMessage::PtyClose {
            session_id: sid,
            exit: PtyExit {
                code: 0,
                signal: None,
            },
        })
        .unwrap();
        let joined = tokio::time::timeout(Duration::from_secs(2), handle).await;
        assert!(joined.is_ok(), "pump output task should finish after close");
    }
}
