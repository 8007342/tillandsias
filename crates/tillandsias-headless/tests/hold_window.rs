// @trace order:828-h7kw, spec:simplified-tray-ux
//
// `tillandsias --hold-window -- <lane>` is what a lane's terminal runs, so the
// window survives the lane's exit. These drive the REAL binary: the hold must
// not return before the operator presses Enter, whatever the lane's exit, it
// must pass the lane's exit code through, and it must leave nothing behind.

#![cfg(unix)]

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn hold(lane: &[&str], home: &std::path::Path) -> std::process::Child {
    Command::new(env!("CARGO_BIN_EXE_tillandsias"))
        .arg("--hold-window")
        .arg("--")
        .args(lane)
        .env("HOME", home)
        .env("XDG_RUNTIME_DIR", home)
        .env("XDG_CACHE_HOME", home)
        .env("XDG_CONFIG_HOME", home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the tillandsias binary")
}

/// The hold outlives the lane until Enter, then returns the lane's code.
fn assert_holds(lane: &[&str], want_code: i32, want_word: &str) {
    let home = tempfile::tempdir().unwrap();
    let mut child = hold(lane, home.path());
    // The lane itself ends at once; the hold must still be waiting.
    std::thread::sleep(Duration::from_millis(700));
    assert!(
        child.try_wait().unwrap().is_none(),
        "{lane:?}: the window closed before the operator pressed Enter"
    );
    child.stdin.as_mut().unwrap().write_all(b"\n").unwrap();
    let t0 = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        assert!(
            t0.elapsed() < Duration::from_secs(5),
            "Enter did not close the hold"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    let mut out = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .unwrap();
    assert_eq!(
        status.code(),
        Some(want_code),
        "{lane:?}: exit code not passed through"
    );
    assert!(
        out.contains(want_word) && out.contains("Press Enter to close this window"),
        "{lane:?}: {out:?}"
    );
    // No residue: the hold wrote nothing under its home/runtime/cache/config.
    let left: Vec<_> = std::fs::read_dir(home.path()).unwrap().flatten().collect();
    assert!(left.is_empty(), "the hold left files behind: {left:?}");
}

#[test]
fn a_clean_lane_exit_holds_the_window_until_enter() {
    assert_holds(&["true"], 0, "finished (exit 0)");
}

#[test]
fn a_failed_lane_exit_holds_the_window_and_passes_the_code_through() {
    assert_holds(&["false"], 1, "FAILED (exit 1)");
}

#[test]
fn a_lane_that_cannot_start_still_holds() {
    assert_holds(&["/nonexistent/lane-binary"], 127, "could not start");
}
