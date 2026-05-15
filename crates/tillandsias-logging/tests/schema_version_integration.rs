// @trace spec:runtime-logging, gap:OBS-003
//! Integration tests for schema_version field in all log scenarios
//!
//! Validates that:
//! - schema_version is always present in LogEntry
//! - schema_version is correctly serialized to JSON
//! - schema_version value is "1.0"
//! - schema_version is immutable across all log types
//! - schema_version works with all LogEntry builder methods

use chrono::Utc;
use serde_json::json;
use tillandsias_logging::LogEntry;

#[test]
fn test_schema_version_always_present_in_new_logs() {
    // @trace gap:OBS-003 — schema_version must be present in all new log entries
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "test message".to_string(),
    );

    assert_eq!(entry.schema_version, "1.0");
}

#[test]
fn test_schema_version_in_json_serialization() {
    // @trace gap:OBS-003 — schema_version must be present in JSON output
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "git-service".to_string(),
        "test message".to_string(),
    );

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert!(parsed.get("schema_version").is_some());
    assert_eq!(parsed["schema_version"], "1.0");
}

#[test]
fn test_schema_version_in_pretty_json() {
    // @trace gap:OBS-003 — schema_version must be present in pretty JSON output
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "inference".to_string(),
        "test message".to_string(),
    );

    let json = entry.to_json_pretty().unwrap();
    assert!(json.contains("\"schema_version\""));
    assert!(json.contains("\"1.0\""));
}

#[test]
fn test_schema_version_with_all_builder_methods() {
    // @trace gap:OBS-003 — schema_version must persist through all builder operations
    let entry = LogEntry::new(
        Utc::now(),
        "ERROR".to_string(),
        "forge".to_string(),
        "test message".to_string(),
    )
    .with_context("key1", json!("value1"))
    .with_context("key2", json!(42))
    .with_spec_trace("spec:enclave-network")
    .as_accountability("secrets")
    .with_safety("no credentials exposed");

    assert_eq!(entry.schema_version, "1.0");

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["schema_version"], "1.0");
}

#[test]
fn test_schema_version_with_span_context() {
    // @trace gap:OBS-003, gap:OBS-007 — schema_version must be present with span context
    use tillandsias_logging::span_context::SpanContext;

    let ctx = SpanContext::root();
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "test message".to_string(),
    )
    .with_span_context(&ctx);

    assert_eq!(entry.schema_version, "1.0");

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["schema_version"], "1.0");
}

#[test]
fn test_schema_version_with_sampling_metadata() {
    // @trace gap:OBS-003, gap:OBS-006 — schema_version with sampling metadata
    let entry = LogEntry::new(
        Utc::now(),
        "DEBUG".to_string(),
        "git-service".to_string(),
        "test message".to_string(),
    )
    .with_sample_rate(0.5);

    assert_eq!(entry.schema_version, "1.0");

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["schema_version"], "1.0");
    assert_eq!(parsed["sample_rate"], 0.5);
}

#[test]
fn test_schema_version_immutable_across_variations() {
    // @trace gap:OBS-003 — all log variations must have the same schema_version
    let entries = vec![
        LogEntry::new(
            Utc::now(),
            "TRACE".to_string(),
            "proxy".to_string(),
            "msg1".to_string(),
        ),
        LogEntry::new(
            Utc::now(),
            "DEBUG".to_string(),
            "git-service".to_string(),
            "msg2".to_string(),
        )
        .as_accountability("network"),
        LogEntry::new(
            Utc::now(),
            "INFO".to_string(),
            "inference".to_string(),
            "msg3".to_string(),
        )
        .with_context("model", json!("qwen2.5-coder:7b")),
        LogEntry::new(
            Utc::now(),
            "WARN".to_string(),
            "forge".to_string(),
            "msg4".to_string(),
        )
        .with_spec_trace("spec:container-launch"),
        LogEntry::new(
            Utc::now(),
            "ERROR".to_string(),
            "proxy".to_string(),
            "msg5".to_string(),
        )
        .as_accountability("secrets")
        .with_safety("credentials were not exposed"),
    ];

    for entry in entries {
        assert_eq!(
            entry.schema_version, "1.0",
            "Schema version must be 1.0 for all entries"
        );
    }
}

#[test]
fn test_schema_version_json_field_order() {
    // @trace gap:OBS-003 — schema_version should be present (field order may vary)
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "test message".to_string(),
    );

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Verify all essential fields are present
    assert!(parsed.get("schema_version").is_some());
    assert!(parsed.get("timestamp").is_some());
    assert!(parsed.get("level").is_some());
    assert!(parsed.get("component").is_some());
    assert!(parsed.get("message").is_some());
}

#[test]
fn test_schema_version_deserialization() {
    // @trace gap:OBS-003 — schema_version must deserialize correctly
    let json_str = r#"{
        "schema_version": "1.0",
        "timestamp": "2026-05-14T12:34:56Z",
        "level": "INFO",
        "component": "proxy",
        "message": "test message"
    }"#;

    let entry: LogEntry = serde_json::from_str(json_str).unwrap();
    assert_eq!(entry.schema_version, "1.0");
    assert_eq!(entry.level, "INFO");
    assert_eq!(entry.component, "proxy");
}

#[test]
fn test_schema_version_consistency_roundtrip() {
    // @trace gap:OBS-003 — schema_version must be consistent across serialize/deserialize
    let original = LogEntry::new(
        Utc::now(),
        "WARN".to_string(),
        "git-service".to_string(),
        "test message".to_string(),
    )
    .with_context("pr_number", json!(42))
    .as_accountability("git");

    let json = original.to_json().unwrap();
    let deserialized: LogEntry = serde_json::from_str(&json).unwrap();

    assert_eq!(original.schema_version, deserialized.schema_version);
    assert_eq!(original.schema_version, "1.0");
    assert_eq!(deserialized.schema_version, "1.0");
}

#[test]
fn test_schema_version_with_all_optional_fields() {
    // @trace gap:OBS-003 — schema_version with all optional fields populated
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "test message".to_string(),
    )
    .with_context("key1", json!("value1"))
    .with_context("key2", json!("value2"))
    .with_spec_trace("spec:enclave-network")
    .as_accountability("network")
    .with_safety("network sandboxed from external IPs")
    .with_sample_rate(0.75)
    .with_span_id("span123")
    .with_parent_span_id("parent456")
    .with_trace_id("trace789");

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Verify schema_version is present and correct
    assert_eq!(parsed["schema_version"], "1.0");

    // Verify all other fields are also present
    assert_eq!(parsed["level"], "INFO");
    assert_eq!(parsed["component"], "proxy");
    assert_eq!(parsed["message"], "test message");
    assert_eq!(parsed["accountability"], true);
    assert_eq!(parsed["category"], "network");
}
