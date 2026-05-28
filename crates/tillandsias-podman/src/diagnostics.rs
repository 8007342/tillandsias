use std::fmt;

use tillandsias_core::event::ContainerState;

use crate::backend::{CommandFailure, CommandOutput, OperationKind, RetryClass};

/// Origin of one container lifecycle observation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleSource {
    PodmanEvents,
    WslRouter,
    BackoffInspection,
}

impl fmt::Display for LifecycleSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::PodmanEvents => "podman-events",
            Self::WslRouter => "wsl-router",
            Self::BackoffInspection => "backoff-inspection",
        };
        f.write_str(label)
    }
}

/// Semantic action inferred from a raw lifecycle source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerLifecycleAction {
    Created,
    Started,
    StopRequested,
    Killed,
    Died,
    /// Killed by the kernel OOM killer. Podman events emits this as
    /// `Status=oom` separately from `died` (a Died record typically
    /// follows). Routed to `event:resource_exhaustion` by the
    /// diagnostic-event emitter so the orchestrator can distinguish
    /// "container exited with non-zero" from "kernel killed it for
    /// breaching its memory cgroup limit".
    ///
    /// @trace spec:runtime-diagnostics-stream (Resource event)
    Oom,
    Removed,
    CleanedUp,
    Observed,
    Disappeared,
}

impl fmt::Display for ContainerLifecycleAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Created => "created",
            Self::Started => "started",
            Self::StopRequested => "stop-requested",
            Self::Killed => "killed",
            Self::Died => "died",
            Self::Oom => "oom",
            Self::Removed => "removed",
            Self::CleanedUp => "cleaned-up",
            Self::Observed => "observed",
            Self::Disappeared => "disappeared",
        };
        f.write_str(label)
    }
}

/// Loss-minimized lifecycle fact used before adapting back to runtime events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerLifecycleRecord {
    pub container_name: String,
    pub action: ContainerLifecycleAction,
    pub new_state: ContainerState,
    pub source: LifecycleSource,
    pub raw_status: Option<String>,
    pub observed_at_unix: Option<i64>,
    /// Container exit code when the source can carry it (podman events
    /// emits `ContainerExitCode` on `Status=died` payloads). `None` for
    /// non-terminal actions and for sources that don't expose it (today
    /// the WSL router event channel doesn't). Feeds the (future)
    /// `event:container_exit container=… exit_code=…` typed-event line
    /// pinned in `format_container_exit_event`.
    ///
    /// @trace spec:runtime-diagnostics-stream (Container exit event)
    pub exit_code: Option<i32>,
}

impl ContainerLifecycleRecord {
    pub fn render_human(&self) -> String {
        let mut rendered = format!(
            "event:container_lifecycle container={} action={} state={:?} source={}",
            self.container_name, self.action, self.new_state, self.source
        );
        if let Some(raw_status) = &self.raw_status {
            rendered.push_str(&format!(" raw_status={raw_status}"));
        }
        if let Some(observed_at_unix) = self.observed_at_unix {
            rendered.push_str(&format!(" observed_at_unix={observed_at_unix}"));
        }
        if let Some(exit_code) = self.exit_code {
            rendered.push_str(&format!(" exit_code={exit_code}"));
        }
        rendered
    }
}

/// The channel Podman exposes for followed logs today.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerLogChannel {
    Combined,
}

/// One typed line from a followed container log stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerLogRecord {
    pub container_name: String,
    pub channel: ContainerLogChannel,
    pub line: String,
}

impl ContainerLogRecord {
    pub fn combined(container_name: impl Into<String>, line: impl Into<String>) -> Self {
        Self {
            container_name: container_name.into(),
            channel: ContainerLogChannel::Combined,
            line: line.into(),
        }
    }

    /// Keep the historic terminal format while callers gain a typed record.
    pub fn render_human(&self) -> String {
        format!("[{}] {}", self.container_name, self.line)
    }
}

/// Recent log output captured for failure analysis.
#[derive(Debug, Clone, Default)]
pub struct LogTail {
    pub lines: Vec<String>,
}

impl LogTail {
    pub fn records_for(&self, container_name: &str) -> Vec<ContainerLogRecord> {
        self.lines
            .iter()
            .cloned()
            .map(|line| ContainerLogRecord::combined(container_name, line))
            .collect()
    }
}

/// Compact command facts suitable for snapshots and terminal rendering.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSnapshot {
    pub operation: OperationKind,
    pub redacted_argv: Vec<String>,
    pub status: Option<i32>,
    pub stdout_lines: usize,
    pub stderr_lines: usize,
}

impl From<&CommandOutput> for CommandSnapshot {
    fn from(output: &CommandOutput) -> Self {
        Self {
            operation: output.operation,
            redacted_argv: output.redacted_argv.clone(),
            status: output.status,
            stdout_lines: output.stdout.lines().count(),
            stderr_lines: output.stderr.lines().count(),
        }
    }
}

/// Stable summary of a diagnostics capture, cheap to compare in tests or logs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerDiagnosticsSnapshot {
    pub name: String,
    pub state: Option<String>,
    pub image: Option<String>,
    pub health: Option<String>,
    pub inspect_bytes: Option<usize>,
    pub log_line_count: usize,
    pub command: Option<CommandSnapshot>,
    pub failure: Option<CommandSnapshot>,
    pub failure_retry: Option<RetryClass>,
}

/// Inspect-derived container facts kept separate from presentation.
#[derive(Debug, Clone, Default)]
pub struct ContainerDiagnostics {
    pub name: String,
    pub state: Option<String>,
    pub image: Option<String>,
    pub health: Option<String>,
    pub inspect_json: Option<String>,
    pub log_tail: LogTail,
    pub command: Option<CommandOutput>,
    pub failure: Option<CommandFailure>,
}

impl ContainerDiagnostics {
    pub fn snapshot(&self) -> ContainerDiagnosticsSnapshot {
        ContainerDiagnosticsSnapshot {
            name: self.name.clone(),
            state: self.state.clone(),
            image: self.image.clone(),
            health: self.health.clone(),
            inspect_bytes: self.inspect_json.as_ref().map(String::len),
            log_line_count: self.log_tail.lines.len(),
            command: self.command.as_ref().map(CommandSnapshot::from),
            failure: self
                .failure
                .as_ref()
                .map(|failure| CommandSnapshot::from(failure.output.as_ref())),
            failure_retry: self.failure.as_ref().map(|failure| failure.retry),
        }
    }

    pub fn render_human(&self) -> String {
        let mut out = vec![format!("container: {}", self.name)];
        if let Some(state) = &self.state {
            out.push(format!("state: {state}"));
        }
        if let Some(image) = &self.image {
            out.push(format!("image: {image}"));
        }
        if let Some(health) = &self.health {
            out.push(format!("health: {health}"));
        }
        if let Some(inspect_json) = &self.inspect_json {
            out.push(format!(
                "inspect json: {} bytes captured",
                inspect_json.len()
            ));
        }
        if let Some(command) = &self.command {
            out.push(render_command("last command", command));
        }
        if let Some(failure) = &self.failure {
            out.push(failure.to_string());
        }
        if !self.log_tail.lines.is_empty() {
            out.push("recent logs:".into());
            out.extend(self.log_tail.lines.iter().map(|line| format!("  {line}")));
        }
        out.join("\n")
    }
}

fn render_command(label: &str, command: &CommandOutput) -> String {
    format!(
        "{label}: {:?} podman {} (status {:?}, {} ms)",
        command.operation,
        command.redacted_argv.join(" "),
        command.status,
        command.duration.as_millis()
    )
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    fn command_output() -> CommandOutput {
        CommandOutput {
            operation: OperationKind::Inspect,
            argv: vec!["inspect".into(), "secret".into()],
            redacted_argv: vec!["inspect".into(), "<redacted>".into()],
            status: Some(0),
            stdout: "line one\nline two\n".into(),
            stderr: String::new(),
            duration: Duration::from_millis(17),
        }
    }

    #[test]
    fn lifecycle_records_render_source_and_raw_status() {
        let record = ContainerLifecycleRecord {
            container_name: "tillandsias-demo-aeranthos".into(),
            action: ContainerLifecycleAction::Started,
            new_state: ContainerState::Running,
            source: LifecycleSource::PodmanEvents,
            raw_status: Some("start".into()),
            observed_at_unix: Some(1_711_400_000),
            exit_code: None,
        };

        assert_eq!(
            record.render_human(),
            "event:container_lifecycle container=tillandsias-demo-aeranthos action=started state=Running source=podman-events raw_status=start observed_at_unix=1711400000"
        );
    }

    /// A Died record with a captured `exit_code` renders the additional
    /// `exit_code=<N>` field — pinned by unit test so the (future)
    /// `event:container_exit ... exit_code=…` typed-event line and any
    /// downstream grep stay deterministic across renderers.
    #[test]
    fn lifecycle_records_render_exit_code_when_present() {
        let record = ContainerLifecycleRecord {
            container_name: "tillandsias-demo-aeranthos".into(),
            action: ContainerLifecycleAction::Died,
            new_state: ContainerState::Stopped,
            source: LifecycleSource::PodmanEvents,
            raw_status: Some("died".into()),
            observed_at_unix: Some(1_711_400_005),
            exit_code: Some(137),
        };

        assert_eq!(
            record.render_human(),
            "event:container_lifecycle container=tillandsias-demo-aeranthos action=died state=Stopped source=podman-events raw_status=died observed_at_unix=1711400005 exit_code=137"
        );
    }

    #[test]
    fn log_records_keep_legacy_human_prefix() {
        let record = ContainerLogRecord::combined("tillandsias-demo-aeranthos", "forge ready");

        assert_eq!(
            record.render_human(),
            "[tillandsias-demo-aeranthos] forge ready"
        );
    }

    #[test]
    fn diagnostics_snapshot_keeps_structured_command_facts() {
        let command = command_output();
        let diagnostics = ContainerDiagnostics {
            name: "tillandsias-demo-aeranthos".into(),
            inspect_json: Some(r#"{"State":"running"}"#.into()),
            log_tail: LogTail {
                lines: vec!["one".into(), "two".into()],
            },
            command: Some(command.clone()),
            failure: Some(CommandFailure {
                output: Box::new(command),
                retry: RetryClass::Retryable,
            }),
            ..Default::default()
        };

        let snapshot = diagnostics.snapshot();
        assert_eq!(snapshot.inspect_bytes, Some(19));
        assert_eq!(snapshot.log_line_count, 2);
        assert_eq!(snapshot.command.unwrap().stdout_lines, 2);
        assert_eq!(snapshot.failure_retry, Some(RetryClass::Retryable));
    }

    #[test]
    fn human_rendering_adds_command_and_inspect_without_losing_logs() {
        let diagnostics = ContainerDiagnostics {
            name: "tillandsias-demo-aeranthos".into(),
            state: Some("running".into()),
            inspect_json: Some("{}".into()),
            log_tail: LogTail {
                lines: vec!["forge ready".into()],
            },
            command: Some(command_output()),
            ..Default::default()
        };

        let rendered = diagnostics.render_human();
        assert!(rendered.contains("inspect json: 2 bytes captured"));
        assert!(rendered.contains("last command: Inspect podman inspect <redacted>"));
        assert!(rendered.contains("recent logs:\n  forge ready"));
    }

    #[test]
    fn log_tail_projects_to_typed_records() {
        let tail = LogTail {
            lines: vec!["one".into(), "two".into()],
        };

        let records = tail.records_for("demo");
        assert_eq!(records.len(), 2);
        assert_eq!(records[1], ContainerLogRecord::combined("demo", "two"));
    }
}
