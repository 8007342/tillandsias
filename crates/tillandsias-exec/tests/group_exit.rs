// @trace order:1443-8pur, spec:command-runtime
//
// Slice 1b of 1443-8pur, measured on darwin by macbookair and POSIX everywhere:
// in a GROUP run, nothing the child starts outlives the run, and the LEADER's
// status is what is reported. PRE-FIX (397c5f3ff) both arms FAIL: 3a reports
// TimedOut after the full deadline; 3b's grandchild is still alive.
#![cfg(unix)]

use std::time::{Duration, Instant};
use tillandsias_exec::{Command, Completion};

/// Is `pid` still a live process (not gone, not a zombie awaiting a reaper)?
fn alive(pid: i32) -> bool {
    #[cfg(target_os = "linux")]
    {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Err(_) => false,
            // state is the field after the parenthesised comm
            Ok(s) => s
                .rsplit(')')
                .next()
                .map(|r| r.trim_start().chars().next() != Some('Z'))
                .unwrap_or(false),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let out = std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output();
        match out {
            Ok(o) => {
                let s = String::from_utf8_lossy(&o.stdout);
                let s = s.trim();
                !s.is_empty() && !s.starts_with('Z')
            }
            Err(_) => false,
        }
    }
}

/// 3a: a grandchild that KEEPS the leader's stdout must not hold the run open.
/// The leader exited 0 at once; that is the answer, promptly, not the deadline.
#[tokio::test]
async fn a_grandchild_holding_stdout_does_not_turn_success_into_a_timeout() {
    let deadline = Duration::from_secs(10);
    let t0 = Instant::now();
    let out = Command::new(["sh", "-c", "sleep 30 & echo started; exit 0"])
        .group(true)
        .timeout(deadline)
        .run()
        .await
        .expect("spawn");
    assert_eq!(
        out.completion,
        Completion::Exited(0),
        "the leader's exit, not a timeout"
    );
    assert_eq!(
        out.stdout_lossy(),
        "started\n",
        "the leader's output survives the group reap"
    );
    assert!(
        t0.elapsed() < Duration::from_secs(3),
        "returned promptly: {:?}",
        t0.elapsed()
    );
}

/// 3b: a grandchild that DETACHES its stdio must not survive the run.
#[tokio::test]
async fn a_detached_grandchild_does_not_outlive_the_run() {
    let out = Command::new([
        "sh",
        "-c",
        "sleep 30 >/dev/null 2>&1 </dev/null & echo $!; exit 0",
    ])
    .group(true)
    .timeout(Duration::from_secs(10))
    .run()
    .await
    .expect("spawn");
    assert_eq!(out.completion, Completion::Exited(0));
    let pid: i32 = out
        .stdout_lossy()
        .trim()
        .parse()
        .expect("the grandchild's pid");
    // The run has returned: the group was reaped before it did.
    std::thread::sleep(Duration::from_millis(50));
    assert!(!alive(pid), "grandchild {pid} survived the run");
}

/// Control: the leader's own non-zero exit is still what is reported after the
/// group reap, and a run with no descendants is unaffected.
#[tokio::test]
async fn the_leaders_status_is_reported_after_the_reap() {
    let out = Command::new(["sh", "-c", "sleep 30 & exit 3"])
        .group(true)
        .timeout(Duration::from_secs(10))
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.completion, Completion::Exited(3));
    let out = Command::new(["sh", "-c", "echo plain"])
        .group(true)
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.completion, Completion::Exited(0));
    assert_eq!(out.stdout_lossy(), "plain\n");
}
