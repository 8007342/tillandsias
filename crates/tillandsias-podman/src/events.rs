// @trace spec:podman-orchestration, spec:cross-platform, spec:wsl-daemon-orchestration, spec:fix-windows-extended-path

use std::collections::HashSet;
use std::time::Duration;

use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use tillandsias_core::event::ContainerState;

#[cfg(not(target_os = "windows"))]
use crate::OperationKind;
use crate::diagnostics::{ContainerLifecycleAction, ContainerLifecycleRecord, LifecycleSource};
#[cfg(not(target_os = "windows"))]
use crate::diagnostics_stream::spawn_podman_stream;

/// Event from podman events stream.
#[derive(Debug, Clone)]
pub struct PodmanEvent {
    pub container_name: String,
    pub new_state: ContainerState,
}

impl From<ContainerLifecycleRecord> for PodmanEvent {
    fn from(record: ContainerLifecycleRecord) -> Self {
        Self {
            container_name: record.container_name,
            new_state: record.new_state,
        }
    }
}

/// Streams container state changes via `podman events`.
/// Falls back to exponential backoff status checks when events are unavailable.
pub struct PodmanEventStream {
    /// Filter containers by this name prefix.
    prefix: String,
}

impl PodmanEventStream {
    pub fn new(prefix: &str) -> Self {
        Self {
            prefix: prefix.to_string(),
        }
    }

    /// Start streaming events. Sends to the provided channel.
    /// Platform-specific dispatch:
    /// - **Linux**: Uses `podman events --format json` as primary source.
    /// - **Windows (WSL)**: Connects to systemd socket at `\\wsl$\<distro>\run\tillandsias\router.sock`.
    /// - Falls back to exponential backoff inspection when events fail.
    ///
    /// The outer loop has its own exponential backoff (2s → 5min) to prevent
    /// tight retry loops when podman is persistently unavailable (e.g. machine
    /// not running on macOS/Windows).
    // @trace spec:podman-orchestration, spec:cross-platform, spec:wsl-daemon-orchestration
    pub async fn stream(self, tx: mpsc::Sender<PodmanEvent>) {
        let mut attempt: u32 = 0;

        loop {
            attempt += 1;

            // Log every attempt initially, then only every 5th to reduce spam
            if attempt <= 3 || attempt.is_multiple_of(5) {
                info!(attempt, "Starting podman events listener");
            }

            // Try event-driven approach first (platform-specific)
            #[cfg(target_os = "windows")]
            let stream_result = self.stream_events_wsl(&tx).await;
            #[cfg(not(target_os = "windows"))]
            let stream_result = self.stream_events(&tx).await;

            match stream_result {
                Ok(()) => return, // Clean shutdown (channel closed)
                Err(e) => {
                    if attempt <= 3 || attempt.is_multiple_of(5) {
                        warn!(
                            ?e,
                            attempt,
                            "Podman/WSL events stream failed, falling back to backoff inspection"
                        );
                    }
                }
            }

            // Fall back to exponential backoff inspection (1s → 30s internal backoff).
            // Blocks until podman service becomes available (Ok) or channel closes (Err).
            match self.backoff_inspect(&tx).await {
                Ok(()) => {
                    // Podman came back — reset attempt counter and retry stream_events
                    attempt = 0;
                }
                Err(()) => return, // Channel closed
            }
        }
    }

    /// Lossless sibling of [`Self::stream`]: emits full
    /// [`ContainerLifecycleRecord`]s (carrying `exit_code`, `action`,
    /// `source`, ...) instead of the simplified `PodmanEvent`. The
    /// retry/backoff/fall-back-to-inspect machinery is identical to
    /// `stream`; only the channel item type differs.
    ///
    /// Intended consumer: the gap-2/3 phase-2 diagnostics-stream emitter
    /// that converts each record into a typed `event:container_exit`
    /// (with `exit_code` and `duration_seconds`) or `event:container_signal`
    /// line via `format_container_*_event` + `emit_diagnostic_event`. Today
    /// (slice 2026-05-28T12:23Z) only the channel surface is provided; the
    /// wiring lives in a follow-on slice.
    ///
    /// @trace spec:runtime-diagnostics-stream, spec:podman-orchestration
    /// @trace plan/issues/linux-headless-spec-gaps-2026-05-27.md (gap 3 phase-2)
    pub async fn stream_records(self, tx: mpsc::Sender<ContainerLifecycleRecord>) {
        let mut attempt: u32 = 0;

        loop {
            attempt += 1;

            if attempt <= 3 || attempt.is_multiple_of(5) {
                info!(attempt, "Starting podman events listener (records sink)");
            }

            #[cfg(target_os = "windows")]
            let stream_result = self.stream_events_wsl(&tx).await;
            #[cfg(not(target_os = "windows"))]
            let stream_result = self.stream_events(&tx).await;

            match stream_result {
                Ok(()) => return,
                Err(e) => {
                    if attempt <= 3 || attempt.is_multiple_of(5) {
                        warn!(
                            ?e,
                            attempt,
                            "Podman/WSL events stream (records sink) failed, falling back to backoff inspection"
                        );
                    }
                }
            }

            match self.backoff_inspect(&tx).await {
                Ok(()) => {
                    attempt = 0;
                }
                Err(()) => return,
            }
        }
    }

    /// Primary (Linux): stream `podman events --format json`.
    ///
    /// No container name filter on the command -- podman's `--filter container=`
    /// takes exact names, not globs. We filter by prefix in `parse_podman_event()`.
    ///
    /// Generic on the sink item type `T: From<ContainerLifecycleRecord>` so the
    /// same parse loop can drive two public methods: `stream` (lossy
    /// `PodmanEvent`, keeps UI-state callers happy) and `stream_records`
    /// (lossless `ContainerLifecycleRecord` carrying `exit_code` etc., used by
    /// the diagnostics-stream emitter when gap-2/3 phase-2 wiring lands).
    /// Reflexive `T: From<T>` makes the records case a free no-op conversion.
    // @trace spec:podman-orchestration
    #[cfg(not(target_os = "windows"))]
    async fn stream_events<T>(&self, tx: &mpsc::Sender<T>) -> Result<(), PodmanEventError>
    where
        T: From<ContainerLifecycleRecord> + Send + 'static,
    {
        debug!(prefix = %self.prefix, "Starting podman events stream (no name filter, prefix matched in-process)");

        let mut child = spawn_podman_stream(
            OperationKind::Events,
            vec![
                "events".into(),
                "--format".into(),
                "json".into(),
                "--filter".into(),
                "type=container".into(),
            ],
        )
        .map_err(|e| PodmanEventError::SpawnFailed(e.to_string()))?;

        let stdout = child.stdout.take().ok_or(PodmanEventError::NoStdout)?;
        let mut reader = tokio::io::BufReader::new(stdout);
        let mut line = String::new();

        loop {
            line.clear();
            use tokio::io::AsyncBufReadExt;
            match reader.read_line(&mut line).await {
                Ok(0) => {
                    // EOF — podman events process exited
                    debug!("Podman events stream reached EOF");
                    return Err(PodmanEventError::StreamEnded);
                }
                Ok(_) => {
                    debug!(raw_json = %line.trim(), "Received podman event line");
                    if let Some(record) = parse_podman_lifecycle_record(&line, &self.prefix) {
                        debug!(
                            container = %record.container_name,
                            action = %record.action,
                            state = ?record.new_state,
                            source = %record.source,
                            "Dispatching parsed container event"
                        );
                        if tx.send(record.into()).await.is_err() {
                            return Ok(()); // Channel closed, clean shutdown
                        }
                    }
                }
                Err(e) => {
                    return Err(PodmanEventError::ReadError(e.to_string()));
                }
            }
        }
    }

    /// Windows (WSL): Connect to systemd socket and listen for state change notifications.
    ///
    /// The router daemon in WSL runs under systemd with socket activation and sd_notify.
    /// This method connects to the WSL socket at `\\wsl$\<distro>\run\tillandsias\router.sock`
    /// and receives event notifications when container state changes occur in the daemon.
    ///
    /// Event format (newline-delimited JSON):
    /// ```json
    /// {"container":"tillandsias-myapp-aeranthos","state":"Running"}
    /// {"container":"tillandsias-myapp-aeranthos","state":"Stopped"}
    /// ```
    ///
    /// The daemon notifies via `sd_notify("WATCHDOG=1")` every 10s (WatchdogSec=10s in unit).
    /// Connection drops trigger fallback to backoff inspection.
    // @trace spec:cross-platform, spec:wsl-daemon-orchestration
    // @cheatsheet runtime/wsl-daemon-patterns.md, runtime/systemd-socket-activation.md
    #[cfg(target_os = "windows")]
    async fn stream_events_wsl<T>(&self, tx: &mpsc::Sender<T>) -> Result<(), PodmanEventError>
    where
        T: From<ContainerLifecycleRecord> + Send + 'static,
    {
        use tokio::fs::OpenOptions;

        debug!(prefix = %self.prefix, "Starting WSL systemd socket stream");

        // Construct socket path: \\wsl$\<distro>\run\tillandsias\router.sock
        // Get distro name from TILLANDSIAS_WSL_DISTRO env var, default to "Fedora"
        let distro =
            std::env::var("TILLANDSIAS_WSL_DISTRO").unwrap_or_else(|_| "Fedora".to_string());

        // On Windows, UNC path to WSL socket: \\wsl$\Fedora\run\tillandsias\router.sock
        let socket_path = format!(r"\\wsl$\{}\run\tillandsias\router.sock", distro);

        debug!(socket_path = %socket_path, "Connecting to WSL router socket");

        // Open the socket as a named pipe (Windows treats Unix sockets as named pipes in WSL)
        let sock_file = OpenOptions::new()
            .read(true)
            .open(&socket_path)
            .await
            .map_err(|e| {
                debug!(socket_path = %socket_path, error = %e, "Failed to open WSL socket");
                PodmanEventError::SpawnFailed(format!("WSL socket open failed: {}", e))
            })?;

        let mut reader = tokio::io::BufReader::new(sock_file);
        let mut line = String::new();

        loop {
            line.clear();
            use tokio::io::AsyncBufReadExt;
            match reader.read_line(&mut line).await {
                Ok(0) => {
                    // EOF — socket closed by daemon or WSL
                    debug!("WSL socket stream reached EOF");
                    return Err(PodmanEventError::StreamEnded);
                }
                Ok(_) => {
                    debug!(raw_json = %line.trim(), "Received WSL event line");

                    // Parse WSL event format: {"container":"name","state":"Running|Stopped|Creating"}
                    if let Some(record) = parse_wsl_lifecycle_record(&line, &self.prefix) {
                        debug!(
                            container = %record.container_name,
                            action = %record.action,
                            state = ?record.new_state,
                            source = %record.source,
                            "Dispatching parsed container event from WSL"
                        );
                        if tx.send(record.into()).await.is_err() {
                            return Ok(()); // Channel closed, clean shutdown
                        }
                    }
                }
                Err(e) => {
                    debug!(error = %e, "WSL socket read error");
                    return Err(PodmanEventError::ReadError(e.to_string()));
                }
            }
        }
    }

    /// Fallback: exponential backoff inspection.
    /// Starts at 1s, doubles to 30s max. NEVER fixed-interval polling.
    ///
    /// Tracks previously-seen running containers so that disappearances
    /// (from `--rm` containers dying) are detected and reported as Stopped.
    async fn backoff_inspect<T>(&self, tx: &mpsc::Sender<T>) -> Result<(), ()>
    where
        T: From<ContainerLifecycleRecord> + Send + 'static,
    {
        let mut interval = Duration::from_secs(1);
        let max_interval = Duration::from_secs(30);
        let mut known_running: HashSet<String> = HashSet::new();

        debug!("Fallback backoff inspection activated");

        loop {
            tokio::time::sleep(interval).await;

            // Try to reconnect — `podman info` actually connects to the podman
            // service, unlike `--help` which succeeds even when the machine is down.
            let mut info_cmd = crate::podman_cmd();
            info_cmd
                .args(["info", "--format", "json"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            crate::log_podman_invocation("events:info-probe", info_cmd.as_std());
            if info_cmd.output().await.is_ok_and(|o| o.status.success()) {
                info!("Podman service available again, switching to event stream");
                return Ok(()); // Will restart stream_events in outer loop
            }

            // Inspect containers as fallback
            let mut ps_cmd = crate::podman_cmd();
            ps_cmd.args([
                "ps",
                "-a",
                "--filter",
                &format!("name=^{}", self.prefix),
                "--format",
                "json",
            ]);
            crate::log_podman_invocation("events:ps-fallback", ps_cmd.as_std());
            let output = ps_cmd.output().await;

            if let Ok(o) = output
                && o.status.success()
            {
                let stdout = String::from_utf8_lossy(&o.stdout);
                let mut current_names: HashSet<String> = HashSet::new();

                if let Ok(entries) = serde_json::from_str::<Vec<serde_json::Value>>(&stdout) {
                    for entry in entries {
                        if let (Some(name), Some(state)) = (
                            entry["Names"]
                                .as_array()
                                .and_then(|n| n.first())
                                .and_then(|n| n.as_str()),
                            entry["State"].as_str(),
                        ) {
                            let new_state = match state {
                                "running" => ContainerState::Running,
                                "created" | "configured" => ContainerState::Creating,
                                "exited" | "stopped" => ContainerState::Stopped,
                                _ => ContainerState::Absent,
                            };

                            if new_state == ContainerState::Running {
                                current_names.insert(name.to_string());
                            }

                            let record = ContainerLifecycleRecord {
                                container_name: name.to_string(),
                                action: ContainerLifecycleAction::Observed,
                                new_state,
                                source: LifecycleSource::BackoffInspection,
                                raw_status: Some(state.to_string()),
                                observed_at_unix: None,
                                // `podman ps` doesn't include the exit
                                // code in its JSON output — exit codes
                                // come from `podman events` Died lines.
                                exit_code: None,
                            };

                            if tx.send(record.into()).await.is_err() {
                                return Err(()); // Channel closed
                            }
                        }
                    }
                }

                // Detect disappearances: containers that were running but are now
                // absent from `podman ps`. This happens with `--rm` containers
                // which are removed immediately on death.
                for vanished in known_running.difference(&current_names) {
                    debug!(
                        container = %vanished,
                        "Container disappeared from podman ps (--rm death detected)"
                    );
                    let record = ContainerLifecycleRecord {
                        container_name: vanished.clone(),
                        action: ContainerLifecycleAction::Disappeared,
                        new_state: ContainerState::Stopped,
                        source: LifecycleSource::BackoffInspection,
                        raw_status: None,
                        observed_at_unix: None,
                        // `--rm` removed the container before we could
                        // observe its exit; the code is gone.
                        exit_code: None,
                    };
                    if tx.send(record.into()).await.is_err() {
                        return Err(()); // Channel closed
                    }
                }

                known_running = current_names;
            }

            // Exponential backoff (never fixed-interval)
            interval = (interval * 2).min(max_interval);
        }
    }
}

/// Parse a JSON event line from `podman events --format json`.
///
/// Podman emits events with top-level `Name` and `Status` fields:
/// ```json
/// {"Name": "tillandsias-tetris-aeranthos", "Status": "died", "Type": "container", ...}
/// ```
/// Note: This is NOT Docker's format (`Actor.Attributes.name` / `Action`).
// @trace spec:podman-orchestration
#[cfg(test)]
fn parse_podman_event(json_line: &str, prefix: &str) -> Option<PodmanEvent> {
    parse_podman_lifecycle_record(json_line, prefix).map(PodmanEvent::from)
}

fn parse_podman_lifecycle_record(
    json_line: &str,
    prefix: &str,
) -> Option<ContainerLifecycleRecord> {
    let value: serde_json::Value = serde_json::from_str(json_line.trim()).ok()?;

    let name = value["Name"].as_str()?;
    if !name.starts_with(prefix) {
        return None;
    }

    let action = value["Status"].as_str()?;
    let (action, new_state) = match action {
        "start" => (ContainerLifecycleAction::Started, ContainerState::Running),
        "create" => (ContainerLifecycleAction::Created, ContainerState::Creating),
        "stop" => (
            ContainerLifecycleAction::StopRequested,
            ContainerState::Stopping,
        ),
        "kill" => (ContainerLifecycleAction::Killed, ContainerState::Stopping),
        "died" => (ContainerLifecycleAction::Died, ContainerState::Stopped),
        // Podman emits `Status=oom` as a SEPARATE event from `died`
        // when the kernel OOM killer reaps a container — both fire,
        // typically in close succession. We surface it as a distinct
        // typed event downstream (event:resource_exhaustion with
        // resource=memory_oom) so operators can distinguish a clean
        // non-zero exit from a memory-limit kill.
        "oom" => (ContainerLifecycleAction::Oom, ContainerState::Stopped),
        "remove" => (ContainerLifecycleAction::Removed, ContainerState::Stopped),
        "cleanup" => (ContainerLifecycleAction::CleanedUp, ContainerState::Stopped),
        _ => return None,
    };

    // Podman emits the container's exit status on `Status=died` payloads
    // as `ContainerExitCode` (top-level integer). Some older builds put it
    // under `Actor.Attributes.containerExitCode` instead — accept both.
    // For non-Died statuses there's no exit code to capture.
    let exit_code = if matches!(action, ContainerLifecycleAction::Died) {
        extract_podman_exit_code(&value)
    } else {
        None
    };

    Some(ContainerLifecycleRecord {
        container_name: name.to_string(),
        action,
        new_state,
        source: LifecycleSource::PodmanEvents,
        raw_status: value["Status"].as_str().map(str::to_string),
        observed_at_unix: value["Time"].as_i64(),
        exit_code,
    })
}

/// Extract a container exit code from a podman events JSON payload.
///
/// Podman has shipped two shapes over the years; we read both:
///   * top-level `ContainerExitCode` (current; observed on podman 4.x+)
///   * `Actor.Attributes.containerExitCode` (older builds, stringified)
///
/// Returns `None` if neither field is present or convertible to `i32`.
/// Exit codes outside `i32` are clamped to `None` rather than silently
/// truncated.
fn extract_podman_exit_code(value: &serde_json::Value) -> Option<i32> {
    if let Some(n) = value.get("ContainerExitCode").and_then(|v| v.as_i64()) {
        return i32::try_from(n).ok();
    }
    let attr = value
        .get("Actor")
        .and_then(|a| a.get("Attributes"))
        .and_then(|a| a.get("containerExitCode"))?;
    if let Some(n) = attr.as_i64() {
        return i32::try_from(n).ok();
    }
    if let Some(s) = attr.as_str() {
        return s.parse::<i32>().ok();
    }
    None
}

/// Parse a JSON event line from the WSL router systemd socket.
///
/// The WSL daemon sends events with "container" and "state" fields:
/// ```json
/// {"container":"tillandsias-myapp-aeranthos","state":"Running"}
/// {"container":"tillandsias-myapp-aeranthos","state":"Stopped"}
/// {"container":"tillandsias-myapp-aeranthos","state":"Creating"}
/// ```
///
/// State values are uppercase: Running, Stopped, Creating, Stopping.
// @trace spec:cross-platform, spec:wsl-daemon-orchestration
// @cheatsheet runtime/wsl-daemon-patterns.md
#[cfg(all(target_os = "windows", test))]
fn parse_wsl_event(json_line: &str, prefix: &str) -> Option<PodmanEvent> {
    parse_wsl_lifecycle_record(json_line, prefix).map(PodmanEvent::from)
}

#[cfg(target_os = "windows")]
fn parse_wsl_lifecycle_record(json_line: &str, prefix: &str) -> Option<ContainerLifecycleRecord> {
    let value: serde_json::Value = serde_json::from_str(json_line.trim()).ok()?;

    let name = value["container"].as_str()?;
    if !name.starts_with(prefix) {
        return None;
    }

    let state_str = value["state"].as_str()?;
    let (action, new_state) = match state_str {
        "Running" => (ContainerLifecycleAction::Started, ContainerState::Running),
        "Creating" => (ContainerLifecycleAction::Created, ContainerState::Creating),
        "Stopping" => (
            ContainerLifecycleAction::StopRequested,
            ContainerState::Stopping,
        ),
        "Stopped" => (ContainerLifecycleAction::Died, ContainerState::Stopped),
        _ => return None,
    };

    Some(ContainerLifecycleRecord {
        container_name: name.to_string(),
        action,
        new_state,
        source: LifecycleSource::WslRouter,
        raw_status: Some(state_str.to_string()),
        observed_at_unix: None,
        // The WSL router systemd-socket event channel doesn't expose
        // exit codes today; can be plumbed through later if needed.
        exit_code: None,
    })
}

#[derive(Debug, thiserror::Error)]
enum PodmanEventError {
    #[error("Failed to spawn podman events: {0}")]
    SpawnFailed(String),
    #[error("No stdout from podman events")]
    NoStdout,
    #[error("Event stream ended")]
    StreamEnded,
    #[error("Read error: {0}")]
    ReadError(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a podman-format JSON event line.
    fn podman_event_json(name: &str, status: &str) -> String {
        format!(r#"{{"Name":"{name}","Status":"{status}","Type":"container","Time":1711400000}}"#)
    }

    #[test]
    fn parse_start_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "start");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.container_name, "tillandsias-tetris-aeranthos");
        assert_eq!(event.new_state, ContainerState::Running);
    }

    #[test]
    fn typed_lifecycle_record_preserves_podman_action_source_and_time() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "start");
        let record = parse_podman_lifecycle_record(&json, "tillandsias-").unwrap();

        assert_eq!(record.container_name, "tillandsias-tetris-aeranthos");
        assert_eq!(record.action, ContainerLifecycleAction::Started);
        assert_eq!(record.new_state, ContainerState::Running);
        assert_eq!(record.source, LifecycleSource::PodmanEvents);
        assert_eq!(record.raw_status.as_deref(), Some("start"));
        assert_eq!(record.observed_at_unix, Some(1_711_400_000));
    }

    #[test]
    fn typed_lifecycle_record_distinguishes_stop_and_kill() {
        let stop = parse_podman_lifecycle_record(
            &podman_event_json("tillandsias-tetris-aeranthos", "stop"),
            "tillandsias-",
        )
        .unwrap();
        let kill = parse_podman_lifecycle_record(
            &podman_event_json("tillandsias-tetris-aeranthos", "kill"),
            "tillandsias-",
        )
        .unwrap();

        assert_eq!(stop.action, ContainerLifecycleAction::StopRequested);
        assert_eq!(kill.action, ContainerLifecycleAction::Killed);
        assert_eq!(stop.new_state, kill.new_state);
    }

    #[test]
    fn parse_create_event() {
        let json = podman_event_json("tillandsias-myapp-ionantha", "create");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Creating);
    }

    #[test]
    fn parse_died_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "died");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopped);
    }

    /// Modern podman 4.x+ shape: `ContainerExitCode` at the top level of
    /// the event JSON. Verifies the typed record captures it for the
    /// `event:container_exit ... exit_code=…` typed-event downstream.
    #[test]
    fn died_event_extracts_top_level_exit_code() {
        let json = r#"{"Name":"tillandsias-x-forge","Status":"died","Type":"container","Time":1711400005,"ContainerExitCode":137}"#;
        let record = parse_podman_lifecycle_record(json, "tillandsias-").unwrap();
        assert_eq!(record.action, ContainerLifecycleAction::Died);
        assert_eq!(record.exit_code, Some(137));
    }

    /// Older podman builds put the exit code on the Actor.Attributes
    /// blob, sometimes stringified. The extractor accepts both shapes.
    #[test]
    fn died_event_extracts_legacy_actor_attributes_exit_code() {
        let json = r#"{
            "Name":"tillandsias-x-forge",
            "Status":"died",
            "Type":"container",
            "Time":1711400005,
            "Actor":{"Attributes":{"containerExitCode":"137"}}
        }"#;
        let record = parse_podman_lifecycle_record(json, "tillandsias-").unwrap();
        assert_eq!(record.exit_code, Some(137));

        // Integer (non-stringified) Actor.Attributes form also works.
        let json_int = r#"{
            "Name":"tillandsias-x-forge",
            "Status":"died",
            "Type":"container",
            "Time":1711400005,
            "Actor":{"Attributes":{"containerExitCode":42}}
        }"#;
        let record = parse_podman_lifecycle_record(json_int, "tillandsias-").unwrap();
        assert_eq!(record.exit_code, Some(42));
    }

    /// Non-Died statuses MUST NOT carry an exit_code, even if a payload
    /// happens to ship a `ContainerExitCode`. Exit codes are only
    /// semantically meaningful at termination — anything else would be a
    /// stale value from a previous run leaking into a Start record.
    #[test]
    fn non_died_events_have_no_exit_code() {
        for status in ["start", "create", "stop", "kill", "remove", "cleanup"] {
            let json = format!(
                r#"{{"Name":"tillandsias-x","Status":"{status}","Type":"container","Time":1,"ContainerExitCode":99}}"#
            );
            let record = parse_podman_lifecycle_record(&json, "tillandsias-").unwrap();
            assert_eq!(
                record.exit_code, None,
                "status={status} should not carry exit_code"
            );
        }
    }

    /// A Died event without any exit-code field gracefully reports None
    /// — we never fabricate a value (matching the same honesty principle
    /// as the metrics endpoint).
    #[test]
    fn died_event_without_exit_code_reports_none() {
        let json = r#"{"Name":"tillandsias-x","Status":"died","Type":"container","Time":1}"#;
        let record = parse_podman_lifecycle_record(json, "tillandsias-").unwrap();
        assert_eq!(record.action, ContainerLifecycleAction::Died);
        assert_eq!(record.exit_code, None);
    }

    /// `Status=oom` is its own podman event (fires alongside `died`
    /// when the kernel reaps a container for breaching its memory
    /// cgroup limit). It maps to the dedicated `Oom` action so the
    /// downstream emitter can produce `event:resource_exhaustion`
    /// rather than a generic `event:container_exit`.
    #[test]
    fn parse_oom_event() {
        let json = r#"{"Name":"tillandsias-myproject-forge","Status":"oom","Type":"container","Time":1711400005,"ContainerExitCode":137}"#;
        let record = parse_podman_lifecycle_record(json, "tillandsias-").unwrap();
        assert_eq!(record.action, ContainerLifecycleAction::Oom);
        assert_eq!(record.new_state, ContainerState::Stopped);
        assert_eq!(record.raw_status.as_deref(), Some("oom"));
        // We only extract exit_code on Died records — oom is a separate
        // observation; the Died event that follows will carry the code.
        assert_eq!(record.exit_code, None);
    }

    #[test]
    fn parse_cleanup_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "cleanup");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopped);
    }

    #[test]
    fn parse_remove_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "remove");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopped);
    }

    #[test]
    fn parse_stop_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "stop");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopping);
    }

    #[test]
    fn parse_kill_event() {
        let json = podman_event_json("tillandsias-tetris-aeranthos", "kill");
        let event = parse_podman_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopping);
    }

    #[test]
    fn prefix_filter_rejects_non_matching() {
        let json = podman_event_json("other-container", "start");
        assert!(parse_podman_event(&json, "tillandsias-").is_none());
    }

    #[test]
    fn prefix_filter_accepts_matching() {
        let json = podman_event_json("tillandsias-foo-bar", "start");
        assert!(parse_podman_event(&json, "tillandsias-").is_some());
    }

    #[test]
    fn malformed_json_returns_none() {
        assert!(parse_podman_event("not json at all", "tillandsias-").is_none());
        assert!(parse_podman_event("{}", "tillandsias-").is_none());
        assert!(parse_podman_event("", "tillandsias-").is_none());
    }

    #[test]
    fn docker_format_json_returns_none() {
        // Docker-format events should NOT parse -- we only support Podman format
        let docker_json = r#"{"Actor":{"Attributes":{"name":"tillandsias-x-y"}},"Action":"die"}"#;
        assert!(parse_podman_event(docker_json, "tillandsias-").is_none());
    }

    #[test]
    fn unknown_status_returns_none() {
        let json = podman_event_json("tillandsias-foo-bar", "attach");
        assert!(parse_podman_event(&json, "tillandsias-").is_none());
    }

    /// Helper: build a WSL-format JSON event line.
    #[cfg(target_os = "windows")]
    fn wsl_event_json(name: &str, state: &str) -> String {
        format!(r#"{{"container":"{name}","state":"{state}"}}"#)
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn parse_wsl_running_event() {
        let json = wsl_event_json("tillandsias-tetris-aeranthos", "Running");
        let event = parse_wsl_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.container_name, "tillandsias-tetris-aeranthos");
        assert_eq!(event.new_state, ContainerState::Running);
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn parse_wsl_creating_event() {
        let json = wsl_event_json("tillandsias-myapp-ionantha", "Creating");
        let event = parse_wsl_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Creating);
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn parse_wsl_stopping_event() {
        let json = wsl_event_json("tillandsias-tetris-aeranthos", "Stopping");
        let event = parse_wsl_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopping);
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn parse_wsl_stopped_event() {
        let json = wsl_event_json("tillandsias-tetris-aeranthos", "Stopped");
        let event = parse_wsl_event(&json, "tillandsias-").unwrap();
        assert_eq!(event.new_state, ContainerState::Stopped);
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn wsl_prefix_filter_rejects_non_matching() {
        let json = wsl_event_json("other-container", "Running");
        assert!(parse_wsl_event(&json, "tillandsias-").is_none());
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn wsl_prefix_filter_accepts_matching() {
        let json = wsl_event_json("tillandsias-foo-bar", "Running");
        assert!(parse_wsl_event(&json, "tillandsias-").is_some());
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn wsl_malformed_json_returns_none() {
        assert!(parse_wsl_event("not json at all", "tillandsias-").is_none());
        assert!(parse_wsl_event("{}", "tillandsias-").is_none());
        assert!(parse_wsl_event("", "tillandsias-").is_none());
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn wsl_unknown_state_returns_none() {
        let json = wsl_event_json("tillandsias-foo-bar", "Unknown");
        assert!(parse_wsl_event(&json, "tillandsias-").is_none());
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn wsl_lowercase_state_returns_none() {
        // WSL uses uppercase state strings; lowercase should not parse
        let json = wsl_event_json("tillandsias-foo-bar", "running");
        assert!(parse_wsl_event(&json, "tillandsias-").is_none());
    }

    /// Compile-pinning for `PodmanEventStream::stream_records`. The
    /// records-sink path takes `mpsc::Sender<ContainerLifecycleRecord>`
    /// (lossless — carries exit_code, action, source) rather than the
    /// `PodmanEvent` sink that `stream` uses. We can't exercise the live
    /// `podman events` subprocess in unit tests, but we CAN prove the
    /// public surface stays compatible with the typed channel by
    /// constructing it and dropping it without calling `.await`.
    ///
    /// If a future refactor narrows `stream_records` to a non-record
    /// sink type, this test fails at compile time — which is exactly
    /// the drift signal the gap-2/3 phase-2 wiring slice needs.
    #[test]
    fn stream_records_accepts_lifecycle_record_channel() {
        let (tx, _rx) = mpsc::channel::<ContainerLifecycleRecord>(1);
        let stream = PodmanEventStream::new("tillandsias-");
        // Coerce to the typed sender to verify signature; never await.
        let _fut: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> =
            Box::pin(stream.stream_records(tx));
    }
}
