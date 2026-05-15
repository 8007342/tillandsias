// @trace spec:runtime-logging, gap:OBS-001
// Log schema field stability validation tests
// Prevents silent breaking changes in log field names and types

use crate::LogEntry;
use chrono::Utc;
use serde_json::json;
use std::collections::HashMap;

/// Validates that all required core fields are present in LogEntry
/// @trace gap:OBS-001 — Core field presence validation
#[test]
fn test_core_fields_present() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "test-component".to_string(),
        "test message".to_string(),
    );

    assert!(!entry.schema_version.is_empty());
    assert_eq!(entry.schema_version, "1.0");
    assert_eq!(entry.level, "INFO");
    assert_eq!(entry.component, "test-component");
    assert_eq!(entry.message, "test message");
    // timestamp is always present (cannot be None in struct)
    let _ = entry.timestamp;
}

/// Validates that optional fields can be independently set
/// @trace gap:OBS-001 — Optional field independence
#[test]
fn test_optional_fields_independent() {
    let entry1 = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "comp1".to_string(),
        "msg1".to_string(),
    );

    let entry2 = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "comp2".to_string(),
        "msg2".to_string(),
    )
    .with_spec_trace("some-spec");

    // entry1 has no spec_trace
    assert!(entry1.spec_trace.is_none());

    // entry2 has spec_trace
    assert_eq!(entry2.spec_trace, Some("some-spec".to_string()));

    // They are independent
    assert_ne!(entry1.spec_trace, entry2.spec_trace);
}

/// Validates that accountability field serialization behavior is correct
/// @trace gap:OBS-001 — Accountability field serialization stability
#[test]
fn test_accountability_serialization_stability() {
    // Entry without accountability should not include field in JSON
    let entry_no_accountability = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "routine event".to_string(),
    );

    let json1 = entry_no_accountability.to_json().unwrap();
    let parsed1: serde_json::Value = serde_json::from_str(&json1).unwrap();
    assert!(parsed1.get("accountability").is_none(),
            "Accountability should be omitted when false or None");

    // Entry with accountability=true should include field in JSON
    let entry_with_accountability = LogEntry::new(
        Utc::now(),
        "WARN".to_string(),
        "git-service".to_string(),
        "token mounted".to_string(),
    )
    .as_accountability("secrets");

    let json2 = entry_with_accountability.to_json().unwrap();
    let parsed2: serde_json::Value = serde_json::from_str(&json2).unwrap();
    assert_eq!(parsed2["accountability"], true,
               "Accountability should be true when explicitly set");
    assert_eq!(parsed2["category"], "secrets",
               "Category should be present with accountability");
}

/// Validates that all core field names match the golden schema
/// @trace gap:OBS-001 — Core field name stability
#[test]
fn test_all_core_field_names_present() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "test".to_string(),
        "test".to_string(),
    );

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Core fields must be present in JSON
    let core_fields = vec![
        "schema_version",
        "timestamp",
        "level",
        "component",
        "message",
    ];

    for field in core_fields {
        assert!(parsed.get(field).is_some(),
                "Core field '{}' missing from serialized JSON", field);
    }
}

/// Validates context field flexibility (arbitrary key-value pairs)
/// @trace gap:OBS-001 — Context field schema flexibility
#[test]
fn test_context_field_flexibility() {
    let mut ctx = HashMap::new();
    ctx.insert("string_val".to_string(), json!("hello"));
    ctx.insert("number_val".to_string(), json!(42));
    ctx.insert("bool_val".to_string(), json!(true));
    ctx.insert("nested_obj".to_string(), json!({"inner": "value"}));

    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "test".to_string(),
        "test".to_string(),
    )
    .with_contexts(ctx);

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Context should be present
    assert!(parsed.get("context").is_some());
    let context = &parsed["context"];
    assert_eq!(context["string_val"], "hello");
    assert_eq!(context["number_val"], 42);
    assert_eq!(context["bool_val"], true);
    assert_eq!(context["nested_obj"]["inner"], "value");
}

/// Validates distributed tracing fields are optional and independent
/// @trace gap:OBS-001, gap:OBS-007 — Distributed tracing field stability
#[test]
fn test_distributed_tracing_fields_optional() {
    // Entry without any tracing fields
    let entry_no_trace = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "forge".to_string(),
        "startup".to_string(),
    );

    assert!(entry_no_trace.span_id.is_none());
    assert!(entry_no_trace.trace_id.is_none());
    assert!(entry_no_trace.parent_span_id.is_none());

    // Serialized JSON should omit tracing fields when not set
    let json1 = entry_no_trace.to_json().unwrap();
    let parsed1: serde_json::Value = serde_json::from_str(&json1).unwrap();
    assert!(parsed1.get("span_id").is_none());
    assert!(parsed1.get("trace_id").is_none());
    assert!(parsed1.get("parent_span_id").is_none());

    // Entry with all tracing fields
    let entry_full_trace = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "proxy".to_string(),
        "forward to git-service".to_string(),
    )
    .with_span_id("0123456789abcdef")
    .with_trace_id("550e8400-e29b-41d4-a716-446655440000")
    .with_parent_span_id("fedcba9876543210");

    assert_eq!(entry_full_trace.span_id, Some("0123456789abcdef".to_string()));
    assert_eq!(entry_full_trace.trace_id, Some("550e8400-e29b-41d4-a716-446655440000".to_string()));
    assert_eq!(entry_full_trace.parent_span_id, Some("fedcba9876543210".to_string()));

    // Serialized JSON should include tracing fields when set
    let json2 = entry_full_trace.to_json().unwrap();
    let parsed2: serde_json::Value = serde_json::from_str(&json2).unwrap();
    assert_eq!(parsed2["span_id"], "0123456789abcdef");
    assert_eq!(parsed2["trace_id"], "550e8400-e29b-41d4-a716-446655440000");
    assert_eq!(parsed2["parent_span_id"], "fedcba9876543210");
}

/// Validates sampling rate field is optional and numeric
/// @trace gap:OBS-001, gap:OBS-006 — Cost-aware sampling field stability
#[test]
fn test_sampling_rate_field_optional() {
    // Entry without sampling
    let entry_no_sample = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "test".to_string(),
        "regular event".to_string(),
    );

    assert!(entry_no_sample.sample_rate.is_none());

    // Entry with sampling
    let entry_with_sample = LogEntry::new(
        Utc::now(),
        "DEBUG".to_string(),
        "test".to_string(),
        "sampled debug event".to_string(),
    )
    .with_sample_rate(0.1);

    assert_eq!(entry_with_sample.sample_rate, Some(0.1));

    // Serialization should omit when None
    let json1 = entry_no_sample.to_json().unwrap();
    let parsed1: serde_json::Value = serde_json::from_str(&json1).unwrap();
    assert!(parsed1.get("sample_rate").is_none());

    // Serialization should include when Some
    let json2 = entry_with_sample.to_json().unwrap();
    let parsed2: serde_json::Value = serde_json::from_str(&json2).unwrap();
    assert_eq!(parsed2["sample_rate"], 0.1);
}

/// Validates field ordering stability in JSON output
/// @trace gap:OBS-001 — JSON field ordering consistency
#[test]
fn test_json_field_ordering_consistent() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "test".to_string(),
        "test".to_string(),
    )
    .with_spec_trace("test-spec")
    .as_accountability("test-cat");

    let json1 = entry.to_json().unwrap();
    let json2 = entry.to_json().unwrap();

    // JSON should be identical on multiple serializations
    assert_eq!(json1, json2, "JSON serialization should be deterministic");

    // Verify it's valid JSON both times
    let _: serde_json::Value = serde_json::from_str(&json1).unwrap();
    let _: serde_json::Value = serde_json::from_str(&json2).unwrap();
}

/// Validates that breaking field changes would be detected
/// This test serves as a baseline for what constitutes a breaking change
/// @trace gap:OBS-001 — Breaking change detection strategy
#[test]
fn test_breaking_change_detection_baseline() {
    // If someone removes a required core field (e.g., timestamp),
    // this would fail to compile. If someone renames a field,
    // serialization tests would catch it.

    // This test documents the expected contract:
    // - Core fields: schema_version, timestamp, level, component, message
    // - Cannot be removed, renamed, or change type
    // - Optional fields: can be added without version bump
    // - Schema version 1.0 is immutable for this release

    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "baseline".to_string(),
        "test".to_string(),
    );

    // These must compile and work:
    let _ = entry.schema_version;
    let _ = entry.timestamp;
    let _ = entry.level;
    let _ = entry.component;
    let _ = entry.message;

    // If any of these fields are removed or renamed, compilation fails.
    // If serialization skips them, the test above catches it.
}

/// Validates that new optional fields don't break deserialization
/// @trace gap:OBS-001 — Forward compatibility validation
#[test]
fn test_forward_compatible_field_omission() {
    // Old logs without optional fields should deserialize correctly
    let json_minimal = r#"{
        "schema_version": "1.0",
        "timestamp": "2026-05-14T12:00:00Z",
        "level": "INFO",
        "component": "test",
        "message": "minimal log entry"
    }"#;

    // Should deserialize successfully
    let result: Result<LogEntry, _> = serde_json::from_str(json_minimal);
    assert!(result.is_ok(), "Should deserialize minimal log entry without optional fields");

    let entry = result.unwrap();
    assert_eq!(entry.schema_version, "1.0");
    assert_eq!(entry.level, "INFO");
    assert_eq!(entry.component, "test");
    assert_eq!(entry.message, "minimal log entry");
    assert!(entry.spec_trace.is_none());
    assert!(entry.accountability.is_none());
    assert!(entry.span_id.is_none());
}

/// Validates that deserialization handles unknown fields gracefully
/// @trace gap:OBS-001 — Future-proof schema evolution
#[test]
fn test_unknown_field_tolerance() {
    // Logs from future versions with unknown optional fields should still deserialize
    let json_with_unknown = r#"{
        "schema_version": "1.0",
        "timestamp": "2026-05-14T12:00:00Z",
        "level": "INFO",
        "component": "test",
        "message": "log with unknown field",
        "future_field": "unknown value",
        "another_future": 42
    }"#;

    // serde's default behavior ignores unknown fields
    let result: Result<LogEntry, _> = serde_json::from_str(json_with_unknown);
    assert!(result.is_ok(), "Should ignore unknown fields during deserialization");

    let entry = result.unwrap();
    assert_eq!(entry.message, "log with unknown field");
}

/// Validates spec trace link format stability
/// @trace gap:OBS-001 — Spec trace field stability
#[test]
fn test_spec_trace_format_stability() {
    let entry = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "git-service".to_string(),
        "pull started".to_string(),
    )
    .with_spec_trace("git-mirror-service");

    assert_eq!(entry.spec_trace, Some("git-mirror-service".to_string()));

    let json = entry.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(parsed["spec_trace"], "git-mirror-service");

    // spec_trace should always be a string, never null or object
    assert!(parsed["spec_trace"].is_string());
}

/// Validates that the schema version field is always present and immutable
/// @trace gap:OBS-001 — Schema version immutability validation
#[test]
fn test_schema_version_immutable_and_present() {
    // Create entries in different ways
    let entry1 = LogEntry::new(
        Utc::now(),
        "INFO".to_string(),
        "comp1".to_string(),
        "msg1".to_string(),
    );

    let entry2 = LogEntry::new(
        Utc::now(),
        "ERROR".to_string(),
        "comp2".to_string(),
        "msg2".to_string(),
    )
    .with_spec_trace("spec1")
    .as_accountability("cat1");

    // Both must have the same immutable schema version
    assert_eq!(entry1.schema_version, "1.0");
    assert_eq!(entry2.schema_version, "1.0");
    assert_eq!(entry1.schema_version, entry2.schema_version);

    // Both serializations must include schema_version
    let json1 = entry1.to_json().unwrap();
    let json2 = entry2.to_json().unwrap();

    let parsed1: serde_json::Value = serde_json::from_str(&json1).unwrap();
    let parsed2: serde_json::Value = serde_json::from_str(&json2).unwrap();

    assert!(parsed1["schema_version"].is_string());
    assert!(parsed2["schema_version"].is_string());
    assert_eq!(parsed1["schema_version"], "1.0");
    assert_eq!(parsed2["schema_version"], "1.0");
}
