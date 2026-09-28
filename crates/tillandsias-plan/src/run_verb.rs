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
    /// The child ran; its completion, output and identity.
    Ran {
        output: tillandsias_exec::Output,
        wall_ms: u64,
        rule_id: String,
    },
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

/// Decide, then (only on allow) spawn. `caller` names the door in the audit.
pub fn execute(spec: &RunSpec, caller: &str) -> RunOutcome {
    let cwd = spec
        .cwd
        .clone()
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    let root = crate::branch_discipline::find_root(&cwd).unwrap_or_else(|| cwd.clone());
    let protected = cp::protected_refs(&root);
    let (seed, _) = cp::load_seed(&root, None, &protected);
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
    // decide() is side-effect free; the audit line is written once, below,
    // when the run identity (if any) is known.
    let d = cp::decide(&req, seed.as_ref(), &protected);
    if d.strictness != cp::Strictness::Allow {
        cp::audit_decision(&req, &d, None);
        return RunOutcome::Refused(d);
    }

    let mut cmd = tillandsias_exec::Command::new(spec.argv.clone())
        .env_clear()
        .current_dir(cwd)
        .group(spec.group);
    for (k, v) in base_env(&spec.env) {
        cmd = cmd.env(k, v);
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
        Err(e) => {
            cp::audit_decision(&req, &d, None);
            RunOutcome::SpawnFailed {
                error: e.to_string(),
                wall_ms,
            }
        }
    }
}
