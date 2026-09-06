//! `tillandsias-tray --diagnose` — installed-tray support diagnostic.
//!
//! Mirrors `tillandsias-windows-tray::notify_icon::diagnose` (commit
//! `20fb9d1f`) in spirit — a one-shot CLI flag that prints a bundled
//! health report and exits without launching AppKit. Designed to be
//! invoked from the terminal during user-attended smoke sessions:
//!
//! ```bash
//! /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --diagnose
//! ```
//!
//! **macOS-specific limitation vs. windows-tray**: Apple's
//! `Virtualization.framework` vsock is per-VM-handle, not per-host
//! (macOS has no `AF_VSOCK`). A standalone `--diagnose` process
//! therefore cannot reach a separately-running tray's VM control
//! wire — it would need to be the same process that started the VM
//! to hold the `VZVirtioSocketDevice` handle. So unlike windows, the
//! macOS report covers static/filesystem health only:
//!
//!   * version (`WORKSPACE_VERSION`, read from the repo-root VERSION file at build — 635-bhkb; it was `CARGO_PKG_VERSION`, i.e. the frozen "0.1.0")
//!   * bundle identity (whether the binary lives inside an `.app`)
//!   * image-root artifacts (rootfs.img / vmlinuz / initramfs.img)
//!   * manifest pin source (bundled, first 12 chars of SHA)
//!
//! Live wire status comes from clicking the menubar icon (which the
//! 30 s `spawn_vm_status_poller` already drives into the chip text).
//! A future `--attach-existing-tray` would need a host-side Unix
//! socket forwarder; that's a v0.0.2 enhancement.
//!
//! Exit codes mirror windows' shape:
//!   * `0` — image-root provisioned, bundle valid
//!   * `2` — degraded (image-root not provisioned yet — run the
//!     tray once to materialize)
//!   * `1` — hard failure (only used if even the static checks
//!     cannot complete)
//!
//! macOS-only. The non-macOS branch of the crate never compiles this
//! module.
//!
//! @trace spec:macos-native-tray.diagnose@v1,
//!        plan/steps/20-macos-tray-v0_0_1.md (m4 sub-task B slice 11)

#![cfg(target_os = "macos")]

use std::io;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::OnceLock;
use std::task::{Context, Poll};
use tillandsias_control_wire::secure_wire_mode::SecureWireMode;

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use tillandsias_control_wire::guest_transport::GuestEndpoint;
use tillandsias_secure_channel::{EncryptedStream, HopId, channel_psk, client_handshake};

use crate::guest_binary::stage_embedded_guest_binary;

/// Manifest bundled at build time so the binary doesn't need the repo or
/// network to know its artifact-URL template + pinned SHAs. Same constant
/// pattern as `action_host::BUNDLED_MANIFEST_TOML` — both the tray UI and
/// the headless `--provision` mode consume it.
const BUNDLED_MANIFEST_TOML: &str = include_str!("../../../images/vm/manifest.toml");

/// Where the .app installer materializes VM artifacts on a macOS host.
/// Mirrors `status_item::default_image_root` so `--diagnose` reads the
/// same paths the live tray writes/reads.
fn image_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support/tillandsias")
}

/// Guest crash-loop DETECTION state file. On macOS `--diagnose` is
/// static/filesystem-only (no live wire handle — `Virtualization.framework`
/// vsock is per-VM-handle, not per-host), so the crash-loop verdict is READ
/// from this file, which the long-lived tray process updates on each
/// VM-status observation. Lives in the same `image_root` the tray already
/// reads/writes, so the two agree.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn crashloop_state_path() -> PathBuf {
    image_root().join("crashloop.state")
}

/// What the guest's provisioning script recorded about its own outcome
/// (order 1055-e8ie).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ProvisionRecord {
    /// The script wrote a completion line as its last statement.
    ///
    /// `guest_binary_sha256` is what the GUEST hashed of the binary it will
    /// run (order 1084-x8ya). Comparing it against the staged provenance is
    /// the one measurement that settles version skew, and it is the only way
    /// to ask: every host-side path into the guest is closed when the wire is
    /// down, and no string scan of the raw image can date the binary because
    /// 79e3ca876 flipped a default without adding a shipped string literal.
    Complete {
        written_at: Option<u64>,
        guest_binary_sha256: Option<String>,
    },
    /// The ERR trap fired and named the failing line.
    Failed {
        written_at: Option<u64>,
        line: Option<String>,
        rc: Option<String>,
        cmd: Option<String>,
    },
    /// A start with NO completion and NO failure. This is a POSITIVE signal of
    /// an aborted provision, not an absence of information: the completion line
    /// is the script's last statement, so a start that is not followed by one
    /// means the script did not reach its end.
    StartedNeverFinished { written_at: Option<u64> },
    /// No record at all. Either no provisioning has run since this image root
    /// was created, or the share is not mounted. NEVER read as success.
    Absent,
}

/// Read the provisioning record the guest wrote to the host-visible share.
///
/// THIS READER IS THE POINT. Before 1055-e8ie the marker was written inside the
/// guest at /var/log and NOTHING read it — `grep -rn provision-marker` found no
/// consumer anywhere in the tree — so a record existed that no host could ever
/// consult, in exactly the condition it was written for. Order 272 makes the
/// control wire the only host<->guest channel, so when provisioning fails there
/// is no way in: `--exec-guest` rides the wire that is down and macOS cannot
/// mount the guest's ext4.
///
/// The timestamp is read from INSIDE the file, never from mtime (980-ja2m): a
/// copy, a restore or a `touch` forges an mtime, and mtime is a property of the
/// filesystem rather than of the event.
pub(crate) fn provision_record_from(text: &str) -> ProvisionRecord {
    let mut phase = None;
    let mut written_at = None;
    let (mut line, mut rc, mut cmd) = (None, None, None);
    let mut guest_binary_sha256 = None;
    for l in text.lines() {
        let mut parts = l.splitn(2, ' ');
        match (parts.next(), parts.next()) {
            (Some("phase"), Some(v)) => phase = Some(v.trim().to_string()),
            (Some("written_at"), Some(v)) => written_at = v.trim().parse::<u64>().ok(),
            (Some("line"), Some(v)) => line = Some(v.trim().to_string()),
            (Some("rc"), Some(v)) => rc = Some(v.trim().to_string()),
            (Some("cmd"), Some(v)) => cmd = Some(v.trim().to_string()),
            (Some("guest_binary_sha256"), Some(v)) => {
                guest_binary_sha256 = Some(v.trim().to_string())
            }
            _ => {}
        }
    }
    match phase.as_deref() {
        Some("complete") => ProvisionRecord::Complete {
            written_at,
            guest_binary_sha256,
        },
        Some("failed") => ProvisionRecord::Failed {
            written_at,
            line,
            rc,
            cmd,
        },
        Some("start") => ProvisionRecord::StartedNeverFinished { written_at },
        _ => ProvisionRecord::Absent,
    }
}

/// Compare the binary the GUEST hashed against the one the host STAGED.
///
/// ORDER 1084-x8ya, and this is the measurement the packet turns on. A guest
/// that provisioned to completion and still never reaches Ready leaves one
/// question — is it running the binary we staged — and until now no host could
/// ask it. Order 272 masks every sshd surface, `--exec-guest` rides the
/// control wire that is down in exactly this failure, macOS cannot mount the
/// guest's ext4, and a raw-image string scan cannot date the artefact because
/// 79e3ca876 flipped the wire to encrypted-by-default WITHOUT adding any
/// string literal that reaches the shipped binary.
///
/// So the guest hashes its own binary at the end of provisioning and writes it
/// to the share. This compares the two.
///
/// SKEW IS REPORTED AS A FINDING, NOT AS AN ERROR: a mismatch is the expected
/// state on a host that has staged a newer bundle than the guest last
/// installed, and naming it is the point.
fn guest_binary_skew_line(guest_sha: Option<&str>) -> String {
    let staged = crate::guest_binary::guest_binary_provenance().staged_sha256;
    match (guest_sha, staged) {
        (None, _) => "              guest binary: NOT RECORDED — this guest provisioned before \
             the hash was added, so skew cannot be judged (1084-x8ya)."
            .to_string(),
        (Some("absent"), _) => "              guest binary: ABSENT in the guest. Provisioning \
             completed and left no binary at /usr/local/bin/tillandsias-headless."
            .to_string(),
        (Some("unreadable"), _) => "              guest binary: present but UNREADABLE to the \
             hashing step; skew cannot be judged."
            .to_string(),
        (Some(g), None) => format!(
            "              guest binary: {} — nothing staged on this host to compare against.",
            &g[..g.len().min(12)]
        ),
        (Some(g), Some(st)) if g == st => format!(
            "              guest binary: MATCHES the staged artefact ({}…). Version skew is \
             ELIMINATED as a cause.",
            &g[..g.len().min(12)]
        ),
        (Some(g), Some(st)) => format!(
            "              guest binary: SKEW — guest {}…, staged {}…. The guest is NOT running \
             the binary this host staged, which is a cause a dead control wire would present as \
             a handshake failure (1084-x8ya).",
            &g[..g.len().min(12)],
            &st[..st.len().min(12)]
        ),
    }
}

/// Where the host reads the provisioning record.
pub fn provision_state_path() -> std::path::PathBuf {
    image_root().join("provision").join("provision.state")
}

/// The `Provisioning` line of the report.
pub(crate) fn provision_report_line() -> String {
    let text = std::fs::read_to_string(provision_state_path()).unwrap_or_default();
    match provision_record_from(&text) {
        ProvisionRecord::Complete {
            written_at,
            guest_binary_sha256,
        } => format!(
            "Provisioning: COMPLETE — the guest script recorded its own completion{}\n{}",
            written_at
                .map(|t| format!(" at {}", format_utc(t)))
                .unwrap_or_default(),
            guest_binary_skew_line(guest_binary_sha256.as_deref())
        ),
        ProvisionRecord::Failed {
            written_at,
            line,
            rc,
            cmd,
        } => format!(
            "Provisioning: FAILED{} — line {}, rc {}, cmd: {}",
            written_at
                .map(|t| format!(" at {}", format_utc(t)))
                .unwrap_or_default(),
            line.unwrap_or_else(|| "?".into()),
            rc.unwrap_or_else(|| "?".into()),
            cmd.unwrap_or_else(|| "?".into())
        ),
        ProvisionRecord::StartedNeverFinished { written_at } => format!(
            "Provisioning: ABORTED — the script started{} and never recorded completion. \
             The completion line is its LAST statement, so a start without one means it did \
             not reach the end. This guest may be assembled from a mixture of runs.",
            written_at
                .map(|t| format!(" at {}", format_utc(t)))
                .unwrap_or_default()
        ),
        ProvisionRecord::Absent => {
            "Provisioning: UNKNOWN — no record. Either nothing has provisioned this image \
             root, or the provision-state share is not mounted. Never read as success."
                .to_string()
        }
    }
}

/// Heartbeat period: how often the live tray writes `heartbeat.state`
/// (980-ja2m slice (b)).
///
/// MEASURED, NOT CHOSEN BY TASTE. On macneo 2026-09-05 a healthy, Ready,
/// podman-ready guest emitted exactly ONE `vm-status` line in 25m34s — the
/// first, nine seconds after boot — and nothing for the remaining 1525
/// seconds. SC-07 says why in its own log line: "vm-status/login/cloud/local
/// polls demoted to fallback". The push channel is event-driven and correctly
/// silent, so a timestamp written only on pushes is 25 minutes stale on a
/// system with nothing wrong, and unbounded thereafter.
///
/// That kills every push-driven threshold in BOTH directions: short enough to
/// notice death means UNKNOWN continuously on a working guest, and long enough
/// to avoid that cannot notice death at all. The heartbeat is therefore the
/// mechanism, not an optimisation — the freshness bound is the load-bearing
/// part of this packet, and a bound that reads UNKNOWN precisely when the
/// system works is the original defect with extra steps.
///
/// 30 s bounds worst-case staleness in SECONDS, as the criterion requires, for
/// two writes a minute of a ~100-byte file. Set on the fleet's most
/// memory-constrained host deliberately: if 8 GB can afford it, everything can.
pub(crate) const HEARTBEAT_PERIOD_SECS: u64 = 30;

/// Staleness bound: a heartbeat older than this reads UNKNOWN, never a phase.
///
/// THREE PERIODS, NOT ONE. A single missed write — a scheduling stall, a
/// suspend, a slow disk on a loaded 8 GB host — must not flip a healthy system
/// to UNKNOWN, which would be the false-alarm half of the defect. Three
/// consecutive misses is the same shape as the crash-loop detector's own
/// `threshold 3` already in crashloop.state, and it keeps the worst-case
/// detection latency inside 90 s.
pub(crate) const HEARTBEAT_STALE_AFTER_SECS: u64 = 3 * HEARTBEAT_PERIOD_SECS;

/// Where the live tray writes its heartbeat. Same image root as the rest of
/// the report, so `--diagnose` and the tray agree on one location.
pub fn heartbeat_state_path() -> std::path::PathBuf {
    image_root().join("heartbeat.state")
}

/// Serialize a heartbeat record. Line-based and forward-compatible, matching
/// crashloop.state's format so a reader learns one shape, not two.
///
/// The timestamp is INSIDE the file. mtime is never the truth here — see
/// `TimestampSource` — so a copy or a `touch` cannot manufacture freshness.
pub fn heartbeat_state_string(status_line: &str, written_at_unix: u64) -> String {
    // `status` carries the tray's chip text VERBATIM and may contain spaces and
    // emoji, so it is written last and parsed to end-of-line. Everything above
    // it is a single token, which keeps the format readable by the same
    // split_whitespace parser crashloop.state uses.
    format!(
        "tillandsias-heartbeat-state v1\nwritten_at {written_at_unix}\nperiod_secs {HEARTBEAT_PERIOD_SECS}\nstatus {status_line}\n"
    )
}

/// What the heartbeat file says about the guest right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum HeartbeatVerdict {
    /// A heartbeat written within the staleness bound: the phase is CURRENT.
    Fresh { phase: String, age_secs: u64 },
    /// A heartbeat older than the bound. The phase it names is NOT reported —
    /// a stale phase is exactly the lie this packet exists to stop.
    Stale { age_secs: u64 },
    /// No heartbeat file, or one this reader cannot parse.
    Absent,
}

/// Read the heartbeat and bound it by age.
///
/// Prefers the content timestamp and falls back to mtime only for a file that
/// predates it, disclosing the fallback to the caller so the printed line can
/// say "mtime" — the same rule the Guest health line follows, through the same
/// `TimestampSource`, so the two readers cannot drift apart.
pub(crate) fn heartbeat_verdict_at(now_unix: u64) -> HeartbeatVerdict {
    let path = heartbeat_state_path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HeartbeatVerdict::Absent;
    };
    heartbeat_verdict_from(&text, file_mtime_unix(&path), now_unix)
}

/// The parse and the bound, with no filesystem in the way.
///
/// Split out so both directions of the bound are testable as pure values.
/// `mtime_fallback` is the file's mtime for a record that predates
/// `written_at`; it is used ONLY then, and never silently — see
/// `TimestampSource`.
pub(crate) fn heartbeat_verdict_from(
    text: &str,
    mtime_fallback: Option<u64>,
    now_unix: u64,
) -> HeartbeatVerdict {
    let mut phase = None;
    let mut written = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("status ") {
            // To end-of-line: the tray's chip text contains spaces and emoji.
            phase = Some(rest.trim().to_string());
            continue;
        }
        let mut parts = line.split_whitespace();
        if let Some("written_at") = parts.next() {
            written = parts.next().and_then(|v| v.parse::<u64>().ok());
        }
    }
    let src = written
        .map(TimestampSource::Content)
        .or_else(|| mtime_fallback.map(TimestampSource::Mtime));
    let (Some(phase), Some(src)) = (phase, src) else {
        return HeartbeatVerdict::Absent;
    };
    let age = now_unix.saturating_sub(src.unix());
    if age > HEARTBEAT_STALE_AFTER_SECS {
        HeartbeatVerdict::Stale { age_secs: age }
    } else {
        HeartbeatVerdict::Fresh {
            phase,
            age_secs: age,
        }
    }
}

/// The `Guest state` line: the ONE place in this report that can speak about a
/// live guest, and only within `HEARTBEAT_STALE_AFTER_SECS`.
pub(crate) fn guest_state_report_line_at(now_unix: u64) -> String {
    match heartbeat_verdict_at(now_unix) {
        HeartbeatVerdict::Fresh { phase, age_secs } => format!(
            "Guest state: {phase} — as the live tray reported it (heartbeat {} old, bound {}s)",
            humanize_age(age_secs),
            HEARTBEAT_STALE_AFTER_SECS
        ),
        HeartbeatVerdict::Stale { age_secs } => format!(
            "Guest state: UNKNOWN — the last heartbeat is {} old, past the {}s bound. \
             The phase it names is NOT reported: a stale phase is indistinguishable \
             from a live one, which is the defect this bound exists to close.",
            humanize_age(age_secs),
            HEARTBEAT_STALE_AFTER_SECS
        ),
        HeartbeatVerdict::Absent => format!(
            "Guest state: UNKNOWN — no heartbeat file. Either no tray has run since \
             this was installed, or the tray is not writing one. Absence is never \
             read as healthy (bound {}s).",
            HEARTBEAT_STALE_AFTER_SECS
        ),
    }
}

fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Read the persisted crash-loop detector and render its verdict in the PINNED
/// grammar `^(healthy|starting|crash-loop:[a-z0-9-]+)$`. A missing/unwritten
/// state file yields `starting` (nothing observed yet), never a panic.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn guest_health_verdict() -> String {
    tillandsias_control_wire::crashloop::CrashLoopDetector::load(&crashloop_state_path())
        .verdict(unix_now_secs())
        .verdict()
}

/// Render a Unix timestamp as `YYYY-MM-DDTHH:MM:SSZ`.
///
/// A local civil-from-days conversion rather than a date crate: this binary
/// ships to the fleet's most memory-constrained target and the dependency is
/// not worth one timestamp. The algorithm is Howard Hinnant's days-from-civil
/// inverted; the era arithmetic handles the /100 and /400 leap rules together,
/// which a naive `year % 4` check gets wrong in 2000 and 2100 — both pinned as
/// fixed points in `format_utc_fixed_points`.
///
/// @trace order:980-ja2m
fn format_utc(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Shift so the era starts 0000-03-01, which puts the leap day last in the
    // year and makes the month arithmetic uniform.
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11], March-based
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y,
        m,
        d,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Render an age in seconds as a short human string (`5d 1h`, `3h 12m`, `47s`).
///
/// @trace order:980-ja2m
fn humanize_age(secs: u64) -> String {
    let d = secs / 86_400;
    let h = (secs % 86_400) / 3600;
    let m = (secs % 3600) / 60;
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m")
    } else {
        format!("{secs}s")
    }
}

/// The `Guest health:` line, rendered so a RECORDED verdict cannot be read as a
/// live observation.
///
/// THE DEFECT THIS EXISTS FOR (980-ja2m, filed macneo, instance macbookair on
/// the 16 GiB host): `guest_health_verdict()` is a pure disk read of
/// crashloop.state with no live probe and no VM contact, so `healthy` means
/// "the last RECORDED phase was not a crash loop" and NEVER "a guest is alive
/// now". Measured: `--diagnose --with-metrics` printed `Guest health: healthy`
/// with no VM process running for the full 70 s sampled, FIVE DAYS after
/// crashloop.state was written. The two cases were indistinguishable in the
/// output.
///
/// WHY THE VERDICT WORD IS KEPT, QUOTED, INSIDE THE FRAMING rather than
/// replaced: the pinned grammar `^(healthy|starting|crash-loop:<subsystem>)$`
/// is the only place the report names WHICH subsystem is looping. Dropping the
/// word to avoid the false-liveness reading would take that with it.
///
/// WHY THE `Guest health:` LABEL IS KEPT: windows-tray prints the same label
/// (notify_icon.rs:2915) and two surface tests pin the literal (macos-tray
/// main.rs:722, windows-tray main.rs:402). The Windows line carries the
/// identical defect and is filed separately.
///
/// AN UNKNOWN AGE MUST NOT READ AS FRESH. If the file is absent or its mtime
/// is unreadable, the age is printed as UNKNOWN rather than omitted — an
/// omitted age is read as "just now" by exactly the reader this line is for.
///
/// @trace order:980-ja2m
fn guest_health_report_line() -> String {
    let verdict = guest_health_verdict();
    let path = crashloop_state_path();
    let written_at = tillandsias_control_wire::crashloop::CrashLoopDetector::load(&path)
        .written_at()
        .map(TimestampSource::Content)
        .or_else(|| file_mtime_unix(&path).map(TimestampSource::Mtime));

    match written_at {
        Some(src) => {
            let written = src.unix();
            let elapsed = unix_now_secs().saturating_sub(written);
            format!(
                "Guest health: RECORDED, not observed — last recorded verdict \
                 \"{verdict}\" (crashloop.state, written {}{}, {} ago)",
                format_utc(written),
                src.disclosure(),
                humanize_age(elapsed)
            )
        }
        None => format!(
            "Guest health: RECORDED, not observed — last recorded verdict \
             \"{verdict}\" (crashloop.state age UNKNOWN: file absent or unreadable)"
        ),
    }
}

/// Where a state file's write time came from (980-ja2m).
///
/// MTIME IS NOT THE TRUTH. A copy, a restore, a `touch` or an rsync gives stale
/// content a fresh mtime, and nothing at the filesystem layer can tell that
/// apart from a real write. A timestamp written INSIDE the file cannot be
/// forged by ordinary filesystem operations, so it is preferred whenever the
/// file carries one.
///
/// The mtime path is kept ONLY for files written before the content timestamp
/// existed, and a reader that falls back MUST SAY SO — hence `disclosure()`
/// putting the word "mtime" in the printed line. A silent fallback would make
/// a forgeable number indistinguishable from an unforgeable one, which is the
/// same class of defect as printing a recorded phase as if it were observed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TimestampSource {
    /// Read from inside the file. Not forgeable by filesystem operations.
    Content(u64),
    /// Read from the filesystem. Forgeable; always disclosed to the reader.
    Mtime(u64),
}

impl TimestampSource {
    pub(crate) fn unix(self) -> u64 {
        match self {
            Self::Content(t) | Self::Mtime(t) => t,
        }
    }

    /// Text appended after the rendered timestamp. Empty for a content
    /// timestamp; names mtime when the fallback was used.
    pub(crate) fn disclosure(self) -> &'static str {
        match self {
            Self::Content(_) => "",
            Self::Mtime(_) => " (from mtime: this file predates the written_at field)",
        }
    }
}

/// Unix seconds of a file's mtime, or `None` if absent or unreadable.
fn file_mtime_unix(path: &std::path::Path) -> Option<u64> {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
}

/// 972-umik: DELEGATES to the one reader in tillandsias-control-wire. This
/// crate used to parse `TILLANDSIAS_SECURE_CONTROL_WIRE` itself, which is how
/// six copies of one parse drifted apart. The `OnceLock` is kept — it memoises
/// the RESULT, including the error, so a bad value fails identically on every
/// call — but the environment is read once, inside the shared module.
///
/// The default is whatever the shared reader gives (Off today). It is NOT
/// restated here: a local default is exactly the drift this conversion removes,
/// and the flip to On belongs to the commit that converts the LAST reader.
fn secure_control_wire_mode() -> Result<SecureWireMode, String> {
    static MODE: OnceLock<Result<SecureWireMode, String>> = OnceLock::new();
    MODE.get_or_init(tillandsias_control_wire::secure_wire_mode::secure_wire_mode)
        .clone()
}

type GuestWireStream = Box<dyn tillandsias_control_wire::transport::AsyncReadWrite + Unpin + Send>;

enum ControlWireStream {
    Plain(GuestWireStream),
    Secure(Box<EncryptedStream<GuestWireStream>>),
}

impl AsyncRead for ControlWireStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_read(cx, out),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_read(cx, out),
        }
    }
}

impl AsyncWrite for ControlWireStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_write(cx, buf),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_flush(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            ControlWireStream::Plain(stream) => Pin::new(stream).poll_shutdown(cx),
            ControlWireStream::Secure(stream) => Pin::new(stream).poll_shutdown(cx),
        }
    }
}

async fn open_control_wire_stream(
    vz: &tillandsias_vm_layer::vz::VzRuntime,
    port: u32,
    timeout: std::time::Duration,
) -> Result<ControlWireStream, String> {
    let endpoint = GuestEndpoint::MacVz { port };
    let stream = vz
        .open_guest_transport_stream_current_thread(&endpoint, timeout)
        .await
        .map_err(|e| e.to_string())?;

    match secure_control_wire_mode()? {
        SecureWireMode::Off => Ok(ControlWireStream::Plain(stream)),
        SecureWireMode::On => {
            let psk = channel_psk(
                tillandsias_secure_channel::workspace_version(),
                tillandsias_control_wire::WIRE_VERSION,
                HopId::HostGuest,
            );
            // 733-mppc. Same defect as action_host.rs's copy of this function,
            // and WORSE HERE because of where it sits: this is the DIAGNOSTIC
            // path, so the tool an operator reaches for when the host is sick
            // was itself the thing that hung. A guest that completes the socket
            // and then stalls mid-Noise parked `--diagnose` forever.
            //
            // THE BOUND IS THE CALLER'S, and for an interactive tool that is the
            // deliberate choice rather than an inherited one. Criterion 2 warns
            // against inheriting an exec-shaped timeout that would leave the
            // diagnostic hanging for minutes; the callers here pass 30s (and
            // `probe_phase_secure_or_plain` passes the readiness probe's own
            // per-attempt budget), so the ceiling is tens of seconds, not
            // minutes — an operator gets an answer while a genuinely slow guest
            // on a loaded host still completes. A shorter fixed constant was
            // rejected: it would make the readiness probe, which legitimately
            // retries against a booting guest, fail faster than the guest can
            // reasonably answer.
            let secure =
                crate::action_host::secure_handshake_bounded(stream, &psk, timeout).await?;
            Ok(ControlWireStream::Secure(Box::new(secure)))
        }
    }
}

/// `VzRuntime::wait_phase_ready`'s per-attempt probe callback. `vm-layer`
/// does not depend on `tillandsias-secure-channel`, so it cannot decide
/// Plain-vs-Secure itself; this reuses the exact `open_control_wire_stream`
/// opener that `--exec-guest` / `--list-cloud-projects` / GitHub login use,
/// so readiness probing never bypasses secure mode when it is enabled.
/// @trace plan/issues/secure-channel-release-and-probe-hardening-2026-07-05.md
async fn probe_phase_secure_or_plain(
    vz: &tillandsias_vm_layer::vz::VzRuntime,
    timeout: std::time::Duration,
) -> Result<tillandsias_control_wire::VmPhase, String> {
    use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

    let stream = open_control_wire_stream(vz, CONTROL_WIRE_VSOCK_PORT, timeout).await?;
    tillandsias_vm_layer::vsock_exec::probe_vm_phase(stream).await
}

/// Output format selected via `--diagnose` (default) or
/// `--diagnose --json`. Mirrors windows-tray's `DiagnoseFormat`
/// (commit c4908438).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnoseFormat {
    Human,
    Json,
}

/// Bundled diagnostic-report payload. Both human and JSON formatters
/// emit exactly these fields, so support tooling that parses the JSON
/// gets the same data the user sees in the terminal. Mirrors windows-
/// tray's `DiagnoseReport` (commit c4908438) — field names match
/// byte-for-byte where the concept exists on both hosts; macOS-only
/// fields and windows-only fields differ.
#[derive(serde::Serialize)]
pub struct DiagnoseReport {
    pub version: &'static str,
    pub guest_version: Option<String>,
    pub in_app: bool,
    pub exe_path: Option<String>,
    pub image_root: String,
    pub rootfs_present: bool,
    pub rootfs_bytes: Option<u64>,
    pub kernel_present: bool,
    pub kernel_bytes: Option<u64>,
    pub initrd_present: bool,
    pub initrd_bytes: Option<u64>,
    pub release_tag: &'static str,
    pub manifest_pin_aarch64_qcow2: Option<String>,
    pub provisioned: bool,
    /// 701-kgvk. Which guest binary this bundle carries, versus the one actually
    /// staged for the guest to install on its next boot. The staging path is
    /// keyed only on `$HOME` and the guest reinstalls from it unconditionally,
    /// so an older `.app` started later silently downgrades the guest — stickily,
    /// across reboots and guest resets. Nothing surfaced that before: the only
    /// integrity gate compares a VERSION string that does not roll between
    /// builds. A real skew on this host had to be found by hashing by hand.
    pub guest_binary_bundle_sha256: Option<String>,
    pub guest_binary_staged_sha256: Option<String>,
    /// `Some(false)` means the guest will boot a DIFFERENT binary than this
    /// bundle carries. `None` means undecidable (no bundle, or nothing staged
    /// yet) and must never be read as "fine".
    pub guest_binary_staged_matches_bundle: Option<bool>,
    /// Whether a tray PROCESS is running right now, established by probing the
    /// tray's own singleton lock (order 735-2g5i; renamed from `vm_owner_live`
    /// by 980-ja2m).
    ///
    /// READ THE NAME LITERALLY: this observes a PROCESS, not a VM. It was
    /// called `vm_owner_live` and documented as "a live tray process owns the
    /// VM", which is a claim the probe cannot support — the lock says a tray is
    /// running and nothing more. A tray that is running but wedged, holding no
    /// VM at all, holds the lock exactly as a healthy one does; the field
    /// cannot separate them in either direction.
    ///
    /// This is NOT macOS's answer to what Windows answers with
    /// `wire.reachable`, and the old comment saying so overstated it. Windows
    /// asks the guest and believes the phase it names; this asks the host
    /// whether a process is alive. macOS cannot ask the guest from here — its
    /// vsock is per-VM-handle with no AF_VSOCK, so the live phase is reachable
    /// ONLY from inside the tray process (see the "Control wire status" note in
    /// `print_human`). Process liveness is the strongest fact a separate
    /// `--diagnose` can establish today; naming it for the fact it establishes
    /// is the point of the rename.
    pub tray_process_running: bool,

    /// Guest metrics snapshot (778-n9z2), read over the control wire.
    ///
    /// The wire types travel through UNCHANGED — every counter stays
    /// `Option<u64>` and every sample keeps its `error`, with no
    /// `skip_serializing_if` anywhere on the path, so a counter that could
    /// not be collected serialises as JSON `null` and never as a healthy
    /// zero (spec:observability-metrics; the tray hop is exactly where that
    /// contract would be lost).
    ///
    /// `None` on the ordinary standalone `--diagnose`: a separate process
    /// holds no VM handle (VZ vsock is per-VM-handle, macOS has no
    /// AF_VSOCK), so there is nothing to read. `metrics_status` always says
    /// which of those it is.
    pub metrics: Option<tillandsias_control_wire::MetricsSnapshotWire>,

    /// Why `metrics` is or is not populated. Grammar, pinned by test:
    ///   `ok`
    ///   `unsupported:no-live-wire-handle`     — standalone --diagnose
    ///   `unsupported:guest-lacks-capability`  — HelloAck server_caps lacks it
    ///   `error:<slug>`                        — the read was attempted and failed
    ///
    /// A status is mandatory precisely because absence is ambiguous: "no
    /// metrics" must never be readable as "no containers".
    pub metrics_status: String,
}

/// Status constant for the default standalone path — no VM handle, so the
/// wire cannot be read at all. Named so the value cannot drift between the
/// collector and its test.
pub(crate) const METRICS_STATUS_NO_HANDLE: &str = "unsupported:no-live-wire-handle";

/// Status constant for a guest whose HelloAck did not advertise
/// `MetricsSnapshotRequest`. Feature detection is by CAPABILITY, never by
/// wire-version comparison — a version number says what the peer is, a
/// capability says what it can do (778-n9z2 exit criterion 1).
pub(crate) const METRICS_STATUS_NO_CAPABILITY: &str = "unsupported:guest-lacks-capability";

/// Entry point invoked from `main` when `--diagnose` is on argv.
/// Returns the exit code to bubble up via `std::process::exit`.
pub fn main(format: DiagnoseFormat) -> i32 {
    let report = collect_report();
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

fn collect_report() -> DiagnoseReport {
    let exe = std::env::current_exe().ok();
    let in_app = exe
        .as_ref()
        .and_then(|p| p.to_str())
        .map(|s| s.contains("/Tillandsias.app/"))
        .unwrap_or(false);
    let exe_path = exe.as_ref().map(|p| p.display().to_string());

    let root = image_root();
    let image_root_str = root.display().to_string();
    let (rootfs_present, rootfs_bytes) = stat_file(&root.join("rootfs.img"));
    let (kernel_present, kernel_bytes) = stat_file(&root.join("vmlinuz"));
    let (initrd_present, initrd_bytes) = stat_file(&root.join("initramfs.img"));
    let provisioned = rootfs_present;

    let manifest_pin_aarch64_qcow2 = parse_aarch64_qcow2_sha(BUNDLED_MANIFEST_TOML);
    let provenance = crate::guest_binary::guest_binary_provenance();

    DiagnoseReport {
        version: env!("WORKSPACE_VERSION"),
        guest_version: None,
        in_app,
        exe_path,
        image_root: image_root_str,
        rootfs_present,
        rootfs_bytes,
        kernel_present,
        kernel_bytes,
        initrd_present,
        initrd_bytes,
        release_tag: crate::action_host::FEDORA_BASELINE,
        manifest_pin_aarch64_qcow2,
        provisioned,
        guest_binary_bundle_sha256: provenance.bundle_sha256,
        guest_binary_staged_sha256: provenance.staged_sha256,
        guest_binary_staged_matches_bundle: provenance.staged_matches_bundle,
        tray_process_running: a_tray_process_holds_the_singleton(),
        // collect_report() runs in a process with no VM handle by
        // construction. It must NOT boot one: install-macos.sh runs
        // `--diagnose --json` synchronously during install, so a wire read
        // on this path would start a VM mid-install and could race a live
        // tray's handle. The opt-in verb below is the only reader.
        metrics: None,
        metrics_status: METRICS_STATUS_NO_HANDLE.to_string(),
    }
}

/// Is a tray PROCESS holding the singleton right now? (order 735-2g5i; renamed
/// from `live_tray_owns_vm` by 980-ja2m)
///
/// `Ok(None)` is WouldBlock — the lock is held, i.e. a tray process is running.
/// It does NOT mean that process owns a VM, that a VM exists, or that the guest
/// is reachable; the old name and comment claimed the first of those and the
/// probe cannot see any of them. Acquiring and immediately dropping the guard
/// is side-effect free when the lock is free, which is what makes this safe to
/// call from a read-only report. A probe infrastructure error returns false: an
/// unknown state must never be reported as a running one, because that is the
/// direction that tells automation to keep waiting.
fn a_tray_process_holds_the_singleton() -> bool {
    matches!(
        tillandsias_core::singleton::SingletonGuard::try_acquire("tillandsias-macos-tray"),
        Ok(None)
    )
}

fn stat_file(path: &std::path::Path) -> (bool, Option<u64>) {
    match std::fs::metadata(path) {
        Ok(md) => (true, Some(md.len())),
        Err(_) => (false, None),
    }
}

fn print_human(r: &DiagnoseReport) {
    println!("Tillandsias.app diagnostic report");
    println!("================================");
    println!();
    println!("Version:    {}", r.version);
    println!(
        "Bundle:     {}",
        if r.in_app {
            "inside Tillandsias.app (codesigned ad-hoc at build)"
        } else {
            "running outside .app (development binary)"
        }
    );
    if let Some(ref exe_path) = r.exe_path {
        println!("Exe:        {exe_path}");
    }
    println!("Image-root: {}", r.image_root);
    print_artifact("  rootfs.img", r.rootfs_present, r.rootfs_bytes);
    print_artifact("  vmlinuz", r.kernel_present, r.kernel_bytes);
    print_artifact("  initramfs.img", r.initrd_present, r.initrd_bytes);
    println!("Release:    {}", r.release_tag);
    println!("Manifest:   bundled at build (compile-time include_str!)");
    match &r.manifest_pin_aarch64_qcow2 {
        Some(sha) => println!("  aarch64.qcow2 SHA-256 pin: {sha}\u{2026}"),
        None => println!("  aarch64.qcow2 SHA-256 pin: (not found / parse skipped)"),
    }
    println!();
    println!("Control wire status:");
    println!("  (live VM phase + podman_ready are only reachable from");
    println!("   the running tray process itself — macOS vsock is per-");
    println!("   VM-handle, no AF_VSOCK. Click the menubar icon for");
    println!("   the live chip; the 30 s poller refreshes it in place.)");
    println!();
    // Guest crash-loop DETECTION verdict. Read from the state file the live
    // tray persists (this `--diagnose` process holds no live wire handle, per
    // the module-header limitation). Emits the PINNED grammar
    // ^(healthy|starting|crash-loop:[a-z0-9-]+)$; a repeated
    // restart/unseal/handshake pattern flips it to crash-loop:<subsystem>.
    // Additive — does NOT affect the 0/2/1 exit-code contract.
    // @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    println!("{}", provision_report_line());
    println!("{}", guest_state_report_line_at(unix_now_secs()));
    println!("{}", guest_health_report_line());
    println!("No live probe was made; this report cannot contact the guest.");
    println!();
    // 701-kgvk. The guest reinstalls its headless binary from the staged copy on
    // EVERY boot, and that path is keyed only on $HOME — so an older .app
    // started later silently downgrades the guest, and stays downgraded. Print
    // it here because a skew is otherwise invisible: the only integrity gate
    // compares a VERSION string that does not roll between builds.
    println!("Guest binary:");
    match (
        &r.guest_binary_bundle_sha256,
        &r.guest_binary_staged_sha256,
        r.guest_binary_staged_matches_bundle,
    ) {
        (Some(b), Some(_), Some(true)) => {
            println!(
                "  in sync — staged copy matches this bundle ({}…)",
                &b[..12]
            );
        }
        (Some(b), Some(s), Some(false)) => {
            println!(
                "  *** SKEW *** the guest will install a DIFFERENT binary than this bundle carries."
            );
            println!("      this bundle : {}…", &b[..12]);
            println!("      staged copy : {}…", &s[..12]);
            println!("      The staged copy wins on the guest's next boot. Another (likely older)");
            println!("      Tillandsias.app staged it. Re-stage from the build you intend to run.");
        }
        (None, _, _) => {
            println!("  unknown — no bundled guest binary found (running outside .app?);");
            println!("      a run like this stages NOTHING, so the guest keeps whatever it has.");
        }
        (_, None, _) => {
            println!("  not staged yet — the guest has never been given a binary from this host.");
        }
        // Both hashes present but no verdict is structurally impossible today;
        // report it as unknown rather than silently implying agreement.
        (Some(_), Some(_), None) => {
            println!("  unknown — both binaries readable but comparison unavailable.");
        }
    }
    println!();
    if r.provisioned {
        // 980-ja2m. Say what was MEASURED — the boot artifacts are on disk —
        // and then say plainly what was not. This used to read "PROVISIONED —
        // first-launch materialization complete." and stop, which an operator
        // reasonably read as "the system is healthy". Nothing in this report
        // observes the VM or the guest, so the report must not leave the
        // impression that something did.
        println!("Status: PROVISIONED — the boot artifacts are on disk.");
        if r.tray_process_running {
            println!("        A tray process is running (singleton lock held).");
        } else {
            println!("        No tray process is running.");
        }
        println!(
            "        NOT CHECKED: whether a VM is running, or whether the guest is healthy. This"
        );
        println!("        report cannot see either — macOS has no AF_VSOCK, so the live phase is");
        println!(
            "        readable only from inside the tray process. Open the menubar chip for live status."
        );
    } else if r.tray_process_running {
        // Order 735-2g5i, narrowed by 980-ja2m. Distinct from the line below,
        // and distinctly EXITED. The old text said "a running tray owns the VM
        // and is still materializing it" — the singleton cannot support either
        // half of that: a WEDGED tray with no VM holds the lock identically.
        // What is actually known is that the artifacts are absent and a tray
        // process exists. Telling the operator to "launch the tray once" here
        // would still be advice to do what they are already doing.
        println!(
            "Status: CONVERGING (exit {DIAGNOSE_EXIT_CONVERGING}) — boot artifacts are absent \
             and a tray process is running."
        );
        println!(
            "        Not an error. Re-run --diagnose in a few moments; the tray's \
             menubar chip shows live progress."
        );
    } else {
        println!(
            "Status: NOT PROVISIONED — launch the tray once (or `open \
             /Applications/Tillandsias.app`) to fetch rootfs.img on \
             first launch."
        );
    }
}

fn print_artifact(label: &str, present: bool, bytes: Option<u64>) {
    if present {
        println!("{label:<16}  present, {} bytes", bytes.unwrap_or(0));
    } else {
        println!("{label:<16}  MISSING");
    }
}

fn print_json(r: &DiagnoseReport) {
    match serde_json::to_string_pretty(r) {
        Ok(s) => println!("{s}"),
        Err(e) => {
            // Best-effort: emit a single-line fallback object so the
            // tool consuming the output isn't stuck parsing empty stdout.
            eprintln!("[tillandsias-tray] --diagnose --json serialize failed: {e}");
            println!("{{\"error\":\"serialize failed: {e}\"}}");
        }
    }
}

/// Exit code for a converging VM: not ready yet, and not broken (order
/// 735-2g5i, matching windows-tray's `DIAGNOSE_EXIT_CONVERGING` from 647-i98k).
///
/// THE DEFECT this closes: a converging state and a broken state shared exit 2,
/// so any scripted post-install check that runs `--diagnose` once and branches
/// on the code declares a still-provisioning host broken. Windows hit exactly
/// that in the 644-a3wj curl smoke and separated the two; macOS still collapsed
/// them, which is the asymmetry
/// `litmus:exit-code-provisioned-zero-degraded-two-symmetric` was reporting.
///
/// macOS reaches the same verdict from a DIFFERENT fact, because it cannot
/// reach the same one. Windows asks the guest and believes the phase it names.
/// macOS has no AF_VSOCK — the live phase is readable only from inside the tray
/// process — so a separate `--diagnose` cannot ask. What it CAN establish is
/// whether a live tray owns the VM, and that is an observation of the same
/// kind: somebody is working on this right now.
pub(crate) const DIAGNOSE_EXIT_CONVERGING: i32 = 3;

fn exit_code_from(r: &DiagnoseReport) -> i32 {
    if r.provisioned {
        return 0;
    }
    // Boot artifacts absent WHILE a live tray owns the VM is the unambiguous
    // converging case: provisioning is the first thing the tray does, so the
    // artifacts are missing BECAUSE the work is still underway. Automation
    // should keep waiting.
    //
    // No live owner stays exit 2 deliberately, mirroring the Windows reasoning
    // for an unreachable wire: with nothing holding the VM, an incomplete image
    // root is indistinguishable from a failed provision, and inventing a third
    // verdict from leftover staging files would trade a false "broken" for a
    // false "converging" — the worse error, because it tells automation to wait
    // for something that will never arrive. Staging residue (`rootfs.qcow2`,
    // `rootfs.img.xz.partial`, `*.part`) survives a crashed provision, so its
    // mere presence is not evidence that anything is still running.
    if r.tray_process_running {
        return DIAGNOSE_EXIT_CONVERGING;
    }
    2
}

/// Entry point invoked from `main` when `--provision` is on argv.
/// Downloads the Fedora Cloud qcow2, converts it to raw for
/// Virtualization.framework, and SHA-verifies against the manifest
/// pin — all without launching the NSApplication event loop.
/// Prints JSON-line progress to stdout for script consumption.
///
/// Exit codes:
///   * `0` — provisioned (or already provisioned)
///   * `1` — hard failure (manifest parse, network, conversion, SHA)
///
/// `--reset-guest` CLI verb (windows-260717-4): intentional EPHEMERAL RESET —
/// delete the provisioned boot artifacts (rootfs.img and with it the in-VM
/// vault, vmlinuz, initramfs.img), clear the persisted crash-loop state (a
/// fresh guest has a fresh history), then re-run the exact same
/// `provision_main` path `--provision` uses. Destructive by design: state of
/// value lives in the cloud; the only cost is one re-authentication. The
/// dispatcher gates this behind `require_no_live_tray` (order 277) so it
/// never wipes the disk out from under a running tray's VM.
///
/// @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
pub fn reset_guest_main() -> i32 {
    eprintln!(
        "[reset-guest] This discards the local guest and its cached credentials. \
         Everything lives in the cloud \u{2014} you'll re-authenticate once."
    );
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    if let Err(err) = vz.wipe_provisioned_artifacts() {
        eprintln!("[reset-guest] RESULT: FAILED \u{2014} wipe: {err}");
        return 1;
    }
    let _ = std::fs::remove_file(crashloop_state_path());
    eprintln!("[reset-guest] guest wiped \u{2014} reprovisioning from scratch\u{2026}");
    provision_main()
}

pub fn provision_main() -> i32 {
    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let image_root = image_root();
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root);

    if vz.is_provisioned() {
        println!(
            "{{\"status\":\"already_provisioned\",\"path\":\"{}\"}}",
            vz.rootfs_image_path().display()
        );
        return 0;
    }

    let manifest = match tillandsias_vm_layer::recipe::Manifest::from_toml(BUNDLED_MANIFEST_TOML) {
        Ok(m) => m,
        Err(e) => {
            let escaped =
                serde_json::to_string(&e.to_string()).unwrap_or_else(|_| format!("\"{e}\""));
            println!(
                "{{\"error\":\"manifest parse: {}\",\"detail\":{}}}",
                e, escaped
            );
            return 1;
        }
    };

    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            println!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    let on_phase = |phase: &str| {
        let escaped = serde_json::to_string(phase).unwrap_or_else(|_| format!("\"{}\"", phase));
        println!("{{\"phase\":{}}}", escaped);
    };

    match rt.block_on(vz.fetch_fedora_cloud_image(&manifest, &on_phase)) {
        Ok(()) => {
            println!(
                "{{\"status\":\"provisioned\",\"path\":\"{}\"}}",
                vz.rootfs_image_path().display()
            );
            0
        }
        Err(e) => {
            let escaped = serde_json::to_string(&e).unwrap_or_else(|_| format!("\"{}\"", e));
            println!("{{\"error\":{}}}", escaped);
            1
        }
    }
}

/// How long `--exec-guest` waits for piped stdin to reach EOF before giving up
/// on it and booting anyway. Generous enough for a real producer
/// (`gh auth token | …`), short enough that an inherited-but-idle stdin costs
/// seconds instead of forever. A full boot + guest exec measures ~9s on this
/// host, so this is the same order as the work it precedes.
const STDIN_FORWARD_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Read piped stdin to EOF, but never block the caller past `timeout`.
///
/// 663-69kp ROOT CAUSE. The previous shape was `if !stdin().is_terminal() {
/// read_to_end() }` — treating "not a TTY" as "a pipe that will EOF". That
/// holds for `printf … | tray --exec-guest`, and fails for every stdin
/// inherited from a parent that keeps the write end open: an agent harness, a
/// launchd job, a background shell. There `read_to_end` blocks forever, on the
/// main thread, BEFORE the first `eprintln!` and before the VM is created —
/// which is exactly the reported symptom ("hangs before printing even
/// '[exec-guest] starting VM…', nothing reaches stderr"). Measured live
/// 2026-08-11: identical invocations, 12+ minutes silent with inherited stdin
/// vs 9s to completion with `</dev/null`. The packet's standing hypothesis was
/// a VZ storage/disk lock; it is not — no VM process is ever created.
///
/// The read happens on a detached helper thread so the timeout is real: a
/// thread parked in `read(2)` cannot be cancelled, and this is a one-shot
/// process, so the thread is left to die with it.
fn read_piped_stdin_bounded(timeout: std::time::Duration) -> Vec<u8> {
    use std::io::{IsTerminal, Read};

    if std::io::stdin().is_terminal() {
        return Vec::new();
    }
    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = std::io::stdin().read_to_end(&mut buf);
        let _ = tx.send(buf);
    });
    match rx.recv_timeout(timeout) {
        Ok(buf) => buf,
        Err(_) => {
            eprintln!(
                "[exec-guest] warning: stdin is not a terminal but sent no EOF within {}s — \
                 continuing with NO forwarded stdin.\n\
                 If you meant to pipe input, make sure the producer closes its end \
                 (e.g. `printf '…' | tillandsias-tray --exec-guest …`).\n\
                 If you did not, pass `</dev/null` to say so explicitly.",
                timeout.as_secs()
            );
            Vec::new()
        }
    }
}

/// `--exec-guest <argv...>`: boot the provisioned VM, run `argv` in the guest
/// over the control wire (the same `vsock_exec` path `VzRuntime::exec` uses),
/// print the guest's output + exit, then stop the VM. The real-path proof for
/// the idiomatic exec layer and a reusable headless smoke tool.
///
/// MUST run on the process main thread: Vz `start()`/`stop()` dispatch their VZ
/// completion handlers to the main dispatch queue and pump the CFRunLoop from
/// the calling thread, so the whole flow runs on a **current-thread** runtime on
/// the main thread (mirrors the `vz-spike` headless boot, not the tray's
/// NSApp-on-main + worker model).
///
/// @trace plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
///
/// `required_cap` is the capability the chosen argv SHAPE depends on (795-zshi):
/// `Some(CAP_EXEC_ARGV_VECTOR)` for a verbatim argv vector, `None` for the
/// flattened `/bin/bash -lc <string>` shape, which every guest has always
/// admitted. It is checked against `HelloAck.server_caps`, never against a wire
/// version — a version says what a peer IS, a capability says what it can DO,
/// and this fleet routinely runs a tray newer than the guest image beside it.
pub fn exec_guest_main(argv: Vec<String>, required_cap: Option<&'static str>) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if argv.is_empty() {
        eprintln!("--exec-guest requires a command, e.g. --exec-guest /bin/echo HELLO");
        return 2;
    }
    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true); // keep guest serial getty noise off the user terminal
    if !vz.is_provisioned() {
        eprintln!("{{\"error\":\"not provisioned; run --provision first\"}}");
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    let argv_ref: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();

    // Forward piped host stdin to the guest (delivered on the child's stdin +
    // /dev/tty), so e.g. `printf 'tok\n' | --exec-guest <login-cmd>` works.
    let stdin_bytes: Vec<u8> = read_piped_stdin_bounded(STDIN_FORWARD_TIMEOUT);

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

        eprintln!("[exec-guest] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[exec-guest] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        eprintln!("[exec-guest] running: {argv_ref:?}");
        // Connect on THIS (main) thread, not via the trait-level default
        // opener: VZ delivers the connect completion on the main dispatch
        // queue, which is only serviced while the main thread pumps the
        // CFRunLoop. The current-thread GuestTransport helper preserves the
        // per-attempt timeout that readiness probes pass down.
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        // Stream output chunk-by-chunk so long-running commands (curl, --init,
        // forge) show progress live instead of buffering until exit.
        let result = {
            use std::io::Write;
            let stdout = std::io::stdout();
            let on_chunk = |chunk: &[u8]| {
                let mut out = stdout.lock();
                let _ = out.write_all(chunk);
                let _ = out.flush();
            };
            match required_cap {
                Some(cap) => {
                    tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming_requiring(
                        stream,
                        &argv_ref,
                        &stdin_bytes,
                        cap,
                        on_chunk,
                    )
                    .await
                }
                None => {
                    tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming(
                        stream,
                        &argv_ref,
                        &stdin_bytes,
                        on_chunk,
                    )
                    .await
                }
            }
        };
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                let signal = out
                    .exit
                    .signal
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "null".to_string());
                eprintln!(
                    "{{\"status\":\"ok\",\"exit_code\":{},\"signal\":{}}}",
                    out.exit.code, signal,
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"exec: {e}\"}}");
                1
            }
        }
    })
}

/// The guest-side pre-flight both one-shot exec paths run before handing off to
/// `tillandsias-headless` (795-zshi slice 5).
///
/// THIS WAS DUPLICATED VERBATIM at two call sites — `--github-login` and
/// `--list-cloud-projects` — differing by EXACTLY ONE TOKEN, the headless
/// subcommand at the end. A `diff` of the two blocks reported a single changed
/// line. Two copies of a shell string that reaches a guest as one flattened
/// `-lc` word is the shape this whole packet is about, and it is also how this
/// codebase keeps producing paired defects: 733-mppc had two copies of
/// `open_control_wire_stream` and the same unbounded handshake was written twice
/// and fixed neither time.
///
/// WHAT IT DOES, and why each part is still here rather than deleted:
///   * three `export`s — the control-wire exec env is cleared (no host-env
///     leak), so HOME, XDG_RUNTIME_DIR and the vault base URL must be set here;
///   * `install -d -m 0700 "$XDG_RUNTIME_DIR"` — the DesktopUserSession gate
///     requires it to exist and be writable;
///   * `podman rm tillandsias-proxy` — redundant with `ensure_proxy_running`'s
///     own `rm --ignore`, and idempotent (`|| true`);
///   * the openssl block — first-use CA generation, genuinely needed;
///   * the trailing unconditional `chmod 600` — redundant since the guest gained
///     `CAP_PROXY_CA_KEY_HEAL` (795-zshi slice 4), and idempotent.
///
/// SLICE 5 WAS BRIEFED TO DELETE THE TWO REDUNDANT LINES BEHIND THAT CAPABILITY.
/// Measured first, and it does not pay: both are already `|| true`-guarded
/// no-ops on a healed guest, NEITHER is among the packet's five named
/// workarounds, and removing them leaves the exports, the `install -d` and the
/// openssl block — so the preamble REMAINS a shell script and not one
/// flattening workaround becomes deletable. Buying that with a second
/// connection and handshake purely to read one capability is a bad trade on a
/// path with wedge history. The real blocker is the openssl/env work, which has
/// to move guest-side or into the structured env field, exactly as slice 2 said.
/// So this slice takes the reduction that IS real — one copy instead of two —
/// and leaves the capability gate unspent for the slice that can use it.
/// ORDER 998-qrwu: the CA directory is interpolated from the ONE declaration
/// (images/ca-path.txt via tillandsias-core), not written eight times into this
/// string. It is a SHELL preamble, so the path appears here as text rather than
/// as a path value — which is exactly why it escaped every earlier attempt to
/// single-source it, and why 975-rsgm could not move the directory safely.
fn proxy_exec_preamble(headless_arg: &str) -> String {
    // ORDER 1002-9xmb: the TEMPLATE, not the expansion. This string is exec'd
    // IN THE GUEST, and the very next thing it does is `export HOME=/root`.
    // `ca_dir()` would substitute the HOST's HOME here, so a Mac emitted
    // `/Users/<you>/.local/state/tillandsias/ca` for the guest to create — and
    // measured in a live guest, that path SUCCEEDS: mkdir as root, openssl
    // writes, perms 600, owner root, exit 0. Nothing fails, so nothing would
    // ever have reported it. The guest shell expands `${HOME}` itself, which
    // is the only expansion standing in the filesystem the path names.
    let ca = tillandsias_core::ca_path::ca_dir_template();
    format!(
        "export HOME=/root; export XDG_RUNTIME_DIR=/run/user/0; \
         export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200; \
         install -d -m 0700 \"$XDG_RUNTIME_DIR\"; \
         podman rm tillandsias-proxy 2>/dev/null || true; \
         if ! test -s {ca}/intermediate.key 2>/dev/null; then \
           mkdir -p {ca} && \
           openssl req -x509 -newkey rsa:2048 \
             -keyout {ca}/intermediate.key \
             -out {ca}/intermediate.crt \
             -days 25 -nodes -subj '/CN=Tillandsias CA' 2>/dev/null && \
           chmod 600 {ca}/intermediate.key || true; \
         fi; \
         chmod 600 {ca}/intermediate.key 2>/dev/null || true; \
         exec /usr/local/bin/tillandsias-headless {headless_arg}"
    )
}

/// How long a NON-INTERACTIVE stdin gets to answer a prompt before we give up.
///
/// Generous compared to `STDIN_FORWARD_TIMEOUT`'s 5s, because a pipe feeding a
/// three-prompt login may be doing real work between lines. Still bounded,
/// because the alternative is unbounded (see `prompt_line`).
const PROMPT_LINE_PIPED_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Prompt the user on the host terminal and read a single line. When `hidden`,
/// terminal echo is disabled via `stty -echo` for the duration (no extra crate
/// dep) so secrets like the PAT are not shown. Returns the trimmed line, or an
/// empty string when stdin could not answer — callers already treat empty as a
/// hard error.
///
/// 663-69kp THIRD PATH. 689-stig bounded the `--exec-guest` stdin read and
/// 689-y2my dealt with the guest heartbeat resetting the exec idle deadline.
/// This function was the remaining unbounded read, and it is the one
/// `--github-login` uses (three call sites). It is worse-placed than the one
/// 689-stig fixed, in a way that changes the SIGNATURE of the hang:
///
///   * `read_line` here had NO `is_terminal()` guard and no timeout at all;
///   * it is called from inside a `DynamicExpect` response closure, i.e. AFTER
///     the VM is booted and the control-wire stream is open — so the symptom is
///     NOT the pre-breadcrumb silence of 689-stig, it is a wedge that already
///     printed its progress lines and is holding a live VM;
///   * and per the comment on the `expects` list below, the guest's 30s PTY
///     heartbeat keeps resetting the exec idle deadline (689-y2my), so nothing
///     upstream bounds the wait either.
///
/// So an unattended `--github-login` WITHOUT `--with-token` boots a VM, reaches
/// the guest's token prompt, and then blocks here forever on a stdin whose
/// parent never closes the write end — an agent harness, a launchd job, a
/// background shell. The 07-29 prompt-ordering deadlock the comment below
/// describes was a SECOND, independent cause of the same 70-minute wedges; it
/// was fixed by reordering, which is why this one survived.
///
/// The rule mirrors 689-stig's insight — "not a TTY" is not "a pipe that will
/// EOF" — without breaking interactive use:
///   * stdin IS a terminal: read unbounded. A human is reading the prompt and
///     typing a token; timing that out would be the bug.
///   * stdin is NOT a terminal: bounded, and on expiry refuse LOUDLY telling the
///     operator how to answer by pipe.
///
/// The refusal deliberately does NOT suggest `--with-token`. That is a
/// tillandsias-headless (GUEST) flag with no macOS host equivalent, and
/// suggesting it here would repeat 663-acdw, where it cost one session two blind
/// credential runs. On macOS the host drives the guest login over the control
/// wire, so PIPING credentials to `--github-login` is the supported unattended
/// path (main.rs:262-271 is the authority) — which is exactly the path this
/// bounded read has to keep working, not merely tolerate.
fn prompt_line(label: &str, hidden: bool) -> String {
    use std::io::{IsTerminal, Write};

    print!("{label}: ");
    let _ = std::io::stdout().flush();

    // Echo suppression must be undone on EVERY exit from this function,
    // including the timeout path. Leaving a terminal with echo off after an
    // already-confusing hang is a hostile end state, and it outlives the
    // process.
    if hidden {
        let _ = std::process::Command::new("stty").arg("-echo").status();
    }
    let restore_echo = || {
        if hidden {
            let _ = std::process::Command::new("stty").arg("echo").status();
            println!(); // newline the suppressed Enter would have produced
        }
    };

    if std::io::stdin().is_terminal() {
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        restore_echo();
        return line.trim().to_string();
    }

    // Non-interactive: the read happens on a detached helper thread so the
    // timeout is real — a thread parked in `read(2)` cannot be cancelled. This
    // is a one-shot process, so the thread is left to die with it.
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        let _ = tx.send(line);
    });
    match rx.recv_timeout(PROMPT_LINE_PIPED_TIMEOUT) {
        Ok(line) => {
            restore_echo();
            line.trim().to_string()
        }
        Err(_) => {
            restore_echo();
            eprintln!(
                "[github-login] stdin is not a terminal and sent no line for \"{label}\" \
                 within {}s — refusing to wait longer.\n\
                 A VM is already booted and the guest is waiting at its prompt, so an \
                 unbounded wait here holds a live VM open indefinitely (663-69kp).\n\
                 On macOS the host drives the guest login over the control wire, so pipe \
                 the answers in — one full line each, in this order (token, author name, \
                 author email), with the producer closing its end:\n\
                 \x20 printf '%s\\n%s\\n%s\\n' \"$TOKEN\" \"$NAME\" \"$EMAIL\" \
                 | tillandsias-tray --github-login\n\
                 (`--with-token` is a tillandsias-headless GUEST flag and is NOT accepted \
                 here — see 663-acdw.)",
                PROMPT_LINE_PIPED_TIMEOUT.as_secs()
            );
            String::new()
        }
    }
}

/// `--transport-conformance`: run the shared GuestTransport conformance
/// fixtures (order 128) against the live VZ backend (order 126 exit
/// criterion 3, "both primitives pass the shared conformance fixtures on
/// Darwin").
///
/// Threading: the fixtures call the REAL trait methods
/// (`GuestTransport::{open_stream, exec, exec_streaming}`), whose VZ connect
/// completions land on the main dispatch queue. A headless caller that parks
/// the main thread in `block_on` would deadlock them (see
/// `open_vsock_stream_current_thread` docs) — so boot + readiness run on the
/// main thread (their helpers pump internally), the fixture set runs on a
/// worker-thread runtime, and the main thread pumps the CFRunLoop until the
/// worker finishes. That is the same division of labor as the AppKit tray,
/// so the run proves the exact code path production uses.
///
/// Verdict grammar (greppable, falsifiable):
/// `transport-conformance: PASS n=<N>` or
/// `transport-conformance: FAIL <fixture>: <reason>`.
pub fn transport_conformance_main() -> i32 {
    use std::sync::Arc;
    use std::time::Duration;
    use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
    use tillandsias_vm_layer::VmRuntime;
    use tillandsias_vm_layer::transport_conformance::{
        all_passed, render_report, run_all_with_progress,
    };

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = Arc::new(tillandsias_vm_layer::vz::VzRuntime::new(3, image_root()));
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    // Boot + readiness on the main thread (helpers pump the runloop).
    let booted = rt.block_on(async {
        eprintln!("[transport-conformance] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return false;
        }
        eprintln!("[transport-conformance] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            return false;
        }
        true
    });
    if !booted {
        let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
        return 1;
    }

    // Fixtures on a worker runtime; main thread pumps the CFRunLoop so the
    // trait-level VZ connects (spawn_blocking + main-queue completion) fire.
    eprintln!("[transport-conformance] running shared fixtures over GuestEndpoint::MacVz…");
    let worker_vz = Arc::clone(&vz);
    let worker = std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("worker tokio runtime: {e}"))?;
        let ep = GuestEndpoint::MacVz {
            port: CONTROL_WIRE_VSOCK_PORT,
        };
        Ok::<_, String>(rt.block_on(async {
            let t: &dyn tillandsias_control_wire::guest_transport::GuestTransport = &*worker_vz;
            // Stream each verdict as it lands (loud floor; a buffered
            // report hides which fixture is hanging).
            run_all_with_progress(t, &ep, &mut |r| match &r.outcome {
                Ok(()) => eprintln!("[transport-conformance] fixture {} ok", r.name),
                Err(e) => eprintln!("[transport-conformance] fixture {} FAIL: {e}", r.name),
            })
            .await
        }))
    });
    while !worker.is_finished() {
        tillandsias_vm_layer::vz::boot::pump_cf_loop_for(Duration::from_millis(50));
    }
    let results = match worker.join() {
        Ok(Ok(results)) => results,
        Ok(Err(e)) => {
            eprintln!("{{\"error\":\"{e}\"}}");
            let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
            return 1;
        }
        Err(_) => {
            eprintln!("{{\"error\":\"conformance worker panicked\"}}");
            let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
            return 1;
        }
    };

    print!("{}", render_report(&results));
    let _ = rt.block_on(vz.stop(Duration::from_secs(10)));
    if all_passed(&results) { 0 } else { 1 }
}

/// `--github-login`: boot the VM and drive the *released* guest
/// `tillandsias-headless --github-login` over the control wire. Each end user is
/// **prompted on the host terminal for their OWN** git author name, git author
/// email, and GitHub PAT — nothing is defaulted from the operator's host git
/// config. The token echo is suppressed (`stty -echo`) and the values are fed to
/// the guest's prompts via the proven expect-style PTY input path, so the token
/// lands on the guest `/dev/tty` and never appears in `argv`. (The host process
/// does hold the token transiently in memory while delivering it; it is never
/// logged or written to argv.)
///
/// Operator usage: run in a terminal and answer the prompts —
///   tillandsias-tray --github-login
///
/// @trace spec:gh-auth-script, plan/issues/optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md
pub fn github_login_main() -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true); // keep guest serial getty noise off the user terminal
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::{DynamicExpect, exec_over_stream_expect_dynamic};

        eprintln!("[github-login] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[github-login] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!(
            "[github-login] control wire ready; guest auth preflight runs before credential prompts"
        );
        // ORDER IS LOAD-BEARING and must track the GUEST, which prompts
        // CREDENTIAL FIRST, identity second — see the operator directive of
        // 2026-07-29 quoted at crates/tillandsias-headless/src/main.rs:7647
        // ("Prompting for name/email before the token led operators to believe
        // those fields WERE their GitHub credentials").
        //
        // This list said name -> email -> token, i.e. the pre-07-29 guest, and
        // `DynamicExpect` is strictly sequential: the host scanned for "author
        // name" while the guest sat blocked on its token prompt, and neither
        // side could move. That deadlock is silent and, because the guest's 30s
        // PTY heartbeat keeps resetting the exec idle deadline (689-y2my), it
        // is also unbounded — the 70-minute wedges of 2026-08-10/11. The
        // attended login of 2026-07-24 worked precisely because it predates the
        // guest's reorder.
        let expects = vec![
            DynamicExpect {
                needle: b"authentication token".to_vec(),
                label: "github token".to_string(),
                response: Box::new(|| {
                    let pat = prompt_line("GitHub Personal Access Token (hidden)", true);
                    if pat.is_empty() {
                        return Err("--github-login: a GitHub token is required".to_string());
                    }
                    Ok(format!("{pat}\n").into_bytes())
                }),
            },
            DynamicExpect {
                needle: b"author name".to_vec(),
                label: "git author name".to_string(),
                response: Box::new(|| {
                    let name = prompt_line("Git author name", false);
                    if name.is_empty() {
                        return Err(
                            "--github-login: git author name and email are both required"
                                .to_string(),
                        );
                    }
                    Ok(format!("{name}\n").into_bytes())
                }),
            },
            DynamicExpect {
                needle: b"author email".to_vec(),
                label: "git author email".to_string(),
                response: Box::new(|| {
                    let email = prompt_line("Git author email", false);
                    if email.is_empty() {
                        return Err(
                            "--github-login: git author name and email are both required"
                                .to_string(),
                        );
                    }
                    Ok(format!("{email}\n").into_bytes())
                }),
            },
        ];
        eprintln!("[github-login] driving guest login (token -> git name -> email)…");
        let github_login_preamble = proxy_exec_preamble("--github-login");
        let result = exec_over_stream_expect_dynamic(
            stream,
            &[
                "/bin/bash",
                "-lc",
                // The control-wire exec env is cleared (no host-env leak), but
                // the guest `--github-login` needs:
                //   - HOME: prompt_and_store_git_identity writes the managed
                //     git identity (name/email — not the token) under $HOME.
                //   - XDG_RUNTIME_DIR (+writable): require_desktop_user_session
                //     gate on the DesktopUserSession lane.
                //   - TILLANDSIAS_VAULT_API_BASE_URL: the guest vault bootstrap
                //     probes the enclave service DNS name, not the default
                //     loopback publish which is Linux-only.
                // The GitHub token itself is handled by the released flow inside
                // an ephemeral `--rm` git container (piped to `gh auth login
                // --with-token`, written to Vault, container destroyed on exit),
                // so nothing unencrypted is left at rest here.
                //
                // Pre-flight before handing off to headless:
                //   1. Remove any exited proxy container from a prior attempt so
                //      `ensure_proxy_running` can `podman run --name tillandsias-proxy`
                //      without "name already in use".
                //   2. Clamp the ephemeral CA key to 0o600 and heal an existing
                //      widened key DOWN (772-shi9).
                //      This block used to chmod 644 "so Squid (uid 1000) can read
                //      it". That reason is FALSE since 755-qcxh: the key reaches
                //      the proxy as the `tillandsias-ca-key` podman secret
                //      (uid=1000,gid=1000,mode=0400 — main.rs
                //      PROXY_CA_KEY_SECRET_OPTS), and images/proxy/entrypoint.sh
                //      reads ONLY /run/secrets/tillandsias-ca-key, exiting 1 when
                //      it is absent. Nothing in the guest reads this file's mode:
                //      the headless that writes and re-reads it runs as root
                //      (vz.rs writes the unit with no User=).
                //      The heal is UNCONDITIONAL, outside the `test -s` guard,
                //      because an already-present 0644 key skips the openssl block
                //      entirely — and `ensure_proxy_running` early-returns when the
                //      proxy is already up, BEFORE the ensure_ca_bundle call that
                //      would otherwise heal it, so the widened key would survive
                //      for the VM's lifetime.
                // 795-zshi slice 5: one builder, two call sites. See
                // `proxy_exec_preamble` for what each part does and why the two
                // redundant lines are still in it.
                &github_login_preamble,
            ],
            expects,
            |ev| eprintln!("[github-login] {ev}"),
        )
        .await;

        // 701-g98y: capture the NEW epoch's handover into the host Keychain
        // BEFORE stopping the VM.
        //
        // A successful login initializes a fresh Vault inside the guest, so the
        // guest now holds a share and root token the host has never seen — the
        // Keychain still holds the PREVIOUS epoch. Until this call existed, that
        // divergence was permanent for a CLI login: the capture half runs only
        // from the GUI tray's paths (action_host.rs), and when the tray next
        // connected it would DELIVER its stale Keychain values into the guest
        // first — overwriting the epoch this command had just created — and only
        // then ask for a handover that was no longer pending. Seeding from the
        // CLI and then opening the tray could therefore destroy the credential
        // the CLI had just proven durable.
        //
        // Capture only, never deliver: this process is the one that CAUSED the
        // new epoch, so anything it holds is older by construction.
        //
        // Best-effort by design — the login itself has already succeeded and its
        // exit code must not change here. A failure is reported loudly because
        // the consequence (a later tray launch clobbering a good credential) is
        // silent and expensive.
        if matches!(&result, Ok(out) if out.exit.code == 0) {
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(hstream) => {
                    use tillandsias_control_wire::transport::Transport;
                    use tillandsias_host_shell::vsock_client::Client;
                    let mut client = Client::from_stream(
                        Box::new(hstream),
                        Transport::Vsock {
                            // Same guest CID the VzRuntime was constructed with
                            // at the top of this function.
                            cid: 3,
                            port: CONTROL_WIRE_VSOCK_PORT,
                        },
                    );
                    match client.handshake().await {
                        Ok(_) => {
                            match crate::installation_uuid::capture_vault_handover(&mut client).await
                            {
                                Ok(true) => eprintln!(
                                    "[github-login] host Keychain updated with this login's vault handover"
                                ),
                                // Say what actually happened. A guest holds a
                                // pending handover ONLY after a FRESH Vault init;
                                // a login that reused an already-initialized
                                // Vault has nothing to hand over, and claiming
                                // "updated" there is a success message with no
                                // evidence behind it. IMPORTANT for the operator:
                                // this branch means the Keychain still holds
                                // whatever epoch it held before, which may be
                                // OLDER than the guest's — 701-g98y's hazard is
                                // NOT cleared by this path.
                                Ok(false) => eprintln!(
                                    "[github-login] no pending vault handover to capture — the guest reused an \
                                     already-initialized Vault, so the host Keychain is UNCHANGED. If it was \
                                     already older than the guest's epoch it still is; re-verify with \
                                     --list-cloud-projects after the first tray start (701-g98y)."
                                ),
                                Err(e) => eprintln!(
                                    "[github-login] WARNING: could not capture the vault handover ({e}). \
                                     The login succeeded, but the host Keychain still holds an OLDER epoch — \
                                     opening the tray may overwrite this credential. Re-verify with \
                                     --list-cloud-projects after the first tray start (701-g98y)."
                                ),
                            }
                        }
                        Err(e) => eprintln!(
                            "[github-login] WARNING: handover capture handshake failed ({e}); host Keychain not updated (701-g98y)"
                        ),
                    }
                }
                Err(e) => eprintln!(
                    "[github-login] WARNING: handover capture could not connect ({e}); host Keychain not updated (701-g98y)"
                ),
            }
        }

        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                // Guest output is safe to print: name/email are not secret and
                // the token prompt is `read -rs` (never echoed to the PTY).
                use std::io::Write;
                let _ = std::io::stdout().write_all(&out.stdout);
                let _ = std::io::stdout().flush();
                println!();
                println!(
                    "{{\"status\":\"login-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                if out.exit.code == 0 {
                    eprintln!(
                        "[github-login] SUCCESS — the token is in the guest Vault. \
                         Click the tray; the menu should reveal the project submenus."
                    );
                }
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"login: {e}\"}}");
                1
            }
        }
    })
}

/// `--list-cloud-projects`: boot the VM and run the in-guest
/// `tillandsias-headless --list-cloud-projects` over the control wire, streaming
/// the repo listing to stdout. Mirrors the Linux headless CLI mode for 1:1 tray
/// parity (order 128 parity-matrix row `list-cloud-projects`).
///
/// Requires a prior `--github-login` run to have stored the GitHub token in Vault.
/// `--diagnose --with-metrics`: the ONLY path that reads guest metrics over
/// the control wire (778-n9z2 exit criterion 1).
///
/// Separate from `main(format)` deliberately. A standalone `--diagnose` must
/// stay a static, VM-free report: `scripts/install-macos.sh` runs
/// `--diagnose --json` synchronously during install, so booting a VM on the
/// default path would start a guest mid-install and could collide with a live
/// tray's VM handle. `main.rs` gates this verb with `require_no_live_tray`
/// for the same reason every other VM-booting one-shot is gated (order 277).
///
/// The exit code stays the ordinary `exit_code_from(&report)` contract
/// {0,3,2,1}: a metrics failure is reported IN the report, never by changing
/// the code an operator's script branches on.
///
/// @trace spec:observability-metrics, spec:macos-native-tray
pub fn metrics_snapshot_main(format: DiagnoseFormat) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    let mut report = collect_report();

    if let Err(err) = stage_embedded_guest_binary() {
        report.metrics_status = "error:stage-guest-binary".to_string();
        eprintln!("[diagnose] stage guest binary: {err}");
        return finish_metrics_report(report, format);
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        report.metrics_status = "error:not-provisioned".to_string();
        eprintln!("[diagnose] not provisioned; run --provision or launch the tray once first");
        return finish_metrics_report(report, format);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            report.metrics_status = "error:tokio-runtime".to_string();
            eprintln!("[diagnose] tokio runtime: {e}");
            return finish_metrics_report(report, format);
        }
    };

    let outcome: Result<Option<tillandsias_control_wire::MetricsSnapshotWire>, String> = rt
        .block_on(async {
            use std::time::Duration;
            use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;

            eprintln!("[diagnose] starting VM for the metrics read…");
            vz.start().await.map_err(|e| format!("start: {e}"))?;
            let result = async {
                vz.wait_phase_ready(Duration::from_secs(300), |t| {
                    probe_phase_secure_or_plain(&vz, t)
                })
                .await
                .map_err(|e| format!("wait_phase_ready: {e}"))?;
                let stream =
                    open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                        .await
                        .map_err(|e| format!("vsock connect: {e}"))?;
                tillandsias_vm_layer::vsock_exec::fetch_metrics_snapshot(stream).await
            }
            .await;
            // Stop the VM whatever happened: this verb owns the VM it booted.
            let _ = vz.stop(Duration::from_secs(10)).await;
            result
        });

    match outcome {
        Ok(Some(snapshot)) => {
            report.metrics = Some(snapshot);
            report.metrics_status = "ok".to_string();
        }
        Ok(None) => {
            // Handshake fine, capability absent — an older guest, not a fault.
            report.metrics_status = METRICS_STATUS_NO_CAPABILITY.to_string();
        }
        Err(e) => {
            eprintln!("[diagnose] metrics read failed: {e}");
            report.metrics_status = "error:wire-read".to_string();
        }
    }
    finish_metrics_report(report, format)
}

/// Print a metrics-bearing report and return the ordinary diagnose exit code.
fn finish_metrics_report(report: DiagnoseReport, format: DiagnoseFormat) -> i32 {
    match format {
        DiagnoseFormat::Human => print_human(&report),
        DiagnoseFormat::Json => print_json(&report),
    }
    exit_code_from(&report)
}

/// Applies the same CA cert / exited-proxy workaround as `github_login_main`
/// (TODO linux-next: remove once headless uses 0o640 + rm-on-reuse).
///
/// @trace spec:remote-projects, plan/issues/tray-feature-parity-matrix-2026-06-28.md
pub fn list_cloud_projects_main() -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming;

        eprintln!("[list-cloud-projects] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[list-cloud-projects] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!("[list-cloud-projects] control wire ready; fetching remote projects…");

        // Same CA cert + exited-proxy workaround as github_login_main, including
        // the 0o600 clamp and the unconditional heal-down (772-shi9 — see the
        // reasoning at that site: the proxy gets the key as a 0400 podman
        // secret, so no reader ever needed this file widened).
        let cmd = proxy_exec_preamble("--list-cloud-projects");

        let result = exec_over_stream_with_input_streaming(
            stream,
            &["/bin/bash", "-lc", cmd.as_str()],
            &[],
            |chunk| {
                use std::io::Write;
                let _ = std::io::stdout().write_all(chunk);
                let _ = std::io::stdout().flush();
            },
        )
        .await;
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                eprintln!(
                    "{{\"status\":\"list-cloud-projects-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"list-cloud-projects: {e}\"}}");
                1
            }
        }
    })
}

/// `--opencode <path> [--prompt <text>]`: boot the VM and run the in-guest
/// `tillandsias-headless --opencode <path>` over the control wire, streaming
/// PTY output to the host terminal in real-time. When `--prompt` is given the
/// forge runs non-interactively (one shot + exit); without it the session is
/// open-ended until the user exits.
///
/// @trace plan/issues/smoke-curl-install-e2e-macos-v0.3.260626.4-2026-06-26.md
/// Guest-side root where the host's `~/src` arrives via the `home-src`
/// virtiofs share (vz.rs cloud-init fstab entry).
const GUEST_SRC_ROOT: &str = "/home/forge/src";

/// Order 331: translate an operator-supplied project path into the
/// guest-visible form, BEFORE booting the VM.
///
/// Pure over already-absolute host paths so it is unit-pinnable:
/// - a path already under `/home/forge/src` passes through verbatim
///   (the operator supplied the guest form);
/// - a path under `<host_home>/src/…` rewrites to `/home/forge/src/…`
///   (only `~/src` is shared into the guest, so only it can translate);
/// - anything else is rejected with a message naming both accepted forms —
///   failing on the host in milliseconds instead of after a ~60s boot with
///   the guest's opaque "Project not found" (live repro 2026-07-13).
pub fn translate_project_path_for_guest(abs_path: &str, host_home: &str) -> Result<String, String> {
    let guest_root = std::path::Path::new(GUEST_SRC_ROOT);
    let p = std::path::Path::new(abs_path);
    if p.starts_with(guest_root) {
        return Ok(abs_path.to_string());
    }
    let host_src = std::path::Path::new(host_home).join("src");
    if let Ok(rest) = p.strip_prefix(&host_src) {
        if rest.as_os_str().is_empty() {
            return Err(format!(
                "--opencode needs a project INSIDE {}, not the src root itself",
                host_src.display()
            ));
        }
        return Ok(guest_root.join(rest).to_string_lossy().into_owned());
    }
    Err(format!(
        "--opencode project path must be under {} (host form) or {} (guest form); got: {}. \
         Only ~/src is shared into the guest, so projects elsewhere are not visible to the forge.",
        host_src.display(),
        GUEST_SRC_ROOT,
        abs_path
    ))
}

/// Host-side wrapper for [`translate_project_path_for_guest`]: resolves
/// relative paths (including the bare-`.` default) against the current
/// directory via `canonicalize` when the path exists on the host, then
/// applies the pure translation.
fn resolve_project_path_pre_boot(raw: &str) -> Result<String, String> {
    let host_home = std::env::var("HOME").map_err(|_| "HOME is not set".to_string())?;
    // Guest-absolute paths don't exist on the host; skip canonicalize.
    if raw.starts_with(GUEST_SRC_ROOT) {
        return translate_project_path_for_guest(raw, &host_home);
    }
    let abs = std::fs::canonicalize(raw)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| raw.to_string());
    translate_project_path_for_guest(&abs, &host_home)
}

pub fn opencode_main(path: String, prompt: Option<String>) -> i32 {
    use tillandsias_vm_layer::VmRuntime;

    // Order 331: translate/validate on the host BEFORE any VM work.
    let path = match resolve_project_path_pre_boot(&path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{{\"error\":\"{e}\"}}");
            return 2;
        }
    };

    if let Err(err) = stage_embedded_guest_binary() {
        eprintln!("{{\"error\":\"stage guest binary: {err}\"}}");
        return 1;
    }
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root());
    vz.set_serial_to_log(true);
    if !vz.is_provisioned() {
        eprintln!(
            "{{\"error\":\"not provisioned; run --provision or launch the tray once first\"}}"
        );
        return 1;
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{{\"error\":\"tokio runtime: {e}\"}}");
            return 1;
        }
    };

    rt.block_on(async move {
        use std::time::Duration;
        use tillandsias_control_wire::transport::CONTROL_WIRE_VSOCK_PORT;
        use tillandsias_vm_layer::vsock_exec::exec_over_stream_with_input_streaming;

        eprintln!("[opencode] starting VM…");
        if let Err(e) = vz.start().await {
            eprintln!("{{\"error\":\"start: {e}\"}}");
            return 1;
        }
        eprintln!("[opencode] waiting for VM phase Ready…");
        if let Err(e) = vz
            .wait_phase_ready(Duration::from_secs(300), |t| {
                probe_phase_secure_or_plain(&vz, t)
            })
            .await
        {
            eprintln!("{{\"error\":\"wait_phase_ready: {e}\"}}");
            let _ = vz.stop(Duration::from_secs(10)).await;
            return 1;
        }
        let stream =
            match open_control_wire_stream(&vz, CONTROL_WIRE_VSOCK_PORT, Duration::from_secs(30))
                .await
            {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{{\"error\":\"vsock connect: {e}\"}}");
                    let _ = vz.stop(Duration::from_secs(10)).await;
                    return 1;
                }
            };
        eprintln!("[opencode] control wire ready; launching forge in guest…");

        // Build the shell command for the guest: set required env vars and
        // exec the headless binary with --opencode and optional --prompt.
        // TILLANDSIAS_FORGE_SRC_ISOLATION=clone (order 342): the macOS lane
        // shares the operator's real checkout into the guest over virtiofs,
        // so the forge MUST work on a guest-owned clone — a blocked in-forge
        // cycle once git-cleaned sibling work through this share
        // (plan/issues/forge-shared-checkout-destructive-clean-2026-07-13.md).
        let mut headless_cmd = format!(
            "export HOME=/root; \
             export XDG_RUNTIME_DIR=/run/user/0; \
             export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200; \
             export TILLANDSIAS_FORGE_SRC_ISOLATION=clone; \
             install -d -m 0700 \"$XDG_RUNTIME_DIR\"; \
             exec /usr/local/bin/tillandsias-headless --opencode {path}"
        );
        if let Some(ref p) = prompt {
            // Shell-quote the prompt so spaces/special chars are safe.
            let escaped: String = p
                .chars()
                .flat_map(|c| {
                    if c == '\'' {
                        vec!['\'', '\\', '\'', '\'']
                    } else {
                        vec![c]
                    }
                })
                .collect();
            headless_cmd.push_str(&format!(" --prompt '{escaped}'"));
        }

        let argv: &[&str] = &["/bin/bash", "-lc", &headless_cmd];
        let result = exec_over_stream_with_input_streaming(stream, argv, &[], |chunk| {
            use std::io::Write;
            let _ = std::io::stdout().write_all(chunk);
            let _ = std::io::stdout().flush();
        })
        .await;
        let _ = vz.stop(Duration::from_secs(10)).await;

        match result {
            Ok(out) => {
                eprintln!(
                    "{{\"status\":\"opencode-finished\",\"exit_code\":{}}}",
                    out.exit.code
                );
                out.exit.code
            }
            Err(e) => {
                eprintln!("{{\"error\":\"opencode: {e}\"}}");
                1
            }
        }
    })
}

/// Extract the first 12-char SHA-256 prefix for `aarch64.qcow2` from a
/// manifest.toml body. Pure, testable — both the quoted-key form
/// (`"aarch64.qcow2" = "<sha>"`, the actual file) and the bare-key
/// form (`aarch64.qcow2 = "<sha>"`) parse. Returns the 12-char prefix
/// or None if no valid pin is found.
fn parse_aarch64_qcow2_sha(manifest_toml: &str) -> Option<String> {
    for line in manifest_toml.lines() {
        let trimmed = line.trim().trim_start_matches('"');
        if let Some(rest) = trimmed.strip_prefix("aarch64.qcow2") {
            let rest = rest.trim_start_matches(['"', ' ', '=', '"']);
            let sha: String = rest.chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            if sha.len() >= 12 {
                return Some(sha[..12].to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use tillandsias_control_wire::secure_wire_mode::{SecureWireMode, parse_secure_wire_mode};

    /// 972-umik. THE macOS LANE PAIRS SERVER AND CLIENT UNDER THE SHARED
    /// READER'S `On`.
    ///
    /// The conversion's risk is not that the parse is wrong — it is that this
    /// crate and its peer stop agreeing about WHICH mode they are in, and a
    /// disagreement is invisible until a real guest refuses to talk. So this
    /// drives the actual handshake both sides use, with the psk built from the
    /// same expression `probe_phase_secure_or_plain` uses, and passes a frame
    /// through it.
    #[tokio::test]
    async fn macos_lane_pairs_server_and_client_under_shared_reader_on() {
        use tillandsias_secure_channel::{HopId, channel_psk};
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        // Precondition, asserted rather than assumed: this test is only about
        // the secure path, so a build whose shared reader stopped offering On
        // must fail here rather than silently test nothing.
        assert_eq!(
            parse_secure_wire_mode(Ok("on".to_string())),
            Ok(SecureWireMode::On),
            "the shared reader must still resolve 'on' to On"
        );

        let psk = channel_psk(
            tillandsias_secure_channel::workspace_version(),
            tillandsias_control_wire::WIRE_VERSION,
            HopId::HostGuest,
        );
        let psk_server = *psk;
        let psk_client = *psk;

        let (host, guest) = tokio::io::duplex(64 * 1024);

        let server = tokio::spawn(async move {
            let mut s =
                tillandsias_secure_channel::secure_stream::server_handshake(guest, &psk_server)
                    .await
                    .expect("server handshake");
            let mut buf = [0u8; 5];
            s.read_exact(&mut buf).await.expect("server read");
            s.write_all(b"pong!").await.expect("server write");
            buf
        });

        let mut c = tillandsias_secure_channel::secure_stream::client_handshake(host, &psk_client)
            .await
            .expect("client handshake");
        c.write_all(b"ping!").await.expect("client write");
        let mut back = [0u8; 5];
        c.read_exact(&mut back).await.expect("client read");

        assert_eq!(&server.await.expect("server task")[..], b"ping!");
        assert_eq!(&back[..], b"pong!");
    }

    /// 972-umik. THE DEFAULT IS THE SHARED READER'S, NOT A LOCAL ONE.
    ///
    /// Absent still means Off today; the flip to On belongs to the commit that
    /// converts the LAST reader (yolanda holds it, hvsocket.rs). Pinned through
    /// the pure parser so no process-global `set_var` is touched — that race is
    /// how three ca_path tests failed under concurrent cargo (1002-9xmb).
    ///
    /// THE BLANK CASE IS A DELIBERATE BEHAVIOUR CHANGE ON macOS. Both readers
    /// this crate used to carry matched `raw.is_empty()` to Off, so a blank
    /// variable meant PLAINTEXT here. The shared reader refuses blank, because
    /// blank is the shape an unfilled CI variable takes and reading it as
    /// insecure is the worst available guess. This is the conversion's one
    /// non-mechanical effect and it is asserted rather than left to be noticed.
    #[test]
    fn shared_reader_owns_the_default_and_refuses_blank() {
        // 972-umik FLIPPED, and this pin is what noticed. It asserted
        // absent -> Off "until the last reader is converted"; yolanda converted
        // the last one (hvsocket.rs) and landed the flip, the ratchet now reads
        // ok:secure-wire-single-reader:0 of 0, and this test went red on the
        // merge — which is the pin doing its job, not a regression.
        //
        // ABSENT NOW MEANS SECURE. That is the direction a default should move
        // and the reason the flip waited for every reader: a host that reads
        // the variable itself could otherwise disagree with the shared reader
        // about what "unset" means, and one of them would be running plaintext
        // while believing otherwise.
        assert_eq!(
            parse_secure_wire_mode(Err(std::env::VarError::NotPresent)),
            Ok(SecureWireMode::On),
            "absent must mean On now that every reader is converted (972-umik)"
        );
        assert!(
            parse_secure_wire_mode(Ok(String::new())).is_err(),
            "blank must be an error, not the plaintext this crate used to infer"
        );
    }

    /// 795-zshi slice 5. The two exec preambles were duplicated VERBATIM and
    /// differed by exactly one token — a `diff` of the two blocks reported a
    /// single changed line. This pins the property that made the duplication
    /// dangerous rather than merely untidy: the guest-side pre-flight must be
    /// THE SAME for both one-shot paths, so a fix to one cannot miss the other.
    ///
    /// That is not a hypothetical concern in this file. 733-mppc found two
    /// copies of `open_control_wire_stream` where the identical unbounded
    /// handshake had been written twice and fixed neither time.
    #[test]
    fn both_exec_paths_share_one_preamble_differing_only_in_the_subcommand() {
        let login = super::proxy_exec_preamble("--github-login");
        let projects = super::proxy_exec_preamble("--list-cloud-projects");

        let marker = "exec /usr/local/bin/tillandsias-headless ";
        let login_head = login.split(marker).next().expect("login preamble head");
        let projects_head = projects.split(marker).next().expect("projects head");
        assert_eq!(
            login_head, projects_head,
            "both one-shot paths must run the IDENTICAL guest pre-flight; divergence here is \
             how a fix lands on one path and misses the other"
        );
        assert!(login.ends_with(&format!("{marker}--github-login")));
        assert!(projects.ends_with(&format!("{marker}--list-cloud-projects")));
    }

    /// The pre-flight's parts, asserted so a future edit cannot quietly drop one.
    ///
    /// Each is load-bearing for a reason recorded at `proxy_exec_preamble`: the
    /// control-wire exec env is CLEARED, so the three exports are the only way
    /// HOME / XDG_RUNTIME_DIR / the vault base URL reach the guest; the
    /// `install -d` satisfies the DesktopUserSession gate; the openssl block is
    /// first-use CA generation.
    ///
    /// The two REDUNDANT lines (`podman rm`, the trailing `chmod 600`) are
    /// asserted present ON PURPOSE. Slice 5 was briefed to delete them behind
    /// CAP_PROXY_CA_KEY_HEAL and measured that it does not pay — both are
    /// already `|| true` no-ops, neither is among the packet's five named
    /// workarounds, and removing them leaves the preamble a shell script
    /// regardless. If a later slice DOES delete them it must edit this test,
    /// which is the point: the deletion should be a decision, not a drift.
    #[test]
    fn the_preamble_keeps_every_part_that_is_load_bearing() {
        let p = super::proxy_exec_preamble("--github-login");
        for needle in [
            "export HOME=/root",
            "export XDG_RUNTIME_DIR=/run/user/0",
            "export TILLANDSIAS_VAULT_API_BASE_URL=https://vault:8200",
            "install -d -m 0700",
            "openssl req -x509",
            "podman rm tillandsias-proxy",
        ] {
            assert!(p.contains(needle), "preamble lost {needle:?}: {p}");
        }
        // ORDER 998-qrwu: the CA needle is INTERPOLATED, so it follows the
        // declaration when 975-rsgm moves the directory instead of pinning a
        // path the preamble no longer emits.
        {
            let ca_needle = format!(
                "chmod 600 {}/intermediate.key",
                tillandsias_core::ca_path::ca_dir_template()
            );
            assert!(p.contains(&ca_needle), "preamble lost {ca_needle:?}: {p}");
        }
    }

    /// THE HOST'S HOME MUST NEVER APPEAR IN A STRING THE GUEST EXECUTES.
    ///
    /// ORDER 1002-9xmb. `ca_dir()` expands `${HOME}` from the CALLING process,
    /// and this preamble is composed on the Mac but run in the Linux guest,
    /// which sets `HOME=/root` in its own first statement. Expanding on the
    /// host therefore emitted `/Users/<you>/.local/state/tillandsias/ca` for
    /// the guest to create.
    ///
    /// WHY THIS NEEDS A TEST AND NOT A COMMENT: measured in a live guest
    /// 2026-09-04, the wrong path SUCCEEDS — mkdir -p as root, openssl writes
    /// the key, perms 600, owner root, exit 0. There is no failure anywhere
    /// for a probe, a gate, or an operator to notice; the CA just lives at a
    /// per-developer path inside the guest. Only a test that reads the emitted
    /// string can catch it.
    #[test]
    fn the_preamble_never_bakes_in_the_hosts_home() {
        let p = super::proxy_exec_preamble("--github-login");
        assert!(
            p.contains("${HOME}/"),
            "the CA path must reach the guest as a TEMPLATE for the guest shell \
             to expand; an already-expanded path carries this Mac's HOME: {p}"
        );
        if let Ok(host_home) = std::env::var("HOME")
            && host_home.starts_with('/')
            && host_home != "/root"
        {
            assert!(
                !p.contains(&host_home),
                "the host HOME {host_home:?} leaked into a guest command: {p}"
            );
        }
        // The expander must be set up BEFORE the first use, or the guest shell
        // expands an empty HOME and the path becomes /.local/state/... at the
        // filesystem root — which, being root, would also succeed.
        let export_at = p.find("export HOME=/root").expect("HOME export");
        let first_use = p.find("${HOME}/").expect("templated CA path");
        assert!(
            export_at < first_use,
            "HOME must be exported before the CA path that expands it: {p}"
        );
    }

    use super::parse_aarch64_qcow2_sha;
    use super::translate_project_path_for_guest;
    use super::{METRICS_STATUS_NO_CAPABILITY, METRICS_STATUS_NO_HANDLE};

    /// `parse_aarch64_qcow2_sha` reads the actual manifest.toml format
    /// the Fedora pivot emits (`"aarch64.qcow2" = "<sha>"` inside
    /// `[output.expected_rootfs_sha]`). Asserts on a single 12-char
    /// prefix so the test isn't sensitive to the live SHA changing.
    #[test]
    fn parses_quoted_key_sha_form() {
        let manifest = r#"
[output.expected_rootfs_sha]
"aarch64.tar" = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
"aarch64.qcow2" = "55c60a3b80d3616a08705afd0459e75fe9f03c54aba7a46e4002a41a72fa0d5b"
"#;
        assert_eq!(
            parse_aarch64_qcow2_sha(manifest),
            Some("55c60a3b80d3".to_string())
        );
    }

    /// Tolerate the bare-key form too. TOML accepts both for keys
    /// that contain only `[A-Za-z0-9_-]` plus dots, so future
    /// manifest authors might drop the quotes.
    #[test]
    fn parses_bare_key_sha_form() {
        let manifest =
            "aarch64.qcow2 = \"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\"";
        assert_eq!(
            parse_aarch64_qcow2_sha(manifest),
            Some("abcdef012345".to_string())
        );
    }

    /// Placeholder SHA ("pending-ci") must NOT parse as a valid
    /// pin — `take_while(is_ascii_hexdigit)` produces "" since `p`
    /// is hex but the resulting prefix is too short. Return None so
    /// the diagnose report falls back to "(not found / parse
    /// skipped)" instead of printing garbage.
    #[test]
    fn refuses_placeholder_pending_ci() {
        let manifest = r#""aarch64.qcow2" = "pending-ci""#;
        assert_eq!(parse_aarch64_qcow2_sha(manifest), None);
    }

    fn source_window<'a>(source: &'a str, signature: &str) -> &'a str {
        let start = source
            .find(signature)
            .unwrap_or_else(|| panic!("missing signature: {signature}"));
        let tail = &source[start..];
        let end = tail.find("\n///").unwrap_or(tail.len());
        &tail[..end]
    }

    /// 663-69kp THIRD PATH. `prompt_line` is the only remaining stdin read on a
    /// one-shot path, and it had no `is_terminal()` guard and no timeout. It is
    /// reached from inside the `DynamicExpect` closures — after the VM is booted
    /// and the control wire is open — and per 689-y2my the guest's 30s PTY
    /// heartbeat keeps resetting the exec idle deadline, so nothing upstream
    /// bounds it either. An unattended `--github-login` therefore booted a VM and
    /// then blocked here forever on a stdin whose parent never closes.
    ///
    /// HONEST LIMIT OF THIS TEST: it is a SOURCE-SHAPE assertion, not a
    /// behavioural one. It cannot prove the timeout fires — only that the guard
    /// and the bound are present and that the interactive path stays unbounded.
    /// A behavioural test would have to boot a VM, which is far too heavy for a
    /// unit test and is why the property is pinned this way rather than not at
    /// all. Treat a green result here as "the shape is right", not as "measured".
    #[test]
    fn prompt_line_is_bounded_for_non_interactive_stdin() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let window = source_window(
            source,
            "fn prompt_line(label: &str, hidden: bool) -> String {",
        );

        assert!(
            window.contains("is_terminal()"),
            "prompt_line must distinguish an interactive stdin from a pipe — treating \
             'not a TTY' as 'a pipe that will EOF' is the 689-stig mistake: {window}"
        );
        assert!(
            window.contains("recv_timeout(PROMPT_LINE_PIPED_TIMEOUT)"),
            "the NON-INTERACTIVE read must be bounded, or an unattended --github-login \
             wedges forever holding a live VM (663-69kp): {window}"
        );
        // The interactive branch must stay UNBOUNDED. A human reading a prompt and
        // typing a token must never be timed out; a fix that bounded both paths
        // would satisfy the assertion above and break attended logins.
        let terminal_idx = window
            .find("if std::io::stdin().is_terminal() {")
            .expect("prompt_line must special-case an interactive stdin");
        let terminal_branch = &window[terminal_idx..];
        let terminal_end = terminal_branch
            .find("// Non-interactive")
            .expect("the interactive branch must precede the bounded one");
        assert!(
            !terminal_branch[..terminal_end].contains("recv_timeout"),
            "the INTERACTIVE branch must not be bounded — a human typing a token is not a \
             hang: {}",
            &terminal_branch[..terminal_end]
        );

        // Echo restoration must be reachable from the timeout path too: leaving a
        // terminal with echo off outlives the process.
        assert!(
            window.matches("restore_echo()").count() >= 3,
            "restore_echo must run on the interactive, piped-ok AND timeout exits — a \
             terminal left with echo disabled after a hang is a hostile end state: {window}"
        );

        // The refusal must not send the operator to a flag this binary rejects.
        assert!(
            !window.contains("--github-login --with-token"),
            "must NOT suggest --with-token: it is a tillandsias-headless GUEST flag with no \
             macOS host equivalent, and suggesting it repeats 663-acdw (two blind credential \
             runs). main.rs:262-271 is the authority: pipe to --github-login instead."
        );
    }

    #[test]
    fn github_login_host_prompts_after_control_wire_ready() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let window = source_window(source, "pub fn github_login_main() -> i32");
        let start_idx = window
            .find("vz.start().await")
            .expect("github login must start the VM");
        let wait_idx = window
            .find("wait_phase_ready(Duration::from_secs(300), |t| {")
            .expect("github login must wait for the VM phase Ready");
        let stream_idx = window
            .find("open_control_wire_stream(")
            .expect("github login must open the control-wire stream");
        let prompt_idx = window
            .find("prompt_line(\"Git author name\"")
            .expect("github login must prompt for git identity");
        let dynamic_idx = window
            .find("let result = exec_over_stream_expect_dynamic")
            .expect("github login must use lazy prompt responses");

        assert!(start_idx < wait_idx);
        assert!(wait_idx < stream_idx);
        assert!(
            stream_idx < prompt_idx,
            "host prompts must not be reachable before VM/control-wire readiness: {window}"
        );
        assert!(
            prompt_idx < dynamic_idx,
            "prompts should be supplied lazily through the dynamic expect path"
        );
    }

    /// Order 259 lock-namespace pin: the login exec preamble's
    /// XDG_RUNTIME_DIR export must stay /run/user/0 — the same value the
    /// guest headless unit pins (vm-layer vz.rs, its own matching test).
    /// The order-232 per-resource flocks live under
    /// $XDG_RUNTIME_DIR/tillandsias-locks; if the two processes resolve
    /// different dirs the vault check+act sections never serialize and the
    /// fresh-VM first-login name-in-use race (exit 125) returns.
    #[test]
    fn github_login_preamble_pins_the_shared_lock_namespace() {
        // 795-zshi slice 5 re-expressed this against the BUILT value. It used to
        // grep the source window of `github_login_main` for the literal, which
        // broke the moment the preamble moved into `proxy_exec_preamble` — a
        // correct refactor reading as a regression, the same literal-pin failure
        // 701-iu9b hit one cycle earlier in vz.rs. Asserting the built string is
        // also STRICTLY STRONGER: a source-window grep passes on a literal that
        // is present but unused, whereas this proves the export actually reaches
        // the guest.
        assert!(
            super::proxy_exec_preamble("--github-login")
                .contains("export XDG_RUNTIME_DIR=/run/user/0;"),
            "login preamble must export the lock namespace the headless unit pins (order 259)"
        );
    }

    /// litmus:secure-wait-phase-ready — `wait_phase_ready`'s probe callback
    /// must route through the same secure-or-plain opener as user actions
    /// (`open_control_wire_stream`), not a bare `open_vsock_stream*` connect.
    /// Otherwise a flag-ON guest's readiness probe would run in plaintext
    /// even though the guest only speaks Noise, and could hang/fail even
    /// though the real user-facing traffic is correctly secured.
    /// @trace plan/issues/secure-channel-release-and-probe-hardening-2026-07-05.md
    #[test]
    fn probe_phase_secure_or_plain_uses_the_secure_or_plain_opener() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let start = source
            .find("async fn probe_phase_secure_or_plain(")
            .expect("probe_phase_secure_or_plain must exist");
        let tail = &source[start..];
        // Function bodies here are flat (no nested `}\n}`), so the first
        // `\n}\n` after `start` is this function's own closing brace.
        let end = tail.find("\n}\n").map(|i| i + 2).unwrap_or(tail.len());
        let window = &tail[..end];

        assert!(
            window.contains("open_control_wire_stream("),
            "wait_phase_ready's probe callback must open its connection via \
             open_control_wire_stream (the secure-or-plain opener), not a raw \
             vsock connect: {window}"
        );
        assert!(
            !window.contains("open_vsock_stream"),
            "wait_phase_ready's probe callback must not bypass \
             open_control_wire_stream with a direct vsock connect: {window}"
        );
    }

    /// `--diagnose` and its sibling CLI actions must construct a normalized
    /// macOS guest endpoint and delegate current-thread VZ connection details
    /// to vm-layer, rather than naming `VsockStream` directly.
    ///
    /// @trace spec:host-guest-transport
    #[test]
    fn diagnose_control_wire_opener_uses_guest_transport_endpoint() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        let start = source
            .find("async fn open_control_wire_stream(")
            .expect("open_control_wire_stream must exist");
        let tail = &source[start..];
        let end = tail.find("\n///").unwrap_or(tail.len());
        let window = &tail[..end];

        assert!(
            window.contains("GuestEndpoint::MacVz"),
            "diagnose opener must construct the normalized MacVz endpoint: {window}"
        );
        assert!(
            window.contains("open_guest_transport_stream_current_thread(&endpoint, timeout)"),
            "diagnose opener must delegate current-thread VZ details to vm-layer: {window}"
        );
        assert!(
            !window.contains("open_vsock_stream_current_thread"),
            "diagnose opener must not call the raw VZ connector directly: {window}"
        );
        let raw_stream_type = concat!("transport_macos::", "VsockStream");
        assert!(
            !source.contains(raw_stream_type),
            "diagnose.rs must not name the raw macOS stream type directly"
        );
    }

    /// 778-n9z2 criterion 2 — the NO-FABRICATION contract must survive the
    /// tray hop. A sample that failed to collect carries `error` and absent
    /// counters; it must serialise as JSON `null`s, never as healthy zeros
    /// and never by vanishing from the document (spec:observability-metrics).
    ///
    /// This is the assertion that would catch the two tempting "cleanups" —
    /// a `.unwrap_or(0)` on the counters, or a
    /// `skip_serializing_if = "Option::is_none"` on the wire structs — either
    /// of which silently converts "could not measure" into "measured zero".
    #[test]
    fn metrics_error_sample_renders_null_counters_never_zero() {
        use tillandsias_control_wire::{
            ContainerMetricWire, MetricsSnapshotWire, MountIoMetricWire,
        };

        let mut report = baseline_diagnose_report();
        report.metrics = Some(MetricsSnapshotWire {
            sampled_at_unix: 1_786_900_000,
            containers: vec![ContainerMetricWire {
                name: "tillandsias-proxy".to_string(),
                cpu_usec: None,
                memory_current_bytes: None,
                blkio_read_bytes: None,
                blkio_write_bytes: None,
                blkio_read_ops: None,
                blkio_write_ops: None,
                error: Some("cgroup read failed: ENOENT".to_string()),
            }],
            mounts: vec![MountIoMetricWire {
                path: "/home/forge/src".to_string(),
                device: None,
                read_bytes: None,
                write_bytes: None,
                read_ops: None,
                write_ops: None,
                error: Some("unavailable: virtiofs".to_string()),
            }],
        });
        report.metrics_status = "ok".to_string();

        let json = serde_json::to_value(&report).expect("report must serialise");
        let container = &json["metrics"]["containers"][0];
        assert!(
            container["cpu_usec"].is_null(),
            "an uncollected counter must be null, not a fabricated zero: {container}"
        );
        assert!(
            container["memory_current_bytes"].is_null(),
            "an uncollected counter must be null: {container}"
        );
        assert_eq!(
            container["error"], "cgroup read failed: ENOENT",
            "the sample's error must survive the tray hop"
        );
        let mount = &json["metrics"]["mounts"][0];
        assert!(
            mount["read_bytes"].is_null() && mount["device"].is_null(),
            "an unavailable mount reports nulls, not zeros: {mount}"
        );
        assert_eq!(mount["error"], "unavailable: virtiofs");
        // Absent-vs-null matters: a consumer must be able to tell "no such
        // key" (schema drift) from "known key, unmeasured".
        assert!(
            container.get("cpu_usec").is_some() && mount.get("read_bytes").is_some(),
            "counters must be PRESENT-and-null, never omitted"
        );
    }

    /// 778-n9z2 criterion 1 — the report always says WHY metrics are absent,
    /// and the default standalone path never claims a wire it does not hold.
    #[test]
    fn metrics_status_states_why_metrics_are_absent() {
        let report = baseline_diagnose_report();
        assert_eq!(report.metrics_status, METRICS_STATUS_NO_HANDLE);
        assert!(report.metrics.is_none());

        let json = serde_json::to_value(&report).expect("report must serialise");
        assert!(
            json["metrics"].is_null(),
            "no snapshot must serialise as null, not as an empty object that reads like 'no containers'"
        );
        assert_eq!(json["metrics_status"], METRICS_STATUS_NO_HANDLE);

        for status in [
            "ok",
            METRICS_STATUS_NO_HANDLE,
            METRICS_STATUS_NO_CAPABILITY,
            "error:wire-read",
        ] {
            assert!(
                status == "ok"
                    || status.starts_with("unsupported:")
                    || status.starts_with("error:"),
                "metrics_status grammar is ok|unsupported:<why>|error:<slug>, got {status}"
            );
        }
        // Feature detection is by capability, never by wire version — the
        // constant that carries that decision must name the capability.
        assert_eq!(
            tillandsias_vm_layer::vsock_exec::CAP_METRICS_SNAPSHOT,
            "MetricsSnapshotRequest"
        );
    }

    /// 772-shi9: neither guest exec preamble may widen the CA PRIVATE key.
    ///
    /// Both preambles once ran `chmod 644` on it, justified by "so Squid
    /// (uid 1000) can read it" — false since 755-qcxh made the key travel as a
    /// 0400 podman secret. The widened mode also persisted, because a
    /// preamble that finds the key present skips the openssl block and
    /// `ensure_proxy_running` early-returns before the heal.
    ///
    /// Two mechanics are load-bearing. The key path is assembled with
    /// `concat!` so this test's own literals are not present verbatim in the
    /// scanned source (the same dodge as the raw-stream-type pin above);
    /// without it the negative assertions match themselves. And every
    /// negative is anchored to the KEY path — `intermediate.crt` is
    /// deliberately world-readable, so a bare `chmod 644` scan would forbid
    /// the correct thing.
    #[test]
    fn guest_ca_preflight_never_widens_the_private_key() {
        let source = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/diagnose.rs"));
        // ORDER 998-qrwu: built from the ONE declaration, not a split literal.
        // The `concat!` form here was invisible to a grep by construction — which
        // is exactly how it survived a literal audit — and it would have kept
        // matching the OLD path after 975-rsgm moves the directory, so this test
        // would have gone quietly vacuous rather than failing.
        let key = format!(
            "{}/intermediate.key",
            tillandsias_core::ca_path::ca_dir_template()
        );

        // 795-zshi slice 5 moved these assertions from the two call sites'
        // SOURCE WINDOWS onto the BUILT preamble. The windows stopped containing
        // the literal when the duplicated preamble became one builder, so a
        // correct refactor read as a regression — the same literal-pin failure
        // 701-iu9b hit in vz.rs one cycle earlier, and the second instance in
        // this session. Asserting the built value is strictly stronger: a
        // source-window grep passes on a literal that is present but never
        // reaches the guest.
        for arg in ["--github-login", "--list-cloud-projects"] {
            let preamble = super::proxy_exec_preamble(arg);
            assert!(
                preamble.contains(&format!("chmod 600 {key}")),
                "{arg}: preflight must clamp the CA private key to 0600"
            );
            // The heal must sit OUTSIDE the `test -s` guard: an existing 0644
            // key never reaches the openssl block.
            let guarded = preamble
                .split("fi; ")
                .next()
                .expect("preamble must contain the test -s guard block");
            let after_guard = &preamble[guarded.len()..];
            assert!(
                after_guard.contains(&format!("chmod 600 {key}")),
                "{arg}: the heal-down must run unconditionally, after the guard"
            );
        }

        for wide in ["644", "640", "664", "666", "755", "777"] {
            assert!(
                !source.contains(&format!("chmod {wide} {key}")),
                "no code path may chmod the CA private key to {wide} (755-qcxh / 772-shi9)"
            );
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  JSON schema-pin tests (mirrors windows-tray e96d1fc8)
    //
    //  The --diagnose --json schema is a public surface that
    //  scripts/tray-diagnose.sh (and any future support tooling
    //  uploading the JSON) parse field-by-field. Renames or removes
    //  here must break the build, not silently break the consumer.
    // ────────────────────────────────────────────────────────────────

    use super::{DIAGNOSE_EXIT_CONVERGING, DiagnoseReport, exit_code_from};

    fn baseline_diagnose_report() -> DiagnoseReport {
        DiagnoseReport {
            version: env!("WORKSPACE_VERSION"),
            guest_version: None,
            in_app: true,
            exe_path: Some(
                "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray".to_string(),
            ),
            image_root: "/Users/test/Library/Application Support/tillandsias".to_string(),
            rootfs_present: true,
            rootfs_bytes: Some(8_589_934_592),
            kernel_present: false,
            kernel_bytes: None,
            initrd_present: false,
            initrd_bytes: None,
            release_tag: "fedora-44",
            manifest_pin_aarch64_qcow2: Some("55c60a3b80d3".to_string()),
            provisioned: true,
            // 701-kgvk: the healthy shape — bundle and staged agree.
            guest_binary_bundle_sha256: Some("26f120b6b1ef".to_string()),
            guest_binary_staged_sha256: Some("26f120b6b1ef".to_string()),
            guest_binary_staged_matches_bundle: Some(true),
            // A provisioned host at rest: nothing is mid-materialization.
            tray_process_running: false,
            metrics: None,
            metrics_status: METRICS_STATUS_NO_HANDLE.to_string(),
        }
    }

    /// Top-level JSON keys are the support-tooling contract.
    /// `tray-diagnose.sh` reads `.version`, `.in_app`, `.release_tag`,
    /// `.manifest_pin_aarch64_qcow2`, `.provisioned`, and the per-
    /// artifact `_present` flags by name. A silent rename of any of
    /// these would degrade the consumer to "FAIL : null".
    #[test]
    fn diagnose_report_json_keys_locked() {
        let report = baseline_diagnose_report();
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        let obj = value
            .as_object()
            .expect("DiagnoseReport must serialise as a JSON object");
        for required_key in [
            "version",
            "in_app",
            "exe_path",
            "image_root",
            "rootfs_present",
            "rootfs_bytes",
            "kernel_present",
            "kernel_bytes",
            "initrd_present",
            "initrd_bytes",
            "release_tag",
            "manifest_pin_aarch64_qcow2",
            "provisioned",
        ] {
            assert!(
                obj.contains_key(required_key),
                "DiagnoseReport JSON missing required key {required_key:?}; check serde rename"
            );
        }
    }

    /// `manifest_pin_aarch64_qcow2: None` must serialise as JSON null,
    /// not the literal string "null" or the absent key. Consumer
    /// path: `tray-diagnose.sh` reads `.manifest_pin_aarch64_qcow2 //
    /// "(none)"` — `//` only triggers on null/missing, so a string
    /// "null" would silently render as PASS with bogus pin.
    #[test]
    fn diagnose_report_none_pin_serialises_as_null() {
        let mut report = baseline_diagnose_report();
        report.manifest_pin_aarch64_qcow2 = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["manifest_pin_aarch64_qcow2"], serde_json::Value::Null);
    }

    /// `bytes` fields are `Option<u64>`; missing artifacts MUST
    /// serialise as JSON null. `tray-diagnose.sh` doesn't currently
    /// read the bytes, but a future dashboard expects null for
    /// "absent" so it can render "—" instead of "0".
    #[test]
    fn diagnose_report_none_bytes_serialise_as_null() {
        let mut report = baseline_diagnose_report();
        report.kernel_present = false;
        report.kernel_bytes = None;
        report.initrd_present = false;
        report.initrd_bytes = None;
        let value: serde_json::Value = serde_json::to_value(&report).unwrap();
        assert_eq!(value["kernel_bytes"], serde_json::Value::Null);
        assert_eq!(value["initrd_bytes"], serde_json::Value::Null);
    }

    /// `exit_code_from` is the public contract `tray-diagnose.sh` (and
    /// `--diagnose --json`'s own `main`) rely on. Pin the mapping so accidental
    /// flips break the build.
    ///
    /// Order 735-2g5i renamed this from `exit_code_provisioned_zero_degraded_two`
    /// to match windows-tray's `exit_code_separates_healthy_converging_and_degraded`,
    /// because the two-state name had become a lie: converging is now its own
    /// verdict. `litmus:exit-code-provisioned-zero-degraded-two-symmetric`
    /// accepts either name on either side precisely so this rename is legal.
    #[test]
    fn exit_code_separates_healthy_converging_and_degraded() {
        let mut report = baseline_diagnose_report();
        assert_eq!(exit_code_from(&report), 0, "provisioned is healthy");

        // NOT provisioned with a live tray owning the VM: converging, not
        // broken. This is the case that used to collapse into 2 and made a
        // scripted post-install check call a still-materializing host broken.
        report.provisioned = false;
        report.tray_process_running = true;
        assert_eq!(
            exit_code_from(&report),
            DIAGNOSE_EXIT_CONVERGING,
            "a live tray owning an unmaterialized VM is converging, not broken"
        );

        // NEGATIVE CONTROL, load-bearing: with no live owner the same missing
        // artifacts stay exit 2. Without this, "always report converging when
        // unprovisioned" would satisfy the assertion above — and that is the
        // worse failure, because it tells automation to keep waiting on a host
        // where nothing is running.
        report.tray_process_running = false;
        assert_eq!(
            exit_code_from(&report),
            2,
            "unprovisioned with no live owner is indistinguishable from broken"
        );

        // And converging must never mask a healthy host: provisioned wins
        // regardless of who holds the VM (the steady state — the tray is
        // normally running).
        report.provisioned = true;
        report.tray_process_running = true;
        assert_eq!(
            exit_code_from(&report),
            0,
            "provisioned is healthy even while the tray owns the VM"
        );
    }

    /// Order 331 pin: the pure host→guest project-path translation.
    #[test]
    fn project_path_translation_rules() {
        let t = |p: &str| translate_project_path_for_guest(p, "/Users/op");
        // host ~/src/<name> → guest path (the 2026-07-13 live repro shape)
        assert_eq!(
            t("/Users/op/src/tillandsias").unwrap(),
            "/home/forge/src/tillandsias"
        );
        // nested subpath translates too
        assert_eq!(
            t("/Users/op/src/tillandsias/crates").unwrap(),
            "/home/forge/src/tillandsias/crates"
        );
        // guest-absolute passes through verbatim
        assert_eq!(
            t("/home/forge/src/tillandsias").unwrap(),
            "/home/forge/src/tillandsias"
        );
        // the src root itself is not a project
        assert!(t("/Users/op/src").unwrap_err().contains("INSIDE"));
        // outside ~/src fails fast with both accepted forms named
        let err = t("/tmp/elsewhere").unwrap_err();
        assert!(
            err.contains("/Users/op/src") && err.contains("/home/forge/src"),
            "{err}"
        );
    }

    // ────────────────────────────────────────────────────────────────
    //  Guest crash-loop DETECTION — the macOS `--diagnose` read path.
    //  (macOS-only tests; the cross-platform detector behavior itself is
    //  pinned in tillandsias-control-wire::crashloop on the Linux dev box.)
    //  @trace plan/issues/guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md
    // ────────────────────────────────────────────────────────────────

    /// The `--diagnose` guest-health line always renders a verdict in the
    /// pinned grammar, even with no state file present (fresh install →
    /// `starting`), and never panics.
    #[test]
    fn guest_health_verdict_matches_pinned_grammar() {
        let v = super::guest_health_verdict();
        assert!(
            tillandsias_control_wire::crashloop::verdict_matches_grammar(&v),
            "guest-health verdict {v:?} must match ^(healthy|starting|crash-loop:[a-z0-9-]+)$"
        );
    }

    /// `format_utc` against fixed points chosen where a naive implementation
    /// breaks, not where it is easy.
    ///
    /// 2000-02-29 is the case the `year % 4 == 0 && year % 100 != 0` rule gets
    /// WRONG on its own: 2000 is divisible by 100 and IS a leap year because it
    /// 1055-e8ie CRITERION 2: a partially-provisioned guest is distinguishable
    /// from a completed one.
    ///
    /// ALL THREE STATES, because two would not settle it. The defect this
    /// closes is that the previous marker recorded a start and a failure and NO
    /// completion, so "ran to completion", "died without the ERR trap firing"
    /// and "died before the write landed" collapsed into one artefact — a start
    /// line and nothing else. A fixture that only proved failure-is-detected
    /// would pass on that broken marker, because the broken marker detects
    /// failure too. What it could not do is tell success from silence.
    #[test]
    fn provision_record_distinguishes_complete_aborted_and_failed() {
        let complete = "tillandsias-provision-state v1\nwritten_at 1800000000\nphase complete\n";
        assert_eq!(
            super::provision_record_from(complete),
            super::ProvisionRecord::Complete {
                written_at: Some(1_800_000_000),
                guest_binary_sha256: None,
            }
        );

        // The case the old marker could not express: started, never finished.
        // This must NOT read as success and must NOT read as "no information".
        let aborted = "tillandsias-provision-state v1\nwritten_at 1800000000\nphase start\n";
        assert_eq!(
            super::provision_record_from(aborted),
            super::ProvisionRecord::StartedNeverFinished {
                written_at: Some(1_800_000_000)
            },
            "a start with no completion is a POSITIVE abort signal, not an absence"
        );

        let failed = "tillandsias-provision-state v1\nwritten_at 1800000000\nphase failed\n\
                      line 373\nrc 1\ncmd systemctl start tillandsias-headless.service\n";
        assert_eq!(
            super::provision_record_from(failed),
            super::ProvisionRecord::Failed {
                written_at: Some(1_800_000_000),
                line: Some("373".into()),
                rc: Some("1".into()),
                cmd: Some("systemctl start tillandsias-headless.service".into()),
            },
            "the failing line must survive into the verdict; a bare FAILED is what \
             sent an investigation to the raw disk image"
        );

        // NEGATIVE CONTROL, load-bearing: absence must not be any of the three.
        // Without this, a reader that returned Complete for everything would
        // satisfy the first assertion.
        assert_eq!(
            super::provision_record_from(""),
            super::ProvisionRecord::Absent
        );
        assert_eq!(
            super::provision_record_from("garbage\nphase wat\n"),
            super::ProvisionRecord::Absent
        );
    }

    /// 1055-e8ie. The record must be read from INSIDE the file, never mtime.
    /// A copy, a restore or a `touch` forges an mtime; mtime is a property of
    /// the filesystem and not of the event (980-ja2m).
    #[test]
    fn provision_record_takes_its_timestamp_from_the_content() {
        let no_ts = "tillandsias-provision-state v1\nphase complete\n";
        assert_eq!(
            super::provision_record_from(no_ts),
            super::ProvisionRecord::Complete {
                written_at: None,
                guest_binary_sha256: None
            },
            "a record without a content timestamp reports None rather than \
             borrowing the filesystem's"
        );
    }

    /// 1084-x8ya. The guest's own hash of its binary must survive into the
    /// record, and the comparison against the staged artefact must name SKEW
    /// rather than swallow it.
    ///
    /// This is the measurement the packet turns on, and it exists only because
    /// no host-side path to the guest survives the failure it diagnoses: order
    /// 272 masks every sshd surface, exec-guest rides the dead wire, macOS
    /// cannot mount ext4, and a raw-image string scan cannot date the binary
    /// because 79e3ca876 flipped a default without adding a shipped literal.
    #[test]
    fn a_completed_provision_carries_the_guests_own_binary_hash() {
        let with_hash = "tillandsias-provision-state v1\nwritten_at 1800000000\n\
                         phase complete\nguest_binary_sha256 d677e5f5843d\n";
        assert_eq!(
            super::provision_record_from(with_hash),
            super::ProvisionRecord::Complete {
                written_at: Some(1_800_000_000),
                guest_binary_sha256: Some("d677e5f5843d".into()),
            },
            "the guest's hash must reach the host; it is the only way to ask what \
             the guest is running"
        );

        // ABSENT is an ANSWER, not a missing field. A provision that completed
        // and left no binary is the whole finding, and an omitted value would
        // read as "not measured".
        let absent = "tillandsias-provision-state v1\nphase complete\n\
                      guest_binary_sha256 absent\n";
        match super::provision_record_from(absent) {
            super::ProvisionRecord::Complete {
                guest_binary_sha256,
                ..
            } => assert_eq!(guest_binary_sha256.as_deref(), Some("absent")),
            other => panic!("expected Complete, got {other:?}"),
        }
    }

    /// 1084-x8ya. The skew verdict must distinguish FOUR cases and must never
    /// collapse an unknown into a match.
    #[test]
    fn the_skew_line_names_skew_and_never_calls_unknown_a_match() {
        // No hash recorded: a guest provisioned before the field existed.
        let none = super::guest_binary_skew_line(None);
        assert!(none.contains("NOT RECORDED"), "got: {none}");
        assert!(
            !none.contains("MATCHES"),
            "an unrecorded hash must never read as a match: {none}"
        );

        let absent = super::guest_binary_skew_line(Some("absent"));
        assert!(absent.contains("ABSENT"), "got: {absent}");

        let unreadable = super::guest_binary_skew_line(Some("unreadable"));
        assert!(unreadable.contains("UNREADABLE"), "got: {unreadable}");
    }

    /// 1055-e8ie. The reader must exist and be WIRED IN. The previous marker's
    /// defect was not that it was written badly — it was that nothing read it:
    /// `grep -rn provision-marker` found no consumer anywhere in the tree, so a
    /// record was produced for a reader that had never been written.
    #[test]
    fn the_provisioning_line_is_actually_printed_by_the_report() {
        let source = include_str!("diagnose.rs");
        assert!(
            source.contains("println!(\"{}\", provision_report_line());"),
            "the provisioning record must be PRINTED; a reader nothing calls is \
             the same defect as a record nothing reads (1055-e8ie)"
        );
    }

    /// 980-ja2m slice (b). BOTH DIRECTIONS, round-tripped through the real
    /// parser. A bound proved only on the stale side is satisfied by a reader
    /// that says UNKNOWN always — and that reader is the original defect
    /// wearing the fix's clothes, because it reports UNKNOWN precisely when
    /// the system works.
    #[test]
    fn heartbeat_bound_reports_a_phase_when_fresh_and_unknown_when_stale() {
        let now = 1_800_000_000u64;

        // FRESH: 10 s old, inside the 90 s bound. The phase IS reported, and
        // it is the tray's own chip text, emoji and all.
        let fresh = super::heartbeat_state_string("\u{1F535} Booting\u{2026}", now - 10);
        match super::heartbeat_verdict_from(&fresh, None, now) {
            super::HeartbeatVerdict::Fresh { phase, age_secs } => {
                assert_eq!(
                    phase, "\u{1F535} Booting\u{2026}",
                    "chip text is recorded verbatim"
                );
                assert_eq!(age_secs, 10);
            }
            other => panic!("a 10 s old heartbeat must report a phase, got {other:?}"),
        }

        // STALE: 120 s old, past the bound. The phase must NOT survive into
        // the verdict — reporting a two-minute-old phase as current is the
        // lie, not the age.
        let stale = super::heartbeat_state_string("\u{1F7E2} Ready", now - 120);
        match super::heartbeat_verdict_from(&stale, None, now) {
            super::HeartbeatVerdict::Stale { age_secs } => assert_eq!(age_secs, 120),
            other => panic!("a 120 s old heartbeat must read UNKNOWN, got {other:?}"),
        }

        // ABSENT beats a guess: no timestamp anywhere is not "just now".
        assert_eq!(
            super::heartbeat_verdict_from("garbage", None, now),
            super::HeartbeatVerdict::Absent
        );
    }

    /// 980-ja2m. mtime is the fallback ONLY for a record predating
    /// `written_at`, and using it must change what the reader is told.
    #[test]
    fn heartbeat_falls_back_to_mtime_only_when_the_record_has_no_timestamp() {
        let now = 1_800_000_000u64;
        let no_ts = "tillandsias-heartbeat-state v1\nstatus Ready\n";
        match super::heartbeat_verdict_from(no_ts, Some(now - 5), now) {
            super::HeartbeatVerdict::Fresh { age_secs, .. } => assert_eq!(age_secs, 5),
            other => panic!("mtime must be used when the record carries none, got {other:?}"),
        }
        // With a content timestamp present, a LYING mtime must not win: a
        // `touch` on a stale file cannot manufacture freshness.
        let with_ts = super::heartbeat_state_string("Ready", now - 600);
        assert_eq!(
            super::heartbeat_verdict_from(&with_ts, Some(now), now),
            super::HeartbeatVerdict::Stale { age_secs: 600 },
            "a fresh mtime must not override a stale content timestamp"
        );
    }

    /// 980-ja2m slice (b). The bound must be a MULTIPLE of the period, not an
    /// independent number: one missed write under load must not flip a healthy
    /// host to UNKNOWN, and the relationship is what makes that true.
    #[test]
    fn heartbeat_bound_is_three_periods() {
        assert_eq!(super::HEARTBEAT_PERIOD_SECS, 30);
        assert_eq!(super::HEARTBEAT_STALE_AFTER_SECS, 90);
        assert_eq!(
            super::HEARTBEAT_STALE_AFTER_SECS,
            3 * super::HEARTBEAT_PERIOD_SECS,
            "the bound is three periods so a single missed write is tolerated"
        );
    }

    /// 980-ja2m slice (b). THE ARM A PUSH-DRIVEN DESIGN FAILS, exercised
    /// against the real verdict rather than by comparing two constants.
    ///
    /// Measured on macneo 2026-09-05: one `vm-status` line in 25 m 34 s on a
    /// healthy, Ready, podman-ready guest, so a record written only when a
    /// push arrives is 1525 s old on a system with nothing wrong. Fed to the
    /// bound it reads UNKNOWN — which is the false alarm this design exists to
    /// avoid — while the heartbeat's own worst case, one period, reads as a
    /// phase. Both halves are asserted here; the first alone would be
    /// satisfied by a reader that always says UNKNOWN.
    #[test]
    fn a_push_driven_timestamp_would_fail_the_bound_a_heartbeat_passes() {
        const MEASURED_SILENT_SPAN_SECS: u64 = 1525;
        let now = 1_800_000_000u64;

        let push_driven = super::heartbeat_state_string("Ready", now - MEASURED_SILENT_SPAN_SECS);
        assert_eq!(
            super::heartbeat_verdict_from(&push_driven, None, now),
            super::HeartbeatVerdict::Stale {
                age_secs: MEASURED_SILENT_SPAN_SECS
            },
            "a push-driven record on a HEALTHY guest reads UNKNOWN — the false \
             alarm that rules the push stream out as a liveness source"
        );

        let heartbeat_worst_case =
            super::heartbeat_state_string("Ready", now - super::HEARTBEAT_PERIOD_SECS);
        match super::heartbeat_verdict_from(&heartbeat_worst_case, None, now) {
            super::HeartbeatVerdict::Fresh { age_secs, .. } => {
                assert_eq!(age_secs, super::HEARTBEAT_PERIOD_SECS)
            }
            other => panic!("one period old must still report a phase, got {other:?}"),
        }
    }

    /// 980-ja2m. mtime must never silently stand in for a content timestamp: a
    /// copy or a `touch` forges it. When the fallback IS used the printed line
    /// has to say so, and this pins the disclosure.
    #[test]
    fn an_mtime_fallback_is_disclosed_and_a_content_timestamp_is_not() {
        assert_eq!(super::TimestampSource::Content(1).disclosure(), "");
        assert!(
            super::TimestampSource::Mtime(1)
                .disclosure()
                .contains("mtime"),
            "a forgeable timestamp must name itself in the output"
        );
        assert_eq!(super::TimestampSource::Content(42).unix(), 42);
        assert_eq!(super::TimestampSource::Mtime(42).unix(), 42);
    }

    /// is divisible by 400. 2100-03-01 is the converse — divisible by 100, not
    /// by 400, NOT a leap year — and the day after the February that a wrong
    /// implementation gives 29 days. An implementation that handles only the
    /// /4 rule passes 1970 and 2001 and fails both of these.
    ///
    /// @trace order:980-ja2m
    #[test]
    fn format_utc_fixed_points() {
        assert_eq!(super::format_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(super::format_utc(1_000_000_000), "2001-09-09T01:46:40Z");
        assert_eq!(super::format_utc(951_825_600), "2000-02-29T12:00:00Z");
        assert_eq!(super::format_utc(4_107_542_400), "2100-03-01T00:00:00Z");
    }

    /// @trace order:980-ja2m
    #[test]
    fn humanize_age_pins() {
        assert_eq!(super::humanize_age(0), "0s");
        assert_eq!(super::humanize_age(47), "47s");
        assert_eq!(super::humanize_age(60), "1m");
        assert_eq!(super::humanize_age(11_520), "3h 12m");
        assert_eq!(super::humanize_age(436_800), "5d 1h");
    }

    /// THE GUARD WITH TEETH for 980-ja2m: the `Guest health:` line may not
    /// print the bare verdict, and must name both its SOURCE and its AGE.
    ///
    /// The pre-fix line was exactly `Guest health: healthy` for a state file
    /// five days old with no VM running. This asserts the shape that makes
    /// that unreadable as a live observation — if someone reverts to printing
    /// `guest_health_verdict()` directly, every arm here fails.
    ///
    /// @trace order:980-ja2m
    #[test]
    fn guest_health_line_names_source_and_age_and_is_never_the_bare_verdict() {
        let line = super::guest_health_report_line();

        // The bare-verdict shape is what the defect was. Reject it whatever
        // the verdict word happens to be on this host.
        for bare in ["healthy", "starting"] {
            assert_ne!(
                line,
                format!("Guest health: {bare}"),
                "the Guest health line is the bare verdict again — a RECORDED \
                 disk read reading as a live observation (980-ja2m)"
            );
        }

        assert!(
            line.starts_with("Guest health:"),
            "the label is pinned by two parity tests (macos main.rs:722, \
             windows main.rs:402); got {line}"
        );
        assert!(
            line.contains("RECORDED, not observed"),
            "missing the framing that separates a record from an observation: {line}"
        );
        assert!(
            line.contains("crashloop.state"),
            "the line must name its SOURCE: {line}"
        );
        // Age is present either as a rendered timestamp or as an explicit
        // UNKNOWN. An omitted age reads as "just now", which is the failure.
        assert!(
            line.contains(" ago)") || line.contains("age UNKNOWN"),
            "the line must name its AGE, or say the age is unknown — an \
             omitted age reads as fresh: {line}"
        );
    }

    /// The crash-loop state file lives under the same `image_root` the live
    /// tray reads/writes, so the writer and this static reader agree.
    #[test]
    fn crashloop_state_path_under_image_root() {
        let p = super::crashloop_state_path();
        assert!(
            p.ends_with("Library/Application Support/tillandsias/crashloop.state"),
            "{}",
            p.display()
        );
    }

    /// A tripped state written to a temp file reads back as
    /// `crash-loop:<subsystem>` — the exact load path `--diagnose` uses.
    #[test]
    fn tripped_state_reads_back_as_crash_loop() {
        use tillandsias_control_wire::crashloop::{
            CrashLoopDetector, CrashLoopSubsystem, GuestHealth,
        };
        let dir = std::env::temp_dir().join(format!("tillandsias-diag-{}", std::process::id()));
        let path = dir.join("crashloop.state");
        let mut det = CrashLoopDetector::new(120, 3);
        det.record_failure(CrashLoopSubsystem::Guest, 10);
        det.record_failure(CrashLoopSubsystem::Guest, 11);
        det.record_failure(CrashLoopSubsystem::Guest, 12);
        det.save(&path).unwrap();
        let mut loaded = CrashLoopDetector::load(&path);
        assert_eq!(
            loaded.verdict(12),
            GuestHealth::CrashLoop(CrashLoopSubsystem::Guest)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
