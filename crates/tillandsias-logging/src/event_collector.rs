// @trace spec:runtime-logging, gap:OBS-021, gap:OBS-022
//! Structured event collection for observability gaps OBS-021 and OBS-022.
//!
//! Collects and logs:
//! - OBS-021: Secret rotation events (actor, resource, status, no secret values)
//! - OBS-022: Image build events (duration, status, builder)
//!
//! All events are JSON-serialized with timestamp, metadata, and no PII/secrets.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;

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
}
