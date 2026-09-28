//! ORDER 1443-we89 — THE TEMPORARY BRIDGE: classify a raw Bash-tool command
//! before it runs.
//!
//! The damage of an unquoted heredoc happens in the shell before any file
//! exists to lint: on 2026-09-27 fragments lost their backticked spans to
//! `<<EOF`, and one run EXECUTED `openspec init` and `openspec update` in a
//! protected checkout. No decider can see that; only the tool boundary can. This
//! is the boundary check, for Claude Code's PreToolUse hook on the Bash tool,
//! until agents call the runtime directly (1443-8pur, 1443-r4cj) and the Bash
//! tool stops being the default door. RETIREMENT_CONDITION says when.
//!
//! LEXICAL, NOT A PARSER, over the seven measured shapes (bash cannot be trusted
//! to parse bash; 1252-r72q's tree-sitter lint is the future parser):
//!   1 unquoted heredoc whose body carries a backtick or `$(`       deny
//!   2 pipefail + a pipeline ending in `grep -q` (SIGPIPE verdict)  deny
//!   3 a check-/test- script's verdict read through `| tail -1`     deny
//!   4 credential mutation (gh auth login|refresh|token, …)         deny
//!   5 destructive classes: resets, recursive rm outside the
//!     working dir / TMPDIR / scratch, force-push to a protected ref ask (the
//!     policy floor's own classes, 1443-isrk; a forge's soft reset is allowed)
//!   6 a shell string crossing a boundary (wsl.exe … bash -c "…",
//!     bash -c "…") that carries a pipe, a backtick or `$(`         deny
//!   7 a token-shaped literal on the command line                  deny
//! ANYTHING ELSE IS ALLOWED: a bridge that refuses what it does not understand
//! stops the fleet.

use crate::command_policy as cp;
use regex::Regex;
use std::path::{Path, PathBuf};

/// Printed by `--status` and pinned by the fixture.
pub const RETIREMENT_CONDITION: [&str; 3] = [
    "(a) 1443-8pur and 1443-r4cj are closed on every locus (agents call the runtime directly)",
    "(b) the audit shows zero deny and zero ask decisions from caller=pretooluse for 14 consecutive fleet days",
    "(c) the operator flips the Bash tool's default",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Ask,
    Deny,
}

impl Verdict {
    pub fn as_str(self) -> &'static str {
        match self {
            Verdict::Allow => "allow",
            Verdict::Ask => "ask",
            Verdict::Deny => "deny",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Classification {
    pub verdict: Verdict,
    /// The shape or class that decided; `allow` for an unmatched command.
    pub rule: String,
    /// One verdict line: refused:bash-policy:<rule> | consent:bash-policy:<class> | ok:bash-policy:allow
    pub token: String,
    pub why: Option<String>,
    pub remedy: Option<String>,
}

impl Classification {
    fn allow() -> Self {
        Classification {
            verdict: Verdict::Allow,
            rule: "allow".into(),
            token: "ok:bash-policy:allow".into(),
            why: None,
            remedy: None,
        }
    }
    fn deny(rule: &str, why: &str, remedy: &str) -> Self {
        Classification {
            verdict: Verdict::Deny,
            rule: rule.into(),
            token: format!("refused:bash-policy:{rule}"),
            why: Some(why.into()),
            remedy: Some(remedy.into()),
        }
    }
    fn ask(class: &str, why: String, remedy: String) -> Self {
        Classification {
            verdict: Verdict::Ask,
            rule: class.into(),
            token: format!("consent:bash-policy:{class}"),
            why: Some(why),
            remedy: Some(remedy),
        }
    }
}

/// Where the command runs and what counts as scratch.
#[derive(Debug, Clone)]
pub struct Context {
    pub cwd: PathBuf,
    pub host_kind: cp::HostKind,
    /// Roots under which a recursive rm needs no consent besides `cwd`:
    /// TMPDIR (or /tmp) and any TILLANDSIAS_PRETOOLUSE_SCRATCH entries.
    pub scratch: Vec<PathBuf>,
    pub protected: Vec<String>,
}

// ── lexing ──────────────────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct Lexed {
    /// Pipelines; each is a list of stages; each stage is an argv.
    pipelines: Vec<Vec<Vec<String>>>,
    /// (quoted delimiter?, body) per heredoc.
    heredocs: Vec<(bool, String)>,
}

/// A small shell lexer: quotes, backslashes, `$(…)`/backticks kept inside
/// words, the operators | || && ; & and newline, and heredoc bodies.
fn lex(cmd: &str) -> Lexed {
    let chars: Vec<char> = cmd.chars().collect();
    let mut out = Lexed::default();
    let mut pipeline: Vec<Vec<String>> = Vec::new();
    let mut stage: Vec<String> = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut pending: Vec<(String, bool, bool)> = Vec::new(); // (delim, quoted, strip_tabs)
    let mut expect_delim: Option<bool> = None; // Some(strip_tabs) right after << / <<-
    let mut i = 0;

    fn end_word(word: &mut String, in_word: &mut bool, stage: &mut Vec<String>) -> Option<String> {
        if *in_word {
            *in_word = false;
            let w = std::mem::take(word);
            stage.push(w.clone());
            return Some(w);
        }
        None
    }

    let flush_stage = |stage: &mut Vec<String>, pipeline: &mut Vec<Vec<String>>| {
        if !stage.is_empty() {
            pipeline.push(std::mem::take(stage));
        }
    };

    while i < chars.len() {
        let c = chars[i];
        match c {
            '\'' => {
                in_word = true;
                word.push('\'');
                i += 1;
                while i < chars.len() && chars[i] != '\'' {
                    word.push(chars[i]);
                    i += 1;
                }
                word.push('\'');
                i += 1;
            }
            '"' => {
                in_word = true;
                word.push('"');
                i += 1;
                while i < chars.len() && chars[i] != '"' {
                    if chars[i] == '\\' && i + 1 < chars.len() {
                        word.push(chars[i]);
                        i += 1;
                    }
                    word.push(chars[i]);
                    i += 1;
                }
                word.push('"');
                i += 1;
            }
            '\\' => {
                in_word = true;
                word.push('\\');
                if i + 1 < chars.len() {
                    word.push(chars[i + 1]);
                }
                i += 2;
            }
            '`' => {
                in_word = true;
                word.push('`');
                i += 1;
                while i < chars.len() && chars[i] != '`' {
                    word.push(chars[i]);
                    i += 1;
                }
                word.push('`');
                i += 1;
            }
            '$' if chars.get(i + 1) == Some(&'(') => {
                in_word = true;
                let mut depth = 0;
                while i < chars.len() {
                    let ch = chars[i];
                    word.push(ch);
                    if ch == '(' {
                        depth += 1;
                    } else if ch == ')' {
                        depth -= 1;
                        if depth == 0 {
                            i += 1;
                            break;
                        }
                    }
                    i += 1;
                }
            }
            '<' if chars.get(i + 1) == Some(&'<') && chars.get(i + 2) != Some(&'<') => {
                end_word(&mut word, &mut in_word, &mut stage);
                let strip = chars.get(i + 2) == Some(&'-');
                expect_delim = Some(strip);
                i += if strip { 3 } else { 2 };
            }
            ' ' | '\t' => {
                if let Some(w) = end_word(&mut word, &mut in_word, &mut stage)
                    && let Some(strip) = expect_delim.take()
                {
                    stage.pop();
                    let quoted = w.contains(['\'', '"', '\\']);
                    let d: String = w
                        .chars()
                        .filter(|c| !matches!(c, '\'' | '"' | '\\'))
                        .collect();
                    pending.push((d, quoted, strip));
                }
                i += 1;
            }
            '\n' => {
                if let Some(w) = end_word(&mut word, &mut in_word, &mut stage)
                    && let Some(strip) = expect_delim.take()
                {
                    stage.pop();
                    let quoted = w.contains(['\'', '"', '\\']);
                    let d: String = w
                        .chars()
                        .filter(|c| !matches!(c, '\'' | '"' | '\\'))
                        .collect();
                    pending.push((d, quoted, strip));
                }
                flush_stage(&mut stage, &mut pipeline);
                if !pipeline.is_empty() {
                    out.pipelines.push(std::mem::take(&mut pipeline));
                }
                i += 1;
                // Heredoc bodies start on the line after the operator.
                for (delim, quoted, strip) in pending.drain(..) {
                    let mut body = String::new();
                    while i < chars.len() {
                        let start = i;
                        while i < chars.len() && chars[i] != '\n' {
                            i += 1;
                        }
                        let line: String = chars[start..i].iter().collect();
                        i += 1;
                        let cmp = if strip {
                            line.trim_start_matches('\t')
                        } else {
                            line.as_str()
                        };
                        if cmp == delim {
                            break;
                        }
                        body.push_str(&line);
                        body.push('\n');
                    }
                    out.heredocs.push((quoted, body));
                }
            }
            '|' | '&' | ';' => {
                if let Some(w) = end_word(&mut word, &mut in_word, &mut stage)
                    && let Some(strip) = expect_delim.take()
                {
                    stage.pop();
                    let quoted = w.contains(['\'', '"', '\\']);
                    let d: String = w
                        .chars()
                        .filter(|c| !matches!(c, '\'' | '"' | '\\'))
                        .collect();
                    pending.push((d, quoted, strip));
                }
                let double = chars.get(i + 1) == Some(&c);
                flush_stage(&mut stage, &mut pipeline);
                if c == '|' && !double {
                    // a pipe: the next stage joins this pipeline
                } else if !pipeline.is_empty() {
                    out.pipelines.push(std::mem::take(&mut pipeline));
                }
                i += if double { 2 } else { 1 };
            }
            _ => {
                in_word = true;
                word.push(c);
                i += 1;
            }
        }
    }
    if let Some(w) = end_word(&mut word, &mut in_word, &mut stage)
        && expect_delim.is_some()
    {
        stage.pop();
        let _ = w;
    }
    flush_stage(&mut stage, &mut pipeline);
    if !pipeline.is_empty() {
        out.pipelines.push(pipeline);
    }
    out
}

/// A word with its quotes removed (for argv comparison, not for display).
fn unquote(w: &str) -> String {
    let mut out = String::new();
    let mut chars = w.chars().peekable();
    let mut in_single = false;
    let mut in_double = false;
    while let Some(c) = chars.next() {
        match c {
            '\'' if !in_double => in_single = !in_single,
            '"' if !in_single => in_double = !in_double,
            '\\' if !in_single => {
                if let Some(n) = chars.next() {
                    out.push(n);
                }
            }
            _ => out.push(c),
        }
    }
    out
}

fn argv_of(stage: &[String]) -> Vec<String> {
    stage
        .iter()
        .map(|w| unquote(w))
        // leading VAR=value assignments are not the program
        .skip_while(|w| {
            w.split_once('=')
                .map(|(k, _)| {
                    !k.is_empty() && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                })
                .unwrap_or(false)
        })
        .collect()
}

// ── the shapes ───────────────────────────────────────────────────────────────

fn token_literal(cmd: &str) -> Option<String> {
    let re = Regex::new(
        r"(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})",
    )
    .ok()?;
    re.find(cmd).map(|m| {
        let t = m.as_str();
        format!("{}…({} chars)", &t[..t.len().min(6)], t.len())
    })
}

fn sets_pipefail(cmd: &str) -> bool {
    Regex::new(r"(^|[;&|\n]|\s)set\s+(-[a-zA-Z]*o\s+pipefail|-o\s+pipefail)")
        .map(|re| re.is_match(cmd))
        .unwrap_or(false)
}

fn is_grep_quiet(argv: &[String]) -> bool {
    matches!(
        argv.first().map(|p| cp::program_name(p)).as_deref(),
        Some("grep" | "egrep" | "fgrep")
    ) && argv.iter().skip(1).any(|a| {
        a == "--quiet"
            || a == "--silent"
            || (a.starts_with('-') && !a.starts_with("--") && a[1..].contains('q'))
    })
}

fn is_tail_one(argv: &[String]) -> bool {
    if argv.first().map(|p| cp::program_name(p)).as_deref() != Some("tail") {
        return false;
    }
    let a: Vec<&str> = argv.iter().skip(1).map(String::as_str).collect();
    a.iter().enumerate().any(|(i, x)| {
        *x == "-1" || *x == "-n1" || *x == "--lines=1" || (*x == "-n" && a.get(i + 1) == Some(&"1"))
    })
}

/// The first stage's script basename, looking through `bash|sh <script>`.
fn verdict_script(argv: &[String]) -> Option<String> {
    let prog = cp::program_name(argv.first()?);
    let script = if matches!(prog.as_str(), "bash" | "sh" | "zsh" | "dash") {
        argv.iter().skip(1).find(|a| !a.starts_with('-'))?.clone()
    } else {
        argv.first()?.clone()
    };
    let base = Path::new(&script)
        .file_name()?
        .to_string_lossy()
        .to_string();
    (base.starts_with("check-") || base.starts_with("test-")).then_some(base)
}

/// A shell handed a command STRING that carries a pipe, a backtick or `$(`.
/// Returns the string's shell for the refusal. Plain strings are allowed.
fn string_crosses_boundary(stage: &[String]) -> Option<String> {
    let argv = argv_of(stage);
    let raw: Vec<&String> = stage.iter().collect();
    let shells = ["bash", "sh", "zsh", "dash", "ksh"];
    for (i, a) in argv.iter().enumerate() {
        let prog = cp::program_name(a);
        if !shells.contains(&prog.as_str()) {
            continue;
        }
        // `bash -c STR` / `bash -lc STR`: the string is the word after the flag.
        let mut j = i + 1;
        while j < argv.len() {
            let f = argv[j].as_str();
            if f.starts_with('-') && !f.starts_with("--") && f[1..].contains('c') {
                let s_raw = raw.get(j + 1 + (stage.len() - argv.len()))?;
                let s = s_raw.as_str();
                if s.contains('|') || s.contains('`') || s.contains("$(") {
                    let via = argv
                        .first()
                        .map(|p| cp::program_name(p))
                        .filter(|p| p.starts_with("wsl"))
                        .map(|p| format!("{p} … "))
                        .unwrap_or_default();
                    return Some(format!("{via}{prog} {f}"));
                }
                return None;
            }
            if !f.starts_with('-') {
                break;
            }
            j += 1;
        }
    }
    None
}

/// Expand a leading `~` and `$VAR` / `${VAR}` / `${VAR:-default}` from the
/// environment. `None` when the word depends on something the hook cannot know
/// before the shell runs: an unset variable, `$(…)`, a backtick, or `$` followed
/// by anything else (`$1`, `$@`).
fn expand_word(w: &str) -> Option<String> {
    if w.contains('`') || w.contains("$(") {
        return None;
    }
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    let mut s = w.to_string();
    if s == "~" || s.starts_with("~/") {
        s = format!("{}{}", env("HOME")?, &s[1..]);
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s.as_str();
    while let Some(i) = rest.find('$') {
        out.push_str(&rest[..i]);
        rest = &rest[i + 1..];
        if let Some(body) = rest.strip_prefix('{') {
            let end = body.find('}')?;
            let inner = &body[..end];
            let (name, default) = match inner.split_once(":-") {
                Some((n, d)) => (n, Some(d)),
                None => (inner, None),
            };
            if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return None;
            }
            out.push_str(&match env(name) {
                Some(v) => v,
                None => default?.to_string(),
            });
            rest = &body[end + 1..];
        } else {
            let n = rest
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .unwrap_or(rest.len());
            if n == 0 || rest.as_bytes()[0].is_ascii_digit() {
                return None;
            }
            out.push_str(&env(&rest[..n])?);
            rest = &rest[n..];
        }
    }
    out.push_str(rest);
    Some(out)
}

/// Does an rm's target name a scratch root itself (lexically, trailing `/` and
/// `.` segments ignored)?
fn targets_a_scratch_root(argv: &[String], ctx: &Context) -> bool {
    let norm = |p: &Path| -> PathBuf {
        let mut out = PathBuf::new();
        for c in p.components() {
            match c {
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    out.pop();
                }
                other => out.push(other.as_os_str()),
            }
        }
        out
    };
    let roots: Vec<PathBuf> = ctx.scratch.iter().map(|r| norm(r)).collect();
    argv.iter()
        .skip(1)
        .filter(|a| !a.starts_with('-'))
        .map(|a| {
            let p = Path::new(a);
            norm(&if p.is_absolute() {
                p.to_path_buf()
            } else {
                ctx.cwd.join(p)
            })
        })
        .any(|t| roots.contains(&t))
}

fn floor_on(argv: &[String], ctx: &Context, workspace: &Path) -> Option<cp::Decision> {
    let req = cp::Request {
        argv: argv.to_vec(),
        cwd: ctx.cwd.clone(),
        workspace: workspace.to_path_buf(),
        host_kind: ctx.host_kind,
        regime: "hook".into(),
        caller: "pretooluse".into(),
    };
    cp::floor_decide(&req, &ctx.protected)
}

/// Classify one raw Bash-tool command.
pub fn classify(cmd: &str, ctx: &Context) -> Classification {
    if let Some(t) = token_literal(cmd) {
        return Classification::deny(
            "token-literal",
            &format!(
                "the command carries a token-shaped literal ({t}); it lands in the transcript, the shell history and any log that echoes the command"
            ),
            "read the secret from its channel instead (Vault, a file the operator wrote, a credential helper), never paste it into a command",
        );
    }
    let lexed = lex(cmd);

    if lexed
        .heredocs
        .iter()
        .any(|(quoted, body)| !quoted && (body.contains('`') || body.contains("$(")))
    {
        return Classification::deny(
            "unquoted-heredoc-executes-prose",
            "an unquoted heredoc EXECUTES every backtick and $( ) span in its body before the file exists (2026-09-27: backticked prose ran `openspec init` in a protected checkout)",
            "quote the delimiter (<<'EOF') so the body is literal, and fill in values afterwards (sed on a placeholder); or pass the text as a file with `tillandsias-plan run --stdin-file <path>`",
        );
    }

    let pipefail = sets_pipefail(cmd);
    for p in &lexed.pipelines {
        if p.len() < 2 {
            continue;
        }
        let last = argv_of(p.last().expect("len >= 2"));
        if pipefail && is_grep_quiet(&last) {
            return Classification::deny(
                "sigpipe-verdict-pipeline",
                "under pipefail, `grep -q` exits at its first match and the producer dies of SIGPIPE, so a MATCH can read as a failure (1252-fg9e)",
                "capture first and test the value: `out=$(producer)`, then `grep -q PAT <<<\"$out\"`; or use `tillandsias-plan run --json` and read the field",
            );
        }
        if is_tail_one(&last)
            && let Some(script) = verdict_script(&argv_of(&p[0]))
        {
            return Classification::deny(
                "verdict-through-tail",
                &format!(
                    "`{script} | tail -1` keeps the last line and drops the exit status, so a refusal that prints another line last reads as its verdict"
                ),
                "run the check directly and read its exit status and full verdict line; or `tillandsias-plan run --json -- <check>` and read the verdict field",
            );
        }
    }

    // Per stage: shell strings, then the policy floor's classes.
    let mut ask: Option<Classification> = None;
    for p in &lexed.pipelines {
        for stage in p {
            if let Some(how) = string_crosses_boundary(stage) {
                return Classification::deny(
                    "string-crosses-a-boundary",
                    &format!(
                        "`{how} \"…\"` hands a command STRING with a pipe, backtick or $( ) to another shell: quoting, globbing and SIGPIPE are decided by a shell nobody reads"
                    ),
                    "run the stages as separate commands, or put the pipeline in a script FILE and pass its path (`bash path/to/script.sh` is argv and allowed)",
                );
            }
            let mut argv = argv_of(stage);
            if argv.is_empty() {
                continue;
            }
            // A plain shell string is the bridge's business only in shape 6.
            if cp::is_shell_string_call(&argv) {
                continue;
            }
            // The hook sees the command BEFORE the shell expands it, so an rm
            // target like "$HOME" or ~/x would otherwise be judged as a literal
            // path under the working directory. Expand ~, $VAR, ${VAR} and
            // ${VAR:-default} from the environment; a target that cannot be
            // resolved statically (an unset variable, $(…)) asks.
            if cp::program_name(&argv[0]) == "rm" {
                let mut unresolved = None;
                for a in argv.iter_mut().skip(1) {
                    match expand_word(a) {
                        Some(e) => *a = e,
                        None => {
                            unresolved = Some(a.clone());
                            break;
                        }
                    }
                }
                if let Some(t) = unresolved {
                    if ask.is_none() {
                        ask = Some(Classification::ask(
                            "workspace-destroy",
                            format!(
                                "a recursive rm whose target `{}` cannot be resolved before the shell runs it [consent class: workspace-destroy]",
                                cp::redact(&t)
                            ),
                            "name the target as a literal path under the working directory, $TMPDIR or /tmp".into(),
                        ));
                    }
                    continue;
                }
            }
            let Some(d) = floor_on(&argv, ctx, &ctx.cwd) else {
                continue;
            };
            match d.strictness {
                cp::Strictness::Allow => {}
                cp::Strictness::Deny => {
                    let rule = if d.rule_id == "no-credential-mutation" {
                        "no-credential-mutation".to_string()
                    } else {
                        d.rule_id.clone()
                    };
                    return Classification::deny(
                        &rule,
                        d.why
                            .as_deref()
                            .unwrap_or("the policy floor refuses this command"),
                        d.remedy
                            .as_deref()
                            .unwrap_or("see `tillandsias-plan policy show`"),
                    );
                }
                cp::Strictness::Consent => {
                    // A recursive rm BENEATH TMPDIR or a scratch root needs no
                    // consent; a scratch root ITSELF always asks, even when it
                    // sits beneath another root ($TMPDIR under /tmp).
                    if d.rule_id == "workspace-destroy"
                        && !targets_a_scratch_root(&argv, ctx)
                        && ctx
                            .scratch
                            .iter()
                            .any(|root| floor_on(&argv, ctx, root).is_none())
                    {
                        continue;
                    }
                    if ask.is_none() {
                        ask = Some(Classification::ask(
                            &d.rule_id,
                            format!(
                                "{} [consent class: {}]",
                                d.why.clone().unwrap_or_default(),
                                d.rule_id
                            ),
                            d.remedy.clone().unwrap_or_default(),
                        ));
                    }
                }
            }
        }
    }
    ask.unwrap_or_else(Classification::allow)
}

/// The context the hook runs in: cwd from the hook input, host kind from the
/// policy engine's three sources, scratch roots from TMPDIR and the env.
pub fn context_for(cwd: &Path) -> Context {
    let root = crate::branch_discipline::find_root(cwd).unwrap_or_else(|| cwd.to_path_buf());
    // Scratch roots: $TMPDIR, and /tmp and /private/tmp on every platform
    // (coordinator ruling 2026-09-28, from macbookair's darwin run: TMPDIR is
    // /var/folders/…/T/ there, and an agent on a Mac must get the same answer
    // for /tmp as on Linux). Paths BENEATH a root are scratch; the roots
    // themselves still ask (the floor treats target == root as a destroy).
    let mut scratch = vec![PathBuf::from("/tmp"), PathBuf::from("/private/tmp")];
    if let Ok(t) = std::env::var("TMPDIR")
        && !t.is_empty()
    {
        scratch.push(PathBuf::from(t.trim_end_matches('/')));
    }
    if let Ok(extra) = std::env::var("TILLANDSIAS_PRETOOLUSE_SCRATCH") {
        scratch.extend(
            extra
                .split(':')
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
        );
    }
    Context {
        cwd: cwd.to_path_buf(),
        host_kind: cp::read_host_kind(&root).kind,
        scratch,
        protected: cp::protected_refs(&root),
    }
}

/// Where the bridge's decisions go: the per-host policy AUDIT (1443-w9hf),
/// shared with every other evaluator decision, as caller=pretooluse.
pub fn log_path(workspace: &Path) -> PathBuf {
    cp::audit_log_path(workspace)
}

/// Record one bridge decision. Never the raw command (a command can carry a
/// secret no shape catches): the audit keeps its sha256 only. `ask` is
/// recorded as `consent`, the engine's word for the same thing.
pub fn log_decision(ctx: &Context, command: &str, verdict: &str, rule: &str, kill_switch: bool) {
    let decision = if verdict == "ask" { "consent" } else { verdict };
    let workspace =
        crate::branch_discipline::find_root(&ctx.cwd).unwrap_or_else(|| ctx.cwd.clone());
    cp::audit_bridge(
        &workspace,
        ctx.host_kind,
        command,
        rule,
        decision,
        kill_switch,
    );
}

/// (deny, ask, allow, kill_switch uses) for caller=pretooluse, from the audit.
pub fn status_counts(workspace: &Path) -> (usize, usize, usize, usize) {
    let text = std::fs::read_to_string(log_path(workspace)).unwrap_or_default();
    let (mut d, mut a, mut al, mut k) = (0, 0, 0, 0);
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if v.get("caller").and_then(|x| x.as_str()) != Some("pretooluse") {
            continue;
        }
        match v.get("decision").and_then(|x| x.as_str()) {
            Some("deny") => d += 1,
            Some("consent") | Some("ask") => a += 1,
            Some("allow") => al += 1,
            _ => {}
        }
        if v.get("kill_switch").and_then(|x| x.as_i64()) == Some(1) {
            k += 1;
        }
    }
    (d, a, al, k)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> Context {
        Context {
            cwd: PathBuf::from("/work/proj"),
            host_kind: cp::HostKind::BareMetal,
            scratch: vec![PathBuf::from("/tmp")],
            protected: vec!["main".into(), "linux-next".into()],
        }
    }

    #[test]
    fn heredoc_quoting_decides() {
        let bad = "cat > f <<EOF\nrun `openspec init` now\nEOF\n";
        assert_eq!(
            classify(bad, &ctx()).rule,
            "unquoted-heredoc-executes-prose"
        );
        let good = "cat > f <<'EOF'\nrun `openspec init` now\nEOF\n";
        assert_eq!(classify(good, &ctx()).verdict, Verdict::Allow);
    }

    #[test]
    fn pipelines() {
        let c = ctx();
        assert_eq!(
            classify("set -o pipefail; git log | grep -q x", &c).rule,
            "sigpipe-verdict-pipeline"
        );
        assert_eq!(classify("git log | grep -q x", &c).verdict, Verdict::Allow);
        assert_eq!(
            classify("bash scripts/check-foo.sh | tail -1", &c).rule,
            "verdict-through-tail"
        );
        assert_eq!(
            classify("printf %s \"$x\" | sort", &c).verdict,
            Verdict::Allow
        );
    }

    #[test]
    fn strings_and_floor() {
        let c = ctx();
        assert_eq!(
            classify("wsl.exe -d x -- bash -lc \"a | b\"", &c).rule,
            "string-crosses-a-boundary"
        );
        assert_eq!(
            classify("bash -c \"$(cat f)\"", &c).rule,
            "string-crosses-a-boundary"
        );
        assert_eq!(classify("bash -c \"echo hi\"", &c).verdict, Verdict::Allow);
        assert_eq!(
            classify("gh auth refresh", &c).rule,
            "no-credential-mutation"
        );
        assert_eq!(
            classify("git push --force origin linux-next", &c).verdict,
            Verdict::Ask
        );
        assert_eq!(
            classify("rm -rf /tmp/scratch-x", &c).verdict,
            Verdict::Allow
        );
        assert_eq!(classify("rm -rf /etc/x", &c).verdict, Verdict::Ask);
        assert_eq!(classify("git status", &c).verdict, Verdict::Allow);
    }
}
