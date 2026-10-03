// @trace order:1534-puyz, order:1538-pwdr, spec:command-runtime
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
pub const SPAWN_SETUP_BOUND: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, PartialEq)]
enum Stop {
    Running,
    Kill,
    Close,
}

#[derive(Clone, Copy, PartialEq)]
enum ObservationMode {
    Silent,
    Completion,
    Lines,
}

struct Observation {
    events: mpsc::Sender<Event>,
    lines: bool,
}

struct State {
    finished: AtomicBool,
    reaped: AtomicBool,
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
        self.cancel.send_if_modified(|stop| {
            if *stop == Stop::Running {
                *stop = Stop::Kill;
                true
            } else {
                false
            }
        });
    }
    pub fn result(&self) -> Option<Result<Output, String>> {
        self.state
            .result
            .lock()
            .unwrap()
            .as_ref()
            .map(|r| r.as_ref().cloned().map_err(ToString::to_string))
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
    /// Linearizes shutdown against launch acceptance AND registration. The supervisor owns
    /// a successfully spawned child before the caller can obtain its handle.
    /// `stream=true` emits bounded lines followed by Finished; `false` emits
    /// no events (the legacy blocking run path). Capture bounds are independent.
    pub fn spawn(&self, command: Command, stream: bool) -> Result<Process, ExecError> {
        self.spawn_observed(
            command,
            if stream {
                ObservationMode::Lines
            } else {
                ObservationMode::Silent
            },
        )
    }
    /// Capture bytes without line buffering or line events, but emit the same
    /// Finished receipt after fd draining and direct-child reaping. Script-owned
    /// chain stages use this mode; public streaming still enforces MAX_LINE_BYTES.
    /// Ownership, deadlines, capture defaults and result publication are unchanged.
    pub fn spawn_completion(&self, command: Command) -> Result<Process, ExecError> {
        self.spawn_observed(command, ObservationMode::Completion)
    }
    fn spawn_observed(
        &self,
        command: Command,
        mode: ObservationMode,
    ) -> Result<Process, ExecError> {
        let mut processes = self.0.processes.lock().unwrap();
        if self.stopped() {
            return Err(scope_error(&command, "script-scope-closed"));
        }
        processes.retain(|p| {
            !p.state.finished.load(Ordering::Acquire) || !p.state.reaped.load(Ordering::Acquire)
        });
        if processes.len() >= MAX_ACTIVE_PROCESSES {
            return Err(scope_error(&command, "script-process-limit"));
        }
        let id = self.0.next.fetch_add(1, Ordering::Relaxed);
        let (cancel, rx) = watch::channel(Stop::Running);
        let state = Arc::new(State {
            finished: AtomicBool::new(false),
            reaped: AtomicBool::new(false),
            result: Mutex::new(None),
            done: Condvar::new(),
        });
        let process = Process {
            id,
            state: state.clone(),
            cancel,
        };
        let observation = (mode != ObservationMode::Silent).then(|| Observation {
            events: self.0.events.clone(),
            lines: mode == ObservationMode::Lines,
        });
        let deadline = self.0.deadline;
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let argv = command.argv.clone();
        let thread_argv = argv.clone();
        // Register BEFORE setup. A late setup result remains owned even when
        // the caller's bounded handshake expires or the scope closes meanwhile.
        processes.push(process.clone());
        drop(processes); // No OS thread/process setup holds the close gate.
        let worker_state = state.clone();
        let spawned = std::thread::Builder::new()
            .name(format!("proc-{id}"))
            .spawn(move || {
                let result = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => {
                        let result = rt.block_on(supervise(
                            command,
                            id,
                            rx,
                            deadline,
                            observation,
                            ready_tx,
                            &worker_state.reaped,
                        ));
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
                        worker_state.reaped.store(true, Ordering::Release);
                        Err(ExecError::Io {
                            argv: argv.clone(),
                            source: std::io::Error::other("supervisor-runtime-failed"),
                        })
                    }
                };
                let mut slot = worker_state.result.lock().unwrap();
                *slot = Some(result);
                worker_state.finished.store(true, Ordering::Release);
                drop(slot);
                worker_state.done.notify_all();
            });
        if let Err(source) = spawned {
            let mut slot = state.result.lock().unwrap();
            *slot = Some(Err(ExecError::Io {
                argv: thread_argv.clone(),
                source: std::io::Error::other("supervisor-thread-failed"),
            }));
            state.reaped.store(true, Ordering::Release); // No worker or child exists.
            state.finished.store(true, Ordering::Release);
            drop(slot);
            state.done.notify_all();
            self.0.processes.lock().unwrap().retain(|p| p.id != id);
            return Err(ExecError::Io {
                argv: thread_argv,
                source,
            });
        }
        let setup_bound = deadline
            .map(|d| SPAWN_SETUP_BOUND.min(d.saturating_duration_since(Instant::now())))
            .unwrap_or(SPAWN_SETUP_BOUND);
        ready_rx.recv_timeout(setup_bound).map_err(|e| {
            let _ = process.cancel.send(Stop::Close);
            ExecError::Io {
                argv: thread_argv,
                source: std::io::Error::other(format!("proc-spawn-setup-failed:{e}")),
            }
        })??;
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
            if !p.state.reaped.load(Ordering::Acquire) {
                return Err("script-cleanup-incomplete:direct-child-reap".into());
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
    if let Some(tx) = &events
        && !pending.is_empty()
    {
        tx.send(Event::Line {
            process: id,
            fd,
            bytes: pending,
        })
        .await
        .map_err(|_| std::io::Error::other("script-stream-closed"))?;
    }
    Ok((kept, dropped))
}

async fn supervise(
    command: Command,
    id: u64,
    mut cancel: watch::Receiver<Stop>,
    deadline: Option<Instant>,
    observation: Option<Observation>,
    ready: std::sync::mpsc::Sender<Result<(), ExecError>>,
    reaped: &AtomicBool,
) -> Result<Output, ExecError> {
    if *cancel.borrow() != Stop::Running || deadline.is_some_and(|d| Instant::now() >= d) {
        reaped.store(true, Ordering::Release); // No child was spawned.
        let _ = ready.send(Err(scope_error(&command, "script-scope-closed")));
        return Err(scope_error(&command, "script-scope-closed"));
    }
    let Some((program, rest)) = command.argv.split_first() else {
        reaped.store(true, Ordering::Release);
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
            reaped.store(true, Ordering::Release);
            let _ = ready.send(Err(ExecError::Spawn {
                argv: command.argv.clone(),
                source,
            }));
            return Err(scope_error(&command, "spawn-failed"));
        }
    };
    #[cfg(unix)]
    let pgid = if command.group { child.id() } else { None };
    #[cfg(windows)]
    let job = if command.group {
        match win_job::JobObject::assign(&child) {
            Ok(job) => Some(job),
            Err(source) => {
                let _ = child.start_kill();
                match tokio::time::timeout(Duration::from_secs(1), child.wait()).await {
                    Ok(Ok(_)) => reaped.store(true, Ordering::Release),
                    _ => {
                        let _ = ready.send(Err(scope_error(
                            &command,
                            "direct-child-reap-failed:job-setup",
                        )));
                        return Err(scope_error(&command, "direct-child-reap-failed:job-setup"));
                    }
                }
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
    // Completion-only observers never enter read_stream's line assembly path;
    // both fds still drain and retain the ordinary bounded byte-prefix capture.
    let line_events = observation
        .as_ref()
        .filter(|observer| observer.lines)
        .map(|observer| observer.events.clone());
    let io = async {
        use tokio::io::AsyncWriteExt;
        let feed = async {
            if let (Some(mut input), Some(bytes)) = (input, &command.stdin)
                && let Err(e) = input.write_all(bytes).await
                && e.kind() != std::io::ErrorKind::BrokenPipe
            {
                return Err(e);
            }
            Ok::<(), std::io::Error>(())
        };
        let (a, b, _) = tokio::try_join!(
            read_stream(
                out,
                command.capture_bytes,
                id,
                "stdout",
                line_events.clone(),
                leader_rx.clone()
            ),
            read_stream(
                err,
                command.capture_bytes,
                id,
                "stderr",
                line_events.clone(),
                leader_rx
            ),
            feed
        )?;
        Ok::<_, std::io::Error>((a.0, b.0, a.1 + b.1))
    };
    let mut io = Box::pin(io);
    tokio::pin!(timer);
    let mut drained = None;
    let mut status = None;
    let mut timed_out = false;
    let mut failure = None;
    let mut group_cleaned = false;
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
                group_cleaned = true;
                // Only grouped commands guarantee descendant EOF. Legacy
                // group=false retains its explicitly limited semantics.
                if command.group { let _ = leader_tx.send(true); }
            }
        }
        if drained.is_some() && status.is_some() {
            break;
        }
    }
    // Cancelled readers may own queued mpsc permits. Drop them BEFORE enqueueing
    // Finished, otherwise completion could wait behind an unpolled sender.
    drop(io);
    // Always close the group even on reader errors, blocked stdin or cancellation.
    #[cfg(unix)]
    if let Some(pgid) = pgid.filter(|_| !group_cleaned) {
        unsafe {
            libc::killpg(pgid as libc::pid_t, libc::SIGKILL);
        }
    }
    #[cfg(windows)]
    if let Some(job) = &job
        && !group_cleaned
    {
        job.terminate();
    }
    if status.is_none() {
        let _ = child.start_kill();
        status = Some(
            tokio::time::timeout(Duration::from_secs(1), child.wait())
                .await
                .map_err(|_| scope_error(&command, "direct-child-reap-timeout"))?
                .map_err(|e| scope_error(&command, &format!("direct-child-reap-failed:{e}")))?,
        );
    }
    // This receipt is about Child::wait of our direct child ONLY.
    reaped.store(true, Ordering::Release);
    let result = match failure {
        Some(source) => Err(ExecError::Io {
            argv: command.argv.clone(),
            source,
        }),
        None => {
            let (stdout, stderr, dropped) = match (timed_out, drained) {
                (false, Some(capture)) => capture,
                _ => (Vec::new(), Vec::new(), 0),
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
    if let Some(observer) = &observation {
        tokio::select! {
            biased;
            _ = scope_cancelled(&mut cancel) => {},
            _ = observer.events.send(Event::Finished(id)) => {},
        }
    }
    result
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn cat(bytes: Vec<u8>) -> Command {
        Command::new(["/bin/cat"])
            .stdin_bytes(bytes)
            .group(true)
            .timeout(Duration::from_secs(2))
    }

    async fn published(process: &Process) -> Result<Output, String> {
        tokio::time::timeout(Duration::from_secs(4), async {
            loop {
                if let Some(result) = process.result() {
                    return result;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("managed result was not published")
    }

    fn only_finished(events: &mut mpsc::Receiver<Event>, id: u64) {
        assert!(matches!(events.try_recv(), Ok(Event::Finished(actual)) if actual == id));
        assert!(matches!(
            events.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn completion_only_accepts_newline_free_payload_beyond_stream_line_bound() {
        let (scope, mut events) = Scope::new(Some(Instant::now() + Duration::from_secs(5)));
        let bytes = vec![b'x'; MAX_LINE_BYTES + 1];
        let process = scope.spawn_completion(cat(bytes.clone())).unwrap();
        let output = published(&process).await.unwrap();
        assert_eq!(output.completion, Completion::Exited(0));
        assert_eq!(output.stdout, bytes);
        assert!(output.stderr.is_empty());
        assert!(!output.truncated);
        assert_eq!(output.dropped, 0);
        only_finished(&mut events, process.id);
        scope.cleanup().unwrap();
    }

    #[tokio::test]
    async fn completion_only_capture_is_bounded_without_line_queue_backpressure() {
        let (scope, mut events) = Scope::new(Some(Instant::now() + Duration::from_secs(5)));
        let bytes = b"line\0\xff\n".repeat(MAX_LINE_BYTES / 7 + 1);
        let cap = 257;
        let process = scope
            .spawn_completion(cat(bytes.clone()).capture_bytes(cap))
            .unwrap();
        // Deliberately do not poll events until publication. Full line streaming
        // would fill the 32-slot queue and fail to drain this producer in time.
        let output = published(&process).await.unwrap();
        assert_eq!(output.completion, Completion::Exited(0));
        assert_eq!(output.stdout, bytes[..cap]);
        assert!(output.stderr.is_empty());
        assert!(output.truncated);
        assert_eq!(output.dropped, (bytes.len() - cap) as u64);
        only_finished(&mut events, process.id);
        scope.cleanup().unwrap();
    }

    #[tokio::test]
    async fn full_streaming_keeps_unterminated_line_limit() {
        let (scope, mut events) = Scope::new(Some(Instant::now() + Duration::from_secs(5)));
        let process = scope
            .spawn(cat(vec![b'x'; MAX_LINE_BYTES + 1]), true)
            .unwrap();
        let failure = published(&process).await.unwrap_err();
        assert!(failure.contains("proc-line-too-long"), "{failure}");
        only_finished(&mut events, process.id);
        scope.cleanup().unwrap();
    }

    #[tokio::test]
    async fn silent_spawn_keeps_no_event_legacy_semantics() {
        let (scope, mut events) = Scope::new(Some(Instant::now() + Duration::from_secs(5)));
        let bytes = vec![b'x'; MAX_LINE_BYTES + 1];
        let process = scope.spawn(cat(bytes.clone()), false).unwrap();
        let output = published(&process).await.unwrap();
        assert_eq!(output.completion, Completion::Exited(0));
        assert_eq!(output.stdout, bytes);
        assert!(matches!(
            events.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
        scope.cleanup().unwrap();
    }
}
