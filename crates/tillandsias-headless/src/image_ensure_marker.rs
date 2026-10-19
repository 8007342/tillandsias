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
//! Never a sticky refusal (1793-wggq, the same ruling): a declared failure
//! expires one more backoff step after its last attempt
//! ([`declared_failed_expires_at`]), a marker written by another Tillandsias
//! version reads as absent, and every reset clears the directory
//! ([`clear_all`]). Measured on v56.10.18.1: a transient guest fault declared
//! forge-base failed, the installer's soft reset kept the marker, and every
//! later macOS launch refused with no retry the user could reach.
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
    /// The Tillandsias version that wrote it. A marker from any other version
    /// (an update, or a pre-1793 marker with none) reads as absent.
    #[serde(default)]
    pub tillandsias_version: String,
}

/// The version every marker this binary writes or honours is keyed on.
pub(crate) fn current_version() -> &'static str {
    crate::VERSION.trim()
}

/// When a declared-failed marker stops refusing: one more step of the
/// backoff ladder after its last failure (8 min at the default base). `None`
/// while a retry is still scheduled.
pub(crate) fn declared_failed_expires_at(m: &FailureMarker, base_ms: u64) -> Option<u64> {
    m.next_retry_at.is_none().then(|| {
        m.last_failed_at
            .saturating_add(retry_delay_ms(RETRY_BUDGET.saturating_add(1), base_ms).div_ceil(1000))
    })
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

/// The marker for `image` that still applies, or `None` when there is none,
/// it is unreadable (an unreadable marker must never wedge an image), another
/// version wrote it, or its declared failure has expired.
pub(crate) fn load(dir: &Path, image: &str) -> Option<FailureMarker> {
    load_at(dir, image, now_secs(), current_version(), retry_base_ms())
}

pub(crate) fn load_at(
    dir: &Path,
    image: &str,
    now: u64,
    version: &str,
    base_ms: u64,
) -> Option<FailureMarker> {
    let text = std::fs::read_to_string(marker_path(dir, image)?).ok()?;
    serde_json::from_str::<FailureMarker>(&text)
        .ok()
        .filter(|m| m.image == image && m.tillandsias_version == version)
        .filter(|m| declared_failed_expires_at(m, base_ms).is_none_or(|t| now < t))
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
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
        tillandsias_version: current_version().to_string(),
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

/// Remove every marker (a reset: the operator starting over is the retry).
/// Returns how many there were.
pub(crate) fn clear_all(dir: &Path) -> Result<usize, String> {
    let n = std::fs::read_dir(dir).map_or(0, |rd| rd.filter_map(Result::ok).count());
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(n),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(format!("image-ensure markers remove: {e}")),
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
        None => {
            let at = declared_failed_expires_at(m, retry_base_ms()).unwrap_or(now);
            format!(
                "declared failed; it is retried by itself after {} (in {} min), at once after a Tillandsias update or a reset (reinstalling Tillandsias resets it on macOS and Windows), and on Linux `tillandsias --retry-image {}` retries now",
                utc(at),
                at.saturating_sub(now).div_ceil(60),
                m.image
            )
        }
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
        assert_eq!(
            load_at(&d, "proxy", 9001, current_version(), 30_000),
            Some(m3)
        );
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
            tillandsias_version: current_version().into(),
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
        let now = now_secs();
        record(&d, "forge-base", "sha256:aa", "c", "/l", now, None).unwrap();
        record(&d, "chromium-core", "sha256:bb", "c", "/l", now, None).unwrap();
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
            tillandsias_version: current_version().into(),
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
        assert!(r.contains("declared failed"), "{r}");
        // 1793-wggq: never sticky, and a remedy a macOS or Windows user can take.
        assert!(r.contains("retried by itself after"), "{r}");
        assert!(r.contains("reinstalling Tillandsias resets it"), "{r}");
        assert!(!r.contains("no automatic retry is left"), "{r}");
        let busy = FailureMarker {
            attempts: 1,
            next_retry_at: Some(1_760_000_700),
            ..m
        };
        let b = refusal(&busy, 1_760_000_100);
        assert!(b.contains("busy") && b.contains("in 10 min"), "{b}");
    }

    /// 1793-wggq: v56.10.18.1 declared forge-base failed on a transient guest
    /// fault, and the marker refused every later launch. A declared failure
    /// now refuses for one more backoff step, then reads as absent, so the
    /// next ensure builds with a fresh budget.
    #[test]
    fn a_declared_failure_expires_after_one_more_backoff_step() {
        let d = tmp("expiry");
        let failed = record(&d, "forge-base", "sha256:aa", "c", "/l", 1_000, None).unwrap();
        let until = declared_failed_expires_at(&failed, 30_000);
        assert_eq!(until, Some(1_000 + 480), "the step after the budget's last");
        let v = current_version();
        assert!(
            load_at(&d, "forge-base", 1_479, v, 30_000).is_some(),
            "still refusing"
        );
        assert!(
            load_at(&d, "forge-base", 1_480, v, 30_000).is_none(),
            "expired"
        );
        // The next failure after expiry starts a fresh budget at one.
        let prev = load_at(&d, "forge-base", 1_480, v, 30_000);
        assert!(prev.is_none());
        // NEGATIVE CONTROL: a marker still inside its retry schedule never
        // expires by age; the ensure that owns it resumes the budget.
        let busy = record(&d, "proxy", "sha256:bb", "c", "/l", 1_000, Some(1_030)).unwrap();
        assert_eq!(declared_failed_expires_at(&busy, 30_000), None);
        assert!(load_at(&d, "proxy", 99_999, v, 30_000).is_some());
        let _ = std::fs::remove_dir_all(&d);
    }

    /// 1793-wggq: a new Tillandsias version retries at once even when the
    /// image's own inputs did not change, and a marker written before markers
    /// carried a version (v56.10.18.1's) reads as absent too.
    #[test]
    fn a_marker_from_another_version_reads_as_absent() {
        let d = tmp("version");
        let now = now_secs();
        record(&d, "forge-base", "sha256:aa", "c", "/l", now, None).unwrap();
        assert!(load_at(&d, "forge-base", now, current_version(), 30_000).is_some());
        assert!(load_at(&d, "forge-base", now, "0.0.0.1", 30_000).is_none());
        let legacy = format!(
            r#"{{"image":"git","source_digest":"sha256:cc","attempts":3,"first_failed_at":{now},"last_failed_at":{now},"next_retry_at":null,"cause":"c","log":"/l"}}"#
        );
        std::fs::write(d.join("git.json"), legacy).unwrap();
        assert!(load(&d, "git").is_none(), "a pre-1793 marker never refuses");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// 1793-wggq: a reset clears every marker, and clearing nothing is fine.
    #[test]
    fn clear_all_removes_every_marker() {
        let d = tmp("clear-all");
        let now = now_secs();
        record(&d, "forge-base", "sha256:aa", "c", "/l", now, None).unwrap();
        record(&d, "vault", "sha256:bb", "c", "/l", now, None).unwrap();
        assert_eq!(clear_all(&d), Ok(2));
        assert!(list(&d).is_empty());
        assert_eq!(clear_all(&d), Ok(0));
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
