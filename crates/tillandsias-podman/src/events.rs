use std::time::Duration;

use tokio::process::Command;
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
    /// Uses `podman events --format json` as primary source.
    /// Falls back to exponential backoff inspection when events fail.
    pub async fn stream(self, tx: mpsc::Sender<PodmanEvent>) {
        loop {
            info!("Starting podman events listener");

            // Try event-driven approach first
            match self.stream_events(&tx).await {
                Ok(()) => break, // Clean shutdown
                Err(e) => {
                    warn!(?e, "Podman events stream failed, falling back to backoff inspection");
                    // Fall back to exponential backoff
                    if self.backoff_inspect(&tx).await.is_err() {
                        break; // Channel closed
                    }
                }
            }
        }
    }

    /// Primary: stream `podman events --format json`.
    async fn stream_events(
        &self,
        tx: &mpsc::Sender<PodmanEvent>,
    ) -> Result<(), PodmanEventError> {
        let mut child = Command::new("podman")
            .args([
                "events",
                "--format",
                "json",
                "--filter",
                &format!("container={}*", self.prefix),
            ])
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
                    return Err(PodmanEventError::StreamEnded);
                }
                Ok(_) => {
                    if let Some(event) = parse_podman_event(&line, &self.prefix) {
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

    /// Fallback: exponential backoff inspection.
    /// Starts at 1s, doubles to 30s max. NEVER fixed-interval polling.
    async fn backoff_inspect(
        &self,
        tx: &mpsc::Sender<PodmanEvent>,
    ) -> Result<(), ()> {
        let mut interval = Duration::from_secs(1);
        let max_interval = Duration::from_secs(30);

        loop {
            tokio::time::sleep(interval).await;

            // Try to reconnect to events first
            if Command::new("podman")
                .args(["events", "--help"])
                .output()
                .await
                .is_ok_and(|o| o.status.success())
            {
                debug!("Podman events available again, switching back");
                return Ok(()); // Will restart stream_events in outer loop
            }

            // Inspect containers as fallback
            let output = Command::new("podman")
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

            if let Ok(o) = output {
                if o.status.success() {
                    let stdout = String::from_utf8_lossy(&o.stdout);
                    if let Ok(entries) =
                        serde_json::from_str::<Vec<serde_json::Value>>(&stdout)
                    {
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
                }
            }

            // Exponential backoff (never fixed-interval)
            interval = (interval * 2).min(max_interval);
        }
    }
}

/// Parse a JSON event line from `podman events --format json`.
fn parse_podman_event(json_line: &str, prefix: &str) -> Option<PodmanEvent> {
    let value: serde_json::Value = serde_json::from_str(json_line.trim()).ok()?;

    let name = value["Actor"]["Attributes"]["name"].as_str()?;
    if !name.starts_with(prefix) {
        return None;
    }

    let action = value["Action"].as_str()?;
    let new_state = match action {
        "start" => ContainerState::Running,
        "create" => ContainerState::Creating,
        "stop" | "kill" => ContainerState::Stopping,
        "die" | "remove" => ContainerState::Stopped,
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
