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
#[async_trait]
pub trait PodmanBackend: Send + Sync {
    async fn execute(
        &self,
        operation: OperationKind,
        argv: &[String],
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
    ) -> Result<CommandOutput, CommandFailure> {
        let started = Instant::now();
        let mut cmd = crate::podman_cmd();
        cmd.args(argv);
        // User-visible debug log (only when --debug / TILLANDSIAS_DEBUG=1). See
        // crate::log_podman_invocation for the format and redaction rules.
        let label = format!("{:?}", operation).to_ascii_lowercase();
        crate::log_podman_invocation(&label, cmd.as_std());
        let result = cmd.output().await;
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
