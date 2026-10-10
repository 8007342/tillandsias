// @trace order:1252-fg9e, spec:ci-release
//
// The verifiable closure of 1252-fg9e, one test per exit criterion. Each names
// the PRE-FIX result the packet recorded, so a reader can tell what changed.

use std::time::Duration;
use tillandsias_exec::{Command, Completion};

// @trace order:1534-puyz
#[tokio::test]
async fn managed_stream_is_live_ordered_byte_exact_and_capture_bounded() {
    use tillandsias_exec::managed::{Event, Scope};
    let (scope, mut events) = Scope::new(Some(std::time::Instant::now() + Duration::from_secs(10)));
    let process = scope.spawn(Command::new(["sh", "-c", "i=0; while [ $i -lt 10000 ]; do printf '%s\\r\\n' $i; printf 'E%s\\r\\n' $i >&2; i=$((i+1)); done; printf last"])
        .group(true).capture_bytes(17), true).unwrap();
    let (mut stdout, mut stderr) = (0, 0);
    let mut final_line = false;
    loop {
        match tokio::time::timeout(Duration::from_secs(10), events.recv())
            .await
            .unwrap()
            .unwrap()
        {
            Event::Line {
                process: id,
                fd,
                bytes,
            } => {
                assert_eq!(id, process.id);
                if fd == "stdout" {
                    if stdout == 10000 {
                        assert_eq!(bytes, b"last");
                        final_line = true;
                    } else {
                        assert_eq!(bytes, format!("{stdout}\r").as_bytes());
                        stdout += 1;
                    }
                } else {
                    assert_eq!(bytes, format!("E{stderr}\r").as_bytes());
                    stderr += 1;
                }
            }
            Event::Finished(id) => {
                assert_eq!(id, process.id);
                break;
            }
        }
    }
    assert_eq!((stdout, stderr, final_line), (10000, 10000, true));
    let out = loop {
        if let Some(result) = process.result() {
            break result.unwrap();
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    };
    assert_eq!(out.stdout, b"0\r\n1\r\n2\r\n3\r\n4\r\n5\r");
    assert_eq!(out.stderr.len(), 17);
    assert!(out.truncated && out.dropped > 0 && out.completion.is_success());
    scope.cleanup().unwrap();
}

// Cancellation must not require the consumer to free a full delivery queue.
#[test]
fn managed_cancel_reaps_when_delivery_or_stdin_is_blocked() {
    use tillandsias_exec::managed::Scope;
    for stdin in [false, true] {
        let (scope, _events) = Scope::new(None);
        let mut command = Command::new(["sh", "-c", "while :; do printf 'x\\n'; done"]).group(true);
        if stdin {
            command = command.stdin_bytes(vec![0; 1024 * 1024]);
        }
        let process = scope.spawn(command, true).unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let t0 = std::time::Instant::now();
        scope.cleanup().unwrap();
        assert!(t0.elapsed() < Duration::from_secs(2));
        assert!(process.result().is_some());
        assert!(scope.spawn(Command::new(["true"]), false).is_err());
    }
}

#[tokio::test]
async fn managed_unterminated_line_has_an_explicit_bound() {
    use tillandsias_exec::managed::{MAX_LINE_BYTES, Scope};
    let (scope, mut events) = Scope::new(None);
    let process = scope
        .spawn(
            Command::new(["sh", "-c", "head -c 1048577 /dev/zero"]).group(true),
            true,
        )
        .unwrap();
    assert!(matches!(
        events.recv().await,
        Some(tillandsias_exec::managed::Event::Finished(_))
    ));
    let failure = loop {
        if let Some(result) = process.result() {
            break result.unwrap_err();
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    };
    assert_eq!(MAX_LINE_BYTES, 1048576);
    assert!(failure.contains("proc-line-too-long"), "{failure}");
    scope.cleanup().unwrap();
}

#[test]
fn managed_launch_close_race_keeps_every_accepted_child_owned() {
    use tillandsias_exec::managed::Scope;
    let mut accepted = 0;
    for i in 0..20 {
        let (scope, _events) = Scope::new(None);
        let worker_scope = scope.clone();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let worker_barrier = barrier.clone();
        let worker = std::thread::spawn(move || {
            worker_barrier.wait();
            worker_scope.spawn(Command::new(["sleep", "30"]).group(true), false)
        });
        barrier.wait();
        if i % 2 == 0 {
            std::thread::sleep(Duration::from_millis(10));
        }
        scope.cleanup().unwrap();
        if let Ok(process) = worker.join().unwrap() {
            accepted += 1;
            // An accepted launch may finish setup after close, but it is already
            // registered and must be reaped before cleanup reports success.
            assert!(process.result().is_some());
        }
        assert!(scope.spawn(Command::new(["true"]), false).is_err());
    }
    assert!(
        accepted > 0,
        "positive control: at least one child actually launched"
    );
}

/// CRITERION 1. stdout and stderr are SEPARATE values, and stderr survives when
/// a caller reads only stdout.
/// PRE-FIX: FAILS — run-litmus-test.sh redirects every step `2>&1`, so no
/// litmus step can distinguish them; "only stdout" silently means both.
#[tokio::test]
async fn stderr_survives_when_only_stdout_is_read() {
    let out = Command::new(["sh", "-c", "printf OUT; printf ERR 1>&2"])
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.stdout_lossy(), "OUT");
    assert_eq!(out.stderr_lossy(), "ERR");
    // The point of the criterion: consuming stdout does not consume or
    // interleave stderr.
    assert!(!out.stdout_contains("ERR"), "streams must not interleave");
}

/// CRITERION 2. 1 MiB on stdout AND 1 MiB on stderr completes and returns both
/// in full.
/// PRE-FIX: FAILS — a sequential single-fd read deadlocks at the ~64 KiB pipe
/// buffer. If concurrent draining ever regresses, this test does not fail, it
/// HANGS, which is the honest symptom.
#[tokio::test]
async fn dual_stream_megabyte_each_completes() {
    let script = "yes ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123 \
                  | head -c 1048576; \
                  yes ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123 \
                  | head -c 1048576 1>&2";
    let out = Command::new(["sh", "-c", script])
        .timeout(Duration::from_secs(60))
        .run()
        .await
        .expect("spawn");
    assert_eq!(out.stdout.len(), 1_048_576, "stdout truncated");
    assert_eq!(out.stderr.len(), 1_048_576, "stderr truncated");
    assert!(out.completion.is_success());
}

/// CRITERION 3. The SIGPIPE inversion is UNCONSTRUCTIBLE here.
///
/// The packet's reproducer returns rc=141 and NO-MATCH 5/5 through a shell
/// pipeline under pipefail, over a 200,000-line input whose FIRST line matches:
/// grep -q exits on the first hit, SIGPIPEs the producer, and pipefail reports
/// the pipeline as FAILED — i.e. "no match" while the string is present 200,000
/// times. This asserts BOTH halves on the same input: the shell pipeline still
/// inverts, and the executor is correct 5/5.
#[tokio::test]
async fn sigpipe_inversion_does_not_occur_through_the_executor() {
    const GEN: &str = "for i in $(seq 1 200000); do echo NEEDLE-line-$i; done";

    // The shell shape, reproduced so the test proves the hazard is real here
    // and not merely described. `|| true` keeps the harness from dying on the
    // inversion we are demonstrating.
    let mut shell_wrong = 0;
    for _ in 0..5 {
        let probe = format!("set -o pipefail; {{ {GEN}; }} | grep -q NEEDLE; echo rc=$?");
        let out = Command::new(["sh", "-c", &probe])
            .run()
            .await
            .expect("spawn");
        if !out.stdout_contains("rc=0") {
            shell_wrong += 1;
        }
    }

    // The executor: capture, then match in Rust. No OS pipe between stages, so
    // there is no early-exiting consumer and nothing to SIGPIPE.
    let mut exec_right = 0;
    for _ in 0..5 {
        let out = Command::new(["sh", "-c", GEN])
            .timeout(Duration::from_secs(120))
            .run()
            .await
            .expect("spawn");
        if out.completion.is_success() && out.stdout_contains("NEEDLE") {
            exec_right += 1;
        }
    }

    assert_eq!(exec_right, 5, "the executor must be correct 5/5");
    // Documented rather than asserted as 5: the inversion is input-size
    // dependent, and on a fast host the producer can finish first. If this
    // prints 0 the hazard did not reproduce HERE, which does not make the
    // executor's 5/5 less true.
    eprintln!("shell pipeline inverted on {shell_wrong}/5 trials");
}

/// THE INVERSION CASE, pinned the other way round (ruling 2026-09-28 on
/// 1252-fg9e: the closure proves the FIX, not the bug). A producer that DIES
/// OF SIGPIPE keeps its OWN status, separate from its consumer's, so the kill
/// can never read as a fresh result. Through the executor producer and
/// consumer are separate runs with separate `Completion`s and run identities;
/// the producer's `Signaled(13)` survives next to the consumer's `Exited(0)`.
///
/// The control is the shell pipeline, where both facts share ONE exit status:
/// without pipefail the producer's SIGPIPE disappears into the consumer's 0;
/// with pipefail it becomes 141 and the consumer's MATCH disappears. Either
/// way one number carries two facts and one is lost, which is exactly what
/// separate capture prevents.
#[tokio::test]
async fn a_sigpipe_killed_producer_keeps_its_own_status() {
    const SIGPIPE: i32 = 13;
    let producer = Command::new(["sh", "-c", "echo NEEDLE; kill -PIPE $$"])
        .run()
        .await
        .expect("spawn producer");
    let consumer = Command::new(["grep", "-q", "NEEDLE"])
        .stdin_bytes(producer.stdout.clone())
        .run()
        .await
        .expect("spawn consumer");

    // Signals are a Unix contract (1553-5x9x). On native Windows there is no
    // SIGPIPE: the MSYS `sh` reports its own signal death as an EXIT code,
    // measured Exited(3328) = 13 << 8 on yolanda-windows 2026-10-08. What
    // still holds there is that the producer keeps its OWN status. The
    // executor deliberately does NOT decode 3328 back into Signaled(13): a
    // native Windows program can exit 3328 on its own, and decoding would
    // invent a signal it never received.
    #[cfg(unix)]
    assert_eq!(
        producer.completion,
        Completion::Signaled(SIGPIPE),
        "the producer's SIGPIPE death is its own, reported as a signal"
    );
    #[cfg(windows)]
    assert_eq!(
        producer.completion,
        Completion::Exited(SIGPIPE << 8),
        "the producer's MSYS signal-exit code is its own, kept unrelabelled"
    );
    assert!(
        !producer.completion.is_success(),
        "a killed producer is never a success"
    );
    assert_eq!(
        consumer.completion,
        Completion::Exited(0),
        "the consumer found the match"
    );
    assert_ne!(producer.run, consumer.run, "two runs, two identities");

    // CONTROL: the same two programs as one shell pipeline yield ONE status.
    let fused = |pipefail: bool| {
        let opt = if pipefail { "set -o pipefail; " } else { "" };
        format!("{opt}sh -c 'echo NEEDLE; kill -PIPE $$' | grep -q NEEDLE; echo rc=$?")
    };
    let plain = Command::new(["sh", "-c", &fused(false)])
        .run()
        .await
        .expect("spawn");
    let strict = Command::new(["sh", "-c", &fused(true)])
        .run()
        .await
        .expect("spawn");
    assert!(
        plain.stdout_contains("rc=0"),
        "without pipefail the producer's kill is invisible: {}",
        String::from_utf8_lossy(&plain.stdout)
    );
    assert!(
        strict.stdout_contains("rc=141"),
        "with pipefail the match is invisible: {}",
        String::from_utf8_lossy(&strict.stdout)
    );
}

/// CRITERION 4. argv only — a literal containing a space, a quote and a glob
/// reaches the child as ONE unaltered argument.
/// PRE-FIX: FAILS — no such API exists; every call site builds a shell string.
/// There is deliberately no `Command::shell(&str)` for this test to guard.
#[tokio::test]
async fn one_argv_entry_arrives_unaltered() {
    let hostile = r#"a b "c" *.rs $HOME `id` 'q'"#;
    let out = Command::new(["printf", "%s", hostile])
        .run()
        .await
        .expect("spawn");
    assert_eq!(
        out.stdout_lossy(),
        hostile,
        "argv must not be split, globbed, or expanded"
    );
}

/// CRITERION 5. Every Result carries an identity distinct per invocation.
#[tokio::test]
async fn two_runs_have_distinct_run_identities() {
    let a = Command::new(["true"]).run().await.expect("spawn");
    let b = Command::new(["true"]).run().await.expect("spawn");
    assert_ne!(a.run, b.run, "a stale artifact must not read as fresh");
    assert!(!a.run.as_str().is_empty());
}

/// CRITERION 6. A timeout fires on a child that IGNORES SIGTERM, and the Result
/// says the run was KILLED rather than reporting an exit status it never made.
#[tokio::test]
async fn timeout_on_a_sigterm_ignoring_child_reports_killed() {
    // `trap '' TERM` makes SIGTERM a no-op, so a polite terminate would hang.
    let out = Command::new(["sh", "-c", "trap '' TERM; sleep 120"])
        .timeout(Duration::from_millis(400))
        .run()
        .await
        .expect("spawn");
    match out.completion {
        Completion::TimedOut { .. } => {}
        other => panic!("expected TimedOut, got {other:?} — an invented exit status"),
    }
    assert!(!out.completion.is_success());
}

/// A TIMEOUT ENDS THE WHOLE RUN, not only the call (1553-6e3q). The child is a
/// shell whose grandchild (`sleep`) holds the stdout pipe. On native Windows the
/// pipe reader is a blocking thread, and killing only the shell left the
/// grandchild holding the pipe: run() returned at ~430 ms, but dropping the
/// runtime waited for the reader until the grandchild exited on its own.
/// MEASURED pre-fix on yolanda-windows: the criterion-6 test above took 120.09 s
/// against a 400 ms deadline. The runtime is built and dropped HERE so the
/// bound covers its shutdown; a #[tokio::test] drops it after the measurement.
/// The drop finishing is the proof that no live process still holds the pipe.
#[test]
fn a_timeout_does_not_leave_the_pipe_held_past_the_run() {
    let started = std::time::Instant::now();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");
    let out = rt.block_on(
        Command::new(["sh", "-c", "trap '' TERM; sleep 60"])
            .timeout(Duration::from_millis(400))
            .run(),
    );
    drop(rt);
    let whole = started.elapsed();
    let out = out.expect("spawn");
    assert!(
        matches!(out.completion, Completion::TimedOut { .. }),
        "expected TimedOut, got {:?}",
        out.completion
    );
    assert!(
        whole < Duration::from_secs(15),
        "a 400 ms timeout held the run for {whole:?}: the grandchild kept the pipe"
    );
}

/// An empty argv is refused rather than guessed at.
#[tokio::test]
async fn empty_argv_is_refused() {
    let err = Command::new(Vec::<String>::new()).run().await.unwrap_err();
    assert!(matches!(err, tillandsias_exec::ExecError::EmptyArgv));
}
