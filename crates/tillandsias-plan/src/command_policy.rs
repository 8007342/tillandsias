// @trace order:1443-isrk, spec:command-policies
//
// ORDER 1443-isrk — the COMMAND POLICY EVALUATOR: allow | deny | consent for one
// argv request, from a BUILT-IN floor plus a per-project seed that can only
// tighten it.
//
// Spec: openspec/changes/lua-command-runtime-and-policies/specs/command-policies/spec.md,
// re-scoped by the operator rulings of 2026-09-27 (plan fragment 1446-xqi6):
// the old `substrate-reset` class is split into `soft-reset` (pre-authorised in
// a forge) and `hard-reset` (never grantable in a forge), and `rm -rf` outside
// the workspace is `workspace-destroy`.
//
// THE FLOOR IS COMPILED IN. A seed (`.tillandsias/command-policies.yaml`) may
// add rules and may make a floor answer STRICTER; it may never make one looser.
// Two mechanisms hold that, deliberately redundant:
//   1. at EVALUATION the answer is the strictest of the floor's and every
//      matching seed rule's, so a looser seed rule cannot win even if it loads;
//   2. at LOAD a seed rule that would loosen a floor answer is REFUSED, loudly,
//      and the whole seed is dropped (`refused:policy-seed:cannot-loosen:<id>`),
//      so an attempt to loosen is visible instead of silently ineffective, and
//      the engine never answers from a PARTIAL seed.
//
// NO PROCESS SPAWNS, and the decision depends only on the request, the seed and
// the host-kind evidence, so the same argv gives the same answer on every host
// that shares those.
//
// OUT OF THIS SLICE, by name, so nobody reads a green as more: consent TOKENS
// (`policy consent grant`) and the smoke-skill env authorisation, the audit log
// and `policy audit`, the fixture-regime filesystem scope, and the measured
// default flip. `deny_after_quiet_days` is PARSED and validated here, but the
// default never flips in this slice: the flip reads the audit (1443-w9hf) and
// the operator confirms N before it flips anywhere.

use serde_yaml::Value;
use std::path::{Component, Path, PathBuf};

pub const SEED_RELATIVE_PATH: &str = ".tillandsias/command-policies.yaml";

/// Exit status of `policy eval` per decision.
pub const EXIT_ALLOW: i32 = 0;
pub const EXIT_DENY: i32 = 1;
pub const EXIT_CONSENT: i32 = 4;

// ── request ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKind {
    BareMetal,
    Forge,
    Ci,
}

impl HostKind {
    pub fn parse(s: &str) -> Option<HostKind> {
        match s {
            "bare-metal" => Some(HostKind::BareMetal),
            "forge" => Some(HostKind::Forge),
            "ci" => Some(HostKind::Ci),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            HostKind::BareMetal => "bare-metal",
            HostKind::Forge => "forge",
            HostKind::Ci => "ci",
        }
    }
    pub const ALL: [HostKind; 3] = [HostKind::BareMetal, HostKind::Forge, HostKind::Ci];
}

pub const REGIMES: [&str; 5] = ["interactive", "gate", "fixture", "hook", "relay"];

/// Where the host kind came from, and whether the sources agreed.
#[derive(Debug, Clone)]
pub struct HostKindReading {
    pub kind: HostKind,
    /// `flag`, `evidence` or `env`/`default` — what decided it.
    pub source: &'static str,
    /// Set when the sources disagree. A self-declared host kind is not a
    /// security fact (cheatsheets/concurrent-git/git-mirror-architecture-audit.md),
    /// so the disagreement is reported rather than resolved silently.
    pub disagreement: Option<String>,
}

/// Derive the host kind from the three sources the spec names TOGETHER:
/// `TILLANDSIAS_HOST_KIND`, `/run/.containerenv` and the
/// `.forge-startup-context.md` marker under `root`.
///
/// A FORGE NEEDS PHYSICAL EVIDENCE. The environment variable alone cannot
/// declare one, because a forge is where `soft-reset` is pre-authorised: a
/// variable that could claim it would be a way round the consent. Evidence
/// wins over the variable, and a disagreement between them is reported.
pub fn read_host_kind(root: &Path) -> HostKindReading {
    let env = std::env::var("TILLANDSIAS_HOST_KIND").ok();
    let containerenv = Path::new("/run/.containerenv").exists();
    let marker = root.join(".forge-startup-context.md").exists();
    read_host_kind_from(env.as_deref(), containerenv, marker)
}

/// Pure half of [`read_host_kind`], so the rule is testable without a container.
pub fn read_host_kind_from(env: Option<&str>, containerenv: bool, marker: bool) -> HostKindReading {
    let evidence_forge = containerenv || marker;
    let env_kind = env.and_then(HostKind::parse);
    let evidence_names = || {
        let mut v = Vec::new();
        if containerenv {
            v.push("/run/.containerenv");
        }
        if marker {
            v.push(".forge-startup-context.md");
        }
        v.join("+")
    };
    if evidence_forge {
        let disagreement = match (env, env_kind) {
            (Some(e), Some(k)) if k != HostKind::Forge => Some(format!(
                "TILLANDSIAS_HOST_KIND={e} but {} present",
                evidence_names()
            )),
            (Some(e), None) => Some(format!(
                "TILLANDSIAS_HOST_KIND={e} is not a host kind; {} present",
                evidence_names()
            )),
            _ => None,
        };
        return HostKindReading {
            kind: HostKind::Forge,
            source: "evidence",
            disagreement,
        };
    }
    match (env, env_kind) {
        (Some(e), Some(HostKind::Forge)) => HostKindReading {
            kind: HostKind::BareMetal,
            source: "default",
            disagreement: Some(format!(
                "TILLANDSIAS_HOST_KIND={e} but neither /run/.containerenv nor \
                 .forge-startup-context.md is present; a forge is not self-declared"
            )),
        },
        (Some(_), Some(k)) => HostKindReading {
            kind: k,
            source: "env",
            disagreement: None,
        },
        (Some(e), None) => HostKindReading {
            kind: HostKind::BareMetal,
            source: "default",
            disagreement: Some(format!("TILLANDSIAS_HOST_KIND={e} is not a host kind")),
        },
        (None, _) => HostKindReading {
            kind: HostKind::BareMetal,
            source: "default",
            disagreement: None,
        },
    }
}

#[derive(Debug, Clone)]
pub struct Request {
    pub argv: Vec<String>,
    pub cwd: PathBuf,
    /// The workspace a destroy is measured against (the repository root).
    pub workspace: PathBuf,
    pub host_kind: HostKind,
    pub regime: String,
    pub caller: String,
}

// ── decision ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Strictness {
    Allow = 0,
    Consent = 1,
    Deny = 2,
}

impl Strictness {
    pub fn parse(s: &str) -> Option<Strictness> {
        match s {
            "allow" => Some(Strictness::Allow),
            "consent" => Some(Strictness::Consent),
            "deny" => Some(Strictness::Deny),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decision {
    pub strictness: Strictness,
    /// The rule or class that decided; `default` for an unmatched request.
    pub rule_id: String,
    /// The stdout verdict line.
    pub token: String,
    pub why: Option<String>,
    pub remedy: Option<String>,
}

impl Decision {
    pub fn exit_code(&self) -> i32 {
        match self.strictness {
            Strictness::Allow => EXIT_ALLOW,
            Strictness::Deny => EXIT_DENY,
            Strictness::Consent => EXIT_CONSENT,
        }
    }

    fn allow(rule_id: &str, token: String) -> Decision {
        Decision {
            strictness: Strictness::Allow,
            rule_id: rule_id.to_string(),
            token,
            why: None,
            remedy: None,
        }
    }

    fn deny(rule_id: &str, token: String, why: &str, remedy: String) -> Decision {
        Decision {
            strictness: Strictness::Deny,
            rule_id: rule_id.to_string(),
            token,
            why: Some(why.to_string()),
            remedy: Some(remedy),
        }
    }

    fn consent(rule_id: &str, why: &str, remedy: String) -> Decision {
        Decision {
            strictness: Strictness::Consent,
            rule_id: rule_id.to_string(),
            token: format!("consent:policy:{rule_id}"),
            why: Some(why.to_string()),
            remedy: Some(remedy),
        }
    }
}

// ── argv helpers ─────────────────────────────────────────────────────────────

/// Program basename, lowercased, `.exe` stripped: `C:\x\GH.EXE` -> `gh`.
pub fn program_name(argv0: &str) -> String {
    let base = argv0.rsplit(['/', '\\']).next().unwrap_or(argv0);
    let lower = base.to_ascii_lowercase();
    lower.strip_suffix(".exe").unwrap_or(&lower).to_string()
}

/// The positional words after the program, skipping options and the values of
/// the options that take one (`git -C dir credential approve` -> `credential`,
/// `approve`). `--opt=value` carries its value inside the one argument.
fn positional_words<'a>(args: &'a [String], value_flags: &[&str]) -> Vec<&'a str> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--" {
            out.extend(args[i + 1..].iter().map(String::as_str));
            break;
        }
        if a.starts_with('-') && a.len() > 1 {
            if value_flags.contains(&a) {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        out.push(a);
        i += 1;
    }
    out
}

const GIT_VALUE_FLAGS: &[&str] = &["-C", "-c", "--git-dir", "--work-tree", "--namespace"];
const GH_VALUE_FLAGS: &[&str] = &["-R", "--repo", "--hostname", "-h"];
const PODMAN_VALUE_FLAGS: &[&str] = &[
    "--root",
    "--runroot",
    "--url",
    "--connection",
    "-c",
    "--log-level",
    "--storage-driver",
    "--cgroup-manager",
    "--identity",
];

/// Shells that turn one string argument into a command line. Handing them a
/// string reintroduces quoting, globbing and pipes, which is what argv-only
/// execution exists to delete (1252-fg9e). Moved here from lua_predicate.rs
/// (1443-isrk): the rule lives in the policy, and proc.run asks the policy.
pub const SHELL_PROGRAMS: &[&str] = &[
    "sh",
    "bash",
    "dash",
    "zsh",
    "ksh",
    "fish",
    "cmd",
    "powershell",
    "pwsh",
];

pub fn is_shell_string_call(argv: &[String]) -> bool {
    let Some(prog) = argv.first() else {
        return false;
    };
    if !SHELL_PROGRAMS.contains(&program_name(prog).as_str()) {
        return false;
    }
    argv.iter().skip(1).any(|a| {
        let a = a.to_ascii_lowercase();
        a == "-c"
            || a == "-lc"
            || a == "-ic"
            || a == "/c"
            || a == "/k"
            || a == "-command"
            || a == "-encodedcommand"
    })
}

/// Replace token-shaped literals with `<redacted:token>` before any argv text
/// reaches a refusal line (spec: every decision is audited with secrets
/// redacted; the refusal text obeys the same rule).
pub fn redact(s: &str) -> String {
    // ORDER 1443-w9hf: a PEM block (`-----BEGIN … PRIVATE KEY-----`) is
    // redacted from its header to the end of the text: a key's body spans
    // lines and has no single-token shape to stop at.
    if let Some(i) = s.find("-----BEGIN") {
        return format!("{}<redacted:pem>", redact(&s[..i]));
    }
    // AWS-style access key ids: AKIA/ASIA + 16 upper-case alphanumerics.
    let aws_redacted = {
        let mut out = String::with_capacity(s.len());
        let b = s.as_bytes();
        let mut i = 0;
        while i < b.len() {
            let is_key = (s[i..].starts_with("AKIA") || s[i..].starts_with("ASIA"))
                && b.len() >= i + 20
                && b[i + 4..i + 20]
                    .iter()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit());
            if is_key {
                out.push_str("<redacted:token>");
                i += 20;
                continue;
            }
            let ch = s[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
        out
    };
    let s: &str = &aws_redacted;
    const PREFIXES: &[&str] = &[
        "github_pat_",
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "sk-ant-",
        "hvs.",
    ];
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    'outer: while !rest.is_empty() {
        for p in PREFIXES {
            if let Some(tail) = rest.strip_prefix(p) {
                let n = tail
                    .find(|c: char| {
                        !(c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.')
                    })
                    .unwrap_or(tail.len());
                if n >= 8 {
                    out.push_str("<redacted:token>");
                    rest = &tail[n..];
                    continue 'outer;
                }
            }
        }
        let ch = rest.chars().next().unwrap();
        out.push(ch);
        rest = &rest[ch.len_utf8()..];
    }
    out
}

fn shown(argv: &[String]) -> String {
    redact(
        &argv
            .iter()
            .map(|a| {
                if a.is_empty() || a.contains([' ', '\t', '"', '\'']) {
                    format!("{a:?}")
                } else {
                    a.clone()
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

// ── the floor ────────────────────────────────────────────────────────────────

/// Every floor rule id, in evaluation order. A seed rule naming one of these as
/// its `id` is a statement about that floor rule and is held to the same
/// cannot-loosen check.
pub const FLOOR_RULES: [&str; 6] = [
    "no-shell-strings",
    "no-credential-mutation",
    "hard-reset",
    "soft-reset",
    "workspace-destroy",
    "force-push",
];

const CONSENT_GRANT: &str = "the operator runs it themselves, or grants this one run with \
    `tillandsias-plan policy consent grant <class>` on the host (never in a forge)";

/// The class of reset an argv is, if any. `--reset-guest` is SOFT on the Linux
/// launcher (`tillandsias`) and HARD on a guest regime (the Windows/macOS tray,
/// which owns a VM): the same flag, two blast radii (operator ruling 3,
/// 2026-09-27, host-state-lifecycle).
fn reset_class(req: &Request) -> Option<&'static str> {
    let prog = program_name(&req.argv[0]);
    let args = &req.argv[1..];
    let has = |f: &str| args.iter().any(|a| a == f);
    match prog.as_str() {
        "tillandsias" => {
            if has("--reset-state") || has("--reset-guest") {
                return Some("soft-reset");
            }
        }
        "tillandsias-tray" => {
            if has("--reset-guest") {
                return Some("hard-reset");
            }
            if has("--reset-state") {
                return Some("soft-reset");
            }
        }
        "podman" => {
            let w = positional_words(args, PODMAN_VALUE_FLAGS);
            if w.len() >= 2 && w[0] == "system" && w[1] == "reset" {
                return Some("soft-reset");
            }
        }
        "wsl" if has("--unregister") => {
            return Some("hard-reset");
        }
        _ => {}
    }
    None
}

fn is_credential_mutation(argv: &[String]) -> Option<&'static str> {
    let prog = program_name(&argv[0]);
    let args = &argv[1..];
    match prog.as_str() {
        "gh" => {
            let w = positional_words(args, GH_VALUE_FLAGS);
            if w.len() >= 2
                && w[0] == "auth"
                && matches!(w[1], "login" | "refresh" | "logout" | "token")
            {
                return Some("gh");
            }
        }
        "git" => {
            let w = positional_words(args, GIT_VALUE_FLAGS);
            if w.len() >= 2 && w[0] == "credential" && matches!(w[1], "approve" | "reject") {
                return Some("git");
            }
        }
        "vault" => {
            let w = positional_words(args, &[]);
            if w.first() == Some(&"login") {
                return Some("vault");
            }
        }
        _ => {}
    }
    None
}

/// Lexically resolve `p` against `cwd` (no filesystem access: the target may
/// not exist, and a symlink check belongs to the fs verbs, not to argv policy).
fn lexical_abs(cwd: &Path, p: &str) -> PathBuf {
    let raw = if let Some(rest) = p.strip_prefix("~/") {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"))
            .join(rest)
    } else if p == "~" {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"))
    } else {
        let pb = PathBuf::from(p);
        if pb.is_absolute() { pb } else { cwd.join(pb) }
    };
    let mut out = PathBuf::new();
    for c in raw.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// `rm` with a recursive flag and at least one target outside the workspace.
/// A target AT the workspace root is outside too: removing the whole checkout
/// is not "inside" it.
fn destroy_target(req: &Request) -> Option<String> {
    if program_name(&req.argv[0]) != "rm" {
        return None;
    }
    let args = &req.argv[1..];
    let mut recursive = false;
    let mut targets = Vec::new();
    let mut after_dd = false;
    for a in args {
        if !after_dd && a == "--" {
            after_dd = true;
            continue;
        }
        if !after_dd && a.starts_with("--") {
            if a == "--recursive" {
                recursive = true;
            }
            continue;
        }
        if !after_dd && a.starts_with('-') && a.len() > 1 {
            if a[1..].contains(['r', 'R']) {
                recursive = true;
            }
            continue;
        }
        targets.push(a.as_str());
    }
    if !recursive {
        return None;
    }
    let ws = lexical_abs(Path::new("/"), &req.workspace.to_string_lossy());
    for t in targets {
        let abs = lexical_abs(&req.cwd, t);
        if abs == ws || !abs.starts_with(&ws) {
            return Some(abs.display().to_string());
        }
    }
    None
}

/// The protected refs a force-push may not rewrite without consent: the
/// default branch and every integration branch the project's branch-discipline
/// seed names, else `main` alone.
pub fn protected_refs(root: &Path) -> Vec<String> {
    let mut out = vec!["main".to_string()];
    let d = crate::branch_discipline::load(root, None);
    out.push(d.default_branch.clone());
    out.extend(d.integration.values().cloned());
    out.sort();
    out.dedup();
    out
}

fn force_push_target(req: &Request, protected: &[String]) -> Option<String> {
    if program_name(&req.argv[0]) != "git" {
        return None;
    }
    let args = &req.argv[1..];
    let w = positional_words(args, GIT_VALUE_FLAGS);
    if w.first() != Some(&"push") {
        return None;
    }
    let flag_force = args.iter().any(|a| {
        a == "-f" || a == "--force" || a.starts_with("--force-with-lease") || a == "--mirror"
    });
    // positional words after `push`: remote, then refspecs.
    for spec in w.iter().skip(2) {
        let plus = spec.starts_with('+');
        let spec = spec.trim_start_matches('+');
        let dst = spec.rsplit(':').next().unwrap_or(spec);
        let dst = dst.strip_prefix("refs/heads/").unwrap_or(dst);
        if (flag_force || plus) && protected.iter().any(|p| p == dst) {
            return Some(dst.to_string());
        }
    }
    None
}

/// The floor's answer, or `None` when no floor rule matches.
pub fn floor_decide(req: &Request, protected: &[String]) -> Option<Decision> {
    if req.argv.is_empty() {
        return None;
    }
    if is_shell_string_call(&req.argv) {
        return Some(Decision::deny(
            "no-shell-strings",
            "refused:policy:no-shell-strings".into(),
            "a shell given a command STRING reintroduces quoting, globbing and pipes \
             (argv-only execution, 1252-fg9e)",
            format!(
                "pass the program's own argv instead of `{}`: e.g. [\"git\", \"status\"]; \
                 a pipeline becomes two proc.run calls joined in Lua, and a script FILE \
                 given to the shell (`bash path/to/script.sh`) is argv and allowed",
                shown(&req.argv)
            ),
        ));
    }
    if let Some(tool) = is_credential_mutation(&req.argv) {
        let remedy = match tool {
            "gh" => {
                "GitHub tokens arrive only from the operator, on stdin: \
                     `tillandsias --github-login --with-token` (never an agent; a re-auth on \
                     one host evicts the token on every other, 1025-a896); the read-only \
                     `gh auth status` is allowed"
            }
            "git" => {
                "git credentials are the operator's; git reads them through the \
                      configured helper, and an agent never approves or rejects one"
            }
            _ => {
                "Vault tokens come from the enclave's AppRole agent sink; an agent never \
                  runs `vault login`"
            }
        };
        return Some(Decision::deny(
            "no-credential-mutation",
            "refused:policy:no-credential-mutation".into(),
            "a credential mutation changes the operator's identity on this host \
             (credential channel, 982-sguu)",
            remedy.to_string(),
        ));
    }
    if let Some(class) = reset_class(req) {
        let forge = req.host_kind == HostKind::Forge;
        return Some(match (class, forge) {
            ("hard-reset", true) => Decision::deny(
                "hard-reset",
                "refused:policy:hard-reset:not-grantable-in-forge".into(),
                "a HARD reset destroys the guest and its operator data; operator ruling \
                 2026-09-27: it requires explicit approval each time, and never from a forge",
                "run it on the host, as the operator, with a per-run consent token".into(),
            ),
            ("hard-reset", false) => Decision::consent(
                "hard-reset",
                "a HARD reset destroys the guest and its operator data; operator ruling \
                 2026-09-27: explicit approval EACH TIME, and no environment variable \
                 pre-authorises it",
                format!("{CONSENT_GRANT}; there is no env override for this class"),
            ),
            (_, true) => Decision::allow(
                "soft-reset",
                "ok:policy:soft-reset:forge-preauthorised".into(),
            ),
            (_, false) => Decision::consent(
                "soft-reset",
                "a SOFT reset destroys containers, images and build state on this host \
                 (host-state-lifecycle); it is pre-authorised only in a forge",
                format!(
                    "{CONSENT_GRANT}; `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` makes the reset \
                     a plain init instead"
                ),
            ),
        });
    }
    if let Some(target) = destroy_target(req) {
        return Some(Decision::consent(
            "workspace-destroy",
            "a recursive rm outside the workspace destroys state the workspace does not own",
            format!(
                "remove only paths under {} , or {CONSENT_GRANT} (target: {})",
                req.workspace.display(),
                redact(&target)
            ),
        ));
    }
    if let Some(dst) = force_push_target(req, protected) {
        return Some(Decision::consent(
            "force-push",
            "a force-push rewrites a protected ref other hosts build on",
            format!(
                "push to a work ref (work/<order>) instead of rewriting `{dst}`, or \
                 {CONSENT_GRANT}"
            ),
        ));
    }
    None
}

// ── the seed ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DefaultPolicy {
    Allow,
    Deny,
    /// Parsed and validated; not active in this slice (see the header).
    DenyAfterQuietDays(u32),
}

#[derive(Debug, Clone)]
pub struct SeedRule {
    pub id: String,
    pub program: String,
    /// Positional-word prefix after the program (options skipped).
    pub args: Vec<String>,
    /// Matches when ANY argv element equals one of these.
    pub any_arg: Vec<String>,
    pub decision: Strictness,
    pub host_kinds: Vec<HostKind>,
    pub why: Option<String>,
    pub remedy: Option<String>,
}

impl SeedRule {
    fn applies_to(&self, k: HostKind) -> bool {
        self.host_kinds.is_empty() || self.host_kinds.contains(&k)
    }

    fn matches(&self, req: &Request) -> bool {
        if !self.applies_to(req.host_kind) || req.argv.is_empty() {
            return false;
        }
        if program_name(&req.argv[0]) != self.program {
            return false;
        }
        let words = positional_words(&req.argv[1..], &[]);
        let all_words: Vec<&str> = req.argv[1..].iter().map(String::as_str).collect();
        // A prefix of the positional words, or (for flag-shaped args) of the raw argv.
        let prefix_ok = self.args.is_empty()
            || (words.len() >= self.args.len()
                && self.args.iter().zip(&words).all(|(a, w)| a == w))
            || (all_words.len() >= self.args.len()
                && self.args.iter().zip(&all_words).all(|(a, w)| a == w));
        let any_ok =
            self.any_arg.is_empty() || req.argv[1..].iter().any(|a| self.any_arg.contains(a));
        prefix_ok && any_ok
    }

    /// The representative argv a rule describes, for the load-time check.
    fn synth_argv(&self) -> Vec<String> {
        let mut v = vec![self.program.clone()];
        v.extend(self.args.iter().cloned());
        if let Some(a) = self.any_arg.first()
            && !v.contains(a)
        {
            v.push(a.clone());
        }
        v
    }
}

#[derive(Debug, Clone)]
pub struct Seed {
    pub default: DefaultPolicy,
    pub rules: Vec<SeedRule>,
}

/// Why a seed was not used. The engine then answers from the floor alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SeedLoad {
    Absent,
    Loaded(usize),
    Refused(String),
}

impl SeedLoad {
    pub fn verdict(&self) -> String {
        match self {
            SeedLoad::Absent => "ok:policy-seed:absent".into(),
            SeedLoad::Loaded(n) => format!("ok:policy-seed:loaded:{n}-rules"),
            SeedLoad::Refused(r) => format!("refused:policy-seed:{r}"),
        }
    }
}

fn str_list(v: Option<&Value>, what: &str) -> Result<Vec<String>, String> {
    match v {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Sequence(s)) => s
            .iter()
            .map(|x| {
                x.as_str()
                    .map(str::to_string)
                    .ok_or_else(|| format!("invalid:{what}-not-strings"))
            })
            .collect(),
        Some(_) => Err(format!("invalid:{what}-not-a-list")),
    }
}

/// Parse a seed document. Structural errors are refusals, never partial loads.
pub fn parse_seed(text: &str) -> Result<Seed, String> {
    let doc: Value = serde_yaml::from_str(text).map_err(|_| "unparseable".to_string())?;
    let map = doc.as_mapping().ok_or("invalid:not-a-mapping")?;
    for k in map.keys() {
        let k = k.as_str().unwrap_or("");
        if !["version", "default", "rules"].contains(&k) {
            return Err(format!("invalid:unknown-key:{k}"));
        }
    }
    match doc.get("version").and_then(Value::as_u64) {
        Some(1) => {}
        _ => return Err("invalid:version".into()),
    }
    let default = match doc.get("default") {
        None | Some(Value::Null) => DefaultPolicy::Allow,
        Some(Value::String(s)) if s == "allow" => DefaultPolicy::Allow,
        Some(Value::String(s)) if s == "deny" => DefaultPolicy::Deny,
        Some(Value::Mapping(m)) => {
            let n = m
                .get(Value::from("deny_after_quiet_days"))
                .and_then(Value::as_u64)
                .filter(|n| (1..=365).contains(n))
                .ok_or("invalid:default")?;
            if m.len() != 1 {
                return Err("invalid:default".into());
            }
            DefaultPolicy::DenyAfterQuietDays(n as u32)
        }
        Some(_) => return Err("invalid:default".into()),
    };
    let mut rules = Vec::new();
    if let Some(rs) = doc.get("rules") {
        let rs = rs.as_sequence().ok_or("invalid:rules-not-a-list")?;
        for r in rs {
            let m = r.as_mapping().ok_or("invalid:rule-not-a-mapping")?;
            for k in m.keys() {
                let k = k.as_str().unwrap_or("");
                if ![
                    "id",
                    "program",
                    "args",
                    "any_arg",
                    "decision",
                    "host_kinds",
                    "why",
                    "remedy",
                ]
                .contains(&k)
                {
                    return Err(format!("invalid:rule-unknown-key:{k}"));
                }
            }
            let id = r
                .get("id")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or("invalid:rule-without-id")?
                .to_string();
            let program = r
                .get("program")
                .and_then(Value::as_str)
                .map(program_name)
                .ok_or_else(|| format!("invalid:rule-without-program:{id}"))?;
            let decision = r
                .get("decision")
                .and_then(Value::as_str)
                .and_then(Strictness::parse)
                .ok_or_else(|| format!("invalid:rule-decision:{id}"))?;
            let host_kinds = str_list(r.get("host_kinds"), "host_kinds")?
                .iter()
                .map(|s| HostKind::parse(s).ok_or_else(|| format!("invalid:host-kind:{s}")))
                .collect::<Result<Vec<_>, _>>()?;
            rules.push(SeedRule {
                id,
                program,
                args: str_list(r.get("args"), "args")?,
                any_arg: str_list(r.get("any_arg"), "any_arg")?,
                decision,
                host_kinds,
                why: r.get("why").and_then(Value::as_str).map(str::to_string),
                remedy: r.get("remedy").and_then(Value::as_str).map(str::to_string),
            });
        }
    }
    Ok(Seed { default, rules })
}

/// The cannot-loosen check. For every rule and every host kind it applies to,
/// the floor's answer to the argv the rule describes must not be stricter than
/// the rule's own decision; and a rule whose `id` names a floor rule is held to
/// that floor rule's answer for the same argv. The first violation names the
/// FLOOR rule it would loosen.
pub fn check_cannot_loosen(
    seed: &Seed,
    protected: &[String],
    workspace: &Path,
) -> Result<(), String> {
    for r in &seed.rules {
        for k in HostKind::ALL {
            if !r.applies_to(k) {
                continue;
            }
            let req = Request {
                argv: r.synth_argv(),
                cwd: workspace.to_path_buf(),
                workspace: workspace.to_path_buf(),
                host_kind: k,
                regime: "interactive".into(),
                caller: "seed-load".into(),
            };
            if let Some(f) = floor_decide(&req, protected)
                && f.strictness > r.decision
            {
                return Err(format!("cannot-loosen:{}", f.rule_id));
            }
        }
        if FLOOR_RULES.contains(&r.id.as_str()) && r.decision == Strictness::Allow {
            // Naming a floor rule and allowing it is a loosening whether or not
            // the synthesised argv happens to reach that rule.
            return Err(format!("cannot-loosen:{}", r.id));
        }
    }
    Ok(())
}

/// Load the seed at `seed_path` (default `<root>/.tillandsias/command-policies.yaml`).
pub fn load_seed(
    root: &Path,
    seed_path: Option<&Path>,
    protected: &[String],
) -> (Option<Seed>, SeedLoad) {
    let path = seed_path
        .map(Path::to_path_buf)
        .unwrap_or_else(|| root.join(SEED_RELATIVE_PATH));
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) if seed_path.is_none() => return (None, SeedLoad::Absent),
        Err(_) => return (None, SeedLoad::Refused("unreadable".into())),
    };
    let seed = match parse_seed(&text) {
        Ok(s) => s,
        Err(e) => return (None, SeedLoad::Refused(e)),
    };
    if let Err(e) = check_cannot_loosen(&seed, protected, root) {
        return (None, SeedLoad::Refused(e));
    }
    let n = seed.rules.len();
    (Some(seed), SeedLoad::Loaded(n))
}

// ── evaluation ───────────────────────────────────────────────────────────────

/// The answer for one request: the strictest of the floor's and every matching
/// seed rule's; the seed's default when nothing matched. Ties go to the floor.
/// Decide one request AND append the decision to the per-host audit log
/// (order 1443-w9hf). Every caller goes through here, so the log is complete
/// by construction: `policy eval`, proc.run's pre-spawn check, and whatever
/// door calls the evaluator next.
pub fn evaluate(req: &Request, seed: Option<&Seed>, protected: &[String]) -> Decision {
    let d = decide(req, seed, protected);
    audit_decision(req, &d, None);
    d
}

/// The decision alone, with no side effect.
pub fn decide(req: &Request, seed: Option<&Seed>, protected: &[String]) -> Decision {
    let mut best = floor_decide(req, protected);
    if let Some(seed) = seed {
        for r in seed.rules.iter().filter(|r| r.matches(req)) {
            let stricter = best.as_ref().is_none_or(|b| r.decision > b.strictness);
            if !stricter {
                continue;
            }
            let why = r
                .why
                .clone()
                .unwrap_or_else(|| format!("seed rule `{}` in {SEED_RELATIVE_PATH}", r.id));
            let remedy = r.remedy.clone().unwrap_or_else(|| {
                format!(
                    "change or remove seed rule `{}` in {SEED_RELATIVE_PATH}",
                    r.id
                )
            });
            best = Some(match r.decision {
                Strictness::Allow => Decision::allow(&r.id, format!("ok:policy:allow:{}", r.id)),
                Strictness::Deny => {
                    Decision::deny(&r.id, format!("refused:policy:{}", r.id), &why, remedy)
                }
                Strictness::Consent => Decision::consent(&r.id, &why, remedy),
            });
        }
    }
    if let Some(d) = best {
        return d;
    }
    match seed.map(|s| &s.default) {
        Some(DefaultPolicy::Deny) => Decision::deny(
            "default-deny",
            "refused:policy:default-deny".into(),
            "the project seed denies a request no rule matches",
            format!(
                "add a rule for `{}` to {SEED_RELATIVE_PATH} (program, args, decision: allow)",
                program_name(&req.argv[0])
            ),
        ),
        _ => Decision::allow("default", "ok:policy:allow:default".into()),
    }
}

// ── the audit log (order 1443-w9hf) ─────────────────────────────────────────
//
// One JSONL line per decision, so the bridge hook's retirement condition
// (1443-we89: zero deny/ask from caller=pretooluse for 14 fleet days) and the
// "refusal storm" of a wrong rule are numbers. Per host, under .cache
// (gitignored); NEVER the shared timing path (1204-3s2s). The argv itself is
// not recorded: argv_digest is its sha256, and argv_shown is the argv passed
// through redact() first, so a line cannot carry a token.

pub const AUDIT_BASENAME: &str = "command-policy-audit.jsonl";

/// TILLANDSIAS_POLICY_AUDIT_LOG, else <checkout>/.cache/metrics/ when
/// `workspace` is a checkout (a `.git` directory), else
/// $HOME/.cache/tillandsias/metrics/.
pub fn audit_log_path(workspace: &Path) -> PathBuf {
    if let Ok(p) = std::env::var("TILLANDSIAS_POLICY_AUDIT_LOG")
        && !p.is_empty()
    {
        return PathBuf::from(p);
    }
    if workspace.join(".git").is_dir() {
        return workspace
            .join(".cache")
            .join("metrics")
            .join(AUDIT_BASENAME);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join(".cache")
        .join("tillandsias")
        .join("metrics")
        .join(AUDIT_BASENAME)
}

fn audit_append(path: &Path, line: &serde_json::Value) {
    if cfg!(test) || std::env::var("TILLANDSIAS_POLICY_AUDIT").as_deref() == Ok("off") {
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(f, "{line}");
    }
}

fn decision_word(s: Strictness) -> &'static str {
    match s {
        Strictness::Allow => "allow",
        Strictness::Deny => "deny",
        Strictness::Consent => "consent",
    }
}

/// Append one evaluator decision. `run_id` is the executor's run identity when
/// the decision guarded a spawn that happened.
pub fn audit_decision(req: &Request, d: &Decision, run_id: Option<&str>) {
    let argv_digest = crate::host_verbs::sha256_hex(req.argv.join("\0").as_bytes());
    let consent_source = if d.token == "ok:policy:soft-reset:forge-preauthorised" {
        Some("forge-policy")
    } else {
        None
    };
    let line = serde_json::json!({
        "ts": crate::host_verbs::now_rfc3339(),
        "run_id": run_id,
        "host_kind": req.host_kind.as_str(),
        "regime": req.regime,
        "caller": req.caller,
        "program": req.argv.first().map(|p| program_name(p)),
        "argv_digest": argv_digest,
        "argv_shown": shown(&req.argv),
        "rule_id": d.rule_id,
        "decision": decision_word(d.strictness),
        "consent_source": consent_source,
    });
    audit_append(&audit_log_path(&req.workspace), &line);
}

/// Append one Bash-tool bridge decision (order 1443-we89, caller=pretooluse).
/// The raw command is never recorded: only its digest (a command can carry a
/// secret no shape catches). `decision` is allow | consent | deny.
pub fn audit_bridge(
    workspace: &Path,
    host_kind: HostKind,
    command: &str,
    rule_id: &str,
    decision: &str,
    kill_switch: bool,
) {
    let line = serde_json::json!({
        "ts": crate::host_verbs::now_rfc3339(),
        "run_id": serde_json::Value::Null,
        "host_kind": host_kind.as_str(),
        "regime": "hook",
        "caller": "pretooluse",
        "program": "bash",
        "argv_digest": crate::host_verbs::sha256_hex(command.as_bytes()),
        "argv_shown": serde_json::Value::Null,
        "rule_id": rule_id,
        "decision": decision,
        "consent_source": serde_json::Value::Null,
        "kill_switch": if kill_switch { 1 } else { 0 },
    });
    audit_append(&audit_log_path(workspace), &line);
}

/// One summary row: (rule_id, decision) -> count.
pub type AuditRow = ((String, String), usize);

/// Count the log's lines per (rule_id, decision), optionally only those newer
/// than `since`, and optionally for one caller. `None` when there is no log.
pub fn audit_summary(
    path: &Path,
    since: Option<chrono::Duration>,
    caller: Option<&str>,
) -> Option<Vec<AuditRow>> {
    let text = std::fs::read_to_string(path).ok()?;
    let cutoff = since.map(|d| chrono::Utc::now() - d);
    let mut counts: std::collections::BTreeMap<(String, String), usize> =
        std::collections::BTreeMap::new();
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(c) = caller
            && v.get("caller").and_then(|x| x.as_str()) != Some(c)
        {
            continue;
        }
        if let Some(cut) = cutoff {
            let ts = v
                .get("ts")
                .and_then(|x| x.as_str())
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok());
            match ts {
                Some(t) if t >= cut => {}
                _ => continue,
            }
        }
        let rule = v.get("rule_id").and_then(|x| x.as_str()).unwrap_or("?");
        let dec = v.get("decision").and_then(|x| x.as_str()).unwrap_or("?");
        *counts
            .entry((rule.to_string(), dec.to_string()))
            .or_default() += 1;
    }
    Some(counts.into_iter().collect())
}

/// `24h`, `7d`, `30m`, `90s` -> a duration.
pub fn parse_since(s: &str) -> Option<chrono::Duration> {
    let (n, unit) = s.split_at(s.len().checked_sub(1)?);
    let n: i64 = n.parse().ok()?;
    Some(match unit {
        "s" => chrono::Duration::seconds(n),
        "m" => chrono::Duration::minutes(n),
        "h" => chrono::Duration::hours(n),
        "d" => chrono::Duration::days(n),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(argv: &[&str], k: HostKind) -> Request {
        Request {
            argv: argv.iter().map(|s| s.to_string()).collect(),
            cwd: PathBuf::from("/work/repo"),
            workspace: PathBuf::from("/work/repo"),
            host_kind: k,
            regime: "interactive".into(),
            caller: "test".into(),
        }
    }
    fn prot() -> Vec<String> {
        vec!["main".into(), "linux-next".into()]
    }
    fn tok(argv: &[&str], k: HostKind) -> String {
        evaluate(&req(argv, k), None, &prot()).token
    }

    #[test]
    fn credential_mutations_are_denied_and_status_is_not() {
        for a in [
            &["gh", "auth", "refresh"][..],
            &["gh", "--repo", "x/y", "auth", "login"],
            &["/usr/bin/gh", "auth", "token"],
            &["git", "-C", "/r", "credential", "approve"],
            &["vault", "login", "-method=token"],
        ] {
            assert_eq!(
                tok(a, HostKind::Forge),
                "refused:policy:no-credential-mutation",
                "{a:?}"
            );
        }
        assert_eq!(
            tok(&["gh", "auth", "status"], HostKind::Forge),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn shell_strings_are_denied_and_a_script_file_is_not() {
        assert_eq!(
            tok(&["bash", "-c", "a | b"], HostKind::BareMetal),
            "refused:policy:no-shell-strings"
        );
        assert_eq!(
            tok(&["PWSH.EXE", "-Command", "x"], HostKind::BareMetal),
            "refused:policy:no-shell-strings"
        );
        assert_eq!(
            tok(&["bash", "scripts/x.sh"], HostKind::BareMetal),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn resets_split_soft_and_hard_per_host_kind() {
        assert_eq!(
            tok(
                &["podman", "system", "reset", "--force"],
                HostKind::BareMetal
            ),
            "consent:policy:soft-reset"
        );
        assert_eq!(
            tok(&["podman", "system", "reset", "--force"], HostKind::Forge),
            "ok:policy:soft-reset:forge-preauthorised"
        );
        assert_eq!(
            tok(&["tillandsias", "--reset-state"], HostKind::Forge),
            "ok:policy:soft-reset:forge-preauthorised"
        );
        assert_eq!(
            tok(&["tillandsias-tray", "--reset-guest"], HostKind::BareMetal),
            "consent:policy:hard-reset"
        );
        assert_eq!(
            tok(&["tillandsias-tray.exe", "--reset-guest"], HostKind::Forge),
            "refused:policy:hard-reset:not-grantable-in-forge"
        );
        assert_eq!(
            tok(&["wsl", "--unregister", "d"], HostKind::BareMetal),
            "consent:policy:hard-reset"
        );
        assert_eq!(
            tok(&["podman", "ps"], HostKind::BareMetal),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn exit_codes_follow_the_decision() {
        assert_eq!(
            evaluate(
                &req(&["gh", "auth", "login"], HostKind::Forge),
                None,
                &prot()
            )
            .exit_code(),
            1
        );
        assert_eq!(
            evaluate(
                &req(&["podman", "system", "reset"], HostKind::BareMetal),
                None,
                &prot()
            )
            .exit_code(),
            4
        );
        assert_eq!(
            evaluate(&req(&["git", "status"], HostKind::BareMetal), None, &prot()).exit_code(),
            0
        );
    }

    #[test]
    fn rm_outside_the_workspace_needs_consent_and_inside_does_not() {
        assert_eq!(
            tok(&["rm", "-rf", "/etc"], HostKind::BareMetal),
            "consent:policy:workspace-destroy"
        );
        assert_eq!(
            tok(&["rm", "-rf", "../other"], HostKind::BareMetal),
            "consent:policy:workspace-destroy"
        );
        assert_eq!(
            tok(&["rm", "-rf", "."], HostKind::BareMetal),
            "consent:policy:workspace-destroy"
        );
        assert_eq!(
            tok(&["rm", "-rf", "target/x"], HostKind::BareMetal),
            "ok:policy:allow:default"
        );
        assert_eq!(
            tok(&["rm", "/etc/x"], HostKind::BareMetal),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn force_push_to_a_protected_ref_needs_consent() {
        assert_eq!(
            tok(
                &["git", "push", "--force", "origin", "linux-next"],
                HostKind::BareMetal
            ),
            "consent:policy:force-push"
        );
        assert_eq!(
            tok(
                &["git", "push", "origin", "+HEAD:refs/heads/main"],
                HostKind::BareMetal
            ),
            "consent:policy:force-push"
        );
        assert_eq!(
            tok(
                &["git", "push", "--force", "origin", "work/1443-isrk"],
                HostKind::BareMetal
            ),
            "ok:policy:allow:default"
        );
        assert_eq!(
            tok(
                &["git", "push", "origin", "linux-next"],
                HostKind::BareMetal
            ),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn a_forge_is_not_self_declared() {
        let r = read_host_kind_from(Some("forge"), false, false);
        assert_eq!(r.kind, HostKind::BareMetal);
        assert!(r.disagreement.is_some());
        let r = read_host_kind_from(Some("bare-metal"), true, false);
        assert_eq!(r.kind, HostKind::Forge);
        assert!(r.disagreement.is_some());
        let r = read_host_kind_from(None, false, true);
        assert_eq!((r.kind, r.disagreement.is_none()), (HostKind::Forge, true));
        assert_eq!(
            read_host_kind_from(Some("ci"), false, false).kind,
            HostKind::Ci
        );
    }

    #[test]
    fn a_seed_that_loosens_is_refused_whole_and_one_that_tightens_applies() {
        let loosen = "version: 1\nrules:\n  - id: let-me\n    program: gh\n    args: [auth, refresh]\n    decision: allow\n";
        let s = parse_seed(loosen).unwrap();
        assert_eq!(
            check_cannot_loosen(&s, &prot(), Path::new("/work/repo")),
            Err("cannot-loosen:no-credential-mutation".into())
        );
        let by_id = "version: 1\nrules:\n  - id: soft-reset\n    program: podman\n    args: [system, reset]\n    decision: allow\n    host_kinds: [forge]\n";
        let s = parse_seed(by_id).unwrap();
        assert_eq!(
            check_cannot_loosen(&s, &prot(), Path::new("/work/repo")),
            Err("cannot-loosen:soft-reset".into())
        );
        let tighten = "version: 1\nrules:\n  - id: no-soft-reset-in-forge\n    program: podman\n    args: [system, reset]\n    decision: deny\n    host_kinds: [forge]\n";
        let s = parse_seed(tighten).unwrap();
        assert!(check_cannot_loosen(&s, &prot(), Path::new("/work/repo")).is_ok());
        let d = evaluate(
            &req(&["podman", "system", "reset", "--force"], HostKind::Forge),
            Some(&s),
            &prot(),
        );
        assert_eq!(d.token, "refused:policy:no-soft-reset-in-forge");
    }

    #[test]
    fn a_looser_seed_rule_cannot_win_at_evaluation_either() {
        // Belt and braces: even a seed that skipped the load check cannot loosen.
        let s = Seed {
            default: DefaultPolicy::Allow,
            rules: vec![SeedRule {
                id: "x".into(),
                program: "gh".into(),
                args: vec!["auth".into()],
                any_arg: vec![],
                decision: Strictness::Allow,
                host_kinds: vec![],
                why: None,
                remedy: None,
            }],
        };
        let d = evaluate(
            &req(&["gh", "auth", "login"], HostKind::BareMetal),
            Some(&s),
            &prot(),
        );
        assert_eq!(d.token, "refused:policy:no-credential-mutation");
    }

    #[test]
    fn default_deny_names_the_rule_to_add_and_quiet_days_does_not_flip() {
        let s = parse_seed("version: 1\ndefault: deny\n").unwrap();
        let d = evaluate(&req(&["make"], HostKind::BareMetal), Some(&s), &prot());
        assert_eq!(d.token, "refused:policy:default-deny");
        assert!(d.remedy.unwrap().contains("make"));
        let s = parse_seed("version: 1\ndefault: {deny_after_quiet_days: 14}\n").unwrap();
        assert_eq!(s.default, DefaultPolicy::DenyAfterQuietDays(14));
        assert_eq!(
            evaluate(&req(&["make"], HostKind::BareMetal), Some(&s), &prot()).token,
            "ok:policy:allow:default"
        );
        assert!(parse_seed("version: 1\ndefault: {deny_after_quiet_days: 0}\n").is_err());
        assert!(parse_seed("version: 1\nbogus: 1\n").is_err());
    }

    #[test]
    fn tokens_never_reach_refusal_text() {
        let d = evaluate(
            &req(
                &["bash", "-c", "echo ghp_abcdefghijklmnopqrstuvwxyz0123"],
                HostKind::BareMetal,
            ),
            None,
            &prot(),
        );
        let r = d.remedy.unwrap();
        assert!(!r.contains("ghp_abc"), "{r}");
        assert!(r.contains("<redacted:token>"), "{r}");
    }
}
