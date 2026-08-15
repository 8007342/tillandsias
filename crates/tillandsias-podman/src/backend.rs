//! Authoritative Podman transport seam and command accounting.
//!
//! The rest of the repository may describe *what* Podman should do, but this
//! module owns the act of invoking it and the raw facts produced by that act.

use std::collections::VecDeque;
use std::fmt;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use parking_lot::Mutex;

/// High-level purpose of one Podman invocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationKind {
    Availability,
    Image,
    Container,
    Network,
    Secret,
    Health,
    Inspect,
    Logs,
    Events,
    Diagnostics,
    Scenario,
}

impl OperationKind {
    /// The declared wall-clock budget for one invocation of this class
    /// (order 690-7adz).
    ///
    /// Before this existed, every podman call in the product awaited
    /// `cmd.output()` with no deadline, so a storage lock, a stuck netavark, or
    /// a container that never becomes healthy hung the caller forever with no
    /// output — the failure mode is indistinguishable from slow work, which is
    /// why it kept being diagnosed as one.
    ///
    /// These are DEADLINES, not expectations: each is set well above what the
    /// operation takes when the substrate is healthy, because the only thing a
    /// budget must separate is "working" from "wedged". A caller that genuinely
    /// needs longer says so with `execute_with_budget`; inheriting infinity is
    /// no longer an option any caller has.
    pub fn default_budget(self) -> Duration {
        match self {
            // Local metadata reads. If these are not instant the substrate is
            // already unhealthy and waiting longer tells us nothing new.
            OperationKind::Availability | OperationKind::Inspect => Duration::from_secs(30),
            OperationKind::Secret | OperationKind::Health => Duration::from_secs(60),
            OperationKind::Network | OperationKind::Events => Duration::from_secs(120),
            // Container create/start/stop/rm. Generous because a cold start can
            // pull layers, bounded because `podman wait --condition=healthy` on
            // a container that never gets there is the exact hang this fixes.
            OperationKind::Container => Duration::from_secs(300),
            OperationKind::Logs | OperationKind::Diagnostics => Duration::from_secs(120),
            // Builds and pulls move gigabytes over a network. The budget is a
            // deadlock detector, not a performance target.
            OperationKind::Image => Duration::from_secs(3600),
            // Scenario replays drive whole multi-step flows.
            OperationKind::Scenario => Duration::from_secs(900),
        }
    }
}

/// Retry posture inferred from the raw failure facts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetryClass {
    Retryable,
    Permanent,
    Unknown,
}

/// Lossless result of a Podman command.
#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub operation: OperationKind,
    pub argv: Vec<String>,
    pub redacted_argv: Vec<String>,
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub duration: Duration,
}

impl CommandOutput {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }
}

/// Structured failed Podman command.
#[derive(Debug, Clone)]
pub struct CommandFailure {
    pub output: Box<CommandOutput>,
    pub retry: RetryClass,
}

impl fmt::Display for CommandFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let stderr = self.output.stderr.trim();
        let stdout = self.output.stdout.trim();
        write!(
            f,
            "{:?} command failed (status {:?}, retry {:?}): podman {}",
            self.output.operation,
            self.output.status,
            self.retry,
            self.output.redacted_argv.join(" ")
        )?;
        if !stderr.is_empty() {
            write!(f, "\nstderr: {stderr}")?;
        } else if !stdout.is_empty() {
            write!(f, "\nstdout: {stdout}")?;
        } else {
            write!(f, "\nno stdout/stderr captured")?;
        }
        Ok(())
    }
}

impl std::error::Error for CommandFailure {}

/// Backend seam shared by production, fake, and replay transports.
///
/// `budget` is a hard wall-clock deadline for the invocation (order 690-7adz).
/// It is a required parameter rather than an option with a default precisely so
/// that adding a new transport, or a new caller, cannot silently reintroduce an
/// unbounded wait: there is no way to spell "no deadline" here.
#[async_trait]
pub trait PodmanBackend: Send + Sync {
    async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
        budget: Duration,
    ) -> Result<CommandOutput, CommandFailure>;
}

/// Real backend backed by the actual `podman` binary.
#[derive(Debug, Default)]
pub struct RealBackend;

#[async_trait]
impl PodmanBackend for RealBackend {
    async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
        budget: Duration,
    ) -> Result<CommandOutput, CommandFailure> {
        let started = Instant::now();
        let mut cmd = crate::podman_cmd();
        cmd.args(argv);
        // Backend calls are frequently wrapped in bounded timeouts. Ensure
        // cancelling such a future cannot strand the Podman CLI process.
        cmd.kill_on_drop(true);
        // User-visible debug log (only when --debug / TILLANDSIAS_DEBUG=1). See
        // crate::log_podman_invocation for the format and redaction rules.
        let label = format!("{:?}", operation).to_ascii_lowercase();
        crate::log_podman_invocation(&label, cmd.as_std());
        // Order 690-7adz: bound the wait. `kill_on_drop(true)` above means the
        // timeout does not merely abandon the future — dropping the child kills
        // the podman process, so a wedged invocation cannot outlive its budget
        // and keep holding a storage lock.
        let result = match tokio::time::timeout(budget, cmd.output()).await {
            Ok(result) => result,
            Err(_) => {
                let output = CommandOutput {
                    operation,
                    argv: argv.to_vec(),
                    redacted_argv: redact_argv(argv),
                    status: None,
                    stdout: String::new(),
                    // NAME the operation, the budget, and the command. A bare
                    // "timed out" reproduces the original defect at a smaller
                    // scale: the operator still cannot tell WHAT stopped.
                    stderr: timeout_message(operation, &redact_argv(argv), budget),
                    duration: started.elapsed(),
                };
                crate::log_podman_failure(&label, "timeout", &output.stderr);
                return Err(CommandFailure {
                    // A deadline says nothing about whether the substrate will
                    // recover, and guessing "retryable" turns one hang into a
                    // loop of them.
                    retry: RetryClass::Unknown,
                    output: Box::new(output),
                });
            }
        };
        let output = match result {
            Ok(output) => CommandOutput {
                operation,
                argv: argv.to_vec(),
                redacted_argv: redact_argv(argv),
                status: output.status.code(),
                stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                duration: started.elapsed(),
            },
            Err(err) => CommandOutput {
                operation,
                argv: argv.to_vec(),
                redacted_argv: redact_argv(argv),
                status: None,
                stdout: String::new(),
                stderr: err.to_string(),
                duration: started.elapsed(),
            },
        };

        if output.success() {
            Ok(output)
        } else {
            // Emit the structured failure line so `grep '[tillandsias] podman'`
            // surfaces both invocation + outcome in the user's session.
            let status_str = output
                .status
                .map(|c| c.to_string())
                .unwrap_or_else(|| "spawn-error".to_string());
            crate::log_podman_failure(&label, &status_str, &output.stderr);
            Err(CommandFailure {
                retry: classify_retry(&output),
                output: Box::new(output),
            })
        }
    }
}

/// The message a budget exhaustion produces. Kept as a function so the test can
/// assert the exact shape an operator will read, not a paraphrase of it.
pub fn timeout_message(
    operation: OperationKind,
    redacted_argv: &[String],
    budget: Duration,
) -> String {
    format!(
        "podman {} operation exceeded its {}s budget and was killed: podman {}",
        format!("{operation:?}").to_ascii_lowercase(),
        budget.as_secs(),
        redacted_argv.join(" ")
    )
}

/// Deterministic fake backend for small tests.
#[derive(Default)]
pub struct FakeBackend {
    queued: Mutex<VecDeque<Result<CommandOutput, CommandFailure>>>,
    seen: Mutex<Vec<(OperationKind, Vec<String>)>>,
}

impl FakeBackend {
    pub fn push(&self, response: Result<CommandOutput, CommandFailure>) {
        self.queued.lock().push_back(response);
    }

    pub fn seen(&self) -> Vec<(OperationKind, Vec<String>)> {
        self.seen.lock().clone()
    }
}

#[async_trait]
impl PodmanBackend for FakeBackend {
    async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
        _budget: Duration,
    ) -> Result<CommandOutput, CommandFailure> {
        self.seen.lock().push((operation, argv.to_vec()));
        self.queued.lock().pop_front().unwrap_or_else(|| {
            Ok(CommandOutput {
                operation,
                argv: argv.to_vec(),
                redacted_argv: redact_argv(argv),
                status: Some(0),
                stdout: String::new(),
                stderr: String::new(),
                duration: Duration::ZERO,
            })
        })
    }
}

/// Replay backend that returns a fixed transcript in order.
pub struct ReplayBackend {
    transcript: Mutex<VecDeque<Result<CommandOutput, CommandFailure>>>,
}

impl ReplayBackend {
    pub fn new(transcript: Vec<Result<CommandOutput, CommandFailure>>) -> Self {
        Self {
            transcript: Mutex::new(transcript.into()),
        }
    }
}

#[async_trait]
impl PodmanBackend for ReplayBackend {
    async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
        _budget: Duration,
    ) -> Result<CommandOutput, CommandFailure> {
        self.transcript.lock().pop_front().unwrap_or_else(|| {
            let output = CommandOutput {
                operation,
                argv: argv.to_vec(),
                redacted_argv: redact_argv(argv),
                status: None,
                stdout: String::new(),
                stderr: "replay transcript exhausted".to_string(),
                duration: Duration::ZERO,
            };
            Err(CommandFailure {
                retry: RetryClass::Permanent,
                output: Box::new(output),
            })
        })
    }
}

pub type BackendRef = Arc<dyn PodmanBackend>;

pub fn redact_argv(argv: &[String]) -> Vec<String> {
    let mut redacted = Vec::with_capacity(argv.len());
    let mut hide_next = false;
    for arg in argv {
        if hide_next {
            redacted.push("<redacted>".to_string());
            hide_next = false;
            continue;
        }
        if matches!(arg.as_str(), "--password" | "--token" | "--secret-value") {
            redacted.push(arg.clone());
            hide_next = true;
        } else if arg.contains("TOKEN=") || arg.contains("PASSWORD=") {
            let key = arg.split('=').next().unwrap_or(arg);
            redacted.push(format!("{key}=<redacted>"));
        } else {
            redacted.push(arg.clone());
        }
    }
    redacted
}

pub fn classify_retry(output: &CommandOutput) -> RetryClass {
    let text = format!("{}\n{}", output.stdout, output.stderr).to_ascii_lowercase();
    if text.contains("timeout")
        || text.contains("connection refused")
        || text.contains("temporarily unavailable")
    {
        RetryClass::Retryable
    } else if output.status == Some(125)
        || text.contains("permission denied")
        || text.contains("no such image")
        || text.contains("not found")
        || text.contains("ipam error")
        || text.contains("already allocated")
        || text.contains("netlink error")
    {
        RetryClass::Permanent
    } else {
        RetryClass::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Order 690-7adz, the packet's fourth exit criterion: drive a deliberately
    /// STALLED podman stand-in and assert the failure is bounded and named.
    ///
    /// This exercises `RealBackend` end to end — spawn, deadline, kill — rather
    /// than a fake that returns a pre-cooked timeout, because the property under
    /// test is that the real transport gives up, and a fake cannot fail to.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_stalled_podman_fails_within_its_budget_and_names_the_operation() {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;

        let dir =
            std::env::temp_dir().join(format!("tillandsias-stalled-podman-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fixture dir");
        let stub = dir.join("podman");
        {
            let mut f = std::fs::File::create(&stub).expect("stub");
            // Sleeps regardless of argv: a podman that accepted the command and
            // then never returned, which is what a storage lock looks like.
            writeln!(f, "#!/bin/sh\nsleep 600").expect("write stub");
        }
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        // SAFETY: single-threaded test process env mutation before any spawn.
        unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", &stub) };

        let budget = Duration::from_millis(300);
        let started = Instant::now();
        let failure = RealBackend
            .execute(
                OperationKind::Container,
                &["wait".into(), "--condition=healthy".into(), "vault".into()],
                budget,
            )
            .await
            .expect_err("a stalled podman must not report success");
        let elapsed = started.elapsed();

        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        let _ = std::fs::remove_dir_all(&dir);

        // BOUNDED: the whole point. The stub sleeps 600s; anything near that
        // means the deadline did not fire.
        assert!(
            elapsed < Duration::from_secs(30),
            "stalled call took {elapsed:?}, budget was {budget:?}"
        );
        // NAMED: an operator reading this line must learn what stopped, under
        // what budget, and which command — the original defect was a silent
        // hang, and a bare "timed out" would only shrink it.
        let message = failure.output.stderr.clone();
        assert!(
            message.contains("container"),
            "names the operation: {message}"
        );
        assert!(message.contains("budget"), "names the budget: {message}");
        assert!(
            message.contains("wait --condition=healthy vault"),
            "names the command: {message}"
        );
        assert_eq!(failure.output.status, None);
        // A deadline is not evidence the substrate will recover; claiming
        // Retryable here would turn one hang into a loop of them.
        assert_eq!(failure.retry, RetryClass::Unknown);
    }

    /// Negative control for the test above: with the SAME transport and a stub
    /// that returns promptly, the call must succeed. Without this, the timeout
    /// test could pass because the backend always fails.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_prompt_podman_still_succeeds_under_the_same_budget() {
        use std::io::Write;
        use std::os::unix::fs::PermissionsExt;

        let dir =
            std::env::temp_dir().join(format!("tillandsias-prompt-podman-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fixture dir");
        let stub = dir.join("podman");
        {
            let mut f = std::fs::File::create(&stub).expect("stub");
            writeln!(f, "#!/bin/sh\necho ok").expect("write stub");
        }
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", &stub) };

        let output = RealBackend
            .execute(
                OperationKind::Container,
                &["ps".into()],
                Duration::from_secs(30),
            )
            .await;

        unsafe { std::env::remove_var("TILLANDSIAS_PODMAN_BIN") };
        let _ = std::fs::remove_dir_all(&dir);

        let output = output.expect("a prompt podman must succeed");
        assert_eq!(output.stdout.trim(), "ok");
    }

    /// Every operation class must declare a finite budget. A new variant added
    /// without one would be the unbounded wait creeping back in through the
    /// door this packet closed.
    #[test]
    fn every_operation_class_declares_a_finite_budget() {
        for op in [
            OperationKind::Availability,
            OperationKind::Image,
            OperationKind::Container,
            OperationKind::Network,
            OperationKind::Secret,
            OperationKind::Health,
            OperationKind::Inspect,
            OperationKind::Logs,
            OperationKind::Events,
            OperationKind::Diagnostics,
            OperationKind::Scenario,
        ] {
            let budget = op.default_budget();
            assert!(budget > Duration::ZERO, "{op:?} has a zero budget");
            assert!(
                budget <= Duration::from_secs(3600),
                "{op:?} budget {budget:?} is long enough to read as unbounded"
            );
        }
    }

    #[test]
    fn redacts_tokens() {
        let argv = vec!["run".into(), "-e".into(), "TOKEN=abc".into()];
        assert_eq!(redact_argv(&argv)[2], "TOKEN=<redacted>");
    }

    #[test]
    fn classifies_empty_failure_as_unknown_not_lossy() {
        let out = CommandOutput {
            operation: OperationKind::Container,
            argv: vec!["run".into()],
            redacted_argv: vec!["run".into()],
            status: Some(1),
            stdout: String::new(),
            stderr: String::new(),
            duration: Duration::ZERO,
        };
        let failure = CommandFailure {
            retry: classify_retry(&out),
            output: Box::new(out),
        };
        assert_eq!(failure.retry, RetryClass::Unknown);
        assert!(failure.to_string().contains("no stdout/stderr captured"));
    }

    #[test]
    fn classifies_ipam_allocation_failures_as_permanent() {
        let out = CommandOutput {
            operation: OperationKind::Container,
            argv: vec!["run".into()],
            redacted_argv: vec!["run".into()],
            status: Some(126),
            stdout: String::new(),
            stderr: "IPAM error: requested ip address is already allocated".into(),
            duration: Duration::ZERO,
        };

        assert_eq!(classify_retry(&out), RetryClass::Permanent);
    }
}
