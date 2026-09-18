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

    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = Some(d);
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
            .stdin(Stdio::null())
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

        let mut child = cmd.spawn().map_err(|source| ExecError::Spawn {
            argv: self.argv.clone(),
            source,
        })?;

        // Take both pipes BEFORE awaiting anything, then drain them together.
        // Reading one to EOF and then the other is the deadlock this crate
        // exists to make unconstructible.
        let mut out_pipe = child.stdout.take().expect("stdout piped above");
        let mut err_pipe = child.stderr.take().expect("stderr piped above");

        let drain = async {
            use tokio::io::AsyncReadExt;
            let mut o = Vec::new();
            let mut e = Vec::new();
            let (ro, re) = tokio::join!(out_pipe.read_to_end(&mut o), err_pipe.read_to_end(&mut e));
            ro?;
            re?;
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
