// @trace spec:linux-native-portable-executable, spec:headless-mode, spec:graceful-shutdown
//! Direct-binary shutdown litmus for the headless launcher.

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
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn direct tillandsias binary");

    let mut stdout = child.stdout.take().expect("missing stdout pipe");
    let mut stderr = child.stderr.take().expect("missing stderr pipe");

    std::thread::sleep(Duration::from_millis(250));

    let pid = child.id() as libc::pid_t;
    let rc = unsafe { libc::kill(pid, signal) };
    assert_eq!(rc, 0, "failed to send {signal_name} to pid {pid}");

    wait_with_timeout(&mut child, Duration::from_secs(5))
        .unwrap_or_else(|err| panic!("{signal_name} shutdown litmus failed: {err}"));

    let status = child.wait().expect("failed to collect child status");
    let elapsed = start.elapsed();

    assert!(
        status.success() || status.code().is_none(),
        "{signal_name} should stop the direct binary cleanly, got {status:?}"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "{signal_name} shutdown should finish quickly, took {elapsed:?}"
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
