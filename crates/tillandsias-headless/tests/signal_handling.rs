// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:graceful-shutdown
//! Direct-binary shutdown litmus for the headless launcher.
//!
//! Unix-only: drives the binary with libc::kill/SIGTERM process semantics.
//! PLEASE REVIEW: linux — cfg gate added by the windows lane so
//! `cargo test -p tillandsias-headless` compiles on Windows targets
//! (E0425 libc::pid_t/kill; litmus:cross-target-cfg-gate-check class).
#![cfg(unix)]

use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn headless_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tillandsias"))
}

fn wait_with_timeout(child: &mut std::process::Child, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => return Ok(()),
            Ok(None) => {
                if Instant::now() >= deadline {
                    return Err(format!("process did not exit within {:?}", timeout));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(err) => return Err(format!("failed to poll child status: {err}")),
        }
    }
}

fn assert_shutdown(signal: libc::c_int, signal_name: &str) {
    let binary = headless_binary();
    let start = Instant::now();

    let mut child = Command::new(binary)
        .arg("--headless")
        .env(
            "TILLANDSIAS_LOCK_NAME",
            format!("test-signal-{}", signal_name),
        )
        .env("TILLANDSIAS_STOP_TIMEOUT", "2")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn direct tillandsias binary");

    let mut stdout = child.stdout.take().expect("missing stdout pipe");
    let mut stderr = child.stderr.take().expect("missing stderr pipe");

    // Give the child time to install its signal handlers before we signal it.
    // Under `--ci-full` load (concurrent image/litmus builds) startup is slower,
    // so 250ms was racy — keep generous headroom.
    std::thread::sleep(Duration::from_millis(1500));

    let pid = child.id() as libc::pid_t;
    let rc = unsafe { libc::kill(pid, signal) };
    assert_eq!(rc, 0, "failed to send {signal_name} to pid {pid}");

    // Generous ceiling: this asserts the process does not HANG on shutdown, not
    // that it shuts down within a tight wall-clock budget. A 5s ceiling flaked
    // under concurrent `--ci-full` load; 30s still flaked (graceful shutdown
    // self-reported ~32s under full parallel image/litmus load while exiting
    // cleanly with code 0). Keep a wide hang-detection ceiling.
    if let Err(err) = wait_with_timeout(&mut child, Duration::from_secs(60)) {
        let mut stdout_buf = String::new();
        let mut stderr_buf = String::new();
        let _ = stdout.read_to_string(&mut stdout_buf);
        let _ = stderr.read_to_string(&mut stderr_buf);
        panic!(
            "{signal_name} shutdown litmus failed: {err}\n--- CHILD STDOUT ---\n{stdout_buf}\n--- CHILD STDERR ---\n{stderr_buf}\n"
        );
    }

    let status = child.wait().expect("failed to collect child status");
    let elapsed = start.elapsed();

    assert!(
        status.success() || status.code().is_none(),
        "{signal_name} should stop the direct binary cleanly, got {status:?}"
    );
    assert!(
        elapsed < Duration::from_secs(60),
        "{signal_name} shutdown should finish without hanging, took {elapsed:?}"
    );

    let mut stdout_buf = String::new();
    let mut stderr_buf = String::new();
    stdout
        .read_to_string(&mut stdout_buf)
        .expect("failed to read child stdout");
    stderr
        .read_to_string(&mut stderr_buf)
        .expect("failed to read child stderr");

    assert!(
        stdout_buf.contains(r#""event":"app.started""#),
        "missing startup event in stdout: {stdout_buf}"
    );
    assert!(
        stderr_buf.contains("Received shutdown signal"),
        "missing shutdown signal trace in stderr: {stderr_buf}"
    );
    assert!(
        stderr_buf.contains("Graceful shutdown completed"),
        "missing graceful shutdown trace in stderr: {stderr_buf}"
    );
}

#[test]
fn test_signal_handling_sigterm() {
    assert_shutdown(libc::SIGTERM, "SIGTERM");
}

#[test]
fn test_signal_handling_sigint() {
    assert_shutdown(libc::SIGINT, "SIGINT");
}
