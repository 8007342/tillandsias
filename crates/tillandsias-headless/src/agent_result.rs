//! Outcome parsing for delegated forge agent runs (order 429).
//!
//! Both agent CLIs can emit a JSONL transcript when
//! `TILLANDSIAS_AGENT_RESULT_FORMAT=json` is set (see the forge entrypoints):
//!
//!   * Codex `codex exec --json` emits `thread.started`, `turn.*`,
//!     `item.completed` with a nested `item`, and `error`.
//!   * OpenCode `opencode run --format json` emits events whose payload lives
//!     under `part` (`part.text` and `part.reason`) plus nested error data.
//!
//! # The one invariant that matters
//!
//! **Success must be POSITIVELY EVIDENCED. Absence of evidence is never
//! success.**
//!
//! A dispatcher that treats "no failure seen" as "it worked" is worse than no
//! dispatcher, because it silently marks abandoned, truncated, killed and
//! crashed runs as done. That is the defect class this repository keeps
//! rediscovering: the relay reconcile that logged "Mirror is now up to date"
//! while updating zero refs; a freshness gate that reported PASS against a
//! container that never started; a permission flag that did not exist; a
//! credential written where the tool never reads. Each *worked*, *reported
//! success*, and *was not doing the thing*.
//!
//! So this parser returns [`AgentOutcome::Indeterminate`] for anything it
//! cannot affirmatively classify — empty input, a truncated stream, a stream
//! with no terminal event — and callers MUST treat that as "do not assume the
//! work happened".

use serde_json::Value;

/// What a delegated run actually did, as far as its transcript can prove.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentOutcome {
    /// A terminal success event was observed. `last_message` is the final
    /// assistant text when the transcript carried one.
    Succeeded { last_message: Option<String> },
    /// A terminal failure or error event was observed.
    Failed { reason: String },
    /// The run exceeded its deadline. Only the caller can know this; the
    /// transcript alone cannot distinguish "slow" from "stopped".
    TimedOut { after_secs: u64 },
    /// The transcript does not prove either outcome. NOT a success.
    Indeterminate { reason: String },
}

impl AgentOutcome {
    /// True only for an affirmatively evidenced success. Deliberately not a
    /// `matches!(.., Succeeded | Indeterminate)` convenience — an
    /// indeterminate run must never read as done.
    pub fn is_success(&self) -> bool {
        matches!(self, AgentOutcome::Succeeded { .. })
    }

    /// One-line operator-facing summary.
    pub fn summary(&self) -> String {
        match self {
            AgentOutcome::Succeeded { last_message } => match last_message {
                Some(m) if !m.trim().is_empty() => {
                    format!("succeeded: {}", truncate(m.trim(), 160))
                }
                _ => "succeeded".to_string(),
            },
            AgentOutcome::Failed { reason } => format!("FAILED: {}", truncate(reason, 240)),
            AgentOutcome::TimedOut { after_secs } => {
                format!("TIMED OUT after {after_secs}s")
            }
            AgentOutcome::Indeterminate { reason } => {
                format!("INDETERMINATE (do not assume the work happened): {reason}")
            }
        }
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let head: String = s.chars().take(max).collect();
    format!("{head}…")
}

/// Parse a JSONL transcript from either agent CLI.
///
/// Non-JSON lines are skipped rather than fatal: both CLIs interleave human
/// log output with the event stream, and a stray banner must not mask a real
/// terminal event. But skipped noise never *contributes* to a success verdict.
pub fn parse_transcript(transcript: &str) -> AgentOutcome {
    let mut saw_any_event = false;
    let mut saw_start = false;
    let mut last_text: Option<String> = None;
    let mut saw_terminal_success = false;
    let mut failure_reason: Option<String> = None;

    for line in transcript.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue; // interleaved non-JSON log output
        };
        let Some(kind) = v.get("type").and_then(Value::as_str) else {
            continue;
        };
        saw_any_event = true;

        match kind {
            // ---- codex ----
            "thread.started" | "turn.started" => saw_start = true,
            "turn.completed" => {
                saw_terminal_success = true;
            }
            "turn.failed" => {
                failure_reason.get_or_insert_with(|| {
                    extract_reason(&v).unwrap_or_else(|| "turn.failed".to_string())
                });
            }
            "error" => {
                failure_reason.get_or_insert_with(|| {
                    extract_reason(&v).unwrap_or_else(|| "error event".to_string())
                });
            }
            "item.completed" => {
                if let Some(item) = v.get("item")
                    && item.get("type").and_then(Value::as_str) == Some("agent_message")
                    && let Some(text) = item.get("text").and_then(Value::as_str)
                    && !text.trim().is_empty()
                {
                    last_text = Some(text.to_string());
                }
            }

            // ---- opencode ----
            "step_start" => saw_start = true,
            "step_finish" => {
                // OpenCode may emit an intermediate `tool-calls` finish before
                // continuing with another step. Only an explicit `stop` is a
                // terminal success. Missing and unknown reasons remain
                // non-terminal so a truncated stream cannot manufacture done.
                if v.pointer("/part/reason").and_then(Value::as_str) == Some("stop") {
                    saw_terminal_success = true;
                }
            }
            "text" => {
                if let Some(t) = v.pointer("/part/text").and_then(Value::as_str)
                    && !t.trim().is_empty()
                {
                    last_text = Some(t.to_string());
                }
            }

            _ => {}
        }
    }

    // Failure is sticky. A later finish event cannot erase an earlier error.
    if let Some(reason) = failure_reason {
        return AgentOutcome::Failed { reason };
    }
    if saw_terminal_success {
        return AgentOutcome::Succeeded {
            last_message: last_text,
        };
    }

    // No terminal event. Everything below is explicitly NOT success.
    if !saw_any_event {
        AgentOutcome::Indeterminate {
            reason: "transcript contained no recognisable agent events".to_string(),
        }
    } else if saw_start {
        AgentOutcome::Indeterminate {
            reason: "run started but never reported a terminal event (truncated, killed, or still running)"
                .to_string(),
        }
    } else {
        AgentOutcome::Indeterminate {
            reason: "events present but neither a start nor a terminal event was seen".to_string(),
        }
    }
}

/// Combine a transcript verdict with the process exit status.
///
/// The exit code is authoritative for FAILURE: a non-zero exit means the run
/// failed even if the transcript looked fine (the process may have died after
/// its last event). But a zero exit is NOT sufficient for success — the
/// transcript must still evidence it, because a CLI can exit 0 after doing
/// nothing at all.
pub fn classify_run(transcript: &str, exit_code: Option<i32>) -> AgentOutcome {
    let parsed = parse_transcript(transcript);
    match exit_code {
        Some(0) => parsed,
        Some(code) => AgentOutcome::Failed {
            reason: match parsed {
                AgentOutcome::Failed { reason } => {
                    format!("exit {code}; {reason}")
                }
                other => format!("exit {code} (transcript said: {})", other.summary()),
            },
        },
        None => AgentOutcome::Indeterminate {
            reason: format!(
                "no exit status available; transcript said: {}",
                parsed.summary()
            ),
        },
    }
}

/// Combine a transcript with a real child-process status.
///
/// A status without an exit code means signal/forced termination and is a
/// failure, not the "status unavailable" case represented by
/// `classify_run(_, None)`.
pub fn classify_exit_status(transcript: &str, status: &std::process::ExitStatus) -> AgentOutcome {
    if status.success() {
        classify_run(transcript, Some(0))
    } else if let Some(code) = status.code() {
        classify_run(transcript, Some(code))
    } else {
        AgentOutcome::Failed {
            reason: format!(
                "process terminated without an exit code (transcript said: {})",
                parse_transcript(transcript).summary()
            ),
        }
    }
}

/// Classify a bounded current-run capture.
///
/// Capture overflow can never be success, but it also cannot hide a real
/// nonzero/signal failure.
pub fn classify_captured_run(
    transcript: &str,
    status: &std::process::ExitStatus,
    stdout_truncated: bool,
) -> AgentOutcome {
    if !status.success() {
        classify_exit_status(transcript, status)
    } else if stdout_truncated {
        AgentOutcome::Indeterminate {
            reason: "captured agent transcript exceeded its bounded host-memory limit".to_string(),
        }
    } else {
        classify_exit_status(transcript, status)
    }
}

fn extract_reason(v: &Value) -> Option<String> {
    for pointer in ["/error/data/message", "/data/message"] {
        if let Some(s) = v.pointer(pointer).and_then(Value::as_str)
            && !s.trim().is_empty()
        {
            return Some(s.to_string());
        }
    }
    for key in ["error", "message", "reason", "detail"] {
        match v.get(key) {
            Some(Value::String(s)) if !s.trim().is_empty() => return Some(s.clone()),
            Some(Value::Object(o)) => {
                if let Some(Value::String(s)) = o.get("message")
                    && !s.trim().is_empty()
                {
                    return Some(s.clone());
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn test_exit_status(code: i32) -> std::process::ExitStatus {
        use std::os::unix::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(code << 8)
    }

    #[cfg(windows)]
    fn test_exit_status(code: i32) -> std::process::ExitStatus {
        use std::os::windows::process::ExitStatusExt;
        std::process::ExitStatus::from_raw(code as u32)
    }

    // ---------------------------------------------------------------
    // The load-bearing tests: nothing ambiguous may read as success.
    // ---------------------------------------------------------------

    #[test]
    fn empty_transcript_is_indeterminate_not_success() {
        let o = parse_transcript("");
        assert!(!o.is_success(), "empty transcript must never be a success");
        assert!(matches!(o, AgentOutcome::Indeterminate { .. }));
    }

    #[test]
    fn whitespace_and_noise_only_is_indeterminate() {
        for input in [
            "   \n\n  ",
            "starting up...\nsome banner text\n",
            "{not json}\n[]\n",
        ] {
            let o = parse_transcript(input);
            assert!(
                !o.is_success(),
                "non-event input must never be a success: {input:?}"
            );
        }
    }

    #[test]
    fn started_but_truncated_is_indeterminate_not_success() {
        let t = r#"{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"not terminal"}}"#;
        let o = parse_transcript(t);
        assert!(
            !o.is_success(),
            "a truncated run must not be reported as success"
        );
        match o {
            AgentOutcome::Indeterminate { reason } => {
                assert!(reason.contains("terminal"), "unhelpful reason: {reason}")
            }
            other => panic!("expected Indeterminate, got {other:?}"),
        }
    }

    #[test]
    fn zero_exit_alone_does_not_manufacture_success() {
        // A CLI can exit 0 having done nothing. Exit status is authoritative
        // for failure, never sufficient for success.
        let o = classify_run("", Some(0));
        assert!(
            !o.is_success(),
            "exit 0 with an empty transcript must not be success"
        );
    }

    #[test]
    fn nonzero_exit_overrides_a_success_looking_transcript() {
        let t = r#"{"type":"thread.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"all done"}}
{"type":"turn.completed"}"#;
        assert!(parse_transcript(t).is_success());
        let o = classify_run(t, Some(37));
        assert!(!o.is_success(), "non-zero exit must dominate");
        match o {
            AgentOutcome::Failed { reason } => assert!(reason.contains("37"), "{reason}"),
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn missing_exit_status_is_indeterminate() {
        let t = r#"{"type":"turn.completed"}"#;
        let o = classify_run(t, None);
        assert!(!o.is_success());
    }

    // ---------------------------------------------------------------
    // Positive classification
    // ---------------------------------------------------------------

    #[test]
    fn delegated_result_codex_nested_agent_message_is_returned() {
        let t = r#"{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"first"}}
{"type":"item.completed","item":{"type":"agent_message","text":"final answer"}}
{"type":"turn.completed"}"#;
        match parse_transcript(t) {
            AgentOutcome::Succeeded { last_message } => {
                assert_eq!(last_message.as_deref(), Some("final answer"));
            }
            other => panic!("expected Succeeded, got {other:?}"),
        }
    }

    #[test]
    fn codex_turn_failed_is_failure_with_reason() {
        let t = r#"{"type":"thread.started"}
{"type":"turn.failed","error":{"message":"model refused"}}"#;
        match parse_transcript(t) {
            AgentOutcome::Failed { reason } => {
                assert!(reason.contains("model refused"), "{reason}")
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn codex_error_event_is_failure() {
        let t = r#"{"type":"thread.started"}
{"type":"error","message":"stream disconnected"}"#;
        match parse_transcript(t) {
            AgentOutcome::Failed { reason } => {
                assert!(reason.contains("stream disconnected"), "{reason}")
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }

    #[test]
    fn delegated_result_opencode_tool_calls_only_is_indeterminate() {
        let t = r#"{"type":"step_start","sessionID":"s1"}
{"type":"text","sessionID":"s1","part":{"text":"calling a tool"}}
{"type":"step_finish","sessionID":"s1","part":{"reason":"tool-calls"}}"#;
        assert!(matches!(
            parse_transcript(t),
            AgentOutcome::Indeterminate { .. }
        ));
    }

    #[test]
    fn delegated_result_opencode_tool_calls_then_stop_succeeds() {
        let t = r#"{"type":"step_start","sessionID":"s1"}
{"type":"text","sessionID":"s1","part":{"text":"calling a tool"}}
{"type":"step_finish","sessionID":"s1","part":{"reason":"tool-calls"}}
{"type":"step_start","sessionID":"s1"}
{"type":"text","sessionID":"s1","part":{"text":"did the thing"}}
{"type":"step_finish","sessionID":"s1","part":{"reason":"stop"}}"#;
        match parse_transcript(t) {
            AgentOutcome::Succeeded { last_message } => {
                assert_eq!(last_message.as_deref(), Some("did the thing"));
            }
            other => panic!("expected Succeeded, got {other:?}"),
        }
    }

    #[test]
    fn interleaved_log_noise_does_not_break_classification() {
        let t = r#"loading config...
{"type":"thread.started"}
warning: cache miss
{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}
not json at all
{"type":"turn.completed"}
done."#;
        assert!(parse_transcript(t).is_success());
    }

    #[test]
    fn delegated_result_opencode_error_then_finish_is_sticky_failure() {
        let t = r#"{"type":"step_start","sessionID":"s1"}
{"type":"error","sessionID":"s1","error":{"name":"UnknownError","data":{"message":"tool blew up"}}}
{"type":"step_finish","sessionID":"s1","part":{"reason":"stop"}}"#;
        match parse_transcript(t) {
            AgentOutcome::Failed { reason } => assert!(reason.contains("tool blew up"), "{reason}"),
            other => panic!("expected sticky Failed, got {other:?}"),
        }
    }

    #[test]
    fn delegated_result_unknown_or_missing_opencode_reason_is_not_terminal() {
        for finish in [
            r#"{"type":"step_finish","sessionID":"s1","part":{}}"#,
            r#"{"type":"step_finish","sessionID":"s1","part":{"reason":"length"}}"#,
        ] {
            assert!(matches!(
                parse_transcript(finish),
                AgentOutcome::Indeterminate { .. }
            ));
        }
    }

    #[test]
    fn delegated_result_capture_overflow_never_succeeds_or_hides_nonzero() {
        assert!(matches!(
            classify_captured_run(r#"{"type":"turn.completed"}"#, &test_exit_status(0), true),
            AgentOutcome::Indeterminate { .. }
        ));
        match classify_captured_run(r#"{"type":"turn.completed"}"#, &test_exit_status(37), true) {
            AgentOutcome::Failed { reason } => assert!(reason.contains("37"), "{reason}"),
            other => panic!("overflow + exit 37 must remain Failed, got {other:?}"),
        }
    }

    #[test]
    fn a_failure_anywhere_beats_an_earlier_success_event() {
        let t = r#"{"type":"turn.completed"}
{"type":"error","message":"post-run crash"}"#;
        assert!(matches!(parse_transcript(t), AgentOutcome::Failed { .. }));
    }

    #[test]
    fn timeout_is_never_success_and_reports_the_deadline() {
        let o = AgentOutcome::TimedOut { after_secs: 900 };
        assert!(!o.is_success());
        assert!(o.summary().contains("900"));
    }

    #[test]
    fn summaries_flag_non_success_loudly() {
        assert!(
            AgentOutcome::Indeterminate { reason: "x".into() }
                .summary()
                .contains("do not assume")
        );
        assert!(
            AgentOutcome::Failed { reason: "y".into() }
                .summary()
                .contains("FAILED")
        );
    }
}
