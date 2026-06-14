use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn headless_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_tillandsias"))
}

#[test]
fn test_cli_coexistence_with_tray() {
    let binary = headless_binary();
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");

    // We run a CLI mode (like --opencode with a non-existent path)
    // and verify that the detached tray started by it does NOT kill it.
    let lock_name = "test-singleton-coexist";

    let mut child = Command::new(binary)
        .arg("/nonexistent-path-for-coexist-test")
        .arg("--opencode")
        .arg("--tray")
        .arg("--debug")
        .env("TILLANDSIAS_LOCK_NAME", lock_name)
        .env("XDG_RUNTIME_DIR", temp_dir.path())
        .env("TILLANDSIAS_NO_TRAY", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to spawn tillandsias CLI");

    // Give it a bit to execute
    let status = child.wait().expect("failed to wait for CLI process");

    // Read stdout/stderr for diagnostics
    let mut stdout_buf = String::new();
    let mut stderr_buf = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = out.read_to_string(&mut stdout_buf);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = err.read_to_string(&mut stderr_buf);
    }

    println!("--- CLI STDOUT ---");
    println!("{}", stdout_buf);
    println!("--- CLI STDERR ---");
    println!("{}", stderr_buf);

    // If the singleton guard bug existed, the child tray would terminate the parent CLI
    // with SIGTERM, causing code() to be None (on Unix) or status to indicate exit by signal.
    // If fixed, the parent CLI runs to completion and exits with code 1 (since /nonexistent-path is invalid).
    // Crucially, it must NOT exit with 143 (SIGTERM).
    assert!(
        status.code().is_some(),
        "CLI process was terminated by a signal (likely SIGTERM from the tray companion)! Status: {:?}",
        status
    );
    assert_ne!(
        status.code().unwrap(),
        143,
        "CLI process was terminated by SIGTERM (exit code 143). Status: {:?}",
        status
    );
}
