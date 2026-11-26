//! Order 2408-fsxe: a TERM or INT to the RUNNER ends its live child groups.
//!
//! A grouped child leads its own process group, so a signal to the runner
//! never reached it: the runner died with 143 and the child was reparented,
//! unbounded, because the deadline that would have ended it died with the
//! runner (#1610 arm 11b, land run 94: "live=1 left=1 rc=143").
//!
//! The test re-executes its own binary as the RUNNER (the `RUNNER_TERM_ROLE`
//! env), which runs one grouped `sh` that records its pid, sets an EXIT trap
//! that removes a marker, and blocks. The test signals the runner and then
//! asks whether that sh is still alive and whether its trap ran. The control
//! arm lets the child finish by itself and pins that nothing else changed.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

const ROLE: &str = "RUNNER_TERM_ROLE";
const DIR: &str = "RUNNER_TERM_DIR";

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "tilland-runner-term-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// The runner role: one grouped sh that blocks until `release` appears.
fn as_runner(dir: &Path) {
    let d = dir.display().to_string();
    let script = format!(
        "echo $$ > '{d}/pid.tmp'; mv '{d}/pid.tmp' '{d}/pid'; touch '{d}/marker'; \
         trap \"rm -f '{d}/marker'\" EXIT; trap 'exit 143' TERM; \
         while [ ! -e '{d}/release' ]; do sleep 0.05; done"
    );
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let out = rt
        .block_on(
            tillandsias_exec::Command::new(["sh".to_string(), "-c".to_string(), script])
                .group(true)
                .timeout(Duration::from_secs(60))
                .run(),
        )
        .expect("spawn");
    std::fs::write(dir.join("runner-done"), format!("{:?}", out.completion)).unwrap();
}

fn alive(pid: i32) -> bool {
    // SAFETY: kill with signal 0 only probes; no pointers.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait_for(p: &Path, within: Duration) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < within {
        if p.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn spawn_runner(dir: &Path, test: &str) -> std::process::Child {
    std::process::Command::new(std::env::current_exe().unwrap())
        .args([test, "--exact", "--nocapture", "--test-threads=1"])
        .env(ROLE, "runner")
        .env(DIR, dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

/// Signal the runner; the child must be gone and its trap run within the grace.
fn signalled(sig: libc::c_int, test: &str) {
    if std::env::var_os(ROLE).is_some() {
        return as_runner(Path::new(&std::env::var_os(DIR).unwrap()));
    }
    let dir = scratch(test);
    let mut runner = spawn_runner(&dir, test);
    assert!(
        wait_for(&dir.join("pid"), Duration::from_secs(20)),
        "child never started"
    );
    let child: i32 = std::fs::read_to_string(dir.join("pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    // SAFETY: kill takes no pointers.
    unsafe { libc::kill(runner.id() as i32, sig) };
    let status = runner.wait().unwrap();
    let t0 = Instant::now();
    while alive(child) && t0.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(20));
    }
    let (live, marker) = (alive(child), dir.join("marker").exists());
    if live {
        // Do not leave the orphan this test exists to catch.
        unsafe { libc::killpg(child, libc::SIGKILL) };
    }
    let _ = std::fs::remove_dir_all(&dir);
    use std::os::unix::process::ExitStatusExt;
    assert!(
        !live,
        "child group {child} outlived the runner's signal {sig}"
    );
    assert!(!marker, "child's EXIT trap never ran");
    assert_eq!(
        status.signal(),
        Some(sig),
        "runner must exit with the signal's status: {status:?}"
    );
}

#[test]
fn term_to_the_runner_ends_its_child_group() {
    signalled(libc::SIGTERM, "term_to_the_runner_ends_its_child_group");
}

#[test]
fn int_to_the_runner_ends_its_child_group() {
    signalled(libc::SIGINT, "int_to_the_runner_ends_its_child_group");
}

/// Control: no signal. The child finishes by itself and the run reports it.
#[test]
fn without_a_signal_the_run_is_unchanged() {
    let test = "without_a_signal_the_run_is_unchanged";
    if std::env::var_os(ROLE).is_some() {
        return as_runner(Path::new(&std::env::var_os(DIR).unwrap()));
    }
    let dir = scratch(test);
    let mut runner = spawn_runner(&dir, test);
    assert!(
        wait_for(&dir.join("pid"), Duration::from_secs(20)),
        "child never started"
    );
    std::fs::write(dir.join("release"), "").unwrap();
    let status = runner.wait().unwrap();
    let done = std::fs::read_to_string(dir.join("runner-done")).unwrap_or_default();
    let marker = dir.join("marker").exists();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "runner: {status:?}");
    assert_eq!(done, "Exited(0)", "completion");
    assert!(!marker, "trap ran on a normal exit");
}
