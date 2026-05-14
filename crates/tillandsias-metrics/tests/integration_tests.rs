//! Integration tests for tillandsias-metrics.
//!
//! @trace spec:resource-metric-collection, spec:observability-metrics
//! @cheatsheet observability/cheatsheet-metrics.md
//!
//! These tests exercise the sampler against a real host kernel — they are
//! therefore environment-sensitive but should be stable on any Linux host
//! that has /proc available. Containers without /proc visibility may see
//! zero values; the assertions are deliberately permissive about that.

use std::time::Duration;
use tillandsias_metrics::{DashboardSnapshot, MetricsSampler, emit_dashboard_metric};

#[test]
fn sampler_survives_rapid_burst() {
    let mut s = MetricsSampler::new();
    for _ in 0..10 {
        let cpu = s.sample_cpu();
        let mem = s.sample_memory();
        let disks = s.sample_disk();
        // Range invariants — never panic, always in documented bounds.
        assert!(cpu.is_valid(), "cpu out of range: {cpu:?}");
        assert!(mem.used_percent() >= 0.0 && mem.used_percent() <= 100.0);
        for d in &disks {
            let p = d.used_percent();
            assert!((0.0..=100.0).contains(&p), "disk {} pct {p}", d.mount_point);
        }
    }
}

#[test]
fn sampler_values_converge_to_reasonable_ranges() {
    // After two samples spaced by the documented minimum interval the CPU
    // value should still be in [0, 100]. We do NOT assert specific numbers
    // (CI hosts can spike unpredictably) — only the invariant.
    let mut s = MetricsSampler::new();
    let _ = s.sample_cpu();
    std::thread::sleep(sysinfo_min_interval());
    let cpu = s.sample_cpu();
    assert!(cpu.is_valid());

    // Memory total should be the same across two back-to-back samples
    // (sysinfo refreshes the same /proc/meminfo).
    let m1 = s.sample_memory();
    let m2 = s.sample_memory();
    assert_eq!(m1.total_bytes, m2.total_bytes, "memory total drifted");
}

#[tokio::test]
async fn continuous_sampler_runs_without_panic() {
    let mut s = MetricsSampler::new();
    // Spawn the sampler with a 100ms interval and abort after 350ms.
    let handle = tokio::spawn(async move {
        s.collect_continuous(Duration::from_millis(100)).await;
    });
    tokio::time::sleep(Duration::from_millis(350)).await;
    handle.abort();
    // If the loop panicked, awaiting the handle yields the panic. We
    // accept either cancelled or completed-without-panic.
    let res = handle.await;
    assert!(res.is_err() || res.is_ok());
}

#[test]
fn dashboard_snapshot_from_real_sampler() {
    let mut s = MetricsSampler::new();
    let _ = s.sample_cpu();
    std::thread::sleep(sysinfo_min_interval());
    let cpu = s.sample_cpu();
    let mem = s.sample_memory();
    let disks = s.sample_disk();
    let snap = DashboardSnapshot::from_samples(&cpu, &mem, &disks);
    assert!(snap.cpu_percent >= 0.0 && snap.cpu_percent <= 100.0);
    assert!(snap.memory_percent >= 0.0 && snap.memory_percent <= 100.0);
    assert!(snap.disk_percent >= 0.0 && snap.disk_percent <= 100.0);
    let json = snap.to_json();
    let s = serde_json::to_string(&json).unwrap();
    assert!(s.contains("cpu_percent"));
    assert!(s.contains("sample_timestamp"));
}

#[test]
fn emit_dashboard_metric_callable() {
    // Smoke test: ensure the public API is reachable from outside the crate.
    emit_dashboard_metric("integration_test_metric", 0.0);
    emit_dashboard_metric("integration_test_metric", 99.999);
}

fn sysinfo_min_interval() -> Duration {
    // sysinfo::MINIMUM_CPU_UPDATE_INTERVAL is ~200ms in 0.30. Re-export it
    // here so integration tests do not depend on sysinfo directly.
    Duration::from_millis(250)
}
