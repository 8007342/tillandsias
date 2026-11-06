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
        // 1968-psy9: mirror-seed has TWO call sites, one per launch path that
        // gates on the mirror (ensure_enclave_for_project and the OpenCode
        // lane); a launch runs one of them, so each launch still times it once.
        let seed = main
            .matches("timed_async( \"mirror-seed\", gate_forge_launch(")
            .count();
        assert_eq!(seed, 2, "mirror-seed timed at {seed} gate sites, want 2");
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

    fn repo_file(rel: &str) -> std::path::PathBuf {
        std::path::PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"),
        )
        .join("../..")
        .join(rel)
    }

    /// 2004-in3v: the forge entrypoint's timer helpers, run for real. One
    /// line per step in the lifecycle log, none on stderr unless debugging.
    #[test]
    #[cfg(unix)]
    fn forge_step_helpers_log_one_line_per_step_and_stay_off_the_screen() {
        let lib = repo_file("images/default/lib-common.sh");
        let t = tempfile::tempdir().unwrap();
        let log = t.path().join("lifecycle.log");
        let script = format!(
            "eval \"$(sed -n '/^_forge_now_us()/,/^}}/p;/^forge_step_line()/,/^}}/p;\
             /^forge_step_mark()/,/^}}/p;/^forge_step_done()/,/^}}/p' '{}')\"\n\
             set -e\nforge_step_mark\ntrue\nforge_step_done first\n\
             forge_step_mark\nX=exported\nforge_step_done second\n\
             [ \"$X\" = exported ]\n",
            lib.display()
        );
        let run = |debug: &str| {
            let _ = std::fs::remove_file(&log);
            let out = std::process::Command::new("bash")
                .arg("-c")
                .arg(&script)
                .env("TILLANDSIAS_LIFECYCLE_LOG", &log)
                .env("TILLANDSIAS_DEBUG", debug)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            (
                std::fs::read_to_string(&log).unwrap(),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            )
        };
        let (logged, stderr) = run("");
        let lines: Vec<&str> = logged.lines().collect();
        assert_eq!(lines.len(), 2, "{logged}");
        for (line, step) in lines.iter().zip(["first", "second"]) {
            let ms = line
                .strip_prefix(&format!("bringup: step=forge-entry-{step} ms="))
                .unwrap_or_else(|| panic!("bad line: {line}"));
            assert!(ms.parse::<u64>().is_ok(), "{line}");
        }
        assert!(stderr.is_empty(), "the agent's screen got: {stderr}");
        let (_, debug_stderr) = run("1");
        assert_eq!(
            debug_stderr
                .lines()
                .filter(|l| l.starts_with("bringup: "))
                .count(),
            2
        );
    }

    /// 2004-in3v: every timed step in the opencode entrypoint is a bare call
    /// between a mark and a done, names are unique, and the total span ends
    /// at launch.
    #[test]
    fn the_opencode_entrypoint_times_each_step_and_the_total() {
        let src = std::fs::read_to_string(repo_file("images/default/entrypoint-forge-opencode.sh"))
            .unwrap();
        let lines: Vec<&str> = src.lines().collect();
        let mut names = Vec::new();
        for (i, line) in lines.iter().enumerate() {
            if let Some(name) = line.strip_prefix("forge_step_done ") {
                assert!(
                    i >= 2 && lines[i - 2] == "forge_step_mark",
                    "{name}: no mark before its step"
                );
                assert!(
                    !lines[i - 1].starts_with("forge_step"),
                    "{name}: no step between mark and done"
                );
                names.push(name);
            }
        }
        assert!(names.len() >= 10, "{names:?}");
        let mut unique = names.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), names.len(), "duplicate step names: {names:?}");
        assert!(src.contains("FORGE_ENTRY_T0_US=\"${EPOCHREALTIME//[.,]/}\""));
        let total = src.find("forge_step_line total ").expect("total span");
        let launching = src
            .find("trace_lifecycle \"entrypoint\" \"opencode launching\"")
            .unwrap();
        assert!(total > launching, "the total span ends at launch");
    }
}
