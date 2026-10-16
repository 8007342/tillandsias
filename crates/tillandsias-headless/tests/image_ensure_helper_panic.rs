// ORDER 1744-xjfw: the detached image-ensure helper names its own death.
//
// On the macOS guest (v56.10.15.1) the forge helper exited 101 and its build
// log held nothing past the forge-base pull. The helper's stdout and stderr ARE
// that log, so a failed write both panics the helper (println!/eprintln! panic
// on a write error) and loses the panic message. This test reproduces exactly
// that with the real binary: its stdout and stderr are a pipe whose read end is
// already closed, so every write fails (EPIPE; Rust ignores SIGPIPE). The panic
// hook must still leave the panic text in the sidecar file.
// @trace order:1744-xjfw

#![cfg(unix)]

use std::os::fd::{FromRawFd, OwnedFd};
use std::process::{Command, Stdio};

/// A write end whose reader is gone: every write to it fails.
fn dead_pipe() -> OwnedFd {
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe()");
    unsafe { libc::close(fds[0]) };
    unsafe { OwnedFd::from_raw_fd(fds[1]) }
}

#[test]
fn a_helper_that_cannot_write_its_log_still_records_its_panic() {
    let dir = tempfile::tempdir().unwrap();
    let sidecar = dir.path().join("helper.panic");
    let out = dead_pipe();
    let err = out.try_clone().unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_tillandsias"))
        // A root with no Containerfiles: the ensure fails at once, and its
        // error line is the first write, which is what panics.
        .args(["--internal-ensure-image"])
        .arg(dir.path().join("no-such-root"))
        .args(["xjfw-test-image", "tillandsias-xjfw-test:v0"])
        .env("TILLANDSIAS_IMAGE_BUILD_HELPER", "1")
        .env("TILLANDSIAS_IMAGE_ENSURE_PANIC_FILE", &sidecar)
        .env("HOME", dir.path())
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err))
        .status()
        .expect("spawn the helper");
    assert_eq!(
        status.code(),
        Some(101),
        "an unwritable log panics the helper: {status}"
    );
    let text = std::fs::read_to_string(&sidecar)
        .expect("the panic hook must leave the panic text in the sidecar");
    assert!(
        text.contains("failed printing to"),
        "the sidecar names the failed write: {text}"
    );
}
