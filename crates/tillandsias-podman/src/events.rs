// @trace spec:podman-orchestration, spec:cross-platform, spec:wsl-daemon-orchestration

use std::collections::HashSet;
use std::time::Duration;

use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use tillandsias_core::event::ContainerState;

/// Event from podman events stream.
#[derive(Debug, Clone)]
pub struct PodmanEvent {
    pub container_name: String,
    pub new_state: ContainerState,
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

    /// Primary (Linux): stream `podman events --format json`.
    ///
    /// No container name filter on the command -- podman's `--filter container=`
    /// takes exact names, not globs. We filter by prefix in `parse_podman_event()`.
    // @trace spec:podman-orchestration
    #[cfg(not(target_os = "windows"))]
    async fn stream_events(&self, tx: &mpsc::Sender<PodmanEvent>) -> Result<(), PodmanEventError> {
        debug!(prefix = %self.prefix, "Starting podman events stream (no name filter, prefix matched in-process)");

        let mut child = crate::podman_cmd()
            .args(["events", "--format", "json", "--filter", "type=container"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
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
                    if let Some(event) = parse_podman_event(&line, &self.prefix) {
                        debug!(
                            container = %event.container_name,
                            state = ?event.new_state,
                            "Dispatching parsed container event"
                        );
                        if tx.send(event).await.is_err() {
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
    async fn stream_events_wsl(
        &self,
        tx: &mpsc::Sender<PodmanEvent>,
    ) -> Result<(), PodmanEventError> {
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
                    if let Some(event) = parse_wsl_event(&line, &self.prefix) {
                        debug!(
                            container = %event.container_name,
                            state = ?event.new_state,
                            "Dispatching parsed container event from WSL"
                        );
                        if tx.send(event).await.is_err() {
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
    async fn backoff_inspect(&self, tx: &mpsc::Sender<PodmanEvent>) -> Result<(), ()> {
        let mut interval = Duration::from_secs(1);
        let max_interval = Duration::from_secs(30);
        let mut known_running: HashSet<String> = HashSet::new();

        debug!("Fallback backoff inspection activated");

        loop {
            tokio::time::sleep(interval).await;

            // Try to reconnect — `podman info` actually connects to the podman
            // service, unlike `--help` which succeeds even when the machine is down.
            if crate::podman_cmd()
                .args(["info", "--format", "json"])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .output()
                .await
                .is_ok_and(|o| o.status.success())
            {
                info!("Podman service available again, switching to event stream");
                return Ok(()); // Will restart stream_events in outer loop
            }

            // Inspect containers as fallback
            let output = crate::podman_cmd()
                .args([
                    "ps",
                    "-a",
                    "--filter",
                    &format!("name=^{}", self.prefix),
                    "--format",
                    "json",
                ])
                .output()
                .await;

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

                            let event = PodmanEvent {
                                container_name: name.to_string(),
                                new_state,
                            };

                            if tx.send(event).await.is_err() {
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
                    let event = PodmanEvent {
                        container_name: vanished.clone(),
                        new_state: ContainerState::Stopped,
                    };
                    if tx.send(event).await.is_err() {
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
fn parse_podman_event(json_line: &str, prefix: &str) -> Option<PodmanEvent> {
    let value: serde_json::Value = serde_json::from_str(json_line.trim()).ok()?;

    let name = value["Name"].as_str()?;
    if !name.starts_with(prefix) {
        return None;
    }

    let action = value["Status"].as_str()?;
    let new_state = match action {
        "start" => ContainerState::Running,
        "create" => ContainerState::Creating,
        "stop" | "kill" => ContainerState::Stopping,
        "died" | "remove" | "cleanup" => ContainerState::Stopped,
        _ => return None,
    };

    Some(PodmanEvent {
        container_name: name.to_string(),
        new_state,
    })
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
#[cfg(target_os = "windows")]
fn parse_wsl_event(json_line: &str, prefix: &str) -> Option<PodmanEvent> {
    let value: serde_json::Value = serde_json::from_str(json_line.trim()).ok()?;

    let name = value["container"].as_str()?;
    if !name.starts_with(prefix) {
        return None;
    }

    let state_str = value["state"].as_str()?;
    let new_state = match state_str {
        "Running" => ContainerState::Running,
        "Creating" => ContainerState::Creating,
        "Stopping" => ContainerState::Stopping,
        "Stopped" => ContainerState::Stopped,
        _ => return None,
    };

    Some(PodmanEvent {
        container_name: name.to_string(),
        new_state,
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
}
