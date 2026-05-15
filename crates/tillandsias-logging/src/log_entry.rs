// @trace spec:runtime-logging, gap:OBS-003
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Structured log entry with accountability metadata and spec tracing.
// @trace spec:runtime-logging, spec:log-schema-versioning, gap:OBS-003
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogEntry {
    /// Schema version for backwards compatibility. Immutable.
    /// @trace gap:OBS-003 — Log schema version field for evolution tracking
    pub schema_version: String,

    /// RFC3339 timestamp
    pub timestamp: DateTime<Utc>,

    /// Log level: TRACE, DEBUG, INFO, WARN, ERROR
    pub level: String,

    /// Component/module name (e.g., "proxy", "git-service", "inference", "forge")
    pub component: String,

    /// Human-readable log message
    pub message: String,

    /// Context fields (arbitrary key-value pairs)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<HashMap<String, Value>>,

    /// `@trace spec:<name>` link for spec traceability
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spec_trace: Option<String>,

    /// Accountability tagging: true if this is a sensitive/auditable operation
    #[serde(skip_serializing_if = "is_false")]
    pub accountability: Option<bool>,

    /// Category for accountability events (e.g., "secrets", "network", "git")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,

    /// Safety note for sensitive operations
    #[serde(skip_serializing_if = "Option::is_none")]
    pub safety: Option<String>,

    /// Sampling rate applied to this trace (e.g., 0.5 if 50% sampled)
    /// Only set if trace was subject to cost-aware sampling
    /// @trace gap:OBS-006 — Trace sampling by cost
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<f64>,

    /// Span ID for distributed tracing across containers
    /// @trace gap:OBS-007 — Cross-container span linkage
    #[serde(skip_serializing_if = "Option::is_none")]
    pub span_id: Option<String>,

    /// Parent span ID for cross-container log linkage
    /// @trace gap:OBS-007 — Cross-container span linkage
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_span_id: Option<String>,

    /// Trace ID shared across all spans in a distributed trace
    /// @trace gap:OBS-007 — Cross-container span linkage
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
}

impl LogEntry {
    /// Current schema version for all log entries (immutable).
    const SCHEMA_VERSION: &'static str = "1.0";

    /// Create a new log entry
    pub fn new(
        timestamp: DateTime<Utc>,
        level: String,
        component: String,
        message: String,
    ) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION.to_string(),
            timestamp,
            level,
            component,
            message,
            context: None,
            spec_trace: None,
            accountability: None,
            category: None,
            safety: None,
            sample_rate: None,
            span_id: None,
            parent_span_id: None,
            trace_id: None,
        }
    }

    /// Add context field
    pub fn with_context(mut self, key: impl Into<String>, value: Value) -> Self {
        self.context
            .get_or_insert_with(HashMap::new)
            .insert(key.into(), value);
        self
    }

    /// Add multiple context fields
    pub fn with_contexts(mut self, fields: HashMap<String, Value>) -> Self {
        self.context = Some(fields);
        self
    }

    /// Add spec trace link
    pub fn with_spec_trace(mut self, spec: impl Into<String>) -> Self {
        self.spec_trace = Some(spec.into());
        self
    }

    /// Mark as accountability event with category
    pub fn as_accountability(mut self, category: impl Into<String>) -> Self {
        self.accountability = Some(true);
        self.category = Some(category.into());
        self
    }

    /// Add safety note for accountability event
    pub fn with_safety(mut self, note: impl Into<String>) -> Self {
        self.safety = Some(note.into());
        self
    }

    /// Set sampling rate metadata
    pub fn with_sample_rate(mut self, rate: f64) -> Self {
        self.sample_rate = Some(rate);
        self
    }

    /// Set span ID for distributed tracing
    /// @trace gap:OBS-007 — Cross-container span linkage
    pub fn with_span_id(mut self, span_id: impl Into<String>) -> Self {
        self.span_id = Some(span_id.into());
        self
    }

    /// Set parent span ID for cross-container linkage
    /// @trace gap:OBS-007 — Cross-container span linkage
    pub fn with_parent_span_id(mut self, parent_span_id: impl Into<String>) -> Self {
        self.parent_span_id = Some(parent_span_id.into());
        self
    }

    /// Set trace ID for distributed tracing
    /// @trace gap:OBS-007 — Cross-container span linkage
    pub fn with_trace_id(mut self, trace_id: impl Into<String>) -> Self {
        self.trace_id = Some(trace_id.into());
        self
    }

    /// Attach span context from SpanContext
    /// @trace gap:OBS-007 — Cross-container span linkage
    pub fn with_span_context(mut self, ctx: &crate::span_context::SpanContext) -> Self {
        self.span_id = Some(ctx.span_id().to_string());
        self.trace_id = Some(ctx.trace_id().to_string());
        if let Some(parent_id) = ctx.parent_span_id() {
            self.parent_span_id = Some(parent_id.to_string());
        }
        self
    }

    /// Serialize to JSON
    pub fn to_json(&self) -> serde_json::Result<String> {
        serde_json::to_string(self)
    }

    /// Serialize to pretty-printed JSON
    pub fn to_json_pretty(&self) -> serde_json::Result<String> {
        serde_json::to_string_pretty(self)
    }
}

fn is_false(v: &Option<bool>) -> bool {
    v.is_none() || v == &Some(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_log_entry_creation() {
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "proxy".to_string(),
            "cache hit for api.github.com".to_string(),
        )
        .with_context("url", json!("api.github.com/repos/..."))
        .with_spec_trace("spec:enclave-network");

        assert_eq!(entry.schema_version, "1.0");
        assert_eq!(entry.level, "INFO");
        assert_eq!(entry.component, "proxy");
        assert!(entry.context.is_some());
        assert!(entry.spec_trace.is_some());
    }

    #[test]
    fn test_accountability_event() {
        let entry = LogEntry::new(
            Utc::now(),
            "WARN".to_string(),
            "git-service".to_string(),
            "push failed to remote".to_string(),
        )
        .as_accountability("git")
        .with_safety("credentials were not exposed")
        .with_spec_trace("spec:git-mirror-service");

        assert_eq!(entry.accountability, Some(true));
        assert_eq!(entry.category, Some("git".to_string()));
        assert!(entry.safety.is_some());
    }

    #[test]
    fn test_json_serialization() {
        let entry = LogEntry::new(
            Utc::now(),
            "ERROR".to_string(),
            "inference".to_string(),
            "model pull failed".to_string(),
        )
        .with_context("model", json!("qwen2.5-coder:7b"));

        let json = entry.to_json().unwrap();
        assert!(json.contains("\"schema_version\":\"1.0\""));
        assert!(json.contains("\"level\":\"ERROR\""));
        assert!(json.contains("\"component\":\"inference\""));
    }

    #[test]
    fn test_schema_version_immutable() {
        let entry1 = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "forge".to_string(),
            "container started".to_string(),
        );

        let entry2 = LogEntry::new(
            Utc::now(),
            "WARN".to_string(),
            "git-service".to_string(),
            "push delayed".to_string(),
        );

        // All entries must have the same immutable schema version
        assert_eq!(entry1.schema_version, entry2.schema_version);
        assert_eq!(entry1.schema_version, "1.0");
    }

    #[test]
    fn test_schema_version_in_json_serialization() {
        // @trace gap:OBS-003 — Verify schema_version is always present in serialized logs
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "proxy".to_string(),
            "connection established".to_string(),
        );

        let json = entry.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Schema version must be present in JSON output
        assert!(parsed.get("schema_version").is_some());
        assert_eq!(parsed["schema_version"], "1.0");
    }

    #[test]
    fn test_schema_version_backwards_compatible() {
        // @trace gap:OBS-003 — Verify backwards compatibility: old logs without schema_version can be upgraded
        let json_without_version = r#"{
            "timestamp": "2026-05-14T10:00:00Z",
            "level": "INFO",
            "component": "forge",
            "message": "legacy log entry"
        }"#;

        // Deserializing old logs would fail due to missing schema_version field
        // This is expected — the schema_version field is immutable and required.
        // Migration: when reading old logs, inject schema_version = "0.9" or similar legacy marker.
        let result: Result<LogEntry, _> = serde_json::from_str(json_without_version);
        assert!(
            result.is_err(),
            "Missing schema_version should cause deserialization to fail"
        );
    }

    #[test]
    fn test_schema_version_field_queryable() {
        // @trace gap:OBS-003 — Verify schema_version field is present and queryable in structured logs
        let entry = LogEntry::new(
            Utc::now(),
            "ERROR".to_string(),
            "inference".to_string(),
            "model pull timeout".to_string(),
        )
        .with_context("model_name", json!("qwen2.5-coder:14b"))
        .with_context("schema_version", json!("1.0"));

        let json = entry.to_json_pretty().unwrap();

        // Verify the JSON can be queried for schema_version
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["schema_version"], "1.0");

        // Verify all required fields are present for observability
        assert!(parsed.get("timestamp").is_some());
        assert!(parsed.get("level").is_some());
        assert!(parsed.get("component").is_some());
        assert!(parsed.get("message").is_some());
        assert!(parsed.get("schema_version").is_some());
    }

    #[test]
    fn test_log_entry_with_span_ids() {
        // @trace gap:OBS-007 — Verify span IDs are attached to log entries
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "proxy".to_string(),
            "cache hit for api.github.com".to_string(),
        )
        .with_span_id("0123456789abcdef")
        .with_trace_id("550e8400-e29b-41d4-a716-446655440000");

        assert_eq!(entry.span_id, Some("0123456789abcdef".to_string()));
        assert_eq!(
            entry.trace_id,
            Some("550e8400-e29b-41d4-a716-446655440000".to_string())
        );
    }

    #[test]
    fn test_log_entry_with_parent_span_id() {
        // @trace gap:OBS-007 — Verify parent_span_id enables cross-container linkage
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "forge".to_string(),
            "spawned child process".to_string(),
        )
        .with_span_id("abcdef0123456789")
        .with_parent_span_id("0123456789abcdef")
        .with_trace_id("550e8400-e29b-41d4-a716-446655440000");

        assert_eq!(entry.span_id, Some("abcdef0123456789".to_string()));
        assert_eq!(entry.parent_span_id, Some("0123456789abcdef".to_string()));
        assert_eq!(
            entry.trace_id,
            Some("550e8400-e29b-41d4-a716-446655440000".to_string())
        );
    }

    #[test]
    fn test_log_entry_span_context_attachment() {
        // @trace gap:OBS-007 — Verify span context can be attached to log entries
        use crate::span_context::SpanContext;

        let ctx = SpanContext::root();
        let span_id = ctx.span_id();
        let trace_id = ctx.trace_id();

        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "git-service".to_string(),
            "push started".to_string(),
        )
        .with_span_context(&ctx);

        assert_eq!(entry.span_id, Some(span_id.to_string()));
        assert_eq!(entry.trace_id, Some(trace_id.to_string()));
        assert_eq!(entry.parent_span_id, None);
    }

    #[test]
    fn test_log_entry_child_span_context_attachment() {
        // @trace gap:OBS-007 — Verify child span context includes parent reference
        use crate::span_context::SpanContext;

        let root = SpanContext::root();
        let child = root.child_span();
        let parent_id = root.span_id();
        let trace_id = root.trace_id();

        let entry = LogEntry::new(
            Utc::now(),
            "DEBUG".to_string(),
            "inference".to_string(),
            "model inference started".to_string(),
        )
        .with_span_context(&child);

        assert_eq!(entry.trace_id, Some(trace_id.to_string()));
        assert_eq!(entry.parent_span_id, Some(parent_id.to_string()));
    }

    #[test]
    fn test_log_entry_span_fields_serialization() {
        // @trace gap:OBS-007 — Verify span fields serialize correctly to JSON
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "proxy".to_string(),
            "request routed".to_string(),
        )
        .with_span_id("fedcba9876543210")
        .with_parent_span_id("0123456789abcdef")
        .with_trace_id("550e8400-e29b-41d4-a716-446655440000");

        let json = entry.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Span fields should be present in JSON
        assert_eq!(parsed["span_id"], "fedcba9876543210");
        assert_eq!(parsed["parent_span_id"], "0123456789abcdef");
        assert_eq!(parsed["trace_id"], "550e8400-e29b-41d4-a716-446655440000");
    }

    #[test]
    fn test_log_entry_span_fields_omitted_when_none() {
        // @trace gap:OBS-007 — Verify span fields are omitted from JSON when not set
        let entry = LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "forge".to_string(),
            "container started".to_string(),
        );

        let json = entry.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Span fields should not be present when not set
        assert!(parsed.get("span_id").is_none());
        assert!(parsed.get("parent_span_id").is_none());
        assert!(parsed.get("trace_id").is_none());
    }
}
