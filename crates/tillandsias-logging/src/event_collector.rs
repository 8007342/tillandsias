// @trace spec:runtime-logging, gap:OBS-021, gap:OBS-022, spec:windows-event-logging
//! Structured event collection for observability gaps OBS-021 and OBS-022.
//!
//! Collects and logs:
//! - OBS-021: Secret rotation events (actor, resource, status, no secret values)
//! - OBS-022: Image build events (duration, status, builder)
//!
//! All events are JSON-serialized with timestamp, metadata, and no PII/secrets.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[cfg(test)]
use serde_json::json;

/// Base event metadata common to all events.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventMetadata {
    /// RFC3339 timestamp when event occurred
    pub timestamp: DateTime<Utc>,

    /// Event type (e.g., "secret.rotated", "image.built")
    pub event_type: String,

    /// Component/actor that triggered the event
    pub actor: String,

    /// Additional context fields (never contains secrets or PII)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<HashMap<String, Value>>,

    /// OpenSpec spec trace link
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spec_trace: Option<String>,
}

/// Secret rotation event (OBS-021).
///
/// Logged when a secret is rotated, refreshed, or provisioned.
/// NEVER includes actual secret values.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SecretRotationEvent {
    /// Base event metadata
    #[serde(flatten)]
    pub metadata: EventMetadata,

    /// Secret identifier (e.g., "github-token", "ca-cert")
    pub secret_name: String,

    /// Actor performing the rotation
    pub actor: String,

    /// Rotation status: "success" or "failure"
    pub rotation_status: String,

    /// Reason for rotation (e.g., "expiry", "manual", "refresh_threshold")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,

    /// Error details if rotation failed
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl SecretRotationEvent {
    /// Create a new secret rotation event.
    pub fn new(
        secret_name: impl Into<String>,
        actor: impl Into<String>,
        status: impl Into<String>,
    ) -> Self {
        let actor_str = actor.into();
        Self {
            metadata: EventMetadata {
                timestamp: Utc::now(),
                event_type: "secret.rotated".to_string(),
                actor: actor_str.clone(),
                context: None,
                spec_trace: Some("spec:secret-rotation".to_string()),
            },
            secret_name: secret_name.into(),
            actor: actor_str,
            rotation_status: status.into(),
            reason: None,
            error: None,
        }
    }

    /// Add rotation reason
    pub fn with_reason(mut self, reason: impl Into<String>) -> Self {
        self.reason = Some(reason.into());
        self
    }

    /// Add error details if rotation failed
    pub fn with_error(mut self, error: impl Into<String>) -> Self {
        self.error = Some(error.into());
        self
    }

    /// Add context field
    pub fn with_context(mut self, key: impl Into<String>, value: Value) -> Self {
        self.metadata
            .context
            .get_or_insert_with(HashMap::new)
            .insert(key.into(), value);
        self
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Image build event (OBS-022).
///
/// Logged when a container image is built.
/// Includes duration, status, builder type.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ImageBuildEvent {
    /// Base event metadata
    #[serde(flatten)]
    pub metadata: EventMetadata,

    /// Image name (e.g., "tillandsias-forge")
    pub image_name: String,

    /// Full image tag (e.g., "tillandsias-forge:v1.2.3")
    pub image_tag: String,

    /// Build duration in seconds
    pub build_duration_seconds: f64,

    /// Build status: "success", "skipped", or "failure"
    pub build_status: String,

    /// Builder implementation (e.g., "nix-build", "podman-build")
    pub builder: String,

    /// Image size in bytes (0 if unknown or skipped)
    #[serde(skip_serializing_if = "is_zero")]
    pub image_size_bytes: u64,

    /// Error details if build failed
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Helper to skip zero-valued size fields in JSON
fn is_zero(v: &u64) -> bool {
    *v == 0
}

impl ImageBuildEvent {
    /// Create a new image build event.
    pub fn new(
        image_name: impl Into<String>,
        image_tag: impl Into<String>,
        duration_seconds: f64,
        status: impl Into<String>,
        builder: impl Into<String>,
    ) -> Self {
        let builder_str = builder.into();
        Self {
            metadata: EventMetadata {
                timestamp: Utc::now(),
                event_type: "image.built".to_string(),
                actor: builder_str.clone(),
                context: None,
                spec_trace: Some("spec:image-builder".to_string()),
            },
            image_name: image_name.into(),
            image_tag: image_tag.into(),
            build_duration_seconds: duration_seconds,
            build_status: status.into(),
            builder: builder_str,
            image_size_bytes: 0,
            error: None,
        }
    }

    /// Set image size in bytes
    pub fn with_size(mut self, bytes: u64) -> Self {
        self.image_size_bytes = bytes;
        self
    }

    /// Add error details if build failed
    pub fn with_error(mut self, error: impl Into<String>) -> Self {
        self.error = Some(error.into());
        self
    }

    /// Add context field
    pub fn with_context(mut self, key: impl Into<String>, value: Value) -> Self {
        self.metadata
            .context
            .get_or_insert_with(HashMap::new)
            .insert(key.into(), value);
        self
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Tray window lifecycle event (OBS-021 enhancement).
///
/// Logged when tray windows change state: created, attached, state changed, detached.
/// Used for tracking tray UI responsiveness and user interaction patterns.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TrayWindowLifecycleEvent {
    /// Base event metadata
    #[serde(flatten)]
    pub metadata: EventMetadata,

    /// Window ID or identifier (e.g., "project1-settings", "logs-viewer")
    pub window_id: String,

    /// Project identifier if window is project-specific
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,

    /// Lifecycle event type: "created", "attached", "state_changed", "detached"
    pub event_kind: String,

    /// Previous state (if applicable)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_state: Option<String>,

    /// New state or current state
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_state: Option<String>,

    /// Genus name if applicable (e.g., "aeranthos")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub genus: Option<String>,
}

impl TrayWindowLifecycleEvent {
    /// Create a new tray window lifecycle event.
    pub fn new(window_id: impl Into<String>, event_kind: impl Into<String>) -> Self {
        Self {
            metadata: EventMetadata {
                timestamp: Utc::now(),
                event_type: "tray.window_lifecycle".to_string(),
                actor: "tillandsias-tray".to_string(),
                context: None,
                spec_trace: Some("spec:tray-window-lifecycle".to_string()),
            },
            window_id: window_id.into(),
            project_id: None,
            event_kind: event_kind.into(),
            old_state: None,
            new_state: None,
            genus: None,
        }
    }

    /// Set project ID
    pub fn with_project(mut self, project_id: impl Into<String>) -> Self {
        self.project_id = Some(project_id.into());
        self
    }

    /// Set state transition (old -> new)
    pub fn with_state_transition(
        mut self,
        old_state: impl Into<String>,
        new_state: impl Into<String>,
    ) -> Self {
        self.old_state = Some(old_state.into());
        self.new_state = Some(new_state.into());
        self
    }

    /// Set genus name
    pub fn with_genus(mut self, genus: impl Into<String>) -> Self {
        self.genus = Some(genus.into());
        self
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Container metrics event (OBS-022 enhancement).
///
/// Logged when sampling container resource metrics: CPU, memory, I/O.
/// Used for performance analysis and resource bottleneck detection.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ContainerMetricsEvent {
    /// Base event metadata
    #[serde(flatten)]
    pub metadata: EventMetadata,

    /// Container ID (full podman container ID hash)
    pub container_id: String,

    /// Container name (e.g., "tillandsias-my-project-aeranthos")
    pub container_name: String,

    /// Memory usage in bytes
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_bytes: Option<u64>,

    /// Memory limit in bytes (cgroup limit)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_limit_bytes: Option<u64>,

    /// CPU usage percentage (0.0 to 100+ for multi-core)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_percent: Option<f64>,

    /// CPU count (number of cores)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cpu_count: Option<u32>,

    /// I/O read bytes per second
    #[serde(skip_serializing_if = "Option::is_none")]
    pub io_read_bytes_per_sec: Option<f64>,

    /// I/O write bytes per second
    #[serde(skip_serializing_if = "Option::is_none")]
    pub io_write_bytes_per_sec: Option<f64>,

    /// Network bytes received
    #[serde(skip_serializing_if = "Option::is_none")]
    pub net_rx_bytes: Option<u64>,

    /// Network bytes transmitted
    #[serde(skip_serializing_if = "Option::is_none")]
    pub net_tx_bytes: Option<u64>,

    /// Wall-clock time taken for metric collection (ms)
    pub wall_clock_ms: u64,
}

impl ContainerMetricsEvent {
    /// Create a new container metrics event.
    pub fn new(
        container_id: impl Into<String>,
        container_name: impl Into<String>,
        wall_clock_ms: u64,
    ) -> Self {
        Self {
            metadata: EventMetadata {
                timestamp: Utc::now(),
                event_type: "container.metrics".to_string(),
                actor: "tillandsias-metrics".to_string(),
                context: None,
                spec_trace: Some("spec:resource-metric-collection".to_string()),
            },
            container_id: container_id.into(),
            container_name: container_name.into(),
            memory_bytes: None,
            memory_limit_bytes: None,
            cpu_percent: None,
            cpu_count: None,
            io_read_bytes_per_sec: None,
            io_write_bytes_per_sec: None,
            net_rx_bytes: None,
            net_tx_bytes: None,
            wall_clock_ms,
        }
    }

    /// Set memory metrics
    pub fn with_memory(mut self, used_bytes: u64, limit_bytes: u64) -> Self {
        self.memory_bytes = Some(used_bytes);
        self.memory_limit_bytes = Some(limit_bytes);
        self
    }

    /// Set CPU metrics
    pub fn with_cpu(mut self, cpu_percent: f64, cpu_count: u32) -> Self {
        self.cpu_percent = Some(cpu_percent);
        self.cpu_count = Some(cpu_count);
        self
    }

    /// Set I/O metrics
    pub fn with_io(mut self, read_bytes_per_sec: f64, write_bytes_per_sec: f64) -> Self {
        self.io_read_bytes_per_sec = Some(read_bytes_per_sec);
        self.io_write_bytes_per_sec = Some(write_bytes_per_sec);
        self
    }

    /// Set network metrics
    pub fn with_network(mut self, rx_bytes: u64, tx_bytes: u64) -> Self {
        self.net_rx_bytes = Some(rx_bytes);
        self.net_tx_bytes = Some(tx_bytes);
        self
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }
}

/// Event collector for structured audit logging.
///
/// Collects and validates events, ensuring no secrets or PII leak into logs.
pub struct EventCollector;

impl EventCollector {
    /// Log a secret rotation event.
    ///
    /// # Arguments
    /// * `event` - SecretRotationEvent to log
    ///
    /// # Returns
    /// JSON string of the event, or error if serialization fails
    pub fn log_secret_rotation(event: &SecretRotationEvent) -> serde_json::Result<String> {
        event.to_json()
    }

    /// Log an image build event.
    ///
    /// # Arguments
    /// * `event` - ImageBuildEvent to log
    ///
    /// # Returns
    /// JSON string of the event, or error if serialization fails
    pub fn log_image_build(event: &ImageBuildEvent) -> serde_json::Result<String> {
        event.to_json()
    }

    /// Log a tray window lifecycle event.
    ///
    /// # Arguments
    /// * `event` - TrayWindowLifecycleEvent to log
    ///
    /// # Returns
    /// JSON string of the event, or error if serialization fails
    pub fn log_window_lifecycle(event: &TrayWindowLifecycleEvent) -> serde_json::Result<String> {
        event.to_json()
    }

    /// Log a container metrics event.
    ///
    /// # Arguments
    /// * `event` - ContainerMetricsEvent to log
    ///
    /// # Returns
    /// JSON string of the event, or error if serialization fails
    pub fn log_container_metrics(event: &ContainerMetricsEvent) -> serde_json::Result<String> {
        event.to_json()
    }

    /// Validate that an event contains no secret values.
    ///
    /// Checks serialized JSON for common secret patterns.
    ///
    /// # Arguments
    /// * `json_str` - Serialized event JSON
    ///
    /// # Returns
    /// true if no secret patterns detected, false otherwise
    pub fn validate_no_secrets(json_str: &str) -> bool {
        let forbidden_patterns = [
            "secret_value",
            "token_value",
            "password",
            "private_key",
            "ghp_",
            "ghu_",
            "ghs_",
            "ghr_",
        ];

        for pattern in &forbidden_patterns {
            if json_str.contains(pattern) {
                return false;
            }
        }

        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_secret_rotation_event_creation() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success");

        assert_eq!(event.secret_name, "github-token");
        assert_eq!(event.actor, "tillandsias-headless");
        assert_eq!(event.rotation_status, "success");
        assert_eq!(event.metadata.event_type, "secret.rotated");
    }

    #[test]
    fn test_secret_rotation_with_reason() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success")
            .with_reason("expiry");

        assert_eq!(event.reason, Some("expiry".to_string()));
    }

    #[test]
    fn test_secret_rotation_with_error() {
        let event = SecretRotationEvent::new("ca-cert", "tillandsias-headless", "failure")
            .with_error("keyring access denied");

        assert_eq!(event.rotation_status, "failure");
        assert_eq!(event.error, Some("keyring access denied".to_string()));
    }

    #[test]
    fn test_secret_rotation_with_context() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success")
            .with_context("retry_count", json!(3))
            .with_context("duration_ms", json!(150));

        let ctx = event.metadata.context.unwrap();
        assert_eq!(ctx.get("retry_count"), Some(&json!(3)));
        assert_eq!(ctx.get("duration_ms"), Some(&json!(150)));
    }

    #[test]
    fn test_secret_rotation_json_serialization() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success")
            .with_reason("refresh_threshold");

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["secret_name"], "github-token");
        assert_eq!(parsed["actor"], "tillandsias-headless");
        assert_eq!(parsed["rotation_status"], "success");
        assert_eq!(parsed["reason"], "refresh_threshold");
        assert_eq!(parsed["event_type"], "secret.rotated");
    }

    #[test]
    fn test_secret_rotation_no_secret_values_in_json() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success");
        let json = event.to_json().unwrap();

        // Verify no actual token value appears anywhere
        assert!(!json.contains("ghp_"));
        assert!(!json.contains("ghu_"));
        assert!(!json.contains("ghs_"));
        assert!(!json.contains("ghr_"));
        assert!(!json.contains("secret_value"));
    }

    #[test]
    fn test_image_build_event_creation() {
        let event = ImageBuildEvent::new(
            "tillandsias-forge",
            "tillandsias-forge:v1.2.3",
            42.5,
            "success",
            "nix-build",
        );

        assert_eq!(event.image_name, "tillandsias-forge");
        assert_eq!(event.image_tag, "tillandsias-forge:v1.2.3");
        assert_eq!(event.build_duration_seconds, 42.5);
        assert_eq!(event.build_status, "success");
        assert_eq!(event.builder, "nix-build");
        assert_eq!(event.metadata.event_type, "image.built");
    }

    #[test]
    fn test_image_build_with_size() {
        let event = ImageBuildEvent::new(
            "tillandsias-proxy",
            "tillandsias-proxy:v1.2.3",
            15.0,
            "success",
            "nix-build",
        )
        .with_size(1024 * 1024 * 512); // 512 MB

        assert_eq!(event.image_size_bytes, 512 * 1024 * 1024);
    }

    #[test]
    fn test_image_build_with_error() {
        let event = ImageBuildEvent::new(
            "tillandsias-inference",
            "tillandsias-inference:v1.2.3",
            0.0,
            "failure",
            "nix-build",
        )
        .with_error("nix build failed: missing dependency");

        assert_eq!(event.build_status, "failure");
        assert_eq!(
            event.error,
            Some("nix build failed: missing dependency".to_string())
        );
    }

    #[test]
    fn test_image_build_with_context() {
        let event = ImageBuildEvent::new(
            "tillandsias-forge",
            "tillandsias-forge:v1.2.3",
            120.5,
            "success",
            "nix-build",
        )
        .with_context("cache_hit", json!(true))
        .with_context("layer_count", json!(15));

        let ctx = event.metadata.context.unwrap();
        assert_eq!(ctx.get("cache_hit"), Some(&json!(true)));
        assert_eq!(ctx.get("layer_count"), Some(&json!(15)));
    }

    #[test]
    fn test_image_build_json_serialization() {
        let event = ImageBuildEvent::new(
            "tillandsias-git",
            "tillandsias-git:v1.2.3",
            25.5,
            "success",
            "nix-build",
        )
        .with_size(256 * 1024 * 1024);

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["image_name"], "tillandsias-git");
        assert_eq!(parsed["image_tag"], "tillandsias-git:v1.2.3");
        assert_eq!(parsed["build_duration_seconds"], 25.5);
        assert_eq!(parsed["build_status"], "success");
        assert_eq!(parsed["builder"], "nix-build");
        assert_eq!(parsed["image_size_bytes"], 256 * 1024 * 1024);
        assert_eq!(parsed["event_type"], "image.built");
    }

    #[test]
    fn test_event_collector_validate_no_secrets_success() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success");
        let json = event.to_json().unwrap();

        assert!(EventCollector::validate_no_secrets(&json));
    }

    #[test]
    fn test_event_collector_validate_no_secrets_failure() {
        // Manually construct JSON with a secret pattern (simulating a bug)
        let bad_json = r#"{"secret_name":"github-token","ghp_secret_value":"abc123"}"#;

        assert!(!EventCollector::validate_no_secrets(bad_json));
    }

    #[test]
    fn test_image_build_size_zero_omitted_from_json() {
        let event = ImageBuildEvent::new(
            "tillandsias-forge",
            "tillandsias-forge:v1.2.3",
            42.5,
            "skipped",
            "nix-build",
        );

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // image_size_bytes should not be present when 0
        assert!(parsed.get("image_size_bytes").is_none());
    }

    #[test]
    fn test_secret_rotation_error_omitted_when_none() {
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success");

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // error should not be present when None
        assert!(parsed.get("error").is_none());
    }

    #[test]
    fn test_secret_rotation_timestamp_present() {
        let before = Utc::now();
        let event = SecretRotationEvent::new("github-token", "tillandsias-headless", "success");
        let after = Utc::now();

        // Verify timestamp is within expected window
        assert!(event.metadata.timestamp >= before);
        assert!(event.metadata.timestamp <= after);
    }

    #[test]
    fn test_image_build_timestamp_present() {
        let before = Utc::now();
        let event = ImageBuildEvent::new(
            "tillandsias-forge",
            "tillandsias-forge:v1.2.3",
            42.5,
            "success",
            "nix-build",
        );
        let after = Utc::now();

        // Verify timestamp is within expected window
        assert!(event.metadata.timestamp >= before);
        assert!(event.metadata.timestamp <= after);
    }

    #[test]
    fn test_multiple_secret_rotation_events() {
        let events = vec![
            SecretRotationEvent::new("github-token", "tillandsias-headless", "success"),
            SecretRotationEvent::new("ca-cert", "tillandsias-git", "success"),
            SecretRotationEvent::new("ca-key", "tillandsias-proxy", "failure")
                .with_error("file permissions denied"),
        ];

        for event in events {
            let json = event.to_json().unwrap();
            assert!(EventCollector::validate_no_secrets(&json));
        }
    }

    #[test]
    fn test_multiple_image_build_events() {
        let events = vec![
            ImageBuildEvent::new(
                "tillandsias-forge",
                "tillandsias-forge:v1.2.3",
                120.0,
                "success",
                "nix-build",
            ),
            ImageBuildEvent::new(
                "tillandsias-proxy",
                "tillandsias-proxy:v1.2.3",
                45.0,
                "success",
                "nix-build",
            ),
            ImageBuildEvent::new(
                "tillandsias-inference",
                "tillandsias-inference:v1.2.3",
                0.0,
                "failure",
                "nix-build",
            )
            .with_error("dependency resolution failed"),
        ];

        for event in events {
            let json = event.to_json().unwrap();
            assert!(!json.is_empty());
        }
    }

    // OBS-021: Tray window lifecycle events
    #[test]
    fn test_tray_window_lifecycle_event_creation() {
        let event = TrayWindowLifecycleEvent::new("project1-settings", "created");

        assert_eq!(event.window_id, "project1-settings");
        assert_eq!(event.event_kind, "created");
        assert_eq!(event.metadata.event_type, "tray.window_lifecycle");
        assert_eq!(event.metadata.actor, "tillandsias-tray");
    }

    #[test]
    fn test_tray_window_lifecycle_with_project() {
        let event = TrayWindowLifecycleEvent::new("logs-viewer", "attached").with_project("my-app");

        assert_eq!(event.project_id, Some("my-app".to_string()));
    }

    #[test]
    fn test_tray_window_lifecycle_with_state_transition() {
        let event = TrayWindowLifecycleEvent::new("project1-window", "state_changed")
            .with_state_transition("minimized", "maximized");

        assert_eq!(event.old_state, Some("minimized".to_string()));
        assert_eq!(event.new_state, Some("maximized".to_string()));
    }

    #[test]
    fn test_tray_window_lifecycle_with_genus() {
        let event =
            TrayWindowLifecycleEvent::new("project1-env", "created").with_genus("aeranthos");

        assert_eq!(event.genus, Some("aeranthos".to_string()));
    }

    #[test]
    fn test_tray_window_lifecycle_full_event() {
        let event = TrayWindowLifecycleEvent::new("project1-forge", "created")
            .with_project("my-app")
            .with_genus("caput-medusae")
            .with_state_transition("initializing", "ready");

        assert_eq!(event.window_id, "project1-forge");
        assert_eq!(event.event_kind, "created");
        assert_eq!(event.project_id, Some("my-app".to_string()));
        assert_eq!(event.genus, Some("caput-medusae".to_string()));
        assert_eq!(event.old_state, Some("initializing".to_string()));
        assert_eq!(event.new_state, Some("ready".to_string()));
    }

    #[test]
    fn test_tray_window_lifecycle_json_serialization() {
        let event = TrayWindowLifecycleEvent::new("settings-dialog", "created")
            .with_project("project-a")
            .with_genus("aeranthos");

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["window_id"], "settings-dialog");
        assert_eq!(parsed["event_kind"], "created");
        assert_eq!(parsed["project_id"], "project-a");
        assert_eq!(parsed["genus"], "aeranthos");
        assert_eq!(parsed["event_type"], "tray.window_lifecycle");
    }

    #[test]
    fn test_tray_window_lifecycle_states() {
        let event_kinds = vec!["created", "attached", "state_changed", "detached"];

        for kind in event_kinds {
            let event = TrayWindowLifecycleEvent::new("test-window", kind);
            assert_eq!(event.event_kind, kind);
            let json = event.to_json().unwrap();
            assert!(!json.is_empty());
        }
    }

    // OBS-022: Container metrics events
    #[test]
    fn test_container_metrics_event_creation() {
        let event =
            ContainerMetricsEvent::new("abc123def456", "tillandsias-my-project-aeranthos", 42);

        assert_eq!(event.container_id, "abc123def456");
        assert_eq!(event.container_name, "tillandsias-my-project-aeranthos");
        assert_eq!(event.wall_clock_ms, 42);
        assert_eq!(event.metadata.event_type, "container.metrics");
        assert_eq!(event.metadata.actor, "tillandsias-metrics");
    }

    #[test]
    fn test_container_metrics_with_memory() {
        let event =
            ContainerMetricsEvent::new("container-id-1", "tillandsias-project-aeranthos", 25)
                .with_memory(512 * 1024 * 1024, 2048 * 1024 * 1024); // 512 MB / 2048 MB

        assert_eq!(event.memory_bytes, Some(512 * 1024 * 1024));
        assert_eq!(event.memory_limit_bytes, Some(2048 * 1024 * 1024));
    }

    #[test]
    fn test_container_metrics_with_cpu() {
        let event =
            ContainerMetricsEvent::new("container-id-2", "tillandsias-project-aeranthos", 30)
                .with_cpu(45.5, 4);

        assert_eq!(event.cpu_percent, Some(45.5));
        assert_eq!(event.cpu_count, Some(4));
    }

    #[test]
    fn test_container_metrics_with_io() {
        let event =
            ContainerMetricsEvent::new("container-id-3", "tillandsias-project-aeranthos", 20)
                .with_io(1024.0 * 1024.0, 512.0 * 1024.0); // 1 MB/s read, 512 KB/s write

        assert_eq!(event.io_read_bytes_per_sec, Some(1024.0 * 1024.0));
        assert_eq!(event.io_write_bytes_per_sec, Some(512.0 * 1024.0));
    }

    #[test]
    fn test_container_metrics_with_network() {
        let event =
            ContainerMetricsEvent::new("container-id-4", "tillandsias-project-aeranthos", 35)
                .with_network(10 * 1024 * 1024, 5 * 1024 * 1024); // 10 MB rx, 5 MB tx

        assert_eq!(event.net_rx_bytes, Some(10 * 1024 * 1024));
        assert_eq!(event.net_tx_bytes, Some(5 * 1024 * 1024));
    }

    #[test]
    fn test_container_metrics_full_event() {
        let event =
            ContainerMetricsEvent::new("full-container-id", "tillandsias-comprehensive-test", 55)
                .with_memory(768 * 1024 * 1024, 4096 * 1024 * 1024)
                .with_cpu(62.3, 8)
                .with_io(2048.0 * 1024.0, 1024.0 * 1024.0)
                .with_network(100 * 1024 * 1024, 50 * 1024 * 1024);

        assert_eq!(event.memory_bytes, Some(768 * 1024 * 1024));
        assert_eq!(event.memory_limit_bytes, Some(4096 * 1024 * 1024));
        assert_eq!(event.cpu_percent, Some(62.3));
        assert_eq!(event.cpu_count, Some(8));
        assert_eq!(event.io_read_bytes_per_sec, Some(2048.0 * 1024.0));
        assert_eq!(event.io_write_bytes_per_sec, Some(1024.0 * 1024.0));
        assert_eq!(event.net_rx_bytes, Some(100 * 1024 * 1024));
        assert_eq!(event.net_tx_bytes, Some(50 * 1024 * 1024));
        assert_eq!(event.wall_clock_ms, 55);
    }

    #[test]
    fn test_container_metrics_json_serialization() {
        let event = ContainerMetricsEvent::new("container-xyz", "tillandsias-test-project", 40)
            .with_memory(256 * 1024 * 1024, 1024 * 1024 * 1024)
            .with_cpu(25.0, 2);

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["container_id"], "container-xyz");
        assert_eq!(parsed["container_name"], "tillandsias-test-project");
        assert_eq!(parsed["wall_clock_ms"], 40);
        assert_eq!(parsed["memory_bytes"], 256 * 1024 * 1024);
        assert_eq!(parsed["cpu_percent"], 25.0);
        assert_eq!(parsed["event_type"], "container.metrics");
    }

    #[test]
    fn test_container_metrics_optional_fields_omitted() {
        let event = ContainerMetricsEvent::new("container-id", "tillandsias-project", 10);

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Optional fields should not appear when None
        assert!(parsed.get("memory_bytes").is_none());
        assert!(parsed.get("cpu_percent").is_none());
        assert!(parsed.get("io_read_bytes_per_sec").is_none());
        assert!(parsed.get("net_rx_bytes").is_none());
    }

    #[test]
    fn test_event_collector_log_window_lifecycle() {
        let event =
            TrayWindowLifecycleEvent::new("test-window", "created").with_project("test-project");

        let json = EventCollector::log_window_lifecycle(&event).unwrap();
        assert!(!json.is_empty());

        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["event_type"], "tray.window_lifecycle");
    }

    #[test]
    fn test_event_collector_log_container_metrics() {
        let event =
            ContainerMetricsEvent::new("container-1", "tillandsias-test", 50).with_cpu(30.0, 2);

        let json = EventCollector::log_container_metrics(&event).unwrap();
        assert!(!json.is_empty());

        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["event_type"], "container.metrics");
    }

    #[test]
    fn test_multiple_window_lifecycle_events() {
        let events = vec![
            TrayWindowLifecycleEvent::new("settings", "created"),
            TrayWindowLifecycleEvent::new("logs", "attached").with_project("proj1"),
            TrayWindowLifecycleEvent::new("status", "state_changed")
                .with_state_transition("minimized", "maximized"),
            TrayWindowLifecycleEvent::new("browser", "detached"),
        ];

        for event in events {
            let json = event.to_json().unwrap();
            assert!(!json.is_empty());
            assert!(EventCollector::log_window_lifecycle(&event).is_ok());
        }
    }

    #[test]
    fn test_multiple_container_metrics_events() {
        let containers = vec![
            ("container-1", "tillandsias-app1-aeranthos"),
            ("container-2", "tillandsias-app2-stricta"),
            ("container-3", "tillandsias-app3-ionantha"),
        ];

        for (id, name) in containers {
            let event = ContainerMetricsEvent::new(id, name, 25)
                .with_memory(512 * 1024 * 1024, 2048 * 1024 * 1024)
                .with_cpu(45.0, 4);

            let json = event.to_json().unwrap();
            assert!(!json.is_empty());
            assert!(EventCollector::log_container_metrics(&event).is_ok());
        }
    }

    #[test]
    fn test_tray_window_lifecycle_timestamp_present() {
        let before = Utc::now();
        let event = TrayWindowLifecycleEvent::new("window-1", "created");
        let after = Utc::now();

        assert!(event.metadata.timestamp >= before);
        assert!(event.metadata.timestamp <= after);
    }

    #[test]
    fn test_container_metrics_timestamp_present() {
        let before = Utc::now();
        let event = ContainerMetricsEvent::new("container-1", "tillandsias-test", 10);
        let after = Utc::now();

        assert!(event.metadata.timestamp >= before);
        assert!(event.metadata.timestamp <= after);
    }

    #[test]
    fn test_events_include_spec_traces() {
        let window_event = TrayWindowLifecycleEvent::new("w1", "created");
        let metrics_event = ContainerMetricsEvent::new("c1", "tillandsias-test", 10);

        assert_eq!(
            window_event.metadata.spec_trace,
            Some("spec:tray-window-lifecycle".to_string())
        );
        assert_eq!(
            metrics_event.metadata.spec_trace,
            Some("spec:resource-metric-collection".to_string())
        );
    }
}
