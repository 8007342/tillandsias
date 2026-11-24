// @trace order:2294-dtch, spec:command-runtime
//
// `Command::detach(true)`: a grouped run whose leader EXITS (normally, or by a
// signal from outside) does NOT reap the leader's process group, so a
// descendant left behind is still there for the caller to see. A DEADLINE
// still kills the whole group, and a scope close or `kill()` still does
// (2294-dtch).
//
// WHY. Every grouped run reaped its group the moment the leader exited, and
// the Lua runtime runs every proc.run and proc.spawn grouped. A fixture that
// asks "did the subject leave anything behind?" therefore always heard "no":
// the runner had already killed whatever the subject leaked. Measured on
// darwin 2026-11-24: test-fleet-run arm 10 stayed green against a fleet-run
// mutant that leaks its step's child, and a .sh→.lua port of
// test-macos-vz-orphan-diagnosis read ok:4 on a helper that outlives a
// SIGKILLed tray, a mutant the .sh reds.
//
// PRE-FIX: these tests do not compile (no `detach`). With `detach` accepted
// and ignored, the two "survives" tests FAIL: the grandchild is reaped.
#![cfg(unix)]

use std::time::{Duration, Instant};
use tillandsias_exec::{Command, Completion};

fn alive(pid: i32) -> bool {
    #[cfg(target_os = "linux")]
    {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Err(_) => false,
            Ok(s) => s
                .rsplit(')')
                .next()
                .map(|r| !r.trim_start().starts_with('Z'))
                .unwrap_or(false),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        match std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
        {
            Ok(o) => {
                let s = String::from_utf8_lossy(&o.stdout);
                let s = s.trim();
                !s.is_empty() && !s.starts_with('Z')
            }
            Err(_) => false,
        }
    }
}

fn kill9(pid: i32) {
    let _ = std::process::Command::new("kill")
        .args(["-9", &pid.to_string()])
        .status();
}

const LEAK: &str = "sleep 30 >/dev/null 2>&1 </dev/null & echo $!; exit 0";

fn grandchild(out: &tillandsias_exec::Output) -> i32 {
    out.stdout_lossy()
        .trim()
        .parse()
        .expect("the grandchild's pid")
}

/// Wait up to 2 s for `pid` to go, since a reap is TERM then KILL.
fn gone_within(pid: i32) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_secs(2) {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

// ── the managed scope (what the Lua runtime's proc.run and proc.spawn use) ──

#[test]
fn managed_detached_run_leaves_a_leaked_grandchild_for_the_caller_to_see() {
    use tillandsias_exec::managed::Scope;
    let (scope, _events) = Scope::new(None);
    let out = scope
        .run(
            Command::new(["sh", "-c", LEAK])
                .group(true)
                .detach(true)
                .timeout(Duration::from_secs(10)),
        )
        .expect("run");
    assert_eq!(out.completion, Completion::Exited(0));
    let pid = grandchild(&out);
    std::thread::sleep(Duration::from_millis(300));
    let survived = alive(pid);
    kill9(pid);
    assert!(
        survived,
        "detach=true: grandchild {pid} was reaped when the leader exited"
    );
}

#[test]
fn managed_control_without_detach_still_reaps_the_grandchild() {
    use tillandsias_exec::managed::Scope;
    let (scope, _events) = Scope::new(None);
    let out = scope
        .run(
            Command::new(["sh", "-c", LEAK])
                .group(true)
                .timeout(Duration::from_secs(10)),
        )
        .expect("run");
    let pid = grandchild(&out);
    let reaped = gone_within(pid);
    if !reaped {
        kill9(pid);
    }
    assert!(
        reaped,
        "control: without detach the group reap must still end {pid}"
    );
}

#[test]
fn managed_detached_run_is_still_killed_whole_by_its_deadline() {
    use tillandsias_exec::managed::Scope;
    let (scope, _events) = Scope::new(None);
    // The leader writes the grandchild's pid to a file, then outlives the deadline.
    let dir = std::env::temp_dir().join(format!("dtch-deadline-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let pidf = dir.join("gc.pid");
    let script = format!(
        "sleep 30 >/dev/null 2>&1 </dev/null & echo $! > '{}'; sleep 30",
        pidf.display()
    );
    let out = scope
        .run(
            Command::new(["sh", "-c", &script])
                .group(true)
                .detach(true)
                .timeout(Duration::from_millis(800)),
        )
        .expect("run");
    assert!(
        matches!(out.completion, Completion::TimedOut { .. }),
        "{:?}",
        out.completion
    );
    let pid: i32 = std::fs::read_to_string(&pidf)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let killed = gone_within(pid);
    if !killed {
        kill9(pid);
    }
    assert!(
        killed,
        "detach must not exempt a run from its deadline: {pid} survived it"
    );
}

#[test]
fn managed_detach_without_a_group_is_refused() {
    use tillandsias_exec::managed::Scope;
    let (scope, _events) = Scope::new(None);
    let r = scope.run(Command::new(["true"]).group(false).detach(true));
    assert!(
        r.is_err(),
        "detach names a group it does not reap; with no group it means nothing"
    );
}

// ── the direct Command::run path ──

#[tokio::test]
async fn direct_detached_run_leaves_a_leaked_grandchild_for_the_caller_to_see() {
    let out = Command::new(["sh", "-c", LEAK])
        .group(true)
        .detach(true)
        .timeout(Duration::from_secs(10))
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.completion, Completion::Exited(0));
    let pid = grandchild(&out);
    std::thread::sleep(Duration::from_millis(300));
    let survived = alive(pid);
    kill9(pid);
    assert!(
        survived,
        "detach=true: grandchild {pid} was reaped when the leader exited"
    );
}
