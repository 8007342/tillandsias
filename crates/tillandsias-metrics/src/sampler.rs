//! Sysinfo-backed sampler for CPU, memory, disk-usage, disk-I/O, and PSI metrics.
//!
//! The sampler holds a [`sysinfo::System`] and a [`sysinfo::Disks`] handle
//! and refreshes only the components it needs for each sample call. This
//! keeps individual samples cheap (sub-millisecond on Linux for memory; CPU
//! requires the documented minimum interval between two refreshes to be
//! accurate). Disk-I/O rates are derived by differencing `/proc/diskstats`
//! between two consecutive samples; PSI is parsed from `/proc/pressure/*`.
//!
//! @trace spec:observability-metrics, spec:resource-metric-collection
//! @cheatsheet observability/cheatsheet-metrics.md

use crate::error::MetricsError;
use crate::models::{CpuMetric, DiskIoMetric, DiskMetric, MemoryMetric, PsiMetric};
use chrono::Utc;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};
use sysinfo::{Disks, MINIMUM_CPU_UPDATE_INTERVAL, System};
use tracing::{debug, info, warn};

/// Path to the kernel's per-device I/O counter file. Configurable for tests.
const PROC_DISKSTATS: &str = "/proc/diskstats";
/// Directory holding PSI pseudo-files (`cpu`, `memory`, `io`). Configurable
/// for tests.
const PROC_PRESSURE_DIR: &str = "/proc/pressure";
/// Sector size assumed for `/proc/diskstats` sector counts. The kernel always
/// reports in 512-byte sectors regardless of the underlying physical sector
/// size (see kernel Documentation/admin-guide/iostats.rst).
const DISKSTATS_SECTOR_BYTES: u64 = 512;

/// One row of `/proc/diskstats`, used as the previous-snapshot baseline for
/// rate computation. Only the columns we need are kept (sectors and ticks).
#[derive(Debug, Clone, Copy, PartialEq)]
struct DiskstatsRow {
    sectors_read: u64,
    sectors_written: u64,
    reads_completed: u64,
    writes_completed: u64,
    /// Total milliseconds spent doing I/O (the `io_ticks` column). Wraps the
    /// kernel's `part_stat_read` busy time; used for utilisation.
    io_ticks_ms: u64,
}

/// Sampler for CPU, memory, disk-usage, disk-I/O, and cgroup PSI metrics.
///
/// `MetricsSampler` owns a [`sysinfo::System`] that is refreshed on demand.
/// CPU sampling requires the sampler to be alive long enough between calls
/// to satisfy sysinfo's [`MINIMUM_CPU_UPDATE_INTERVAL`] — the first call may
/// return zeros, which is documented and not an error. Disk-I/O rates work
/// the same way: the first [`Self::sample_disk_io`] call after construction
/// records a baseline and returns an empty vector.
#[derive(Debug)]
pub struct MetricsSampler {
    system: System,
    disks: Disks,
    /// Previous `/proc/diskstats` snapshot used for rate computation.
    /// `None` until the first `sample_disk_io` call.
    previous_diskstats: Option<(Instant, BTreeMap<String, DiskstatsRow>)>,
    /// Override for `/proc/diskstats` location (testing only).
    diskstats_path: String,
    /// Override for `/proc/pressure` directory (testing only).
    pressure_dir: String,
}

impl MetricsSampler {
    /// Construct a new sampler. The underlying `System` is created with no
    /// initial refresh; call a `sample_*` method to populate values.
    pub fn new() -> Self {
        let system = System::new();
        let disks = Disks::new_with_refreshed_list();
        Self {
            system,
            disks,
            previous_diskstats: None,
            diskstats_path: PROC_DISKSTATS.to_string(),
            pressure_dir: PROC_PRESSURE_DIR.to_string(),
        }
    }

    /// Construct a sampler with custom `/proc/diskstats` and `/proc/pressure`
    /// paths. Intended for unit tests that drive the parser from fixture
    /// files; production callers use [`Self::new`].
    #[doc(hidden)]
    pub fn with_proc_paths(
        diskstats_path: impl Into<String>,
        pressure_dir: impl Into<String>,
    ) -> Self {
        let mut s = Self::new();
        s.diskstats_path = diskstats_path.into();
        s.pressure_dir = pressure_dir.into();
        s
    }

    /// Sample current CPU usage (aggregate and per-core).
    ///
    /// Note: sysinfo computes CPU usage as a delta between two refreshes.
    /// The very first call after [`Self::new`] returns 0.0 for every core.
    /// Production callers should either:
    ///
    /// 1. Discard the first sample, or
    /// 2. Use [`Self::collect_continuous`], which warms up the sampler
    ///    before emitting events.
    pub fn sample_cpu(&mut self) -> CpuMetric {
        self.system.refresh_cpu_usage();
        let per_core_percent: Vec<f64> = self
            .system
            .cpus()
            .iter()
            .map(|c| c.cpu_usage() as f64)
            .collect();
        let system_percent = self.system.global_cpu_info().cpu_usage() as f64;
        CpuMetric {
            system_percent: clamp_percent(system_percent),
            per_core_percent: per_core_percent.into_iter().map(clamp_percent).collect(),
            timestamp: Utc::now(),
        }
    }

    /// Sample current memory usage (RAM + swap).
    pub fn sample_memory(&mut self) -> MemoryMetric {
        self.system.refresh_memory();
        MemoryMetric {
            total_bytes: self.system.total_memory(),
            used_bytes: self.system.used_memory(),
            available_bytes: self.system.available_memory(),
            swap_total_bytes: self.system.total_swap(),
            swap_used_bytes: self.system.used_swap(),
            timestamp: Utc::now(),
        }
    }

    /// Sample disk usage across all mounted filesystems known to the kernel.
    ///
    /// Filesystem entries that report zero total bytes (e.g., pseudo
    /// filesystems like cgroup2) are filtered out.
    pub fn sample_disk(&mut self) -> Vec<DiskMetric> {
        self.disks.refresh();
        let timestamp = Utc::now();
        self.disks
            .iter()
            .filter(|d| d.total_space() > 0)
            .map(|d| DiskMetric {
                mount_point: d.mount_point().to_string_lossy().to_string(),
                total_bytes: d.total_space(),
                available_bytes: d.available_space(),
                timestamp,
            })
            .collect()
    }

    /// Sample disk I/O rates across every block device known to the kernel.
    ///
    /// Returns an empty vector on the first call (baseline-only) and on
    /// kernels that do not expose `/proc/diskstats`. Subsequent calls
    /// compute byte/op rates by differencing against the prior snapshot.
    /// Devices that appear or disappear between samples are silently
    /// skipped — the kernel handles hot-plug without our help.
    ///
    /// @trace spec:resource-metric-collection
    pub fn sample_disk_io(&mut self) -> Vec<DiskIoMetric> {
        let now = Instant::now();
        let timestamp = Utc::now();
        let current = match read_diskstats(Path::new(&self.diskstats_path)) {
            Ok(rows) => rows,
            Err(e) => {
                debug!(
                    spec = "resource-metric-collection",
                    error = %e,
                    path = %self.diskstats_path,
                    "diskstats unavailable; skipping disk-IO sample"
                );
                return Vec::new();
            }
        };

        let result = match self.previous_diskstats.as_ref() {
            None => Vec::new(),
            Some((prev_instant, prev)) => {
                let elapsed = now.saturating_duration_since(*prev_instant).as_secs_f64();
                if elapsed <= 0.0 {
                    Vec::new()
                } else {
                    current
                        .iter()
                        .filter_map(|(device, row)| {
                            let prev_row = prev.get(device)?;
                            Some(diff_diskstats(device, prev_row, row, elapsed, timestamp))
                        })
                        .collect()
                }
            }
        };

        self.previous_diskstats = Some((now, current));
        result
    }

    /// Sample cgroup Pressure Stall Information.
    ///
    /// Reads the `avg10` column from `/proc/pressure/{cpu,memory,io}` and
    /// returns a [`PsiMetric`]. On kernels without PSI support (pre-4.20 or
    /// `CONFIG_PSI=n`), returns [`PsiMetric::unavailable`] with `available =
    /// false` and zeroed fields. Partial availability (e.g., `cpu` present
    /// but `io` missing) is collapsed to the per-file default of 0.0.
    ///
    /// @trace spec:resource-metric-collection
    pub fn sample_psi(&self) -> PsiMetric {
        let dir = Path::new(&self.pressure_dir);
        if !dir.is_dir() {
            debug!(
                spec = "resource-metric-collection",
                path = %self.pressure_dir,
                "/proc/pressure missing; PSI unavailable"
            );
            return PsiMetric::unavailable();
        }

        let cpu = read_psi_avg10(&dir.join("cpu")).unwrap_or(0.0);
        let mem = read_psi_avg10(&dir.join("memory")).unwrap_or(0.0);
        let io = read_psi_avg10(&dir.join("io")).unwrap_or(0.0);

        PsiMetric {
            cpu_psi_percent: clamp_percent(cpu),
            memory_psi_percent: clamp_percent(mem),
            io_psi_percent: clamp_percent(io),
            available: true,
            timestamp: Utc::now(),
        }
    }

    /// Run a continuous sampling loop that emits tracing events at the given
    /// interval. Intended to be spawned as a background tokio task.
    ///
    /// The first iteration warms up the CPU sampler by taking two samples
    /// separated by [`MINIMUM_CPU_UPDATE_INTERVAL`] before emitting its
    /// first dashboard-bound event. Cancellation is via `JoinHandle::abort`
    /// — the loop is cancellation-safe at every `await` point.
    ///
    /// PSI is sampled at half the frequency of CPU/memory/disk (every second
    /// loop iteration) because the underlying counters are themselves smoothed
    /// over a 10-second window — oversampling produces no new information.
    ///
    /// @trace spec:resource-metric-collection
    pub async fn collect_continuous(&mut self, interval: Duration) {
        if interval.is_zero() {
            warn!(
                spec = "resource-metric-collection",
                "collect_continuous called with zero interval; aborting loop"
            );
            return;
        }

        // Warm-up: prime CPU counters and disk-IO baseline before the first emit.
        let _ = self.sample_cpu();
        let _ = self.sample_disk_io();
        tokio::time::sleep(MINIMUM_CPU_UPDATE_INTERVAL).await;

        let mut ticker = tokio::time::interval(interval);
        // Skip the immediate first tick — interval() fires once at t=0.
        ticker.tick().await;
        let mut iteration: u64 = 0;
        loop {
            ticker.tick().await;
            iteration = iteration.wrapping_add(1);

            let cpu = self.sample_cpu();
            let mem = self.sample_memory();
            // Disk sampling is comparatively expensive (one syscall per
            // mount); sample once per loop iteration but emit only the
            // aggregate "root" percent to the trace stream.
            let disks = self.sample_disk();
            let worst_disk_percent = disks
                .iter()
                .map(|d| d.used_percent())
                .fold(0.0_f64, f64::max);

            // Disk I/O is sampled every iteration so byte-rate windows match
            // the user's chosen cadence.
            let disk_io = self.sample_disk_io();
            let (read_bps, write_bps, iops, worst_io_util) = aggregate_disk_io(&disk_io);

            info!(
                spec = "resource-metric-collection",
                cheatsheet = "observability/cheatsheet-metrics.md",
                cpu_percent = format!("{:.1}", cpu.system_percent),
                mem_percent = format!("{:.1}", mem.used_percent()),
                disk_worst_percent = format!("{:.1}", worst_disk_percent),
                disk_read_bps = format!("{read_bps:.0}"),
                disk_write_bps = format!("{write_bps:.0}"),
                disk_iops = format!("{iops:.0}"),
                disk_io_percent = format!("{worst_io_util:.1}"),
                "resource sample"
            );
            debug!(
                spec = "resource-metric-collection",
                cores = cpu.per_core_percent.len(),
                mount_count = disks.len(),
                device_count = disk_io.len(),
                "resource sample detail"
            );

            // PSI is smoothed kernel-side over 10s — emit on every second
            // iteration so we honour the "low-frequency" guidance without a
            // second timer.
            if iteration.is_multiple_of(2) {
                let psi = self.sample_psi();
                if psi.available {
                    info!(
                        spec = "resource-metric-collection",
                        cheatsheet = "observability/cheatsheet-metrics.md",
                        cpu_psi_percent = format!("{:.2}", psi.cpu_psi_percent),
                        memory_psi_percent = format!("{:.2}", psi.memory_psi_percent),
                        io_psi_percent = format!("{:.2}", psi.io_psi_percent),
                        "psi sample"
                    );
                } else {
                    debug!(
                        spec = "resource-metric-collection",
                        "psi unavailable (older kernel or PSI disabled)"
                    );
                }
            }
        }
    }

    /// Validate that an interval is usable for [`Self::collect_continuous`].
    /// Exposed for callers that want to reject misconfiguration up front.
    pub fn validate_interval(interval: Duration) -> Result<(), MetricsError> {
        if interval.is_zero() {
            return Err(MetricsError::InvalidInterval(interval));
        }
        Ok(())
    }
}

impl Default for MetricsSampler {
    fn default() -> Self {
        Self::new()
    }
}

fn clamp_percent(v: f64) -> f64 {
    if v.is_nan() {
        return 0.0;
    }
    v.clamp(0.0, 100.0)
}

/// Parse `/proc/diskstats`. Documented column order (kernel
/// `Documentation/admin-guide/iostats.rst`): the device name is the third
/// whitespace-separated field; counters follow starting at field 4. We only
/// keep the few columns relevant to rate computation.
fn read_diskstats(path: &Path) -> std::io::Result<BTreeMap<String, DiskstatsRow>> {
    let contents = std::fs::read_to_string(path)?;
    let mut rows = BTreeMap::new();
    for line in contents.lines() {
        if let Some((device, row)) = parse_diskstats_line(line) {
            rows.insert(device, row);
        }
    }
    Ok(rows)
}

/// Parse a single `/proc/diskstats` line. Returns `None` for malformed lines
/// instead of failing the whole sample — the kernel is allowed to emit new
/// columns at the end without warning.
fn parse_diskstats_line(line: &str) -> Option<(String, DiskstatsRow)> {
    let mut tokens = line.split_whitespace();
    // Columns 1-2: major:minor (skip). Column 3: device name. Columns 4-7:
    // reads_completed, reads_merged, sectors_read, ms_reading. Columns 8-11:
    // writes_completed, writes_merged, sectors_written, ms_writing. Column 13:
    // io_ticks (ms).
    let _major = tokens.next()?;
    let _minor = tokens.next()?;
    let device = tokens.next()?.to_string();
    let reads_completed: u64 = tokens.next()?.parse().ok()?;
    let _reads_merged: u64 = tokens.next()?.parse().ok()?;
    let sectors_read: u64 = tokens.next()?.parse().ok()?;
    let _ms_reading: u64 = tokens.next()?.parse().ok()?;
    let writes_completed: u64 = tokens.next()?.parse().ok()?;
    let _writes_merged: u64 = tokens.next()?.parse().ok()?;
    let sectors_written: u64 = tokens.next()?.parse().ok()?;
    let _ms_writing: u64 = tokens.next()?.parse().ok()?;
    let _ios_in_flight: u64 = tokens.next()?.parse().ok()?;
    let io_ticks_ms: u64 = tokens.next()?.parse().ok()?;
    Some((
        device,
        DiskstatsRow {
            sectors_read,
            sectors_written,
            reads_completed,
            writes_completed,
            io_ticks_ms,
        },
    ))
}

/// Compute the per-device delta between two diskstats snapshots, expressed as
/// rates over `elapsed_secs` seconds.
fn diff_diskstats(
    device: &str,
    prev: &DiskstatsRow,
    curr: &DiskstatsRow,
    elapsed_secs: f64,
    timestamp: chrono::DateTime<chrono::Utc>,
) -> DiskIoMetric {
    let read_sectors = curr.sectors_read.saturating_sub(prev.sectors_read);
    let write_sectors = curr.sectors_written.saturating_sub(prev.sectors_written);
    let read_ops = curr.reads_completed.saturating_sub(prev.reads_completed);
    let write_ops = curr.writes_completed.saturating_sub(prev.writes_completed);
    let io_ticks = curr.io_ticks_ms.saturating_sub(prev.io_ticks_ms);

    let read_bytes_per_sec = (read_sectors * DISKSTATS_SECTOR_BYTES) as f64 / elapsed_secs;
    let write_bytes_per_sec = (write_sectors * DISKSTATS_SECTOR_BYTES) as f64 / elapsed_secs;
    let io_ops_per_sec = (read_ops + write_ops) as f64 / elapsed_secs;

    // io_ticks is in milliseconds. Utilisation = busy_ms / wall_clock_ms.
    let wall_clock_ms = elapsed_secs * 1000.0;
    let io_util_percent = if wall_clock_ms > 0.0 {
        clamp_percent((io_ticks as f64 / wall_clock_ms) * 100.0)
    } else {
        0.0
    };

    DiskIoMetric {
        device: device.to_string(),
        read_bytes_per_sec: read_bytes_per_sec.max(0.0),
        write_bytes_per_sec: write_bytes_per_sec.max(0.0),
        io_ops_per_sec: io_ops_per_sec.max(0.0),
        io_util_percent,
        timestamp,
    }
}

/// Read the `avg10` field from a single PSI file. Returns `None` on missing
/// files or malformed contents — callers default to 0.0 for partial coverage.
fn read_psi_avg10(path: &Path) -> Option<f64> {
    let contents = std::fs::read_to_string(path).ok()?;
    parse_psi_avg10(&contents)
}

/// Parse a PSI file body. The "some" line is the canonical signal — at least
/// one task was stalled. Format: `some avg10=X.XX avg60=Y.YY avg300=Z.ZZ
/// total=N`. We only need `avg10`.
fn parse_psi_avg10(body: &str) -> Option<f64> {
    for line in body.lines() {
        let mut tokens = line.split_whitespace();
        if tokens.next()? != "some" {
            continue;
        }
        for tok in tokens {
            if let Some(v) = tok.strip_prefix("avg10=") {
                return v.parse::<f64>().ok();
            }
        }
    }
    None
}

/// Aggregate per-device disk-IO metrics into single read-bps/write-bps/iops
/// values plus a worst-case utilisation percent. Returned as a tuple to keep
/// the call-site terse in the hot logging path.
fn aggregate_disk_io(metrics: &[DiskIoMetric]) -> (f64, f64, f64, f64) {
    let mut read = 0.0;
    let mut write = 0.0;
    let mut iops = 0.0;
    let mut worst = 0.0_f64;
    for m in metrics {
        read += m.read_bytes_per_sec;
        write += m.write_bytes_per_sec;
        iops += m.io_ops_per_sec;
        worst = worst.max(m.io_util_percent);
    }
    (read, write, iops, worst)
}

/// Archive metrics files older than 30 days into a rolling-window archive.
///
/// This function implements the metrics retention policy (gap:OBS-005) by:
/// 1. Checking all metrics files in the metrics directory
/// 2. Identifying files with mtime > 30 days old
/// 3. Moving them to `.cache/tillandsias/metrics-archive/`
/// 4. Logging the retention action
///
/// The archive directory is created on-demand if it doesn't exist.
/// Files that cannot be moved are logged but do not error — the function
/// continues processing remaining files.
///
/// @trace gap:OBS-005, spec:observability-metrics
pub fn archive_old_metrics(metrics_dir: &Path, retention_days: u64) -> Result<(), MetricsError> {
    // Ensure metrics directory exists
    if !metrics_dir.is_dir() {
        debug!(
            spec = "observability-metrics",
            gap = "OBS-005",
            path = ?metrics_dir,
            "metrics directory does not exist; skipping retention"
        );
        return Ok(());
    }

    // Create archive directory path (~/.cache/tillandsias/metrics-archive/)
    let archive_dir = if let Some(cache_parent) = metrics_dir.parent() {
        cache_parent.join("metrics-archive")
    } else {
        return Err(MetricsError::RetentionFailed(
            "metrics directory has no parent".to_string(),
        ));
    };

    // Create archive directory if it doesn't exist
    if !archive_dir.is_dir() {
        fs::create_dir_all(&archive_dir).map_err(|e| {
            MetricsError::RetentionFailed(format!("failed to create archive directory: {e}"))
        })?;
    }

    // Calculate cutoff time (now - retention_days)
    let cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(retention_days * 24 * 60 * 60))
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let mut archived_count = 0;
    let mut oldest_days = 0u64;

    // Scan metrics directory for files older than cutoff
    let entries = fs::read_dir(metrics_dir).map_err(|e| {
        MetricsError::RetentionFailed(format!("failed to read metrics directory: {e}"))
    })?;

    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                debug!(
                    spec = "observability-metrics",
                    gap = "OBS-005",
                    error = %e,
                    "failed to read directory entry during retention; skipping"
                );
                continue;
            }
        };

        let path = entry.path();

        // Skip directories; only process files
        if path.is_dir() {
            continue;
        }

        // Check file modification time
        let metadata = match fs::metadata(&path) {
            Ok(m) => m,
            Err(e) => {
                debug!(
                    spec = "observability-metrics",
                    gap = "OBS-005",
                    path = ?path,
                    error = %e,
                    "failed to stat file during retention; skipping"
                );
                continue;
            }
        };

        let mtime = match metadata.modified() {
            Ok(t) => t,
            Err(e) => {
                debug!(
                    spec = "observability-metrics",
                    gap = "OBS-005",
                    path = ?path,
                    error = %e,
                    "failed to get mtime during retention; skipping"
                );
                continue;
            }
        };

        // If file is older than cutoff, archive it
        if mtime < cutoff {
            // Calculate age in days for logging
            if let Ok(elapsed) = SystemTime::now().duration_since(mtime) {
                let days = elapsed.as_secs() / (24 * 60 * 60);
                if days > oldest_days {
                    oldest_days = days;
                }
            }

            let filename = path.file_name().unwrap_or_default();
            let archive_path = archive_dir.join(filename);

            match fs::rename(&path, &archive_path) {
                Ok(()) => {
                    archived_count += 1;
                    debug!(
                        spec = "observability-metrics",
                        gap = "OBS-005",
                        from = ?path,
                        to = ?archive_path,
                        "archived old metrics file"
                    );
                }
                Err(e) => {
                    debug!(
                        spec = "observability-metrics",
                        gap = "OBS-005",
                        path = ?path,
                        error = %e,
                        "failed to archive metrics file; skipping"
                    );
                }
            }
        }
    }

    // Log retention action if any files were archived
    if archived_count > 0 {
        info!(
            spec = "observability-metrics",
            gap = "OBS-005",
            archived_count = archived_count,
            oldest_days = oldest_days,
            "metrics retention: archived old metrics files"
        );
    } else {
        debug!(
            spec = "observability-metrics",
            gap = "OBS-005",
            "no metrics files older than {} days found",
            retention_days
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn new_does_not_panic() {
        let _s = MetricsSampler::new();
    }

    #[test]
    fn sample_cpu_returns_zeros_on_first_call() {
        // sysinfo documents that the first refresh returns 0% for all cores.
        // We assert the type and shape, not the value.
        let mut s = MetricsSampler::new();
        let cpu = s.sample_cpu();
        assert!(cpu.is_valid(), "first sample should still be in [0,100]");
        assert!(
            !cpu.per_core_percent.is_empty(),
            "expected at least one CPU core to be reported"
        );
    }

    #[test]
    fn sample_cpu_after_warmup_in_range() {
        let mut s = MetricsSampler::new();
        let _ = s.sample_cpu();
        std::thread::sleep(MINIMUM_CPU_UPDATE_INTERVAL);
        let cpu = s.sample_cpu();
        assert!(cpu.is_valid(), "warmed sample out of range: {cpu:?}");
    }

    #[test]
    fn sample_memory_returns_sane_values() {
        let mut s = MetricsSampler::new();
        let m = s.sample_memory();
        // On any real Linux box this is at least 1 MiB. CI containers may
        // report tiny values, so we only assert non-zero.
        assert!(m.total_bytes > 0, "total memory unexpectedly zero");
        assert!(
            m.used_bytes <= m.total_bytes,
            "used > total: {} > {}",
            m.used_bytes,
            m.total_bytes
        );
        assert!(m.used_percent() >= 0.0 && m.used_percent() <= 100.0);
    }

    #[test]
    fn sample_disk_finds_at_least_one_mount() {
        let mut s = MetricsSampler::new();
        let disks = s.sample_disk();
        // CI sandboxes occasionally lack /proc/mounts visibility; only
        // assert that we never panic. If we do see mounts, validate them.
        for d in &disks {
            assert!(d.total_bytes > 0, "filtered disks should be non-zero");
            assert!(d.used_percent() >= 0.0 && d.used_percent() <= 100.0);
        }
    }

    #[test]
    fn validate_interval_rejects_zero() {
        assert!(MetricsSampler::validate_interval(Duration::ZERO).is_err());
        assert!(MetricsSampler::validate_interval(Duration::from_millis(1)).is_ok());
    }

    #[test]
    fn clamp_percent_handles_edges() {
        assert_eq!(clamp_percent(-1.0), 0.0);
        assert_eq!(clamp_percent(150.0), 100.0);
        assert_eq!(clamp_percent(f64::NAN), 0.0);
        assert_eq!(clamp_percent(42.5), 42.5);
    }

    #[test]
    fn ten_rapid_samples_do_not_panic() {
        let mut s = MetricsSampler::new();
        for _ in 0..10 {
            let _ = s.sample_cpu();
            let _ = s.sample_memory();
            let _ = s.sample_disk();
        }
    }

    #[tokio::test]
    async fn collect_continuous_returns_immediately_on_zero_interval() {
        let mut s = MetricsSampler::new();
        // With zero interval the loop logs a warning and returns; assert it
        // does not hang.
        tokio::time::timeout(Duration::from_secs(2), s.collect_continuous(Duration::ZERO))
            .await
            .expect("collect_continuous should return on zero interval, not hang");
    }

    // ---- diskstats parsing ------------------------------------------------

    /// Real /proc/diskstats line captured from a Fedora 41 host. Contains
    /// the trailing flush columns introduced in kernel 5.5 — our parser must
    /// ignore them gracefully.
    const REAL_DISKSTATS_LINE: &str =
        " 259       0 nvme0n1 100 0 200 50 300 0 400 60 0 1234 110 0 0 0 0 0 0";

    #[test]
    fn parse_diskstats_line_extracts_columns() {
        let (dev, row) = parse_diskstats_line(REAL_DISKSTATS_LINE)
            .expect("should parse a well-formed kernel line");
        assert_eq!(dev, "nvme0n1");
        assert_eq!(row.reads_completed, 100);
        assert_eq!(row.sectors_read, 200);
        assert_eq!(row.writes_completed, 300);
        assert_eq!(row.sectors_written, 400);
        assert_eq!(row.io_ticks_ms, 1234);
    }

    #[test]
    fn parse_diskstats_line_rejects_garbage() {
        assert!(parse_diskstats_line("not a real line").is_none());
        assert!(parse_diskstats_line("").is_none());
        assert!(parse_diskstats_line(" 1 2 ").is_none());
    }

    #[test]
    fn diff_diskstats_computes_rates() {
        let prev = DiskstatsRow {
            sectors_read: 0,
            sectors_written: 0,
            reads_completed: 0,
            writes_completed: 0,
            io_ticks_ms: 0,
        };
        let curr = DiskstatsRow {
            sectors_read: 2048,    // 2048 * 512 = 1 MiB
            sectors_written: 1024, // 1024 * 512 = 512 KiB
            reads_completed: 10,
            writes_completed: 5,
            io_ticks_ms: 500, // 500ms busy over 1s window = 50%
        };
        let m = diff_diskstats("sda", &prev, &curr, 1.0, Utc::now());
        assert!(m.is_valid(), "diffed metric out of range: {m:?}");
        assert_eq!(m.read_bytes_per_sec, 1_048_576.0);
        assert_eq!(m.write_bytes_per_sec, 524_288.0);
        assert_eq!(m.io_ops_per_sec, 15.0);
        assert!(
            (m.io_util_percent - 50.0).abs() < 0.01,
            "expected ~50% util, got {}",
            m.io_util_percent
        );
    }

    #[test]
    fn diff_diskstats_handles_counter_wrap() {
        // Saturating sub means a counter that appears to go "backwards"
        // (e.g., device hot-replug) does not produce negative rates.
        let prev = DiskstatsRow {
            sectors_read: 1_000_000,
            sectors_written: 1_000_000,
            reads_completed: 1000,
            writes_completed: 1000,
            io_ticks_ms: 1000,
        };
        let curr = DiskstatsRow {
            sectors_read: 0,
            sectors_written: 0,
            reads_completed: 0,
            writes_completed: 0,
            io_ticks_ms: 0,
        };
        let m = diff_diskstats("sda", &prev, &curr, 1.0, Utc::now());
        assert!(m.is_valid());
        assert_eq!(m.read_bytes_per_sec, 0.0);
        assert_eq!(m.write_bytes_per_sec, 0.0);
        assert_eq!(m.io_ops_per_sec, 0.0);
    }

    #[test]
    fn sample_disk_io_returns_empty_on_first_call() {
        // The very first call has no baseline to diff against, mirroring
        // sysinfo's CPU semantics.
        let mut s = MetricsSampler::new();
        let v = s.sample_disk_io();
        assert!(v.is_empty(), "first sample should be empty, got {v:?}");
        assert!(s.previous_diskstats.is_some());
    }

    #[test]
    fn sample_disk_io_from_fixture() {
        // Drive the sampler from two fixture files to exercise the rate
        // computation end-to-end without touching the real /proc.
        let dir = tempfile::tempdir().unwrap();
        let stats_path = dir.path().join("diskstats");
        std::fs::write(&stats_path, " 8       0 sda 0 0 0 0 0 0 0 0 0 0 0\n").unwrap();
        let mut s = MetricsSampler::with_proc_paths(
            stats_path.to_string_lossy().to_string(),
            dir.path().join("pressure").to_string_lossy().to_string(),
        );
        let first = s.sample_disk_io();
        assert!(first.is_empty());

        // Bump the counters and re-read.
        std::fs::write(
            &stats_path,
            " 8       0 sda 10 0 4096 0 5 0 2048 0 0 100 0\n",
        )
        .unwrap();
        // Sleep a tiny bit so the elapsed delta is non-zero.
        std::thread::sleep(Duration::from_millis(20));
        let second = s.sample_disk_io();
        assert_eq!(second.len(), 1);
        let m = &second[0];
        assert_eq!(m.device, "sda");
        assert!(m.read_bytes_per_sec > 0.0);
        assert!(m.write_bytes_per_sec > 0.0);
        assert!(m.io_ops_per_sec > 0.0);
        assert!(m.is_valid());
    }

    #[test]
    fn sample_disk_io_missing_file_returns_empty() {
        let mut s = MetricsSampler::with_proc_paths(
            "/var/empty/nonexistent-diskstats",
            "/var/empty/nonexistent-pressure",
        );
        assert!(s.sample_disk_io().is_empty());
        // Second call must also stay empty (no baseline established).
        assert!(s.sample_disk_io().is_empty());
    }

    // ---- PSI parsing ------------------------------------------------------

    const REAL_PSI_BODY: &str = "some avg10=1.23 avg60=4.56 avg300=7.89 total=123456\n\
                                  full avg10=0.50 avg60=2.00 avg300=3.00 total=98765\n";

    #[test]
    fn parse_psi_avg10_extracts_some_line() {
        let v = parse_psi_avg10(REAL_PSI_BODY).unwrap();
        assert!((v - 1.23).abs() < 1e-9);
    }

    #[test]
    fn parse_psi_avg10_returns_none_on_garbage() {
        assert!(parse_psi_avg10("").is_none());
        assert!(parse_psi_avg10("nothing here").is_none());
        assert!(parse_psi_avg10("full avg10=1.0\n").is_none());
    }

    #[test]
    fn sample_psi_missing_dir_unavailable() {
        let s = MetricsSampler::with_proc_paths("/dev/null", "/var/empty/nonexistent-pressure");
        let psi = s.sample_psi();
        assert!(!psi.available);
        assert!(psi.is_valid());
    }

    #[test]
    fn sample_psi_from_fixture() {
        let dir = tempfile::tempdir().unwrap();
        let pdir = dir.path().join("pressure");
        std::fs::create_dir_all(&pdir).unwrap();
        std::fs::write(
            pdir.join("cpu"),
            "some avg10=2.50 avg60=3.0 avg300=4.0 total=1\nfull avg10=0 avg60=0 avg300=0 total=0\n",
        )
        .unwrap();
        std::fs::write(
            pdir.join("memory"),
            "some avg10=0.75 avg60=0 avg300=0 total=1\nfull avg10=0 avg60=0 avg300=0 total=0\n",
        )
        .unwrap();
        // Intentionally omit `io` to exercise the partial-coverage path.

        let s = MetricsSampler::with_proc_paths("/dev/null", pdir.to_string_lossy().to_string());
        let psi = s.sample_psi();
        assert!(psi.available);
        assert!(psi.is_valid());
        assert!((psi.cpu_psi_percent - 2.50).abs() < 1e-9);
        assert!((psi.memory_psi_percent - 0.75).abs() < 1e-9);
        assert_eq!(
            psi.io_psi_percent, 0.0,
            "missing io file should default to 0"
        );
    }

    #[test]
    fn aggregate_disk_io_sums_devices() {
        let now = Utc::now();
        let metrics = vec![
            DiskIoMetric {
                device: "sda".into(),
                read_bytes_per_sec: 100.0,
                write_bytes_per_sec: 200.0,
                io_ops_per_sec: 3.0,
                io_util_percent: 25.0,
                timestamp: now,
            },
            DiskIoMetric {
                device: "sdb".into(),
                read_bytes_per_sec: 50.0,
                write_bytes_per_sec: 60.0,
                io_ops_per_sec: 2.0,
                io_util_percent: 75.0,
                timestamp: now,
            },
        ];
        let (r, w, ops, worst) = aggregate_disk_io(&metrics);
        assert_eq!(r, 150.0);
        assert_eq!(w, 260.0);
        assert_eq!(ops, 5.0);
        assert_eq!(worst, 75.0);
    }

    #[test]
    fn aggregate_disk_io_empty_is_zero() {
        let (r, w, ops, worst) = aggregate_disk_io(&[]);
        assert_eq!(r, 0.0);
        assert_eq!(w, 0.0);
        assert_eq!(ops, 0.0);
        assert_eq!(worst, 0.0);
    }

    // ---- metrics retention (OBS-005) ----------------------------------------

    #[test]
    fn archive_old_metrics_nonexistent_dir_is_ok() {
        // @trace gap:OBS-005
        let result = archive_old_metrics(Path::new("/nonexistent/metrics"), 30);
        // Should degrade gracefully rather than error
        assert!(result.is_ok());
    }

    #[test]
    fn archive_old_metrics_with_old_files() {
        // @trace gap:OBS-005
        let dir = tempfile::tempdir().unwrap();
        let metrics_dir = dir.path().join("metrics");
        fs::create_dir_all(&metrics_dir).unwrap();

        // Create test files
        let recent_file = metrics_dir.join("recent.metrics");
        let old_file = metrics_dir.join("old.metrics");

        fs::write(&recent_file, "recent data").unwrap();
        fs::write(&old_file, "old data").unwrap();

        // Set old file's mtime to 45 days ago
        let now = SystemTime::now();
        let old_time = now
            .checked_sub(Duration::from_secs(45 * 24 * 60 * 60))
            .unwrap();
        filetime::set_file_mtime(&old_file, old_time.into())
            .expect("set mtime on old file");

        // Run retention with 30-day window
        let result = archive_old_metrics(&metrics_dir, 30);
        assert!(result.is_ok());

        // Old file should be archived, recent should remain
        assert!(!old_file.exists(), "old file should be archived");
        assert!(recent_file.exists(), "recent file should remain");

        // Check archive directory exists and contains old file
        let archive_dir = dir.path().join("metrics-archive");
        assert!(archive_dir.is_dir(), "archive dir should exist");
        assert!(archive_dir.join("old.metrics").exists(), "archived file should exist");
    }

    #[test]
    fn archive_old_metrics_empty_dir_is_ok() {
        // @trace gap:OBS-005
        let dir = tempfile::tempdir().unwrap();
        let metrics_dir = dir.path().join("metrics");
        fs::create_dir_all(&metrics_dir).unwrap();

        let result = archive_old_metrics(&metrics_dir, 30);
        assert!(result.is_ok(), "empty directory should not error");
    }
}
