// @trace order:1252-fg9e, spec:ci-release
//
// The remaining verbs: stdin, pipeline composition, and spawn/reap.

use std::time::Duration;
use tillandsias_exec::{Command, Completion, Pipeline};

/// stdin is fed and the child sees it. The `echo X | cmd` replacement.
#[tokio::test]
async fn stdin_bytes_reach_the_child() {
    let out = Command::new(["cat"])
        .stdin_bytes("hello from stdin")
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.stdout_lossy(), "hello from stdin");
    assert!(out.completion.is_success());
}

/// THE THREE-FD DEADLOCK, and the ORDER OF THE CHILD'S OWN WORK IS THE TEST.
///
/// The child must WRITE BEFORE IT READS. That is what makes the deadlock
/// reachable: the parent is blocked writing 1 MiB of stdin (the child is not
/// reading yet) while the child is blocked writing 1 MiB of stdout (the parent
/// is not reading yet). Neither moves.
///
/// MEASURED, because the first version of this test got it wrong: with
/// `cat >/dev/null` FIRST the child drains stdin before emitting anything, and
/// a deliberately mutated executor that sequenced the stdin write ahead of the
/// reads still PASSED — the test was exercising nothing. Writing first is the
/// whole fixture. Verified by mutation: sequencing the write before the reads
/// makes this hang.
#[tokio::test]
async fn stdin_and_both_outputs_do_not_deadlock() {
    let payload = vec![b'x'; 1_048_576];
    let script = "yes ABCDEFGHIJ | head -c 1048576; \
                  yes ABCDEFGHIJ | head -c 1048576 1>&2; \
                  cat >/dev/null";
    let out = Command::new(["sh", "-c", script])
        .stdin_bytes(payload)
        .timeout(Duration::from_secs(60))
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.stdout.len(), 1_048_576);
    assert_eq!(out.stderr.len(), 1_048_576);
}

/// A child that exits WITHOUT consuming stdin is not an error of ours. `head -1`
/// legitimately does this and the resulting EPIPE must not surface as a failure.
#[tokio::test]
async fn a_child_that_ignores_stdin_is_not_an_error() {
    let out = Command::new(["sh", "-c", "exit 0"])
        .stdin_bytes(vec![b'y'; 1_048_576])
        .timeout(Duration::from_secs(30))
        .run()
        .await
        .expect("a broken pipe on stdin is not a spawn failure");
    assert!(out.completion.is_success());
}

/// Pipeline composition: stage N's stdout feeds stage N+1's stdin.
#[tokio::test]
async fn pipeline_feeds_each_stage() {
    let p = Pipeline::new(Command::new(["printf", "beta\nalpha\ngamma\n"]))
        .pipe_to(Command::new(["sort"]))
        .pipe_to(Command::new(["head", "-n", "1"]));
    let out = p.run().await.expect("spawn");
    assert_eq!(out.last().stdout_lossy(), "alpha\n");
    assert!(out.all_succeeded());
    assert_eq!(out.stages.len(), 3);
}

/// EVERY STAGE'S STATUS AND STDERR SURVIVE — the thing `a | b` cannot do. A
/// shell pipeline discards the first stage's status entirely without pipefail,
/// and gives one bit with it.
#[tokio::test]
async fn a_failing_early_stage_is_visible_and_named() {
    let p = Pipeline::new(Command::new([
        "sh",
        "-c",
        "printf partial; printf 'stage one broke' 1>&2; exit 3",
    ]))
    .pipe_to(Command::new(["cat"]));
    let out = p.run().await.expect("spawn");

    assert!(!out.all_succeeded());
    let failed = out.first_failure().expect("the first stage failed");
    assert_eq!(failed.completion, Completion::Exited(3));
    assert_eq!(failed.stderr_lossy(), "stage one broke");
    // The downstream stage still ran and saw what the first stage did emit.
    assert_eq!(out.last().stdout_lossy(), "partial");
}

/// spawn() returns a handle; try_completion() reports the THIRD state — still
/// running — rather than collapsing it into a falsy "not successful".
#[tokio::test]
async fn spawn_reports_still_running_then_reaps() {
    let mut running = Command::new(["sleep", "5"]).spawn().await.expect("spawn");
    assert!(
        running.try_completion().expect("try_wait").is_none(),
        "a running child must report None, not a completion"
    );
    let id = running.run_id().clone();
    let completion = running.kill().await.expect("kill");
    assert!(!completion.is_success());
    assert!(!id.as_str().is_empty());
}

/// A spawned child carries its own identity, distinct from any other run.
#[tokio::test]
async fn spawned_children_have_distinct_identities() {
    let a = Command::new(["true"]).spawn().await.expect("spawn");
    let b = Command::new(["true"]).spawn().await.expect("spawn");
    assert_ne!(a.run_id(), b.run_id());
    a.wait().await.expect("wait");
    b.wait().await.expect("wait");
}
