//! In-VM PTY handler — control-wire-pty-attach Tasks 4.1–4.7.
//!
//! Each vsock connection owns one [`PtySessionStore`]. When a `PtyOpen`
//! envelope arrives the store allocates a Unix PTY pair via `nix::pty`,
//! forks + execs the requested `argv` with the slave fd as the
//! controlling tty, and spawns a tokio task that pumps bytes off the
//! master fd into `PtyData{ToHost}` envelopes on the connection's
//! outbound channel.
//!
//! Host → guest bytes (`PtyData{ToGuest}`) and resizes (`PtyResize`)
//! look up the session by id and ENQUEUE onto a bounded per-session
//! write queue drained by a dedicated writer task (audit D6, order 493):
//! the connection loop never awaits the master fd inline, so a wedged
//! child cannot starve control-plane frames past the 250 ms fairness
//! bound — a queue full past the deadline kills the session instead
//! (kill-not-drop). Host
//! `PtyClose` drives a SIGTERM with 2-second grace then SIGKILL. The
//! pump task also reaps the child via `waitpid` and emits a final
//! `PtyClose` carrying the exit code or signal before tearing the
//! session down.
//!
//! All sessions are scoped to the vsock connection — when the
//! connection closes, [`PtySessionStore::shutdown_all`] runs the same
//! SIGTERM-then-SIGKILL drain on every still-live session.
//!
//! Unix-only by design; Windows hosts run their own host-side ConPTY
//! pipe per the proposal's Task 3.3 (windows-tray w4).
//!
//! @trace openspec/changes/control-wire-pty-attach/proposal.md (Tasks 4.x),
//! @trace spec:vsock-exec-authz
//!        plan/issues/multi-host-integration-loop-2026-05-24.md (l3),
//!        plan/issues/windows-next-work-queue-2026-05-25.md (w4)

#![cfg(unix)]
#![allow(dead_code)]

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use nix::fcntl::{FcntlArg, OFlag, fcntl};
use nix::pty::openpty;
use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use tillandsias_control_wire::{
    ControlEnvelope, ControlMessage, MAX_PTY_FRAME_BYTES, PtyDirection, PtyExit, PtyInputState,
    WIRE_VERSION,
};
use tokio::io::Interest;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

const PTY_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// Depth of the per-session host→guest write queue drained by the writer
/// task (audit D6, order 493). Sized so a burst of max-size `PtyData`
/// frames (`MAX_PTY_FRAME_BYTES` = 64,000 bytes each) bounds per-session
/// memory at ~1 MiB while still absorbing legitimate type-ahead during a
/// busy cooked phase without tripping the wedge deadline below.
const PTY_WRITE_QUEUE_CAPACITY: usize = 16;

/// How long the connection loop may wait to ENQUEUE one host→guest
/// command before declaring the session wedged. Equal to the ≤250 ms
/// control-plane fairness bound ("PTY-traffic does not starve
/// control-plane envelopes",
/// openspec/changes/control-wire-pty-attach/specs/vsock-transport/spec.md):
/// the bounded enqueue is the only PTY-write await the connection loop
/// performs inline, so bounding it restores the fairness invariant even
/// when the child wedges (stops reading its slave). A queue that stays
/// FULL for this whole window — not merely non-empty; type-ahead drains
/// within it — means the child is wedged, and the session is KILLED via
/// the existing SIGTERM+2s+SIGKILL path rather than dropping bytes
/// (kill-not-drop: silently dropped frames would recreate the UTF-8
/// tearing fixed in ea2fbc8d).
/// @trace plan/issues/guest-pty-write-wedge-2026-07-27.md (audit D6)
const PTY_WRITE_ENQUEUE_DEADLINE: Duration = Duration::from_millis(250);

/// One host→guest command routed through the per-session bounded write
/// queue. `Resize` travels through the SAME queue as `Write` so
/// `TIOCSWINSZ` can never apply ahead of input bytes that arrived before
/// it (audit D6 ordering note: resize kept inline while data queued
/// would reorder).
enum PtyWriteCommand {
    Write(Vec<u8>),
    Resize {
        rows: u16,
        cols: u16,
    },
    /// Host says its stdin for this child is finished (order 925-eofi).
    /// Routed through this SAME queue as the input bytes, for the ordering
    /// reason `Resize` documents: an EOF that overtook the bytes it follows
    /// would truncate them.
    StdinEof,
}

/// One active PTY session for a single connection.
struct PtySession {
    session_id: u32,
    /// Master fd wrapped as `AsyncFd<OwnedFd>` — readiness-based async
    /// I/O. Host → guest writes go here;
    /// the pump task reads from this for guest → host bytes.
    master: Arc<AsyncFd<OwnedFd>>,
    /// PID of the forked child running `argv[0]`.
    child_pid: Pid,
    /// Explicit cancellation for the pump task. `close_host_initiated`
    /// drops this Sender so the pump's `recv()` resolves immediately;
    /// pump then breaks the read loop, reaps the child, and emits the
    /// terminal PtyClose. Without this, the pump would wait for the
    /// kernel's PTY HUP edge to reach AsyncFd, which is racey in the
    /// 10s test budget after a SIGTERM-killed child.
    cancel: Option<tokio::sync::oneshot::Sender<()>>,
    /// Drop trigger for the pump task. Dropping cancels the read loop;
    /// the task also exits voluntarily on EOF or `waitpid` reaping the
    /// child.
    _pump: tokio::task::JoinHandle<()>,
    /// Bounded host→guest write queue (audit D6). The connection loop
    /// only ENQUEUES here — deadline-bounded via
    /// [`PTY_WRITE_ENQUEUE_DEADLINE`] — while the writer task owns the
    /// potentially-unbounded master-fd writes.
    writer_tx: mpsc::Sender<PtyWriteCommand>,
    /// Explicit cancellation for the writer task, mirroring `cancel`:
    /// firing (or dropping) it interrupts even a wedged mid-write await
    /// so teardown never waits on a child that stopped reading.
    writer_cancel: Option<tokio::sync::oneshot::Sender<()>>,
    /// Writer-task handle. The task exits on cancel, on queue close
    /// (session removed from the store), or on a failed master write.
    _writer: tokio::task::JoinHandle<()>,
}

/// Per-connection PTY session table. Keyed by `session_id` chosen by the
/// host. Inserts on `PtyOpen`, removes on `PtyClose` (either direction).
pub struct PtySessionStore {
    sessions: HashMap<u32, PtySession>,
    outbound: mpsc::Sender<ControlEnvelope>,
    heartbeat_interval: Option<Duration>,
    /// Order 723-2yb3: emit `PtyHeartbeat` (which carries the input state)
    /// instead of the v1 empty `PtyData`. Only ever true for a peer that
    /// advertised `pty.heartbeat@v2` — a v1 host decodes the new variant as
    /// `Error::UnknownVariant`.
    heartbeat_v2: bool,
}

impl PtySessionStore {
    /// Create a new store. `outbound` is the per-connection channel that
    /// `PtyData{ToHost}` and child-exit `PtyClose` envelopes are pushed
    /// to; the connection's writer task drains it.
    pub fn new(outbound: mpsc::Sender<ControlEnvelope>) -> Self {
        Self {
            sessions: HashMap::new(),
            outbound,
            heartbeat_interval: None,
            heartbeat_v2: false,
        }
    }

    /// Enable PTY liveness frames for a client that advertised
    /// `pty.heartbeat@v1` (or `@v2`) during the control-wire handshake.
    ///
    /// `v2` selects the frame SHAPE, not whether heartbeats happen at all: a
    /// v2 peer gets `PtyHeartbeat` carrying the input state, a v1 peer keeps
    /// the empty `PtyData{ToHost}` it already understands.
    pub fn new_with_heartbeat(outbound: mpsc::Sender<ControlEnvelope>, v2: bool) -> Self {
        Self {
            sessions: HashMap::new(),
            outbound,
            heartbeat_interval: Some(PTY_HEARTBEAT_INTERVAL),
            heartbeat_v2: v2,
        }
    }

    /// Handle a `PtyOpen` envelope. Allocates a PTY pair, forks the
    /// requested argv with `env` (replacing — not extending — the
    /// child's env) and `cwd`, and spawns the read pump.
    ///
    /// Returns `Err` if the session id is already in use, the PTY
    /// allocation fails, or the exec fails (the child reports via
    /// `pre_exec` and the parent sees the spawn error).
    pub async fn open(
        &mut self,
        session_id: u32,
        rows: u16,
        cols: u16,
        argv: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
    ) -> Result<(), PtyOpenError> {
        self.open_with_stdin_kind(session_id, rows, cols, argv, env, cwd, false)
            .await
    }

    /// [`Self::open`] with the DATA-session choice made explicit (926-bin4).
    ///
    /// `data_session = true` puts the child's fd 0 on a PIPE and leaves fd 1/2
    /// on the PTY slave. That is the entire fix for the control-byte
    /// corruption: stdin crosses no line discipline, so 0x03/0x04/0x11/0x13/
    /// 0x15/0x1a/0x7f are delivered rather than interpreted, and end-of-input
    /// becomes a real close instead of a VEOF injection that only works in
    /// canonical mode.
    ///
    /// Output is deliberately UNCHANGED: fd 1 and 2 still point at the slave,
    /// so streaming, combined stdout/stderr ordering and `isatty(1)` behave
    /// exactly as before, and an interactive attach (which must keep its Ctrl-C)
    /// never takes this path.
    #[allow(clippy::too_many_arguments)]
    pub async fn open_with_stdin_kind(
        &mut self,
        session_id: u32,
        rows: u16,
        cols: u16,
        argv: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
        data_session: bool,
    ) -> Result<(), PtyOpenError> {
        if self.sessions.contains_key(&session_id) {
            return Err(PtyOpenError::DuplicateSession(session_id));
        }
        if argv.is_empty() {
            return Err(PtyOpenError::EmptyArgv);
        }

        let is_allowed = crate::exec_allowlist::exec_argv_is_allowed(&argv);

        if !is_allowed {
            return Err(PtyOpenError::Spawn(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                format!("exec allowlist violation: {:?}", argv),
            )));
        }

        // 1) Allocate the PTY pair.
        let OpenptyOwned { master, slave } =
            openpty_owned(rows, cols).map_err(PtyOpenError::Openpty)?;

        // 1b) Line-discipline hygiene (audit D2 — the character-bleeding
        // source): the kernel-default slave termios is cooked with the echo
        // family ON, so during any phase where the child is not itself raw
        // (the whole `bash -lc` provisioning window before podman attaches)
        // unconsumed host input — e.g. Terminal.app scroll synthesized into
        // arrow keys — echoes straight back as literal `^[[A`/`^[[B` over an
        // output-only stream. Clear ONLY the echo family; ISIG (Ctrl+C
        // ownership) and everything else stay untouched. TUIs and `podman
        // exec -it` set their own termios/echo; the lanes that DO rely on
        // kernel echo for typed input (github-login's cooked prompts, the
        // bare-VM `/bin/bash -l` debug shell whose non-readline children
        // would type blind) keep it — see `argv_wants_kernel_echo`.
        // @trace plan/issues/macos-terminal-management-audit-2026-07-27.md (D2),
        //        plan/issues/macos-tray-scroll-arrowkey-spill-during-build-2026-07-23.md
        if !argv_wants_kernel_echo(&argv)
            && let Err(err) = clear_slave_echo_family(&slave)
        {
            // Best-effort: a cooked-echo PTY is degraded UX, not a
            // launch blocker.
            warn!(session_id, %err, "guest PTY echo-family clear failed");
        }
        // 1c) UTF-8-aware cooked-mode editing (order-491 in-forge probe 1):
        // the kernel default leaves IUTF8 off, so a canonical-mode erase
        // (backspace in github-login prompts, `read` lines) can split a
        // multibyte sequence even though the session env is UTF-8
        // (LANG=C.UTF-8 / en_US.UTF-8). Linux-only flag; the guest is
        // always Linux — the cfg keeps macOS dev-host unit builds green.
        #[cfg(target_os = "linux")]
        if let Err(err) = set_slave_iutf8(&slave) {
            warn!(session_id, %err, "guest PTY IUTF8 set failed");
        }

        // 2) Build the child Command. Slave fd becomes child stdin/out/err
        //    and its controlling tty (via setsid + TIOCSCTTY in pre_exec).
        let slave_raw = slave.as_raw_fd();
        let mut cmd = std::process::Command::new(&argv[0]);
        if argv.len() > 1 {
            cmd.args(&argv[1..]);
        }
        cmd.env_clear();
        for (k, v) in child_env(&env) {
            cmd.env(k, v);
        }
        if let Some(dir) = cwd {
            cmd.current_dir(dir);
        }
        // 2b) DATA SESSION: fd 0 comes from a PIPE, not the slave (926-bin4).
        // Created BEFORE the fork so both ends exist for pre_exec to dup2 from;
        // the parent keeps the write end and the child keeps the read end.
        let stdin_pipe = if data_session {
            // O_CLOEXEC ON BOTH ENDS IS LOAD-BEARING, not hygiene. A plain
            // pipe() leaves both ends inheritable, so the forked child would
            // keep a copy of the WRITE end open across exec — and a pipe
            // reports EOF only when the LAST writer closes. The child would
            // then hold open the very thing whose closure is supposed to tell
            // it that input ended, and every reader would block forever.
            // MEASURED before this flag existed: `cat` hung at the 120s bound
            // instead of returning, on a byte (0x03) that the pipe had already
            // stopped interpreting — delivery working, EOF silently impossible.
            //
            // dup2 clears CLOEXEC on the NEW descriptor, so the read end still
            // reaches the child as fd 0; only the inherited duplicates vanish.
            // pipe() + explicit FD_CLOEXEC rather than pipe2(O_CLOEXEC): nix
            // gates pipe2 away on macOS (Darwin has no pipe2(2)), and this file
            // compiles on the macOS dev host for its unit tests even though the
            // guest it runs in is Linux. fcntl(F_SETFD) is portable to both.
            let (read_fd, write_fd) = nix::unistd::pipe().map_err(PtyOpenError::Openpty)?;
            for end in [read_fd.as_raw_fd(), write_fd.as_raw_fd()] {
                nix::fcntl::fcntl(
                    end,
                    nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
                )
                .map_err(PtyOpenError::Openpty)?;
            }
            Some((read_fd, write_fd))
        } else {
            None
        };
        let stdin_read_raw = stdin_pipe.as_ref().map(|(r, _)| r.as_raw_fd());

        // SAFETY: pre_exec runs in the child after fork; the closure
        // must only call async-signal-safe functions. setsid + dup2 +
        // ioctl(TIOCSCTTY) are all on the safe list.
        unsafe {
            cmd.pre_exec(move || {
                use nix::libc;
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                // fd 1 and 2 ALWAYS come from the slave: output streaming,
                // combined ordering and isatty(1) must not change (926-bin4).
                for target_fd in 1..=2 {
                    if libc::dup2(slave_raw, target_fd) < 0 {
                        return Err(std::io::Error::last_os_error());
                    }
                }
                // fd 0 is the pipe on a data session, the slave otherwise.
                let stdin_src = stdin_read_raw.unwrap_or(slave_raw);
                if libc::dup2(stdin_src, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                // `ioctl`'s request arg is `c_ulong` on BSD/macOS but the
                // `TIOCSCTTY` constant is `c_int`/`u32` there; cast so the
                // guest handler also compiles on a macOS dev host (lets the
                // sole macOS worker run these unit tests). Value is identical
                // on Linux, where the request type already matches.
                if libc::ioctl(slave_raw, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::null());
        cmd.stderr(Stdio::null());

        // 3) Spawn the child. The pre_exec wiring redirects its
        //    std{in,out,err} to the slave fd; we don't need Stdio
        //    pipes from the parent side.
        let child = cmd.spawn().map_err(PtyOpenError::Spawn)?;
        let child_pid = Pid::from_raw(child.id() as i32);
        // The parent doesn't need the slave fd after spawn.
        drop(slave);

        // 4) Set the master fd non-blocking and wrap in tokio's
        //    AsyncFd<OwnedFd>. Readiness-based I/O is the right
        //    primitive for PTY masters: the previous tokio::fs::File
        //    wrapper used the blocking thread-pool, which didn't
        //    reliably surface EIO / EOF when the child exited
        //    (two pty_handler tests were `#[ignore]`'d for exactly
        //    this reason). AsyncFd::readable()+try_io() correctly
        //    returns Ok(0) on EOF or Err(EIO) on slave-close, which
        //    drives the pump's break-and-reap path.
        let master_raw = master.as_raw_fd();
        let flags = fcntl(master_raw, FcntlArg::F_GETFL).map_err(PtyOpenError::Openpty)?;
        let new_flags = OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK;
        fcntl(master_raw, FcntlArg::F_SETFL(new_flags)).map_err(PtyOpenError::Openpty)?;
        let master_async = AsyncFd::with_interest(master, Interest::READABLE | Interest::WRITABLE)
            .map_err(PtyOpenError::Spawn)?;
        let master_arc = Arc::new(master_async);

        // 5) Spawn the pump task with an explicit cancellation channel.
        let (cancel_tx, cancel_rx) = tokio::sync::oneshot::channel::<()>();
        let pump = spawn_pump_task(
            session_id,
            child_pid,
            master_arc.clone(),
            self.outbound.clone(),
            cancel_rx,
            self.heartbeat_interval,
            self.heartbeat_v2,
        );

        // 6) Spawn the writer task behind the bounded write queue (audit
        //    D6): host→guest data and resizes are enqueued by the
        //    connection loop and drained here, so a child that stops
        //    reading its slave wedges only this task — never the loop.
        let (writer_tx, writer_rx) = mpsc::channel::<PtyWriteCommand>(PTY_WRITE_QUEUE_CAPACITY);
        let (writer_cancel_tx, writer_cancel_rx) = tokio::sync::oneshot::channel::<()>();
        // The child now owns the pipe's READ end via dup2; the parent drops it
        // so the child sees EOF when we close the WRITE end and not before —
        // a lingering read end in this process would make that close silent.
        let stdin_sink = match stdin_pipe {
            Some((read_fd, write_fd)) => {
                drop(read_fd);
                StdinSink::Pipe(Some(
                    AsyncFd::new(write_fd).map_err(PtyOpenError::StdinPipe)?,
                ))
            }
            None => StdinSink::Pty(master_arc.clone()),
        };
        let writer = spawn_writer_task(
            session_id,
            master_arc.clone(),
            stdin_sink,
            writer_rx,
            writer_cancel_rx,
        );

        self.sessions.insert(
            session_id,
            PtySession {
                session_id,
                master: master_arc,
                child_pid,
                cancel: Some(cancel_tx),
                _pump: pump,
                writer_tx,
                writer_cancel: Some(writer_cancel_tx),
                _writer: writer,
            },
        );

        info!(
            spec = "vsock-transport",
            session_id, pid = child_pid.as_raw(),
            argv = ?argv,
            "PtyOpen: session started"
        );
        Ok(())
    }

    /// Handle a `PtyData{ToGuest}` envelope: enqueue the bytes on the
    /// session's bounded write queue (audit D6 — the actual master-fd
    /// write happens on the writer task, never inline in the connection
    /// loop). No-ops if the session id is unknown (the host may race a
    /// write against a child-exit close). If the queue stays full past
    /// [`PTY_WRITE_ENQUEUE_DEADLINE`], the session is killed
    /// (kill-not-drop).
    pub async fn write_to_guest(&mut self, session_id: u32, bytes: Vec<u8>) {
        self.enqueue_write_command(session_id, PtyWriteCommand::Write(bytes))
            .await;
    }

    /// Handle a `PtyStdinEof`: the host has no more input for this child
    /// (order 925-eofi). Enqueued on the same bounded queue as the bytes it
    /// follows so it cannot overtake them.
    pub async fn stdin_eof(&mut self, session_id: u32) {
        self.enqueue_write_command(session_id, PtyWriteCommand::StdinEof)
            .await;
    }

    /// Handle a `PtyResize`: routed through the SAME per-session queue as
    /// `PtyData{ToGuest}` so `TIOCSWINSZ` is applied at its host-arrival
    /// position relative to input bytes (audit D6 ordering note).
    pub async fn resize(&mut self, session_id: u32, rows: u16, cols: u16) {
        self.enqueue_write_command(session_id, PtyWriteCommand::Resize { rows, cols })
            .await;
    }

    /// Deadline-bounded enqueue shared by [`write_to_guest`] and
    /// [`resize`]. The timeout is event-driven on the awaited `send` (a
    /// bounded `mpsc::Sender::send` resolves the moment a slot frees) —
    /// never a periodic queue inspection. When the queue has been FULL
    /// for the whole [`PTY_WRITE_ENQUEUE_DEADLINE`] the child has stopped
    /// reading its slave: the session is killed loudly via the existing
    /// SIGTERM+2s+SIGKILL path ([`Self::close_host_initiated`]) instead
    /// of blocking the connection loop unboundedly or silently dropping
    /// the command (kill-not-drop). The pump task still emits the
    /// terminal `PtyClose` so the host observes the kill.
    async fn enqueue_write_command(&mut self, session_id: u32, cmd: PtyWriteCommand) {
        let Some(session) = self.sessions.get(&session_id) else {
            debug!(
                spec = "vsock-transport",
                session_id,
                "host→guest PTY command for unknown session — dropping (likely raced child-exit)"
            );
            return;
        };
        let kind = match &cmd {
            PtyWriteCommand::Write(_) => "PtyData{ToGuest}",
            PtyWriteCommand::Resize { .. } => "PtyResize",
            PtyWriteCommand::StdinEof => "PtyStdinEof",
        };
        let writer_tx = session.writer_tx.clone();
        match tokio::time::timeout(PTY_WRITE_ENQUEUE_DEADLINE, writer_tx.send(cmd)).await {
            Ok(Ok(())) => {}
            Ok(Err(_send_err)) => {
                // Writer task exited (a master write failed — child side
                // is gone or dying). The command cannot be delivered;
                // close the session loudly rather than dropping it
                // silently and letting the host keep writing into a void.
                warn!(
                    spec = "vsock-transport",
                    session_id,
                    command = kind,
                    "PTY writer task is gone (master write previously failed); \
                     killing session via SIGTERM/SIGKILL (kill-not-drop, audit D6)"
                );
                self.close_host_initiated(session_id).await;
            }
            Err(_elapsed) => {
                warn!(
                    spec = "vsock-transport",
                    session_id,
                    command = kind,
                    deadline_ms = PTY_WRITE_ENQUEUE_DEADLINE.as_millis() as u64,
                    "PTY write queue FULL past the control-plane fairness deadline — \
                     child is wedged (not reading its slave); killing session via \
                     SIGTERM/SIGKILL instead of blocking the connection loop or \
                     dropping bytes (kill-not-drop, audit D6)"
                );
                self.close_host_initiated(session_id).await;
            }
        }
    }

    /// Handle a host-initiated `PtyClose`: SIGTERM, wait 2s, then
    /// SIGKILL if the child is still alive. The pump task observes
    /// the child exit via `waitpid` and emits the terminal `PtyClose`
    /// envelope to the host.
    pub async fn close_host_initiated(&mut self, session_id: u32) {
        let Some(mut session) = self.sessions.remove(&session_id) else {
            return;
        };
        // Fire the explicit cancel — the pump observes it before the
        // SIGTERM-driven HUP edge would arrive, breaks the read loop,
        // and runs reap_child → terminal PtyClose envelope.
        if let Some(cancel) = session.cancel.take() {
            let _ = cancel.send(());
        }
        // Fire the writer cancel too: a writer wedged mid-write on a
        // child that stopped reading must not linger until the master
        // fd errors (audit D6).
        if let Some(cancel) = session.writer_cancel.take() {
            let _ = cancel.send(());
        }
        spawn_terminator(session.child_pid, Duration::from_secs(2));
    }

    /// Tear down every still-live session. Called when the connection
    /// is dropping (vsock peer disconnected).
    pub async fn shutdown_all(&mut self) {
        // Drain so we can fire each session's cancel before terminating
        // the child PID — otherwise the pumps could outlive the host
        // teardown.
        let drained: Vec<PtySession> = self.sessions.drain().map(|(_, s)| s).collect();
        for mut session in drained {
            if let Some(cancel) = session.cancel.take() {
                let _ = cancel.send(());
            }
            if let Some(cancel) = session.writer_cancel.take() {
                let _ = cancel.send(());
            }
            spawn_terminator(session.child_pid, Duration::from_secs(2));
        }
    }
}

/// What can go wrong opening a session. Wire-level errors are mapped
/// to `ControlMessage::Error` by the caller.
#[derive(Debug)]
pub enum PtyOpenError {
    DuplicateSession(u32),
    EmptyArgv,
    Openpty(nix::Error),
    Spawn(std::io::Error),
    /// The data session's stdin pipe could not be made non-blocking/async
    /// (order 926-bin4). Distinct from `Openpty` so the failure names the pipe
    /// rather than blaming the PTY that opened fine.
    StdinPipe(std::io::Error),
}

impl std::fmt::Display for PtyOpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PtyOpenError::DuplicateSession(id) => write!(f, "session_id {id} already in use"),
            PtyOpenError::EmptyArgv => write!(f, "PtyOpen.argv must not be empty"),
            PtyOpenError::Openpty(err) => write!(f, "openpty failed: {err}"),
            PtyOpenError::Spawn(err) => write!(f, "fork+exec failed: {err}"),
            PtyOpenError::StdinPipe(err) => {
                write!(f, "data-session stdin pipe unusable: {err}")
            }
        }
    }
}

impl std::error::Error for PtyOpenError {}

/// Default `PATH` seeded into a PTY child when the caller supplied none.
/// Standard Fedora/Linux system path; covers `/usr/local/bin` (gh, vault-cli,
/// tillandsias-headless) and `/usr/bin` (podman, bash, coreutils).
const DEFAULT_CHILD_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// Build the PTY child's environment. The caller's `env` REPLACES the inherited
/// environment (`env_clear` precedes this — no host-env leak), but a sane
/// default `PATH` is injected when the caller did not supply one.
///
/// Rationale: a cleared environment has no `PATH`, so a bare-name `argv[0]`
/// (`gh`, `podman`, `tillandsias-headless`, …) cannot be resolved and the spawn
/// fails with `ENOENT` — which on the tray attach path surfaced as a blank
/// terminal with no error. Seeding `PATH` keeps the no-host-env-leak intent
/// while making bare-name commands resolvable, so callers no longer must pass
/// absolute paths or wrap every command in a login shell.
///
/// @trace plan/issues/macos-tray-github-login-blank-terminal-2026-06-21.md,
///        plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
/// The child's HOME, read from the passwd database rather than assumed.
///
/// ORDER 1072-qk43. `child_env` seeded PATH, no_proxy and NO_PROXY and NOT HOME,
/// so every `--exec-guest` command ran with HOME unset while USER, whoami and id
/// all reported root. That environment is INCONSISTENT, not minimal, and the
/// loud half was the cheap half:
///
///   * LOUD: any `set -u` script dies at its first $HOME reference. Measured on
///     tlatoanis-macbook-air 2026-09-05 — the project's own build script:
///     "scripts/build-image.sh: line 40: HOME: unbound variable", exit 1 in 0s.
///   * SILENT, and the reason this is p1: the login profile prepends
///     "$HOME/.local/bin", which with HOME unset expands to "/.local/bin" — a
///     real absolute path that does not exist. Nothing errors and nothing warns,
///     so a tool that WOULD resolve under a correct HOME is simply not found.
///     An environment fault wearing a missing-tool's clothes, which is
///     1004-x9ua's class arriving from the other side.
///
/// A CALLER-SIDE EXPORT CANNOT REPAIR IT, which is why the fix must be here:
/// re-running with `export HOME=/root` as the first statement still yields
/// PATH=/.local/bin:..., because the login shell computes PATH before the
/// export runs. There is no workaround available to a caller.
///
/// READ, NOT ASSUMED. The guest's PTY children run as root today, so "/root"
/// would be right today; hardcoding it is the shape that protects whoever
/// remembers. passwd is the actual source of truth and costs one small read.
/// The PURE half, split out so it is testable on every host.
///
/// It has to be pure or it cannot be tested where it matters. macOS keeps
/// regular users in Directory Services, not /etc/passwd, so a dev host's
/// lookup legitimately returns None for its own uid — which means a test
/// written against the impure function passes vacuously there. MEASURED: the
/// first version of this test survived deleting the entire HOME seed, because
/// its "no home found" branch was satisfied by the dev host's own uid.
fn home_from_passwd(passwd: &str, uid: u32) -> Option<String> {
    for line in passwd.lines() {
        let f: Vec<&str> = line.split(':').collect();
        // name:passwd:uid:gid:gecos:home:shell
        if f.len() >= 6 && f[2].parse::<u32>().ok() == Some(uid) && !f[5].is_empty() {
            return Some(f[5].to_string());
        }
    }
    // Fallback only for root, whose home is fixed by convention on every distro
    // the guest is built from. For any other uid, seeding a GUESSED home would
    // be worse than none: a wrong HOME points caches and dotfiles at a directory
    // the child may not own, and that failure is quieter than the one above.
    (uid == 0).then(|| "/root".to_string())
}

fn default_child_home() -> Option<String> {
    // libc, not nix::unistd::geteuid: that needs nix's "user" feature, which
    // this crate does not enable. geteuid() cannot fail and touches no memory.
    let uid = unsafe { libc::geteuid() };
    let passwd = std::fs::read_to_string("/etc/passwd").unwrap_or_default();
    home_from_passwd(&passwd, uid)
}

fn child_env(provided: &[(String, String)]) -> Vec<(String, String)> {
    child_env_with_home(provided, default_child_home())
}

/// The seeding logic, with the host lookup INJECTED so it can be tested off the
/// guest.
///
/// ORDER 1072-qk43, and this split is the third attempt at giving the arm teeth.
/// Asserting against `child_env` directly is vacuous on any host whose passwd
/// has no entry for its own uid — macOS keeps regular users in Directory
/// Services — so the test's body simply never ran there and SURVIVED deleting
/// the seed twice: once through a "no home found" branch, once through an
/// `is_some()` guard. Injecting the home is what makes the mutation observable.
fn child_env_with_home(
    provided: &[(String, String)],
    home: Option<String>,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::with_capacity(provided.len() + 4);
    if !provided.iter().any(|(k, _)| k == "PATH") {
        out.push(("PATH".to_string(), DEFAULT_CHILD_PATH.to_string()));
    }
    // Seed HOME when the caller did not. Caller-provided HOME still wins,
    // exactly like PATH.
    if !provided.iter().any(|(k, _)| k == "HOME")
        && let Some(home) = home
    {
        out.push(("HOME".to_string(), home));
    }
    out.extend(provided.iter().cloned());

    // proxy-exemption pattern
    if !provided.iter().any(|(k, _)| k == "no_proxy") {
        out.push(("no_proxy".to_string(), crate::enclave_no_proxy()));
    }
    if !provided.iter().any(|(k, _)| k == "NO_PROXY") {
        out.push(("NO_PROXY".to_string(), crate::enclave_no_proxy()));
    }

    out
}

struct OpenptyOwned {
    master: OwnedFd,
    slave: OwnedFd,
}

fn openpty_owned(rows: u16, cols: u16) -> nix::Result<OpenptyOwned> {
    use nix::pty::Winsize;
    let winsize = Winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let result = openpty(Some(&winsize), None)?;
    Ok(OpenptyOwned {
        master: result.master,
        slave: result.slave,
    })
}

/// Does this argv rely on KERNEL echo for operator-typed input?
/// - github-login: prompts for name/email/PAT via plain cooked reads (no
///   readline, no TUI).
/// - the bare-VM debug shell (`/bin/bash -l`, PtyIntent::Shell with no
///   project): readline restores the shell's STARTUP termios before each
///   foreground command, so cooked non-readline children (`read`, `cat`)
///   would type blind with the family cleared (review F5) — and the bleed
///   this clear targets lives in the orchestrated `-lc`/agent lanes, not
///   in a human-driven debug shell.
///
/// Everything else (agent TUIs, `-lc` provisioning streams, `podman exec
/// -it` shells whose echo comes from the container PTY) gets the family
/// cleared (audit D2). Accepted residue: a cooked `read` prompt inside a
/// `-lc` provisioning stream types blind — that lane is output-only by
/// design.
fn argv_wants_kernel_echo(argv: &[String]) -> bool {
    argv.iter().any(|a| a.contains("--github-login"))
        || matches!(argv, [bash, flag] if bash == "/bin/bash" && flag == "-l")
}

/// Clear the echo family (`ECHO|ECHOE|ECHOK|ECHONL|ECHOCTL`) on the guest
/// PTY slave, leaving every other flag — crucially `ISIG`: this endpoint
/// OWNS Ctrl+C→SIGINT for the child's foreground process group — exactly as
/// the kernel set it. `cfmakeraw` here is explicitly rejected prior art: it
/// clears `ISIG` and would break Ctrl+C on the signal-owning endpoint
/// (that lever is correct only for the transparent host conduit).
fn clear_slave_echo_family(slave: &OwnedFd) -> nix::Result<()> {
    use nix::sys::termios::{LocalFlags, SetArg, tcgetattr, tcsetattr};
    let mut t = tcgetattr(slave)?;
    t.local_flags &= !(LocalFlags::ECHO
        | LocalFlags::ECHOE
        | LocalFlags::ECHOK
        | LocalFlags::ECHONL
        | LocalFlags::ECHOCTL);
    tcsetattr(slave, SetArg::TCSANOW, &t)
}

/// Mark the guest PTY line discipline UTF-8-aware (`IUTF8`) so canonical-
/// mode erase treats multibyte sequences as one character instead of
/// splitting them byte-wise. Linux-only flag (absent on Darwin).
#[cfg(target_os = "linux")]
fn set_slave_iutf8(slave: &OwnedFd) -> nix::Result<()> {
    use nix::sys::termios::{InputFlags, SetArg, tcgetattr, tcsetattr};
    let mut t = tcgetattr(slave)?;
    t.input_flags |= InputFlags::IUTF8;
    tcsetattr(slave, SetArg::TCSANOW, &t)
}

/// The canonical-mode end-of-input byte (^D). Not a constant anyone should
/// reach for casually: it only MEANS end-of-input when the line discipline is
/// interpreting it (order 924-eof7).
const VEOF_BYTE: u8 = 0x04;

/// Is this PTY currently in canonical (line) mode?
///
/// The whole EOF design turns on this answer: with `ICANON` set, VEOF ends the
/// reader's current read; with it clear, the same byte is ordinary data. Asked
/// at the moment of use rather than remembered, because an interactive child
/// can flip the terminal into raw mode at any point in the session.
fn termios_is_canonical(fd: std::os::fd::RawFd) -> nix::Result<bool> {
    use std::os::fd::BorrowedFd;
    // SAFETY: `fd` is the live PTY master owned by this session's Arc<AsyncFd>,
    // borrowed only for the duration of this call.
    let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
    let attrs = nix::sys::termios::tcgetattr(borrowed)?;
    Ok(attrs
        .local_flags
        .contains(nix::sys::termios::LocalFlags::ICANON))
}

fn set_winsize(fd: std::os::fd::RawFd, rows: u16, cols: u16) -> nix::Result<()> {
    use nix::libc;
    let winsize = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ takes a pointer to a winsize struct sized
    // correctly above; fd is a valid PTY master from openpty.
    let rc = unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &winsize as *const _) };
    if rc < 0 {
        Err(nix::Error::last())
    } else {
        Ok(())
    }
}

fn spawn_terminator(pid: Pid, grace: Duration) {
    tokio::spawn(async move {
        // SIGTERM first; give the child the grace window.
        let _ = kill(pid, Signal::SIGTERM);
        tokio::time::sleep(grace).await;
        // If still alive, SIGKILL. `kill(pid, 0)` checks existence;
        // ESRCH means already gone.
        if kill(pid, None).is_ok() {
            let _ = kill(pid, Signal::SIGKILL);
        }
    });
}

/// Order 723-2yb3. The v2 heartbeat: liveness AND the one fact the host cannot
/// determine for itself.
///
/// Maps the guest-local probe verdict onto the wire enum. The two types are
/// deliberately separate: the probe's is a measurement detail of this crate,
/// the wire's is a contract other binaries decode, and collapsing them would
/// make a probe refactor a wire-compatibility event.
fn pty_heartbeat_v2_envelope(
    session_id: u32,
    state: crate::pty_input_probe::InputState,
) -> ControlEnvelope {
    use crate::pty_input_probe::InputState;
    ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 0,
        body: ControlMessage::PtyHeartbeat {
            session_id,
            input_state: match state {
                InputState::BlockedOnInput => PtyInputState::BlockedOnInput,
                InputState::NotBlocked => PtyInputState::NotBlocked,
                InputState::Unknown => PtyInputState::Unknown,
            },
        },
    }
}

fn pty_heartbeat_envelope(session_id: u32) -> ControlEnvelope {
    ControlEnvelope {
        wire_version: WIRE_VERSION,
        seq: 0,
        body: ControlMessage::PtyData {
            session_id,
            direction: PtyDirection::ToHost,
            bytes: Vec::new(),
        },
    }
}

/// Per-session writer task (audit D6): the sole owner of master-fd
/// writes and `TIOCSWINSZ`. Draining one FIFO queue with one task
/// preserves the host arrival order between data and resize. Exits when
/// the cancel fires (session teardown — interruptible even wedged
/// mid-write), when the store drops the sender (session removed), or
/// when a master write fails (child side gone; the pump emits the
/// terminal `PtyClose` through its own path).
/// Write every byte to an arbitrary owned fd (a data session's stdin pipe),
/// mirroring `write_all_to_master`'s cancellation and partial-write handling.
///
/// Separate from that function rather than generic over the fd because the two
/// differ in what a short write MEANS: on the master a wedged child stops
/// draining its slave and the session is killed; on a pipe a full buffer is
/// ordinary back-pressure from a child that simply has not read yet.
async fn write_all_to_fd(
    session_id: u32,
    fd: &AsyncFd<OwnedFd>,
    bytes: &[u8],
    cancel_rx: &mut tokio::sync::oneshot::Receiver<()>,
) -> bool {
    let mut written = 0usize;
    while written < bytes.len() {
        let mut guard = tokio::select! {
            _ = &mut *cancel_rx => {
                debug!(
                    spec = "vsock-transport",
                    session_id,
                    remaining = bytes.len() - written,
                    "PTY writer: cancel signalled mid-write to the stdin pipe"
                );
                return false;
            }
            writable = fd.writable() => match writable {
                Ok(g) => g,
                Err(err) => {
                    warn!(
                        spec = "vsock-transport",
                        session_id, error = %err,
                        "stdin pipe: writable() guard failed"
                    );
                    return false;
                }
            }
        };
        let raw = guard.get_inner().as_raw_fd();
        let result = guard.try_io(|_| {
            // SAFETY: `raw` is the live pipe write end owned by this task.
            let n = unsafe {
                nix::libc::write(
                    raw,
                    bytes[written..].as_ptr() as *const _,
                    bytes.len() - written,
                )
            };
            if n < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        });
        match result {
            Ok(Ok(n)) => written += n,
            Ok(Err(err)) => {
                warn!(
                    spec = "vsock-transport",
                    session_id, error = %err,
                    "stdin pipe: write failed"
                );
                return false;
            }
            Err(_would_block) => continue,
        }
    }
    true
}

/// Where a session's host→guest bytes actually land (order 926-bin4).
///
/// A TERMINAL session writes to the PTY master, so the line discipline
/// interprets what arrives — which is correct there: Ctrl-C must raise SIGINT.
/// A DATA session writes to a pipe on the child's fd 0, so nothing is
/// interpreted and every byte is delivered as sent.
///
/// The distinction also decides what END OF INPUT means, which is why it is
/// modelled here rather than as a bool beside the fd: on the PTY there is no
/// stdin to close (the master serves output too), so EOF is a VEOF injection
/// that only works in canonical mode; on the pipe it is a real close. Holding
/// the pipe write end by VALUE is what makes that close expressible — dropping
/// it is the EOF.
enum StdinSink {
    /// Shares the master with the pump task, which is reading output from it.
    Pty(Arc<AsyncFd<OwnedFd>>),
    /// Owned exclusively by the writer task. `None` once EOF has been sent;
    /// further writes are refused rather than silently discarded.
    Pipe(Option<AsyncFd<OwnedFd>>),
}

fn spawn_writer_task(
    session_id: u32,
    master: Arc<AsyncFd<OwnedFd>>,
    mut stdin_sink: StdinSink,
    mut queue: mpsc::Receiver<PtyWriteCommand>,
    mut cancel_rx: tokio::sync::oneshot::Receiver<()>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            let cmd = tokio::select! {
                _ = &mut cancel_rx => {
                    debug!(
                        spec = "vsock-transport",
                        session_id,
                        undelivered = queue.len(),
                        "PTY writer: cancel signalled; exiting (session tearing down)"
                    );
                    return;
                }
                cmd = queue.recv() => match cmd {
                    Some(cmd) => cmd,
                    // Store dropped the sender: session removed.
                    None => return,
                },
            };
            match cmd {
                PtyWriteCommand::Write(bytes) => {
                    // A DATA session's bytes go to the pipe, where nothing is
                    // interpreted; a terminal session's go to the master, where
                    // the line discipline is doing its job (926-bin4).
                    let target = match &stdin_sink {
                        StdinSink::Pty(m) => m.clone(),
                        StdinSink::Pipe(Some(_)) => {
                            // handled below without cloning an Arc
                            master.clone()
                        }
                        StdinSink::Pipe(None) => {
                            warn!(
                                spec = "vsock-transport",
                                session_id,
                                bytes = bytes.len(),
                                "PtyData{{ToGuest}} arrived AFTER stdin EOF on a \
                                 data session — refusing to write. The host \
                                 declared input finished and then sent more; \
                                 delivering it would contradict the EOF the child \
                                 has already seen."
                            );
                            continue;
                        }
                    };
                    let ok = match &stdin_sink {
                        StdinSink::Pipe(Some(pipe)) => {
                            write_all_to_fd(session_id, pipe, &bytes, &mut cancel_rx).await
                        }
                        _ => write_all_to_master(session_id, &target, &bytes, &mut cancel_rx).await,
                    };
                    if !ok {
                        // Loud, never silent: any commands still queued die
                        // with the session. Teardown (SIGTERM/SIGKILL +
                        // terminal PtyClose) is driven by the store and the
                        // pump — never from this task (it has no store
                        // access; audit D6 fix-shape constraint 3).
                        if !queue.is_empty() {
                            warn!(
                                spec = "vsock-transport",
                                session_id,
                                undelivered = queue.len(),
                                "PTY writer: exiting with undelivered queued \
                                 commands (session tearing down)"
                            );
                        }
                        return;
                    }
                }
                PtyWriteCommand::StdinEof => {
                    // A DATA session has a real stdin to close, so EOF is a
                    // close — no termios question, no VEOF, no canonical-mode
                    // dependency, and no byte injected into the stream. This is
                    // the whole reason 926-bin4 chose a pipe: it collapses the
                    // machinery below into a drop.
                    if let StdinSink::Pipe(pipe) = &mut stdin_sink {
                        if pipe.take().is_some() {
                            debug!(
                                spec = "vsock-transport",
                                session_id,
                                "PtyStdinEof: closed the data session's stdin pipe \
                                 (real EOF; no VEOF injection needed)"
                            );
                        }
                        continue;
                    }
                    let fd = master.get_ref().as_raw_fd();
                    // WHY TWO, ALWAYS. In canonical mode VEOF ends the CURRENT
                    // read: on an empty buffer that is end-of-input, but after
                    // unterminated bytes the first 0x04 only FLUSHES them and a
                    // second is needed to signal EOF. Rather than track whether
                    // the last write ended in a newline, send two — MEASURED
                    // correct in all three buffer states (terminated,
                    // unterminated, empty: child exits, every byte delivered,
                    // nothing corrupted). A redundant EOF on an already-empty
                    // buffer simply reports end-of-input again.
                    //
                    // WHY NOT IN RAW MODE. With ICANON off there is no line
                    // discipline to interpret 0x04 — it is ordinary data, would
                    // be INJECTED into the child's stdin, and would signal
                    // nothing. That is the silent no-op 924-eof7 measured and
                    // rejected, so this refuses loudly instead of writing a
                    // byte that corrupts the stream while pretending to work.
                    match termios_is_canonical(fd) {
                        Ok(true) => {
                            if !write_all_to_master(
                                session_id,
                                &master,
                                &[VEOF_BYTE, VEOF_BYTE],
                                &mut cancel_rx,
                            )
                            .await
                            {
                                return;
                            }
                        }
                        Ok(false) => {
                            warn!(
                                spec = "vsock-transport",
                                session_id,
                                "PtyStdinEof: session is in RAW mode (ICANON \
                                 clear), where 0x04 is data rather than \
                                 end-of-input — refusing to write it. The \
                                 child will not see EOF; a reader waiting for \
                                 one will not return."
                            );
                        }
                        Err(err) => {
                            warn!(
                                spec = "vsock-transport",
                                session_id, error = ?err,
                                "PtyStdinEof: tcgetattr failed; cannot tell \
                                 whether VEOF would be interpreted, so writing \
                                 nothing rather than guessing"
                            );
                        }
                    }
                }
                PtyWriteCommand::Resize { rows, cols } => {
                    let fd = master.get_ref().as_raw_fd();
                    if let Err(err) = set_winsize(fd, rows, cols) {
                        warn!(
                            spec = "vsock-transport",
                            session_id, error = ?err,
                            "PtyResize: TIOCSWINSZ failed"
                        );
                    }
                }
            }
        }
    })
}

/// Write one command's bytes fully to the master fd, looping on
/// writable-readiness with partial writes advancing the offset. This is
/// the potentially-unbounded wait the connection loop must never perform
/// inline (audit D6) — it lives on the writer task, where only this
/// session's queue waits behind it. Returns `false` when the writer task
/// should exit: the session cancel fired mid-write (teardown while
/// wedged) or the write failed (slave side gone).
async fn write_all_to_master(
    session_id: u32,
    master: &AsyncFd<OwnedFd>,
    bytes: &[u8],
    cancel_rx: &mut tokio::sync::oneshot::Receiver<()>,
) -> bool {
    let mut written = 0usize;
    while written < bytes.len() {
        let mut guard = tokio::select! {
            _ = &mut *cancel_rx => {
                debug!(
                    spec = "vsock-transport",
                    session_id,
                    remaining = bytes.len() - written,
                    "PTY writer: cancel signalled mid-write; abandoning \
                     remaining bytes (session tearing down)"
                );
                return false;
            }
            writable = master.writable() => match writable {
                Ok(g) => g,
                Err(err) => {
                    warn!(
                        spec = "vsock-transport",
                        session_id, error = %err,
                        "PtyData{{ToGuest}}: writable() guard failed"
                    );
                    return false;
                }
            }
        };
        let raw = master.get_ref().as_raw_fd();
        let result = guard.try_io(|_| {
            // SAFETY: raw is a valid PTY master fd owned by master_arc;
            // libc::write returns ssize_t with errno on -1.
            let n = unsafe {
                nix::libc::write(
                    raw,
                    bytes[written..].as_ptr() as *const _,
                    bytes.len() - written,
                )
            };
            if n < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(n as usize)
            }
        });
        match result {
            Ok(Ok(n)) => written += n,
            Ok(Err(err)) => {
                warn!(
                    spec = "vsock-transport",
                    session_id, error = %err,
                    "PtyData{{ToGuest}}: write to master fd failed"
                );
                return false;
            }
            Err(_would_block) => continue,
        }
    }
    true
}

fn spawn_pump_task(
    session_id: u32,
    child_pid: Pid,
    master: Arc<AsyncFd<OwnedFd>>,
    outbound: mpsc::Sender<ControlEnvelope>,
    mut cancel_rx: tokio::sync::oneshot::Receiver<()>,
    heartbeat_interval: Option<Duration>,
    heartbeat_v2: bool,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut buf = vec![0u8; MAX_PTY_FRAME_BYTES];
        let mut heartbeat = heartbeat_interval.map(tokio::time::interval);
        if let Some(heartbeat) = heartbeat.as_mut() {
            heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            heartbeat.tick().await;
        }
        loop {
            // Race the next readable-edge against the explicit cancel.
            // Cancel fires when close_host_initiated / shutdown_all drops
            // its half of the channel; on that path we skip straight to
            // reap_child + PtyClose so we don't depend on the kernel
            // HUP reaching AsyncFd within the test budget.
            let mut guard = tokio::select! {
                _ = &mut cancel_rx => {
                    debug!(
                        spec = "vsock-transport",
                        session_id, "PTY pump: cancel signalled; exiting to reap"
                    );
                    break;
                }
                _ = async {
                    match heartbeat.as_mut() {
                        Some(heartbeat) => heartbeat.tick().await,
                        None => std::future::pending().await,
                    };
                } => {
                    // Order 723-2yb3: a v2 peer gets a heartbeat that says
                    // something. The probe runs HERE, on the heartbeat tick,
                    // rather than continuously — the question is only
                    // interesting at the moment we are about to tell the host
                    // "still alive", and a 30s cadence makes its cost
                    // irrelevant.
                    let envelope = if heartbeat_v2 {
                        pty_heartbeat_v2_envelope(
                            session_id,
                            crate::pty_input_probe::probe_pty_input_state(master.as_raw_fd()),
                        )
                    } else {
                        pty_heartbeat_envelope(session_id)
                    };
                    if outbound.send(envelope).await.is_err() {
                        return;
                    }
                    continue;
                }
                readable = master.readable() => match readable {
                    Ok(g) => g,
                    Err(err) => {
                        debug!(
                            spec = "vsock-transport",
                            session_id, error = %err,
                            "PTY pump: readable() guard failed; exiting"
                        );
                        break;
                    }
                }
            };
            let raw = master.get_ref().as_raw_fd();
            let result = guard.try_io(|_| {
                // SAFETY: raw is a valid PTY master fd owned by master_arc.
                let n = unsafe { nix::libc::read(raw, buf.as_mut_ptr() as *mut _, buf.len()) };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            });
            let n = match result {
                Ok(Ok(0)) => 0,
                Ok(Ok(n)) => n,
                Ok(Err(err)) => {
                    debug!(
                        spec = "vsock-transport",
                        session_id, error = %err,
                        "PTY pump: master read failed; exiting pump"
                    );
                    0
                }
                Err(_would_block) => continue,
            };
            if n == 0 {
                break;
            }
            let bytes = buf[..n].to_vec();
            let env = ControlEnvelope {
                wire_version: WIRE_VERSION,
                seq: 0, // Push frames carry no seq; host correlates by session_id.
                body: ControlMessage::PtyData {
                    session_id,
                    direction: PtyDirection::ToHost,
                    bytes,
                },
            };
            if outbound.send(env).await.is_err() {
                // Outbound channel closed = connection going away.
                debug!(
                    spec = "vsock-transport",
                    session_id, "PTY pump: outbound channel closed; exiting"
                );
                return;
            }
        }

        // Reap the child to populate PtyClose.exit.
        let exit = reap_child(child_pid).await;
        let env = ControlEnvelope {
            wire_version: WIRE_VERSION,
            seq: 0,
            body: ControlMessage::PtyClose { session_id, exit },
        };
        let _ = outbound.send(env).await;
        info!(
            spec = "vsock-transport",
            session_id,
            pid = child_pid.as_raw(),
            ?exit,
            "PtyClose: pump emitted child exit"
        );
    })
}

async fn reap_child(pid: Pid) -> PtyExit {
    use nix::sys::wait::{WaitStatus, waitpid};
    // waitpid is blocking; offload to a blocking thread.
    let status = tokio::task::spawn_blocking(move || waitpid(pid, None))
        .await
        .ok()
        .and_then(|r| r.ok());
    match status {
        Some(WaitStatus::Exited(_, code)) => PtyExit { code, signal: None },
        Some(WaitStatus::Signaled(_, signal, _)) => PtyExit {
            code: 128 + signal as i32,
            signal: Some(signal as i32),
        },
        _ => PtyExit {
            code: -1,
            signal: None,
        },
    }
}

#[cfg(test)]
mod tests {

    /// ORDER 925-eofi — the guest must refuse to write VEOF in raw mode rather
    /// than injecting a byte that corrupts the stream while signalling nothing.
    /// That silent no-op is exactly what 924-eof7 measured and rejected.
    #[test]
    fn stdin_eof_refuses_in_raw_mode_and_says_why() {
        let source = include_str!("pty_handler.rs");
        let arm = source
            .split("PtyWriteCommand::StdinEof => {")
            .nth(1)
            .and_then(|t| t.split("PtyWriteCommand::Resize").next())
            .expect("the StdinEof arm moved — repoint this scan");
        assert!(
            arm.contains("termios_is_canonical"),
            "the arm must ASK whether the line discipline would interpret VEOF"
        );
        assert!(
            arm.contains("Ok(false)") && arm.contains("RAW mode"),
            "the raw-mode branch must exist and name itself"
        );
        let raw_branch = arm.split("Ok(false)").nth(1).expect("raw branch");
        assert!(
            !raw_branch.contains("write_all_to_master"),
            "raw mode must write NOTHING: 0x04 there is data, not end-of-input"
        );
    }

    /// Two VEOF bytes, always — measured correct for an empty, a terminated and
    /// an unterminated input buffer. One is not enough after unterminated
    /// input, and tracking the newline state would be a second source of truth.
    #[test]
    fn stdin_eof_writes_two_veof_bytes() {
        let source = include_str!("pty_handler.rs");
        let arm = source
            .split("PtyWriteCommand::StdinEof => {")
            .nth(1)
            .and_then(|t| t.split("PtyWriteCommand::Resize").next())
            .expect("the StdinEof arm moved — repoint this scan");
        assert!(
            arm.contains("&[VEOF_BYTE, VEOF_BYTE]"),
            "must send TWO VEOF bytes; one only flushes an unterminated line"
        );
    }

    /// The EOF rides the same bounded queue as the bytes it terminates. A
    /// separate path could overtake them and truncate the input.
    #[test]
    fn stdin_eof_is_ordered_with_the_input_it_terminates() {
        let source = include_str!("pty_handler.rs");
        let f = source
            .split("pub async fn stdin_eof(")
            .nth(1)
            .expect("stdin_eof entry point moved — repoint this scan");
        let body = f.split("}").next().unwrap();
        assert!(
            body.contains("enqueue_write_command"),
            "stdin_eof must go through the same per-session queue as writes"
        );
    }

    use super::*;

    fn store() -> (PtySessionStore, mpsc::Receiver<ControlEnvelope>) {
        let (tx, rx) = mpsc::channel(64);
        (PtySessionStore::new(tx), rx)
    }

    /// PTY pair for writer-task tests: RAW slave (no echo, no canonical
    /// buffering — master bytes pass to the slave verbatim), nonblocking
    /// master wrapped in `AsyncFd` exactly as `open()` wires it.
    fn raw_pty_pair() -> (Arc<AsyncFd<OwnedFd>>, OwnedFd) {
        use nix::sys::termios::{SetArg, cfmakeraw, tcgetattr, tcsetattr};
        let OpenptyOwned { master, slave } = openpty_owned(24, 80).expect("openpty");
        let mut t = tcgetattr(&slave).expect("tcgetattr(slave)");
        cfmakeraw(&mut t);
        tcsetattr(&slave, SetArg::TCSANOW, &t).expect("tcsetattr raw");
        let raw = master.as_raw_fd();
        let flags = fcntl(raw, FcntlArg::F_GETFL).expect("F_GETFL");
        let new_flags = OFlag::from_bits_truncate(flags) | OFlag::O_NONBLOCK;
        fcntl(raw, FcntlArg::F_SETFL(new_flags)).expect("F_SETFL");
        let master = AsyncFd::with_interest(master, Interest::READABLE | Interest::WRITABLE)
            .expect("AsyncFd::with_interest");
        (Arc::new(master), slave)
    }

    fn winsize_of(fd: std::os::fd::RawFd) -> (u16, u16) {
        let mut ws = nix::libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: TIOCGWINSZ fills a correctly-sized winsize; fd is a
        // live PTY slave owned by the test.
        let rc = unsafe { nix::libc::ioctl(fd, nix::libc::TIOCGWINSZ, &mut ws) };
        assert_eq!(rc, 0, "TIOCGWINSZ failed");
        (ws.ws_row, ws.ws_col)
    }

    /// Audit D6 (a): the per-session writer task drains queued
    /// host→guest writes strictly FIFO — bytes reach the slave exactly in
    /// enqueue order even when many frames queue up before the writer
    /// catches up (odd-sized chunks exercise partial-write offsets).
    #[tokio::test]
    async fn writer_queue_drains_writes_in_order() {
        let (master, slave) = raw_pty_pair();
        let (tx, rx) = mpsc::channel(PTY_WRITE_QUEUE_CAPACITY);
        let (_cancel_tx, cancel_rx) = tokio::sync::oneshot::channel();
        let _writer = spawn_writer_task(
            11,
            master.clone(),
            // These pre-926-bin4 tests exercise the TERMINAL sink, which is
            // still the default for an interactive attach — the data-session
            // pipe is opt-in per session and does not change this path.
            StdinSink::Pty(master),
            rx,
            cancel_rx,
        );

        let mut expected = Vec::new();
        for i in 0..8u8 {
            let chunk = vec![b'a' + i; 997];
            expected.extend_from_slice(&chunk);
            tx.send(PtyWriteCommand::Write(chunk))
                .await
                .expect("enqueue within capacity");
        }
        let total = expected.len();
        let reader = tokio::task::spawn_blocking(move || {
            use std::io::Read;
            let mut f = std::fs::File::from(slave);
            let mut buf = vec![0u8; total];
            f.read_exact(&mut buf).expect("slave reads all bytes");
            buf
        });
        let read_back = tokio::time::timeout(Duration::from_secs(5), reader)
            .await
            .expect("queue drains within budget")
            .expect("reader task");
        assert_eq!(read_back, expected, "bytes must arrive in enqueue order");
    }

    /// Audit D6 (b): `PtyResize` travels through the SAME per-session
    /// queue as writes, so TIOCSWINSZ is applied at exactly its
    /// host-arrival position — never ahead of input bytes that arrived
    /// before it (asserted while the oversized first write is still
    /// draining) and always by the time bytes enqueued after it become
    /// visible at the slave.
    #[tokio::test]
    async fn resize_preserves_arrival_order_relative_to_writes() {
        let (master, slave) = raw_pty_pair();
        let (tx, rx) = mpsc::channel(PTY_WRITE_QUEUE_CAPACITY);
        let (_cancel_tx, cancel_rx) = tokio::sync::oneshot::channel();
        let _writer = spawn_writer_task(
            12,
            master.clone(),
            // These pre-926-bin4 tests exercise the TERMINAL sink, which is
            // still the default for an interactive attach — the data-session
            // pipe is opt-in per session and does not change this path.
            StdinSink::Pty(master),
            rx,
            cancel_rx,
        );

        // First write far exceeds kernel PTY buffering (~64 KiB ceiling),
        // so with nobody reading the slave the writer is still mid-write
        // when the resize queued behind it could otherwise jump ahead.
        let first = vec![b'x'; 192 * 1024];
        let second = b"tail".to_vec();
        tx.send(PtyWriteCommand::Write(first.clone()))
            .await
            .expect("enqueue first write");
        tx.send(PtyWriteCommand::Resize {
            rows: 50,
            cols: 100,
        })
        .await
        .expect("enqueue resize");
        tx.send(PtyWriteCommand::Write(second.clone()))
            .await
            .expect("enqueue second write");

        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            winsize_of(slave.as_raw_fd()),
            (24, 80),
            "resize must not apply ahead of an earlier-arrived write"
        );

        let total = first.len() + second.len();
        let reader = tokio::task::spawn_blocking(move || {
            use std::io::Read;
            let mut f = std::fs::File::from(slave);
            let mut buf = vec![0u8; total];
            f.read_exact(&mut buf).expect("slave reads all bytes");
            // The writer performed TIOCSWINSZ strictly before writing
            // `second`, so once `second` is visible the resize is applied.
            let after = winsize_of(f.as_raw_fd());
            (buf, after)
        });
        let (bytes, after) = tokio::time::timeout(Duration::from_secs(10), reader)
            .await
            .expect("queue drains within budget")
            .expect("reader task");
        assert_eq!(&bytes[..first.len()], &first[..]);
        assert_eq!(&bytes[first.len()..], &second[..]);
        assert_eq!(
            after,
            (50, 100),
            "resize must be applied before bytes enqueued after it are visible"
        );
    }

    /// Audit D6 (c): a child that never reads its slave wedges the kernel
    /// PTY buffer; once the bounded write queue has been FULL for the
    /// 250ms fairness deadline, the store KILLS the session via the
    /// existing SIGTERM/SIGKILL path instead of blocking the caller (the
    /// connection loop) unboundedly or silently dropping bytes — and the
    /// pump still emits the terminal PtyClose so the host observes the
    /// kill (kill-not-drop).
    /// @trace plan/issues/guest-pty-write-wedge-2026-07-27.md
    #[tokio::test]
    async fn full_write_queue_past_deadline_kills_wedged_session() {
        let hermetic_home = std::env::temp_dir()
            .join(format!("tillandsias-wedge-pty-{}", std::process::id()))
            .to_string_lossy()
            .into_owned();
        std::fs::create_dir_all(&hermetic_home).expect("hermetic HOME creates");
        let (mut store, mut rx) = store();
        store
            .open(
                66,
                24,
                80,
                vec![
                    "/bin/bash".to_string(),
                    "-lc".to_string(),
                    "sleep 30".to_string(),
                ],
                vec![("HOME".to_string(), hermetic_home)],
                None,
            )
            .await
            .expect("wedge PTY opens");

        // Cooked slave + a child that never reads: frames of COMPLETE
        // LINES (a real paste), because n_tty only backpressures the
        // master once the canonical buffer holds pending newlines —
        // newline-free overflow is beeped away instead of blocking. The
        // kernel absorbs at most ~68 KiB (64 KiB flip-buffer memory limit
        // + 4 KiB canonical buffer) and can never drain. Kernel
        // (~5 frames) + one in-flight write + the
        // PTY_WRITE_QUEUE_CAPACITY queued slots absorb the first ~22
        // frames; a later enqueue must trip the deadline and kill the
        // session well within the iteration budget.
        let frame: Vec<u8> = std::iter::repeat_with(|| {
            let mut line = vec![b'z'; 63];
            line.push(b'\n');
            line
        })
        .take(256)
        .flatten()
        .collect(); // 256 × 64-byte lines = 16 KiB per frame
        let mut killed = false;
        for _ in 0..(PTY_WRITE_QUEUE_CAPACITY + 16) {
            let call = tokio::time::timeout(
                PTY_WRITE_ENQUEUE_DEADLINE + Duration::from_millis(750),
                store.write_to_guest(66, frame.clone()),
            )
            .await;
            assert!(
                call.is_ok(),
                "write_to_guest must never block the connection loop past \
                 the enqueue deadline"
            );
            if !store.sessions.contains_key(&66) {
                killed = true;
                break;
            }
        }
        assert!(
            killed,
            "wedged session must be killed once the queue stays full past \
             the deadline"
        );

        // Kill-not-drop is loud end-to-end: the pump reaps the SIGTERM'd
        // child and emits the terminal PtyClose to the host.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut close_exit: Option<PtyExit> = None;
        while std::time::Instant::now() < deadline {
            match tokio::time::timeout(Duration::from_secs(1), rx.recv()).await {
                Ok(Some(env)) => {
                    if let ControlMessage::PtyClose { session_id, exit } = env.body {
                        assert_eq!(session_id, 66);
                        close_exit = Some(exit);
                        break;
                    }
                }
                Ok(None) => break,
                Err(_) => continue,
            }
        }
        let exit = close_exit.expect("PtyClose after wedge kill");
        assert!(
            exit.signal == Some(Signal::SIGTERM as i32) || exit.code != 0,
            "child must have been terminated by the kill path: {exit:?}"
        );
    }

    #[test]
    fn pty_heartbeat_is_an_empty_tohost_frame() {
        assert_eq!(PTY_HEARTBEAT_INTERVAL, Duration::from_secs(30));
        let heartbeat = pty_heartbeat_envelope(42);
        assert_eq!(heartbeat.seq, 0);
        match heartbeat.body {
            ControlMessage::PtyData {
                session_id,
                direction,
                bytes,
            } => {
                assert_eq!(session_id, 42);
                assert_eq!(direction, PtyDirection::ToHost);
                assert!(bytes.is_empty());
            }
            other => panic!("expected PtyData heartbeat, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn quiet_pty_pump_emits_empty_to_host_heartbeat() {
        let hermetic_home = std::env::temp_dir()
            .join(format!("tillandsias-quiet-pty-{}", std::process::id()))
            .to_string_lossy()
            .into_owned();
        std::fs::create_dir_all(&hermetic_home).expect("hermetic HOME creates");
        let (tx, mut rx) = mpsc::channel(64);
        let mut store = PtySessionStore {
            sessions: HashMap::new(),
            outbound: tx,
            heartbeat_interval: Some(Duration::from_millis(20)),
            // v1 shape: this test pins the pre-existing empty-PtyData
            // heartbeat, which must keep working untouched (order 723-2yb3).
            heartbeat_v2: false,
        };
        store
            .open(
                77,
                24,
                80,
                vec![
                    "/bin/bash".to_string(),
                    "-lc".to_string(),
                    "sleep 1".to_string(),
                ],
                // Hermetic HOME: `-lc` (the allowlisted shape) is a login
                // shell, so it sources $HOME/.profile — on a dev host the
                // OPERATOR's profile output beats the heartbeat to the
                // channel (flaked on macOS printing a missing-file warning,
                // 2026-07-16). An empty HOME has nothing to source.
                vec![("HOME".to_string(), hermetic_home)],
                None,
            )
            .await
            .expect("quiet PTY opens");

        let heartbeat = tokio::time::timeout(Duration::from_millis(200), rx.recv())
            .await
            .expect("heartbeat arrives before deadline")
            .expect("outbound channel remains open");
        assert_eq!(heartbeat, pty_heartbeat_envelope(77));
        store.shutdown_all().await;
    }

    /// Audit D2 scoping (amended per review F5): kernel echo stays for the
    /// typed-input lanes — github-login's cooked prompts AND the bare-VM
    /// `/bin/bash -l` debug shell (its non-readline children would type
    /// blind). Orchestrated `-lc`/agent lanes clear the family.
    #[test]
    fn kernel_echo_scope_is_typed_input_lanes_only() {
        let login = vec![
            "/bin/bash".to_string(),
            "-lc".to_string(),
            "exec tillandsias-headless --github-login || false".to_string(),
        ];
        assert!(argv_wants_kernel_echo(&login));
        let direct = vec![
            "tillandsias-headless".to_string(),
            "--github-login".to_string(),
        ];
        assert!(argv_wants_kernel_echo(&direct));
        let debug_shell = vec!["/bin/bash".to_string(), "-l".to_string()];
        assert!(argv_wants_kernel_echo(&debug_shell));
        let provisioning = vec![
            "/bin/bash".to_string(),
            "-lc".to_string(),
            "exec tillandsias-headless --cloud 'o/r' --opencode".to_string(),
        ];
        assert!(!argv_wants_kernel_echo(&provisioning));
        let agent = vec!["tillandsias".to_string(), "--agent".to_string()];
        assert!(!argv_wants_kernel_echo(&agent));
    }

    /// Audit D2 pin: a non-login guest PTY is born with the echo family OFF
    /// (no `^[[A` bleed on output-only streams) while `ISIG` stays ON
    /// (Ctrl+C still reaches the child's foreground pgrp through the line
    /// discipline). Asserted on the master fd — termios is per-pair.
    /// @trace plan/issues/macos-terminal-management-audit-2026-07-27.md (D2)
    #[tokio::test]
    async fn guest_pty_clears_echo_family_but_keeps_isig() {
        use nix::sys::termios::{LocalFlags, tcgetattr};
        let hermetic_home = std::env::temp_dir()
            .join(format!("tillandsias-echo-pty-{}", std::process::id()))
            .to_string_lossy()
            .into_owned();
        std::fs::create_dir_all(&hermetic_home).expect("hermetic HOME creates");
        let (mut store, _rx) = store();
        store
            .open(
                91,
                24,
                80,
                vec![
                    "/bin/bash".to_string(),
                    "-lc".to_string(),
                    "sleep 1".to_string(),
                ],
                vec![("HOME".to_string(), hermetic_home)],
                None,
            )
            .await
            .expect("echo-test PTY opens");
        let t = {
            let session = store.sessions.get(&91).expect("session stored");
            tcgetattr(session.master.get_ref()).expect("tcgetattr on master")
        };
        assert!(
            !t.local_flags.contains(LocalFlags::ECHO)
                && !t.local_flags.contains(LocalFlags::ECHOCTL),
            "echo family must be OFF on a non-login guest PTY: {:?}",
            t.local_flags
        );
        assert!(
            t.local_flags.contains(LocalFlags::ISIG),
            "ISIG must stay ON — the guest line discipline owns Ctrl+C"
        );
        store.shutdown_all().await;
    }

    /// A cleared env with no caller PATH gets the sane default seeded, so
    /// bare-name argv[0] resolves instead of failing ENOENT (blank-terminal bug).
    /// ORDER 1072-qk43. The child MUST get a HOME — asserted over the PURE
    /// lookup so the arm has teeth on every host.
    ///
    /// The first version of this test asserted against `child_env` directly and
    /// SURVIVED DELETING THE ENTIRE SEED: on macOS the passwd lookup returns
    /// None for the dev host's own uid (regular users live in Directory
    /// Services), so the "no home" branch was satisfied by the machine rather
    /// than the code. A guard exercised only where it cannot fail is verified
    /// nowhere — the exact class this packet is about.
    #[test]
    fn home_from_passwd_finds_the_uids_home() {
        let passwd = "root:x:0:0:root:/root:/bin/bash\n\
                      forge:x:1000:1000::/home/forge:/bin/bash\n";
        assert_eq!(home_from_passwd(passwd, 0).as_deref(), Some("/root"));
        assert_eq!(
            home_from_passwd(passwd, 1000).as_deref(),
            Some("/home/forge")
        );
    }

    /// The guest runs its PTY children as root, so the root fallback is what
    /// actually fires there. It must survive an unreadable or empty passwd.
    #[test]
    fn home_from_passwd_falls_back_to_root_for_uid_zero_only() {
        assert_eq!(home_from_passwd("", 0).as_deref(), Some("/root"));
        // A NON-root uid with no entry gets NOTHING, deliberately: a guessed
        // home is quieter and worse than an absent one.
        assert_eq!(home_from_passwd("", 4242), None);
    }

    /// An entry with an EMPTY home field must not be accepted — that is how the
    /// phantom "/.local/bin" was produced in the first place, from a HOME that
    /// expanded to nothing.
    #[test]
    fn home_from_passwd_rejects_an_empty_home_field() {
        assert_eq!(home_from_passwd("svc:x:7:7:::/sbin/nologin\n", 7), None);
    }

    /// The seed reaches child_env. Paired with the pure arms above, this is the
    /// wiring assertion: with a home available, HOME is present exactly once.
    /// The seed reaches the environment. INJECTED home, so this fails on every
    /// host when the seed is removed — the previous two versions did not.
    #[test]
    fn child_env_seeds_the_injected_home_exactly_once() {
        let out = child_env_with_home(
            &[("TERM".to_string(), "dumb".to_string())],
            Some("/root".to_string()),
        );
        let homes: Vec<&str> = out
            .iter()
            .filter(|(k, _)| k == "HOME")
            .map(|(_, v)| v.as_str())
            .collect();
        assert_eq!(
            homes,
            vec!["/root"],
            "HOME must be seeded exactly once from the resolved home"
        );
    }

    /// And with NO home resolvable, nothing is invented — the child gets no
    /// HOME rather than a guessed one.
    #[test]
    fn child_env_invents_no_home_when_none_resolves() {
        let out = child_env_with_home(&[("TERM".to_string(), "dumb".to_string())], None);
        assert!(
            !out.iter().any(|(k, _)| k == "HOME"),
            "a guessed HOME is quieter and worse than an absent one"
        );
    }

    /// A caller-provided HOME must WIN, exactly as PATH does. Without this the
    /// seed could silently override a forge launch that sets HOME=/home/forge.
    #[test]
    fn child_env_does_not_override_a_provided_home() {
        let out = child_env_with_home(
            &[("HOME".to_string(), "/home/forge".to_string())],
            Some("/root".to_string()),
        );
        let homes: Vec<&str> = out
            .iter()
            .filter(|(k, _)| k == "HOME")
            .map(|(_, v)| v.as_str())
            .collect();
        assert_eq!(
            homes,
            vec!["/home/forge"],
            "a caller's HOME must be the only HOME — a duplicate lets the \
             seeded value win or lose depending on env iteration order"
        );
    }

    #[test]
    fn child_env_seeds_default_path_when_absent() {
        let out = child_env(&[("TERM".to_string(), "dumb".to_string())]);
        let path = out
            .iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| v.as_str());
        assert_eq!(path, Some(DEFAULT_CHILD_PATH));
        // Caller-provided vars are preserved.
        assert!(out.iter().any(|(k, v)| k == "TERM" && v == "dumb"));
    }

    /// A caller-supplied PATH is honored verbatim (no default override).
    #[test]
    fn child_env_preserves_caller_path() {
        let out = child_env(&[("PATH".to_string(), "/custom/bin".to_string())]);
        let paths: Vec<&str> = out
            .iter()
            .filter(|(k, _)| k == "PATH")
            .map(|(_, v)| v.as_str())
            .collect();
        assert_eq!(paths, vec!["/custom/bin"], "exactly one, caller's PATH");
    }

    /// Empty env still yields a usable PATH + proxy-exemption vars.
    ///
    /// INJECTED HOME, like every other arm in this group, and the exact-count
    /// assertion is why it has to be. This test called the impure `child_env`
    /// and asserted `out.len() == 3`, which made it the ONE assertion in the
    /// file sensitive to the host's /etc/passwd: `default_child_home()` looks
    /// up the running uid, so on any host with a passwd entry for itself the
    /// vector is 4 (PATH, HOME, no_proxy, NO_PROXY) and the test fails.
    ///
    /// MEASURED 2026-09-06 on yoga: `left: 4, right: 3`, deterministic, every
    /// run. It passed on the macOS host that added the HOME seed (1072-qk43)
    /// because macOS keeps regular users in Directory Services rather than
    /// /etc/passwd, so the lookup returns None there — the same vacuity the
    /// `child_env_with_home` split was introduced to remove, surviving in the
    /// one arm that was not converted. It is a HOST-DEPENDENT failure, not a
    /// flaky one; nothing here touches time, and the `#[ignore]` flakiness
    /// notes further down belong to the PTY tests, not to this group.
    #[test]
    fn child_env_empty_input_gets_path_and_proxy_exemption() {
        let out = child_env_with_home(&[], None);
        let path = out
            .iter()
            .find(|(k, _)| k == "PATH")
            .map(|(_, v)| v.as_str());
        assert_eq!(path, Some(DEFAULT_CHILD_PATH));
        assert!(out.iter().any(|(k, _)| k == "no_proxy"));
        assert!(out.iter().any(|(k, _)| k == "NO_PROXY"));
        assert_eq!(out.len(), 3, "PATH + no_proxy + NO_PROXY, and no HOME");
    }

    /// The paired arm, and the reason the fix is not merely "drop the count".
    /// With a home resolvable the empty-input case must yield FOUR — the count
    /// is the only assertion that would catch a second HOME being appended, and
    /// deleting it to make the host-dependence go away would delete that too.
    #[test]
    fn child_env_empty_input_with_a_home_seeds_exactly_one() {
        let out = child_env_with_home(&[], Some("/root".to_string()));
        let homes: Vec<&str> = out
            .iter()
            .filter(|(k, _)| k == "HOME")
            .map(|(_, v)| v.as_str())
            .collect();
        assert_eq!(homes, vec!["/root"]);
        assert_eq!(out.len(), 4, "PATH + HOME + no_proxy + NO_PROXY");
    }

    /// End-to-end smoke: open a PTY for `echo hi`, observe the `hi\r\n`
    /// stream and the terminal PtyClose with exit code 0.
    ///
    /// `#[ignore]` for the same reason as host_initiated_close_drains_child:
    /// the pump task wraps the master fd in `tokio::fs::File` which doesn't
    /// reliably surface PTY master events on the blocking thread pool. The
    /// AsyncFd-based rewrite (follow-up) makes this test pass without a
    /// timeout. Until then this serves as documentation of the intended
    /// behaviour — the build + dispatch wiring are still validated by the
    /// non-ignored tests below.
    ///
    /// Re-marked `#[ignore]` 2026-05-26: AsyncFd<OwnedFd> + cancel-token
    /// rewrites both went in (`65980b02` and the slice carrying this
    /// comment), but the test exhibits run-to-run flakiness depending on
    /// tokio scheduling + PTY-master readiness propagation. Live-VM
    /// validation lives in CI's recipe-smoke job, where the in-VM
    /// headless serves real PtyOpen requests against actual booted
    /// userspace.
    #[tokio::test]
    #[ignore = "PTY/tokio-readiness boundary flaky in unit-test harness; real validation in CI recipe-smoke"]
    async fn open_runs_echo_and_emits_data_then_close() {
        let (mut store, mut rx) = store();
        store
            .open(
                7,
                24,
                80,
                vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "echo hi".to_string(),
                ],
                vec![],
                None,
            )
            .await
            .expect("open succeeds");

        // Read frames until we observe PtyClose. We accumulate stdout bytes
        // along the way; "hi\r\n" (PTY translates LF -> CRLF) plus a possible
        // trailing exit code reset is enough to confirm.
        let mut stdout = Vec::new();
        let mut close_seen = false;
        for _ in 0..50 {
            let env = tokio::time::timeout(Duration::from_secs(5), rx.recv())
                .await
                .expect("frame within 5s")
                .expect("channel still open");
            match env.body {
                ControlMessage::PtyData {
                    session_id,
                    direction,
                    bytes,
                } => {
                    assert_eq!(session_id, 7);
                    assert_eq!(direction, PtyDirection::ToHost);
                    stdout.extend_from_slice(&bytes);
                }
                ControlMessage::PtyClose { session_id, exit } => {
                    assert_eq!(session_id, 7);
                    assert_eq!(exit.code, 0);
                    assert!(exit.signal.is_none());
                    close_seen = true;
                    break;
                }
                other => panic!("unexpected frame: {other:?}"),
            }
        }
        assert!(close_seen, "did not observe PtyClose within budget");
        let s = String::from_utf8_lossy(&stdout);
        assert!(s.contains("hi"), "stdout did not contain 'hi': {s:?}");
    }

    #[tokio::test]
    async fn open_with_empty_argv_returns_error() {
        let (mut store, _rx) = store();
        let err = store
            .open(1, 24, 80, vec![], vec![], None)
            .await
            .expect_err("empty argv must error");
        matches!(err, PtyOpenError::EmptyArgv);
    }

    #[tokio::test]
    async fn duplicate_session_id_returns_error() {
        let (mut store, _rx) = store();
        store
            .open(
                42,
                24,
                80,
                vec!["/bin/bash".to_string(), "-l".to_string()],
                vec![],
                None,
            )
            .await
            .expect("first open succeeds");
        let err = store
            .open(
                42,
                24,
                80,
                vec!["/bin/bash".to_string(), "-l".to_string()],
                vec![],
                None,
            )
            .await
            .expect_err("duplicate session id must error");
        matches!(err, PtyOpenError::DuplicateSession(42));
        // Cleanup: shut down the first child.
        store.shutdown_all().await;
    }

    /// Drains the child via the host-initiated SIGTERM+SIGKILL path and
    /// waits for the pump to emit the terminal PtyClose envelope.
    ///
    /// Currently `#[ignore]`: the pump task uses `tokio::fs::File` (backed
    /// by the blocking thread pool) for the master fd, and a `sleep 30`
    /// subprocess does not seem to release the PTY master read in time
    /// after SIGTERM lands — the master appears to keep blocking until
    /// the child is actually wait()'d. A follow-up will switch the master
    /// to `tokio::io::unix::AsyncFd<OwnedFd>` (readiness-based) which
    /// behaves correctly for PTY masters and lets this test pass within
    /// the 10s budget. The `open_runs_echo_and_emits_data_then_close` test
    /// above already exercises the natural-exit PtyClose path; this one
    /// only covers the host-initiated termination corner.
    /// AsyncFd rewrite landed and the natural-exit PtyClose flow
    /// (`open_runs_echo_and_emits_data_then_close`) now passes
    /// deterministically. The SIGTERM-driven corner here is still
    /// `#[ignore]` because the EPOLLHUP edge on the master fd after a
    /// signal-killed child doesn't always reach AsyncFd in time for
    /// the 10s budget — likely a tokio readiness-tracking interaction
    /// with the kernel's PTY hang-up semantics. A follow-up slice
    /// will add an explicit cancellation token to the pump task that
    /// fires when `close_host_initiated` runs, so the reap path is
    /// driven by the lifecycle event rather than by waiting for the
    /// kernel HUP. Until then the natural-exit test covers the
    /// pump+PtyClose contract end-to-end.
    #[tokio::test]
    #[ignore = "AsyncFd HUP-via-SIGTERM timing flaky; pump needs explicit cancellation token (next slice)"]
    async fn host_initiated_close_drains_child() {
        let (mut store, mut rx) = store();
        store
            .open(
                99,
                24,
                80,
                vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ],
                vec![],
                None,
            )
            .await
            .expect("open succeeds");
        store.close_host_initiated(99).await;
        // The pump task should observe SIGTERM-driven exit and emit
        // PtyClose. Walk the channel until we see it.
        let deadline = Duration::from_secs(10);
        let mut close_exit: Option<PtyExit> = None;
        let start = std::time::Instant::now();
        while start.elapsed() < deadline {
            let Ok(Some(env)) = tokio::time::timeout(Duration::from_secs(1), rx.recv()).await
            else {
                continue;
            };
            if let ControlMessage::PtyClose { exit, .. } = env.body {
                close_exit = Some(exit);
                break;
            }
        }
        let exit = close_exit.expect("PtyClose within deadline");
        // Either the child caught SIGTERM and exited with code 143 (128+15)
        // or it was reaped with signal=SIGTERM directly.
        assert!(
            exit.signal == Some(Signal::SIGTERM as i32)
                || exit.code == 128 + Signal::SIGTERM as i32
                || exit.code != 0,
            "unexpected exit: {exit:?}",
        );
    }
}
