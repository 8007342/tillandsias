//! Headless one-shot of a non-Claude agent lane on a `--cloud` project
//! (order 1847-5xv3).
//!
//! `tillandsias --cloud <owner/repo> --opencode` with no terminal on stdin is a
//! one-shot: the forge runs the agent, the agent exits, the lane exits and the
//! forge is removed. That last part is REUSED, not built here: measured on
//! lenovinha 2026-10-24 (v56.10.20.1, 67 s, exit 0, `podman ps -a` afterwards
//! held no forge, git or lane container; progress event on 1847-5xv3).
//!
//! New here:
//!   - a run with no `--prompt` gets [`DEFAULT_QUEUE_PROMPT`], so a forge
//!     started for queued work reads its queue instead of opening a TUI
//!     nobody is watching;
//!   - a wall-clock backstop ([`arm_timeout`]): past the budget the forge is
//!     torn down, `failed:timeout` is printed and reported, and the launcher
//!     exits [`TIMEOUT_EXIT`]. Removing the forge ends the attached lane, so
//!     the launcher's own return path (Vault credential cleanup included)
//!     still runs and checks [`timed_out`]; the backstop exits the process
//!     itself only if that path has not finished [`GRACE`] later;
//!   - the report goes through [`QueueClient`]. The coordinator client (1826)
//!     has not landed, so the only implementation is [`NoQueue`], which posts
//!     nothing.
//!
//! A Claude lane is never a one-shot here: the dogfood this serves must not
//! fall back to Claude silently.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

static TIMED_OUT: AtomicBool = AtomicBool::new(false);

/// How long the launcher's own return path gets after the forge is removed.
pub(crate) const GRACE: Duration = Duration::from_secs(60);

/// Whether the backstop fired in this process.
pub(crate) fn timed_out() -> bool {
    TIMED_OUT.load(Ordering::SeqCst)
}

/// The prompt a headless one-shot runs when none was given.
pub(crate) const DEFAULT_QUEUE_PROMPT: &str = "Read your queue messages and complete \
what they ask. If there are none, print the single line idle:no-queued-work and exit.";

/// Overrides the wall-clock budget, in whole minutes.
pub(crate) const MAX_MINUTES_ENV: &str = "TILLANDSIAS_ONE_SHOT_MAX_MINUTES";

/// The default budget: the queued-task payload's `max_minutes` default (1847).
pub(crate) const DEFAULT_MAX_MINUTES: u64 = 90;

/// The launcher's exit status when the backstop fired (`timeout(1)`'s).
pub(crate) const TIMEOUT_EXIT: i32 = 124;

/// Whether this launch is a headless one-shot: a cloud project, a non-Claude
/// agent lane, and no terminal to talk to.
pub(crate) fn is_one_shot(is_cloud: bool, non_claude_lane: bool, stdin_is_tty: bool) -> bool {
    is_cloud && non_claude_lane && !stdin_is_tty
}

/// The prompt the lane runs: the caller's, else the queue default for a
/// one-shot, else none (an interactive start is unchanged).
pub(crate) fn effective_prompt(prompt: Option<String>, one_shot: bool) -> Option<String> {
    match prompt {
        Some(p) if !p.trim().is_empty() => Some(p),
        _ if one_shot => Some(DEFAULT_QUEUE_PROMPT.to_string()),
        other => other,
    }
}

/// The budget from [`MAX_MINUTES_ENV`]'s value; unset, empty, zero or
/// unparsable falls back to [`DEFAULT_MAX_MINUTES`].
pub(crate) fn budget(raw: Option<&str>) -> Duration {
    let minutes = raw
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|m| *m > 0)
        .unwrap_or(DEFAULT_MAX_MINUTES);
    Duration::from_secs(minutes * 60)
}

/// How a one-shot ended, as the queue is told.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    Failed(String),
}

impl Outcome {
    pub(crate) fn line(&self) -> String {
        match self {
            Outcome::Failed(why) => format!("failed:{why}"),
        }
    }
}

/// Where a one-shot reports its outcome. 1826's coordinator client
/// implements this when it lands; until then [`NoQueue`].
pub(crate) trait QueueClient: Send {
    fn report(&self, outcome: &Outcome);
}

/// No coordinator yet: report nothing.
pub(crate) struct NoQueue;

impl QueueClient for NoQueue {
    fn report(&self, _outcome: &Outcome) {}
}

/// What the backstop does when it fires, behind a seam so a test can watch
/// it without podman or a process exit.
pub(crate) trait Teardown: Send {
    fn remove_forge(&self, container: &str);
    fn exit(&self, code: i32);
}

/// Arm the wall-clock backstop for a one-shot whose forge is `container`.
/// The thread is detached: a lane that exits first ends the process, and the
/// backstop with it.
pub(crate) fn arm_timeout(
    after: Duration,
    grace: Duration,
    container: String,
    queue: Box<dyn QueueClient>,
    teardown: Box<dyn Teardown>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        std::thread::sleep(after);
        fire(&container, after, queue.as_ref(), teardown.as_ref());
        std::thread::sleep(grace);
        teardown.exit(TIMEOUT_EXIT);
    })
}

fn fire(container: &str, after: Duration, queue: &dyn QueueClient, teardown: &dyn Teardown) {
    TIMED_OUT.store(true, Ordering::SeqCst);
    eprintln!(
        "[tillandsias] one-shot passed its {} min budget ({MAX_MINUTES_ENV}); removing {container}",
        after.as_secs() / 60
    );
    teardown.remove_forge(container);
    let outcome = Outcome::Failed("timeout".into());
    queue.report(&outcome);
    println!("{}", outcome.line());
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn one_shot_needs_cloud_a_non_claude_lane_and_no_tty() {
        assert!(is_one_shot(true, true, false));
        assert!(
            !is_one_shot(false, true, false),
            "a host checkout is not a one-shot"
        );
        assert!(
            !is_one_shot(true, false, false),
            "a Claude lane is never a one-shot"
        );
        assert!(
            !is_one_shot(true, true, true),
            "a terminal means a person is there"
        );
    }

    #[test]
    fn a_one_shot_without_a_prompt_reads_its_queue() {
        let p = effective_prompt(None, true).unwrap();
        assert_eq!(p, DEFAULT_QUEUE_PROMPT);
        assert!(p.contains("queue") && p.contains("idle:no-queued-work"));
        assert_eq!(
            effective_prompt(Some("  ".into()), true).as_deref(),
            Some(DEFAULT_QUEUE_PROMPT)
        );
    }

    #[test]
    fn a_given_prompt_wins_and_an_interactive_start_is_unchanged() {
        assert_eq!(
            effective_prompt(Some("do x".into()), true).as_deref(),
            Some("do x")
        );
        assert_eq!(effective_prompt(None, false), None);
        assert_eq!(
            effective_prompt(Some("do x".into()), false).as_deref(),
            Some("do x")
        );
    }

    #[test]
    fn budget_defaults_to_ninety_minutes() {
        assert_eq!(budget(None), Duration::from_secs(90 * 60));
        assert_eq!(budget(Some("")), Duration::from_secs(90 * 60));
        assert_eq!(budget(Some("0")), Duration::from_secs(90 * 60));
        assert_eq!(budget(Some("soon")), Duration::from_secs(90 * 60));
        assert_eq!(budget(Some(" 5 ")), Duration::from_secs(5 * 60));
    }

    #[derive(Clone, Default)]
    struct Log(Arc<Mutex<Vec<String>>>);
    impl Log {
        fn push(&self, s: String) {
            self.0.lock().unwrap().push(s);
        }
        fn get(&self) -> Vec<String> {
            self.0.lock().unwrap().clone()
        }
    }
    impl QueueClient for Log {
        fn report(&self, outcome: &Outcome) {
            self.push(format!("report {}", outcome.line()));
        }
    }
    impl Teardown for Log {
        fn remove_forge(&self, container: &str) {
            self.push(format!("rm {container}"));
        }
        fn exit(&self, code: i32) {
            self.push(format!("exit {code}"));
        }
    }

    #[test]
    fn the_backstop_removes_the_forge_then_reports_failed_timeout_then_exits_124() {
        let log = Log::default();
        arm_timeout(
            Duration::from_millis(10),
            Duration::from_millis(10),
            "tillandsias-x-forge".into(),
            Box::new(log.clone()),
            Box::new(log.clone()),
        )
        .join()
        .unwrap();
        assert_eq!(
            log.get(),
            [
                "rm tillandsias-x-forge",
                "report failed:timeout",
                "exit 124"
            ]
        );
        assert!(
            timed_out(),
            "the launcher's return path must see the timeout"
        );
    }

    #[test]
    fn the_no_queue_client_posts_nothing() {
        NoQueue.report(&Outcome::Failed("timeout".into()));
    }
}
