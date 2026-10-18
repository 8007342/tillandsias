//! The on-demand image build breaker (order 1776-brk3).
//!
//! @trace order:1776-brk3, openspec/changes/on-demand-image-ensure/design.md
//!
//! Nothing used to remember a failed on-demand build, so every launch, click
//! and MCP call rebuilt an image whose inputs could not build (a stalled
//! index, a vanished pin, a full disk), costing minutes of host CPU each
//! time. A failure now leaves a marker keyed on (image, source digest):
//!
//! - while the marker's digest matches the image's current inputs, an ensure
//!   refuses within seconds with the first cause, the log and the remedy;
//! - the marker is ignored and removed once any input changes the digest;
//! - the ensure that hit the failure retries it in the background, there and
//!   then, [`RETRY_BUDGET`] times on exponential backoff
//!   ([`retry_delay_ms`]); while it waits the marker carries the retry time,
//!   which callers report to agents as "busy, try again in N" and never to
//!   the tray user as a failure;
//! - when the budget is spent the image is declared failed
//!   (`next_retry_at: None`) and every ensure refuses fast;
//! - a successful build (on demand or `--init`) and
//!   `tillandsias --retry-image <name>` clear it. There is no tray "Retry
//!   build" item (operator ruling, 2026-10-17).
//!
//! Pure file I/O under one directory; no podman. The directory is
//! `init_cache_dir()/image-ensure-failures`, which survives a reboot on
//! purpose: a stale lock dies with the session, known-bad inputs do not.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub(crate) const MARKER_DIR: &str = "image-ensure-failures";

/// Automatic background retries after a failed build before the image is
/// declared failed (operator ruling 2026-10-17: "a couple").
pub(crate) const RETRY_BUDGET: u32 = 2;

/// The first retry's delay; each later one is four times the last.
const RETRY_BASE_MS: u64 = 30_000;

/// Fixtures shorten the backoff (milliseconds) so a budget runs in seconds.
pub(crate) const RETRY_BASE_ENV: &str = "TILLANDSIAS_IMAGE_RETRY_BASE_MS";

pub(crate) fn retry_base_ms() -> u64 {
    std::env::var(RETRY_BASE_ENV)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(RETRY_BASE_MS)
}

/// Delay before automatic retry `retry` (1-based): base, 4×base, 16×base…
pub(crate) fn retry_delay_ms(retry: u32, base_ms: u64) -> u64 {
    base_ms.saturating_mul(4u64.saturating_pow(retry.saturating_sub(1)))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct FailureMarker {
    pub image: String,
    pub source_digest: String,
    pub attempts: u32,
    pub first_failed_at: u64,
    pub last_failed_at: u64,
    /// `Some`: a background retry is scheduled then (the build is still
    /// being attempted). `None`: the retry budget is spent; the image is
    /// declared failed until its inputs change or an operator retries.
    pub next_retry_at: Option<u64>,
    /// The first failure's cause (`describe_image_ensure_failure` or the
    /// build error), kept so a later refusal names what went wrong.
    pub cause: String,
    pub log: String,
}

/// What an ensure does with the marker it found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Breaker {
    /// No marker: decide as usual.
    Proceed,
    /// A marker for OTHER inputs: remove it, then decide as usual.
    InputsChanged,
    /// A marker for these inputs with a retry still scheduled. Seen under
    /// the image lock, so the ensure that scheduled it is gone (killed
    /// mid-backoff): resume its budget.
    Resume,
    /// These inputs were declared failed: refuse without building.
    Refuse,
}

pub(crate) fn decide(marker: Option<&FailureMarker>, source_digest: &str) -> Breaker {
    let Some(m) = marker else {
        return Breaker::Proceed;
    };
    if m.source_digest != source_digest {
        return Breaker::InputsChanged;
    }
    match m.next_retry_at {
        Some(_) => Breaker::Resume,
        None => Breaker::Refuse,
    }
}

/// Seconds an agent should wait before asking again while a background
/// retry is scheduled ("busy, try again in N"); `None` when none is.
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub(crate) fn busy_retry_after_secs(m: &FailureMarker, now: u64) -> Option<u64> {
    m.next_retry_at.map(|t| t.saturating_sub(now).max(1))
}

fn safe_name(image: &str) -> bool {
    !image.is_empty()
        && image.len() <= 64
        && image
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

pub(crate) fn marker_path(dir: &Path, image: &str) -> Option<PathBuf> {
    safe_name(image).then(|| dir.join(format!("{image}.json")))
}

/// The marker for `image`, or `None` when there is none or it is unreadable
/// (an unreadable marker must never wedge an image: it is treated as absent).
pub(crate) fn load(dir: &Path, image: &str) -> Option<FailureMarker> {
    let text = std::fs::read_to_string(marker_path(dir, image)?).ok()?;
    serde_json::from_str::<FailureMarker>(&text)
        .ok()
        .filter(|m| m.image == image)
}

/// Record a failed build of `image` at `source_digest`, with the background
/// retry scheduled at `next_retry_at` (`None`: declared failed). A marker for
/// the same digest counts one more attempt and keeps its first cause; any
/// other starts again at one.
pub(crate) fn record(
    dir: &Path,
    image: &str,
    source_digest: &str,
    cause: &str,
    log: &str,
    now: u64,
    next_retry_at: Option<u64>,
) -> Result<FailureMarker, String> {
    let path = marker_path(dir, image).ok_or("image-ensure marker: unsafe image name")?;
    let prev = load(dir, image).filter(|m| m.source_digest == source_digest);
    let attempts = prev.as_ref().map_or(0, |m| m.attempts).saturating_add(1);
    let marker = FailureMarker {
        image: image.to_string(),
        source_digest: source_digest.to_string(),
        attempts,
        first_failed_at: prev.as_ref().map_or(now, |m| m.first_failed_at),
        last_failed_at: now,
        next_retry_at,
        cause: prev
            .as_ref()
            .map_or_else(|| cause.to_string(), |m| m.cause.clone()),
        log: log.to_string(),
    };
    std::fs::create_dir_all(dir).map_err(|e| format!("image-ensure marker dir: {e}"))?;
    let body = serde_json::to_string_pretty(&marker).map_err(|e| e.to_string())?;
    // Write-then-rename, so a reader never sees half a marker.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("image-ensure marker write: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("image-ensure marker rename: {e}"))?;
    Ok(marker)
}

/// Remove `image`'s marker. `Ok(true)` when one existed.
pub(crate) fn clear(dir: &Path, image: &str) -> Result<bool, String> {
    let Some(path) = marker_path(dir, image) else {
        return Ok(false);
    };
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("image-ensure marker remove: {e}")),
    }
}

/// Every image with a marker, sorted (`--retry-image`'s usage line).
pub(crate) fn list(dir: &Path) -> Vec<FailureMarker> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<FailureMarker> = rd
        .filter_map(Result::ok)
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let image = name.strip_suffix(".json")?;
            load(dir, image)
        })
        .collect();
    out.sort_by(|a, b| a.image.cmp(&b.image));
    out
}

fn utc(secs: u64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(secs as i64, 0)
        .map(|t| t.format("%Y-%m-%dT%H:%MZ").to_string())
        .unwrap_or_else(|| secs.to_string())
}

/// The fast refusal: no podman build was spawned.
pub(crate) fn refusal(m: &FailureMarker, now: u64) -> String {
    let first_line = m.cause.lines().find(|l| !l.trim().is_empty()).unwrap_or("");
    let short = m.source_digest.get(..19).unwrap_or(&m.source_digest);
    let next = match m.next_retry_at {
        Some(t) => format!(
            "busy: an automatic retry is scheduled after {} (in {} min); try again then",
            utc(t),
            t.saturating_sub(now).div_ceil(60),
        ),
        None => format!(
            "no automatic retry is left; a change to any image input (a Tillandsias update) retries at once; on Linux `tillandsias --retry-image {}` retries now",
            m.image
        ),
    };
    format!(
        "refused:image-ensure:{image}:build-failed-previously\n  why: inputs {short}… failed {n}× (last {last}): {first_line}\n  log: {log}\n  remedy: {next}",
        image = m.image,
        n = m.attempts,
        last = utc(m.last_failed_at),
        log = m.log,
    )
}

/// The one verdict line every ensure prints (order 1776-brk3):
/// `[tillandsias] image-ensure <name> decided=<action> digest=<identity>
/// present=<label|none> reason=<reason> marker=<none|attempts>`.
pub(crate) fn verdict_line(
    image: &str,
    decided: &str,
    digest: Option<&str>,
    present: Option<&str>,
    reason: &str,
    marker_attempts: Option<u32>,
) -> String {
    format!(
        "[tillandsias] image-ensure {image} decided={decided} digest={} present={} reason={reason} marker={}",
        digest.unwrap_or("unknown"),
        present.unwrap_or("none"),
        marker_attempts.map_or_else(|| "none".to_string(), |n| n.to_string()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("image-ensure-marker-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn image_ensure_marker_records_counts_and_keeps_the_first_cause() {
        let d = tmp("record");
        let m1 = record(
            &d,
            "proxy",
            "sha256:aa",
            "first cause",
            "/l",
            1000,
            Some(1030),
        )
        .unwrap();
        assert_eq!(m1.attempts, 1);
        assert_eq!(m1.next_retry_at, Some(1030));
        let m2 = record(
            &d,
            "proxy",
            "sha256:aa",
            "second cause",
            "/l",
            2000,
            Some(2120),
        )
        .unwrap();
        assert_eq!(m2.attempts, 2);
        assert_eq!(m2.first_failed_at, 1000);
        assert_eq!(m2.cause, "first cause", "the first cause is kept");
        let m3 = record(&d, "proxy", "sha256:aa", "x", "/l", 9000, None).unwrap();
        assert_eq!(m3.next_retry_at, None, "budget spent: declared failed");
        assert_eq!(load(&d, "proxy"), Some(m3));
        // Other inputs start again at one.
        let m4 = record(&d, "proxy", "sha256:bb", "new", "/l", 9500, Some(9530)).unwrap();
        assert_eq!((m4.attempts, m4.cause.as_str()), (1, "new"));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn image_ensure_marker_retries_a_couple_of_times_on_exponential_backoff() {
        assert_eq!(RETRY_BUDGET, 2);
        assert_eq!(retry_delay_ms(1, 30_000), 30_000);
        assert_eq!(retry_delay_ms(2, 30_000), 120_000);
        assert_eq!(retry_delay_ms(3, 30_000), 480_000);
        assert_eq!(retry_delay_ms(1, 50), 50);
    }

    #[test]
    fn image_ensure_marker_decides_by_digest_and_schedule() {
        let m = FailureMarker {
            image: "proxy".into(),
            source_digest: "sha256:aa".into(),
            attempts: 1,
            first_failed_at: 0,
            last_failed_at: 0,
            next_retry_at: Some(600),
            cause: "c".into(),
            log: "/l".into(),
        };
        assert_eq!(decide(None, "sha256:aa"), Breaker::Proceed);
        assert_eq!(decide(Some(&m), "sha256:aa"), Breaker::Resume);
        assert_eq!(decide(Some(&m), "sha256:bb"), Breaker::InputsChanged);
        assert_eq!(busy_retry_after_secs(&m, 10), Some(590));
        assert_eq!(busy_retry_after_secs(&m, 900), Some(1));
        let failed = FailureMarker {
            next_retry_at: None,
            ..m
        };
        assert_eq!(decide(Some(&failed), "sha256:aa"), Breaker::Refuse);
        assert_eq!(busy_retry_after_secs(&failed, 10), None);
    }

    #[test]
    fn image_ensure_marker_clear_list_and_unsafe_names() {
        let d = tmp("clear");
        record(&d, "forge-base", "sha256:aa", "c", "/l", 1, None).unwrap();
        record(&d, "chromium-core", "sha256:bb", "c", "/l", 1, None).unwrap();
        let names: Vec<_> = list(&d).into_iter().map(|m| m.image).collect();
        assert_eq!(names, ["chromium-core", "forge-base"]);
        assert_eq!(clear(&d, "forge-base"), Ok(true));
        assert_eq!(clear(&d, "forge-base"), Ok(false));
        assert!(load(&d, "forge-base").is_none());
        assert!(record(&d, "../etc/passwd", "d", "c", "/l", 1, None).is_err());
        assert!(marker_path(&d, "a/b").is_none());
        // A corrupt marker reads as absent, never wedging the image.
        std::fs::write(d.join("git.json"), "{not json").unwrap();
        assert!(load(&d, "git").is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn image_ensure_marker_refusal_names_cause_log_and_remedy() {
        let m = FailureMarker {
            image: "forge-base".into(),
            source_digest: "sha256:0123456789abcdef0123".into(),
            attempts: 3,
            first_failed_at: 0,
            last_failed_at: 1_760_000_000,
            next_retry_at: None,
            cause: "\nBuild exited with status 1; podman's last stderr lines:\n  boom".into(),
            log: "/c/image-build-forge-base.log".into(),
        };
        let r = refusal(&m, 1_760_000_100);
        assert!(
            r.starts_with("refused:image-ensure:forge-base:build-failed-previously\n"),
            "{r}"
        );
        assert!(r.contains("failed 3×"), "{r}");
        assert!(r.contains("Build exited with status 1"), "{r}");
        assert!(r.contains("log: /c/image-build-forge-base.log"), "{r}");
        assert!(r.contains("tillandsias --retry-image forge-base"), "{r}");
        assert!(r.contains("no automatic retry is left"), "{r}");
        let busy = FailureMarker {
            attempts: 1,
            next_retry_at: Some(1_760_000_700),
            ..m
        };
        let b = refusal(&busy, 1_760_000_100);
        assert!(b.contains("busy") && b.contains("in 10 min"), "{b}");
    }

    #[test]
    fn image_ensure_marker_verdict_line_shape() {
        assert_eq!(
            verdict_line(
                "proxy",
                "build",
                Some("sha256:aa"),
                None,
                "digest_missing",
                Some(2)
            ),
            "[tillandsias] image-ensure proxy decided=build digest=sha256:aa present=none reason=digest_missing marker=2"
        );
    }
}
