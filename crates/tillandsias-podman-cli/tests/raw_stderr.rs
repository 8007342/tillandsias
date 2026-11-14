//! ORDER 2061-cpnt: the bounded `raw` path forwards the call's stderr, as the
//! real podman would. Under the litmus runtime every `podman` goes through this
//! binary; it kept stdout and dropped stderr, so `podman logs` of a container
//! that logs to stderr (squid) read near-empty and litmus:proxy-tier-ports-live
//! reported could-not-run under the runner while passing 8/8 run directly.
//!
//! One test per binary: the stub is written then exec'd by the CLI, and no
//! sibling thread forks in between (the 1478-9r6f race).
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::process::Command;

fn stub(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
    let p = dir.join("podman");
    std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

fn cli(stub: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_tillandsias-podman-cli"))
        .arg("raw")
        .args(args)
        .env("TILLANDSIAS_PODMAN_BIN", stub)
        .output()
        .expect("run the cli")
}

#[test]
fn the_raw_path_forwards_stderr_and_keeps_stdout() {
    let dir = std::env::temp_dir().join(format!("tillandsias-cpnt-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    // A podman that succeeds and writes to both streams (podman logs of a
    // container that logs to stderr).
    let ok = stub(&dir, "echo to-stdout\necho to-stderr >&2\nexit 0");
    let out = cli(&ok, &["logs", "c"]);
    let (so, se) = (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    );

    // NEGATIVE CONTROL: a failing call reports its stderr once, not twice.
    let bad = dir.join("bad");
    std::fs::create_dir_all(&bad).unwrap();
    let fail = stub(&bad, "echo boom-once >&2\nexit 3");
    let out_f = cli(&fail, &["logs", "c"]);
    let fe = String::from_utf8_lossy(&out_f.stderr).into_owned();

    let _ = std::fs::remove_dir_all(&dir);
    assert!(out.status.success(), "status {:?} stderr {se}", out.status);
    assert_eq!(so, "to-stdout\n", "stdout is the capture, unchanged");
    assert!(se.contains("to-stderr"), "stderr was dropped: {se:?}");
    assert!(!out_f.status.success());
    assert_eq!(fe.matches("boom-once").count(), 1, "failure stderr: {fe:?}");
}
