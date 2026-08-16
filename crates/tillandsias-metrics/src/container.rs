//! Per-container CPU / memory / blkio sampling from cgroup v2.
//!
//! Guest headless serves these samples over the vsock control wire so host
//! trays can attribute resource usage to individual service containers
//! (proxy, cache, router, vault, git-mirror, forge lanes) without jumping the
//! VM boundary.
//!
//! Container name → id resolution comes from `podman ps --format json`; the
//! cgroup files are then read from the container's systemd scope:
//!
//! - rootful podman: `<cgroup_root>/machine.slice/libpod-<id>.scope/`
//! - rootless podman: `<cgroup_root>/user.slice/user-<uid>.slice/`
//!   `user@<uid>.service/user.slice/libpod-<id>.scope/`
//!
//! The uid in the rootless parent is not known in advance, so the resolver
//! scans `user.slice` for `user-*.slice/user@*.service/user.slice/` and
//! probes each for `libpod-<id>.scope` (the documented fallback when the
//! rootful probe misses).
//!
//! CRITICAL CONTRACT (spec:observability-metrics): a collection failure
//! populates [`ContainerMetric::error`] and leaves the affected values
//! `None` — a fabricated healthy zero is never emitted. An empty `io.stat`
//! is NOT a failure: it is the kernel's real answer that no I/O has been
//! charged to the cgroup yet, and yields `Some(0)` sums.
//!
//! The sampling core ([`sample_containers_from_ps_json`]) is pure with
//! respect to process spawning: it takes the `podman ps` JSON and the cgroup
//! root path as parameters so unit tests can drive it from fixture trees.
//! [`sample_containers`] is the thin production wrapper that shells out.
//!
//! @trace spec:observability-metrics
//! @trace plan/issues/guest-container-metrics-over-control-wire-2026-07-13.md

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use tillandsias_podman::{OperationKind, podman_cmd_sync};

/// Production cgroup v2 mount point.
const CGROUP_ROOT: &str = "/sys/fs/cgroup";

/// A per-container resource sample read from cgroup v2 counters.
///
/// All counter fields are cumulative kernel counters, not rates:
///
/// - `cpu_usec`: total CPU time charged to the cgroup, microseconds
///   (`cpu.stat` → `usage_usec`).
/// - `memory_current_bytes`: current memory footprint, bytes
///   (`memory.current`).
/// - `blkio_*`: block I/O charged to the cgroup, summed across all devices
///   listed in `io.stat` (`rbytes`/`wbytes` in bytes, `rios`/`wios` in
///   operations).
///
/// `None` means "could not be collected" — see [`ContainerMetric::error`]
/// for why. Values and errors can coexist: a readable `cpu.stat` next to an
/// unreadable `memory.current` yields `cpu_usec: Some(..)`,
/// `memory_current_bytes: None`, and a populated `error`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContainerMetric {
    /// Container name as reported by `podman ps` (first entry in `Names`).
    pub name: String,
    /// Cumulative CPU usage in microseconds (`cpu.stat` `usage_usec`).
    pub cpu_usec: Option<u64>,
    /// Current memory usage in bytes (`memory.current`).
    pub memory_current_bytes: Option<u64>,
    /// Cumulative bytes read, summed across devices (`io.stat` `rbytes`).
    pub blkio_read_bytes: Option<u64>,
    /// Cumulative bytes written, summed across devices (`io.stat` `wbytes`).
    pub blkio_write_bytes: Option<u64>,
    /// Cumulative read operations, summed across devices (`io.stat` `rios`).
    pub blkio_read_ops: Option<u64>,
    /// Cumulative write operations, summed across devices (`io.stat` `wios`).
    pub blkio_write_ops: Option<u64>,
    /// Populated when any part of the collection failed. Affected values are
    /// `None` — never fabricated zeros (spec:observability-metrics).
    pub error: Option<String>,
}

impl ContainerMetric {
    /// A sample that carries only a collection failure: every value `None`,
    /// `error` populated. This is what a total failure looks like on the
    /// wire — visibly broken, never silently healthy.
    fn error_only(name: impl Into<String>, error: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            cpu_usec: None,
            memory_current_bytes: None,
            blkio_read_bytes: None,
            blkio_write_bytes: None,
            blkio_read_ops: None,
            blkio_write_ops: None,
            error: Some(error.into()),
        }
    }
}

/// One row of `podman ps --format json` — only the fields we need.
/// Matches the modern podman JSON shape (PascalCase keys, `Names` array),
/// the same shape `tillandsias-podman`'s `PodmanPsEntry` parses.
#[derive(Debug, Deserialize)]
struct PsRow {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Names")]
    names: Vec<String>,
}

/// Sample every container listed in `podman ps --format json`.
///
/// Thin production wrapper around [`sample_containers_from_ps_json`]: shells
/// out to `podman`, then samples against the real `/sys/fs/cgroup`.
///
/// Failure surface: if `podman` cannot be spawned or exits non-zero, the
/// returned vector contains a single sentinel entry (`name: "podman"`) whose
/// `error` explains the failure — the caller still ships an error over the
/// wire instead of an empty "all healthy" list. A legitimately empty
/// container list returns an empty vector.
pub fn sample_containers() -> Vec<ContainerMetric> {
    // Route through the shared bounded layer (714-4r6w): a direct
    // std::process spawn can wait on a wedged podman forever, and the
    // sync-budget gate counts exactly this shape.
    let output = match podman_cmd_sync()
        .args(["ps", "--format", "json"])
        .output_bounded(OperationKind::Container.default_budget())
    {
        Ok(output) => output,
        Err(err) => {
            return vec![ContainerMetric::error_only(
                "podman",
                format!("spawning `podman ps --format json` failed: {err}"),
            )];
        }
    };
    if !output.status.success() {
        return vec![ContainerMetric::error_only(
            "podman",
            format!(
                "`podman ps --format json` exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        )];
    }
    let ps_json = String::from_utf8_lossy(&output.stdout);
    sample_containers_from_ps_json(&ps_json, Path::new(CGROUP_ROOT))
}

/// Pure sampling core: resolve container name → id from the given
/// `podman ps --format json` output, then sample each container's cgroup v2
/// counters under `cgroup_root`.
///
/// `cgroup_root` is `/sys/fs/cgroup` in production and a tempfile fixture
/// tree in unit tests (path injection — no live podman or cgroupfs needed).
///
/// A JSON parse failure returns a single sentinel entry (`name: "podman"`)
/// with `error` populated, mirroring [`sample_containers`]'s failure surface.
pub fn sample_containers_from_ps_json(ps_json: &str, cgroup_root: &Path) -> Vec<ContainerMetric> {
    let rows: Vec<PsRow> = match serde_json::from_str(ps_json) {
        Ok(rows) => rows,
        Err(err) => {
            return vec![ContainerMetric::error_only(
                "podman",
                format!("parsing `podman ps --format json` output failed: {err}"),
            )];
        }
    };
    rows.iter()
        .map(|row| {
            let name = row
                .names
                .first()
                .cloned()
                .unwrap_or_else(|| short_id(&row.id).to_string());
            sample_one_container(&name, &row.id, cgroup_root)
        })
        .collect()
}

/// First 12 hex chars of a container id (podman's display convention), used
/// as the display name when `Names` is unexpectedly empty.
fn short_id(id: &str) -> &str {
    &id[..id.len().min(12)]
}

/// Sample a single container's cgroup scope. Missing scope → all values
/// `None` with `error` naming both probed parents.
fn sample_one_container(name: &str, id: &str, cgroup_root: &Path) -> ContainerMetric {
    match resolve_scope_dir(cgroup_root, id) {
        Some(scope_dir) => sample_scope_dir(name, &scope_dir),
        None => ContainerMetric::error_only(
            name,
            format!(
                "cgroup scope libpod-{id}.scope not found under machine.slice \
                 (rootful) or user.slice/user-*.slice/user@*.service/user.slice \
                 (rootless) below {}",
                cgroup_root.display()
            ),
        ),
    }
}

/// Locate `libpod-<id>.scope` under the two known cgroup v2 parents.
///
/// 1. Rootful podman (systemd machine slice):
///    `<root>/machine.slice/libpod-<id>.scope`
/// 2. Rootless podman (systemd user session): the scope lives under
///    `<root>/user.slice/user-<uid>.slice/user@<uid>.service/user.slice/`.
///    The uid is not known here, so this is a two-level directory scan
///    (`user-*.slice`, then `user@*.service`) rather than a fixed path —
///    the documented glob fallback.
fn resolve_scope_dir(cgroup_root: &Path, id: &str) -> Option<PathBuf> {
    let scope = format!("libpod-{id}.scope");

    let rootful = cgroup_root.join("machine.slice").join(&scope);
    if rootful.is_dir() {
        return Some(rootful);
    }

    let user_slice = cgroup_root.join("user.slice");
    let user_dirs = fs::read_dir(&user_slice).ok()?;
    for user_dir in user_dirs.flatten() {
        let dir_name = user_dir.file_name();
        let dir_name = dir_name.to_string_lossy();
        if !(dir_name.starts_with("user-") && dir_name.ends_with(".slice")) {
            continue;
        }
        let Ok(service_dirs) = fs::read_dir(user_dir.path()) else {
            continue;
        };
        for service_dir in service_dirs.flatten() {
            let service_name = service_dir.file_name();
            let service_name = service_name.to_string_lossy();
            if !(service_name.starts_with("user@") && service_name.ends_with(".service")) {
                continue;
            }
            let candidate = service_dir.path().join("user.slice").join(&scope);
            if candidate.is_dir() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Read `cpu.stat`, `memory.current`, and `io.stat` from a resolved scope
/// directory. Each file degrades independently: an unreadable file leaves
/// its values `None` and appends to `error`; the other files still report.
fn sample_scope_dir(name: &str, scope_dir: &Path) -> ContainerMetric {
    let mut errors: Vec<String> = Vec::new();

    let cpu_usec = match fs::read_to_string(scope_dir.join("cpu.stat")) {
        Ok(body) => match parse_cpu_stat_usage_usec(&body) {
            Some(usec) => Some(usec),
            None => {
                errors.push("cpu.stat: no parseable usage_usec line".to_string());
                None
            }
        },
        Err(err) => {
            errors.push(format!("cpu.stat: {err}"));
            None
        }
    };

    let memory_current_bytes = match fs::read_to_string(scope_dir.join("memory.current")) {
        Ok(body) => match body.trim().parse::<u64>() {
            Ok(bytes) => Some(bytes),
            Err(_) => {
                errors.push(format!("memory.current: not an integer: {:?}", body.trim()));
                None
            }
        },
        Err(err) => {
            errors.push(format!("memory.current: {err}"));
            None
        }
    };

    let io_totals = match fs::read_to_string(scope_dir.join("io.stat")) {
        Ok(body) => match parse_io_stat_totals(&body) {
            Ok(totals) => Some(totals),
            Err(err) => {
                errors.push(format!("io.stat: {err}"));
                None
            }
        },
        Err(err) => {
            errors.push(format!("io.stat: {err}"));
            None
        }
    };
    let (blkio_read_bytes, blkio_write_bytes, blkio_read_ops, blkio_write_ops) = match io_totals {
        Some(t) => (Some(t.rbytes), Some(t.wbytes), Some(t.rios), Some(t.wios)),
        None => (None, None, None, None),
    };

    ContainerMetric {
        name: name.to_string(),
        cpu_usec,
        memory_current_bytes,
        blkio_read_bytes,
        blkio_write_bytes,
        blkio_read_ops,
        blkio_write_ops,
        error: if errors.is_empty() {
            None
        } else {
            Some(errors.join("; "))
        },
    }
}

/// Extract `usage_usec` from a cgroup v2 `cpu.stat` body, e.g.:
///
/// ```text
/// usage_usec 24487858
/// user_usec 18234012
/// system_usec 6253846
/// ```
fn parse_cpu_stat_usage_usec(body: &str) -> Option<u64> {
    body.lines().find_map(|line| {
        let mut tokens = line.split_whitespace();
        match (tokens.next(), tokens.next()) {
            (Some("usage_usec"), Some(value)) => value.parse().ok(),
            _ => None,
        }
    })
}

/// Per-cgroup io totals summed across every device line of `io.stat`.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct IoStatTotals {
    rbytes: u64,
    wbytes: u64,
    rios: u64,
    wios: u64,
}

/// Sum `rbytes` / `wbytes` / `rios` / `wios` across every device line of a
/// cgroup v2 `io.stat` body, e.g.:
///
/// ```text
/// 8:16 rbytes=1459200 wbytes=314773504 rios=192 wios=353 dbytes=0 dios=0
/// 8:0 rbytes=90430464 wbytes=299008000 rios=8950 wios=1252 dbytes=0 dios=0
/// ```
///
/// An empty body is a valid read (no I/O charged yet) and returns zero
/// totals — that is a real kernel answer, not a fabrication. A line whose
/// counters cannot be parsed is a collection failure (`Err`), so the caller
/// reports `None` + error instead of a partial (and therefore wrong) sum.
fn parse_io_stat_totals(body: &str) -> Result<IoStatTotals, String> {
    let mut totals = IoStatTotals::default();
    for line in body.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut tokens = line.split_whitespace();
        let device = tokens
            .next()
            .ok_or_else(|| format!("malformed line: {line:?}"))?;
        let mut seen_any_counter = false;
        for token in tokens {
            let Some((key, value)) = token.split_once('=') else {
                return Err(format!("device {device}: malformed token {token:?}"));
            };
            let target = match key {
                "rbytes" => &mut totals.rbytes,
                "wbytes" => &mut totals.wbytes,
                "rios" => &mut totals.rios,
                "wios" => &mut totals.wios,
                // Discard counters we do not report (dbytes, dios, future
                // additions) — but they still must parse as integers.
                _ => {
                    value
                        .parse::<u64>()
                        .map_err(|_| format!("device {device}: {key}={value:?} not an integer"))?;
                    continue;
                }
            };
            let parsed: u64 = value
                .parse()
                .map_err(|_| format!("device {device}: {key}={value:?} not an integer"))?;
            *target = target.saturating_add(parsed);
            seen_any_counter = true;
        }
        if !seen_any_counter {
            return Err(format!(
                "device {device}: no rbytes/wbytes/rios/wios counters"
            ));
        }
    }
    Ok(totals)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// Realistic cgroup v2 cpu.stat body (Fedora 41 guest, cgroup v2).
    const CPU_STAT: &str = "usage_usec 24487858\nuser_usec 18234012\nsystem_usec 6253846\n\
        nr_periods 0\nnr_throttled 0\nthrottled_usec 0\n";
    /// Realistic io.stat with two devices; totals must be SUMS across both.
    const IO_STAT_TWO_DEVICES: &str = "8:16 rbytes=1459200 wbytes=314773504 rios=192 wios=353 dbytes=0 dios=0\n\
        8:0 rbytes=90430464 wbytes=299008000 rios=8950 wios=1252 dbytes=0 dios=0\n";

    const CONTAINER_ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn ps_json_for(name: &str, id: &str) -> String {
        format!(r#"[{{"Id":"{id}","Names":["{name}"],"State":"running"}}]"#)
    }

    fn write_scope(scope_dir: &Path, cpu_stat: &str, memory_current: &str, io_stat: &str) {
        fs::create_dir_all(scope_dir).unwrap();
        fs::write(scope_dir.join("cpu.stat"), cpu_stat).unwrap();
        fs::write(scope_dir.join("memory.current"), memory_current).unwrap();
        fs::write(scope_dir.join("io.stat"), io_stat).unwrap();
    }

    #[test]
    fn samples_rootful_machine_slice_scope() {
        let root = TempDir::new().unwrap();
        let scope = root
            .path()
            .join("machine.slice")
            .join(format!("libpod-{CONTAINER_ID}.scope"));
        write_scope(&scope, CPU_STAT, "104857600\n", IO_STAT_TWO_DEVICES);

        let metrics =
            sample_containers_from_ps_json(&ps_json_for("proxy", CONTAINER_ID), root.path());
        assert_eq!(metrics.len(), 1);
        let m = &metrics[0];
        assert_eq!(m.name, "proxy");
        assert_eq!(m.cpu_usec, Some(24_487_858));
        assert_eq!(m.memory_current_bytes, Some(104_857_600));
        // Sums across BOTH io.stat device lines.
        assert_eq!(m.blkio_read_bytes, Some(1_459_200 + 90_430_464));
        assert_eq!(m.blkio_write_bytes, Some(314_773_504 + 299_008_000));
        assert_eq!(m.blkio_read_ops, Some(192 + 8_950));
        assert_eq!(m.blkio_write_ops, Some(353 + 1_252));
        assert_eq!(m.error, None);
    }

    #[test]
    fn samples_rootless_user_slice_scope_via_glob_fallback() {
        let root = TempDir::new().unwrap();
        let scope = root
            .path()
            .join("user.slice")
            .join("user-1000.slice")
            .join("user@1000.service")
            .join("user.slice")
            .join(format!("libpod-{CONTAINER_ID}.scope"));
        write_scope(&scope, CPU_STAT, "2048\n", "");

        let metrics =
            sample_containers_from_ps_json(&ps_json_for("cache", CONTAINER_ID), root.path());
        assert_eq!(metrics.len(), 1);
        let m = &metrics[0];
        assert_eq!(m.name, "cache");
        assert_eq!(m.cpu_usec, Some(24_487_858));
        assert_eq!(m.memory_current_bytes, Some(2048));
        // Empty io.stat is the kernel's real "no I/O charged yet" answer.
        assert_eq!(m.blkio_read_bytes, Some(0));
        assert_eq!(m.blkio_write_bytes, Some(0));
        assert_eq!(m.blkio_read_ops, Some(0));
        assert_eq!(m.blkio_write_ops, Some(0));
        assert_eq!(m.error, None);
    }

    #[test]
    fn missing_scope_reports_error_and_all_values_none() {
        let root = TempDir::new().unwrap();
        fs::create_dir_all(root.path().join("machine.slice")).unwrap();

        let metrics =
            sample_containers_from_ps_json(&ps_json_for("vault", CONTAINER_ID), root.path());
        assert_eq!(metrics.len(), 1);
        let m = &metrics[0];
        assert_eq!(m.name, "vault");
        assert_eq!(m.cpu_usec, None);
        assert_eq!(m.memory_current_bytes, None);
        assert_eq!(m.blkio_read_bytes, None);
        assert_eq!(m.blkio_write_bytes, None);
        assert_eq!(m.blkio_read_ops, None);
        assert_eq!(m.blkio_write_ops, None);
        let error = m.error.as_deref().expect("missing scope must set error");
        assert!(error.contains("libpod-"), "error names the scope: {error}");
    }

    #[test]
    fn unreadable_memory_current_degrades_that_field_only() {
        let root = TempDir::new().unwrap();
        let scope = root
            .path()
            .join("machine.slice")
            .join(format!("libpod-{CONTAINER_ID}.scope"));
        write_scope(&scope, CPU_STAT, "not-a-number\n", IO_STAT_TWO_DEVICES);

        let metrics =
            sample_containers_from_ps_json(&ps_json_for("router", CONTAINER_ID), root.path());
        let m = &metrics[0];
        // cpu + io still report; memory is None with an error — never a
        // fabricated healthy zero (spec:observability-metrics).
        assert_eq!(m.cpu_usec, Some(24_487_858));
        assert_eq!(m.memory_current_bytes, None);
        assert_eq!(m.blkio_read_bytes, Some(1_459_200 + 90_430_464));
        assert!(m.error.as_deref().unwrap().contains("memory.current"));
    }

    #[test]
    fn malformed_io_stat_line_is_error_not_partial_sum() {
        let root = TempDir::new().unwrap();
        let scope = root
            .path()
            .join("machine.slice")
            .join(format!("libpod-{CONTAINER_ID}.scope"));
        write_scope(
            &scope,
            CPU_STAT,
            "1\n",
            "8:0 rbytes=100 wbytes=200 rios=1 wios=2\n8:16 rbytes=garbage wbytes=1 rios=1 wios=1\n",
        );

        let metrics =
            sample_containers_from_ps_json(&ps_json_for("forge", CONTAINER_ID), root.path());
        let m = &metrics[0];
        assert_eq!(m.blkio_read_bytes, None, "no partial (wrong) sums");
        assert_eq!(m.blkio_write_bytes, None);
        assert_eq!(m.blkio_read_ops, None);
        assert_eq!(m.blkio_write_ops, None);
        assert!(m.error.as_deref().unwrap().contains("io.stat"));
    }

    #[test]
    fn unparseable_ps_json_yields_sentinel_error_entry() {
        let root = TempDir::new().unwrap();
        let metrics = sample_containers_from_ps_json("this is not json", root.path());
        assert_eq!(metrics.len(), 1);
        let m = &metrics[0];
        assert_eq!(m.name, "podman");
        assert_eq!(m.cpu_usec, None);
        assert!(m.error.as_deref().unwrap().contains("parsing"));
    }

    #[test]
    fn empty_ps_json_yields_empty_list() {
        let root = TempDir::new().unwrap();
        let metrics = sample_containers_from_ps_json("[]", root.path());
        assert!(metrics.is_empty());
    }

    #[test]
    fn parse_cpu_stat_extracts_usage_usec() {
        assert_eq!(parse_cpu_stat_usage_usec(CPU_STAT), Some(24_487_858));
        assert_eq!(parse_cpu_stat_usage_usec("user_usec 5\n"), None);
        assert_eq!(parse_cpu_stat_usage_usec(""), None);
    }

    #[test]
    fn parse_io_stat_sums_across_devices() {
        let totals = parse_io_stat_totals(IO_STAT_TWO_DEVICES).unwrap();
        assert_eq!(totals.rbytes, 1_459_200 + 90_430_464);
        assert_eq!(totals.wbytes, 314_773_504 + 299_008_000);
        assert_eq!(totals.rios, 192 + 8_950);
        assert_eq!(totals.wios, 353 + 1_252);
    }

    #[test]
    fn parse_io_stat_empty_is_zero_totals() {
        assert_eq!(parse_io_stat_totals("").unwrap(), IoStatTotals::default());
    }

    #[test]
    fn container_metric_serde_roundtrip() {
        let m = ContainerMetric {
            name: "git-mirror".into(),
            cpu_usec: Some(1),
            memory_current_bytes: None,
            blkio_read_bytes: Some(2),
            blkio_write_bytes: Some(3),
            blkio_read_ops: Some(4),
            blkio_write_ops: Some(5),
            error: Some("memory.current: permission denied".into()),
        };
        let json = serde_json::to_string(&m).unwrap();
        let back: ContainerMetric = serde_json::from_str(&json).unwrap();
        assert_eq!(m, back);
    }
}
