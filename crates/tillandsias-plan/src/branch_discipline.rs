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
    rule: &'static str,
    token: &str,
    why: String,
    remedy: String,
) -> RefAnswer {
    let e = d.enforcement_of(rule);
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
