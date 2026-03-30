//! Persistent audit log for update events.
//!
//! All update activity — checks, downloads, applies, and errors — is appended
//! to `~/.cache/tillandsias/update.log`. The file is plain text, one entry per
//! line, with an RFC 3339 timestamp prefix. This allows users and developers
//! to verify update history after the fact without relying on in-process logs
//! or running the application again.
//!
//! # Log rotation
//!
//! If `update.log` exceeds 1 MB before a new entry is written, the file is
//! rewritten keeping only the last 100 lines. A rotation marker is inserted so
//! the trimming is visible in the log itself.
//!
//! # Entry format
//!
//! ```text
//! [2026-03-30T14:17:23Z] UPDATE CHECK: v0.1.90 → v0.1.97 available
//! [2026-03-30T14:17:45Z] DOWNLOAD: 80.7 MB from https://github.com/...
//! [2026-03-30T14:17:46Z] APPLIED: v0.1.90 → v0.1.97 (replaced /home/user/.local/bin/tillandsias) SHA256: b65374ea...
//! [2026-03-30T14:17:46Z] ---
//! [2026-03-30T15:00:00Z] UPDATE CHECK: v0.1.97 — already up to date
//! ```

use std::io::Write as _;
use std::path::{Path, PathBuf};

use sha2::Digest;
use tillandsias_core::config::cache_dir;

/// 1 MB threshold — if `update.log` exceeds this, rotate before writing.
const ROTATE_THRESHOLD_BYTES: u64 = 1_048_576;
/// Number of lines to retain after rotation.
const ROTATE_KEEP_LINES: usize = 100;

// ---------------------------------------------------------------------------
// Public helpers
// ---------------------------------------------------------------------------

/// Path to the persistent update audit log.
pub fn log_path() -> PathBuf {
    cache_dir().join("update.log")
}

/// Append a single line to the update log.
///
/// Format written: `[<rfc3339>] <line>\n`
///
/// If the parent directory does not exist it is created. Rotation is checked
/// before writing so the file never grows past `ROTATE_THRESHOLD_BYTES` plus
/// a few bytes for the new entry.
pub fn append_entry(line: &str) {
    let path = log_path();

    // Ensure parent exists.
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    // Rotate if needed.
    rotate_if_needed(&path);

    // Append the new entry.
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(mut file) => {
            let ts = rfc3339_now();
            let _ = writeln!(file, "[{ts}] {line}");
        }
        Err(_) => {
            // Audit log write failures are silently ignored — the log is
            // informational and must never prevent the update from completing.
        }
    }
}

/// Read the last non-empty line from `update.log`, or `None` if the file is
/// absent or empty.
pub fn read_last_entry() -> Option<String> {
    let contents = std::fs::read_to_string(log_path()).ok()?;
    contents
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .map(|l| l.to_string())
}

/// Compute the SHA256 digest of a file and return it as a lowercase hex string.
pub fn sha256_file(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read file for SHA256: {e}"))?;
    let digest = sha2::Sha256::digest(&bytes);
    Ok(hex::encode(digest))
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Rotate `update.log` if it exceeds the threshold.
///
/// Reads all existing lines, keeps the last [`ROTATE_KEEP_LINES`], rewrites
/// the file, then appends a rotation marker. Called inside [`append_entry`]
/// before the new line is written.
fn rotate_if_needed(path: &Path) {
    let size = match std::fs::metadata(path) {
        Ok(m) => m.len(),
        Err(_) => return, // file doesn't exist yet — nothing to rotate
    };

    if size <= ROTATE_THRESHOLD_BYTES {
        return;
    }

    let contents = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let lines: Vec<&str> = contents.lines().collect();
    let keep = if lines.len() > ROTATE_KEEP_LINES {
        &lines[lines.len() - ROTATE_KEEP_LINES..]
    } else {
        &lines[..]
    };

    let ts = rfc3339_now();
    let mut new_contents = keep.join("\n");
    if !new_contents.is_empty() {
        new_contents.push('\n');
    }
    new_contents.push_str(&format!(
        "[{ts}] LOG ROTATED (kept last {ROTATE_KEEP_LINES} entries)\n"
    ));

    let _ = std::fs::write(path, new_contents);
}

/// Return the current UTC time formatted as an RFC 3339 string with
/// second-level precision (e.g., `2026-03-30T14:17:23Z`).
///
/// Uses `std::time::SystemTime` to avoid pulling in a date-time crate.
/// The implementation manually converts the UNIX timestamp to a calendar
/// date, which is sufficient for an audit log.
fn rfc3339_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    unix_secs_to_rfc3339(secs)
}

/// Convert a UNIX timestamp (seconds since epoch) to an RFC 3339 UTC string.
///
/// Handles all dates from 1970 onward. Leap seconds are ignored (standard
/// POSIX behaviour). This avoids a dependency on `chrono` or `time`.
fn unix_secs_to_rfc3339(secs: u64) -> String {
    // Days since Unix epoch
    let days = secs / 86400;
    let time_of_day = secs % 86400;
    let hh = time_of_day / 3600;
    let mm = (time_of_day % 3600) / 60;
    let ss = time_of_day % 60;

    // Convert days since epoch to (year, month, day) using the Gregorian
    // calendar algorithm (proleptic). Valid for dates >= 1970-01-01.
    let (year, month, day) = days_to_ymd(days);

    format!("{year:04}-{month:02}-{day:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

/// Convert days since 1970-01-01 to (year, month, day).
fn days_to_ymd(days: u64) -> (u64, u8, u8) {
    // Algorithm: shift epoch to 1 March 0000 (Gregorian proleptic).
    // Based on Howard Hinnant's date algorithms (public domain).
    let z = days + 719468; // shift to 1 Mar 0000
    let era = z / 146097;
    let doe = z % 146097; // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153; // month of year [0, 11] starting from March
    let d = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // month [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m as u8, d as u8)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3339_epoch() {
        assert_eq!(unix_secs_to_rfc3339(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn rfc3339_known_timestamp() {
        // 2025-03-30T14:17:23Z = 1743344243
        assert_eq!(
            unix_secs_to_rfc3339(1_743_344_243),
            "2025-03-30T14:17:23Z"
        );
        // 2026-03-30T14:17:23Z = 1774880243
        assert_eq!(
            unix_secs_to_rfc3339(1_774_880_243),
            "2026-03-30T14:17:23Z"
        );
    }

    #[test]
    fn rfc3339_leap_year() {
        // 2000-02-29T00:00:00Z = 951782400
        assert_eq!(unix_secs_to_rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn sha256_file_roundtrip() {
        let path = std::env::temp_dir().join("tillandsias-test-sha256.tmp");
        std::fs::write(&path, b"hello world").unwrap();
        let hash = sha256_file(&path).expect("sha256");
        let _ = std::fs::remove_file(&path);
        // SHA256 output is always 32 bytes = 64 hex chars.
        assert_eq!(hash.len(), 64, "expected 64 hex chars, got {}", hash.len());
        assert!(
            hash.chars().all(|c| c.is_ascii_hexdigit()),
            "non-hex char in hash"
        );
        // Deterministic: same input produces same hash.
        let path2 = std::env::temp_dir().join("tillandsias-test-sha256-2.tmp");
        std::fs::write(&path2, b"hello world").unwrap();
        let hash2 = sha256_file(&path2).expect("sha256 2");
        let _ = std::fs::remove_file(&path2);
        assert_eq!(hash, hash2, "SHA256 must be deterministic");
    }
}
