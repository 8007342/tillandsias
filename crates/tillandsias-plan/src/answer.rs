//! Order 394b — the MANDATORY cited answer envelope.
//!
//! Ratified contract (`plan/issues/experts-construction-research-2026-07-29.md`
//! §4, operator-ratified 2026-07-29):
//!
//! > Every expert answer is a JSON envelope with a non-empty `citations`
//! > array. The deterministic layer emits the citations. The model never
//! > does. An answer with zero citations is returned as "no supported
//! > answer" — never a guess.
//!
//! ```text
//! { "answer": "<prose or table>",
//!   "citations": [ { "path": "...", "line_start": N, "line_end": M,
//!                    "kind": "plan|methodology|spec|cheatsheet|code",
//!                    "authority": { ... } } ],
//!   "freshness": { "source_commit": "<sha>", "indexed_at": "<ISO>" },
//!   "confidence": "exact|retrieved|unsupported" }
//! ```
//!
//! THE LOAD-BEARING DESIGN CHOICE: `confidence` is never an argument. It is
//! DERIVED from the citation set inside the only constructor
//! ([`Envelope::supported`]), and the struct's fields are private, so
//! "zero citations rendered as a confident answer" is not a bug this crate can
//! have — it is a state no caller can construct. An envelope arriving from
//! OUTSIDE (deserialized from a tool boundary, or hand-written by an agent)
//! gets the same guarantee enforced dynamically by [`verify`], which is what
//! the litmus runs.
//!
//! Rule 1 of §4 — resolvability — is [`verify`]: for every citation the path
//! exists, the line range is in-bounds and non-empty, and **the cited span
//! actually contains the token the answer claims**. A fabricated citation
//! (wrong path, wrong range, or a range whose text does not mention the packet
//! it is offered as evidence for) is a hard violation.
//!
//! @trace spec:spec-traceability
//! @trace order:394, order:394b

use crate::Ledger;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Component, Path};

/// The `confidence` vocabulary is CLOSED (§4). `Unsupported` is not a lower
/// grade of answer — it is the refusal to answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    /// A deterministic L0 lookup: the answer IS the ledger content.
    Exact,
    /// Retrieved from a ranked corpus (L1). Not produced at rung 1.
    Retrieved,
    /// No supporting citation was found. Never accompanied by a guess.
    Unsupported,
}

/// The corpus a citation points into. Closed vocabulary, per §4's table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CitationKind {
    Plan,
    Methodology,
    Spec,
    Cheatsheet,
    Code,
}

/// One checkable pointer into the checkout. `authority` is the per-kind
/// payload from §4's table, kept as an open string map rather than a closed
/// struct so a new kind adds data, not a schema migration — the same
/// open-world discipline the ledger itself uses.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Citation {
    /// Repo-relative. An absolute path or one containing `..` is REFUSED by
    /// [`verify`]: a citation a reader cannot resolve from the checkout root
    /// is not evidence.
    path: String,
    /// 1-indexed, inclusive.
    line_start: usize,
    /// 1-indexed, inclusive. Must be >= `line_start`.
    line_end: usize,
    kind: CitationKind,
    authority: BTreeMap<String, String>,
}

impl Citation {
    pub fn new(
        path: String,
        line_start: usize,
        line_end: usize,
        kind: CitationKind,
        authority: BTreeMap<String, String>,
    ) -> Self {
        Self {
            path,
            line_start,
            line_end,
            kind,
            authority,
        }
    }

    pub fn path(&self) -> &str {
        &self.path
    }
    pub fn line_start(&self) -> usize {
        self.line_start
    }
    pub fn line_end(&self) -> usize {
        self.line_end
    }
    pub fn kind(&self) -> CitationKind {
        self.kind
    }
    pub fn authority(&self) -> &BTreeMap<String, String> {
        &self.authority
    }

    /// The token that MUST appear inside the cited span for the citation to be
    /// evidence rather than decoration. For a plan citation that is the
    /// `packet_id: <id>` line — the strongest available proof that the span
    /// really is the packet the answer named.
    fn span_key(&self) -> Result<String, String> {
        match self.kind {
            CitationKind::Plan => self
                .authority
                .get("packet_id")
                .map(|id| format!("packet_id: {id}"))
                .ok_or_else(|| {
                    format!(
                        "{}:{}-{}: plan citation carries no authority.packet_id, so nothing can be verified against its span",
                        self.path, self.line_start, self.line_end
                    )
                }),
            // Future kinds must declare what their span is supposed to say.
            // An undeclared key would make the citation unfalsifiable, which
            // is precisely the failure mode this module exists to prevent.
            _ => self.authority.get("key").cloned().ok_or_else(|| {
                format!(
                    "{}:{}-{}: non-plan citation carries no authority.key, so its span cannot be checked",
                    self.path, self.line_start, self.line_end
                )
            }),
        }
    }

    /// The token the ANSWER text must mention for this citation to be about
    /// something the answer actually claimed.
    fn claim_key(&self) -> Option<String> {
        match self.kind {
            CitationKind::Plan => self.authority.get("packet_id").cloned(),
            _ => self.authority.get("key").cloned(),
        }
    }
}

/// §4's `freshness` block. For an L0 corpus there is no index: the engine
/// reads the file at query time, so "indexed at" IS the moment the corpus was
/// last written. Reporting the source mtime rather than a wall clock keeps the
/// envelope reproducible for a given tree — and keeps the tool's standing
/// refusal to invent timestamps (`main.rs`: `--ts` is required, never
/// defaulted).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Freshness {
    source_commit: String,
    indexed_at: String,
}

impl Freshness {
    pub fn new(source_commit: String, indexed_at: String) -> Self {
        Self {
            source_commit,
            indexed_at,
        }
    }

    /// Best-effort, dependency-free: the commit is read straight out of
    /// `.git`, the timestamp is the corpus file's mtime. Anything that cannot
    /// be determined is reported as the literal `unknown` — an honest hole,
    /// never a fabricated sha or a synthesized "now".
    pub fn for_source(source: &Path) -> Self {
        Self {
            source_commit: git_head_sha(source).unwrap_or_else(|| "unknown".to_string()),
            indexed_at: file_mtime_iso8601(source).unwrap_or_else(|| "unknown".to_string()),
        }
    }

    pub fn source_commit(&self) -> &str {
        &self.source_commit
    }
    pub fn indexed_at(&self) -> &str {
        &self.indexed_at
    }
}

/// The answer envelope. FIELDS ARE PRIVATE ON PURPOSE — see the module doc.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    answer: String,
    citations: Vec<Citation>,
    freshness: Freshness,
    confidence: Confidence,
}

impl Envelope {
    /// The ONLY way to build a non-unsupported envelope, and it can still
    /// refuse: an empty citation set DOWNGRADES to [`Envelope::unsupported`]
    /// and the prose is discarded. Passing `Confidence::Unsupported` here is
    /// also downgraded, so the two fields can never disagree.
    pub fn supported(
        answer: impl Into<String>,
        citations: Vec<Citation>,
        confidence: Confidence,
        freshness: Freshness,
    ) -> Self {
        if citations.is_empty() || confidence == Confidence::Unsupported {
            return Self::unsupported(
                "the deterministic layer produced no citation for this question",
                freshness,
            );
        }
        Self {
            answer: answer.into(),
            citations,
            freshness,
            confidence,
        }
    }

    /// The refusal. The rendering is pinned (`unsupported: <reason>`) so a
    /// caller — MCP client, litmus, or agent — can branch on it without
    /// parsing prose, and so a refusal can never be mistaken for an answer.
    pub fn unsupported(reason: impl AsRef<str>, freshness: Freshness) -> Self {
        Self {
            answer: format!("unsupported: {}", reason.as_ref()),
            citations: Vec::new(),
            freshness,
            confidence: Confidence::Unsupported,
        }
    }

    pub fn answer(&self) -> &str {
        &self.answer
    }
    pub fn citations(&self) -> &[Citation] {
        &self.citations
    }
    pub fn freshness(&self) -> &Freshness {
        &self.freshness
    }
    pub fn confidence(&self) -> Confidence {
        self.confidence
    }
}

/// The falsifiability gate (§4 rule 1). Returns the violations that make this
/// envelope's citations unverifiable — EMPTY means every citation resolves and
/// every cited span really says what the answer claims.
///
/// `root` is the checkout the relative paths are resolved against.
///
/// This runs on envelopes that were DESERIALIZED, i.e. that crossed a tool
/// boundary and lost the type-level guarantee. It is the check the litmus
/// exercises, and the check a seeded fabrication must trip.
pub fn verify(envelope: &Envelope, root: &Path) -> Vec<String> {
    let mut violations = Vec::new();

    // (0) The envelope-level invariant, in BOTH directions.
    let unsupported = envelope.confidence == Confidence::Unsupported;
    if envelope.citations.is_empty() && !unsupported {
        violations.push(format!(
            "zero citations with confidence '{:?}' — an uncited answer MUST render as unsupported",
            envelope.confidence
        ));
    }
    if !envelope.citations.is_empty() && unsupported {
        violations
            .push("confidence 'unsupported' with citations attached — contradictory".to_string());
    }
    if unsupported && !envelope.answer.starts_with("unsupported:") {
        violations.push(format!(
            "an unsupported answer must render as 'unsupported: <reason>', got '{}'",
            truncate(&envelope.answer, 60)
        ));
    }
    if envelope.freshness.source_commit.is_empty() || envelope.freshness.indexed_at.is_empty() {
        violations.push("freshness must carry both source_commit and indexed_at".to_string());
    }

    // (1) Every citation resolves and its span carries the claimed content.
    for c in &envelope.citations {
        if c.path.is_empty() {
            violations.push("citation with an empty path".to_string());
            continue;
        }
        let rel = Path::new(&c.path);
        if rel.is_absolute()
            || rel
                .components()
                .any(|p| matches!(p, Component::ParentDir | Component::Prefix(_)))
        {
            violations.push(format!(
                "{}: citation path must be repo-relative and must not escape the checkout",
                c.path
            ));
            continue;
        }
        let full = root.join(rel);
        let Ok(text) = std::fs::read_to_string(&full) else {
            violations.push(format!(
                "{}: citation path does not resolve to a readable file ({})",
                c.path,
                full.display()
            ));
            continue;
        };
        let lines: Vec<&str> = text.lines().collect();
        if c.line_start == 0 || c.line_end < c.line_start {
            violations.push(format!(
                "{}:{}-{}: citation line range is empty or inverted",
                c.path, c.line_start, c.line_end
            ));
            continue;
        }
        if c.line_end > lines.len() {
            violations.push(format!(
                "{}:{}-{}: citation line range runs past end of file ({} lines)",
                c.path,
                c.line_start,
                c.line_end,
                lines.len()
            ));
            continue;
        }
        let span = lines[c.line_start - 1..c.line_end].join("\n");
        match c.span_key() {
            Err(e) => violations.push(e),
            Ok(key) => {
                if !span.contains(&key) {
                    violations.push(format!(
                        "{}:{}-{}: cited span does not contain '{}' — FABRICATED citation",
                        c.path, c.line_start, c.line_end, key
                    ));
                }
            }
        }
        if let Some(claim) = c.claim_key()
            && !envelope.answer.contains(&claim)
        {
            violations.push(format!(
                "{}:{}-{}: cites '{}', which the answer text never mentions — decorative citation",
                c.path, c.line_start, c.line_end, claim
            ));
        }
    }

    violations
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    s.chars().take(n).collect::<String>() + "…"
}

// ── question -> deterministic query ─────────────────────────────────────────

/// The CLOSED set of questions rung 1 can answer. Anything outside it is
/// `unsupported` — there is deliberately no fallback that guesses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    BlockedBy(String),
    Closure(String),
    Status(String),
    Ready(Option<String>),
    Burndown(String),
}

/// Strip the punctuation an agent types around a reference.
fn clean_token(t: &str) -> &str {
    t.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '-')))
}

/// Deterministic intent classification. NO model, NO fuzzy matching: keyword
/// presence plus "which token in this question names a packet the ledger
/// actually has". A question naming no resolvable packet is refused rather
/// than answered about some nearby packet.
pub fn classify(ledger: &Ledger, question: &str) -> Option<Intent> {
    let lower = question.to_ascii_lowercase();
    let reference = question
        .split_whitespace()
        .map(clean_token)
        .find(|t| !t.is_empty() && ledger.resolve(t).is_some())
        .map(str::to_string);

    let wants_closure = lower.contains("closure")
        || lower.contains("downstream")
        || lower.contains("transitive")
        || lower.contains("everything blocked by");
    let wants_blocked = lower.contains("blocked by")
        || lower.contains("blocks")
        || lower.contains("blocked-by")
        || lower.contains("waiting on");
    let wants_burndown = lower.contains("burndown")
        || lower.contains("children of")
        || lower.contains("milestone")
        || lower.contains("release target");
    let wants_ready = lower.contains("ready") || lower.contains("what can i pick up");

    if let Some(r) = reference {
        if wants_closure {
            return Some(Intent::Closure(r));
        }
        if wants_blocked {
            return Some(Intent::BlockedBy(r));
        }
        if wants_burndown {
            return Some(Intent::Burndown(r));
        }
        if wants_ready {
            return Some(Intent::Ready(role_in(ledger, &lower)));
        }
        return Some(Intent::Status(r));
    }
    if wants_ready {
        return Some(Intent::Ready(role_in(ledger, &lower)));
    }
    None
}

/// Roles are read out of the ledger's own `pickup_role` values, so the
/// vocabulary cannot drift from the data.
fn role_in(ledger: &Ledger, lower_question: &str) -> Option<String> {
    let mut roles: Vec<String> = ledger
        .packets
        .iter()
        .filter_map(|p| p.get("pickup_role").and_then(serde_yaml::Value::as_str))
        .map(str::to_ascii_lowercase)
        .collect();
    roles.sort();
    roles.dedup();
    roles.into_iter().find(|r| {
        lower_question
            .split_whitespace()
            .map(clean_token)
            .any(|t| t == r)
    })
}

/// Answer a question against the ledger, ALWAYS as an envelope.
///
/// `source_rel` is the repo-relative path the citations will carry — it must
/// name the same file the ledger was loaded from, because that is the file a
/// reader will open.
pub fn answer_question(ledger: &Ledger, question: &str, source_rel: &str) -> Envelope {
    let freshness = ledger
        .source_path()
        .map(Freshness::for_source)
        .unwrap_or_else(|| Freshness::new("unknown".into(), "unknown".into()));

    let Some(intent) = classify(ledger, question) else {
        return Envelope::unsupported(
            format!(
                "no packet in the ledger matches any token in {:?}, and it is not a recognised ready/burndown query",
                truncate(question, 120)
            ),
            freshness,
        );
    };

    let (headline, packets): (String, Vec<&serde_yaml::Value>) = match &intent {
        Intent::BlockedBy(r) => (
            format!("packets directly blocked by '{r}'"),
            ledger.blocked_by(r),
        ),
        Intent::Closure(r) => (
            format!("packets transitively downstream of '{r}'"),
            ledger.blocked_by_closure(r),
        ),
        Intent::Burndown(r) => (
            format!("release-target children of '{r}'"),
            ledger.milestone_children(r),
        ),
        Intent::Ready(role) => (
            match role {
                Some(r) => format!("ready packets for pickup_role '{r}'"),
                None => "ready packets".to_string(),
            },
            ledger.ready(role.as_deref()),
        ),
        Intent::Status(r) => (
            format!("status of '{r}'"),
            ledger.resolve(r).into_iter().collect(),
        ),
    };

    if packets.is_empty() {
        // The honest empty result. It is UNSUPPORTED, not "no packets are
        // blocked": with zero citations there is nothing a reader can check,
        // and asserting a negative uncited is exactly the guess §4 forbids.
        return Envelope::unsupported(
            format!(
                "{headline} — the deterministic query returned no rows, so there is nothing to cite"
            ),
            freshness,
        );
    }

    let mut body = String::from("order\tstatus\tpacket_id\n");
    let mut citations = Vec::new();
    let mut uncitable = Vec::new();
    for p in &packets {
        let id = ledger.id_of(p);
        let order = p
            .get("order")
            .map(|v| match v {
                serde_yaml::Value::Number(n) => n.to_string(),
                serde_yaml::Value::String(s) => s.clone(),
                _ => "?".into(),
            })
            .unwrap_or_else(|| "?".into());
        let status = p
            .get("status")
            .and_then(serde_yaml::Value::as_str)
            .unwrap_or("?");
        let Some((line_start, line_end)) = ledger.span_of(&id) else {
            // A row we cannot point at is a row we do not report. Reporting it
            // uncited would be an unsupported claim smuggled into a supported
            // envelope.
            uncitable.push(id);
            continue;
        };
        body.push_str(&format!("{order}\t{status}\t{id}\n"));
        let mut authority = BTreeMap::new();
        authority.insert("packet_id".to_string(), id.clone());
        authority.insert("order".to_string(), order);
        authority.insert("status".to_string(), status.to_string());
        citations.push(Citation::new(
            source_rel.to_string(),
            line_start,
            line_end,
            CitationKind::Plan,
            authority,
        ));
    }

    if !uncitable.is_empty() {
        body.push_str(&format!(
            "NOTE: {} row(s) omitted — no source span could be located for them: {}\n",
            uncitable.len(),
            uncitable.join(", ")
        ));
    }

    // Falls back to `unsupported` automatically when nothing was citable.
    Envelope::supported(
        format!("{headline}:\n{body}"),
        citations,
        Confidence::Exact,
        freshness,
    )
}

// ── freshness helpers (dependency-free) ─────────────────────────────────────

/// Walk up from the source file to the checkout root and read the commit out
/// of `.git`. Handles the plain repo, a `.git` FILE (worktree/submodule), and
/// packed refs. Returns `None` rather than guessing.
fn git_head_sha(source: &Path) -> Option<String> {
    let mut dir = source.parent()?;
    loop {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return head_sha_in(&dot_git);
        }
        if dot_git.is_file() {
            let raw = std::fs::read_to_string(&dot_git).ok()?;
            let gitdir = raw.trim().strip_prefix("gitdir:")?.trim().to_string();
            let p = Path::new(&gitdir);
            let resolved = if p.is_absolute() {
                p.to_path_buf()
            } else {
                dir.join(p)
            };
            return head_sha_in(&resolved);
        }
        dir = dir.parent()?;
    }
}

fn head_sha_in(git_dir: &Path) -> Option<String> {
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    let head = head.trim();
    let Some(reference) = head.strip_prefix("ref:").map(str::trim) else {
        // Detached HEAD: the file already holds the sha.
        return Some(head.to_string());
    };
    if let Ok(sha) = std::fs::read_to_string(git_dir.join(reference)) {
        return Some(sha.trim().to_string());
    }
    let packed = std::fs::read_to_string(git_dir.join("packed-refs")).ok()?;
    packed.lines().find_map(|l| {
        let (sha, name) = l.split_once(' ')?;
        (name.trim() == reference).then(|| sha.trim().to_string())
    })
}

fn file_mtime_iso8601(path: &Path) -> Option<String> {
    let secs = std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some(epoch_to_iso8601(secs as i64))
}

/// Unix seconds -> `YYYY-MM-DDTHH:MM:SSZ`. Hinnant's civil-from-days, so the
/// envelope carries a real ISO timestamp without pulling `chrono` into a crate
/// that is rebuilt on every forge launch.
pub fn epoch_to_iso8601(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn live_ledger() -> Ledger {
        Ledger::load(&repo_root().join("plan/index.yaml")).expect("live plan/index.yaml loads")
    }

    fn fresh() -> Freshness {
        Freshness::new("deadbeef".into(), "2026-07-29T00:00:00Z".into())
    }

    /// EXIT CRITERION (ii). The fixture query returns at least one citation,
    /// its path+range resolves, and — the load-bearing half — the cited span
    /// really contains the packet_id the answer claims.
    #[test]
    fn a_fixture_query_returns_a_resolvable_citation_whose_span_contains_the_packet_id() {
        let ledger = live_ledger();
        let env = answer_question(
            &ledger,
            "what packets are blocked by plan-methodology-experts-rung1/plan-expert-binary-shipping",
            "plan/index.yaml",
        );
        assert_eq!(
            env.confidence(),
            Confidence::Exact,
            "answer: {}",
            env.answer()
        );
        assert!(
            !env.citations().is_empty(),
            "a supported answer must carry citations"
        );
        let violations = verify(&env, &repo_root());
        assert!(
            violations.is_empty(),
            "citations must verify: {violations:#?}"
        );

        // Independently re-derive the span check, so this test does not merely
        // trust `verify`.
        let c = &env.citations()[0];
        let text = std::fs::read_to_string(repo_root().join(c.path())).expect("cited file opens");
        let lines: Vec<&str> = text.lines().collect();
        let span = lines[c.line_start() - 1..c.line_end()].join("\n");
        let claimed = c
            .authority()
            .get("packet_id")
            .expect("plan citation names a packet");
        assert!(
            span.contains(&format!("packet_id: {claimed}")),
            "span {}:{}-{} must contain the claimed packet_id",
            c.path(),
            c.line_start(),
            c.line_end()
        );
        assert!(
            env.answer().contains(claimed),
            "the answer names what it cites"
        );
    }

    /// EXIT CRITERION (iii), unit half: each way of fabricating a citation is
    /// caught. If any of these stopped being a violation the litmus could not
    /// go red on a fabrication.
    #[test]
    fn every_shape_of_fabricated_citation_is_refused() {
        let ledger = live_ledger();
        let env = answer_question(&ledger, "status of 394a", "plan/index.yaml");
        assert_eq!(env.confidence(), Confidence::Exact);
        let good = &env.citations()[0];
        let root = repo_root();

        // (a) a path that does not exist
        let mut auth = good.authority().clone();
        let bad_path = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                "plan/does-not-exist.yaml".into(),
                good.line_start(),
                good.line_end(),
                CitationKind::Plan,
                auth.clone(),
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&bad_path, &root)
                .iter()
                .any(|v| v.contains("does not resolve")),
            "a nonexistent path must be refused"
        );

        // (b) a range past end of file
        let bad_range = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                9_000_000,
                9_000_001,
                CitationKind::Plan,
                auth.clone(),
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&bad_range, &root)
                .iter()
                .any(|v| v.contains("past end of file")),
            "an out-of-bounds range must be refused"
        );

        // (c) THE INTERESTING ONE: a range that resolves perfectly but whose
        // text says nothing about the packet it is offered as evidence for.
        let wrong_span = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                1,
                3,
                CitationKind::Plan,
                auth.clone(),
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&wrong_span, &root)
                .iter()
                .any(|v| v.contains("FABRICATED")),
            "a resolvable range that does not contain the claim must be refused"
        );

        // (d) an inverted / empty range
        let inverted = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                50,
                49,
                CitationKind::Plan,
                auth.clone(),
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&inverted, &root)
                .iter()
                .any(|v| v.contains("empty or inverted"))
        );

        // (e) a citation for a packet the answer never mentions
        auth.insert("packet_id".into(), "plan-yaml-compiled-editor".into());
        let span = ledger
            .span_of("plan-yaml-compiled-editor")
            .expect("a real packet has a span");
        let decorative = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                span.0,
                span.1,
                CitationKind::Plan,
                auth,
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&decorative, &root)
                .iter()
                .any(|v| v.contains("decorative")),
            "a citation for a packet the answer never names must be refused"
        );

        // (f) escaping the checkout
        let escaping = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                "../../../etc/passwd".into(),
                1,
                1,
                CitationKind::Plan,
                good.authority().clone(),
            )],
            Confidence::Exact,
            fresh(),
        );
        assert!(
            verify(&escaping, &root)
                .iter()
                .any(|v| v.contains("must not escape the checkout"))
        );
    }

    /// THE LOAD-BEARING RULE. Zero citations renders as `unsupported`, and no
    /// caller can build anything else — this asserts the type-level guarantee.
    #[test]
    fn zero_citations_is_always_unsupported_never_a_guess() {
        let confident_but_uncited = Envelope::supported(
            "v0.5 ships on Tuesday",
            Vec::new(),
            Confidence::Exact,
            fresh(),
        );
        assert_eq!(
            confident_but_uncited.confidence(),
            Confidence::Unsupported,
            "an uncited answer must be downgraded, not published"
        );
        assert!(
            confident_but_uncited.answer().starts_with("unsupported:"),
            "the guess must be DISCARDED, got {:?}",
            confident_but_uncited.answer()
        );
        assert!(
            !confident_but_uncited.answer().contains("Tuesday"),
            "the uncited prose must not survive the downgrade"
        );
        assert!(verify(&confident_but_uncited, &repo_root()).is_empty());
    }

    /// The dynamic half of the same rule: an envelope that crossed a tool
    /// boundary (deserialized, so the constructor never ran) and claims
    /// confidence with no citations is a hard violation.
    #[test]
    fn a_deserialized_uncited_confident_envelope_is_a_violation() {
        let forged: Envelope = serde_json::from_str(
            r#"{"answer":"394a is done","citations":[],
                "freshness":{"source_commit":"abc","indexed_at":"2026-07-29T00:00:00Z"},
                "confidence":"exact"}"#,
        )
        .expect("parses");
        let violations = verify(&forged, &repo_root());
        assert!(
            violations
                .iter()
                .any(|v| v.contains("MUST render as unsupported")),
            "got {violations:#?}"
        );
    }

    /// An unanswerable question is refused, not answered about a nearby
    /// packet. This is the query-side of "never a guess".
    #[test]
    fn an_unrecognised_question_is_unsupported() {
        let ledger = live_ledger();
        let env = answer_question(
            &ledger,
            "what is the airspeed velocity of an unladen swallow",
            "plan/index.yaml",
        );
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.citations().is_empty());
        assert!(env.answer().starts_with("unsupported:"));
        assert!(verify(&env, &repo_root()).is_empty());
    }

    /// A question naming a REAL packet that simply blocks nothing is also
    /// unsupported — an uncited negative is still an uncited claim.
    #[test]
    fn a_resolvable_query_with_no_rows_is_unsupported_not_an_empty_answer() {
        let raw = "steps:\n  - packet_id: lonely-packet\n    order: 990\n    status: ready\n    depends_on: []\n";
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("parses");
        let env = answer_question(
            &ledger,
            "what is blocked by lonely-packet",
            "plan/index.yaml",
        );
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.answer().starts_with("unsupported:"));
    }

    /// The envelope's JSON shape IS the contract (§4). Field names and the
    /// confidence spelling are what every downstream consumer parses.
    #[test]
    fn the_serialized_envelope_matches_the_ratified_schema() {
        let ledger = live_ledger();
        let env = answer_question(&ledger, "status of 394a", "plan/index.yaml");
        let v: serde_json::Value = serde_json::to_value(&env).expect("serializes");
        let obj = v.as_object().expect("envelope is a JSON object");
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, vec!["answer", "citations", "confidence", "freshness"]);
        assert_eq!(obj["confidence"], serde_json::json!("exact"));
        assert!(obj["freshness"]["source_commit"].is_string());
        assert!(obj["freshness"]["indexed_at"].is_string());
        let c = &obj["citations"][0];
        let mut ckeys: Vec<&str> = c
            .as_object()
            .expect("citation is an object")
            .keys()
            .map(String::as_str)
            .collect();
        ckeys.sort();
        assert_eq!(
            ckeys,
            vec!["authority", "kind", "line_end", "line_start", "path"]
        );
        assert_eq!(c["kind"], serde_json::json!("plan"));
        assert!(c["line_start"].as_u64().unwrap() >= 1);
    }

    #[test]
    fn classification_is_deterministic_and_refuses_the_unknown() {
        let ledger = live_ledger();
        assert!(matches!(
            classify(&ledger, "what is blocked by 394a"),
            Some(Intent::BlockedBy(_))
        ));
        assert!(matches!(
            classify(&ledger, "everything downstream of 394a"),
            Some(Intent::Closure(_))
        ));
        assert!(matches!(
            classify(&ledger, "what is ready for linux"),
            Some(Intent::Ready(Some(r))) if r == "linux"
        ));
        assert!(matches!(classify(&ledger, "394a"), Some(Intent::Status(_))));
        assert!(classify(&ledger, "how do I feel today").is_none());
    }

    #[test]
    fn epoch_formatting_is_correct() {
        assert_eq!(epoch_to_iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso8601(1_000_000_000), "2001-09-09T01:46:40Z");
        // A leap day, because off-by-one calendars are the classic bug here.
        assert_eq!(epoch_to_iso8601(1_709_164_800), "2024-02-29T00:00:00Z");
        assert_eq!(epoch_to_iso8601(1_753_660_800), "2025-07-28T00:00:00Z");
    }
}
