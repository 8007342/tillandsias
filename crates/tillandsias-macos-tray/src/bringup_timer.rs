//! ORDER 1915-vzbt — the tray's bring-up step timer, for the VZ VM boot.
//!
//! The same line and row as tillandsias-headless's bringup_timer and the
//! Windows tray's wsl-boot step: `bringup: step=vz-boot ms=<n>` on stderr and
//! in the tray log, and one timing-ledger row only where
//! `TILLANDSIAS_TIMING_LOG` already switches the ledger on. The row carries
//! the step name, the duration and the exit, never a path, a project name or
//! a user name.
//!
//! The span runs from the VZ start call to the first Ready-with-podman status
//! the tray applies. Both ends are timestamps the tray already passes; no new
//! poll.

use std::sync::Mutex;
use std::time::Instant;

static VZ_BOOT_STARTED: Mutex<Option<Instant>> = Mutex::new(None);

pub(crate) fn line(step: &str, ms: u128) -> String {
    format!("bringup: step={step} ms={ms}")
}

/// Stamp the start of the VZ boot call.
pub(crate) fn vz_boot_started() {
    if let Ok(mut s) = VZ_BOOT_STARTED.lock() {
        *s = Some(Instant::now());
    }
}

/// End the vz-boot span, once: the first call after [`vz_boot_started`]
/// reports, every later one is a no-op until the next boot.
pub(crate) fn vz_boot_finished(exit: i32) {
    let started = VZ_BOOT_STARTED.lock().ok().and_then(|mut s| s.take());
    if let Some(t0) = started {
        report("vz-boot", t0.elapsed().as_millis(), exit);
    }
}

pub(crate) fn report(step: &'static str, ms: u128, exit: i32) {
    let l = line(step, ms);
    eprintln!("{l}");
    tracing::info!("{l}");
    if let Some(path) = std::env::var_os("TILLANDSIAS_TIMING_LOG") {
        append_row(std::path::Path::new(&path), step, ms, exit);
    }
}

fn host() -> String {
    std::env::var("TILLANDSIAS_HOST_ID")
        .ok()
        .map(|h| h.trim().to_lowercase())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

fn append_row(path: &std::path::Path, step: &str, ms: u128, exit: i32) {
    let row = serde_json::json!({
        "ts": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "host": host(),
        "step": step,
        "phase": "bringup",
        "duration_ms": ms as u64,
        "exit": exit,
    });
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{row}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vz_boot_line_and_row_shape() {
        assert_eq!(line("vz-boot", 1234), "bringup: step=vz-boot ms=1234");
        let dir = std::env::temp_dir().join(format!("mac-tray-bringup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.jsonl");
        append_row(&p, "vz-boot", 9, 0);
        let row: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&p).unwrap().trim()).unwrap();
        let mut keys: Vec<&str> = row
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, ["duration_ms", "exit", "host", "phase", "step", "ts"]);
        assert_eq!(row["step"], "vz-boot");
        assert_eq!(row["phase"], "bringup");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One span, one report: a second finish without a new start is a no-op.
    #[test]
    fn vz_boot_reports_once_per_start() {
        vz_boot_started();
        assert!(VZ_BOOT_STARTED.lock().unwrap().is_some());
        vz_boot_finished(0);
        assert!(VZ_BOOT_STARTED.lock().unwrap().is_none());
        vz_boot_finished(0);
        assert!(VZ_BOOT_STARTED.lock().unwrap().is_none());
    }

    /// The boot path stamps the start before the VZ start call, ends the
    /// span on a start failure, and the status path ends it at Ready.
    #[test]
    fn tray_wires_vz_boot_at_both_ends() {
        let src: String = include_str!("action_host.rs")
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let start = "crate::bringup_timer::vz_boot_started(); { let vz = Arc::clone(&vz);";
        assert_eq!(src.matches(start).count(), 1, "start stamp");
        let fail = "crate::bringup_timer::vz_boot_finished(1);";
        assert_eq!(src.matches(fail).count(), 1, "failure end");
        let ready = "if new_login_runtime_ready { crate::bringup_timer::vz_boot_finished(0); }";
        assert_eq!(src.matches(ready).count(), 1, "Ready end");
    }
}
