// @trace order:1252-hsrz, order:1367-q9yc, spec:ci-release
//
// lua_predicate.rs — two predicate classes, and the cacheable one CANNOT REACH
// THE SHELL because the symbol is not in its environment.
//
// Pure shims (order 1367-q9yc) expose repo-rooted `fs.read` and `expect.*`
// assertions to both classes, enabling predicates to read repo files and
// assert values without invoking a shell or impure host tools.
//
// ── WHY THIS EXISTS AND WHAT IT IS NOT ──────────────────────────────────────
//
// OPERATOR DIRECTIVE 2026-09-18: an agent inside the forge has "no place to
// recompile their own binary when adding specs or work implementation". If
// predicates are Rust, a forge agent cannot validate a spec it just wrote. That
// makes the dynamic layer a RUNTIME REQUIREMENT, not a convenience.
//
// THIS DOES NOT REOPEN 920-pxg6. That audit pinned Lua to deterministic
// data-in/data-out work and deleted a PHANTOM sandbox claim from lua_runtime.rs.
// The division of labour survives intact: Lua DECLARES and DECIDES; Rust
// (1252-fg9e, tillandsias-exec) SPAWNS, owns fds, enforces timeouts and reaps.
// Nothing here moves fork/exec into Lua — `expert.shell` hands an argv vector to
// the Rust executor and gets a value back.
//
// ── CONTAINMENT: WHAT IT IS, AND WHAT IT IS NOT ─────────────────────────────
//
// CONTAINMENT IS: (1) a small audited verb set, enumerable at runtime via
// `expert.verbs()` and pinned by a test, and (2) the forge's existing container
// boundary.
//
// SELINUX IS NOT RELIED UPON AND MUST NOT BE CITED HERE. The SELinux policies in
// this project are PROSE — not enforced, not scoped, not required anywhere.
// Claiming SELinux containment would recreate precisely the phantom that
// 920-pxg6 deleted from lua_runtime.rs. If you are reading this looking for the
// guarantee, there isn't one beyond the two items above.
//
// PROVENANCE IS NOT SOLVED HERE, and this row does not close it. Today `lua/` is
// trusted code in the checkout. A forge agent authoring a predicate for
// uncommitted work moves the boundary from "code we shipped" to "code an agent
// just wrote". Bounding blast radius by the verb set is the mitigation this
// module delivers; SIGNING OR ATTESTING predicate provenance is a separate row
// and nothing here should be read as having addressed it.
//
// ── THE CACHE PURITY TRAP, WHICH IS WHY THERE ARE TWO CLASSES ───────────────
//
// The performance case wants cached predicate results. A cached result is sound
// only if the predicate is genuinely pure — and the moment a shell verb is in
// scope, predicates OBSERVE THE WORLD and are not. Cache those and you get stale
// verdicts indistinguishable from fresh ones: a green gate that ran nothing,
// which is the failure this whole programme exists to prevent.
//
// THE ENFORCEMENT IS STRUCTURAL, NOT DOCUMENTARY. A `Cacheable` predicate's
// environment simply DOES NOT CONTAIN `expert.shell`, so calling it raises
// "attempt to call a nil value" at call time. A documented rule drifts the first
// time someone is in a hurry; an absent symbol does not.
//
// `expert.now_ms` IS ALSO WITHHELD FROM THE CACHEABLE CLASS, and that is a
// finding rather than an inherited rule. The existing runtime exposes it to
// everything, and a clock read is an observation of the world exactly as a shell
// call is: a predicate that branches on `now_ms` and is then cached returns an
// answer computed at a time that has passed. The shell verb is the loud case;
// the clock is the quiet one, and a purity boundary that admits it is not a
// purity boundary.

use crate::lua_runtime::LuaError;
use mlua::prelude::*;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

// @trace order:1534-puyz
#[path = "lua_process.rs"]
pub(crate) mod script_process;

/// Which capabilities a predicate is given, and therefore whether its result may
/// be cached. The class is what the environment is built FROM, not a label
/// attached to it afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PredicateClass {
    /// Pure: no shell, no clock. Results MAY be cached.
    Cacheable,
    /// Observes the world: shell and clock available. Results are NEVER cached.
    Observing,
}

impl PredicateClass {
    /// The audited verb set for this class, sorted. `expert.verbs()` returns
    /// exactly this, and a test pins it — so WIDENING THE CAPABILITY SET IS A
    /// VISIBLE DIFF rather than an accident.
    pub fn verbs(self) -> &'static [&'static str] {
        match self {
            // log_info is present in the pure class deliberately: it writes to
            // stderr and cannot affect the value the predicate returns, so it is
            // observationally pure with respect to the result being cached.
            PredicateClass::Cacheable => &["log_info", "verbs"],
            PredicateClass::Observing => &["log_info", "now_ms", "shell", "verbs"],
        }
    }

    /// Whether a result from this class may be served from cache.
    pub fn is_cacheable(self) -> bool {
        matches!(self, PredicateClass::Cacheable)
    }
}

/// What `expert.shell{...}` returns to Lua, mirroring tillandsias_exec::Output.
/// Three SEPARATE values plus the run identity — a predicate can tell stdout
/// from stderr, and a stale artifact from a fresh one.
pub(crate) fn shell_result_to_lua(lua: &Lua, out: tillandsias_exec::Output) -> LuaResult<LuaTable> {
    let t = lua.create_table()?;
    t.set("stdout", String::from_utf8_lossy(&out.stdout).to_string())?;
    t.set("stderr", String::from_utf8_lossy(&out.stderr).to_string())?;
    t.set("run_id", out.run.as_str().to_string())?;
    t.set("truncated", out.truncated)?;
    t.set("dropped", out.dropped)?;
    match out.completion {
        tillandsias_exec::Completion::Exited(code) => {
            t.set("status", "exited")?;
            t.set("code", code)?;
            // Same rule as proc.run: a clipped capture is not ok (1443-esm5).
            t.set("ok", code == 0 && !out.truncated)?;
        }
        tillandsias_exec::Completion::Signaled(sig) => {
            t.set("status", "signaled")?;
            t.set("signal", sig)?;
            t.set("ok", false)?;
        }
        // A killed child produced NO exit status, so none is invented. A
        // predicate that wants to branch on "timed out" reads `status`, and
        // cannot mistake it for an ordinary non-zero exit.
        tillandsias_exec::Completion::TimedOut { after } => {
            t.set("status", "timed_out")?;
            t.set("after_ms", after.as_millis() as u64)?;
            t.set("ok", false)?;
        }
    }
    Ok(t)
}

/// Fields `proc.run{...}` accepts (design section 4.1). Anything else is a
/// programmer error and RAISES: `timeout` misspelt for `timeout_ms` must not
/// silently become "no deadline" (order 1384-aixy).
pub const PROC_RUN_FIELDS: &[&str] = &[
    "argv",
    "cwd",
    "env",
    "stdin",
    "timeout_ms",
    "group",
    "capture_bytes",
];

/// The default deadline, 300 s, per the design. `timeout_ms = 0` means NO
/// deadline and has to be written out.
pub const PROC_RUN_DEFAULT_TIMEOUT_MS: u64 = 300_000;

/// The environment a child starts from: NOTHING is inherited except this set,
/// plus the call's own `env` additions (design section 5.3). One constant, so
/// "which variables leak into a check" has one answer.
pub const PROC_RUN_BASE_ENV_PASSTHROUGH: &[&str] = &[
    "PATH",
    "HOME",
    "TMPDIR",
    // A Windows child without these cannot start many programs at all.
    "SystemRoot",
    "SYSTEMROOT",
    "SystemDrive",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
];

/// Fixed values every child gets, so a verdict cannot depend on the caller's
/// locale, timezone or a git credential prompt.
pub const PROC_RUN_BASE_ENV_FIXED: &[(&str, &str)] = &[
    ("LC_ALL", "C"),
    ("LANG", "C"),
    ("TZ", "UTC"),
    ("GIT_TERMINAL_PROMPT", "0"),
];

/// ORDER 1443-isrk: ask the command policy before spawning. `None` means the
/// request is allowed; `Some` carries the deny or consent decision, and the
/// caller must NOT spawn. The host kind comes from the host's own evidence
/// (never a flag), the regime from `TILLANDSIAS_POLICY_REGIME` (default
/// `interactive`), and the workspace is the repository root.
pub fn policy_gate(
    argv: &[String],
    cwd: Option<&Path>,
    caller: &str,
) -> Option<crate::command_policy::Decision> {
    use crate::command_policy as cp;
    let here = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let root = find_repo_root().unwrap_or_else(|_| here.clone());
    let protected = cp::protected_refs(&root);
    let (seed, load) = cp::load_seed(&root, None, &protected);
    let regime = std::env::var("TILLANDSIAS_POLICY_REGIME")
        .ok()
        .filter(|r| cp::REGIMES.contains(&r.as_str()))
        .unwrap_or_else(|| "interactive".to_string());
    let req = cp::Request {
        argv: argv.to_vec(),
        cwd: cwd.map(Path::to_path_buf).unwrap_or_else(|| root.clone()),
        workspace: root.clone(),
        host_kind: cp::read_host_kind(&root).kind,
        regime,
        caller: caller.to_string(),
    };
    let d = cp::decide_execution(
        &req,
        seed.as_ref(),
        &load,
        &protected,
        &cp::ConsentCtx::from_env(&root),
    );
    cp::audit_decision(&req, &d, None);
    (d.strictness != cp::Strictness::Allow).then_some(d)
}

/// `proc.run{argv=..., cwd, env, stdin, timeout_ms, group}` (order 1384-aixy,
/// design section 4.1): one process, run to completion, returned as a VALUE.
/// A non-zero exit, a signal and a timeout are all DATA; only programmer
/// errors raise. proc.run remains synchronous; the scoped script runner adds
/// async proc.spawn/line delivery (1534-puyz), not chain/select/all.
pub(crate) enum PreparedProc {
    Refused(LuaTable),
    Command {
        argv: Vec<String>,
        command: tillandsias_exec::Command,
    },
}

// @trace order:1534-puyz
// Validate the WHOLE call before the execution gate can consume consent.
pub(crate) fn prepare_proc(
    lua: &Lua,
    spec: LuaTable,
    caller: &str,
    managed_group: bool,
) -> LuaResult<PreparedProc> {
    let err = |m: String| mlua::Error::RuntimeError(format!("{caller}: {m}"));

    for pair in spec.clone().pairs::<LuaValue, LuaValue>() {
        let (k, _) = pair?;
        match k {
            LuaValue::String(s) => {
                let key = s.to_str()?.to_string();
                if !PROC_RUN_FIELDS.contains(&key.as_str()) {
                    return Err(err(format!(
                        "unknown field '{key}' (fields: {})",
                        PROC_RUN_FIELDS.join(", ")
                    )));
                }
            }
            _ => {
                return Err(err(
                    "positional values are not accepted; pass argv = {\"prog\", \"arg\", ...}"
                        .to_string(),
                ));
            }
        }
    }

    let argv_t: LuaTable = match spec.get::<LuaValue>("argv")? {
        LuaValue::Table(t) => t,
        LuaValue::Nil => return Err(err("argv is required".into())),
        _ => {
            return Err(err(
                "argv must be a table of strings, never a command string".into(),
            ));
        }
    };
    let mut argv: Vec<String> = Vec::new();
    for v in argv_t.clone().sequence_values::<LuaValue>() {
        match v? {
            LuaValue::String(s) => argv.push(s.to_str()?.to_string()),
            other => {
                return Err(err(format!(
                    "argv[{}] is a {}, not a string",
                    argv.len() + 1,
                    other.type_name()
                )));
            }
        }
    }
    if argv.is_empty() {
        return Err(err("argv is empty".into()));
    }
    if argv.iter().any(|arg| arg.contains('\0')) {
        return Err(err("argv strings must not contain NUL".into()));
    }
    if argv_t.pairs::<LuaValue, LuaValue>().count() != argv.len() {
        return Err(err(
            "argv must be a sequence with no holes and no named keys".into(),
        ));
    }
    // Snapshot cwd ONCE. Lua __index may return a different value on every
    // lookup; authorization must measure the exact cwd execution will use.
    let cwd_path: Option<PathBuf> = match spec.get::<LuaValue>("cwd")? {
        LuaValue::Nil => None,
        LuaValue::String(s) => {
            let p = PathBuf::from(s.to_str()?.to_string());
            if s.as_bytes().contains(&0) {
                return Err(err("cwd must not contain NUL".into()));
            }
            if !p.is_absolute() {
                return Err(err(format!(
                    "cwd '{}' is relative; pass an absolute path",
                    p.display()
                )));
            }
            Some(p)
        }
        other => {
            return Err(err(format!(
                "cwd must be a string, not a {}",
                other.type_name()
            )));
        }
    };
    let mut cmd = tillandsias_exec::Command::new(argv.clone()).env_clear();
    for key in PROC_RUN_BASE_ENV_PASSTHROUGH {
        if let Some(v) = std::env::var_os(key) {
            cmd = cmd.env(key, v);
        }
    }
    for (k, v) in std::env::vars_os() {
        if k.to_string_lossy().starts_with("TILLANDSIAS_") {
            cmd = cmd.env(k, v);
        }
    }
    for (k, v) in PROC_RUN_BASE_ENV_FIXED {
        cmd = cmd.env(k, v);
    }

    if let Some(p) = &cwd_path {
        cmd = cmd.current_dir(p);
    } else if let Ok(root) = find_repo_root() {
        cmd = cmd.current_dir(root);
    }

    match spec.get::<LuaValue>("env")? {
        LuaValue::Nil => {}
        LuaValue::Table(t) => {
            for pair in t.pairs::<LuaValue, LuaValue>() {
                let (LuaValue::String(k), LuaValue::String(v)) = pair? else {
                    return Err(err("env must map strings to strings".into()));
                };
                let (k, v) = (k.to_str()?.to_string(), v.to_str()?.to_string());
                if k.is_empty() || k.contains(['\0', '=']) || v.contains('\0') {
                    return Err(err(
                        "env names must be nonempty without NUL or '=', values without NUL".into(),
                    ));
                }
                cmd = cmd.env(k, v);
            }
        }
        other => {
            return Err(err(format!(
                "env must be a table, not a {}",
                other.type_name()
            )));
        }
    }

    match spec.get::<LuaValue>("stdin")? {
        LuaValue::Nil => {}
        LuaValue::String(s) => cmd = cmd.stdin_bytes(s.as_bytes().to_vec()),
        other => {
            return Err(err(format!(
                "stdin must be a string, not a {}",
                other.type_name()
            )));
        }
    }

    let timeout_ms: u64 = match spec.get::<LuaValue>("timeout_ms")? {
        LuaValue::Nil => PROC_RUN_DEFAULT_TIMEOUT_MS,
        LuaValue::Integer(i) if i >= 0 => i as u64,
        other => {
            return Err(err(format!(
                "timeout_ms must be a non-negative integer (0 = no deadline), not {other:?}"
            )));
        }
    };
    if timeout_ms > 0 {
        cmd = cmd.timeout(std::time::Duration::from_millis(timeout_ms));
    }

    let group = match spec.get::<LuaValue>("group")? {
        LuaValue::Nil => true,
        LuaValue::Boolean(b) => b,
        other => {
            return Err(err(format!(
                "group must be a boolean, not a {}",
                other.type_name()
            )));
        }
    };
    cmd = cmd.group(group);
    if managed_group && !group {
        return Err(err(
            "group=false is not supported by script-owned proc.spawn".into(),
        ));
    }

    // Per-fd capture cap (order 1443-esm5). Unset keeps the executor's default
    // (tillandsias_exec::DEFAULT_CAPTURE_BYTES); a clipped capture comes back
    // with truncated = true and ok = false, never as a whole one.
    match spec.get::<LuaValue>("capture_bytes")? {
        LuaValue::Nil => {}
        LuaValue::Integer(i) if i > 0 => cmd = cmd.capture_bytes(i as usize),
        other => {
            return Err(err(format!(
                "capture_bytes must be a positive integer, not {other:?}"
            )));
        }
    }

    if let Some(d) = policy_gate(&argv, cwd_path.as_deref(), caller) {
        let t = lua.create_table()?;
        let echo = lua.create_table()?;
        for (i, a) in argv.iter().enumerate() {
            echo.set(i + 1, crate::command_policy::redact(a))?;
        }
        t.set("argv", echo)?;
        t.set(
            "status",
            if d.strictness == crate::command_policy::Strictness::Deny {
                "policy_denied"
            } else {
                "policy_consent_required"
            },
        )?;
        t.set("ok", false)?;
        t.set("rule_id", d.rule_id.as_str())?;
        t.set("decision", d.token.as_str())?;
        t.set("why", d.why.unwrap_or_default())?;
        t.set("remedy", d.remedy.unwrap_or_default())?;
        return Ok(PreparedProc::Refused(t));
    }
    Ok(PreparedProc::Command { argv, command: cmd })
}

fn proc_run(lua: &Lua, spec: LuaTable) -> LuaResult<LuaTable> {
    let (argv, cmd) = match prepare_proc(lua, spec, "proc.run", false)? {
        PreparedProc::Refused(t) => return Ok(t),
        PreparedProc::Command { argv, command } => (argv, command),
    };
    let err = |m: String| mlua::Error::RuntimeError(format!("proc.run: {m}"));
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| err(format!("runtime: {e}")))?;
    let t0 = std::time::Instant::now();
    let result = rt.block_on(cmd.run());
    let wall_ms = t0.elapsed().as_millis() as u64;
    // NOT an implicit drop. Tokio reads a child's pipes on blocking threads
    // (Windows), and dropping the runtime WAITS for them. After an UNGROUPED
    // deadline the killed child's surviving descendants still hold those
    // pipes, so the drop blocked until they exited: measured on native
    // Windows, proc.run reported wall_ms=544 and returned to Lua 30.2 s later.
    // shutdown_background returns now and lets those threads end on their own.
    rt.shutdown_background();

    proc_result_to_lua(lua, &argv, result, wall_ms)
}

pub(crate) fn proc_result_to_lua(
    lua: &Lua,
    argv: &[String],
    result: Result<tillandsias_exec::Output, tillandsias_exec::ExecError>,
    wall_ms: u64,
) -> LuaResult<LuaTable> {
    let err = |m: String| mlua::Error::RuntimeError(format!("proc.run: {m}"));

    let t = lua.create_table()?;
    let echo = lua.create_table()?;
    for (i, a) in argv.iter().enumerate() {
        echo.set(i + 1, a.as_str())?;
    }
    t.set("argv", echo)?;
    t.set("wall_ms", wall_ms)?;
    match result {
        Ok(out) => {
            t.set("run_id", out.run.as_str().to_string())?;
            t.set("stdout", lua.create_string(&out.stdout)?)?;
            t.set("stderr", lua.create_string(&out.stderr)?)?;
            t.set("truncated", out.truncated)?;
            t.set("dropped", out.dropped)?;
            match out.completion {
                tillandsias_exec::Completion::Exited(code) => {
                    t.set("status", "exited")?;
                    t.set("code", code)?;
                    // A clean exit with a CLIPPED capture is not ok: the caller
                    // would be judging output it does not have (1443-esm5).
                    t.set("ok", code == 0 && !out.truncated)?;
                }
                tillandsias_exec::Completion::Signaled(sig) => {
                    t.set("status", "signaled")?;
                    t.set("signal", sig)?;
                    t.set("ok", false)?;
                }
                tillandsias_exec::Completion::TimedOut { .. } => {
                    t.set("status", "timed_out")?;
                    t.set("ok", false)?;
                }
            }
        }
        Err(tillandsias_exec::ExecError::Spawn { source, .. }) => {
            // Operational, not a programmer error: a missing program is data.
            t.set("status", "spawn_failed")?;
            t.set("ok", false)?;
            t.set("stdout", "")?;
            t.set(
                "stderr",
                lua.create_string(format!("spawn failed: {source}"))?,
            )?;
        }
        Err(e) => return Err(err(e.to_string())),
    }
    Ok(t)
}

/// On Windows `canonicalize` returns a VERBATIM path (`\\?\C:\...`), and a
/// plain absolute path like `C:\...` never `starts_with` it, so every absolute
/// path under the root was refused as "outside the repository root" (measured
/// on native Windows while porting the archiver, order 1380-u7sq). Strip the
/// prefix for drive-letter paths only; UNC and device paths are left as they
/// are. A no-op everywhere else.
fn strip_verbatim(p: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(s) = p.to_str()
            && let Some(rest) = s.strip_prefix(r"\\?\")
            && rest.as_bytes().get(1) == Some(&b':')
        {
            return PathBuf::from(rest);
        }
    }
    p
}

/// The path the CONTAINMENT test compares against the (canonical) root: the
/// nearest existing ancestor of `normalized`, canonicalised, with the not-yet-
/// existing tail re-appended. `None` when it cannot be resolved; every caller
/// REFUSES on `None`, so there is no lexical fallback (order 1412-n5cp: the
/// old fallback admitted an unresolvable path, which is fail-open).
///
/// ORDER 1412-n5cp. The probe uses `symlink_metadata`, which does NOT follow
/// links. With `exists()` (which follows), a DANGLING in-root link
/// (root/x -> /outside/newfile, target absent) read as absent, became a tail
/// NAME re-appended to the canonical root, and passed containment. Measured
/// end to end, today's verbs were safe only by incident (fs.write's
/// temp-and-rename replaces the link; fs.mkdir hits EEXIST), not because the
/// sandbox refused. Now the link is the probe point, its target cannot be
/// canonicalised, and the path is refused.
///
/// ORDER 1411-b5fk. The root is canonicalised, but a request was compared only
/// after LEXICAL normalisation, so any symlinked prefix of the root failed
/// `starts_with`. On macOS `/var` is a symlink to `/private/var`, so every path
/// under a temp dir (`/var/folders/…`) was refused as "outside the repository
/// root" and `lua_std::the_archiver_sweeps_in_the_default_sandbox` failed on
/// every Mac, 3/3. Linux `/tmp` is not a symlink, so Linux was green.
pub(crate) fn containment_path(normalized: &Path) -> Option<PathBuf> {
    let mut probe = normalized.to_path_buf();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    // symlink_metadata: a dangling link EXISTS here, so it becomes the probe
    // point instead of a tail name.
    while std::fs::symlink_metadata(&probe).is_err() {
        let name = probe.file_name()?.to_os_string();
        tail.push(name);
        if !probe.pop() {
            return None;
        }
    }
    // A dangling link, or anything else that will not resolve, is refused.
    let mut resolved = probe.canonicalize().map(strip_verbatim).ok()?;
    for name in tail.iter().rev() {
        resolved.push(name);
    }
    Some(resolved)
}

/// Resolve a path for an fs WRITE verb (order 1380-u7sq): the same rooting as
/// `fs.read`, including the symlink check, applied to the nearest EXISTING
/// ancestor because the path itself may not exist yet. Refusals name the verb
/// and the path, never the data.
fn resolve_write_path(root: &Path, path_str: &str, verb: &str) -> Result<PathBuf, String> {
    if path_str.is_empty() {
        return Err(format!("{verb}: refused — empty path"));
    }
    let path = Path::new(path_str);
    let normalized = if path.is_absolute() {
        normalize_path(path)
    } else {
        normalize_path(&root.join(path))
    };
    let Some(contained) = containment_path(&normalized) else {
        return Err(format!(
            "{verb}: refused — '{path_str}' cannot be resolved (a dangling or unresolvable symlink); the sandbox cannot prove it stays inside the repository root"
        ));
    };
    if !contained.starts_with(root) || contained == root {
        return Err(format!(
            "{verb}: refused — path '{path_str}' is outside the repository root (or is the root itself)"
        ));
    }
    let mut probe = normalized.clone();
    while !probe.exists() {
        if !probe.pop() {
            break;
        }
    }
    if let Ok(canon) = probe.canonicalize().map(strip_verbatim)
        && !canon.starts_with(root)
    {
        return Err(format!(
            "{verb}: refused — '{path_str}' resolves through a symlink outside the repository root"
        ));
    }
    Ok(normalized)
}

/// ORDER 1443-fpck. Under regime=fixture a write verb may not reach the real
/// checkout's git dir or leave the declared scope; the refusal is audited and
/// RAISED like every other fs refusal, carrying the verdict token, why and
/// remedy on separate lines, and nothing is written.
fn fixture_write_guard(root: &Path, target: &Path, verb: &str) -> Result<(), mlua::Error> {
    use crate::command_policy as cp;
    if std::env::var("TILLANDSIAS_POLICY_REGIME").as_deref() != Ok("fixture") {
        return Ok(());
    }
    let Some(d) = cp::fixture_write_decision(target, &cp::FixtureScope::from_env(root)) else {
        return Ok(());
    };
    let req = cp::Request {
        argv: vec![verb.to_string(), target.display().to_string()],
        cwd: root.to_path_buf(),
        workspace: root.to_path_buf(),
        host_kind: cp::read_host_kind(root).kind,
        regime: "fixture".into(),
        caller: verb.to_string(),
    };
    cp::audit_decision(&req, &d, None);
    Err(mlua::Error::RuntimeError(format!(
        "{verb}: {}\nwhy: {}\nremedy: {}",
        d.token,
        d.why.unwrap_or_default(),
        d.remedy.unwrap_or_default()
    )))
}

/// fs.mkdir / fs.write / fs.list / fs.exists: OBSERVING ONLY (order 1380-u7sq).
/// Rooted exactly like fs.read, so a script can touch the checkout (or the
/// root TILLANDSIAS_REPO_ROOT names, which is how the archiver's --check points
/// the whole script at its per-run scratch copy) and nothing else. A Cacheable
/// predicate is pure by construction and never gets a write verb.
fn register_fs_write_verbs(lua: &Lua) -> Result<(), LuaError> {
    let fs_table: LuaTable = lua
        .globals()
        .get("fs")
        .map_err(|e| LuaError::VmError(format!("fs table missing: {e}")))?;
    let rooted = |verb: &'static str| {
        move || -> Result<PathBuf, mlua::Error> {
            find_repo_root().map_err(|e| mlua::Error::RuntimeError(e.replace("fs.read", verb)))
        }
    };

    let root_mkdir = rooted("fs.mkdir");
    let mkdir = lua
        .create_function(move |_, path_str: String| {
            let root = root_mkdir()?;
            let p = resolve_write_path(&root, &path_str, "fs.mkdir")
                .map_err(mlua::Error::RuntimeError)?;
            fixture_write_guard(&root, &p, "fs.mkdir")?;
            std::fs::create_dir_all(&p).map_err(|e| {
                mlua::Error::RuntimeError(format!("fs.mkdir: failed to create '{path_str}': {e}"))
            })?;
            Ok(true)
        })
        .map_err(|e| LuaError::VmError(format!("fs.mkdir: {e}")))?;

    // Atomic: the bytes go to a temporary sibling and are renamed over the
    // target, so a reader never sees half a ledger and a failed write leaves
    // the old file intact.
    let root_write = rooted("fs.write");
    let write = lua
        .create_function(move |_, (path_str, data): (String, LuaString)| {
            let root = root_write()?;
            let p = resolve_write_path(&root, &path_str, "fs.write")
                .map_err(mlua::Error::RuntimeError)?;
            fixture_write_guard(&root, &p, "fs.write")?;
            let parent = p.parent().ok_or_else(|| {
                mlua::Error::RuntimeError(format!("fs.write: '{path_str}' has no parent"))
            })?;
            if !parent.is_dir() {
                return Err(mlua::Error::RuntimeError(format!(
                    "fs.write: the directory for '{path_str}' does not exist; fs.mkdir it first"
                )));
            }
            let tmp = parent.join(format!(
                ".{}.fs-write.{}",
                p.file_name().and_then(|n| n.to_str()).unwrap_or("out"),
                std::process::id()
            ));
            std::fs::write(&tmp, data.as_bytes()).map_err(|e| {
                mlua::Error::RuntimeError(format!("fs.write: failed to write '{path_str}': {e}"))
            })?;
            std::fs::rename(&tmp, &p).map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                mlua::Error::RuntimeError(format!("fs.write: failed to replace '{path_str}': {e}"))
            })?;
            Ok(true)
        })
        .map_err(|e| LuaError::VmError(format!("fs.write: {e}")))?;

    // UNSTABLE BY DESIGN, OBSERVING ONLY, NEVER MEMOIZED (operator ruling
    // 2026-09-26, recorded on 1395-ue3i): "clearly mark it as unstable and use
    // it for orchestration but not for hard tests … a test should not say
    // folder.forEachFile(verifySomething) but folder.file1.verifySomething()".
    // A Cacheable predicate never gets it (this whole function is Observing
    // only), and it does not touch the memo's read log, so no cached verdict
    // can depend on a directory's membership; hard tests name their files and
    // fs.read each one. Symlinks are EXCLUDED (never followed), and so are
    // subdirectories. No mtime: git does not preserve it (1395-xjty).
    //
    // Sorted names (not paths) of the regular files in a directory, so the
    // result is identical on every platform. An ABSENT directory is an empty
    // list plus `false`, so "no fragments yet" and "unreadable" stay distinct:
    // any other failure raises.
    let root_list = rooted("fs.list");
    let list = lua
        .create_function(move |lua, path_str: String| {
            let root = root_list()?;
            let p = resolve_write_path(&root, &path_str, "fs.list")
                .map_err(mlua::Error::RuntimeError)?;
            let t = lua.create_table()?;
            if !p.exists() {
                return Ok((t, false));
            }
            let mut names: Vec<String> = Vec::new();
            for entry in std::fs::read_dir(&p).map_err(|e| {
                mlua::Error::RuntimeError(format!("fs.list: failed to list '{path_str}': {e}"))
            })? {
                let entry = entry.map_err(|e| {
                    mlua::Error::RuntimeError(format!("fs.list: failed to list '{path_str}': {e}"))
                })?;
                if entry.file_type().map(|ft| ft.is_file()).unwrap_or(false) {
                    names.push(entry.file_name().to_string_lossy().into_owned());
                }
            }
            names.sort();
            for (i, n) in names.into_iter().enumerate() {
                t.set(i + 1, n)?;
            }
            Ok((t, true))
        })
        .map_err(|e| LuaError::VmError(format!("fs.list: {e}")))?;

    let root_exists = rooted("fs.exists");
    let exists = lua
        .create_function(move |_, path_str: String| {
            let root = root_exists()?;
            let p = resolve_write_path(&root, &path_str, "fs.exists")
                .map_err(mlua::Error::RuntimeError)?;
            Ok(p.exists())
        })
        .map_err(|e| LuaError::VmError(format!("fs.exists: {e}")))?;

    for (name, f) in [
        ("mkdir", mkdir),
        ("write", write),
        ("list", list),
        ("exists", exists),
    ] {
        fs_table
            .set(name, f)
            .map_err(|e| LuaError::VmError(format!("fs.{name}: {e}")))?;
    }
    Ok(())
}

/// The Lua globals a CACHEABLE predicate may reach, besides the `expert` table
/// (1367-upz6, 1367-q9yc). Deterministic, side-effect-free library only: no `os`, no `io`,
/// no `print`, no `load`, no `collectgarbage`, and `math` without `random`.
/// Pinned from inside Lua by tests/lua_predicate_classes.rs.
pub const CACHEABLE_STDLIB_GLOBALS: &[&str] = &[
    "_G",
    "_VERSION",
    "assert",
    "error",
    "expect",
    "fs",
    "getmetatable",
    "hash",
    "ipairs",
    "json",
    "math",
    // "next" survives THIS cut only so lua_std::determinism can capture it as
    // the private walk behind its defined-order `pairs`; it then sets the
    // global to nil (1384-bp6t: the raw walk is hash order, which varies per
    // process). The final global set, without next, is pinned by
    // tests/lua_predicate_classes.rs.
    "next",
    "pairs",
    "path",
    "pcall",
    "rawequal",
    "rawget",
    "rawlen",
    "rawset",
    "select",
    "setmetatable",
    "string",
    "table",
    "tonumber",
    "tostring",
    "type",
    "utf8",
    "xpcall",
    "yaml",
];

/// Locate the repository root by checking environment variables, parent directories
/// for plan/index.yaml or .git, and current executable directory.
///
/// FAILS CLOSED (review of 1367-q9yc): there is no "." fallback. A cwd of `/`
/// would make every absolute path "inside the repository", so an unlocatable
/// root is a named refusal at `fs.read` time, never a guess. `/` itself is
/// never accepted as a root, whichever route proposed it.
pub(crate) fn find_repo_root() -> Result<PathBuf, String> {
    let root = locate_repo_root().ok_or_else(|| {
        "fs.read: refused — no repository root found (set TILLANDSIAS_REPO_ROOT, or run \
         inside a checkout containing plan/index.yaml or .git)"
            .to_string()
    })?;
    validate_repo_root(root)
}

/// The fail-closed half of [`find_repo_root`], separate so it can be tested
/// with `/` without changing the process cwd or environment.
fn validate_repo_root(root: PathBuf) -> Result<PathBuf, String> {
    let root = root.canonicalize().map(strip_verbatim).map_err(|e| {
        format!(
            "fs.read: refused — repository root {} unresolvable: {e}",
            root.display()
        )
    })?;
    if root.parent().is_none() {
        return Err(format!(
            "fs.read: refused — repository root resolved to the filesystem root {}",
            root.display()
        ));
    }
    Ok(root)
}

fn locate_repo_root() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("TILLANDSIAS_REPO_ROOT") {
        let pb = PathBuf::from(p);
        if pb.is_dir() {
            return Some(pb);
        }
    }
    if let Ok(p) = std::env::var("PROJECT_ROOT") {
        let pb = PathBuf::from(p);
        if pb.is_dir() {
            return Some(pb);
        }
    }
    if let Ok(mut dir) = std::env::current_dir() {
        loop {
            if dir.join("plan/index.yaml").is_file() || dir.join(".git").exists() {
                return Some(dir);
            }
            if !dir.pop() {
                break;
            }
        }
    }
    if let Ok(mut exe) = std::env::current_exe() {
        exe.pop();
        loop {
            if exe.join("plan/index.yaml").is_file() || exe.join(".git").exists() {
                return Some(exe);
            }
            if !exe.pop() {
                break;
            }
        }
    }
    None
}

/// Lexicographically normalize a path, eliminating `.` and `..` segments.
fn normalize_path(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::Prefix(p) => out.push(Component::Prefix(p)),
            Component::RootDir => out.push(Component::RootDir),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(c) => out.push(c),
        }
    }
    out
}

fn format_lua_value(val: &LuaValue) -> String {
    match val {
        LuaValue::Nil => "nil".to_string(),
        LuaValue::Boolean(b) => b.to_string(),
        LuaValue::Integer(i) => i.to_string(),
        LuaValue::Number(n) => n.to_string(),
        LuaValue::String(s) => format!("{:?}", s.to_string_lossy()),
        LuaValue::Table(t) => {
            let mut parts = Vec::new();
            for (k, v) in t.clone().pairs::<LuaValue, LuaValue>().flatten() {
                parts.push(format!(
                    "{}: {}",
                    format_lua_value(&k),
                    format_lua_value(&v)
                ));
            }
            format!("{{{}}}", parts.join(", "))
        }
        other => format!("{other:?}"),
    }
}

fn values_equal(a: &LuaValue, b: &LuaValue) -> bool {
    if a == b {
        return true;
    }
    match (a, b) {
        (LuaValue::Table(ta), LuaValue::Table(tb)) => {
            let mut count_a = 0;
            for (k, va) in ta.clone().pairs::<LuaValue, LuaValue>().flatten() {
                count_a += 1;
                match tb.get::<LuaValue>(k) {
                    Ok(vb) => {
                        if !values_equal(&va, &vb) {
                            return false;
                        }
                    }
                    Err(_) => return false,
                }
            }
            let count_b = tb.clone().pairs::<LuaValue, LuaValue>().flatten().count();
            count_a == count_b
        }
        _ => false,
    }
}

/// The digest belongs to the bytes returned by this particular read, not to a
/// later reread of the path. Duplicate paths are retained when their contents
/// differ during one evaluation, making that evaluation uncacheable.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ReadObservation {
    path: PathBuf,
    digest: Option<[u8; 32]>,
}

pub type ReadLog = std::sync::Arc<std::sync::Mutex<Vec<ReadObservation>>>;

/// Build a Lua runtime whose `expert` table contains EXACTLY the verbs its class
/// is entitled to.
pub fn build_environment(class: PredicateClass) -> Result<Lua, LuaError> {
    build_environment_logged(class, ReadLog::default())
}

/// As [`build_environment`], recording every `fs.read` path into `reads`.
pub fn build_environment_logged(class: PredicateClass, reads: ReadLog) -> Result<Lua, LuaError> {
    let lua = Lua::new();

    // @trace order:1532-u9en
    // Both sandboxed classes use a capability allow-list. Being uncached does
    // not authorize Observing to bypass rooted fs verbs with io.lines,
    // os.remove, or package.loadlib. In particular, do not retain package:
    // package.loaded aliases the original stdlib tables and its searchers can
    // load files/native code even if the corresponding globals are removed.
    // There is no debug/registry access or loader alias in the reachable set.
    // This is not a filesystem sandbox for children spawned by proc/sh.
    {
        let globals = lua.globals();
        let observing = matches!(class, PredicateClass::Observing);
        if observing {
            // Fresh tables expose only clock helpers and fixed-stream logging,
            // never file handles, filename readers, or filesystem verbs.
            for (name, members) in [
                ("os", &["clock", "date", "difftime", "time"][..]),
                ("io", &["write", "flush"][..]),
            ] {
                let original: LuaTable = globals
                    .get(name)
                    .map_err(|e| LuaError::VmError(format!("{name}: {e}")))?;
                let restricted = lua
                    .create_table()
                    .map_err(|e| LuaError::VmError(format!("{name}: {e}")))?;
                for member in members {
                    let value: LuaValue = original
                        .get(*member)
                        .map_err(|e| LuaError::VmError(format!("{name}.{member}: {e}")))?;
                    restricted
                        .set(*member, value)
                        .map_err(|e| LuaError::VmError(format!("{name}.{member}: {e}")))?;
                }
                if name == "io" {
                    // The push hook consumes Git's supplied stdin with
                    // io.lines(). Its filename form is a different capability
                    // and must not reach the native reader. No input/output
                    // setter exists, so the streams cannot be redirected.
                    let lines: LuaFunction = original
                        .get("lines")
                        .map_err(|e| LuaError::VmError(format!("io.lines: {e}")))?;
                    let stdin_lines = lua
                        .create_function(move |_, args: LuaMultiValue| {
                            if !args.is_empty() {
                                return Err(mlua::Error::RuntimeError(
                                    "io.lines: refused — filenames are unmanaged; use fs.read (io.lines() is stdin-only)".into(),
                                ));
                            }
                            lines.call::<LuaMultiValue>(())
                        })
                        .map_err(|e| LuaError::VmError(format!("io.lines: {e}")))?;
                    restricted
                        .set("lines", stdin_lines)
                        .map_err(|e| LuaError::VmError(format!("io.lines: {e}")))?;
                    // Do not return native file userdata from write, or expose
                    // its metatable. A private closure owns each fixed stream.
                    let proxy: LuaFunction = lua
                        .load("return function(stream) return {write = function(_, ...) stream:write(...) end, flush = function(_) return stream:flush() end} end")
                        .eval()
                        .map_err(|e| LuaError::VmError(format!("io streams: {e}")))?;
                    for stream in ["stdout", "stderr"] {
                        let handle: LuaValue = original
                            .get(stream)
                            .map_err(|e| LuaError::VmError(format!("io.{stream}: {e}")))?;
                        let table: LuaTable = proxy
                            .call(handle)
                            .map_err(|e| LuaError::VmError(format!("io.{stream}: {e}")))?;
                        restricted
                            .set(stream, table)
                            .map_err(|e| LuaError::VmError(format!("io.{stream}: {e}")))?;
                    }
                    let write: LuaFunction = original
                        .get("write")
                        .map_err(|e| LuaError::VmError(format!("io.write: {e}")))?;
                    restricted
                        .set(
                            "write",
                            lua.create_function(move |_, args: LuaMultiValue| {
                                write.call::<LuaMultiValue>(args)?;
                                Ok(())
                            })
                            .map_err(|e| LuaError::VmError(format!("io.write: {e}")))?,
                        )
                        .map_err(|e| LuaError::VmError(format!("io.write: {e}")))?;
                }
                globals
                    .set(name, restricted)
                    .map_err(|e| LuaError::VmError(format!("{name}: {e}")))?;
            }
        }
        let mut drop: Vec<String> = Vec::new();
        for pair in globals.clone().pairs::<LuaValue, LuaValue>() {
            let (k, _) = pair.map_err(|e| LuaError::VmError(format!("globals: {e}")))?;
            if let LuaValue::String(name) = k {
                let name = name.to_string_lossy().to_string();
                if !CACHEABLE_STDLIB_GLOBALS.contains(&name.as_str())
                    && !(observing
                        && [
                            "os",
                            "io",
                            "print",
                            "warn",
                            "load",
                            "collectgarbage",
                            "coroutine",
                        ]
                        .contains(&name.as_str()))
                {
                    drop.push(name);
                }
            }
        }
        for name in drop {
            globals
                .set(name.as_str(), LuaValue::Nil)
                .map_err(|e| LuaError::VmError(format!("remove {name}: {e}")))?;
        }
        if !observing && let Ok(math) = globals.get::<LuaTable>("math") {
            math.set("random", LuaValue::Nil)
                .map_err(|e| LuaError::VmError(format!("math.random: {e}")))?;
            math.set("randomseed", LuaValue::Nil)
                .map_err(|e| LuaError::VmError(format!("math.randomseed: {e}")))?;
        }
    }

    // ORDER 1367-q9yc. Pure shims exposed to both Cacheable and Observing classes:
    // (1) repo-rooted fs.read rejecting path traversals and absolute paths outside repo root;
    // (2) expect.contains, expect.matches, expect.eq returning boolean true or raising
    // an error with expected and actual values on mismatch.
    {
        let repo_root = find_repo_root();

        let fs_table = lua
            .create_table()
            .map_err(|e| LuaError::VmError(format!("failed to create fs table: {e}")))?;

        let f_read = {
            let root = repo_root.clone();
            let reads = reads.clone();
            lua.create_function(move |lua, path_str: String| {
                let root = root.clone().map_err(mlua::Error::RuntimeError)?;
                if path_str.is_empty() {
                    return Err(mlua::Error::RuntimeError(
                        "fs.read: refused — empty path".to_string(),
                    ));
                }
                let path = Path::new(&path_str);
                let normalized = if path.is_absolute() {
                    normalize_path(path)
                } else {
                    normalize_path(&root.join(path))
                };
                // 1411-b5fk: compare after resolving a symlinked prefix of the
                // root (macOS /var -> /private/var), exactly as the write verbs do.
                // 1412-n5cp: an unresolvable path is refused, never compared
                // lexically.
                if !containment_path(&normalized).is_some_and(|c| c.starts_with(&root)) {
                    return Err(mlua::Error::RuntimeError(format!(
                        "fs.read: refused — path '{path_str}' is outside repository root"
                    )));
                }
                if let Ok(canon) = normalized.canonicalize().map(strip_verbatim)
                    && !canon.starts_with(&root)
                {
                    return Err(mlua::Error::RuntimeError(format!(
                        "fs.read: refused — symlink '{path_str}' resolves outside repository root"
                    )));
                }
                // Record the bytes THIS call observed. A post-evaluation
                // reread can see different bytes and falsely authenticate the
                // verdict against a state it never evaluated (1470-dbuw).
                let bytes = std::fs::read(&normalized);
                let digest = bytes.as_ref().ok().map(|b| Sha256::digest(b).into());
                if let Ok(mut log) = reads.lock() {
                    log.push(ReadObservation {
                        path: normalized,
                        digest,
                    });
                }
                let bytes = bytes.map_err(|e| {
                    mlua::Error::RuntimeError(format!("fs.read: failed to read '{path_str}': {e}"))
                })?;
                lua.create_string(&bytes)
            })
            .map_err(|e| LuaError::VmError(format!("fs.read: {e}")))?
        };
        fs_table
            .set("read", f_read)
            .map_err(|e| LuaError::VmError(format!("fs.read: {e}")))?;

        lua.globals()
            .set("fs", fs_table)
            .map_err(|e| LuaError::VmError(format!("failed to set fs global: {e}")))?;

        let expect_table = lua
            .create_table()
            .map_err(|e| LuaError::VmError(format!("failed to create expect table: {e}")))?;

        let f_contains = lua
            .create_function(|_, (haystack, needle): (String, String)| {
                if haystack.contains(&needle) {
                    Ok(true)
                } else {
                    Err(mlua::Error::RuntimeError(format!(
                        "expectation failed: expected string to contain {:?}, got {:?}",
                        needle, haystack
                    )))
                }
            })
            .map_err(|e| LuaError::VmError(format!("expect.contains: {e}")))?;
        expect_table
            .set("contains", f_contains)
            .map_err(|e| LuaError::VmError(format!("expect.contains: {e}")))?;

        let f_matches = lua
            .create_function(|_, (haystack, pattern): (String, String)| {
                let re = regex::Regex::new(&pattern).map_err(|e| {
                    mlua::Error::RuntimeError(format!(
                        "expect.matches: invalid regex pattern {:?}: {e}",
                        pattern
                    ))
                })?;
                if re.is_match(&haystack) {
                    Ok(true)
                } else {
                    Err(mlua::Error::RuntimeError(format!(
                        "expectation failed: expected string to match pattern {:?}, got {:?}",
                        pattern, haystack
                    )))
                }
            })
            .map_err(|e| LuaError::VmError(format!("expect.matches: {e}")))?;
        expect_table
            .set("matches", f_matches)
            .map_err(|e| LuaError::VmError(format!("expect.matches: {e}")))?;

        let f_eq = lua
            .create_function(|_, (actual, expected): (LuaValue, LuaValue)| {
                if values_equal(&actual, &expected) {
                    Ok(true)
                } else {
                    let act_str = format_lua_value(&actual);
                    let exp_str = format_lua_value(&expected);
                    Err(mlua::Error::RuntimeError(format!(
                        "expectation failed: expected {exp_str}, got {act_str}"
                    )))
                }
            })
            .map_err(|e| LuaError::VmError(format!("expect.eq: {e}")))?;
        expect_table
            .set("eq", f_eq)
            .map_err(|e| LuaError::VmError(format!("expect.eq: {e}")))?;

        lua.globals()
            .set("expect", expect_table)
            .map_err(|e| LuaError::VmError(format!("failed to set expect global: {e}")))?;
    }

    // 1375-btuf: the shared std tables, by class. Registered AFTER the
    // Cacheable allow-list cut, and every name it adds for Cacheable is on
    // that allow-list (lua_std::tables), so this adds, never widens by deny.
    crate::lua_std::register(&lua, class)
        .map_err(|e| LuaError::VmError(format!("lua_std: {e}")))?;

    let expert = lua
        .create_table()
        .map_err(|e| LuaError::VmError(format!("failed to create expert table: {e}")))?;

    // log_info — both classes.
    {
        let f = lua
            .create_function(|_, msg: String| {
                eprintln!("[lua-predicate] {msg}");
                Ok(())
            })
            .map_err(|e| LuaError::VmError(format!("log_info: {e}")))?;
        expert
            .set("log_info", f)
            .map_err(|e| LuaError::VmError(format!("log_info: {e}")))?;
    }

    // verbs() — both classes. Enumerable capability set.
    {
        let list: Vec<String> = class.verbs().iter().map(|s| s.to_string()).collect();
        let f = lua
            .create_function(move |lua, ()| {
                let t = lua.create_table()?;
                for (i, v) in list.iter().enumerate() {
                    t.set(i + 1, v.clone())?;
                }
                Ok(t)
            })
            .map_err(|e| LuaError::VmError(format!("verbs: {e}")))?;
        expert
            .set("verbs", f)
            .map_err(|e| LuaError::VmError(format!("verbs: {e}")))?;
    }

    if matches!(class, PredicateClass::Observing) {
        // now_ms — OBSERVING ONLY. See the header: a clock read is an
        // observation, and caching a predicate that branches on it returns an
        // answer computed at a time that has passed.
        {
            let f = lua
                .create_function(|_, ()| {
                    Ok(std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis() as u64)
                })
                .map_err(|e| LuaError::VmError(format!("now_ms: {e}")))?;
            expert
                .set("now_ms", f)
                .map_err(|e| LuaError::VmError(format!("now_ms: {e}")))?;
        }

        // shell{argv} — OBSERVING ONLY, and ARGV ONLY.
        //
        // The argument is a Lua SEQUENCE of strings, never a command line to be
        // parsed. There is deliberately no string form: that deletes quoting,
        // word-splitting, globbing and injection as a class, which is the single
        // constraint doing the most work in 1252-fg9e and the reason this verb
        // can be exposed to agent-authored code at all.
        //
        // Rust spawns, owns the fds, drains them concurrently, enforces the
        // timeout and reaps. Lua receives a VALUE.
        {
            let f = lua
                .create_function(|lua, spec: LuaTable| {
                    let mut argv: Vec<String> = Vec::new();
                    for pair in spec.clone().sequence_values::<String>() {
                        argv.push(pair?);
                    }
                    if argv.is_empty() {
                        return Err(mlua::Error::RuntimeError(
                            "expert.shell: refused — empty argv; pass a sequence like \
                             {\"git\",\"status\"}, never a command string"
                                .to_string(),
                        ));
                    }
                    let timeout_ms: Option<u64> = spec.get("timeout_ms").ok().flatten();
                    // 1443-isrk: the policy decides before anything spawns.
                    if let Some(d) = policy_gate(&argv, None, "sh.run") {
                        return Err(mlua::Error::RuntimeError(format!(
                            "{}\n  why: {}\n  remedy: {}",
                            d.token,
                            d.why.unwrap_or_default(),
                            d.remedy.unwrap_or_default()
                        )));
                    }

                    let mut cmd = tillandsias_exec::Command::new(argv);
                    if let Some(ms) = timeout_ms {
                        cmd = cmd.timeout(std::time::Duration::from_millis(ms));
                    }

                    // A dedicated current-thread runtime: this is called from
                    // synchronous Lua, and block_on inside an existing runtime
                    // would panic. Cheap relative to a process spawn.
                    let rt = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|e| mlua::Error::RuntimeError(format!("runtime: {e}")))?;
                    let result = rt.block_on(cmd.run());
                    // 1392-bcby, proc.run's 1384-aixy defect in this verb: DROPPING
                    // the runtime waits for its blocking pipe threads, which on
                    // Windows outlive a deadline while a grandchild holds the pipes
                    // (proc.run: reported wall_ms=544, returned 30.2 s later). On
                    // EVERY path, error included, hand them off instead. Unix reads
                    // pipes through async fds and never waited (yoga: 506/507 ms).
                    rt.shutdown_background();
                    let out = result.map_err(|e| mlua::Error::RuntimeError(format!("{e}")))?;
                    shell_result_to_lua(lua, out)
                })
                .map_err(|e| LuaError::VmError(format!("shell: {e}")))?;
            expert
                .set("shell", f.clone())
                .map_err(|e| LuaError::VmError(format!("shell: {e}")))?;
            // 1375-btuf: `sh.run{argv}` is the std name for the same verb;
            // `expert.shell` stays for the scripts that already call it.
            let sh = lua
                .create_table()
                .map_err(|e| LuaError::VmError(format!("sh: {e}")))?;
            sh.set("run", f)
                .map_err(|e| LuaError::VmError(format!("sh.run: {e}")))?;
            lua.globals()
                .set("sh", sh)
                .map_err(|e| LuaError::VmError(format!("sh: {e}")))?;
        }

        // proc.run{argv=...}: OBSERVING ONLY (order 1384-aixy, design 4.1). The
        // Cacheable class filters its globals to CACHEABLE_STDLIB_GLOBALS, so it
        // can never see `proc` (a process is an observation).
        {
            let run = lua
                .create_function(proc_run)
                .map_err(|e| LuaError::VmError(format!("proc.run: {e}")))?;
            let proc_t = lua
                .create_table()
                .map_err(|e| LuaError::VmError(format!("proc: {e}")))?;
            proc_t
                .set("run", run)
                .map_err(|e| LuaError::VmError(format!("proc.run: {e}")))?;
            lua.globals()
                .set("proc", proc_t)
                .map_err(|e| LuaError::VmError(format!("proc: {e}")))?;
        }

        // fs write verbs: OBSERVING ONLY (order 1380-u7sq).
        register_fs_write_verbs(&lua)?;
    }

    lua.globals()
        .set("expert", expert)
        .map_err(|e| LuaError::VmError(format!("failed to set expert global: {e}")))?;

    Ok(lua)
}

/// A registered predicate and the class it was registered in.
pub struct Predicate {
    pub name: String,
    pub class: PredicateClass,
    source: String,
}

/// Registry that owns each predicate's environment and the cache for the
/// cacheable class.
///
/// THE CACHE IS CONTENT-ADDRESSED, and it is populated ONLY for `Cacheable`.
/// An entry is found by (name, source, argument) and SERVED only while every file the
/// predicate read through `fs.read` still has the digest it had when the
/// verdict was computed (review of 1367-q9yc: keying on (name, arg) alone
/// replayed a stale verdict after a file edit). A Cacheable predicate is thus a
/// pure function of its argument AND the bytes it read, which is what the memo
/// may assume. There is no flag to cache an observing predicate.
#[derive(Default)]
pub struct PredicateRegistry {
    predicates: BTreeMap<String, Predicate>,
    cache: BTreeMap<(String, String, String), CacheEntry>,
    /// How many times a cached value was served, for tests that need to prove a
    /// second call did NOT re-execute.
    pub cache_hits: usize,
}

struct CacheEntry {
    verdict: bool,
    inputs: Vec<ReadObservation>,
}

fn file_digest(path: &Path) -> Option<[u8; 32]> {
    std::fs::read(path).ok().map(|b| Sha256::digest(&b).into())
}

impl CacheEntry {
    fn still_valid(&self) -> bool {
        self.inputs
            .iter()
            .all(|read| file_digest(&read.path) == read.digest)
    }
}

impl PredicateRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a predicate from Lua source. The source must define a global
    /// function named `name`.
    pub fn register(
        &mut self,
        name: &str,
        class: PredicateClass,
        source: &str,
    ) -> Result<(), LuaError> {
        // Compile it once here so a syntax error is a registration failure
        // rather than a surprise at the first call.
        let lua = build_environment(class)?;
        lua.load(source)
            .exec()
            .map_err(|e| LuaError::LoadError(format!("predicate {name}: {e}")))?;
        let _: LuaFunction = lua
            .globals()
            .get(name)
            .map_err(|e| LuaError::LoadError(format!("predicate {name} not defined: {e}")))?;
        // A successfully compiled replacement invalidates every old argument;
        // a failed replacement leaves the registered source and memo intact.
        self.cache
            .retain(|(registered, _, _), _| registered != name);
        self.predicates.insert(
            name.to_string(),
            Predicate {
                name: name.to_string(),
                class,
                source: source.to_string(),
            },
        );
        Ok(())
    }

    /// Load a predicate from a FILE, which is the forge-agent path: an agent
    /// writes a .lua file for an uncommitted spec and it executes with no
    /// recompilation of the host binary.
    pub fn register_file(
        &mut self,
        name: &str,
        class: PredicateClass,
        path: &Path,
    ) -> Result<(), LuaError> {
        let source = std::fs::read_to_string(path)
            .map_err(|e| LuaError::LoadError(format!("read {}: {e}", path.display())))?;
        self.register(name, class, &source)
    }

    pub fn names(&self) -> Vec<&str> {
        self.predicates.keys().map(|s| s.as_str()).collect()
    }

    pub fn class_of(&self, name: &str) -> Option<PredicateClass> {
        self.predicates.get(name).map(|p| p.class)
    }

    /// Evaluate a predicate against a string argument.
    ///
    /// A `Cacheable` result is memoised; an `Observing` result never is. The
    /// branch is on the CLASS, which is the thing the environment was built
    /// from, so the classification cannot drift away from what the predicate can
    /// actually reach.
    pub fn eval(&mut self, name: &str, arg: &str) -> Result<bool, LuaError> {
        let p = self
            .predicates
            .get(name)
            .ok_or_else(|| LuaError::LoadError(format!("no such predicate: {name}")))?;
        let class = p.class;
        let source = p.source.clone();
        let key = (name.to_string(), source.clone(), arg.to_string());

        if class.is_cacheable()
            && let Some(hit) = self.cache.get(&key)
            && hit.still_valid()
        {
            self.cache_hits += 1;
            return Ok(hit.verdict);
        }

        let reads = ReadLog::default();
        let lua = build_environment_logged(class, reads.clone())?;
        lua.load(&source)
            .exec()
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;
        let f: LuaFunction = lua
            .globals()
            .get(name)
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;
        let verdict: bool = f
            .call(arg.to_string())
            .map_err(|e| LuaError::VmError(format!("predicate {name}: {e}")))?;

        if class.is_cacheable() {
            let mut inputs = reads
                .lock()
                .map_err(|_| LuaError::VmError("predicate read log poisoned".into()))?
                .clone();
            inputs.sort();
            inputs.dedup();
            self.cache.insert(key, CacheEntry { verdict, inputs });
        }
        Ok(verdict)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Order 1470-dbuw: replacing source must never replay the old verdict.
    #[test]
    fn re_registering_a_predicate_invalidates_its_memo() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let rel = format!("target/lua-source-replace-{}.txt", std::process::id());
        let file = root.join(&rel);
        std::fs::create_dir_all(file.parent().expect("parent")).expect("mkdir target");
        std::fs::write(&file, "same").expect("write unchanged input");

        let mut reg = PredicateRegistry::new();
        reg.register(
            "changed",
            PredicateClass::Cacheable,
            "function changed(p) return fs.read(p) == 'same' end",
        )
        .expect("register first source");
        assert!(reg.eval("changed", &rel).expect("first evaluation"));
        assert!(reg.eval("changed", &rel).expect("cached evaluation"));
        assert_eq!(reg.cache_hits, 1);

        reg.register(
            "changed",
            PredicateClass::Cacheable,
            "function changed(p) return fs.read(p) == 'different' end",
        )
        .expect("register replacement source");
        assert!(!reg.eval("changed", &rel).expect("replacement evaluation"));
        assert_eq!(reg.cache_hits, 1, "replacement may not be a cache hit");
        std::fs::remove_file(file).expect("remove probe");
    }

    /// The read log captures observed bytes before a later file replacement.
    /// This is the deterministic read-then-write schedule behind 1470-dbuw.
    #[test]
    fn read_log_authenticates_bytes_returned_to_lua() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let rel = format!("target/lua-read-log-{}.txt", std::process::id());
        let file = root.join(&rel);
        std::fs::create_dir_all(file.parent().expect("parent")).expect("mkdir target");
        std::fs::write(&file, "before").expect("write first version");

        let reads = ReadLog::default();
        let lua = build_environment_logged(PredicateClass::Cacheable, reads.clone())
            .expect("pure environment");
        let observed: String = lua
            .load(format!("return fs.read('{rel}')"))
            .eval()
            .expect("read from Lua");
        assert_eq!(observed, "before");
        std::fs::write(&file, "after").expect("replace after read");

        let inputs = reads.lock().expect("read log").clone();
        assert_eq!(inputs.len(), 1, "one read must be recorded");
        let expected: [u8; 32] = Sha256::digest(b"before").into();
        assert_eq!(inputs[0].digest, Some(expected));
        assert!(
            !CacheEntry {
                verdict: true,
                inputs,
            }
            .still_valid(),
            "a verdict over old bytes cannot validate against new bytes"
        );
        std::fs::remove_file(file).expect("remove probe");
    }

    /// Review of 1367-q9yc (b): the filesystem root is never a repository root,
    /// so a cwd of `/` cannot turn every absolute path into an "inside" one.
    #[test]
    fn the_filesystem_root_is_refused_as_a_repository_root() {
        let err = validate_repo_root(PathBuf::from("/")).unwrap_err();
        assert!(
            err.contains("refused") && err.contains("filesystem root"),
            "{err}"
        );
        let missing = validate_repo_root(PathBuf::from("/definitely/not/a/dir/1367")).unwrap_err();
        assert!(missing.contains("unresolvable"), "{missing}");
        assert!(validate_repo_root(std::env::temp_dir()).is_ok());
    }

    /// ORDER 1411-b5fk. The macOS shape on any Unix: the root is canonical, the
    /// request arrives through a SYMLINKED ALIAS of it (as `/var/folders/…`
    /// reaches `/private/var/folders/…`). Pre-fix this was refused as "outside
    /// the repository root" and the archiver test failed on every Mac.
    #[cfg(unix)]
    #[test]
    fn a_write_through_a_symlinked_alias_of_the_root_is_inside() {
        let dir = tempfile::tempdir().expect("tempdir");
        let real = dir.path().join("real");
        std::fs::create_dir(&real).expect("mkdir real");
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&real, &alias).expect("symlink alias");
        let root = real.canonicalize().expect("canonical root");
        // A path that does not exist yet, spelled through the alias.
        let req = alias.join("plan").join("archive");
        let got = resolve_write_path(&root, req.to_str().unwrap(), "fs.mkdir");
        assert!(
            got.is_ok(),
            "a symlinked alias of the root is inside it: {got:?}"
        );
    }

    /// The escape check keeps its teeth: a symlink INSIDE the root that points
    /// OUTSIDE it is still refused, both for a new path under it and for reads.
    #[cfg(unix)]
    #[test]
    fn a_symlink_escaping_the_root_is_still_refused() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root_dir = dir.path().join("root");
        let outside = dir.path().join("outside");
        std::fs::create_dir(&root_dir).expect("mkdir root");
        std::fs::create_dir(&outside).expect("mkdir outside");
        std::os::unix::fs::symlink(&outside, root_dir.join("escape")).expect("symlink escape");
        let root = root_dir.canonicalize().expect("canonical root");
        let req = root.join("escape").join("new-file");
        let got = resolve_write_path(&root, req.to_str().unwrap(), "fs.write");
        assert!(
            got.is_err(),
            "a symlink resolving outside the root must be refused: {got:?}"
        );
        assert!(
            !containment_path(&req).is_some_and(|c| c.starts_with(&root)),
            "containment must see through the escaping symlink"
        );
    }

    /// ORDER 1412-n5cp. A DANGLING in-root link to an outside path is refused
    /// by the SANDBOX for every write verb, and named as unresolvable. Pre-fix,
    /// every one of these was admitted (safe only by how the verbs wrote).
    #[cfg(unix)]
    #[test]
    fn a_dangling_in_root_symlink_is_refused_by_every_write_verb() {
        let dir = tempfile::tempdir().expect("tempdir");
        let root_dir = dir.path().join("root");
        let outside = dir.path().join("outside");
        std::fs::create_dir(&root_dir).expect("mkdir root");
        std::fs::create_dir(&outside).expect("mkdir outside");
        std::os::unix::fs::symlink(outside.join("newfile"), root_dir.join("x"))
            .expect("dangling symlink");
        let root = root_dir.canonicalize().expect("canonical root");
        for verb in ["fs.write", "fs.mkdir", "fs.list", "fs.exists"] {
            for req in [root.join("x"), root.join("x").join("sub")] {
                let got = resolve_write_path(&root, req.to_str().unwrap(), verb);
                let err = got.expect_err(&format!("{verb} admitted {}", req.display()));
                assert!(err.contains("cannot be resolved"), "{verb}: {err}");
            }
        }
        assert!(containment_path(&root.join("x")).is_none());
        // A plain absent path (no link) is still resolvable and inside.
        assert!(resolve_write_path(&root, root.join("new").to_str().unwrap(), "fs.write").is_ok());
    }
}
