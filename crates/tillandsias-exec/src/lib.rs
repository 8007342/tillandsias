// @trace order:1252-fg9e, spec:ci-release
//
// tillandsias-exec — run a child process and get back a VALUE.
//
// OPERATOR DIRECTIVE 2026-09-18: "We're not trying to fix a problem, we're
// trying to fix the architecture so the problem doesn't exist." This crate is
// that architecture for process invocation. 1252-hsrz, 1252-znbn and 1252-r72q
// sit on the types here.
//
// ── THE FOUR CONSTRAINTS, AND WHAT EACH ONE DELETES ─────────────────────────
//
// ARGV, NEVER A SHELL STRING. `Command::new(["git", "status"])`, and there is
// deliberately NO entry point taking `&str` to be parsed. This deletes quoting,
// word-splitting, globbing and injection as a CLASS rather than case by case,
// and it is precisely what bash cannot offer. It is also what makes the
// `pgrep -f` self-match unconstructible: argv is assembled callee-side, so the
// pattern never passes through a command line the matcher can see itself in.
//
// SEPARATE FDS. stdout and stderr are two fields, never interleaved into one.
// Measured pre-fix: scripts/run-litmus-test.sh redirects every step with
// `2>&1`, so no litmus step can distinguish them today, and a guard that reads
// "only stdout" is actually reading both.
//
// CONCURRENT DRAINING, WHICH IS A CORRECTNESS REQUIREMENT AND NOT ELEGANCE.
// A child writing past the pipe buffer (~64 KiB) on stdout while nobody drains
// stderr DEADLOCKS: the child blocks writing, the parent blocks reading the
// other fd, and neither moves. Both pipes must be drained at the same time.
// `tokio::join!` below is that, and `dual_stream_megabyte_each_completes` is
// the test that would hang forever if it regressed.
//
// EXIT STATUS IS A VALUE. `Completion` is returned, never a `bool` and never a
// process exit that `set -e` can turn into control flow at a distance. There is
// no SIGPIPE inversion to have, because there is no OS pipe between stages:
// the caller owns the bytes and matches them in Rust.
//
// RUN IDENTITY, WHICH IS NOT A NICETY. On 2026-09-18 a land was monitored with
// `until [ -f land.rc ]`; a THIRTEEN-HOUR-OLD file of that name satisfied it
// instantly and the tool reported rc=0 for a land that had not started.
// Verifying against origin is what caught it. Every `Output` carries a `RunId`
// unique to the invocation that produced it, which makes "a stale artifact read
// as a fresh result" unrepresentable rather than merely discouraged — and it is
// the same distinction 1252-hsrz needs to tell a cached verdict from a fresh one.
//
// SCOPE. This crate does NOT migrate the 669 scripts. Adoption is
// migrate-on-touch by operator ruling; a sweep is how a second substrate appears
// that the gate does not run.

use std::ffi::OsStr;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

/// How a run ended. Exit status is a VALUE, and the three outcomes are distinct
/// cases rather than one integer a caller has to decode.
///
/// `TimedOut` exists because reporting an exit status the child never produced
/// is the specific lie this enum prevents: a killed child has no exit status,
/// and collapsing it to `Exited(143)` would be inventing one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Completion {
    /// The child exited on its own with this status.
    Exited(i32),
    /// The child was terminated by a signal it did not choose.
    Signaled(i32),
    /// The deadline passed and we killed it. There is no exit status to report.
    TimedOut { after: Duration },
}

impl Completion {
    /// True only for a clean zero exit. Deliberately a METHOD and not a `From`
    /// impl: a caller has to ask for the collapse, so it cannot happen by
    /// coercion in an `if`.
    pub fn is_success(&self) -> bool {
        matches!(self, Completion::Exited(0))
    }
}

/// Identity of ONE invocation. Two runs of the same command never share it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RunId(String);

impl RunId {
    fn new() -> Self {
        RunId(uuid::Uuid::new_v4().to_string())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for RunId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// What a run produced. Three separate values plus the identity of the run.
#[derive(Debug, Clone)]
pub struct Output {
    pub completion: Completion,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// The invocation that produced this. Compare it before trusting a result
    /// you did not just await.
    pub run: RunId,
    /// argv as executed, for a refusal that can name what it ran.
    pub argv: Vec<OsString>,
}

impl Output {
    pub fn stdout_lossy(&self) -> std::borrow::Cow<'_, str> {
        String::from_utf8_lossy(&self.stdout)
    }
    pub fn stderr_lossy(&self) -> std::borrow::Cow<'_, str> {
        String::from_utf8_lossy(&self.stderr)
    }
    /// Does stdout contain this needle? The replacement for `| grep -q`, and
    /// the reason the SIGPIPE inversion cannot occur: there is no pipe and no
    /// early-exiting consumer, just bytes already in hand.
    pub fn stdout_contains(&self, needle: &str) -> bool {
        self.stdout
            .windows(needle.len())
            .any(|w| w == needle.as_bytes())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ExecError {
    #[error("spawn failed for {argv:?}: {source}")]
    Spawn {
        argv: Vec<OsString>,
        #[source]
        source: std::io::Error,
    },
    #[error("io while draining {argv:?}: {source}")]
    Io {
        argv: Vec<OsString>,
        #[source]
        source: std::io::Error,
    },
    #[error("refused: empty argv — a command needs a program to run")]
    EmptyArgv,
}

/// A command described as argv. There is NO constructor taking a shell string.
#[derive(Debug, Clone)]
pub struct Command {
    argv: Vec<OsString>,
    cwd: Option<PathBuf>,
    envs: Vec<(OsString, OsString)>,
    env_clear: bool,
    timeout: Option<Duration>,
    stdin: Option<Vec<u8>>,
    group: bool,
}

impl Command {
    /// Build from an argv sequence. `Command::new(["git", "status"])`.
    pub fn new<I, S>(argv: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        Command {
            argv: argv
                .into_iter()
                .map(|s| s.as_ref().to_os_string())
                .collect(),
            cwd: None,
            envs: Vec::new(),
            env_clear: false,
            timeout: None,
            stdin: None,
            group: false,
        }
    }

    pub fn arg<S: AsRef<OsStr>>(mut self, a: S) -> Self {
        self.argv.push(a.as_ref().to_os_string());
        self
    }

    pub fn current_dir<P: Into<PathBuf>>(mut self, p: P) -> Self {
        self.cwd = Some(p.into());
        self
    }

    pub fn env<K: AsRef<OsStr>, V: AsRef<OsStr>>(mut self, k: K, v: V) -> Self {
        self.envs
            .push((k.as_ref().to_os_string(), v.as_ref().to_os_string()));
        self
    }

    /// Start from an empty environment. The seam that makes a run reproducible
    /// instead of inheriting whatever the caller happened to export.
    pub fn env_clear(mut self) -> Self {
        self.env_clear = true;
        self
    }

    /// Feed these bytes to the child on stdin. The replacement for `echo X | cmd`
    /// and `cmd <<<"$x"`.
    ///
    /// THIS IS THE THIRD FD AND IT IS THE SAME DEADLOCK. A child that writes
    /// past the pipe buffer on stdout while the parent is still blocked WRITING
    /// stdin hangs exactly as the two-read case does. So the writer is joined
    /// WITH the two readers below, never sequenced before them.
    pub fn stdin_bytes<B: Into<Vec<u8>>>(mut self, b: B) -> Self {
        self.stdin = Some(b.into());
        self
    }

    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = Some(d);
        self
    }

    /// Run the child as the leader of its own process group (Unix: setsid-style
    /// `process_group(0)`, killed with `killpg`) or inside its own job object
    /// (Windows: `TerminateJobObject`), so a DEADLINE kills everything the child
    /// started, not only the child (order 1384-aixy; the 1132-r4mt and
    /// 1305-udgs defect was a killed guard leaving its grandchildren running).
    ///
    /// Only the timeout path kills the group. A run that completes normally
    /// leaves nothing to kill on Unix; on Windows the job is created with
    /// KILL_ON_JOB_CLOSE, so anything still inside it when the run's handle is
    /// dropped goes too.
    pub fn group(mut self, on: bool) -> Self {
        self.group = on;
        self
    }

    pub fn argv(&self) -> &[OsString] {
        &self.argv
    }

    /// Run to completion. Both fds are drained CONCURRENTLY; see the header.
    pub async fn run(self) -> Result<Output, ExecError> {
        let Some((program, rest)) = self.argv.split_first() else {
            return Err(ExecError::EmptyArgv);
        };
        let run = RunId::new();

        let mut cmd = tokio::process::Command::new(program);
        cmd.args(rest)
            .stdin(if self.stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(d) = &self.cwd {
            cmd.current_dir(d);
        }
        if self.env_clear {
            cmd.env_clear();
        }
        for (k, v) in &self.envs {
            cmd.env(k, v);
        }
        #[cfg(unix)]
        if self.group {
            // pgid = the child's pid, so killpg(pid) reaches every descendant
            // that did not leave the group itself.
            cmd.process_group(0);
        }

        let mut child = cmd.spawn().map_err(|source| ExecError::Spawn {
            argv: self.argv.clone(),
            source,
        })?;
        // Windows: put the child in a fresh job object BEFORE awaiting anything.
        // A descendant it starts from here on is in the job too. (A process
        // started in the few instructions between spawn and assignment would
        // escape; tokio exposes no suspended-spawn to close that window.)
        #[cfg(windows)]
        let job = if self.group {
            Some(
                win_job::JobObject::assign(&child).map_err(|source| ExecError::Io {
                    argv: self.argv.clone(),
                    source,
                })?,
            )
        } else {
            None
        };
        #[cfg(unix)]
        let group_leader = if self.group { child.id() } else { None };

        // Take both pipes BEFORE awaiting anything, then drain them together.
        // Reading one to EOF and then the other is the deadlock this crate
        // exists to make unconstructible.
        let mut out_pipe = child.stdout.take().expect("stdout piped above");
        let mut err_pipe = child.stderr.take().expect("stderr piped above");
        let in_pipe = child.stdin.take();
        let to_write = self.stdin.clone();

        let drain = async {
            use tokio::io::AsyncReadExt;
            use tokio::io::AsyncWriteExt;
            let mut o = Vec::new();
            let mut e = Vec::new();
            // THREE fds, all moving at once. The write is a peer of the reads,
            // not a prelude to them: sequencing it first deadlocks on any child
            // that answers before it has finished reading.
            let feed = async {
                if let (Some(mut w), Some(bytes)) = (in_pipe, to_write) {
                    w.write_all(&bytes).await?;
                    w.shutdown().await?; // EOF, or a reader waits forever
                }
                Ok::<(), std::io::Error>(())
            };
            let (ro, re, rw) = tokio::join!(
                out_pipe.read_to_end(&mut o),
                err_pipe.read_to_end(&mut e),
                feed
            );
            ro?;
            re?;
            // A child that exits before consuming stdin gives us EPIPE here.
            // That is NOT an error of ours -- `head -1` legitimately does it --
            // so it is swallowed rather than turned into a spawn failure.
            match rw {
                Ok(()) => {}
                Err(err) if err.kind() == std::io::ErrorKind::BrokenPipe => {}
                Err(err) => return Err(err),
            }
            Ok::<(Vec<u8>, Vec<u8>), std::io::Error>((o, e))
        };

        let io_err = |source| ExecError::Io {
            argv: self.argv.clone(),
            source,
        };

        match self.timeout {
            None => {
                // Drain and wait CONCURRENTLY. Waiting first would deadlock for
                // the same reason draining serially does.
                let (drained, status) = tokio::join!(drain, child.wait());
                let (stdout, stderr) = drained.map_err(io_err)?;
                let status = status.map_err(io_err)?;
                Ok(Output {
                    completion: completion_of(status),
                    stdout,
                    stderr,
                    run,
                    argv: self.argv,
                })
            }
            Some(d) => {
                let started = std::time::Instant::now();
                let both = async {
                    let (drained, status) = tokio::join!(drain, child.wait());
                    Ok::<_, std::io::Error>((drained?, status?))
                };
                match tokio::time::timeout(d, both).await {
                    Ok(joined) => {
                        let ((stdout, stderr), status) = joined.map_err(io_err)?;
                        Ok(Output {
                            completion: completion_of(status),
                            stdout,
                            stderr,
                            run,
                            argv: self.argv,
                        })
                    }
                    Err(_elapsed) => {
                        // The deadline passed. KILL, and report TimedOut rather
                        // than an exit status the child never produced. A child
                        // that ignores SIGTERM is exactly why this is kill and
                        // not a polite terminate-and-hope.
                        #[cfg(unix)]
                        if let Some(pgid) = group_leader {
                            // SAFETY: killpg is async-signal-safe and takes no
                            // pointers; a stale pgid fails with ESRCH, harmless.
                            unsafe {
                                libc::killpg(pgid as libc::pid_t, libc::SIGKILL);
                            }
                        }
                        #[cfg(windows)]
                        if let Some(j) = &job {
                            j.terminate();
                        }
                        let _ = child.start_kill();
                        let _ = child.wait().await;
                        Ok(Output {
                            completion: Completion::TimedOut {
                                after: started.elapsed().max(d),
                            },
                            // Partial output is deliberately dropped rather than
                            // returned as if complete: a truncated capture that
                            // looks whole is the `tail -1` defect in another form.
                            stdout: Vec::new(),
                            stderr: Vec::new(),
                            run,
                            argv: self.argv,
                        })
                    }
                }
            }
        }
    }
}

fn completion_of(status: std::process::ExitStatus) -> Completion {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(sig) = status.signal() {
            return Completion::Signaled(sig);
        }
    }
    Completion::Exited(status.code().unwrap_or(-1))
}

/// A sequence of commands where each stage's captured stdout becomes the next
/// stage's stdin — the replacement for `a | b`.
///
/// THERE IS NO OS PIPE. Stage N runs to completion, its stdout is held in
/// memory, and stage N+1 is started with those bytes on stdin. So there is no
/// early-exiting consumer, nothing to SIGPIPE, and `pipefail` has no analogue
/// to invert: the SIGPIPE class is deleted rather than avoided.
///
/// THE TRADE, STATED RATHER THAN HIDDEN: this buffers each intermediate in
/// full, so peak memory is the largest intermediate rather than a 64 KiB pipe
/// buffer, and stages do not overlap in time. For the guard-shaped work this
/// crate exists for — run a command, inspect its output — that is the right
/// trade. For streaming gigabytes between long-running processes it is not, and
/// such a caller should spawn() the stages and move bytes itself.
///
/// EVERY STAGE'S Output IS KEPT, which is the second thing a shell pipeline
/// cannot do: `a | b` discards a's exit status and stderr entirely unless
/// pipefail is set, and even then it gives you one bit. Here each stage's
/// status, stdout and stderr survive for inspection.
#[derive(Debug, Clone)]
pub struct Pipeline {
    stages: Vec<Command>,
}

/// What a pipeline produced: every stage's Output, in order.
#[derive(Debug, Clone)]
pub struct PipelineOutput {
    pub stages: Vec<Output>,
}

impl PipelineOutput {
    /// The last stage's Output, which is what `a | b` would have given you.
    pub fn last(&self) -> &Output {
        self.stages
            .last()
            .expect("a pipeline has at least one stage")
    }
    /// Every stage exited zero. The honest form of `pipefail`, and it cannot
    /// invert because no stage was killed by a downstream reader.
    pub fn all_succeeded(&self) -> bool {
        self.stages.iter().all(|s| s.completion.is_success())
    }
    /// The first stage that did not exit zero, for a refusal that can name it.
    pub fn first_failure(&self) -> Option<&Output> {
        self.stages.iter().find(|s| !s.completion.is_success())
    }
}

impl Pipeline {
    pub fn new(first: Command) -> Self {
        Pipeline {
            stages: vec![first],
        }
    }

    /// Append a stage fed by the previous stage's stdout.
    pub fn pipe_to(mut self, next: Command) -> Self {
        self.stages.push(next);
        self
    }

    /// Run every stage in order. Stops at the first stage that fails to SPAWN;
    /// a stage that RUNS and exits non-zero does not stop the pipeline, because
    /// deciding what a non-zero stage means is the caller's business and
    /// swallowing it here would rebuild the thing we are replacing.
    pub async fn run(self) -> Result<PipelineOutput, ExecError> {
        let mut outs: Vec<Output> = Vec::with_capacity(self.stages.len());
        let mut carry: Option<Vec<u8>> = None;
        for stage in self.stages {
            let stage = match carry.take() {
                Some(bytes) => stage.stdin_bytes(bytes),
                None => stage,
            };
            let out = stage.run().await?;
            carry = Some(out.stdout.clone());
            outs.push(out);
        }
        Ok(PipelineOutput { stages: outs })
    }
}

/// A child that is still running. The reaping half of the layer.
///
/// `kill_on_drop` is set on every spawn, so a `Running` that goes out of scope
/// cannot leak a process — the failure mode where a killed harness leaves an
/// orphaned gate behind (measured twice on this host tonight) is not
/// constructible through this type.
#[derive(Debug)]
pub struct Running {
    child: tokio::process::Child,
    run: RunId,
    argv: Vec<OsString>,
}

impl Running {
    pub fn run_id(&self) -> &RunId {
        &self.run
    }
    pub fn argv(&self) -> &[OsString] {
        &self.argv
    }

    /// Has it finished? Does NOT block. `None` means still running — and note
    /// that is a third state, not a falsy "no": a caller that collapses this to
    /// a bool loses the distinction between "finished unsuccessfully" and
    /// "hasn't finished".
    pub fn try_completion(&mut self) -> Result<Option<Completion>, ExecError> {
        match self.child.try_wait() {
            Ok(Some(status)) => Ok(Some(completion_of(status))),
            Ok(None) => Ok(None),
            Err(source) => Err(ExecError::Io {
                argv: self.argv.clone(),
                source,
            }),
        }
    }

    /// Wait for it, reaping the child.
    pub async fn wait(mut self) -> Result<Completion, ExecError> {
        let status = self.child.wait().await.map_err(|source| ExecError::Io {
            argv: self.argv.clone(),
            source,
        })?;
        Ok(completion_of(status))
    }

    /// Kill it and reap. SIGKILL, not SIGTERM: a child that ignores SIGTERM is
    /// exactly the case a caller reaches for this in, and a polite terminate
    /// that hangs is worse than no method at all.
    pub async fn kill(mut self) -> Result<Completion, ExecError> {
        let _ = self.child.start_kill();
        self.wait().await
    }
}

impl Command {
    /// Start the child and return a handle WITHOUT waiting. stdout and stderr
    /// are inherited, because a background child whose pipes nobody drains is
    /// the deadlock this crate exists to prevent — a caller who wants captured
    /// output should use `run()`, which drains concurrently.
    pub async fn spawn(self) -> Result<Running, ExecError> {
        let Some((program, rest)) = self.argv.split_first() else {
            return Err(ExecError::EmptyArgv);
        };
        let mut cmd = tokio::process::Command::new(program);
        cmd.args(rest)
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);
        if let Some(d) = &self.cwd {
            cmd.current_dir(d);
        }
        if self.env_clear {
            cmd.env_clear();
        }
        for (k, v) in &self.envs {
            cmd.env(k, v);
        }
        let child = cmd.spawn().map_err(|source| ExecError::Spawn {
            argv: self.argv.clone(),
            source,
        })?;
        Ok(Running {
            child,
            run: RunId::new(),
            argv: self.argv,
        })
    }
}

/// A Windows job object that owns one child and everything it starts
/// (order 1384-aixy). `terminate` kills the whole job on a deadline; dropping
/// the handle kills whatever is still inside (KILL_ON_JOB_CLOSE), the Windows
/// analogue of a process group that dies with its leader's supervisor.
#[cfg(windows)]
mod win_job {
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };
    use windows::core::PCWSTR;

    pub struct JobObject(HANDLE);

    // The handle is an owned kernel object used only through the calls below.
    unsafe impl Send for JobObject {}
    unsafe impl Sync for JobObject {}

    impl JobObject {
        pub fn assign(child: &tokio::process::Child) -> std::io::Result<Self> {
            let raw = child
                .raw_handle()
                .ok_or_else(|| std::io::Error::other("child has no process handle"))?;
            // SAFETY: plain Win32 calls on handles we own; every failure is
            // turned into an io::Error and the job handle is closed on drop.
            unsafe {
                let job = JobObject(
                    CreateJobObjectW(None, PCWSTR::null()).map_err(std::io::Error::other)?,
                );
                let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                )
                .map_err(std::io::Error::other)?;
                AssignProcessToJobObject(job.0, HANDLE(raw)).map_err(std::io::Error::other)?;
                Ok(job)
            }
        }

        pub fn terminate(&self) {
            // SAFETY: the handle is valid for the lifetime of self.
            unsafe {
                let _ = TerminateJobObject(self.0, 1);
            }
        }
    }

    impl Drop for JobObject {
        fn drop(&mut self) {
            // SAFETY: closing our own handle once; KILL_ON_JOB_CLOSE ends
            // any process still in the job.
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}
