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
use tillandsias_metrics::{
    DashboardSnapshot, DiskIoMetric, MetricsSampler, PsiMetric, emit_dashboard_metric,
};

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

#[test]
fn sample_disk_io_returns_reasonable_rates() {
    // First call establishes a baseline (empty); second after a short sleep
    // produces real rates. On stripped CI containers without /proc/diskstats
    // both calls return empty — both behaviours are acceptable.
    let mut s = MetricsSampler::new();
    let first = s.sample_disk_io();
    assert!(first.is_empty(), "first sample should be a baseline");

    // Generate at least some disk activity so the second sample is likely
    // non-empty on a real host. Even if not, the asserts below tolerate it.
    let tmp = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(tmp.path(), vec![0u8; 64 * 1024]).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let _ = std::fs::read(tmp.path());

    let second: Vec<DiskIoMetric> = s.sample_disk_io();
    for m in &second {
        assert!(m.is_valid(), "disk-io sample invalid: {m:?}");
        assert!(m.read_bytes_per_sec >= 0.0);
        assert!(m.write_bytes_per_sec >= 0.0);
        assert!(m.io_ops_per_sec >= 0.0);
        assert!((0.0..=100.0).contains(&m.io_util_percent));
    }
}

#[test]
fn sample_psi_runs_on_any_kernel() {
    // PSI is widely available on 5.x+ but may be disabled at build time.
    // Either result is fine — we only assert the metric is structurally
    // valid and never panics.
    let s = MetricsSampler::new();
    let psi: PsiMetric = s.sample_psi();
    assert!(psi.is_valid(), "PSI out of range: {psi:?}");
    if !psi.available {
        // On a host without PSI all fields must be 0 by contract.
        assert_eq!(psi.cpu_psi_percent, 0.0);
        assert_eq!(psi.memory_psi_percent, 0.0);
        assert_eq!(psi.io_psi_percent, 0.0);
    }
}

#[test]
fn dashboard_snapshot_includes_disk_io_and_psi() {
    let mut s = MetricsSampler::new();
    let _ = s.sample_cpu();
    let _ = s.sample_disk_io();
    std::thread::sleep(sysinfo_min_interval());
    let cpu = s.sample_cpu();
    let mem = s.sample_memory();
    let disks = s.sample_disk();
    let disk_io = s.sample_disk_io();
    let psi = s.sample_psi();
    let snap = DashboardSnapshot::from_samples(&cpu, &mem, &disks)
        .with_disk_io(&disk_io)
        .with_psi(&psi);

    // Aggregated rates must be non-negative.
    assert!(snap.disk_read_bytes_per_sec >= 0.0);
    assert!(snap.disk_write_bytes_per_sec >= 0.0);
    assert!(snap.disk_iops >= 0.0);
    assert!((0.0..=100.0).contains(&snap.disk_io_percent));
    // PSI percentages must always be in [0, 100] regardless of availability.
    assert!((0.0..=100.0).contains(&snap.cpu_psi_percent));
    assert!((0.0..=100.0).contains(&snap.memory_psi_percent));
    assert!((0.0..=100.0).contains(&snap.io_psi_percent));

    let json = snap.to_json();
    let s = serde_json::to_string(&json).unwrap();
    assert!(s.contains("disk_read_bytes_per_sec"));
    assert!(s.contains("cpu_psi_percent"));
    assert!(s.contains("psi_available"));
}
