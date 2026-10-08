// @trace order:1384-bqhy, order:1539-dt84
//
// script_run.rs — `tillandsias-plan script run <file.lua>`: the ONE runner for a
// Lua decider, and `classify`, the ONE classifier of a decider's outcome.
//
// DESIGN: plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md §4.4
// (verdicts), §6.2 (coexistence), §6.4 (build.sh as a launcher).
//
// THE VERDICT. A decider ends by calling one of
//
//   verdict.ok(name, ...)             stdout `ok:<name>[:<arg>...]`            exit 0
//   verdict.skip(name, ...)           stdout `skip:<name>[:<arg>...]`          exit 0
//   verdict.advisory(line)             stdout `<line> (advisory)`               exit 0
//   verdict.refused(name, detail?)    stdout `refused:<name>`, detail on stderr exit 1
//   verdict.blocked(name, detail?)    stdout `blocked:<name>`, detail on stderr exit 2
//   verdict.could_not_run(name, d?)   stdout `could-not-run:<name>`, d on stderr exit 3
//
// which is the exit vocabulary build.sh already branches on, so no consumer
// changes. The verdict ENDS the script (the first call wins). A script that
// returns without one exits 1 printing `refused:no-verdict:<name>`: a silent
// green is unconstructible, which is the whole reason a runner exists instead
// of `lua file.lua` (1374-4u6i, 1174-jd8n: an empty answer read as ok).
//
// THE CLASSIFIER. Before this, the gate loop and the preflight door each read a
// guard's outcome with their own greps over merged text, and 1359-qf3p is the
// door passing what the gate refuses. `classify` is the one function both reach
// (through `script classify` from build.sh, through `verdict.classify` from Lua).
//
// ORDER 1534-puyz adds script-owned proc.spawn and line callbacks using mlua
// async. Composition/on_exit and original 1384-aixy's remaining closure stay
// with followup 1538; this runner does not claim native platform measurement.

use crate::lua_predicate::PredicateClass;
use mlua::prelude::*;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The outcome classes a runner reports. The preflight door books each into
/// one of its counters; the gate loop names it when it refuses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Ok,
    /// the guard reported an advisory outcome (`… (advisory)`), never a failure
    Advisory,
    /// the guard ran and named its own skip (`skip:` line) — never a failure
    Skip,
    /// the guard ran and said it could not ask (`could-not-run:` line)
    CouldNotRun,
    /// the guard outlived its deadline (rc 124, or status=timed_out)
    TimedOut,
    /// the RUNNER could not start it (rc 127, or `<x>: not found`)
    CannotStart,
    /// the runner ran out of disk (`No space left on device`)
    NoSpace,
    /// anything else non-zero: the guard refused the tree
    Refused,
}

impl Kind {
    pub fn token(self) -> &'static str {
        match self {
            Kind::Ok => "ok",
            Kind::Advisory => "advisory",
            Kind::Skip => "skip",
            Kind::CouldNotRun => "could-not-run",
            Kind::TimedOut => "timed-out",
            Kind::CannotStart => "cannot-start",
            Kind::NoSpace => "no-space",
            Kind::Refused => "refused",
        }
    }
}

fn line_starts(text: &str, prefix: &str) -> bool {
    text.lines().any(|l| l.starts_with(prefix))
}

/// `<name>: not found` / `<name>: command not found`, optionally after `exec: `
/// — the door's `(^|: )(exec: )?[A-Za-z0-9_.-]+: (not found|command not found)$`.
fn runner_not_found(text: &str) -> bool {
    text.lines().any(|l| {
        let l = l.trim_end();
        let rest = if let Some(r) = l.strip_suffix(": command not found") {
            r
        } else if let Some(r) = l.strip_suffix(": not found") {
            r
        } else {
            return false;
        };
        // the token before the suffix, after the last ": " (or the whole line)
        let tok = rest.rsplit(": ").next().unwrap_or(rest);
        let tok = tok.strip_prefix("exec: ").unwrap_or(tok);
        !tok.is_empty()
            && tok
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
    })
}

/// THE classifier. `rc` is the guard's exit status, `status` the runner's own
/// status word when it has one (`timed_out`), `text` the guard's captured output.
///
/// PRECEDENCE IS THE DOOR'S, and it is load-bearing (build.sh comments, kept):
/// a named `skip:` wins over `could-not-run:` (check-gate-memory-floor prints
/// both and RAN); the guard's own words win over the runner's rc; rc 124 is a
/// deadline only when the guard said neither.
pub fn classify(rc: i32, status: Option<&str>, text: &str) -> Kind {
    // Advisory lines are deliberately verbatim legacy interfaces rather than a
    // new prefix. Only a successful, non-timeout run may report one: otherwise
    // an advisory-looking diagnostic could mask the established failure order.
    if rc == 0 && status != Some("timed_out") && text.lines().any(|l| l.ends_with(" (advisory)")) {
        return Kind::Advisory;
    }
    if rc == 0 && status != Some("timed_out") {
        return Kind::Ok;
    }
    if line_starts(text, "skip:") {
        return Kind::Skip;
    }
    if line_starts(text, "could-not-run:") {
        return Kind::CouldNotRun;
    }
    if rc == 124 || status == Some("timed_out") {
        return Kind::TimedOut;
    }
    if rc == 127 || runner_not_found(text) {
        return Kind::CannotStart;
    }
    if text.contains("No space left on device") {
        return Kind::NoSpace;
    }
    Kind::Refused
}

/// A verdict as recorded by the script.
#[derive(Debug, Clone)]
struct Verdict {
    line: String,
    detail: Option<String>,
    code: i32,
}

const VERDICT_EXIT: &str = "\u{1}tillandsias-verdict-exit";

/// Parse `5s`, `200ms`, `2m`, or a bare number of seconds.
pub fn parse_duration(s: &str) -> Option<Duration> {
    let s = s.trim();
    let (num, mult_ms) = if let Some(n) = s.strip_suffix("ms") {
        (n, 1u64)
    } else if let Some(n) = s.strip_suffix('s') {
        (n, 1000)
    } else if let Some(n) = s.strip_suffix('m') {
        (n, 60_000)
    } else {
        (s, 1000)
    };
    num.parse::<u64>()
        .ok()
        .map(|n| Duration::from_millis(n * mult_ms))
}

/// The script's header block: leading `--` comment lines may declare
/// `-- @class cacheable|observing` and `-- @env NAME NAME ...`.
#[derive(Debug, Default, Clone)]
pub struct Header {
    pub cacheable: bool,
    pub env: Vec<String>,
    /// `-- @read-env NAME ...`: env vars whose VALUE (a file or directory)
    /// widens fs.read / fs.walk beyond the repo, read-only, Observing only
    /// (1384-ddua, coordinator ruling 2026-09-30).
    pub read_env: Vec<String>,
}

pub fn parse_header(src: &str) -> Header {
    let mut h = Header::default();
    for l in src.lines() {
        let t = l.trim();
        if t.starts_with("#!") || t.is_empty() {
            continue;
        }
        let Some(c) = t.strip_prefix("--") else { break };
        let c = c.trim();
        if let Some(v) = c.strip_prefix("@class") {
            h.cacheable = v.trim() == "cacheable";
        } else if let Some(v) = c.strip_prefix("@read-env") {
            h.read_env.extend(v.split_whitespace().map(str::to_string));
        } else if let Some(v) = c.strip_prefix("@env") {
            h.env.extend(v.split_whitespace().map(str::to_string));
        }
    }
    h
}

/// The name a verdict-less script is refused under: the file stem.
pub fn script_name(path: &str) -> String {
    let base = path.rsplit('/').next().unwrap_or(path);
    base.strip_suffix(".lua").unwrap_or(base).to_string()
}

fn verdict_value_str(v: &LuaValue) -> Option<String> {
    match v {
        LuaValue::Nil => None,
        LuaValue::String(s) => Some(s.to_string_lossy().to_string()),
        LuaValue::Integer(i) => Some(i.to_string()),
        LuaValue::Number(n) => Some(if n.fract() == 0.0 && n.abs() < 1e15 {
            format!("{}", *n as i64)
        } else {
            n.to_string()
        }),
        LuaValue::Boolean(b) => Some(b.to_string()),
        other => Some(format!("<{}>", other.type_name())),
    }
}

/// The canonical read roots this run widened to, for the trace and the timing
/// record (1384-ddua: "the run trace records every widened read root").
static READ_ROOTS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Regular files under `base`, recursively, relative to it, symlinks not followed.
fn walk_files(base: &std::path::Path, suffix: Option<&str>) -> Vec<String> {
    let mut found = Vec::new();
    let mut stack = vec![base.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let p = e.path();
            if ft.is_dir() {
                stack.push(p);
            } else if ft.is_file() {
                let rel = p
                    .strip_prefix(base)
                    .unwrap_or(&p)
                    .to_string_lossy()
                    .replace('\\', "/");
                if suffix.is_none_or(|x| rel.ends_with(x)) {
                    found.push(rel);
                }
            }
        }
    }
    found
}

/// Register verdict, log, out, text and (observing only) env.
fn register(
    lua: &Lua,
    name: &str,
    header: &Header,
    slot: Arc<Mutex<Option<Verdict>>>,
    host: &crate::lua_predicate::script_process::Host,
) -> LuaResult<()> {
    let g = lua.globals();
    let verdict = lua.create_table()?;

    // ok / skip: every argument after the name joins the line with ':'.
    for (kind, code) in [("ok", 0), ("skip", 0)] {
        let slot = slot.clone();
        let scope = host.scope.clone();
        verdict.set(
            kind,
            lua.create_function(move |_, args: LuaMultiValue| {
                let mut parts: Vec<String> = vec![kind.to_string()];
                for v in args.iter() {
                    if let Some(s) = verdict_value_str(v) {
                        parts.push(s);
                    }
                }
                if parts.len() < 2 {
                    return Err(LuaError::RuntimeError(format!(
                        "verdict.{kind}: a verdict needs a name (verdict.{kind}(\"name\", ...))"
                    )));
                }
                slot.lock().unwrap().get_or_insert(Verdict {
                    line: parts.join(":"),
                    detail: None,
                    code,
                });
                scope.close();
                Err::<(), _>(LuaError::RuntimeError(VERDICT_EXIT.to_string()))
            })?,
        )?;
    }
    // An advisory is a successful report whose established output is not a
    // house-prefix verdict. Keep it verbatim: consumers grep this line.
    {
        let slot = slot.clone();
        let scope = host.scope.clone();
        verdict.set(
            "advisory",
            lua.create_function(move |_, line: String| {
                if !line.ends_with(" (advisory)") {
                    return Err(LuaError::RuntimeError(
                        "verdict.advisory: line must end with ' (advisory)'".into(),
                    ));
                }
                if line.contains(['\n', '\r']) {
                    return Err(LuaError::RuntimeError(
                        "verdict.advisory: line must not contain a newline or carriage return"
                            .into(),
                    ));
                }
                slot.lock().unwrap().get_or_insert(Verdict {
                    line,
                    detail: None,
                    code: 0,
                });
                scope.close();
                Err::<(), _>(LuaError::RuntimeError(VERDICT_EXIT.to_string()))
            })?,
        )?;
    }
    // refused / blocked / could_not_run: the line is kind:name, detail to stderr.
    for (key, kind, code) in [
        ("refused", "refused", 1),
        ("blocked", "blocked", 2),
        ("could_not_run", "could-not-run", 3),
    ] {
        let slot = slot.clone();
        let scope = host.scope.clone();
        verdict.set(
            key,
            lua.create_function(move |_, (n, detail): (LuaValue, LuaValue)| {
                let Some(n) = verdict_value_str(&n) else {
                    return Err(LuaError::RuntimeError(format!(
                        "verdict.{key}: a verdict needs a name"
                    )));
                };
                slot.lock().unwrap().get_or_insert(Verdict {
                    line: format!("{kind}:{n}"),
                    detail: verdict_value_str(&detail),
                    code,
                });
                scope.close();
                Err::<(), _>(LuaError::RuntimeError(VERDICT_EXIT.to_string()))
            })?,
        )?;
    }
    // verdict.emit(line, code, detail?): a LEGACY verdict line with its own
    // exit code, for a byte-identical port whose grammar predates the house
    // mapping (check-bash-dialect prints `blocked:…` with exit 1). The line
    // must still start with a known kind, so classify reads it as before.
    {
        let slot = slot.clone();
        let scope = host.scope.clone();
        verdict.set(
            "emit",
            lua.create_function(move |_, (line, code, detail): (String, i32, LuaValue)| {
                let kind_ok = ["ok:", "skip:", "refused:", "blocked:", "could-not-run:", "violation:"]
                    .iter()
                    .any(|k| line.starts_with(k));
                if !kind_ok || !(0..=3).contains(&code) {
                    return Err(LuaError::RuntimeError(format!(
                        "verdict.emit: '{line}' with code {code} — the line must start with ok:/skip:/refused:/blocked:/could-not-run:/violation: and the code be 0-3"
                    )));
                }
                slot.lock().unwrap().get_or_insert(Verdict {
                    line,
                    detail: verdict_value_str(&detail),
                    code,
                });
                scope.close();
                Err::<(), _>(LuaError::RuntimeError(VERDICT_EXIT.to_string()))
            })?,
        )?;
    }
    // verdict.classify{rc=, status=, text=} -> kind token: THE classifier.
    verdict.set(
        "classify",
        lua.create_function(|_, spec: LuaTable| {
            let rc: i32 = spec.get::<Option<i32>>("rc")?.unwrap_or(0);
            let status: Option<String> = spec.get("status")?;
            let text: String = spec.get::<Option<String>>("text")?.unwrap_or_default();
            Ok(classify(rc, status.as_deref(), &text).token())
        })?,
    )?;
    g.set("verdict", verdict)?;

    // log: stderr, prefixed with the script's name. Never on stdout, where the
    // verdict line is the contract.
    let log = lua.create_table()?;
    for level in ["info", "warn", "error"] {
        let who = name.to_string();
        log.set(
            level,
            lua.create_function(move |_, msg: String| {
                eprintln!("[{who}] {level}: {msg}");
                Ok(())
            })?,
        )?;
    }
    // log.raw(s): one unprefixed stderr line, for a port whose diagnostics
    // are part of its contract (1384-ddua).
    log.set(
        "raw",
        lua.create_function(|_, msg: String| {
            eprintln!("{msg}");
            Ok(())
        })?,
    )?;
    g.set("log", log)?;

    // out.line(s): one line on stdout, for a decider that reports (note: lines).
    let out = lua.create_table()?;
    out.set(
        "line",
        lua.create_function(|_, s: String| {
            println!("{s}");
            Ok(())
        })?,
    )?;
    g.set("out", out)?;

    // text: the operations a shell decider reached for grep/cut/wc for. Pure.
    let text = lua.create_table()?;
    text.set(
        "lines",
        lua.create_function(|lua, s: String| {
            let t = lua.create_table()?;
            for (i, l) in s.lines().enumerate() {
                t.set(i + 1, l)?;
            }
            Ok(t)
        })?,
    )?;
    text.set(
        "split",
        lua.create_function(|lua, (s, sep): (String, String)| {
            if sep.is_empty() {
                return Err(LuaError::RuntimeError("text.split: empty separator".into()));
            }
            let t = lua.create_table()?;
            for (i, p) in s.split(sep.as_str()).enumerate() {
                t.set(i + 1, p)?;
            }
            Ok(t)
        })?,
    )?;
    text.set(
        "trim",
        lua.create_function(|_, s: String| Ok(s.trim().to_string()))?,
    )?;
    text.set(
        "starts_with",
        lua.create_function(|_, (s, p): (String, String)| Ok(s.starts_with(&p)))?,
    )?;
    text.set(
        "contains",
        lua.create_function(|_, (s, p): (String, String)| Ok(s.contains(&p)))?,
    )?;
    // ORDER 1384-ddua — the operations the pilot deciders reached for grep,
    // sed and wc for, as pure functions over strings. The regex engine is
    // Rust's on every host: no `\b`-on-BSD silence, no GNU/BSD flag split.
    // Compiled ONCE per pattern per run: the awk-state-machine ports call
    // is_match per line, and recompiling made check-bash-dialect.lua miss the
    // door's 5 s deadline that the .sh met (1384-ddua).
    let re_of = |name: &'static str, pat: &str| -> LuaResult<regex::Regex> {
        thread_local! {
            static CACHE: std::cell::RefCell<std::collections::HashMap<String, regex::Regex>> =
                std::cell::RefCell::new(std::collections::HashMap::new());
        }
        CACHE.with(|c| {
            if let Some(r) = c.borrow().get(pat) {
                return Ok(r.clone());
            }
            let r = regex::Regex::new(pat)
                .map_err(|e| LuaError::RuntimeError(format!("text.{name}: bad regex: {e}")))?;
            c.borrow_mut().insert(pat.to_string(), r.clone());
            Ok(r)
        })
    };
    text.set(
        "escape",
        lua.create_function(|_, s: String| Ok(regex::escape(&s)))?,
    )?;
    // count_lines(s, re): lines of s matching re — `grep -c` semantics, an
    // integer rather than an exit status, so there is no consumer to SIGPIPE.
    text.set(
        "count_lines",
        lua.create_function(move |_, (s, pat): (String, String)| {
            let re = re_of("count_lines", &pat)?;
            Ok(s.lines().filter(|l| re.is_match(l)).count() as i64)
        })?,
    )?;
    // first_match(s, re, {lines = n}?): the first matching line (within the
    // first n lines when given), or nil.
    text.set(
        "first_match",
        lua.create_function(
            move |_, (s, pat, opts): (String, String, Option<LuaTable>)| {
                let re = re_of("first_match", &pat)?;
                let limit = match opts {
                    Some(o) => o.get::<Option<usize>>("lines")?.unwrap_or(usize::MAX),
                    None => usize::MAX,
                };
                Ok(s.lines()
                    .take(limit)
                    .find(|l| re.is_match(l))
                    .map(str::to_string))
            },
        )?,
    )?;
    text.set(
        "is_match",
        lua.create_function(move |_, (s, pat): (String, String)| {
            Ok(re_of("is_match", &pat)?.is_match(&s))
        })?,
    )?;
    // captures_all(s, re): capture group 1 of every non-overlapping match, in order.
    text.set(
        "captures_all",
        lua.create_function(move |lua, (s, pat): (String, String)| {
            let re = re_of("captures_all", &pat)?;
            let t = lua.create_table()?;
            for (i, c) in re.captures_iter(&s).enumerate() {
                t.set(i + 1, c.get(1).map(|m| m.as_str()).unwrap_or(""))?;
            }
            Ok(t)
        })?,
    )?;
    // find(s, re): 1-based inclusive (start, end) of the first match, or nil —
    // awk's RSTART/RLENGTH, for ports of awk state machines.
    text.set(
        "find",
        lua.create_function(move |_, (s, pat): (String, String)| {
            Ok(match re_of("find", &pat)?.find(&s) {
                Some(m) => (Some(m.start() as i64 + 1), Some(m.end() as i64)),
                None => (None, None),
            })
        })?,
    )?;
    // strip_line_comments(s, marker): each line cut at the first marker —
    // `sed 's://.*::'` semantics, without the fork.
    text.set(
        "strip_line_comments",
        lua.create_function(|_, (s, marker): (String, String)| {
            if marker.is_empty() {
                return Err(LuaError::RuntimeError(
                    "text.strip_line_comments: empty marker".into(),
                ));
            }
            let mut out = String::with_capacity(s.len());
            for l in s.split_inclusive('\n') {
                match l.find(marker.as_str()) {
                    Some(i) => {
                        out.push_str(&l[..i]);
                        if l.ends_with('\n') {
                            out.push('\n');
                        }
                    }
                    None => out.push_str(l),
                }
            }
            Ok(out)
        })?,
    )?;
    g.set("text", text)?;

    // env.get(name): DECLARED names only (`-- @env NAME ...`); os.getenv stays
    // gone. Observing only — an environment read is not pure.
    if !header.cacheable {
        // fs.walk(dir, {suffix = ".rs"}?): every regular FILE under dir,
        // recursively, as repo-relative paths in byte order; symlinks are not
        // followed (GNU `grep -r` semantics, which BSD differs from: 1087-h2z9).
        // OBSERVING ONLY: a directory listing is not content-addressed, so a
        // cacheable script could not be memoised soundly over it.
        // ORDER 1384-ddua — DECLARED READ ROOTS. Each `-- @read-env NAME`
        // whose value is set becomes one canonical (realpath) root that fs.read
        // and fs.walk may read under, read-only. A path is judged by ITS OWN
        // realpath, so a symlink inside a root that points outside it is
        // refused. Nothing undeclared widens anything: an absolute path outside
        // the repo and every root falls through to lua_predicate's repo-rooted
        // fs.read, which refuses it.
        let roots: Vec<std::path::PathBuf> = header
            .read_env
            .iter()
            .filter_map(std::env::var_os)
            .filter(|v| !v.is_empty())
            .filter_map(|v| std::fs::canonicalize(v).ok())
            .collect();
        if let Ok(mut r) = READ_ROOTS.lock() {
            *r = roots.iter().map(|p| p.display().to_string()).collect();
        }
        let within = {
            let roots = roots.clone();
            move |p: &str| -> Option<std::path::PathBuf> {
                let c = std::fs::canonicalize(p).ok()?;
                roots.iter().any(|r| c.starts_with(r)).then_some(c)
            }
        };
        if let Ok(fs_t) = g.get::<LuaTable>("fs") {
            if !roots.is_empty() {
                let orig: LuaFunction = fs_t.get("read")?;
                let within = within.clone();
                fs_t.set(
                    "read",
                    lua.create_function(move |_, p: String| {
                        if std::path::Path::new(&p).is_absolute()
                            && let Some(c) = within(&p)
                        {
                            return std::fs::read_to_string(&c)
                                .map_err(|e| LuaError::RuntimeError(format!("fs.read: {p}: {e}")));
                        }
                        orig.call::<String>(p)
                    })?,
                )?;
            }
            let within = within.clone();
            fs_t.set(
                "walk",
                lua.create_function(move |lua, (dir, opts): (String, Option<LuaTable>)| {
                    if std::path::Path::new(&dir).is_absolute() {
                        // An absolute path is walkable when its realpath is inside
                        // the repo (a fixture's target/plan-scratch) or inside a
                        // declared read root; anywhere else is refused.
                        let in_repo = crate::lua_predicate::find_repo_root()
                            .ok()
                            .and_then(|r| std::fs::canonicalize(&dir).ok().filter(|c| c.starts_with(&r)));
                        let Some(base) = in_repo.or_else(|| within(&dir)) else {
                            return Err(LuaError::RuntimeError(format!(
                                "fs.walk: '{dir}' is outside the repo and every declared read root (-- @read-env)"
                            )));
                        };
                        let suffix: Option<String> = match opts {
                            Some(o) => o.get("suffix")?,
                            None => None,
                        };
                        let mut found = walk_files(&base, suffix.as_deref());
                        found.sort();
                        let t = lua.create_table()?;
                        for (i, f) in found.into_iter().enumerate() {
                            // prefixed by the dir AS THE CALLER SPELLED IT, so a
                            // port prints the same paths the shell form did.
                            t.set(i + 1, format!("{}/{}", dir.trim_end_matches('/'), f))?;
                        }
                        return Ok(t);
                    }
                    let root = crate::lua_predicate::find_repo_root().map_err(LuaError::RuntimeError)?;
                    if dir.starts_with('/') || dir.split('/').any(|c| c == "..") {
                        return Err(LuaError::RuntimeError(format!(
                            "fs.walk: '{dir}' must be repo-relative, without '..'"
                        )));
                    }
                    // @trace order:1532-u9en
                    // read_dir follows the START path (including intermediate
                    // symlinks), unlike DirEntry::file_type below. Check its
                    // resolved containment before enumerating names. Keep the
                    // caller's spelling for presentation and do not follow
                    // descendant links. This does not claim TOCTOU protection.
                    let start = root.join(&dir);
                    let resolved = crate::lua_predicate::containment_path(&start);
                    if !resolved.is_some_and(|p| p.starts_with(&root)) {
                        return Err(LuaError::RuntimeError(format!(
                            "fs.walk: '{dir}' resolves outside the repository root or cannot be resolved"
                        )));
                    }
                    let suffix: Option<String> = match opts {
                        Some(o) => o.get("suffix")?,
                        None => None,
                    };
                    let mut found: Vec<String> = Vec::new();
                    let mut stack = vec![start];
                    while let Some(d) = stack.pop() {
                        let Ok(rd) = std::fs::read_dir(&d) else { continue };
                        for e in rd.flatten() {
                            let Ok(ft) = e.file_type() else { continue };
                            let p = e.path();
                            if ft.is_dir() {
                                stack.push(p);
                            } else if ft.is_file() {
                                let rel = p.strip_prefix(&root).unwrap_or(&p).to_string_lossy().replace('\\', "/");
                                if suffix.as_deref().is_none_or(|x| rel.ends_with(x)) {
                                    found.push(rel);
                                }
                            }
                        }
                    }
                    found.sort();
                    let t = lua.create_table()?;
                    for (i, f) in found.into_iter().enumerate() {
                        t.set(i + 1, f)?;
                    }
                    Ok(t)
                })?,
            )?;
        }
        let env = lua.create_table()?;
        let declared = header.env.clone();
        env.set(
            "get",
            lua.create_function(move |_, n: String| {
                if !declared.iter().any(|d| d == &n) {
                    return Err(LuaError::RuntimeError(format!(
                        "env.get: '{n}' is not declared; add it to the header: -- @env {n}"
                    )));
                }
                Ok(std::env::var(&n).ok())
            })?,
        )?;
        g.set("env", env)?;
    }
    Ok(())
}

/// Run one script to its verdict. Returns (stdout line, stderr detail, exit).
fn run_to_verdict(
    path: &str,
    src: &str,
    args: &[String],
    host: crate::lua_predicate::script_process::Host,
) -> (String, Option<String>, i32) {
    let name = script_name(path);
    let header = parse_header(src);
    let class = if header.cacheable {
        PredicateClass::Cacheable
    } else {
        PredicateClass::Observing
    };
    let lua = match crate::lua_predicate::build_environment(class) {
        Ok(l) => l,
        Err(e) => {
            return (
                format!("could-not-run:{name}"),
                Some(format!("the Lua environment could not be built: {e}")),
                3,
            );
        }
    };
    let slot: Arc<Mutex<Option<Verdict>>> = Arc::new(Mutex::new(None));
    if let Err(e) = host
        .install(&lua)
        .and_then(|_| register(&lua, &name, &header, slot.clone(), &host))
    {
        return (
            format!("could-not-run:{name}"),
            Some(format!("the runner's tables could not be registered: {e}")),
            3,
        );
    }
    if let Ok(t) = lua.create_table() {
        let _ = t.set(0, path);
        for (i, a) in args.iter().enumerate() {
            let _ = t.set((i + 1) as i64, a.as_str());
        }
        let _ = lua.globals().set("arg", t);
    }
    // A shebang line becomes a comment, so line numbers in errors stay true.
    let body = match src.strip_prefix("#!") {
        Some(rest) => format!("--{rest}"),
        None => src.to_string(),
    };
    // @trace order:1534-puyz
    // A caught verdict/error cannot keep executing or launch a new child. The
    // independent supervisors enforce cancellation even before this hook runs.
    let scope = host.scope.clone();
    lua.set_hook(
        mlua::HookTriggers::new().every_nth_instruction(1000),
        move |_, _| {
            if scope.stopped() {
                Err(LuaError::RuntimeError("script-scope-closed".into()))
            } else {
                Ok(mlua::VmState::Continue)
            }
        },
    );
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            return (
                format!("could-not-run:{name}"),
                Some(format!("runtime: {e}")),
                3,
            );
        }
    };
    // Lua::set_hook covers the main VM thread, NOT the async coroutine. Install
    // explicitly on that coroutine too (caught verdict + CPU loop regression).
    let res = match lua
        .load(&body)
        .set_name(path)
        .into_function()
        .and_then(|f| lua.create_thread(f))
    {
        Ok(thread) => {
            let scope = host.scope.clone();
            thread.set_hook(
                mlua::HookTriggers::new().every_nth_instruction(1000),
                move |_, _| {
                    if scope.stopped() {
                        Err(LuaError::RuntimeError("script-scope-closed".into()))
                    } else {
                        Ok(mlua::VmState::Continue)
                    }
                },
            );
            rt.block_on(thread.into_async::<()>(()))
        }
        Err(e) => Err(e),
    };
    // ORDER 1551-7hyq. Test-only seam: end the script worker WITHOUT a
    // verdict, after the script ran and before its scope is cleaned up, which
    // is where an unwinding panic would skip that cleanup. Compiled into debug
    // builds only (`cfg(debug_assertions)`); a release binary has neither the
    // branch nor the variable name.
    #[cfg(debug_assertions)]
    if std::env::var_os("TILLANDSIAS_TEST_SCRIPT_WORKER_PANIC").is_some() {
        panic!("script-worker-panic: forced by TILLANDSIAS_TEST_SCRIPT_WORKER_PANIC");
    }
    host.scope.close();
    let cleanup = host.scope.cleanup();
    host.release_callbacks();
    rt.shutdown_background();
    if let Err(e) = cleanup {
        return (format!("refused:cleanup-incomplete:{name}"), Some(e), 1);
    }
    if let Some(v) = slot.lock().unwrap().clone() {
        return (v.line, v.detail, v.code);
    }
    match res {
        Ok(()) => (
            format!("refused:no-verdict:{name}"),
            Some(format!(
                "{path} ended without calling verdict.ok/skip/refused/blocked/could_not_run — \
                  a decider that says nothing cannot be read as green (1384-bqhy)"
            )),
            1,
        ),
        Err(e) => (
            format!("refused:script-error:{name}"),
            Some(format!("{e}")),
            1,
        ),
    }
}

/// ORDER 1551-7hyq. `run_to_verdict` with a panic caught and named instead of
/// unwinding past the caller: `Err` carries the panic message, so the caller
/// can close and reap the scope and report a crash, never a timeout.
fn run_guarded(
    path: &str,
    src: &str,
    args: &[String],
    host: crate::lua_predicate::script_process::Host,
) -> Result<(String, Option<String>, i32), String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        run_to_verdict(path, src, args, host)
    }))
    .map_err(|payload| {
        payload
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "a panic with no message".to_owned())
    })
}

/// One JSON line into TILLANDSIAS_TIMING_LOG, and only there: a runner never
/// falls back to /tmp/tillandsias-timing.jsonl (1204-3s2s).
fn emit_timing(name: &str, line: &str, code: i32, elapsed: Duration) {
    let Some(p) = std::env::var_os("TILLANDSIAS_TIMING_LOG") else {
        return;
    };
    let rec = serde_json::json!({
        "kind": "script-run",
        "name": name,
        "verdict": line,
        "exit": code,
        "elapsed_ms": elapsed.as_millis() as u64,
        "read_roots": READ_ROOTS.lock().map(|r| r.clone()).unwrap_or_default(),
        "ts_ms": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
    });
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(p)
    {
        let _ = writeln!(f, "{rec}");
    }
}

/// ORDER 1551-n45s. A runner terminated from OUTSIDE takes what it started
/// with it.
///
/// Every script-owned child lives in its OWN process group — that is what lets
/// a deadline kill a whole guard — so a TERM, INT or HUP delivered to the
/// runner, or to the runner's group (which is how the preflight door stops a
/// guard that outlived its deadline), reached none of them. MEASURED before
/// this handler: `kill -TERM -<runner group>` ended the runner and left its
/// child alive and re-parented for the rest of its own sleep.
///
/// The handler closes the scope (bounded by the executor's CLEANUP_BOUND) and
/// exits 128+signal, the status a caller would have read from the unhandled
/// signal. It is installed BEFORE any script code runs and the caller waits
/// for that, so there is no window in which a child exists and the default
/// disposition still applies. Unix only: on Windows the job object owns this.
#[cfg(unix)]
fn reap_on_termination(host: crate::lua_predicate::script_process::Host) {
    use tokio::signal::unix::{SignalKind, signal};
    let (installed, wait) = std::sync::mpsc::channel::<()>();
    let spawned = std::thread::Builder::new()
        .name("script-signal".into())
        .spawn(move || {
            let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            let signo = rt.block_on(async {
                let (Ok(mut term), Ok(mut int), Ok(mut hup)) = (
                    signal(SignalKind::terminate()),
                    signal(SignalKind::interrupt()),
                    signal(SignalKind::hangup()),
                ) else {
                    return None;
                };
                let _ = installed.send(());
                Some(tokio::select! {
                    _ = term.recv() => libc::SIGTERM,
                    _ = int.recv() => libc::SIGINT,
                    _ = hup.recv() => libc::SIGHUP,
                })
            });
            let Some(signo) = signo else {
                return;
            };
            if let Err(e) = host.scope.cleanup() {
                eprintln!("{e}");
            }
            std::process::exit(128 + signo);
        });
    if spawned.is_ok() {
        // A failed install drops the sender, which ends this wait at once; the
        // runner then behaves as it did before (default dispositions).
        let _ = wait.recv_timeout(Duration::from_secs(1));
    }
}

/// `script run <file.lua> [--timeout <dur>] [--trace] [-- args...]`. Exits.
pub fn cli_run(args: &[String]) -> ! {
    let mut file: Option<String> = None;
    let mut timeout: Option<Duration> = None;
    let mut trace = false;
    let mut rest: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--timeout" => {
                let Some(d) = args.get(i + 1).and_then(|s| parse_duration(s)) else {
                    eprintln!("error: --timeout expects a duration (5s, 200ms, 2m) — REFUSED");
                    std::process::exit(2);
                };
                timeout = Some(d);
                i += 2;
            }
            "--trace" => {
                trace = true;
                i += 1;
            }
            "--" => {
                rest.extend(args[i + 1..].iter().cloned());
                break;
            }
            a if file.is_none() => {
                file = Some(a.to_string());
                i += 1;
            }
            a => {
                rest.push(a.to_string());
                i += 1;
            }
        }
    }
    let Some(path) = file else {
        eprintln!(
            "usage: tillandsias-plan script run <file.lua> [--timeout <dur>] [--trace] [-- args...]"
        );
        std::process::exit(2);
    };
    let name = script_name(&path);
    let src = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => {
            println!("could-not-run:{name}");
            eprintln!("  why: {path} could not be read: {e}");
            eprintln!(
                "  remedy: check the path the step or caller names (a missing .lua refuses, never skips)"
            );
            std::process::exit(3);
        }
    };
    let t0 = Instant::now();
    let deadline = timeout.and_then(|d| t0.checked_add(d));
    let host = crate::lua_predicate::script_process::Host::new(deadline);
    #[cfg(unix)]
    reap_on_termination(host.clone());
    // ORDER 1551-7hyq. A worker that ends WITHOUT a verdict (a panic) is a
    // crash and is reported as one: `refused:script-worker-died:<name>`, exit
    // 1, after the scope is closed and its children reaped. It used to share
    // the deadline's arm when --timeout was given (a dropped channel read as
    // an elapsed one: status=timed_out, exit 124, which the door files as
    // slowness), and without --timeout the panic unwound past the scope
    // cleanup. A verdict the script recorded before the crash is NOT reported:
    // the runner did not finish, so nothing it says can be green.
    let outcome = match timeout {
        None => run_guarded(&path, &src, &rest, host.clone()),
        Some(d) => {
            let (tx, rx) = std::sync::mpsc::channel();
            let (p2, s2, r2) = (path.clone(), src.clone(), rest.clone());
            let worker_host = host.clone();
            std::thread::spawn(move || {
                let _ = tx.send(run_guarded(&p2, &s2, &r2, worker_host));
            });
            match rx.recv_timeout(deadline.unwrap().saturating_duration_since(Instant::now())) {
                Ok(Err(died)) => Err(died),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    Err("the worker thread ended without sending an outcome".to_owned())
                }
                Ok(Ok(v)) if Instant::now() < deadline.unwrap() => Ok(v),
                _ => {
                    // Do not abandon the worker and exit with owned groups alive.
                    // Reap supervision is independent of Lua; joining arbitrary
                    // native/blocking Lua work is NOT claimed by this bounded door.
                    if let Err(e) = host.scope.cleanup() {
                        eprintln!("{e}");
                    }
                    println!("status=timed_out");
                    println!("refused:timed-out:{name}");
                    eprintln!(
                        "  why: {path} did not reach a verdict within {}ms",
                        d.as_millis()
                    );
                    eprintln!(
                        "  remedy: find what it waits on (run it with --trace), or raise --timeout if the work is genuinely that long"
                    );
                    emit_timing(&name, "status=timed_out", 124, t0.elapsed());
                    std::process::exit(124);
                }
            }
        }
    };
    let (line, detail, code) = match outcome {
        Ok(v) => v,
        Err(died) => {
            if let Err(e) = host.scope.cleanup() {
                eprintln!("{e}");
            }
            let line = format!("refused:script-worker-died:{name}");
            println!("{line}");
            eprintln!("  why: the runner's script worker ended without a verdict: {died}");
            eprintln!(
                "  remedy: this is a runner defect, not slowness and not the script's verdict — report it with the script and this message"
            );
            emit_timing(&name, &line, 1, t0.elapsed());
            std::process::exit(1);
        }
    };
    if trace {
        for record in host.terminal_trace() {
            eprintln!("trace:proc:{record}");
        }
        eprintln!(
            "[script-run] {name}: {line} exit={code} {}ms",
            t0.elapsed().as_millis()
        );
    }
    println!("{line}");
    if let Some(d) = detail {
        eprintln!("{d}");
    }
    emit_timing(&name, &line, code, t0.elapsed());
    std::process::exit(code);
}

/// `script classify --rc <n> [--status <s>] [--file <path>]` prints one kind.
pub fn cli_classify(args: &[String]) -> ! {
    let get = |k: &str| {
        args.iter()
            .position(|a| a == k)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let Some(rc) = get("--rc").and_then(|s| s.parse::<i32>().ok()) else {
        eprintln!(
            "usage: tillandsias-plan script classify --rc <n> [--status <s>] [--file <path>]"
        );
        std::process::exit(2);
    };
    let text = match get("--file") {
        Some(p) => std::fs::read(&p)
            .map(|b| String::from_utf8_lossy(&b).to_string())
            .unwrap_or_default(),
        None => String::new(),
    };
    println!(
        "{}",
        classify(rc, get("--status").as_deref(), &text).token()
    );
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_follows_the_doors_precedence() {
        assert_eq!(classify(0, None, ""), Kind::Ok);
        assert_eq!(
            classify(0, None, "centicolon: R=1 regime=baseline (advisory)"),
            Kind::Advisory
        );
        // An advisory-shaped diagnostic cannot hide a failure or timeout.
        assert_eq!(
            classify(1, None, "centicolon: R=1 regime=baseline (advisory)"),
            Kind::Refused
        );
        assert_eq!(
            classify(124, None, "centicolon: R=1 regime=baseline (advisory)"),
            Kind::TimedOut
        );
        assert_eq!(
            classify(127, None, "centicolon: R=1 regime=baseline (advisory)"),
            Kind::CannotStart
        );
        assert_eq!(
            classify(
                0,
                Some("timed_out"),
                "centicolon: R=1 regime=baseline (advisory)"
            ),
            Kind::TimedOut
        );
        assert_eq!(classify(1, None, "skip:x:y\ncould-not-run:x"), Kind::Skip);
        assert_eq!(
            classify(3, None, "could-not-run:gate-memory:no-meminfo"),
            Kind::CouldNotRun
        );
        assert_eq!(classify(124, None, "partial output"), Kind::TimedOut);
        assert_eq!(classify(0, Some("timed_out"), ""), Kind::TimedOut);
        assert_eq!(
            classify(1, None, "exec: setsid: not found"),
            Kind::CannotStart
        );
        assert_eq!(classify(127, None, ""), Kind::CannotStart);
        assert_eq!(
            classify(1, None, "write: No space left on device"),
            Kind::NoSpace
        );
        assert_eq!(
            classify(1, None, "refused:x — something is wrong"),
            Kind::Refused
        );
        // a guard that says "not found" about its SUBJECT is not a runner failure
        assert_eq!(
            classify(1, None, "violation: the key was not found in the file"),
            Kind::Refused
        );
    }

    #[test]
    fn header_declares_class_and_env() {
        let h = parse_header(
            "#!/usr/bin/env x\n-- @class cacheable\n-- @env HOME PATH\nlocal x = 1\n-- @env LATE\n",
        );
        assert!(h.cacheable);
        assert_eq!(h.env, vec!["HOME", "PATH"]);
    }

    #[test]
    fn durations_parse() {
        assert_eq!(parse_duration("200ms"), Some(Duration::from_millis(200)));
        assert_eq!(parse_duration("5s"), Some(Duration::from_secs(5)));
        assert_eq!(parse_duration("2m"), Some(Duration::from_secs(120)));
        assert_eq!(parse_duration("7"), Some(Duration::from_secs(7)));
        assert_eq!(parse_duration("x"), None);
    }
}
