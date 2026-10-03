//! ORDER 1443-8pur — THE AGENT DOOR: `tillandsias-plan run … -- <argv…>`.
//!
//! One child, run through tillandsias-exec, AFTER the command-policy engine
//! (1443-isrk) has decided on its argv. The agent-facing shape of the verb
//! 1375-amye also files: whichever lands first, the other adds its arms here;
//! there is no second spawn path.
//!
//! NAMED PARAMETERS ARE FLAGS (--cwd, --env, --timeout-ms, --capture-bytes,
//! --stdin-file). There is no positional command string and no --shell: argv is
//! argv, so there is nothing for a shell, MSYS or wsl.exe to re-quote.
//!
//! The child's environment is the same base proc.run gives a Lua caller
//! (PROC_RUN_BASE_ENV_PASSTHROUGH, TILLANDSIAS_*, PROC_RUN_BASE_ENV_FIXED) plus
//! the caller's --env additions; nothing else is inherited, so a token the
//! caller happens to export does not reach the child.
//!
//! Every decision is audited (1443-w9hf): a refusal with no run_id, a spawn
//! with the executor's run identity.

use crate::command_policy as cp;
use crate::lua_predicate::{
    PROC_RUN_BASE_ENV_FIXED, PROC_RUN_BASE_ENV_PASSTHROUGH, PROC_RUN_DEFAULT_TIMEOUT_MS,
};
use std::path::PathBuf;

/// One request through the door.
#[derive(Debug, Clone)]
pub struct RunSpec {
    pub argv: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    /// Milliseconds; 0 means no deadline. Default PROC_RUN_DEFAULT_TIMEOUT_MS.
    pub timeout_ms: u64,
    /// Per-fd capture cap; None keeps the executor's default.
    pub capture_bytes: Option<usize>,
    pub stdin: Option<Vec<u8>>,
    /// Run the child as a process-group leader so a deadline kills its tree.
    pub group: bool,
    /// Return after starting a detached session instead of waiting for exit.
    pub detach: bool,
    /// Optional append-only log for a detached child's stdout and stderr.
    pub log: Option<PathBuf>,
    /// Advisory whole-file lock held while the child runs.
    pub lock: Option<PathBuf>,
    /// Optional bound on acquiring `lock`; None waits indefinitely.
    pub lock_wait_ms: Option<u64>,
}

impl RunSpec {
    pub fn new(argv: Vec<String>) -> Self {
        RunSpec {
            argv,
            cwd: None,
            env: Vec::new(),
            timeout_ms: PROC_RUN_DEFAULT_TIMEOUT_MS,
            capture_bytes: None,
            stdin: None,
            group: true,
            detach: false,
            log: None,
            lock: None,
            lock_wait_ms: None,
        }
    }
}

/// What happened.
#[derive(Debug)]
pub enum RunOutcome {
    /// The policy refused (deny) or requires consent; no child was spawned.
    Refused(cp::Decision),
    /// The program could not be started.
    SpawnFailed { error: String, wall_ms: u64 },
    /// It started, but its status could not be collected (a wait or drain
    /// failure). THE FIRST-CLASS ABSENT: no code is invented for it
    /// (macbookair, under 1260-2qgi: a substituted integer is the defect).
    NoStatus { reason: String, wall_ms: u64 },
    /// A detached child was started; its independent lifetime is now OS-owned.
    Detached {
        run_id: String,
        wall_ms: u64,
        rule_id: String,
    },
    /// The bounded advisory-lock wait elapsed before spawning.
    LockTimedOut { path: PathBuf, wall_ms: u64 },
    /// The advisory lock could not be opened or acquired for an I/O reason.
    LockFailed { error: String, wall_ms: u64 },
    /// The child ran; its completion, output and identity.
    Ran {
        output: tillandsias_exec::Output,
        wall_ms: u64,
        rule_id: String,
    },
}

/// A status the verb produced by killing the child ITSELF (the deadline, the
/// group reap) comes from the verb's own knowledge — tillandsias-exec builds
/// `TimedOut` without reading the child's status — never from its exit code.
/// A child killed from OUTSIDE on Windows is the named limit below: an MSYS
/// `kill -KILL` reaches the native parent as an exit code (signal N as N<<8,
/// 2304 for SIGKILL), and decoding it would misread a program that exits 2304
/// on purpose, so it is reported as `exited` and the regime is declared
/// (1260-2qgi; coordinator ruling 2026-09-28; spec command-runtime).
pub const WINDOWS_EXTERNAL_KILL_LIMIT: &str = "limit:windows-external-kill-reads-as-exited";

/// Parse the CLI duration grammar: a positive-or-zero integer followed by
/// `ms` or `s`. Checked arithmetic rejects values that cannot fit milliseconds.
pub fn parse_duration_ms(value: &str) -> Option<u64> {
    let (digits, multiplier) = if let Some(n) = value.strip_suffix("ms") {
        (n, 1u64)
    } else {
        let n = value.strip_suffix('s')?;
        (n, 1_000u64)
    };
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse::<u64>().ok()?.checked_mul(multiplier)
}

/// The child's environment: the proc.run base set plus the caller's additions.
pub fn base_env(additions: &[(String, String)]) -> Vec<(String, String)> {
    let mut env = Vec::new();
    for key in PROC_RUN_BASE_ENV_PASSTHROUGH {
        if let Ok(v) = std::env::var(key) {
            env.push((key.to_string(), v));
        }
    }
    for (k, v) in std::env::vars() {
        if k.starts_with("TILLANDSIAS_") {
            env.push((k, v));
        }
    }
    for (k, v) in PROC_RUN_BASE_ENV_FIXED {
        env.push((k.to_string(), v.to_string()));
    }
    env.extend(additions.iter().cloned());
    env
}

/// The `--json` result (slice 2): exactly one object with the keys run_id,
/// status, code, signal, ok, stdout, stderr, truncated, wall_ms, argv, policy
/// (signal added by coordinator ruling 2026-09-28: `code` is an integer only
/// for exited, `signal` only for signaled; null otherwise) — and the
/// verb's exit code. THE VERB EXITS 0 WHENEVER IT REPORTED what happened to a
/// child (any code, a signal, a deadline, a spawn failure); it exits 1 only for
/// a policy refusal and 4 for a consent requirement, and a usage error is 2. So
/// "the policy refused", "the child failed" and "this binary could not answer"
/// are three different things to a caller, which the plain form cannot promise
/// (a refusal and a child's own exit 1 share a code there).
///
/// status: exited | signaled | timed_out | spawn_failed | no_status | policy_denied |
/// policy_consent. ok is true only for exited with code 0 and nothing clipped.
/// policy: {decision, rule_id, why, remedy}. argv is echoed through redact().
pub fn outcome_json(spec: &RunSpec, outcome: &RunOutcome) -> (serde_json::Value, i32) {
    use serde_json::{Value, json};
    let argv: Vec<String> = spec.argv.iter().map(|a| cp::redact(a)).collect();
    let policy = |decision: &str, d_rule: &str, why: Option<&str>, remedy: Option<&str>| json!({"decision": decision, "rule_id": d_rule, "why": why, "remedy": remedy});
    match outcome {
        RunOutcome::Refused(d) => {
            let (status, decision) = match d.strictness {
                cp::Strictness::Consent => ("policy_consent", "consent"),
                _ => ("policy_denied", "deny"),
            };
            (
                json!({
                    "run_id": Value::Null,
                    "status": status,
                    "code": Value::Null,
                    "signal": Value::Null,
                    "ok": false,
                    "stdout": "",
                    "stderr": "",
                    "truncated": false,
                    "wall_ms": 0,
                    "argv": argv,
                    "policy": policy(decision, &d.rule_id, d.why.as_deref(), d.remedy.as_deref()),
                }),
                d.exit_code(),
            )
        }
        RunOutcome::SpawnFailed { error, wall_ms } => (
            json!({
                "run_id": Value::Null,
                "status": "spawn_failed",
                "code": Value::Null,
                "signal": Value::Null,
                "ok": false,
                "stdout": "",
                "stderr": cp::redact(error),
                "truncated": false,
                "wall_ms": wall_ms,
                "argv": argv,
                "policy": policy("allow", "default", None, None),
            }),
            0,
        ),
        RunOutcome::NoStatus { reason, wall_ms } => (
            json!({
                "run_id": Value::Null,
                "status": "no_status",
                "code": Value::Null,
                "signal": Value::Null,
                "ok": false,
                "stdout": "",
                "stderr": cp::redact(reason),
                "truncated": false,
                "wall_ms": wall_ms,
                "argv": argv,
                "policy": policy("allow", "default", None, None),
            }),
            0,
        ),
        RunOutcome::Detached {
            run_id,
            wall_ms,
            rule_id,
        } => (
            json!({
                "run_id": run_id,
                "status": "detached",
                "code": Value::Null,
                "signal": Value::Null,
                "ok": true,
                "stdout": "",
                "stderr": "",
                "truncated": false,
                "wall_ms": wall_ms,
                "argv": argv,
                "policy": policy("allow", rule_id, None, None),
            }),
            0,
        ),
        RunOutcome::LockTimedOut { path, wall_ms } => (
            json!({
                "run_id": Value::Null,
                "status": "lock_timed_out",
                "code": Value::Null,
                "signal": Value::Null,
                "ok": false,
                "stdout": "",
                "stderr": cp::redact(&format!("lock wait expired: {}", path.display())),
                "truncated": false,
                "wall_ms": wall_ms,
                "argv": argv,
                "policy": policy("allow", "default", None, None),
            }),
            75,
        ),
        RunOutcome::LockFailed { error, wall_ms } => (
            json!({
                "run_id": Value::Null,
                "status": "lock_failed",
                "code": Value::Null,
                "signal": Value::Null,
                "ok": false,
                "stdout": "",
                "stderr": cp::redact(error),
                "truncated": false,
                "wall_ms": wall_ms,
                "argv": argv,
                "policy": policy("allow", "default", None, None),
            }),
            125,
        ),
        RunOutcome::Ran {
            output,
            wall_ms,
            rule_id,
        } => {
            // code is an integer ONLY for exited; signal ONLY for signaled.
            let (status, code, signal) = match output.completion {
                tillandsias_exec::Completion::Exited(c) => ("exited", json!(c), Value::Null),
                tillandsias_exec::Completion::Signaled(s) => ("signaled", Value::Null, json!(s)),
                tillandsias_exec::Completion::TimedOut { .. } => {
                    ("timed_out", Value::Null, Value::Null)
                }
            };
            (
                json!({
                    "run_id": output.run.as_str(),
                    "status": status,
                    "code": code,
                    "signal": signal,
                    "ok": output.completion.is_success() && !output.truncated,
                    "stdout": String::from_utf8_lossy(&output.stdout),
                    "stderr": String::from_utf8_lossy(&output.stderr),
                    "truncated": output.truncated,
                    "wall_ms": wall_ms,
                    "argv": argv,
                    "policy": policy("allow", rule_id, None, None),
                }),
                0,
            )
        }
    }
}

/// Decide, then (only on allow) spawn. `caller` names the door in the audit.
pub fn execute(spec: &RunSpec, caller: &str) -> RunOutcome {
    let cwd = spec
        .cwd
        .clone()
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    let root = crate::branch_discipline::find_root(&cwd).unwrap_or_else(|| cwd.clone());
    let protected = cp::protected_refs(&root);
    let (seed, load) = cp::load_seed(&root, None, &protected);
    let regime = std::env::var("TILLANDSIAS_POLICY_REGIME")
        .ok()
        .filter(|r| cp::REGIMES.contains(&r.as_str()))
        .unwrap_or_else(|| "interactive".to_string());
    let req = cp::Request {
        argv: spec.argv.clone(),
        cwd: cwd.clone(),
        workspace: root.clone(),
        host_kind: cp::read_host_kind(&root).kind,
        regime,
        caller: caller.to_string(),
    };
    // Honor refused loads before resolving consent. Audit once below when the
    // run identity (if any) is known. Only this execution path may spend a token.
    let d = cp::decide_execution(
        &req,
        seed.as_ref(),
        &load,
        &protected,
        &cp::ConsentCtx::from_env(&root),
    );
    if d.strictness != cp::Strictness::Allow {
        cp::audit_decision(&req, &d, None);
        return RunOutcome::Refused(d);
    }

    if spec.detach && spec.lock.is_some() {
        cp::audit_decision(&req, &d, None);
        return RunOutcome::LockFailed {
            error: "--detach cannot be combined with --lock: the caller cannot own a detached child's lock lifetime".into(),
            wall_ms: 0,
        };
    }

    let lock_started = std::time::Instant::now();
    let _lock_file = if let Some(path) = &spec.lock {
        use fs2::FileExt;
        let file = match std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
        {
            Ok(file) => file,
            Err(e) => {
                cp::audit_decision(&req, &d, None);
                return RunOutcome::LockFailed {
                    error: format!("lock {}: {e}", path.display()),
                    wall_ms: lock_started.elapsed().as_millis() as u64,
                };
            }
        };
        loop {
            match file.try_lock_exclusive() {
                Ok(()) => break Some(file),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if spec.lock_wait_ms.is_some_and(|limit| {
                        lock_started.elapsed() >= std::time::Duration::from_millis(limit)
                    }) {
                        cp::audit_decision(&req, &d, None);
                        return RunOutcome::LockTimedOut {
                            path: path.clone(),
                            wall_ms: lock_started.elapsed().as_millis() as u64,
                        };
                    }
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(e) => {
                    cp::audit_decision(&req, &d, None);
                    return RunOutcome::LockFailed {
                        error: format!("lock {}: {e}", path.display()),
                        wall_ms: lock_started.elapsed().as_millis() as u64,
                    };
                }
            }
        }
    } else {
        None
    };

    let mut cmd = tillandsias_exec::Command::new(spec.argv.clone())
        .env_clear()
        .current_dir(cwd)
        .group(spec.group);
    for (k, v) in base_env(&spec.env) {
        cmd = cmd.env(k, v);
    }
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            cp::audit_decision(&req, &d, None);
            return RunOutcome::SpawnFailed {
                error: format!("runtime: {e}"),
                wall_ms: 0,
            };
        }
    };
    if spec.detach {
        let t0 = std::time::Instant::now();
        let result = rt.block_on(cmd.spawn_detached(spec.log.clone()));
        let wall_ms = t0.elapsed().as_millis() as u64;
        rt.shutdown_background();
        match result {
            Ok(run) => {
                cp::audit_decision(&req, &d, Some(run.as_str()));
                return RunOutcome::Detached {
                    run_id: run.to_string(),
                    wall_ms,
                    rule_id: d.rule_id,
                };
            }
            Err(e @ tillandsias_exec::ExecError::Spawn { .. }) => {
                cp::audit_decision(&req, &d, None);
                return RunOutcome::SpawnFailed {
                    error: e.to_string(),
                    wall_ms,
                };
            }
            Err(e) => {
                cp::audit_decision(&req, &d, None);
                return RunOutcome::NoStatus {
                    reason: e.to_string(),
                    wall_ms,
                };
            }
        }
    }
    if let Some(bytes) = &spec.stdin {
        cmd = cmd.stdin_bytes(bytes.clone());
    }
    if spec.timeout_ms > 0 {
        cmd = cmd.timeout(std::time::Duration::from_millis(spec.timeout_ms));
    }
    if let Some(n) = spec.capture_bytes {
        cmd = cmd.capture_bytes(n);
    }

    let t0 = std::time::Instant::now();
    let result = rt.block_on(cmd.run());
    let wall_ms = t0.elapsed().as_millis() as u64;
    // Not an implicit drop: dropping the runtime waits for blocking pipe
    // readers a killed child's surviving descendants still hold (see proc.run).
    rt.shutdown_background();
    match result {
        Ok(output) => {
            cp::audit_decision(&req, &d, Some(output.run.as_str()));
            RunOutcome::Ran {
                output,
                wall_ms,
                rule_id: d.rule_id,
            }
        }
        Err(e @ tillandsias_exec::ExecError::Spawn { .. }) => {
            cp::audit_decision(&req, &d, None);
            RunOutcome::SpawnFailed {
                error: e.to_string(),
                wall_ms,
            }
        }
        Err(e) => {
            cp::audit_decision(&req, &d, None);
            RunOutcome::NoStatus {
                reason: e.to_string(),
                wall_ms,
            }
        }
    }
}

#[cfg(test)]
mod duration_tests {
    use super::parse_duration_ms;

    #[test]
    fn duration_parser_accepts_seconds_and_milliseconds_without_rounding() {
        assert_eq!(parse_duration_ms("1s"), Some(1_000));
        assert_eq!(parse_duration_ms("250ms"), Some(250));
        assert_eq!(parse_duration_ms("0s"), Some(0));
    }

    #[test]
    fn duration_parser_rejects_ambiguous_or_overflowing_values() {
        for invalid in [
            "",
            "1",
            "1m",
            "-1s",
            ".5s",
            "1.5s",
            " 1s",
            "18446744073709552s",
        ] {
            assert_eq!(parse_duration_ms(invalid), None, "{invalid:?}");
        }
    }
}
