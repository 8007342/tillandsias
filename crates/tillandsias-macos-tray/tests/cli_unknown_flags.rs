//! Behavioral CLI-surface tests for the macOS tray binary.
//!
//! These spawn the real binary rather than scanning its source, so they pin
//! observable behavior (exit code + stderr) instead of an implementation shape.
//!
//! @trace spec:macos-native-tray, plan 663-acdw

#![cfg(target_os = "macos")]

use std::process::Command;

/// 663-acdw: an unrecognized flag used to fall through to the AppKit tray —
/// putting up an unrelated menu-bar icon AND taking the VM singleton, so the
/// operator's next one-shot refused (order 277) or wedged on the VZ storage
/// lock (663-69kp). `--with-token` is the case that cost real sessions: it is a
/// `tillandsias-headless` (guest) flag with no macOS host equivalent, and the
/// silent acceptance made two credential runs look like they were doing
/// something.
#[test]
fn unknown_flag_is_refused_loudly_and_names_the_flag() {
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-tray"))
        .arg("--with-token")
        .output()
        .expect("tray binary runs");

    assert_eq!(
        out.status.code(),
        Some(2),
        "unknown flag must exit 2; stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("unknown flag") && stderr.contains("--with-token"),
        "the refusal must name the offending flag; got: {stderr}"
    );
}

/// NEGATIVE CONTROL for the guard above (bar-raise 634-39ik: a pin that can
/// only ever fire positively proves nothing). A supported flag must still be
/// accepted — `--diagnose` prints a static report and exits without booting the
/// VM, so it must NOT come back as the exit-2 unknown-flag refusal. Without
/// this, a guard that rejected *every* flag would pass the test above.
#[test]
fn supported_flag_is_not_swallowed_by_the_unknown_flag_guard() {
    let out = Command::new(env!("CARGO_BIN_EXE_tillandsias-tray"))
        .arg("--diagnose")
        .output()
        .expect("tray binary runs");

    // ASSERT THE REFUSAL, NOT THE EXIT CODE. Exit 2 is OVERLOADED on this
    // binary: the unknown-flag guard exits 2, and so does `--diagnose` when the
    // host is NOT PROVISIONED (install-macos.sh documents "first install is
    // 2 / not provisioned"). So `assert_ne!(code, Some(2))` claims to test the
    // guard while actually testing whether this machine happens to have a
    // provisioned guest.
    //
    // MEASURED on macneo 2026-09-21, mid-smoke, right after --reset-state
    // cleared the image root: DIAG_EXIT=2, ZERO occurrences of "unknown flag"
    // in the output, and the last line reading "Status: NOT PROVISIONED". The
    // test went red having found nothing wrong with the guard it names.
    //
    // It was latent until 1286-4437 made reset-then-provision the DEFAULT
    // install path, which puts every macOS host in the unprovisioned state for
    // the length of a provision — so this would now fail on any host gating
    // during that window, not just here.
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("unknown flag"),
        "--diagnose is supported and must not hit the unknown-flag refusal; \
         exit={:?} stderr: {stderr}",
        out.status.code()
    );
}
