// @trace order:1534-puyz, spec:command-runtime
//! Script-owned supervision. No Lua value or callback crosses this boundary.
//! Supervisors run independently of the Lua thread, including during a CPU loop.

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;
use tokio::sync::{mpsc, watch};

/// A line excludes only LF. CR and non-UTF8 bytes are the producer's bytes.
#[derive(Debug)]
pub enum Event {
    Line {
        process: u64,
        fd: &'static str,
        bytes: Vec<u8>,
    },
    Finished(u64),
}

/// A bound on an individual unterminated line, independent of capture.
pub const MAX_LINE_BYTES: usize = 1024 * 1024;
pub const MAX_ACTIVE_PROCESSES: usize = 64;
pub const CLEANUP_BOUND: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, PartialEq)]
enum Stop {
    Running,
    Kill,
    Close,
}

struct State {
    finished: AtomicBool,
    result: Mutex<Option<Result<Output, ExecError>>>,
    done: Condvar,
}

#[derive(Clone)]
pub struct Process {
    pub id: u64,
    state: Arc<State>,
    cancel: watch::Sender<Stop>,
}

impl Process {
    pub fn kill(&self) {
        let _ = self.cancel.send(Stop::Kill);
    }
    pub fn result(&self) -> Option<Result<Output, String>> {
        self.state
            .result
            .lock()
            .unwrap()
            .as_ref()
            .map(|r| r.as_ref().map(Clone::clone).map_err(ToString::to_string))
    }
    fn wait(&self) -> Result<Output, ExecError> {
        let mut result = self.state.result.lock().unwrap();
        while result.is_none() {
            result = self.state.done.wait(result).unwrap();
        }
        result.take().unwrap()
    }
}

struct Inner {
    closed: AtomicBool,
    processes: Mutex<Vec<Process>>,
    next: AtomicU64,
    deadline: Option<Instant>,
    events: mpsc::Sender<Event>,
}

#[derive(Clone)]
pub struct Scope(Arc<Inner>);

impl Scope {
    pub fn new(deadline: Option<Instant>) -> (Self, mpsc::Receiver<Event>) {
        // Lines have a separate size bound. Backpressure is never capture clipping.
        let (events, rx) = mpsc::channel(32);
        (
            Self(Arc::new(Inner {
                closed: AtomicBool::new(false),
                processes: Mutex::new(Vec::new()),
                next: AtomicU64::new(1),
                deadline,
                events,
            })),
            rx,
        )
    }
    pub fn stopped(&self) -> bool {
        self.0.closed.load(Ordering::Acquire)
            || self.0.deadline.is_some_and(|d| Instant::now() >= d)
    }
    /// Linearizes shutdown against spawn AND registration. The supervisor owns
    /// a successfully spawned child before the caller can obtain its handle.
    pub fn spawn(&self, command: Command, stream: bool) -> Result<Process, ExecError> {
        let mut processes = self.0.processes.lock().unwrap();
        if self.stopped() {
            return Err(scope_error(&command, "script-scope-closed"));
        }
        processes.retain(|p| !p.state.finished.load(Ordering::Acquire));
        if processes.len() >= MAX_ACTIVE_PROCESSES {
            return Err(scope_error(&command, "script-process-limit"));
        }
        let id = self.0.next.fetch_add(1, Ordering::Relaxed);
        let (cancel, rx) = watch::channel(Stop::Running);
        let state = Arc::new(State {
            finished: AtomicBool::new(false),
            result: Mutex::new(None),
            done: Condvar::new(),
        });
        let process = Process {
            id,
            state: state.clone(),
            cancel,
        };
        let events = stream.then(|| self.0.events.clone());
        let deadline = self.0.deadline;
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let argv = command.argv.clone();
        let thread_argv = argv.clone();
        std::thread::Builder::new()
            .name(format!("proc-{id}"))
            .spawn(move || {
                let result = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => {
                        let result =
                            rt.block_on(supervise(command, id, rx, deadline, events, ready_tx));
                        // Windows pipe helper threads must not turn shutdown into an
                        // unbounded runtime drop (legacy group=false is still limited).
                        rt.shutdown_background();
                        result
                    }
                    Err(source) => {
                        let _ = ready_tx.send(Err(ExecError::Io {
                            argv: argv.clone(),
                            source,
                        }));
                        return;
                    }
                };
                *state.result.lock().unwrap() = Some(result);
                state.finished.store(true, Ordering::Release);
                state.done.notify_all();
            })
            .map_err(|source| ExecError::Io {
                argv: thread_argv,
                source,
            })?;
        // No await holds this lock. Setup cannot invoke Lua or await a pipe.
        ready_rx.recv().map_err(|e| ExecError::Io {
            argv: Vec::new(),
            source: std::io::Error::other(e.to_string()),
        })??;
        processes.push(process.clone());
        Ok(process)
    }
    pub fn run(&self, command: Command) -> Result<Output, ExecError> {
        self.spawn(command, false)?.wait()
    }
    pub fn close(&self) {
        let processes = self.0.processes.lock().unwrap();
        self.0.closed.store(true, Ordering::Release);
        for p in processes.iter() {
            let _ = p.cancel.send(Stop::Close);
        }
    }
    /// Bounded, explicit direct-child reap. Does NOT claim to waitpid grandchildren.
    pub fn cleanup(&self) -> Result<(), String> {
        self.close();
        let deadline = Instant::now() + CLEANUP_BOUND;
        let processes = self.0.processes.lock().unwrap().clone();
        for p in processes {
            let mut r = p.state.result.lock().unwrap();
            while !p.state.finished.load(Ordering::Acquire) {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err("script-cleanup-incomplete".into());
                }
                r = p.state.done.wait_timeout(r, left).unwrap().0;
            }
        }
        Ok(())
    }
}

fn scope_error(command: &Command, message: &str) -> ExecError {
    ExecError::Io {
        argv: command.argv.clone(),
        source: std::io::Error::other(message),
    }
}

async fn cancelled(rx: &mut watch::Receiver<Stop>) {
    loop {
        if *rx.borrow_and_update() != Stop::Running {
            return;
        }
        if rx.changed().await.is_err() {
            return;
        }
    }
}

async fn scope_cancelled(rx: &mut watch::Receiver<Stop>) {
    loop {
        if *rx.borrow_and_update() == Stop::Close {
            return;
        }
        if rx.changed().await.is_err() {
            return;
        }
    }
}

async fn read_stream<R: tokio::io::AsyncRead + Unpin>(
    mut pipe: R,
    cap: usize,
    id: u64,
    fd: &'static str,
    events: Option<mpsc::Sender<Event>>,
    mut leader: watch::Receiver<bool>,
) -> std::io::Result<(Vec<u8>, u64)> {
    use tokio::io::AsyncReadExt;
    let mut kept = Vec::new();
    let mut dropped = 0;
    let mut pending = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        // Bound PIPE EOF after leader exit, not callback delivery time. Sending
        // queued lines may take arbitrarily long within the process deadline.
        let read = async {
            if *leader.borrow() {
                tokio::time::timeout(GROUP_DRAIN_GRACE, pipe.read(&mut buf))
                    .await
                    .map_err(|_| std::io::Error::other("group-pipe-eof-timeout"))?
            } else {
                tokio::select! {
                    r = pipe.read(&mut buf) => r,
                    _ = leader.changed() => {
                        tokio::time::timeout(GROUP_DRAIN_GRACE, pipe.read(&mut buf)).await
                            .map_err(|_| std::io::Error::other("group-pipe-eof-timeout"))?
                    }
                }
            }
        };
        let n = read.await?;
        let take = cap.saturating_sub(kept.len()).min(n);
        kept.extend_from_slice(&buf[..take]);
        dropped += (n - take) as u64;
        if let Some(tx) = &events {
            for &byte in &buf[..n] {
                if byte == b'\n' {
                    tx.send(Event::Line {
                        process: id,
                        fd,
                        bytes: std::mem::take(&mut pending),
                    })
                    .await
                    .map_err(|_| std::io::Error::other("script-stream-closed"))?;
                } else {
                    if pending.len() == MAX_LINE_BYTES {
                        return Err(std::io::Error::other("proc-line-too-long"));
                    }
                    pending.push(byte);
                }
            }
        }
        if n == 0 {
            break;
        }
    }
    if let Some(tx) = &events {
        if !pending.is_empty() {
            tx.send(Event::Line {
                process: id,
                fd,
                bytes: pending,
            })
            .await
            .map_err(|_| std::io::Error::other("script-stream-closed"))?;
        }
    }
    Ok((kept, dropped))
}

async fn supervise(
    command: Command,
    id: u64,
    mut cancel: watch::Receiver<Stop>,
    deadline: Option<Instant>,
    events: Option<mpsc::Sender<Event>>,
    ready: std::sync::mpsc::Sender<Result<(), ExecError>>,
) -> Result<Output, ExecError> {
    if deadline.is_some_and(|d| Instant::now() >= d) {
        let _ = ready.send(Err(scope_error(&command, "script-scope-closed")));
        return Err(scope_error(&command, "script-scope-closed"));
    }
    let Some((program, rest)) = command.argv.split_first() else {
        let _ = ready.send(Err(ExecError::EmptyArgv));
        return Err(ExecError::EmptyArgv);
    };
    protect_parent_std_handles();
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(rest)
        .stdin(if command.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(cwd) = &command.cwd {
        cmd.current_dir(cwd);
    }
    if command.env_clear {
        cmd.env_clear();
    }
    for (k, v) in &command.envs {
        cmd.env(k, v);
    }
    #[cfg(unix)]
    if command.group {
        cmd.process_group(0);
    }
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(source) => {
            let _ = ready.send(Err(ExecError::Spawn {
                argv: command.argv.clone(),
                source,
            }));
            return Err(scope_error(&command, "spawn-failed"));
        }
    };
    #[cfg(unix)]
    let pgid = command.group.then(|| child.id()).flatten();
    #[cfg(windows)]
    let job = if command.group {
        match win_job::JobObject::assign(&child) {
            Ok(job) => Some(job),
            Err(source) => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                let _ = ready.send(Err(ExecError::Io {
                    argv: command.argv.clone(),
                    source,
                }));
                return Err(scope_error(&command, "job-assignment-failed"));
            }
        }
    } else {
        None
    };
    let _ = ready.send(Ok(()));
    let out = child.stdout.take().unwrap();
    let err = child.stderr.take().unwrap();
    let input = child.stdin.take();
    let (leader_tx, leader_rx) = watch::channel(false);
    let started = Instant::now();
    let process_deadline = command.timeout.and_then(|d| started.checked_add(d));
    let end = match (deadline, process_deadline) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    };
    let timer = async {
        match end {
            Some(d) => tokio::time::sleep_until(tokio::time::Instant::from_std(d)).await,
            None => std::future::pending().await,
        }
    };
    let io = async {
        use tokio::io::AsyncWriteExt;
        let feed = async {
            if let (Some(mut input), Some(bytes)) = (input, &command.stdin) {
                if let Err(e) = input.write_all(bytes).await {
                    if e.kind() != std::io::ErrorKind::BrokenPipe {
                        return Err(e);
                    }
                }
            }
            Ok::<(), std::io::Error>(())
        };
        let (a, b, _) = tokio::try_join!(
            read_stream(
                out,
                command.capture_bytes,
                id,
                "stdout",
                events.clone(),
                leader_rx.clone()
            ),
            read_stream(
                err,
                command.capture_bytes,
                id,
                "stderr",
                events.clone(),
                leader_rx
            ),
            feed
        )?;
        Ok::<_, std::io::Error>((a.0, b.0, a.1 + b.1))
    };
    tokio::pin!(io);
    tokio::pin!(timer);
    let mut drained = None;
    let mut status = None;
    let mut timed_out = false;
    let mut failure = None;
    loop {
        tokio::select! {
            biased;
            _ = cancelled(&mut cancel) => break,
            _ = &mut timer => { timed_out = true; break; },
            r = &mut io, if drained.is_none() => match r {
                Ok(r) => drained = Some(r), Err(e) => { failure = Some(e); break; }
            },
            r = child.wait(), if status.is_none() => {
                match r { Ok(s) => status = Some(s), Err(e) => { failure = Some(e); break; } }
                #[cfg(unix)]
                if let Some(pgid) = pgid { reap_group(pgid as libc::pid_t).await; }
                #[cfg(windows)]
                if let Some(job) = &job { job.terminate(); }
                // Only grouped commands guarantee descendant EOF. Legacy
                // group=false retains its explicitly limited semantics.
                if command.group { let _ = leader_tx.send(true); }
            }
        }
        if drained.is_some() && status.is_some() {
            break;
        }
    }
    // Always close the group even on reader errors, blocked stdin or cancellation.
    #[cfg(unix)]
    if let Some(pgid) = pgid {
        unsafe {
            libc::killpg(pgid as libc::pid_t, libc::SIGKILL);
        }
    }
    #[cfg(windows)]
    if let Some(job) = &job {
        job.terminate();
    }
    if status.is_none() {
        let _ = child.start_kill();
        status = Some(
            tokio::time::timeout(Duration::from_secs(1), child.wait())
                .await
                .map_err(|_| scope_error(&command, "direct-child-reap-timeout"))?
                .map_err(|source| ExecError::Io {
                    argv: command.argv.clone(),
                    source,
                })?,
        );
    }
    let result = match failure {
        Some(source) => Err(ExecError::Io {
            argv: command.argv.clone(),
            source,
        }),
        None => {
            let (stdout, stderr, dropped) = if timed_out || drained.is_none() {
                (Vec::new(), Vec::new(), 0)
            } else {
                drained.unwrap()
            };
            Ok(Output {
                completion: if timed_out {
                    Completion::TimedOut {
                        after: started.elapsed(),
                    }
                } else {
                    completion_of(status.unwrap())
                },
                stdout,
                stderr,
                dropped,
                truncated: dropped > 0,
                argv: command.argv.clone(),
                run: RunId::new(),
            })
        }
    };
    // Completion delivery is also cancellable: cleanup never needs Lua to drain.
    if let Some(tx) = &events {
        tokio::select! {
            biased;
            _ = scope_cancelled(&mut cancel) => {},
            _ = tx.send(Event::Finished(id)) => {},
        }
    }
    result
}
