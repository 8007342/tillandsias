// @trace spec:runtime-logging, gap:OBS-021, gap:OBS-022
//! Comprehensive integration tests for event coverage enhancements (OBS-021 and OBS-022).
//!
//! This module verifies:
//! - OBS-021: Tray & window lifecycle events
//! - OBS-022: Resource metric events
//!
//! Tests ensure:
//! - Event emission with correct schema
//! - Timestamp ordering and consistency
//! - Field validation and optional field handling
//! - JSON serialization correctness
//! - Batch event processing

use chrono::Utc;
use tillandsias_logging::event_collector::{
    ContainerMetricsEvent, EventCollector, TrayWindowLifecycleEvent,
};

#[test]
fn test_event_coverage_obs021_window_lifecycle_created() {
    let event = TrayWindowLifecycleEvent::new("project-forge-window", "created")
        .with_project("my-app")
        .with_genus("aeranthos");

    let json = EventCollector::log_window_lifecycle(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["event_type"], "tray.window_lifecycle");
    assert_eq!(parsed["event_kind"], "created");
    assert_eq!(parsed["window_id"], "project-forge-window");
    assert_eq!(parsed["project_id"], "my-app");
    assert_eq!(parsed["genus"], "aeranthos");
    assert!(parsed.get("timestamp").is_some());
}

#[test]
fn test_event_coverage_obs021_window_lifecycle_attached() {
    let event =
        TrayWindowLifecycleEvent::new("settings-dialog", "attached").with_project("project-b");

    let json = EventCollector::log_window_lifecycle(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["event_kind"], "attached");
    assert_eq!(parsed["window_id"], "settings-dialog");
}

#[test]
fn test_event_coverage_obs021_window_lifecycle_state_changed() {
    let event = TrayWindowLifecycleEvent::new("logs-viewer", "state_changed")
        .with_state_transition("hidden", "visible");

    let json = EventCollector::log_window_lifecycle(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["event_kind"], "state_changed");
    assert_eq!(parsed["old_state"], "hidden");
    assert_eq!(parsed["new_state"], "visible");
}

#[test]
fn test_event_coverage_obs021_window_lifecycle_detached() {
    let event = TrayWindowLifecycleEvent::new("browser-window", "detached")
        .with_project("web-app");

    let json = EventCollector::log_window_lifecycle(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["event_kind"], "detached");
    assert_eq!(parsed["window_id"], "browser-window");
}

#[test]
fn test_event_coverage_obs021_multiple_windows_timestamp_ordering() {
    // Create multiple window events and verify timestamps are ordered
    let mut events = vec![];

    for i in 0..5 {
        let event = TrayWindowLifecycleEvent::new(
            format!("window-{}", i),
            if i % 2 == 0 { "created" } else { "attached" },
        );
        events.push(event);

        // Small sleep to ensure timestamps differ
        std::thread::sleep(std::time::Duration::from_millis(1));
    }

    let mut prev_timestamp = Utc::now() - chrono::Duration::seconds(1);
    for event in events {
        assert!(event.metadata.timestamp >= prev_timestamp);
        prev_timestamp = event.metadata.timestamp;
    }
}

#[test]
fn test_event_coverage_obs022_container_metrics_basic() {
    let event = ContainerMetricsEvent::new(
        "abc123def456abc123def456",
        "tillandsias-my-project-aeranthos",
        42,
    );

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["event_type"], "container.metrics");
    assert_eq!(parsed["container_id"], "abc123def456abc123def456");
    assert_eq!(parsed["container_name"], "tillandsias-my-project-aeranthos");
    assert_eq!(parsed["wall_clock_ms"], 42);
    assert!(parsed.get("timestamp").is_some());
}

#[test]
fn test_event_coverage_obs022_container_metrics_with_memory() {
    let mem_used = 768u64 * 1024 * 1024; // 768 MB
    let mem_limit = 2048u64 * 1024 * 1024; // 2 GB

    let event = ContainerMetricsEvent::new("container-1", "tillandsias-app1", 50)
        .with_memory(mem_used, mem_limit);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["memory_bytes"], mem_used);
    assert_eq!(parsed["memory_limit_bytes"], mem_limit);
}

#[test]
fn test_event_coverage_obs022_container_metrics_with_cpu() {
    let event =
        ContainerMetricsEvent::new("container-2", "tillandsias-app2", 55).with_cpu(45.5, 4);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["cpu_percent"], 45.5);
    assert_eq!(parsed["cpu_count"], 4);
}

#[test]
fn test_event_coverage_obs022_container_metrics_with_io() {
    let read_rate = 1024.0 * 1024.0; // 1 MB/s
    let write_rate = 512.0 * 1024.0; // 512 KB/s

    let event = ContainerMetricsEvent::new("container-3", "tillandsias-app3", 60)
        .with_io(read_rate, write_rate);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["io_read_bytes_per_sec"], read_rate);
    assert_eq!(parsed["io_write_bytes_per_sec"], write_rate);
}

#[test]
fn test_event_coverage_obs022_container_metrics_with_network() {
    let rx_bytes = 10u64 * 1024 * 1024; // 10 MB
    let tx_bytes = 5u64 * 1024 * 1024; // 5 MB

    let event = ContainerMetricsEvent::new("container-4", "tillandsias-app4", 65)
        .with_network(rx_bytes, tx_bytes);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["net_rx_bytes"], rx_bytes);
    assert_eq!(parsed["net_tx_bytes"], tx_bytes);
}

#[test]
fn test_event_coverage_obs022_container_metrics_all_fields() {
    let event = ContainerMetricsEvent::new(
        "full-container-id-12345",
        "tillandsias-comprehensive-app",
        75,
    )
    .with_memory(1024u64 * 1024 * 1024, 4096u64 * 1024 * 1024)
    .with_cpu(62.3, 8)
    .with_io(2048.0 * 1024.0, 1024.0 * 1024.0)
    .with_network(100u64 * 1024 * 1024, 50u64 * 1024 * 1024);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Verify all fields are present and correct
    assert_eq!(parsed["memory_bytes"], 1024u64 * 1024 * 1024);
    assert_eq!(parsed["memory_limit_bytes"], 4096u64 * 1024 * 1024);
    assert_eq!(parsed["cpu_percent"], 62.3);
    assert_eq!(parsed["cpu_count"], 8);
    assert_eq!(parsed["io_read_bytes_per_sec"], 2048.0 * 1024.0);
    assert_eq!(parsed["io_write_bytes_per_sec"], 1024.0 * 1024.0);
    assert_eq!(parsed["net_rx_bytes"], 100u64 * 1024 * 1024);
    assert_eq!(parsed["net_tx_bytes"], 50u64 * 1024 * 1024);
    assert_eq!(parsed["wall_clock_ms"], 75);
}

#[test]
fn test_event_coverage_obs022_container_metrics_optional_fields_not_present() {
    // Create event with no optional fields
    let event = ContainerMetricsEvent::new("minimal-container", "tillandsias-minimal", 20);

    let json = EventCollector::log_container_metrics(&event).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Optional fields should not appear in JSON
    assert!(parsed.get("memory_bytes").is_none());
    assert!(parsed.get("memory_limit_bytes").is_none());
    assert!(parsed.get("cpu_percent").is_none());
    assert!(parsed.get("cpu_count").is_none());
    assert!(parsed.get("io_read_bytes_per_sec").is_none());
    assert!(parsed.get("io_write_bytes_per_sec").is_none());
    assert!(parsed.get("net_rx_bytes").is_none());
    assert!(parsed.get("net_tx_bytes").is_none());

    // But required fields must be present
    assert!(parsed.get("container_id").is_some());
    assert!(parsed.get("container_name").is_some());
    assert!(parsed.get("wall_clock_ms").is_some());
}

#[test]
fn test_event_coverage_batch_window_lifecycle_events() {
    // Simulate rapid window creation/attachment/state changes
    let mut events = vec![];

    for i in 0..10 {
        let project = format!("project-{}", i % 3);
        let event = TrayWindowLifecycleEvent::new(
            format!("window-{}", i),
            match i % 4 {
                0 => "created",
                1 => "attached",
                2 => "state_changed",
                _ => "detached",
            },
        )
        .with_project(project.clone());

        if i % 2 == 0 {
            events.push(event.with_genus("aeranthos"));
        } else {
            events.push(event);
        }
    }

    for event in events {
        let json = EventCollector::log_window_lifecycle(&event).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["event_type"], "tray.window_lifecycle");
    }
}

#[test]
fn test_event_coverage_batch_container_metrics_events() {
    // Simulate periodic metrics collection from multiple containers
    let containers = vec![
        ("container-1", "tillandsias-app1-aeranthos"),
        ("container-2", "tillandsias-app2-stricta"),
        ("container-3", "tillandsias-app3-ionantha"),
        ("container-4", "tillandsias-shared-forge"),
    ];

    let mut events = vec![];
    let mut cpu_offset = 0.0;
    for (id, name) in containers {
        let event = ContainerMetricsEvent::new(id, name, 25)
            .with_memory(512u64 * 1024 * 1024, 2048u64 * 1024 * 1024)
            .with_cpu(35.0 + cpu_offset, 4)
            .with_io(1024.0 * 1024.0, 512.0 * 1024.0);

        events.push(event);
        cpu_offset += 5.0;
    }

    for event in events {
        let json = EventCollector::log_container_metrics(&event).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["event_type"], "container.metrics");
        assert!(parsed.get("memory_bytes").is_some());
        assert!(parsed.get("cpu_percent").is_some());
    }
}

#[test]
fn test_event_coverage_mixed_event_types() {
    // Create a mix of different event types in the same batch
    let window_event =
        TrayWindowLifecycleEvent::new("logs-window", "created").with_project("test-app");

    let metrics_event = ContainerMetricsEvent::new("container-abc", "tillandsias-test-app", 30)
        .with_memory(256u64 * 1024 * 1024, 1024u64 * 1024 * 1024)
        .with_cpu(25.5, 2);

    let window_json = EventCollector::log_window_lifecycle(&window_event).unwrap();
    let metrics_json = EventCollector::log_container_metrics(&metrics_event).unwrap();

    let window_parsed: serde_json::Value = serde_json::from_str(&window_json).unwrap();
    let metrics_parsed: serde_json::Value = serde_json::from_str(&metrics_json).unwrap();

    // Verify type distinction
    assert_eq!(window_parsed["event_type"], "tray.window_lifecycle");
    assert_eq!(metrics_parsed["event_type"], "container.metrics");

    // Both should have timestamps
    assert!(window_parsed.get("timestamp").is_some());
    assert!(metrics_parsed.get("timestamp").is_some());
}

#[test]
fn test_event_coverage_spec_trace_presence() {
    // Verify that all events include spec trace information
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

#[test]
fn test_event_coverage_actor_identification() {
    let window_event = TrayWindowLifecycleEvent::new("w1", "created");
    let metrics_event = ContainerMetricsEvent::new("c1", "tillandsias-test", 10);

    assert_eq!(window_event.metadata.actor, "tillandsias-tray");
    assert_eq!(metrics_event.metadata.actor, "tillandsias-metrics");
}

#[test]
fn test_event_coverage_json_schema_consistency() {
    // Verify JSON schema consistency across multiple events
    let events_data = vec![
        (
            TrayWindowLifecycleEvent::new("w1", "created").to_json().unwrap(),
            "tray.window_lifecycle",
        ),
        (
            ContainerMetricsEvent::new("c1", "tillandsias-test", 10)
                .to_json()
                .unwrap(),
            "container.metrics",
        ),
    ];

    for (json, expected_type) in events_data {
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        // Every event must have these fields
        assert!(parsed.get("event_type").is_some());
        assert!(parsed.get("timestamp").is_some());
        assert!(parsed.get("actor").is_some());
        assert_eq!(parsed["event_type"], expected_type);
    }
}

#[test]
fn test_event_coverage_large_metric_values() {
    // Test handling of large metric values (boundary conditions)
    let event = ContainerMetricsEvent::new("container-large", "tillandsias-large", u64::MAX)
        .with_memory(u64::MAX / 2, u64::MAX - 1)
        .with_cpu(100.0, u32::MAX)
        .with_network(u64::MAX / 4, u64::MAX / 4);

    let json = event.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["wall_clock_ms"], u64::MAX);
    assert_eq!(parsed["memory_bytes"], u64::MAX / 2);
    assert_eq!(parsed["cpu_percent"], 100.0);
}

#[test]
fn test_event_coverage_zero_metric_values() {
    // Test handling of zero metric values
    let event = ContainerMetricsEvent::new("container-zero", "tillandsias-zero", 0)
        .with_memory(0, 0)
        .with_cpu(0.0, 0)
        .with_io(0.0, 0.0)
        .with_network(0, 0);

    let json = event.to_json().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["wall_clock_ms"], 0);
    assert_eq!(parsed["memory_bytes"], 0);
    assert_eq!(parsed["cpu_percent"], 0.0);
    assert_eq!(parsed["io_read_bytes_per_sec"], 0.0);
}

#[test]
fn test_event_coverage_window_with_all_state_kinds() {
    // Test all valid event_kind values for window events
    let kinds = vec!["created", "attached", "state_changed", "detached"];

    for kind in kinds {
        let event = TrayWindowLifecycleEvent::new("test-window", kind)
            .with_project("test-project")
            .with_genus("genus");

        let json = event.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["event_kind"], kind);
        assert_eq!(parsed["event_type"], "tray.window_lifecycle");
    }
}

#[test]
fn test_event_coverage_concurrent_event_creation() {
    // Test that events can be created concurrently without issues
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    let counter = Arc::new(AtomicUsize::new(0));
    let mut handles = vec![];

    for i in 0..5 {
        let counter_clone = Arc::clone(&counter);
        let handle = std::thread::spawn(move || {
            // Window events
            let window = TrayWindowLifecycleEvent::new(
                format!("window-{}", i),
                "created",
            );
            let _ = window.to_json();

            // Metrics events
            let metrics = ContainerMetricsEvent::new(
                format!("container-{}", i),
                format!("tillandsias-app-{}", i),
                25,
            )
            .with_cpu(25.0, 4);
            let _ = metrics.to_json();

            counter_clone.fetch_add(1, Ordering::SeqCst);
        });
        handles.push(handle);
    }

    for handle in handles {
        handle.join().unwrap();
    }

    assert_eq!(counter.load(Ordering::SeqCst), 5);
}
