// @trace order:1443-8pur, spec:command-runtime
//
// Slice 1b of 1443-8pur, measured on darwin by macbookair and POSIX everywhere:
// in a GROUP run, nothing the child starts outlives the run, and the LEADER's
// status is what is reported. PRE-FIX (397c5f3ff) both arms FAIL: 3a reports
// TimedOut after the full deadline; 3b's grandchild is still alive.
#![cfg(unix)]

use std::time::{Duration, Instant};
use tillandsias_exec::{Command, Completion};

/// What a liveness probe saw.
#[derive(Debug, PartialEq, Eq)]
enum Liveness {
    Alive,
    Zombie,
    Gone,
    Unobservable(String),
}

/// Is `pid` still a live process? `ps` is the state reader used off Linux.
///
/// ORDER 1558-ixih. Existence from kill(pid, 0): ESRCH is the only Gone, and
/// success or EPERM means the pid exists. The state then separates a zombie
/// from a live process. A reader that fails, or a spawn of `ps` that fails, is
/// Unobservable, NOT dead: the previous probe mapped `Err(_)` to "not alive".
///
/// KEEP IN STEP WITH `liveness` in tillandsias-plan tests/lua_proc.rs
/// (1543-f44v). It is a local copy because the two live in different crates'
/// test trees, and the two must agree on what counts as dead.
fn liveness_with(pid: i32, ps: &str) -> Liveness {
    fn exists(pid: i32) -> Result<bool, String> {
        // SAFETY: kill with signal 0 sends nothing and takes no pointers.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return Ok(true);
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::ESRCH) => Ok(false),
            Some(libc::EPERM) => Ok(true),
            other => Err(format!("kill({pid}, 0) failed: errno {other:?}")),
        }
    }
    match exists(pid) {
        Ok(false) => return Liveness::Gone,
        Err(why) => return Liveness::Unobservable(why),
        Ok(true) => {}
    }
    #[cfg(target_os = "linux")]
    let state = {
        let _ = ps;
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .map_err(|e| format!("/proc/{pid}/stat: {e}"))
            // state is the field after the parenthesised comm
            .map(|s| s.rsplit(')').next().unwrap_or("").trim_start().to_string())
    };
    #[cfg(not(target_os = "linux"))]
    let state = std::process::Command::new(ps)
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .map_err(|e| format!("{ps} -p {pid}: {e}"))
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    match state {
        Ok(s) if s.starts_with('Z') => Liveness::Zombie,
        Ok(s) if !s.is_empty() => Liveness::Alive,
        // Exists by kill(0) but no state: it may have died in between.
        _ if exists(pid) == Ok(false) => Liveness::Gone,
        Ok(_) => Liveness::Unobservable(format!("pid {pid} exists but reported no state")),
        Err(why) => Liveness::Unobservable(why),
    }
}

fn liveness(pid: i32) -> Liveness {
    liveness_with(pid, "ps")
}

/// ORDER 1558-ixih. The probe must see a process that is certainly alive, and
/// must see its death once it is reaped.
#[test]
fn liveness_sees_a_known_live_process_and_its_death() {
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;
    let seen = liveness(pid);
    child.kill().expect("kill the scratch sleep");
    child.wait().expect("reap the scratch sleep");
    assert_eq!(
        seen,
        Liveness::Alive,
        "a live scratch process {pid} was not seen alive"
    );
    assert_eq!(
        liveness(pid),
        Liveness::Gone,
        "a reaped scratch process {pid} was not seen gone"
    );
}

/// ORDER 1558-ixih. A FAILED OBSERVATION IS NOT DEATH. With a state reader that
/// cannot even be spawned, a live process must come back Unobservable (or
/// Alive), never Gone: "the grandchild did not survive" must not be the
/// probe's blindness.
#[test]
fn a_failed_observation_of_a_live_process_is_not_reported_dead() {
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;
    let seen = liveness_with(pid, "/nonexistent/ps-1558-ixih");
    child.kill().expect("kill the scratch sleep");
    child.wait().expect("reap the scratch sleep");
    assert_ne!(
        seen,
        Liveness::Gone,
        "a live process {pid} was reported dead because its state could not be read"
    );
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
    match liveness(pid) {
        Liveness::Gone | Liveness::Zombie => {}
        Liveness::Alive => panic!("grandchild {pid} survived the run"),
        Liveness::Unobservable(why) => panic!("could not observe grandchild {pid}: {why}"),
    }
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
