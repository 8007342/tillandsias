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

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use tillandsias_control_wire::{ControlMessage, PtyDirection, PtyExit, MAX_PTY_FRAME_BYTES};

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

/// Outbound side of the control wire: wrap `body` in a `ControlEnvelope`
/// (assigning the connection's monotonic `seq`) and send it to the in-VM
/// headless. Abstracted so the session logic is testable without a real
/// vsock connection.
pub trait PtyTransport: Send + Sync {
    fn send(&self, body: ControlMessage) -> Result<(), PtyError>;
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
        let exit = PtyExit { code: 0, signal: None };
        r.route(&ControlMessage::PtyClose { session_id: 1, exit }).unwrap();
        assert_eq!(s.recv().await, Some(SessionEvent::Closed(exit)));

        let sent = t.sent.lock().unwrap();
        assert!(matches!(sent[0], ControlMessage::PtyOpen { session_id: 1, .. }));
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
}
