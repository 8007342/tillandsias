// @trace order:1443-w79y, spec:branch-discipline
//
// ORDER 1443-w79y — the per-project BRANCH DISCIPLINE SEED and the questions
// every tool asks of it.
//
// TODAY THE BRANCH MODEL LIVES IN THREE PLACES WITH THREE ANSWERS: prose in
// methodology/multi-host-development.yaml, an env-var regex in the git
// mirror's entrypoint that does not admit `work/<order>`, and a hook that
// hardcodes "linux-next". `.tillandsias/branch-discipline.yaml` is the one
// answer they all read; this module parses it, validates it, and answers
// `show`, `target` and `check-ref`.
//
// TWO AXES (operator ruling 2026-09-22, 1363-xp2v): `level` is how far up the
// ladder the project has climbed (0 bare, 1 integration branch + PRs, 2 work
// refs into the integration branch; forward-only), and `enforcement` is how
// hard EACH RULE is applied (advised | warn | enforced). A project with NO seed
// is level 0 advised and nothing is ever refused: the floor is absolute.
//
// NO PROCESS SPAWNS. The default branch and any previously published level are
// read from the git directory's files, so the verb answers the same way on a
// host with no git on PATH and inside a forge.

use regex::Regex;
use serde_json::{Value as Json, json};
use serde_yaml::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const SEED_RELATIVE_PATH: &str = ".tillandsias/branch-discipline.yaml";
pub const ENFORCEMENTS: [&str; 3] = ["advised", "warn", "enforced"];
pub const RULES: [&str; 2] = ["default_branch", "ref_grammar"];
pub const PLATFORMS: [&str; 4] = ["linux", "forge", "windows", "macos"];

/// Where the answer came from. `Default` is the built-in level-0 floor, used
/// when the project has no seed OR its seed was refused at load.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Seed,
    Default,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Seed => "seed",
            Source::Default => "default",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Discipline {
    pub source: Source,
    pub level: u8,
    /// Per-rule enforcement; a rule the seed does not name is `advised`.
    pub enforcement: BTreeMap<String, String>,
    pub default_branch: String,
    pub integration: BTreeMap<String, String>,
    pub work_ref: Option<String>,
    pub salvage_ref: Option<String>,
    pub plan_only_paths: Vec<String>,
    pub freeze_namespace: Option<String>,
    pub default_branch_denied: Option<String>,
    pub seed_path: Option<PathBuf>,
    /// sha256 of the seed's bytes, the same value `tillandsias-plan hash
    /// sha256 <seed>` prints, so a mirror-published digest can be compared.
    pub digest: Option<String>,
    /// `refused:discipline-seed:<reason>` when a present seed was refused.
    pub refusal: Option<String>,
}

impl Discipline {
    /// The built-in floor: level 0, every rule advised, every ref admitted.
    pub fn floor(default_branch: String) -> Self {
        Discipline {
            source: Source::Default,
            level: 0,
            enforcement: RULES
                .iter()
                .map(|r| (r.to_string(), "advised".to_string()))
                .collect(),
            default_branch,
            integration: BTreeMap::new(),
            work_ref: None,
            salvage_ref: None,
            plan_only_paths: Vec::new(),
            freeze_namespace: None,
            default_branch_denied: None,
            seed_path: None,
            digest: None,
            refusal: None,
        }
    }

    pub fn enforcement_of(&self, rule: &str) -> &str {
        self.enforcement
            .get(rule)
            .map(String::as_str)
            .unwrap_or("advised")
    }

    /// The branch a platform integrates on. At level 0, or for a platform the
    /// seed does not name, the default branch.
    pub fn target(&self, platform: &str) -> &str {
        if self.level == 0 {
            return &self.default_branch;
        }
        self.integration
            .get(platform)
            .map(String::as_str)
            .unwrap_or(&self.default_branch)
    }

    /// `messages.default_branch_denied` with `{default}`, `{integration}` and
    /// `{work_ref}` substituted from the seed.
    pub fn denied_message(&self, platform: Option<&str>) -> String {
        let integration = match platform {
            Some(p) => self.target(p).to_string(),
            None => {
                let mut branches: Vec<&str> =
                    self.integration.values().map(String::as_str).collect();
                branches.sort_unstable();
                branches.dedup();
                branches.join("|")
            }
        };
        let template = self.default_branch_denied.clone().unwrap_or_else(|| {
            "push to {default} denied: this project uses branch {integration} for \
             integration and {work_ref} for work; switch to the corresponding branch and \
             rebase to remote"
                .to_string()
        });
        template
            .replace("{default}", &self.default_branch)
            .replace("{integration}", &integration)
            .replace(
                "{work_ref}",
                self.work_ref.as_deref().unwrap_or("work/<id>"),
            )
    }

    pub fn to_json(&self) -> Json {
        json!({
            "source": self.source.as_str(),
            "level": self.level,
            "enforcement": self.enforcement,
            "default_branch": self.default_branch,
            "integration": self.integration,
            "work_ref": self.work_ref,
            "salvage_ref": self.salvage_ref,
            "plan_only_lane": { "paths": self.plan_only_paths },
            "freeze_namespace": self.freeze_namespace,
            "messages": { "default_branch_denied": self.default_branch_denied },
            "seed_path": self.seed_path.as_ref().map(|p| p.display().to_string()),
            "digest": self.digest,
            "refusal": self.refusal,
        })
    }

    /// One-line provenance every answer carries. The floor always says
    /// `enforcement=advised` (spec: every default answer names it); a seed's
    /// answer names the rule it applied, or `-` when none was involved.
    pub fn provenance(&self, rule: Option<&str>) -> String {
        let enforcement = match (self.source, rule) {
            (Source::Default, _) => "advised",
            (Source::Seed, Some(r)) => self.enforcement_of(r),
            (Source::Seed, None) => "-",
        };
        format!(
            "source={} level={} enforcement={enforcement}",
            self.source.as_str(),
            self.level
        )
    }
}

/// A check-ref answer: the verdict line plus why/remedy for anything that is
/// not a plain `ok:`, and whether a caller should treat it as a refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefAnswer {
    pub verdict: String,
    pub why: Option<String>,
    pub remedy: Option<String>,
    pub refused: bool,
    pub rule: Option<&'static str>,
}

fn ok(class: &str) -> RefAnswer {
    RefAnswer {
        verdict: format!("ok:discipline:{class}"),
        why: None,
        remedy: None,
        refused: false,
        rule: None,
    }
}

/// Answer a rule at its enforcement: enforced refuses, warn and advised admit
/// with a named token.
fn at_enforcement(
    d: &Discipline,
    reality: Option<&Derived>,
    rule: &'static str,
    token: &str,
    why: String,
    remedy: String,
) -> RefAnswer {
    let e = d.enforcement_of(rule);
    // ORDER 1446-664f — REFUSE ONLY WHERE SEED AND REALITY AGREE. An enforced
    // rule whose qualifier was OBSERVED ABSENT degrades to a warning that names
    // the missing qualifier; one that could not be observed keeps the seed's
    // word (an unobservable fact is not evidence of drift).
    if e == "enforced"
        && let Some(r) = reality
        && let Some(missing) = r.missing_for(rule_level(rule))
    {
        return RefAnswer {
            verdict: format!("warn:discipline:{token}:seed-ahead-of-reality"),
            why: Some(why),
            remedy: Some(format!(
                "the seed enforces this rule at level {}, but the project does not yet show \
                 {missing}; the rule warns instead of refusing until that is observed \
                 (`tillandsias-plan discipline derive` shows every qualifier)",
                d.level
            )),
            refused: false,
            rule: Some(rule),
        };
    }
    let (verdict, refused) = match e {
        "enforced" => (format!("refused:discipline:{token}:enforced"), true),
        "warn" => (format!("warn:discipline:{token}"), false),
        _ => (format!("advised:discipline:{token}"), false),
    };
    RefAnswer {
        verdict,
        why: Some(why),
        remedy: Some(remedy),
        refused,
        rule: Some(rule),
    }
}

/// `salvage/<host>/<yyyymmdd>-<slug>` → an anchored regex.
fn salvage_regex(pattern: &str) -> Option<Regex> {
    let mut re = regex::escape(pattern);
    for (placeholder, class) in [
        ("<host>", "[^/]+"),
        ("<yyyymmdd>", "[0-9]{8}"),
        ("<slug>", "[^/]+"),
    ] {
        re = re.replace(&regex::escape(placeholder), class);
    }
    Regex::new(&format!("^{re}$")).ok()
}

/// Classify one ref. Accepts `refs/heads/<b>` or a bare branch name; any other
/// `refs/...` namespace (tags, refs/tillandsias/*) is not a branch and is
/// admitted as `non-branch`.
pub fn check_ref(d: &Discipline, reference: &str) -> RefAnswer {
    check_ref_observed(d, reference, None)
}

/// ORDER 1446-664f — `check_ref` with the project's observed facts: an
/// enforced rule refuses only when its qualifier is observed.
pub fn check_ref_observed(d: &Discipline, reference: &str, reality: Option<&Derived>) -> RefAnswer {
    let branch = match reference.strip_prefix("refs/heads/") {
        Some(b) => b,
        None if reference.starts_with("refs/") => return ok("non-branch"),
        None => reference,
    };
    // THE FLOOR: at level 0 nothing is refused, including the default branch.
    if d.level == 0 {
        return if branch == d.default_branch {
            ok("default-branch:level=0")
        } else {
            ok("admitted:level=0")
        };
    }
    if branch == d.default_branch {
        return at_enforcement(
            d,
            reality,
            "default_branch",
            "default-branch-protected",
            format!(
                "{branch} is this project's default branch; at level {} it advances only \
                 through {} (the seed's integration branches)",
                d.level,
                if d.level >= 2 {
                    "work refs landed on an integration branch and a pull request"
                } else {
                    "a pull request from an integration branch"
                }
            ),
            d.denied_message(None),
        );
    }
    if d.integration.values().any(|b| b == branch) {
        return ok("integration");
    }
    if let Some(re) = d
        .work_ref
        .as_deref()
        .and_then(|w| Regex::new(&format!("^(?:{w})$")).ok())
        && re.is_match(branch)
    {
        return ok("work-ref");
    }
    if let Some(re) = d.salvage_ref.as_deref().and_then(salvage_regex)
        && re.is_match(branch)
    {
        return ok("salvage");
    }
    at_enforcement(
        d,
        reality,
        "ref_grammar",
        "ref-outside-grammar",
        format!(
            "{branch} is neither the default branch, an integration branch ({}), a work ref \
             ({}) nor a salvage ref ({})",
            {
                let mut b: Vec<&str> = d.integration.values().map(String::as_str).collect();
                b.sort_unstable();
                b.dedup();
                b.join(", ")
            },
            d.work_ref.as_deref().unwrap_or("-"),
            d.salvage_ref.as_deref().unwrap_or("-")
        ),
        format!(
            "name the branch by the grammar (work: {}), or push to your platform's integration \
             branch",
            d.work_ref.as_deref().unwrap_or("-")
        ),
    )
}

// ── loading ─────────────────────────────────────────────────────────────────

/// The checkout root: the nearest ancestor of `start` holding `.git`.
pub fn find_root(start: &Path) -> Option<PathBuf> {
    let mut dir = Some(start);
    while let Some(d) = dir {
        if d.join(".git").exists() {
            return Some(d.to_path_buf());
        }
        dir = d.parent();
    }
    None
}

/// The COMMON git dir (`.git`, or for a worktree the dir its `commondir`
/// names), where remote refs and published discipline refs live.
fn common_git_dir(root: &Path) -> Option<PathBuf> {
    let dot = root.join(".git");
    let gitdir = if dot.is_dir() {
        dot
    } else {
        let text = std::fs::read_to_string(&dot).ok()?;
        let rel = text.trim().strip_prefix("gitdir:")?.trim();
        let p = PathBuf::from(rel);
        if p.is_absolute() { p } else { root.join(p) }
    };
    match std::fs::read_to_string(gitdir.join("commondir")) {
        Ok(c) => {
            let p = PathBuf::from(c.trim());
            Some(if p.is_absolute() { p } else { gitdir.join(p) })
        }
        Err(_) => Some(gitdir),
    }
}

/// The level-0 default branch: the remote's HEAD branch when known, else the
/// local HEAD's branch, else `main`.
pub fn default_branch_of(root: &Path) -> String {
    let Some(common) = common_git_dir(root) else {
        return "main".to_string();
    };
    for (file, prefix) in [
        ("refs/remotes/origin/HEAD", "ref: refs/remotes/origin/"),
        ("HEAD", "ref: refs/heads/"),
    ] {
        if let Ok(text) = std::fs::read_to_string(common.join(file))
            && let Some(b) = text.trim().strip_prefix(prefix)
        {
            return b.to_string();
        }
    }
    "main".to_string()
}

/// The highest level previously published into this repository, read from
/// `refs/tillandsias/discipline/<level>/...` (loose and packed). Levels are
/// forward-only; a seed below this is refused.
pub fn published_level(root: &Path) -> Option<u8> {
    let common = common_git_dir(root)?;
    let mut max: Option<u8> = None;
    let mut see = |name: &str| {
        if let Some(rest) = name.strip_prefix("refs/tillandsias/discipline/")
            && let Some(l) = rest.split('/').next().and_then(|l| l.parse::<u8>().ok())
        {
            max = Some(max.map_or(l, |m| m.max(l)));
        }
    };
    if let Ok(packed) = std::fs::read_to_string(common.join("packed-refs")) {
        for line in packed.lines() {
            if let Some((_, name)) = line.split_once(' ') {
                see(name.trim());
            }
        }
    }
    let base = common.join("refs/tillandsias/discipline");
    if let Ok(levels) = std::fs::read_dir(&base) {
        for l in levels.flatten() {
            if let Some(name) = l.file_name().to_str() {
                see(&format!("refs/tillandsias/discipline/{name}/x"));
            }
        }
    }
    max
}

/// Parse and validate seed text. `Err(reason)` is the `<reason>` of
/// `refused:discipline-seed:<reason>`.
pub fn parse_seed(
    text: &str,
    published: Option<u8>,
    fallback_default: &str,
) -> Result<Discipline, String> {
    let v: Value = serde_yaml::from_str(text).map_err(|_| "unparseable".to_string())?;
    let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let level = match v.get("level").and_then(Value::as_u64) {
        Some(l @ 0..=2) => l as u8,
        Some(_) => return Err("level-out-of-range".into()),
        None => return Err("level-missing".into()),
    };
    if let Some(p) = published
        && level < p
    {
        return Err(format!("level-regressed:{level}<{p}"));
    }
    let mut enforcement = BTreeMap::new();
    for rule in RULES {
        enforcement.insert(rule.to_string(), "advised".to_string());
    }
    if let Some(map) = v.get("enforcement").and_then(Value::as_mapping) {
        for (k, e) in map {
            let (Some(k), Some(e)) = (k.as_str(), e.as_str()) else {
                return Err("enforcement-shape".into());
            };
            if !ENFORCEMENTS.contains(&e) {
                return Err(format!("enforcement-vocabulary:{k}={e}"));
            }
            enforcement.insert(k.to_string(), e.to_string());
        }
    }
    let default_branch = s("default_branch").unwrap_or_else(|| fallback_default.to_string());
    let mut integration = BTreeMap::new();
    if let Some(map) = v.get("integration").and_then(Value::as_mapping) {
        for (k, b) in map {
            let (Some(k), Some(b)) = (k.as_str(), b.as_str()) else {
                return Err("integration-shape".into());
            };
            if level >= 1 && b == default_branch {
                return Err(format!("integration-equals-default:{k}"));
            }
            integration.insert(k.to_string(), b.to_string());
        }
    }
    if level >= 1 && integration.is_empty() {
        return Err("integration-missing".into());
    }
    let work_ref = s("work_ref");
    if let Some(w) = &work_ref
        && Regex::new(&format!("^(?:{w})$")).is_err()
    {
        return Err("work-ref-regex".into());
    }
    let plan_only_paths = v
        .get("plan_only_lane")
        .and_then(|p| p.get("paths"))
        .and_then(Value::as_sequence)
        .map(|seq| {
            seq.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    Ok(Discipline {
        source: Source::Seed,
        level,
        enforcement,
        default_branch,
        integration,
        work_ref,
        salvage_ref: s("salvage_ref"),
        plan_only_paths,
        freeze_namespace: s("freeze_namespace"),
        default_branch_denied: v
            .get("messages")
            .and_then(|m| m.get("default_branch_denied"))
            .and_then(Value::as_str)
            .map(str::to_string),
        seed_path: None,
        digest: None,
        refusal: None,
    })
}

/// Load the discipline for `root`, or from an explicit seed path. A refused
/// seed answers from the floor with `refusal` set, so no caller is ever left
/// without an answer — and none is refused because a seed was malformed.
pub fn load(root: &Path, seed_override: Option<&Path>) -> Discipline {
    let fallback_default = default_branch_of(root);
    let path = seed_override
        .map(Path::to_path_buf)
        .unwrap_or_else(|| root.join(SEED_RELATIVE_PATH));
    let Ok(bytes) = std::fs::read(&path) else {
        return Discipline::floor(fallback_default);
    };
    let digest = crate::host_verbs::sha256_hex_reader(&bytes[..]).ok();
    let text = String::from_utf8_lossy(&bytes);
    match parse_seed(&text, published_level(root), &fallback_default) {
        Ok(mut d) => {
            d.seed_path = Some(path);
            d.digest = digest;
            d
        }
        Err(reason) => {
            let mut d = Discipline::floor(fallback_default);
            d.seed_path = Some(path);
            d.digest = digest;
            d.refusal = Some(format!("refused:discipline-seed:{reason}"));
            d
        }
    }
}

// ── derive: the discipline the project's own history shows ─────────────────
//
// ORDER 1446-664f (operator 2026-09-27: "We should try to derive the
// discipline but check against reality"). Neither side is blindly
// authoritative: a seed AHEAD of reality is a project opting in early — its
// enforced rules WARN until their qualifier is observed; a seed BEHIND reality
// is a project that has outgrown its declaration — nothing is refused on the
// seed's behalf, and the answer names `discipline raise`.
//
// OBSERVED FROM THE CHECKOUT, NOT THE NETWORK. The pre-push hook calls
// check-ref for every ref, so observations read the checkout's own refs
// (refs/remotes/origin/*, origin/HEAD) and `git log`: the origin as of the last
// fetch. Every observation carries the exact command, so a reader can re-run it.
//
// THE COMMITTER QUALIFIER IS HOSTS DERIVED FROM AUTHOR EMAILS. The design said
// "agent trailers, then author"; measured on this repository's last 50 commits,
// no trailer names a host (Co-Authored-By, Claude-Session, Generated-By), and
// author emails do (tlatoani@macuahuitl…, tlatoani@yoga…). The host is derived
// by scripts/fleet-activity.sh's rule (1223-wzc4, coordinator-ratified): the
// domain's FIRST LABEL is the host; an address at a shared provider, or with no
// domain, is an UNATTRIBUTED BUCKET and names no host (1012-hu7d). The provider
// list is pinned equal to that script's by a unit test, so the two cannot drift.
//
// FETCH FIRST. Observations are as of the checkout's last fetch; a checkout with
// no refs/remotes/origin/* observes nothing on origin, and its enforced rules
// warn. derive says so with a `note:` line.

/// Shared mail providers: an address here names no host. MUST equal
/// SHARED_PROVIDERS in scripts/fleet-activity.sh (pinned by
/// `shared_providers_match_fleet_activity`).
pub const SHARED_PROVIDERS: [&str; 8] = [
    "gmail.com",
    "hotmail.com",
    "outlook.com",
    "yahoo.com",
    "icloud.com",
    "protonmail.com",
    "proton.me",
    "users.noreply.github.com",
];

/// fleet-activity.sh's host rule: `Some(host)`, or `None` for a bucket.
pub fn host_of_email(email: &str) -> Option<String> {
    let (_, domain) = email.split_once('@')?;
    let domain = domain.trim().to_lowercase();
    if domain.is_empty() || SHARED_PROVIDERS.contains(&domain.as_str()) {
        return None;
    }
    domain.split('.').next().map(str::to_string)
}

/// How many commits the committer qualifier looks back over.
pub const COMMIT_WINDOW: usize = 50;
const DEFAULT_WORK_REF: &str = "work/[0-9]{3,4}-[a-z0-9]{4}";

/// The level whose qualifier a rule needs before it may refuse.
fn rule_level(rule: &str) -> u8 {
    match rule {
        "ref_grammar" => 2,
        _ => 1,
    }
}

#[derive(Debug, Clone)]
pub struct Observation {
    pub name: &'static str,
    pub value: Json,
    pub command: String,
}

#[derive(Debug, Clone)]
pub struct Qualifier {
    pub level: u8,
    pub met: bool,
    pub requires: &'static str,
}

#[derive(Debug, Clone)]
pub struct Derived {
    pub level: u8,
    pub observations: Vec<Observation>,
    pub qualifiers: Vec<Qualifier>,
    /// No refs/remotes/origin/* at all: origin was never fetched here.
    pub unfetched: bool,
}

impl Derived {
    /// `Some(what is missing)` when the qualifier for `level` was observed absent.
    pub fn missing_for(&self, level: u8) -> Option<&'static str> {
        self.qualifiers
            .iter()
            .find(|q| q.level == level && !q.met)
            .map(|q| q.requires)
    }
}

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Observe the project at `root`. `None` when git cannot answer at all (not a
/// repository, or no git): unobservable, which is not the same as level 0.
pub fn derive(root: &Path, d: &Discipline) -> Option<Derived> {
    git(root, &["rev-parse", "--git-dir"])?;
    let mut obs = Vec::new();

    let head_cmd = "git symbolic-ref -q --short refs/remotes/origin/HEAD";
    let remote_head = git(
        root,
        &["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"],
    )
    .map(|s| s.trim().trim_start_matches("origin/").to_string())
    .filter(|s| !s.is_empty());
    let default = remote_head
        .clone()
        .unwrap_or_else(|| d.default_branch.clone());
    obs.push(Observation {
        name: "remote_head",
        value: json!(remote_head),
        command: head_cmd.into(),
    });

    let heads_cmd = "git for-each-ref --format=%(refname:strip=3) refs/remotes/origin";
    let heads: Vec<String> = git(
        root,
        &[
            "for-each-ref",
            "--format=%(refname:strip=3)",
            "refs/remotes/origin",
        ],
    )
    .unwrap_or_default()
    .lines()
    .map(str::trim)
    .filter(|h| !h.is_empty() && *h != "HEAD")
    .map(str::to_string)
    .collect();
    let integration: Vec<String> = heads
        .iter()
        .filter(|h| {
            **h != default && (d.integration.values().any(|b| b == *h) || h.ends_with("-next"))
        })
        .cloned()
        .collect();
    obs.push(Observation {
        name: "integration_branches_on_origin",
        value: json!(integration),
        command: heads_cmd.into(),
    });

    let work_re = Regex::new(&format!(
        "^(?:{})$",
        d.work_ref.as_deref().unwrap_or(DEFAULT_WORK_REF)
    ))
    .ok();
    let work_refs = heads
        .iter()
        .filter(|h| work_re.as_ref().is_some_and(|re| re.is_match(h)))
        .count();
    obs.push(Observation {
        name: "work_refs_on_origin",
        value: json!(work_refs),
        command: heads_cmd.into(),
    });

    // History to read: the default branch and every integration branch, as
    // origin has them; the local default when origin has none.
    let mut refs: Vec<String> = std::iter::once(&default)
        .chain(integration.iter())
        .filter(|b| heads.contains(b))
        .map(|b| format!("refs/remotes/origin/{b}"))
        .collect();
    if refs.is_empty() {
        refs.push("HEAD".to_string());
    }
    let n = COMMIT_WINDOW.to_string();
    let mut log_args = vec!["log", "-n", n.as_str(), "--format=%ae"];
    log_args.extend(refs.iter().map(String::as_str));
    let emails: std::collections::BTreeSet<String> = git(root, &log_args)
        .unwrap_or_default()
        .lines()
        .map(|l| l.trim().to_lowercase())
        .filter(|l| !l.is_empty())
        .collect();
    let hosts: std::collections::BTreeSet<String> =
        emails.iter().filter_map(|e| host_of_email(e)).collect();
    let buckets = emails.iter().filter(|e| host_of_email(e).is_none()).count();
    obs.push(Observation {
        name: "unattributed_bucket_emails",
        value: json!(buckets),
        command: format!("git log -n {COMMIT_WINDOW} --format=%ae {}", refs.join(" ")),
    });
    obs.push(Observation {
        name: "distinct_committer_hosts",
        value: json!(hosts),
        command: format!("git log -n {COMMIT_WINDOW} --format=%ae {}", refs.join(" ")),
    });

    let default_ref = if heads.contains(&default) {
        format!("refs/remotes/origin/{default}")
    } else {
        default.clone()
    };
    let pr_merges = git(
        root,
        &[
            "log",
            "--merges",
            "-n",
            n.as_str(),
            "--format=%s",
            default_ref.as_str(),
        ],
    )
    .unwrap_or_default()
    .lines()
    .filter(|l| l.starts_with("Merge pull request"))
    .count();
    obs.push(Observation {
        name: "pull_request_merges_on_default",
        value: json!(pr_merges),
        command: format!("git log --merges -n {COMMIT_WINDOW} --format=%s {default_ref}"),
    });

    let hooks_dir = common_git_dir(root).map(|g| g.join("hooks"));
    let hooks: Vec<String> = ["pre-push", "pre-commit", "pre-receive"]
        .iter()
        .filter(|h| hooks_dir.as_ref().is_some_and(|dir| dir.join(h).is_file()))
        .map(|h| h.to_string())
        .collect();
    obs.push(Observation {
        name: "installed_hooks",
        value: json!(hooks),
        command: "ls <git-common-dir>/hooks".into(),
    });

    let l1 = !integration.is_empty() || pr_merges > 0;
    let l2 = hosts.len() >= 2 && work_refs >= 1;
    let qualifiers = vec![
        Qualifier {
            level: 1,
            met: l1,
            requires: "an integration branch on origin other than the default branch, or pull-request merges on the default branch",
        },
        Qualifier {
            level: 2,
            met: l2,
            requires: "two or more distinct committer hosts (by author email domain) in the last 50 commits AND a work ref on origin",
        },
    ];
    let level = if l2 {
        2
    } else if l1 {
        1
    } else {
        0
    };
    Some(Derived {
        level,
        observations: obs,
        qualifiers,
        unfetched: heads.is_empty(),
    })
}

/// The derive answer: text lines and the JSON form.
pub fn derive_report(d: &Discipline, r: Option<&Derived>) -> (Vec<String>, Json) {
    let seed = (d.source == Source::Seed).then_some(d.level);
    let seed_s = seed.map_or("none".to_string(), |l| l.to_string());
    let seed_level = seed.unwrap_or(0);
    let Some(r) = r else {
        let line = format!("derived=unavailable seed={seed_s} effective={seed_level}");
        return (
            vec![
                line,
                "observed=unavailable: git could not read this project; the seed stands".into(),
            ],
            json!({"derived": null, "seed": seed, "effective": seed_level, "observed": false}),
        );
    };
    let effective = seed_level.min(r.level);
    let mut lines = vec![format!(
        "derived={} seed={seed_s} effective={effective}",
        r.level
    )];
    for q in &r.qualifiers {
        lines.push(format!(
            "qualifier level={} met={} requires: {}",
            q.level,
            if q.met { "yes" } else { "no" },
            q.requires
        ));
    }
    for o in &r.observations {
        lines.push(format!(
            "observed {}={} via `{}`",
            o.name, o.value, o.command
        ));
    }
    let drift = if r.level > seed_level {
        format!(
            "drift:seed-behind-reality: discipline raise --to {}; use /project-discipline for instructions",
            r.level
        )
    } else if r.level < seed_level {
        format!(
            "drift:seed-ahead-of-reality: level-{seed_level} rules warn instead of refusing until {} is observed",
            r.missing_for(r.level + 1).unwrap_or("the next qualifier")
        )
    } else {
        "ok:discipline-derive:seed-matches-reality".to_string()
    };
    lines.push(drift.clone());
    if r.unfetched {
        lines.push(
            "note: no refs/remotes/origin/* here — origin was never fetched, so nothing on origin \
             was observed; run `git fetch origin` and derive again"
                .to_string(),
        );
    }
    let json = json!({
        "derived": r.level,
        "seed": seed,
        "effective": effective,
        "observed": true,
        "qualifiers": r.qualifiers.iter().map(|q| json!({"level": q.level, "met": q.met, "requires": q.requires})).collect::<Vec<_>>(),
        "observations": r.observations.iter().map(|o| json!({"name": o.name, "value": o.value, "command": o.command})).collect::<Vec<_>>(),
        "drift": drift,
        "unfetched": r.unfetched,
    });
    (lines, json)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEED: &str = r#"
version: 1
level: 2
enforcement: { default_branch: enforced, ref_grammar: warn }
default_branch: main
integration: { linux: linux-next, forge: linux-next, windows: windows-next, macos: osx-next }
work_ref: "work/[0-9]{3,4}-[a-z0-9]{4}"
salvage_ref: "salvage/<host>/<yyyymmdd>-<slug>"
messages:
  default_branch_denied: "push to {default} denied: this project uses branch {integration} for integration and {work_ref} for work; switch to the corresponding branch and rebase to remote"
"#;

    fn seed() -> Discipline {
        parse_seed(SEED, None, "main").unwrap()
    }

    /// 1446-664f: the host rule is fleet-activity.sh's (1223-wzc4), not a
    /// second one — the provider list is read out of that script.
    #[test]
    fn shared_providers_match_fleet_activity() {
        let script = include_str!("../../../scripts/fleet-activity.sh");
        let line = script
            .lines()
            .find(|l| l.starts_with("SHARED_PROVIDERS="))
            .expect("fleet-activity.sh defines SHARED_PROVIDERS");
        let list: Vec<&str> = line
            .trim_start_matches("SHARED_PROVIDERS=")
            .trim_matches('"')
            .split_whitespace()
            .collect();
        assert_eq!(list, SHARED_PROVIDERS.to_vec());
        assert_eq!(
            host_of_email("t@macuahuitl.ayahuitlcalpan.com").as_deref(),
            Some("macuahuitl")
        );
        assert_eq!(host_of_email("bulloncito@gmail.com"), None);
        assert_eq!(host_of_email("no-domain"), None);
    }

    #[test]
    fn the_seed_targets_each_platform() {
        let d = seed();
        assert_eq!(d.target("macos"), "osx-next");
        assert_eq!(d.target("forge"), "linux-next");
        assert_eq!(d.target("windows"), "windows-next");
    }

    #[test]
    fn check_ref_classifies_at_each_rules_enforcement() {
        let d = seed();
        let main = check_ref(&d, "refs/heads/main");
        assert_eq!(
            main.verdict,
            "refused:discipline:default-branch-protected:enforced"
        );
        assert!(main.refused);
        assert!(
            main.remedy
                .unwrap()
                .contains("uses branch linux-next|osx-next|windows-next")
        );
        assert_eq!(
            check_ref(&d, "refs/heads/work/1443-w79y").verdict,
            "ok:discipline:work-ref"
        );
        assert_eq!(
            check_ref(&d, "osx-next").verdict,
            "ok:discipline:integration"
        );
        assert_eq!(
            check_ref(&d, "salvage/mac/20260927-x").verdict,
            "ok:discipline:salvage"
        );
        let feature = check_ref(&d, "refs/heads/feature-x");
        assert_eq!(feature.verdict, "warn:discipline:ref-outside-grammar");
        assert!(!feature.refused);
        assert_eq!(
            check_ref(&d, "refs/tags/v1").verdict,
            "ok:discipline:non-branch"
        );
        let strict = parse_seed(
            &SEED.replace("ref_grammar: warn", "ref_grammar: enforced"),
            None,
            "main",
        )
        .unwrap();
        assert_eq!(
            check_ref(&strict, "refs/heads/feature-x").verdict,
            "refused:discipline:ref-outside-grammar:enforced"
        );
    }

    #[test]
    fn the_floor_refuses_nothing() {
        let d = Discipline::floor("main".into());
        assert_eq!(
            check_ref(&d, "refs/heads/main").verdict,
            "ok:discipline:default-branch:level=0"
        );
        assert!(!check_ref(&d, "refs/heads/anything").refused);
        assert_eq!(d.target("macos"), "main");
    }

    #[test]
    fn bad_seeds_are_refused_with_a_reason() {
        let eq = SEED.replace("macos: osx-next", "macos: main");
        assert_eq!(
            parse_seed(&eq, None, "main").unwrap_err(),
            "integration-equals-default:macos"
        );
        let re = SEED.replace("work/[0-9]{3,4}-[a-z0-9]{4}", "work/[0-9");
        assert_eq!(parse_seed(&re, None, "main").unwrap_err(), "work-ref-regex");
        assert_eq!(
            parse_seed(SEED, Some(3), "main").unwrap_err(),
            "level-regressed:2<3"
        );
        let vocab = SEED.replace("ref_grammar: warn", "ref_grammar: loud");
        assert_eq!(
            parse_seed(&vocab, None, "main").unwrap_err(),
            "enforcement-vocabulary:ref_grammar=loud"
        );
    }
}
