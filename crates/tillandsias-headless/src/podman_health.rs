//! A podman that cannot start is not a failed build (order 1792-48yg).
//!
//! @trace order:1792-48yg, order:1776-brk3
//!
//! Measured on the v56.10.18.1 macOS smoke (2026-10-19), on the first forge
//! launch after a full wipe: the guest kernel logged `SELinux:  Invalid class
//! 0`, and from then until reboot every podman exec failed with
//! `/usr/bin/podman: error while loading shared libraries: libsemanage.so.2:
//! cannot open shared object file: Invalid argument`. The image ensure counted
//! each of those as a failed build of forge-base, spent its whole retry budget
//! on a podman that could not even load, and declared forge-base failed. The
//! next launch, on a freshly booted and healthy guest, was then refused
//! (1793-wggq).
//!
//! The inputs were never at fault, so none of that may be recorded against the
//! image:
//!
//! - [`podman_could_not_start`] recognises the loader failure in the build
//!   error;
//! - [`after_failure`] gives it one free retry when a `podman --version` probe
//!   now answers, and otherwise refuses with [`refusal`], spending no budget
//!   and writing no failure marker, so the next launch builds normally;
//! - [`capture_once`] writes, once per boot, what the next diagnosis needs to
//!   [`CAPTURE_DIR`] under the init cache dir. That directory is on the guest
//!   disk, so it survives the power-off, and the refusal names the file. It
//!   records the build error, the kernel log around the first `SELinux:
//!   Invalid class` line, every policy load this boot, `semodule -l`,
//!   `sestatus`, the SELinux label of the library the loader could not open,
//!   the relevant package versions and the process table.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Under the init cache dir. Read it back on macOS with
/// `tillandsias-tray --exec-guest 'ls /root/.cache/tillandsias/podman-broken-captures'`.
pub(crate) const CAPTURE_DIR: &str = "podman-broken-captures";

const LOADER_ERROR: &str = "error while loading shared libraries";

/// The library the loader names: `…: libsemanage.so.2: cannot open …`.
fn loader_line(err: &str) -> Option<&str> {
    err.lines().map(str::trim).find(|l| {
        l.split_once(':').is_some_and(|(prog, rest)| {
            prog.trim_end().ends_with("podman") && rest.contains(LOADER_ERROR)
        })
    })
}

/// True when the build failed because the podman binary itself could not
/// start. A RUN step's own `command not found` (also exit 127) is a real
/// build failure and is not this.
pub(crate) fn podman_could_not_start(err: &str) -> bool {
    loader_line(err).is_some()
}

fn missing_library(err: &str) -> Option<&str> {
    let line = loader_line(err)?;
    let after = line
        .split_once(LOADER_ERROR)?
        .1
        .trim_start_matches(':')
        .trim();
    after
        .split(':')
        .next()
        .map(str::trim)
        .filter(|l| !l.is_empty())
}

/// What the build loop does with a failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AfterFailure {
    /// A real build failure: count it against the retry budget (1776-brk3).
    Count,
    /// Podman could not start, but answers now: build again, uncounted.
    FreeRetry,
    /// Podman could not start and still cannot: refuse, count nothing and
    /// record no marker.
    Refuse,
}

/// At most one free retry per ensure, and only after the probe answers, so a
/// podman that stays broken cannot loop.
pub(crate) fn after_failure(
    err: &str,
    free_retries_used: u32,
    probe_answers: impl FnOnce() -> bool,
) -> AfterFailure {
    if !podman_could_not_start(err) {
        return AfterFailure::Count;
    }
    if free_retries_used == 0 && probe_answers() {
        AfterFailure::FreeRetry
    } else {
        AfterFailure::Refuse
    }
}

/// The typed refusal. It names the capture, so the next reader starts from
/// evidence.
pub(crate) fn refusal(image: &str, err: &str, capture: Option<&Path>) -> String {
    let why = loader_line(err).unwrap_or("podman could not start");
    let capture = capture.map_or_else(
        || "none (the capture could not be written)".to_string(),
        |p| p.display().to_string(),
    );
    format!(
        "refused:image-ensure:{image}:podman-could-not-start\n  why: {why}\n  capture: {capture}\n  remedy: the image's inputs are not at fault and nothing was recorded against {image}; the next launch builds it again (on macOS and Windows the guest restarts between launches; on Linux, restart the machine if `podman --version` fails the same way)"
    )
}

/// Whether `podman --version` runs to completion now.
pub(crate) fn podman_starts(mut cmd: tillandsias_podman::SyncPodmanCommand) -> bool {
    cmd.arg("--version");
    cmd.output_bounded(Duration::from_secs(20)).is_ok_and(|o| {
        o.status.success() && !String::from_utf8_lossy(&o.stderr).contains(LOADER_ERROR)
    })
}

/// The kernel log window a diagnosis needs: from a few lines before the first
/// `Invalid class` through the WARNING and its register dump that follow.
pub(crate) fn invalid_class_excerpt(kernel_log: &str) -> Option<String> {
    let lines: Vec<&str> = kernel_log.lines().collect();
    let first = lines
        .iter()
        .position(|l| l.contains("SELinux:") && l.contains("Invalid class"))?;
    let from = first.saturating_sub(5);
    let to = (first + 80).min(lines.len());
    Some(lines[from..to].join("\n"))
}

/// The capture file for this boot, `None` when this boot already has one.
pub(crate) fn capture_path(
    dir: &Path,
    boot_id: &str,
    now_utc: &str,
    image: &str,
) -> Option<PathBuf> {
    let boot: String = boot_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(32)
        .collect();
    let boot = if boot.is_empty() {
        "unknown-boot".to_string()
    } else {
        boot
    };
    let exists = std::fs::read_dir(dir).is_ok_and(|rd| {
        rd.filter_map(Result::ok).any(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with(&format!("{boot}-"))
        })
    });
    (!exists).then(|| dir.join(format!("{boot}-{now_utc}-{image}.txt")))
}

/// Run a diagnostic command for at most `budget`; its output, or why not.
fn bounded(program: &str, args: &[&str], budget: Duration) -> String {
    let mut child = match Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return format!("(could not run {program}: {e})"),
    };
    let mut out = child.stdout.take();
    let mut err = child.stderr.take();
    let reader = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(o) = out.as_mut() {
            let _ = o.read_to_string(&mut s);
        }
        if let Some(e) = err.as_mut() {
            let _ = e.read_to_string(&mut s);
        }
        s
    });
    let deadline = Instant::now() + budget;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return format!("(timed out after {} s: {program})", budget.as_secs());
            }
        }
    }
    reader.join().unwrap_or_default()
}

/// Write this boot's capture (once) and return its path.
pub(crate) fn capture_once(cache_dir: &Path, image: &str, err: &str) -> Option<PathBuf> {
    let dir = cache_dir.join(CAPTURE_DIR);
    std::fs::create_dir_all(&dir).ok()?;
    let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").unwrap_or_default();
    let now = chrono::Utc::now();
    let Some(path) = capture_path(
        &dir,
        boot_id.trim(),
        &now.format("%Y%m%dT%H%M%SZ").to_string(),
        image,
    ) else {
        // This boot is already captured; name that file instead.
        let boot: String = boot_id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .take(32)
            .collect();
        return std::fs::read_dir(&dir)
            .ok()?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .find(|p| {
                p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with(&format!("{boot}-")))
            });
    };
    let t = Duration::from_secs(10);
    let kernel = bounded(
        "journalctl",
        &["-k", "-b", "0", "--no-pager", "-o", "short-iso"],
        t,
    );
    let lib = missing_library(err).unwrap_or("libsemanage.so.2");
    let lib_path = format!("/usr/lib64/{lib}");
    let mut body = String::new();
    let mut section = |title: &str, text: &str| {
        body.push_str(&format!("== {title}\n{}\n\n", text.trim_end()));
    };
    section(
        "what",
        &format!(
            "order 1792-48yg capture: podman could not start during the image ensure of {image}\nutc: {}\nboot_id: {}",
            now.format("%Y-%m-%dT%H:%M:%SZ"),
            boot_id.trim()
        ),
    );
    section("build error", err);
    section(
        "kernel log around the first SELinux Invalid class",
        &invalid_class_excerpt(&kernel).unwrap_or_else(|| {
            "(no `SELinux: Invalid class` line in this boot's kernel log)".into()
        }),
    );
    section(
        "policy loads this boot",
        &bounded(
            "journalctl",
            &[
                "-b",
                "0",
                "--no-pager",
                "-o",
                "short-iso",
                "-g",
                "MAC_POLICY_LOAD|type=1403|type=1404",
            ],
            t,
        ),
    );
    section("semodule -l", &bounded("semodule", &["-l"], t));
    section("sestatus", &bounded("sestatus", &[], t));
    section(
        &format!("label of {lib_path}"),
        &bounded("ls", &["-lZ", &lib_path], t),
    );
    section(
        "packages",
        &bounded(
            "rpm",
            &[
                "-q",
                "kernel-core",
                "selinux-policy-targeted",
                "container-selinux",
                "podman",
                "libsemanage",
            ],
            t,
        ),
    );
    section(
        "processes",
        &bounded("ps", &["-eo", "pid,etime,comm,args"], t),
    );
    std::fs::write(&path, body).ok()?;
    if let Ok(f) = std::fs::File::open(&path) {
        let _ = f.sync_all();
    }
    Some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The build error v56.10.18.1 recorded for forge-base's attempts 2 and 3.
    const MEASURED: &str = "Build exited with status exit status: 127; podman's last stderr lines:\n  /usr/sbin/podman: error while loading shared libraries: libsemanage.so.2: cannot open shared object file: Invalid argument";

    /// Red first: before 1792 every one of these counted against the budget,
    /// so a podman that could not start declared forge-base failed.
    #[test]
    fn a_podman_that_cannot_load_is_not_a_failed_build() {
        assert!(podman_could_not_start(MEASURED));
        assert_eq!(missing_library(MEASURED), Some("libsemanage.so.2"));
        assert_eq!(after_failure(MEASURED, 0, || true), AfterFailure::FreeRetry);
        assert_eq!(after_failure(MEASURED, 0, || false), AfterFailure::Refuse);
        // Never a loop: a second loader failure in the same ensure refuses.
        assert_eq!(after_failure(MEASURED, 1, || true), AfterFailure::Refuse);
    }

    /// NEGATIVE CONTROL: real build failures still count, including a RUN step
    /// whose own command is missing (also exit 127), and a loader error from a
    /// program other than podman inside a RUN step.
    #[test]
    fn a_real_build_failure_still_counts() {
        for err in [
            "Build exited with status 1; podman's last stderr lines:\n  Error: building at STEP \"RUN microdnf install -y nope\": exit status 1",
            "Build exited with status exit status: 127; podman's last stderr lines:\n  /bin/sh: line 1: wasm-pack: command not found",
            "Build exited with status 1; podman's last stderr lines:\n  node: error while loading shared libraries: libnode.so.115: cannot open shared object file",
        ] {
            assert!(!podman_could_not_start(err), "{err}");
            assert_eq!(
                after_failure(err, 0, || panic!("no probe for a real failure")),
                AfterFailure::Count
            );
        }
    }

    #[test]
    fn the_refusal_names_the_cause_and_the_capture_and_records_nothing() {
        let r = refusal(
            "forge-base",
            MEASURED,
            Some(Path::new("/c/podman-broken-captures/b-t-forge-base.txt")),
        );
        assert!(
            r.starts_with("refused:image-ensure:forge-base:podman-could-not-start\n"),
            "{r}"
        );
        assert!(r.contains("libsemanage.so.2"), "{r}");
        assert!(
            r.contains("capture: /c/podman-broken-captures/b-t-forge-base.txt"),
            "{r}"
        );
        assert!(r.contains("nothing was recorded against forge-base"), "{r}");
        assert!(!r.contains("build-failed-previously"), "{r}");
    }

    #[test]
    fn the_excerpt_starts_at_the_first_invalid_class_line() {
        let log = "a\nb\nc\nd\ne\nf\nkernel: SELinux:  Invalid class 0\nkernel: WARNING: security/selinux/avc.c:761 at slow_avc_audit+0xc4/0xe0, CPU#7: podman/17124\nkernel: SELinux:  Invalid class 0";
        let ex = invalid_class_excerpt(log).unwrap();
        assert!(ex.starts_with("b\n"), "{ex}");
        assert!(ex.contains("podman/17124"), "{ex}");
        assert_eq!(invalid_class_excerpt("nothing here"), None);
    }

    /// Once per boot: a second detection in the same boot names the first file.
    #[test]
    fn one_capture_per_boot() {
        let d = tempfile::tempdir().unwrap();
        let p = capture_path(d.path(), "ab12-cd", "20261019T085015Z", "forge-base").unwrap();
        assert_eq!(
            p.file_name().unwrap(),
            "ab12cd-20261019T085015Z-forge-base.txt"
        );
        std::fs::write(&p, "x").unwrap();
        assert_eq!(
            capture_path(d.path(), "ab12-cd", "20261019T085200Z", "forge-base"),
            None
        );
        assert!(capture_path(d.path(), "ef34", "20261019T085200Z", "forge-base").is_some());
    }
}
