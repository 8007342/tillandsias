// @trace order:1443-esm5, spec:ci-release
//
// The verifiable closure of 1443-esm5, the executor half: bounded output is a
// property of Command::run, reported as a field, never silently applied. Each
// test names the PRE-FIX result the packet recorded. The proc.run half lives in
// crates/tillandsias-plan/tests/lua_proc.rs.

use std::time::{Duration, Instant};
use tillandsias_exec::{Command, Completion, DEFAULT_CAPTURE_BYTES};

const MIB: usize = 1024 * 1024;

/// CRITERION 1. 3 MiB on stdout under a 1 MiB cap: the first 1 MiB is kept,
/// the run completes normally, and the Output SAYS it was clipped and by how
/// much.
/// PRE-FIX: FAILS to compile. Command had no capture_bytes, Output had no
/// truncated/dropped, and stdout held all 3 MiB.
#[tokio::test]
async fn a_capture_past_the_cap_is_kept_to_the_cap_and_reported() {
    let deadline = Duration::from_secs(60);
    let t0 = Instant::now();
    let out = Command::new(["sh", "-c", "head -c 3145728 /dev/zero"])
        .capture_bytes(MIB)
        .timeout(deadline)
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.completion, Completion::Exited(0));
    assert_eq!(out.stdout.len(), MIB, "kept exactly the cap");
    assert!(out.truncated, "a clipped capture must say so");
    assert_eq!(
        out.dropped,
        2 * MIB as u64,
        "dropped counts every discarded byte"
    );
    assert!(t0.elapsed() < deadline, "finished inside the deadline");
}

/// CRITERION 2. 64 MiB on stdout AND 64 MiB on stderr under a 1 MiB cap
/// completes: both fds keep draining past the cap, so the child never blocks
/// on a full pipe, and only 2 MiB is ever held.
/// PRE-FIX: FAILS. With no cap the test allocates 128 MiB and passes for the
/// wrong reason; a regression that STOPS reading at the cap does not fail
/// here, it hangs until the deadline, which the TimedOut assertion reports.
#[tokio::test]
async fn both_fds_keep_draining_past_the_cap_without_deadlock() {
    let script = "head -c 67108864 /dev/zero & head -c 67108864 /dev/zero 1>&2; wait";
    let out = Command::new(["sh", "-c", script])
        .capture_bytes(MIB)
        .timeout(Duration::from_secs(120))
        .run()
        .await
        .expect("spawn");
    assert_eq!(
        out.completion,
        Completion::Exited(0),
        "a TimedOut here means a capped fd stopped being drained"
    );
    assert_eq!(out.stdout.len(), MIB);
    assert_eq!(out.stderr.len(), MIB);
    assert!(out.truncated);
    assert_eq!(out.dropped, 2 * (64 * MIB - MIB) as u64);
}

/// CRITERION 4, the NEGATIVE CONTROL. 100 bytes under the same cap is whole:
/// truncated=false, dropped=0. Without this, "always report truncated" would
/// satisfy criteria 1 and 2.
#[tokio::test]
async fn a_capture_under_the_cap_is_whole() {
    let out = Command::new(["sh", "-c", "head -c 100 /dev/zero"])
        .capture_bytes(MIB)
        .run()
        .await
        .expect("spawn");
    assert!(out.completion.is_success());
    assert_eq!(out.stdout.len(), 100);
    assert!(!out.truncated);
    assert_eq!(out.dropped, 0);
}

/// The default cap is the 8 MiB the packet chose, so no existing caller's
/// output changes: 1 MiB with no capture_bytes call comes back whole.
#[tokio::test]
async fn the_default_cap_leaves_ordinary_output_whole() {
    assert_eq!(DEFAULT_CAPTURE_BYTES, 8 * MIB);
    let out = Command::new(["sh", "-c", "head -c 1048576 /dev/zero"])
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.stdout.len(), MIB);
    assert!(!out.truncated);
    assert_eq!(out.dropped, 0);
}
