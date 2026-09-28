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
// Landed since this slice: the audit log and `policy audit` (1443-w9hf), and
// consent TOKENS with the smoke-skill env authorisation (1443-9f5w, the consent
// section below). STILL OUT, by name, so nobody reads a green as more: the
// fixture-regime filesystem scope and the measured default flip.
// `deny_after_quiet_days` is PARSED and validated here, but the
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

/// Derive the host kind from `TILLANDSIAS_HOST_KIND` and the container
/// runtime's record of the image this process runs in (`image="…"` in
/// `/run/.containerenv`, written root-owned by podman; a forge agent runs
/// non-root and cannot rewrite it).
///
/// `root` is accepted for the callers' convenience and deliberately NOT
/// consulted: evidence never comes from a file in the workspace, which any
/// writer of a directory can plant (1467-c8qg: a stray
/// `/tmp/.forge-startup-context.md` made cwd=/tmp read as a forge on bare
/// metal). And the FILE'S PRESENCE is not evidence either: every podman
/// container has one, so the builder toolbox (where bare-metal gates run) and
/// a distrobox read as a forge by presence alone. Only the forge image names a
/// forge; any other container is `container-other`, treated as bare metal.
///
/// A FORGE NEEDS PHYSICAL EVIDENCE. The environment variable alone cannot
/// declare one, because a forge is where `soft-reset` is pre-authorised: a
/// variable that could claim it would be a way round the consent. Evidence
/// wins over the variable, and a disagreement between them is reported.
pub fn read_host_kind(_root: &Path) -> HostKindReading {
    let env = std::env::var("TILLANDSIAS_HOST_KIND").ok();
    let containerenv = std::fs::read_to_string("/run/.containerenv").ok();
    read_host_kind_from(env.as_deref(), containerenv.as_deref())
}

/// The `image="…"` value of a `/run/.containerenv` record.
pub fn containerenv_image(record: &str) -> Option<&str> {
    record.lines().find_map(|l| {
        l.trim()
            .strip_prefix("image=")
            .map(|v| v.trim_matches('"'))
            .filter(|v| !v.is_empty())
    })
}

/// Whether an image reference is the Tillandsias forge image
/// (`[registry/…/]tillandsias-forge[:tag][@digest]`), and nothing else:
/// `tillandsias-forge-base` is a build stage, never a running forge.
pub fn is_forge_image(image: &str) -> bool {
    let no_digest = image.split('@').next().unwrap_or("");
    let last = no_digest.rsplit('/').next().unwrap_or("");
    last.split(':').next() == Some("tillandsias-forge")
}

/// Pure half of [`read_host_kind`], so the rule is testable without a
/// container. `containerenv` is the record's content, `None` when absent.
pub fn read_host_kind_from(env: Option<&str>, containerenv: Option<&str>) -> HostKindReading {
    let env_kind = env.and_then(HostKind::parse);
    let image = containerenv.and_then(containerenv_image);
    if image.is_some_and(is_forge_image) {
        let image = image.unwrap_or_default();
        let disagreement = match (env, env_kind) {
            (Some(e), Some(k)) if k != HostKind::Forge => Some(format!(
                "TILLANDSIAS_HOST_KIND={e} but /run/.containerenv names the forge image {image}"
            )),
            (Some(e), None) => Some(format!(
                "TILLANDSIAS_HOST_KIND={e} is not a host kind; /run/.containerenv names the \
                 forge image {image}"
            )),
            _ => None,
        };
        return HostKindReading {
            kind: HostKind::Forge,
            source: "evidence",
            disagreement,
        };
    }
    let fallback = if containerenv.is_some() {
        "container-other"
    } else {
        "default"
    };
    match (env, env_kind) {
        (Some(e), Some(HostKind::Forge)) => HostKindReading {
            kind: HostKind::BareMetal,
            source: fallback,
            disagreement: Some(format!(
                "TILLANDSIAS_HOST_KIND={e} but no container record names the forge image \
                 (image={}); a forge is not self-declared",
                image.unwrap_or("none")
            )),
        },
        (Some(_), Some(k)) => HostKindReading {
            kind: k,
            source: "env",
            disagreement: None,
        },
        (Some(e), None) => HostKindReading {
            kind: HostKind::BareMetal,
            source: fallback,
            disagreement: Some(format!("TILLANDSIAS_HOST_KIND={e} is not a host kind")),
        },
        (None, _) => HostKindReading {
            kind: HostKind::BareMetal,
            source: fallback,
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
pub const FLOOR_RULES: [&str; 7] = [
    "no-shell-strings",
    "no-credential-mutation",
    "no-self-consent",
    "hard-reset",
    "soft-reset",
    "workspace-destroy",
    "force-push",
];

const CONSENT_GRANT: &str = "the operator runs it themselves, or grants this one run with \
    `tillandsias-plan policy consent grant <class> -- <this exact argv>` in their own terminal \
    on the host (never in a forge)";

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

/// `tillandsias-plan [--index p] policy consent grant …`: minting a consent
/// token (order 1443-9f5w). Only the operator mints, in their own terminal; an
/// agent door that could mint would make every consent class self-granted.
fn is_consent_grant(argv: &[String]) -> bool {
    if program_name(&argv[0]) != "tillandsias-plan" {
        return false;
    }
    let w = positional_words(&argv[1..], &["--index"]);
    w.len() >= 3 && w[0] == "policy" && w[1] == "consent" && w[2] == "grant"
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
    if is_consent_grant(&req.argv) {
        return Some(Decision::deny(
            "no-self-consent",
            "refused:policy:no-self-consent".into(),
            "a consent token is the OPERATOR's approval of one run; minted through an agent \
             door it would approve itself (operator ruling 3, 2026-09-27; order 1443-9f5w)",
            "ask the operator to run `tillandsias-plan policy consent grant <class> -- <argv…>` \
             in their own terminal on the host (in Claude Code the operator can prefix it \
             with `!`); never from a forge"
                .into(),
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
    // A consent is resolved HERE, where the request then proceeds: a token is
    // spent only by a decision that is acted on (1443-9f5w). Never under unit
    // tests, which must not spend a real token on a developer's host: those
    // call resolve_consent with a scratch ConsentCtx.
    let d = if d.strictness == Strictness::Consent && !cfg!(test) {
        resolve_consent(req, d, &ConsentCtx::from_env(&req.workspace))
    } else {
        d
    };
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

// ── consent (order 1443-9f5w) ───────────────────────────────────────────────
//
// Operator ruling 3, 2026-09-27: "Forges should keep pre-authorizing SOFT RESET
// always. HARD RESET should require explicit approval each time." A consent
// answer becomes an allow in exactly three ways, and the audit records which
// (`consent_source`):
//   forge-policy  soft-reset in a forge (floor_decide answers allow itself);
//   env           soft-reset on bare metal when TILLANDSIAS_DESTRUCTIVE_RESET_OK=1
//                 AND TILLANDSIAS_SKILL names a registered smoke skill
//                 (methodology.yaml destructive_reset_policy): never hard-reset,
//                 never any other class;
//   token         a per-run token the OPERATOR minted on this host with
//                 `policy consent grant <class> -- <argv…>`: bound to the host,
//                 the class, the EXACT argv (its sha256) and an expiry, spent by
//                 the first matching run through an atomic rename, so two racing
//                 runs cannot both spend it.
// Tokens count only where the host-kind EVIDENCE says bare metal, never on the
// strength of `--host-kind` or the variable alone. Minting is refused in a
// forge or CI, and the floor denies `policy consent grant` through every agent
// door (no-self-consent), so an agent cannot approve itself.
//
// NOT A SECRET, BY NAME: a token is a file in the operator's runtime dir, and a
// process running as the same uid could write one. The gate stops an agent's
// mistake and a peer's instruction, not a hostile process on the operator's
// account.

/// The floor's consent classes, the only ones a token or the env can satisfy.
/// A project seed's own consent rules stay consent: the operator runs those.
pub const CONSENT_CLASSES: [&str; 4] = [
    "soft-reset",
    "hard-reset",
    "workspace-destroy",
    "force-push",
];

/// methodology.yaml, the skills whose `destructive_reset_policy` pre-authorises
/// the substrate reset.
pub const REGISTERED_SMOKE_SKILLS: [&str; 2] = [
    "smoke-curl-install-and-test-e2e",
    "build-install-and-smoke-test-e2e",
];

pub const CONSENT_DEFAULT_TTL_SECS: i64 = 30 * 60;
pub const CONSENT_MAX_TTL_SECS: i64 = 24 * 60 * 60;
const CONSUMED_LEDGER: &str = "consumed.jsonl";

/// TILLANDSIAS_CONSENT_DIR, else $XDG_RUNTIME_DIR/tillandsias/consent, else
/// $HOME/.cache/tillandsias/consent.
pub fn consent_dir() -> PathBuf {
    for (var, tail) in [
        ("TILLANDSIAS_CONSENT_DIR", None),
        ("XDG_RUNTIME_DIR", Some(["tillandsias", "consent"])),
    ] {
        if let Ok(p) = std::env::var(var)
            && !p.is_empty()
        {
            let mut out = PathBuf::from(p);
            for t in tail.into_iter().flatten() {
                out.push(t);
            }
            return out;
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join(".cache")
        .join("tillandsias")
        .join("consent")
}

/// This host's name, lowercased, with no process spawned.
pub fn this_host() -> String {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: `buf` is valid for `buf.len()` bytes; a truncated name is cut
        // at the first NUL or the buffer's end below.
        let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
        if rc == 0 {
            let n = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            if n > 0 {
                return String::from_utf8_lossy(&buf[..n]).to_lowercase();
            }
        }
    }
    #[cfg(windows)]
    {
        if let Ok(h) = std::env::var("COMPUTERNAME")
            && !h.is_empty()
        {
            return h.to_lowercase();
        }
    }
    "unknown-host".into()
}

pub fn argv_digest(argv: &[String]) -> String {
    crate::host_verbs::sha256_hex(argv.join("\0").as_bytes())
}

/// Everything consent reads, gathered once so the rules are testable without
/// the process environment.
#[derive(Debug, Clone)]
pub struct ConsentCtx {
    pub dir: PathBuf,
    pub host: String,
    pub now: chrono::DateTime<chrono::Utc>,
    /// The host kind from EVIDENCE (read_host_kind), never from a flag.
    pub evidence: HostKind,
    pub skill: Option<String>,
    pub reset_ok: Option<String>,
}

impl ConsentCtx {
    pub fn from_env(workspace: &Path) -> ConsentCtx {
        ConsentCtx {
            dir: consent_dir(),
            host: this_host(),
            now: chrono::Utc::now(),
            evidence: read_host_kind(workspace).kind,
            skill: std::env::var("TILLANDSIAS_SKILL").ok(),
            reset_ok: std::env::var("TILLANDSIAS_DESTRUCTIVE_RESET_OK").ok(),
        }
    }
}

/// Why minting is refused here, or None. `env_kind` is TILLANDSIAS_HOST_KIND
/// as set: a forge is refused on the variable OR the evidence, the stricter of
/// the two, because refusing is the safe error.
pub fn grant_refusal(env_kind: Option<&str>, evidence: HostKind) -> Option<&'static str> {
    let env = env_kind.and_then(HostKind::parse);
    if evidence == HostKind::Forge || env == Some(HostKind::Forge) {
        return Some("refused:consent:not-grantable-in-forge");
    }
    if evidence == HostKind::Ci || env == Some(HostKind::Ci) {
        return Some("refused:consent:not-grantable-in-ci");
    }
    None
}

/// Mint one token. Returns its path and expiry. The caller has checked
/// [`grant_refusal`] and that `argv` is of `class` on this host.
pub fn consent_grant(
    ctx: &ConsentCtx,
    class: &str,
    argv: &[String],
    ttl_secs: i64,
) -> std::io::Result<(PathBuf, chrono::DateTime<chrono::Utc>)> {
    let until = ctx.now + chrono::Duration::seconds(ttl_secs);
    std::fs::create_dir_all(&ctx.dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&ctx.dir, std::fs::Permissions::from_mode(0o700))?;
    }
    let id = format!(
        "{class}-{}-{}",
        ctx.now.format("%Y%m%dT%H%M%S%.9fZ"),
        std::process::id()
    );
    let token = serde_json::json!({
        "version": 1,
        "id": id,
        "class": class,
        "host": ctx.host,
        "argv_digest": argv_digest(argv),
        "argv_shown": shown(argv),
        "granted_at": ctx.now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "expires_at": until.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    });
    let path = ctx.dir.join(format!("{id}.json"));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    use std::io::Write;
    let mut f = opts.open(&path)?;
    writeln!(f, "{token}")?;
    Ok((path, until))
}

/// What the store held for one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenCheck {
    /// A matching token was spent; its id.
    Consumed(String),
    /// Only unusable tokens: foreign-host, expired and malformed ones were
    /// deleted; argv-mismatch ones are kept (they approve a different run).
    Invalid(&'static str),
    /// No token of this class. `replayed_at` when this exact argv already
    /// spent one, so the answer can say a token is single-use.
    NoToken { replayed_at: Option<String> },
}

/// Spend a token for `class` and `argv`, if one is valid. SIDE EFFECT: only on
/// a path that then proceeds (evaluate, the run door).
pub fn consent_consume(ctx: &ConsentCtx, class: &str, argv: &[String]) -> TokenCheck {
    let digest = argv_digest(argv);
    let mut paths: Vec<PathBuf> = match std::fs::read_dir(&ctx.dir) {
        Ok(rd) => rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.extension().is_some_and(|x| x == "json")
                    && p.file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with(&format!("{class}-")))
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    paths.sort();
    let mut invalid: Option<&'static str> = None;
    for p in paths {
        let t: Option<serde_json::Value> = std::fs::read_to_string(&p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok());
        let field = |k: &str| {
            t.as_ref()
                .and_then(|t| t.get(k))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        };
        let expires = chrono::DateTime::parse_from_rfc3339(&field("expires_at"))
            .ok()
            .map(|d| d.with_timezone(&chrono::Utc));
        let unusable = if t.is_none() || field("class") != class || expires.is_none() {
            Some("malformed")
        } else if field("host") != ctx.host {
            Some("foreign-host")
        } else if expires.is_some_and(|e| e <= ctx.now) {
            Some("expired")
        } else {
            None
        };
        if let Some(reason) = unusable {
            let _ = std::fs::remove_file(&p);
            invalid.get_or_insert(reason);
            continue;
        }
        if field("argv_digest") != digest {
            invalid.get_or_insert("argv-mismatch");
            continue;
        }
        // Spend it: the rename is the claim, so a racing run that loses finds
        // no file and moves on.
        let claimed = p.with_extension(format!("spent-{}", std::process::id()));
        if std::fs::rename(&p, &claimed).is_err() {
            continue;
        }
        let _ = std::fs::remove_file(&claimed);
        let id = field("id");
        let line = serde_json::json!({
            "id": id,
            "class": class,
            "argv_digest": digest,
            "consumed_at": ctx.now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        });
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(ctx.dir.join(CONSUMED_LEDGER))
        {
            use std::io::Write;
            let _ = writeln!(f, "{line}");
        }
        return TokenCheck::Consumed(id);
    }
    if let Some(reason) = invalid {
        return TokenCheck::Invalid(reason);
    }
    let replayed_at = std::fs::read_to_string(ctx.dir.join(CONSUMED_LEDGER))
        .ok()
        .and_then(|s| {
            s.lines()
                .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
                .rfind(|v| {
                    v.get("argv_digest").and_then(|x| x.as_str()) == Some(digest.as_str())
                        && v.get("class").and_then(|x| x.as_str()) == Some(class)
                })
                .and_then(|v| {
                    v.get("consumed_at")
                        .and_then(|x| x.as_str())
                        .map(String::from)
                })
        });
    TokenCheck::NoToken { replayed_at }
}

/// Turn a floor consent answer into an allow when the env mapping or a token
/// satisfies it; otherwise the same consent (never a new ASK: only the floor's
/// classes reach here, and a failed token is a refusal, not a question).
pub fn resolve_consent(req: &Request, d: Decision, ctx: &ConsentCtx) -> Decision {
    if d.strictness != Strictness::Consent || !CONSENT_CLASSES.contains(&d.rule_id.as_str()) {
        return d;
    }
    if req.host_kind != HostKind::BareMetal || ctx.evidence != HostKind::BareMetal {
        return d;
    }
    let class = d.rule_id.clone();
    if class == "soft-reset"
        && ctx.reset_ok.as_deref() == Some("1")
        && ctx
            .skill
            .as_deref()
            .is_some_and(|s| REGISTERED_SMOKE_SKILLS.contains(&s))
    {
        return Decision::allow(
            "soft-reset",
            "ok:policy:soft-reset:env-preauthorised".into(),
        );
    }
    match consent_consume(ctx, &class, &req.argv) {
        TokenCheck::Consumed(_) => Decision::allow(&class, format!("ok:policy:{class}:consented")),
        TokenCheck::Invalid(reason) => Decision::deny(
            &class,
            format!("refused:consent:invalid:{reason}"),
            match reason {
                "argv-mismatch" => {
                    "the consent token for this class approves a DIFFERENT argv; a token \
                     approves exactly the run it was minted for"
                }
                "expired" => "the consent token for this class expired unused and was deleted",
                "foreign-host" => {
                    "the consent token was minted on another host and was deleted; consent \
                     is per host"
                }
                _ => "an unreadable consent token was deleted",
            },
            format!(
                "the operator mints a fresh one for exactly this run: `tillandsias-plan policy \
                 consent grant {class} -- {}`",
                shown(&req.argv)
            ),
        ),
        TokenCheck::NoToken {
            replayed_at: Some(ts),
        } => Decision {
            why: Some(format!(
                "{}; a consent token for this exact argv was already spent at {ts}, and each \
                 run needs its own",
                d.why.as_deref().unwrap_or("consent required")
            )),
            ..d
        },
        TokenCheck::NoToken { replayed_at: None } => d,
    }
}

/// `consent_source` for the audit, read off the decision's verdict token.
pub fn consent_source(d: &Decision) -> Option<&'static str> {
    if d.strictness != Strictness::Allow {
        return None;
    }
    if d.token.ends_with(":forge-preauthorised") {
        Some("forge-policy")
    } else if d.token.ends_with(":env-preauthorised") {
        Some("env")
    } else if d.token.ends_with(":consented") {
        Some("token")
    } else {
        None
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
    let consent_source = consent_source(d);
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
        const FORGE: &str = "engine=\"podman-5.8.7\"\nname=\"forge-x\"\nimage=\"localhost/tillandsias-forge:v0.5.1\"\nrootless=1\n";
        const TOOLBOX: &str = "engine=\"podman-5.8.7\"\nname=\"tillandsias-builder\"\nimage=\"registry.fedoraproject.org/fedora-toolbox:44\"\nrootless=1\n";
        let r = read_host_kind_from(Some("forge"), None);
        assert_eq!(r.kind, HostKind::BareMetal);
        assert!(r.disagreement.is_some());
        let r = read_host_kind_from(Some("bare-metal"), Some(FORGE));
        assert_eq!(r.kind, HostKind::Forge);
        assert!(r.disagreement.is_some());
        let r = read_host_kind_from(None, Some(FORGE));
        assert_eq!((r.kind, r.disagreement.is_none()), (HostKind::Forge, true));
        assert_eq!(read_host_kind_from(None, None).kind, HostKind::BareMetal);
        // Presence is not evidence: a toolbox, an empty record, a base stage.
        let r = read_host_kind_from(None, Some(TOOLBOX));
        assert_eq!((r.kind, r.source), (HostKind::BareMetal, "container-other"));
        let r = read_host_kind_from(Some("forge"), Some(TOOLBOX));
        assert_eq!(r.kind, HostKind::BareMetal);
        assert!(r.disagreement.is_some());
        assert_eq!(
            read_host_kind_from(None, Some("")).kind,
            HostKind::BareMetal
        );
        assert!(is_forge_image("tillandsias-forge"));
        assert!(is_forge_image(
            "localhost/tillandsias-forge:latest@sha256:ab"
        ));
        assert!(!is_forge_image("localhost/tillandsias-forge-base:v1"));
        assert!(!is_forge_image("docker.io/evil/not-tillandsias-forge:v1"));
        assert_eq!(read_host_kind_from(Some("ci"), None).kind, HostKind::Ci);
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

    // ── consent (order 1443-9f5w) ───────────────────────────────────────────

    fn ctx(dir: &Path, evidence: HostKind) -> ConsentCtx {
        ConsentCtx {
            dir: dir.to_path_buf(),
            host: "hosta".into(),
            now: chrono::DateTime::parse_from_rfc3339("2026-09-28T12:00:00Z")
                .unwrap()
                .with_timezone(&chrono::Utc),
            evidence,
            skill: None,
            reset_ok: None,
        }
    }
    fn sv(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }
    const HARD: &[&str] = &["wsl", "--unregister", "tillandsias"];
    const SOFT: &[&str] = &["podman", "system", "reset", "--force"];

    fn resolve(argv: &[&str], c: &ConsentCtx) -> Decision {
        let r = req(argv, HostKind::BareMetal);
        let d = decide(&r, None, &prot());
        resolve_consent(&r, d, c)
    }

    #[test]
    fn a_token_approves_one_run_of_its_exact_argv_and_a_replay_asks_again() {
        let t = tempfile::tempdir().unwrap();
        let c = ctx(t.path(), HostKind::BareMetal);
        assert_eq!(resolve(HARD, &c).token, "consent:policy:hard-reset");
        let (path, until) = consent_grant(&c, "hard-reset", &sv(HARD), 1800).unwrap();
        assert_eq!(until.to_rfc3339(), "2026-09-28T12:30:00+00:00");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        let d = resolve(HARD, &c);
        assert_eq!(d.token, "ok:policy:hard-reset:consented");
        assert_eq!(consent_source(&d), Some("token"));
        assert!(!path.exists(), "a spent token is gone");
        let again = resolve(HARD, &c);
        assert_eq!(again.token, "consent:policy:hard-reset");
        assert_eq!(again.exit_code(), EXIT_CONSENT);
        assert!(
            again
                .why
                .unwrap()
                .contains("already spent at 2026-09-28T12:00:00Z")
        );
    }

    #[test]
    fn a_different_argv_is_refused_by_name_and_the_token_survives_for_its_own_run() {
        let t = tempfile::tempdir().unwrap();
        let c = ctx(t.path(), HostKind::BareMetal);
        let (path, _) = consent_grant(&c, "hard-reset", &sv(HARD), 1800).unwrap();
        let d = resolve(&["wsl", "--unregister", "other-distro"], &c);
        assert_eq!(d.token, "refused:consent:invalid:argv-mismatch");
        assert_eq!(d.exit_code(), EXIT_DENY);
        assert!(
            d.remedy
                .unwrap()
                .contains("consent grant hard-reset -- wsl --unregister other-distro")
        );
        assert!(path.exists());
        assert_eq!(resolve(HARD, &c).token, "ok:policy:hard-reset:consented");
    }

    #[test]
    fn a_foreign_host_or_expired_token_is_refused_and_deleted() {
        let t = tempfile::tempdir().unwrap();
        let mut other = ctx(t.path(), HostKind::BareMetal);
        other.host = "hostb".into();
        let (p1, _) = consent_grant(&other, "hard-reset", &sv(HARD), 1800).unwrap();
        let c = ctx(t.path(), HostKind::BareMetal);
        assert_eq!(
            resolve(HARD, &c).token,
            "refused:consent:invalid:foreign-host"
        );
        assert!(!p1.exists());

        let (p2, _) = consent_grant(&c, "hard-reset", &sv(HARD), 60).unwrap();
        let mut later = c.clone();
        later.now += chrono::Duration::seconds(61);
        assert_eq!(
            resolve(HARD, &later).token,
            "refused:consent:invalid:expired"
        );
        assert!(!p2.exists());
    }

    #[test]
    fn a_token_is_never_honoured_without_bare_metal_evidence() {
        let t = tempfile::tempdir().unwrap();
        let bare = ctx(t.path(), HostKind::BareMetal);
        let (path, _) = consent_grant(
            &bare,
            "workspace-destroy",
            &sv(&["rm", "-rf", "/srv/x"]),
            1800,
        )
        .unwrap();
        let in_forge = ctx(t.path(), HostKind::Forge);
        let r = req(&["rm", "-rf", "/srv/x"], HostKind::BareMetal);
        let d = resolve_consent(&r, decide(&r, None, &prot()), &in_forge);
        assert_eq!(d.token, "consent:policy:workspace-destroy");
        // Nor on the strength of a CLAIMED kind: the evidence says bare metal
        // but the request says ci.
        let r_ci = req(&["rm", "-rf", "/srv/x"], HostKind::Ci);
        let d = resolve_consent(&r_ci, decide(&r_ci, None, &prot()), &bare);
        assert_eq!(d.strictness, Strictness::Consent);
        assert!(path.exists(), "an unhonoured token is not spent");
        // Hard reset in a forge is a floor DENY, which no token reaches.
        let r_f = req(HARD, HostKind::Forge);
        let d = resolve_consent(&r_f, decide(&r_f, None, &prot()), &in_forge);
        assert_eq!(d.token, "refused:policy:hard-reset:not-grantable-in-forge");
    }

    #[test]
    fn the_smoke_skill_env_preauthorises_soft_reset_only() {
        let t = tempfile::tempdir().unwrap();
        let mut c = ctx(t.path(), HostKind::BareMetal);
        c.reset_ok = Some("1".into());
        assert_eq!(
            resolve(SOFT, &c).token,
            "consent:policy:soft-reset",
            "no skill: asks"
        );
        c.skill = Some("some-other-skill".into());
        assert_eq!(resolve(SOFT, &c).token, "consent:policy:soft-reset");
        for s in REGISTERED_SMOKE_SKILLS {
            c.skill = Some(s.into());
            let d = resolve(SOFT, &c);
            assert_eq!(d.token, "ok:policy:soft-reset:env-preauthorised");
            assert_eq!(consent_source(&d), Some("env"));
            assert_eq!(
                resolve(HARD, &c).token,
                "consent:policy:hard-reset",
                "never hard-reset"
            );
            assert_eq!(
                resolve(&["rm", "-rf", "/srv/x"], &c).token,
                "consent:policy:workspace-destroy"
            );
        }
        c.reset_ok = Some("0".into());
        assert_eq!(
            resolve(SOFT, &c).token,
            "consent:policy:soft-reset",
            "=0 opts out"
        );
    }

    #[test]
    fn minting_is_refused_in_a_forge_or_ci_by_variable_or_evidence() {
        assert_eq!(
            grant_refusal(Some("forge"), HostKind::BareMetal),
            Some("refused:consent:not-grantable-in-forge")
        );
        assert_eq!(
            grant_refusal(None, HostKind::Forge),
            Some("refused:consent:not-grantable-in-forge")
        );
        assert_eq!(
            grant_refusal(Some("bare-metal"), HostKind::Forge),
            Some("refused:consent:not-grantable-in-forge")
        );
        assert_eq!(
            grant_refusal(Some("ci"), HostKind::Ci),
            Some("refused:consent:not-grantable-in-ci")
        );
        assert_eq!(grant_refusal(None, HostKind::BareMetal), None);
    }

    #[test]
    fn an_agent_door_cannot_mint_consent() {
        for a in [
            &[
                "tillandsias-plan",
                "policy",
                "consent",
                "grant",
                "hard-reset",
                "--",
                "wsl",
            ][..],
            &[
                "/x/target/release/tillandsias-plan",
                "--index",
                "p",
                "policy",
                "consent",
                "grant",
            ],
        ] {
            for k in HostKind::ALL {
                assert_eq!(tok(a, k), "refused:policy:no-self-consent", "{a:?} {k:?}");
            }
        }
        assert_eq!(
            tok(
                &["tillandsias-plan", "policy", "eval", "--", "git", "status"],
                HostKind::BareMetal
            ),
            "ok:policy:allow:default"
        );
    }

    #[test]
    fn consent_source_names_all_three_ways_and_nothing_else() {
        let t = tempfile::tempdir().unwrap();
        let c = ctx(t.path(), HostKind::Forge);
        let r = req(SOFT, HostKind::Forge);
        let d = resolve_consent(&r, decide(&r, None, &prot()), &c);
        assert_eq!(consent_source(&d), Some("forge-policy"));
        assert_eq!(
            consent_source(&decide(
                &req(&["git", "status"], HostKind::Forge),
                None,
                &prot()
            )),
            None
        );
        assert_eq!(
            consent_source(&decide(&req(HARD, HostKind::BareMetal), None, &prot())),
            None
        );
    }
}
