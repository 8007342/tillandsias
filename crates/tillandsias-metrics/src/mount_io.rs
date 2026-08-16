//! Per-mount cumulative I/O counters for hot-path placement decisions.
//!
//! Resolves each queried path to its backing block device via
//! `/proc/self/mountinfo` (longest-prefix mount-point match), then reads the
//! device's cumulative counters from `/proc/diskstats`:
//!
//! - field 4: reads completed (ops)
//! - field 6: sectors read (× 512 = bytes; the kernel always reports
//!   512-byte sectors, see `Documentation/admin-guide/iostats.rst`)
//! - field 8: writes completed (ops)
//! - field 10: sectors written (× 512 = bytes)
//!
//! Counters are for the backing device/partition row in diskstats, so paths
//! sharing a device report that device's combined traffic — this answers
//! "which backing store is hot", the input
//! plan/issues/forge-hot-path-placement-metrics-2026-07-13.md asks for.
//!
//! CRITICAL CONTRACT (spec:observability-metrics): paths whose mount has no
//! diskstats-visible backing device (tmpfs, virtiofs, overlay, …) report
//! `error: "unavailable: <fstype or reason>"` with all counters `None` —
//! never fabricated values.
//!
//! The core ([`sample_mount_io_from_parts`]) takes the mountinfo and
//! diskstats CONTENT as parameters so unit tests drive it from fixture
//! strings; [`sample_mount_io`] is the thin wrapper that reads the real
//! `/proc` files.
//!
//! @trace spec:observability-metrics
//! @trace plan/issues/guest-container-metrics-over-control-wire-2026-07-13.md

use serde::{Deserialize, Serialize};

/// Sector size for `/proc/diskstats` sector counts (always 512 bytes
/// regardless of the physical sector size).
const DISKSTATS_SECTOR_BYTES: u64 = 512;

/// Cumulative I/O counters for the block device backing a filesystem path.
///
/// All counters are cumulative since boot (kernel counters, not rates);
/// consumers difference two snapshots to get rates. `None` means "could not
/// be collected" — see [`MountIoMetric::error`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MountIoMetric {
    /// The queried path (as passed in, not the mount point).
    pub path: String,
    /// Backing device name as it appears in `/proc/diskstats` (e.g.
    /// `nvme0n1p2`, `vdb1`). `None` when no backing device could be resolved.
    pub device: Option<String>,
    /// Cumulative bytes read from the backing device (sectors × 512).
    pub read_bytes: Option<u64>,
    /// Cumulative bytes written to the backing device (sectors × 512).
    pub write_bytes: Option<u64>,
    /// Cumulative read operations completed on the backing device.
    pub read_ops: Option<u64>,
    /// Cumulative write operations completed on the backing device.
    pub write_ops: Option<u64>,
    /// Populated when the path could not be attributed to a diskstats
    /// device (`"unavailable: <fstype or reason>"`) — counters stay `None`,
    /// never fabricated (spec:observability-metrics).
    pub error: Option<String>,
}

impl MountIoMetric {
    fn unavailable(path: impl Into<String>, device: Option<String>, reason: String) -> Self {
        Self {
            path: path.into(),
            device,
            read_bytes: None,
            write_bytes: None,
            read_ops: None,
            write_ops: None,
            error: Some(reason),
        }
    }
}

/// Sample cumulative I/O counters for each queried path.
///
/// Thin production wrapper around [`sample_mount_io_from_parts`]: reads
/// `/proc/self/mountinfo` and `/proc/diskstats`, then delegates. If either
/// file cannot be read, every entry reports that failure in `error`.
pub fn sample_mount_io(paths: &[&str]) -> Vec<MountIoMetric> {
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo");
    let diskstats = std::fs::read_to_string("/proc/diskstats");
    match (mountinfo, diskstats) {
        (Ok(mountinfo), Ok(diskstats)) => sample_mount_io_from_parts(paths, &mountinfo, &diskstats),
        (Err(err), _) => paths
            .iter()
            .map(|p| {
                MountIoMetric::unavailable(
                    *p,
                    None,
                    format!("unavailable: /proc/self/mountinfo unreadable: {err}"),
                )
            })
            .collect(),
        (_, Err(err)) => paths
            .iter()
            .map(|p| {
                MountIoMetric::unavailable(
                    *p,
                    None,
                    format!("unavailable: /proc/diskstats unreadable: {err}"),
                )
            })
            .collect(),
    }
}

/// Pure sampling core: attribute each path to a mount by longest-prefix
/// mount-point match over the given mountinfo content, resolve the mount's
/// backing device, and read its cumulative counters from the given
/// diskstats content.
///
/// Device resolution, in order:
///
/// 1. The mount's `major:minor` looked up in diskstats (real block-backed
///    filesystems, e.g. ext4 on a partition).
/// 2. If the `major:minor` is an anonymous device (btrfs reports `0:NN`)
///    but the mount source is a `/dev/` node, the source's basename is
///    matched against diskstats device names.
/// 3. Otherwise the path is not block-backed (tmpfs, virtiofs, overlay …):
///    `error: "unavailable: <fstype>"`, counters `None`.
pub fn sample_mount_io_from_parts(
    paths: &[&str],
    mountinfo: &str,
    diskstats: &str,
) -> Vec<MountIoMetric> {
    let mounts = parse_mountinfo(mountinfo);
    let devices = parse_diskstats_cumulative(diskstats);
    paths
        .iter()
        .map(|path| sample_one_path(path, &mounts, &devices))
        .collect()
}

fn sample_one_path(
    path: &str,
    mounts: &[MountInfoEntry],
    devices: &[DiskstatsCounters],
) -> MountIoMetric {
    let Some(mount) = longest_prefix_mount(path, mounts) else {
        return MountIoMetric::unavailable(
            path,
            None,
            "unavailable: no mountinfo entry covers this path".to_string(),
        );
    };

    // 1. major:minor match (the authoritative link for block-backed mounts).
    let by_majmin = devices.iter().find(|d| d.majmin == mount.majmin);
    // 2. /dev source basename fallback (btrfs and friends report an
    //    anonymous 0:NN device in mountinfo).
    let resolved = by_majmin.or_else(|| {
        let dev_name = mount.source.strip_prefix("/dev/")?;
        devices.iter().find(|d| d.device == dev_name)
    });

    match resolved {
        Some(d) => MountIoMetric {
            path: path.to_string(),
            device: Some(d.device.clone()),
            read_bytes: Some(d.sectors_read.saturating_mul(DISKSTATS_SECTOR_BYTES)),
            write_bytes: Some(d.sectors_written.saturating_mul(DISKSTATS_SECTOR_BYTES)),
            read_ops: Some(d.reads_completed),
            write_ops: Some(d.writes_completed),
            error: None,
        },
        None => MountIoMetric::unavailable(path, None, format!("unavailable: {}", mount.fstype)),
    }
}

/// One parsed `/proc/self/mountinfo` line — only the fields we need.
#[derive(Debug, Clone, PartialEq, Eq)]
struct MountInfoEntry {
    /// Mount point (field 5), octal escapes decoded.
    mount_point: String,
    /// `major:minor` of the mounted device (field 3).
    majmin: String,
    /// Filesystem type (first field after the `-` separator).
    fstype: String,
    /// Mount source (second field after the `-` separator), e.g. `/dev/vda3`
    /// or `tmpfs`.
    source: String,
}

/// Parse `/proc/self/mountinfo`. Line shape (see `proc(5)`):
///
/// ```text
/// 36 35 98:0 /mnt1 /mnt2 rw,noatime master:1 - ext4 /dev/root rw
/// (1)(2)(3)  (4)   (5)   (6)        (7...)  (-) (9)  (10)     (11)
/// ```
///
/// Optional fields (7) are variable-length and terminated by `-`. Malformed
/// lines are skipped rather than failing the sample.
fn parse_mountinfo(content: &str) -> Vec<MountInfoEntry> {
    content
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let majmin = fields.get(2)?;
            let mount_point = fields.get(4)?;
            let sep = fields.iter().position(|f| *f == "-")?;
            let fstype = fields.get(sep + 1)?;
            let source = fields.get(sep + 2)?;
            Some(MountInfoEntry {
                mount_point: unescape_mountinfo(mount_point),
                majmin: (*majmin).to_string(),
                fstype: (*fstype).to_string(),
                source: (*source).to_string(),
            })
        })
        .collect()
}

/// Decode the octal escapes mountinfo uses for whitespace in paths
/// (`\040` space, `\011` tab, `\012` newline, `\134` backslash).
fn unescape_mountinfo(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let digits: String = chars.clone().take(3).collect();
        if digits.len() == 3
            && let Ok(code) = u8::from_str_radix(&digits, 8)
        {
            out.push(code as char);
            chars.nth(2);
        } else {
            out.push(c);
        }
    }
    out
}

/// Find the mount whose mount point is the longest prefix of `path` on a
/// path-component boundary. Later mountinfo lines win ties (kernel order:
/// a later mount over the same point shadows the earlier one).
fn longest_prefix_mount<'a>(
    path: &str,
    mounts: &'a [MountInfoEntry],
) -> Option<&'a MountInfoEntry> {
    let mut best: Option<&MountInfoEntry> = None;
    for mount in mounts {
        let mp = mount.mount_point.as_str();
        let covers = mp == "/" && path.starts_with('/')
            || path == mp
            || (path.starts_with(mp) && path.as_bytes().get(mp.len()) == Some(&b'/'));
        if !covers {
            continue;
        }
        if best.is_none_or(|b| mp.len() >= b.mount_point.len()) {
            best = Some(mount);
        }
    }
    best
}

/// Cumulative counters for one `/proc/diskstats` row.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DiskstatsCounters {
    /// `major:minor` reassembled from fields 1-2.
    majmin: String,
    /// Device name (field 3).
    device: String,
    /// Field 4: reads completed successfully.
    reads_completed: u64,
    /// Field 6: sectors read (512-byte sectors).
    sectors_read: u64,
    /// Field 8: writes completed successfully.
    writes_completed: u64,
    /// Field 10: sectors written (512-byte sectors).
    sectors_written: u64,
}

/// Parse `/proc/diskstats` keeping the cumulative counters (not rates —
/// `sampler.rs` owns rate derivation for the system-level view). Malformed
/// lines are skipped, mirroring `sampler::parse_diskstats_line`.
fn parse_diskstats_cumulative(content: &str) -> Vec<DiskstatsCounters> {
    content
        .lines()
        .filter_map(|line| {
            let mut tokens = line.split_whitespace();
            let major = tokens.next()?;
            let minor = tokens.next()?;
            let device = tokens.next()?.to_string();
            let reads_completed: u64 = tokens.next()?.parse().ok()?;
            let _reads_merged: u64 = tokens.next()?.parse().ok()?;
            let sectors_read: u64 = tokens.next()?.parse().ok()?;
            let _ms_reading: u64 = tokens.next()?.parse().ok()?;
            let writes_completed: u64 = tokens.next()?.parse().ok()?;
            let _writes_merged: u64 = tokens.next()?.parse().ok()?;
            let sectors_written: u64 = tokens.next()?.parse().ok()?;
            Some(DiskstatsCounters {
                majmin: format!("{major}:{minor}"),
                device,
                reads_completed,
                sectors_read,
                writes_completed,
                sectors_written,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fixture mountinfo: root on ext4 (real partition 252:3), /home on
    /// btrfs (anonymous 0:38, source /dev/vdb1), a nested ext4 mount at
    /// /home/forge (252:16), /opt/cheatsheets on tmpfs, and a space-escaped
    /// mount point.
    const MOUNTINFO: &str = "\
22 1 252:3 / / rw,relatime shared:1 - ext4 /dev/vda3 rw,seclabel\n\
40 22 0:38 / /home rw,relatime shared:15 - btrfs /dev/vdb1 rw,compress=zstd:1\n\
55 40 252:16 / /home/forge rw,relatime shared:20 - ext4 /dev/vdc1 rw\n\
61 22 0:25 / /opt/cheatsheets rw,nosuid,nodev shared:25 - tmpfs tmpfs rw,size=262144k\n\
70 22 252:3 / /mnt/with\\040space rw shared:30 - ext4 /dev/vda3 rw\n";

    /// Fixture diskstats (kernel iostats.rst column order): fields 4/6/8/10
    /// are reads-completed / sectors-read / writes-completed /
    /// sectors-written. vdb1 is present by NAME (btrfs source fallback);
    /// 252:16 (vdc1) is present by major:minor.
    const DISKSTATS: &str = "\
 252       3 vda3 1000 5 2048 30 500 7 4096 40 0 100 70\n\
 253      17 vdb1 77 0 1544 3 11 0 88 1 0 4 4\n\
 252      16 vdc1 9 0 18 1 3 0 10 1 0 2 2\n";

    #[test]
    fn ext4_root_resolves_by_major_minor() {
        let metrics = sample_mount_io_from_parts(&["/var/log/messages"], MOUNTINFO, DISKSTATS);
        assert_eq!(metrics.len(), 1);
        let m = &metrics[0];
        assert_eq!(m.path, "/var/log/messages");
        assert_eq!(m.device.as_deref(), Some("vda3"));
        assert_eq!(m.read_ops, Some(1000));
        assert_eq!(m.read_bytes, Some(2048 * 512));
        assert_eq!(m.write_ops, Some(500));
        assert_eq!(m.write_bytes, Some(4096 * 512));
        assert_eq!(m.error, None);
    }

    #[test]
    fn btrfs_anonymous_device_resolves_via_dev_source_fallback() {
        // /home is btrfs: mountinfo says 0:38 (not in diskstats), but the
        // source /dev/vdb1 matches a diskstats row by name.
        let metrics = sample_mount_io_from_parts(&["/home/user/file"], MOUNTINFO, DISKSTATS);
        let m = &metrics[0];
        assert_eq!(m.device.as_deref(), Some("vdb1"));
        assert_eq!(m.read_ops, Some(77));
        assert_eq!(m.read_bytes, Some(1544 * 512));
        assert_eq!(m.write_ops, Some(11));
        assert_eq!(m.write_bytes, Some(88 * 512));
        assert_eq!(m.error, None);
    }

    #[test]
    fn nested_mount_wins_longest_prefix_match() {
        // /home/forge/src must attribute to the /home/forge mount (vdc1),
        // not /home (vdb1) and not / (vda3).
        let metrics = sample_mount_io_from_parts(&["/home/forge/src"], MOUNTINFO, DISKSTATS);
        let m = &metrics[0];
        assert_eq!(m.device.as_deref(), Some("vdc1"));
        assert_eq!(m.read_ops, Some(9));
        assert_eq!(m.write_ops, Some(3));
        assert_eq!(m.error, None);

        // A sibling that merely shares the string prefix "/home/forge"
        // without a component boundary must NOT match the nested mount.
        let metrics = sample_mount_io_from_parts(&["/home/forgery"], MOUNTINFO, DISKSTATS);
        assert_eq!(metrics[0].device.as_deref(), Some("vdb1"));
    }

    #[test]
    fn tmpfs_reports_unavailable_never_fabricated_values() {
        let metrics =
            sample_mount_io_from_parts(&["/opt/cheatsheets/languages"], MOUNTINFO, DISKSTATS);
        let m = &metrics[0];
        assert_eq!(m.device, None);
        assert_eq!(m.read_bytes, None);
        assert_eq!(m.write_bytes, None);
        assert_eq!(m.read_ops, None);
        assert_eq!(m.write_ops, None);
        assert_eq!(m.error.as_deref(), Some("unavailable: tmpfs"));
    }

    #[test]
    fn no_covering_mount_reports_unavailable() {
        // Mountinfo without a root mount: an uncovered path is an error,
        // not a silent zero.
        let no_root = "40 22 0:38 / /data rw - btrfs /dev/vdb1 rw\n";
        let metrics = sample_mount_io_from_parts(&["/elsewhere"], no_root, DISKSTATS);
        let m = &metrics[0];
        assert_eq!(m.device, None);
        assert!(m.error.as_deref().unwrap().starts_with("unavailable:"));
    }

    #[test]
    fn escaped_mount_point_is_decoded() {
        let metrics = sample_mount_io_from_parts(&["/mnt/with space/f"], MOUNTINFO, DISKSTATS);
        assert_eq!(metrics[0].device.as_deref(), Some("vda3"));
        assert_eq!(metrics[0].error, None);
    }

    #[test]
    fn exact_mount_point_path_matches() {
        let metrics = sample_mount_io_from_parts(&["/home/forge"], MOUNTINFO, DISKSTATS);
        assert_eq!(metrics[0].device.as_deref(), Some("vdc1"));
    }

    #[test]
    fn mount_io_metric_serde_roundtrip() {
        let m = MountIoMetric {
            path: "/opt/cheatsheets".into(),
            device: None,
            read_bytes: None,
            write_bytes: None,
            read_ops: None,
            write_ops: None,
            error: Some("unavailable: tmpfs".into()),
        };
        let json = serde_json::to_string(&m).unwrap();
        let back: MountIoMetric = serde_json::from_str(&json).unwrap();
        assert_eq!(m, back);
    }
}
