//! ORDER 1915-brst — one timer line per runtime bring-up step.
//!
//! Every snapshot and warm-start saving was an estimate because nothing timed
//! the steps. Each step now reports `bringup: step=<name> ms=<n>` on stderr,
//! taken from two timestamps at the step's own boundaries. Nothing here polls:
//! a step that waits already waited before this saw it.
//!
//! The same measurement becomes one timing-ledger row, but only where the
//! ledger is already switched on (`TILLANDSIAS_TIMING_LOG`, the rule
//! `tillandsias-plan script run` follows, 1204-3s2s). The row is the
//! scripts/timing-log.sh shape and carries the step name, the duration and the
//! exit, never a path, a project name or a user name.

use std::time::Instant;

/// The step names a bring-up can report. Kept closed so a row can never carry
/// a free-form string.
pub(crate) const STEPS: &[&str] = &[
    "wsl-boot",
    "proxy-ready",
    "vault-health",
    "image-ensure",
    "mirror-seed",
    "model-preload",
    "forge-start",
];

/// The stderr line, exactly as a litmus greps it.
pub(crate) fn line(step: &str, ms: u128) -> String {
    format!("bringup: step={step} ms={ms}")
}

/// Run `f` as bring-up step `step`, report its duration, and return its result
/// unchanged. An `Err` is recorded with exit 1.
pub(crate) fn timed<T, E>(step: &'static str, f: impl FnOnce() -> Result<T, E>) -> Result<T, E> {
    let t0 = Instant::now();
    let r = f();
    report(
        step,
        t0.elapsed().as_millis(),
        if r.is_ok() { 0 } else { 1 },
    );
    r
}

/// The async form of [`timed`], for steps that run inside a runtime.
pub(crate) async fn timed_async<T, E>(
    step: &'static str,
    f: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, E> {
    let t0 = Instant::now();
    let r = f.await;
    report(
        step,
        t0.elapsed().as_millis(),
        if r.is_ok() { 0 } else { 1 },
    );
    r
}

pub(crate) fn report(step: &'static str, ms: u128, exit: i32) {
    debug_assert!(STEPS.contains(&step), "unknown bring-up step {step}");
    let l = line(step, ms);
    eprintln!("{l}");
    #[cfg(test)]
    capture::push(&l);
    if let Some(path) = std::env::var_os("TILLANDSIAS_TIMING_LOG") {
        append_row(std::path::Path::new(&path), step, ms, exit);
    }
}

fn host() -> String {
    std::env::var("TILLANDSIAS_HOST_ID")
        .ok()
        .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
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

/// Test-only record of the lines emitted on this thread, so a test can assert
/// what a real bring-up path reported without capturing the process's stderr.
#[cfg(test)]
pub(crate) mod capture {
    use std::cell::RefCell;
    thread_local! { static LINES: RefCell<Option<Vec<String>>> = const { RefCell::new(None) }; }
    pub(crate) fn start() {
        LINES.with(|l| *l.borrow_mut() = Some(Vec::new()));
    }
    pub(crate) fn take() -> Vec<String> {
        LINES.with(|l| l.borrow_mut().take().unwrap_or_default())
    }
    pub(super) fn push(line: &str) {
        LINES.with(|l| {
            if let Some(v) = l.borrow_mut().as_mut() {
                v.push(line.to_string());
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timed_reports_one_line_and_returns_the_result() {
        capture::start();
        let r: Result<u8, String> = timed("image-ensure", || Ok(7));
        let lines = capture::take();
        assert_eq!(r, Ok(7));
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(
            lines[0].starts_with("bringup: step=image-ensure ms="),
            "{lines:?}"
        );
        assert!(
            lines[0]["bringup: step=image-ensure ms=".len()..]
                .parse::<u128>()
                .is_ok()
        );
    }

    /// Comment lines dropped, braces and whitespace collapsed, so a pin cannot be met by
    /// a comment and does not depend on rustfmt's line breaks.
    fn code(src: &str) -> String {
        src.lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join(" ")
            .replace(['{', '}'], " ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Each launch step is timed exactly once, around the call that performs
    /// it. The forge-start report is exercised for real by the fake-podman
    /// attached-launch test; these steps need a live enclave to run.
    #[test]
    fn every_bringup_step_is_timed_once_at_its_call_site() {
        let main = code(include_str!("main.rs"));
        let deps = code(include_str!("container_deps.rs"));
        let pins: &[(&str, &str, &str)] = &[
            (
                &deps,
                "proxy-ready",
                "timed(\"proxy-ready\", || crate::ensure_proxy_running(self.debug)",
            ),
            (
                &deps,
                "vault-health",
                "timed(\"vault-health\", || crate::vault_bootstrap::ensure_vault_running(self.debug)",
            ),
            (
                &main,
                "vault-health (--init)",
                "timed(\"vault-health\", || vault_bootstrap::ensure_vault_running(debug)",
            ),
            (
                &main,
                "image-ensure (--init)",
                "timed(\"image-ensure\", || run_init(debug, force)",
            ),
            (
                &main,
                "image-ensure (launch)",
                "timed(\"image-ensure\", || ensure_versioned_images( &root, launch_images::launch_images(launch_images::LaunchSite::EnclaveForProject),",
            ),
            (
                &main,
                "mirror-seed",
                "timed_async( \"mirror-seed\", wait_for_git_mirror_ready(",
            ),
            (
                &main,
                "model-preload",
                "timed_async( \"model-preload\", ensure_inference_for_launch(client, certs_dir, version, debug),",
            ),
            (
                &main,
                "forge-start",
                "bringup_timer::report(\"forge-start\", forge_started.elapsed().as_millis(), 0);",
            ),
        ];
        let mut missing = Vec::new();
        for (src, step, needle) in pins {
            let n = src.matches(needle).count();
            if n != 1 {
                missing.push(format!("{step}: {n} matches"));
            }
        }
        assert!(
            missing.is_empty(),
            "bring-up steps not timed exactly once: {missing:?}"
        );
    }

    #[test]
    fn ledger_row_has_only_step_duration_exit_and_host() {
        let dir = std::env::temp_dir().join(format!("bringup-timer-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("t.jsonl");
        append_row(&p, "vault-health", 42, 1);
        let row: serde_json::Value =
            serde_json::from_str(std::fs::read_to_string(&p).unwrap().trim()).unwrap();
        let keys: Vec<&str> = row
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        let mut keys = keys;
        keys.sort_unstable();
        assert_eq!(keys, ["duration_ms", "exit", "host", "phase", "step", "ts"]);
        assert_eq!(row["step"], "vault-health");
        assert_eq!(row["phase"], "bringup");
        assert_eq!(row["duration_ms"], 42);
        assert_eq!(row["exit"], 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
