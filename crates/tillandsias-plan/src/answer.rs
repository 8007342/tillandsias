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
use std::path::{Component, Path, PathBuf};

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
        Self::for_corpus(source, &[])
    }

    /// ORDER 606-h9vy — freshness over the FOLDED corpus: the base index plus
    /// every fragment beside it. `indexed_at` is the NEWEST mtime across the
    /// whole set, so writing a fragment advances it exactly like editing the
    /// base — a fragment-only change can no longer masquerade as an old
    /// corpus. The keys stay `source_commit`/`indexed_at`: consumers pin that
    /// exact shape, and "when was this corpus last written" is still the one
    /// honest meaning of `indexed_at`.
    pub fn for_corpus(source: &Path, fragments: &[PathBuf]) -> Self {
        let indexed_at = std::iter::once(source.to_path_buf())
            .chain(fragments.iter().cloned())
            .filter_map(|p| file_mtime_epoch(&p))
            .max()
            .map(epoch_to_iso8601)
            .unwrap_or_else(|| "unknown".to_string());
        Self {
            source_commit: git_head_sha(source).unwrap_or_else(|| "unknown".to_string()),
            indexed_at,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    citation_root: Option<String>,
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
            citation_root: None,
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
            citation_root: None,
        }
    }

    pub fn with_citation_root(mut self, root: &Path) -> Self {
        let path = if root.as_os_str().is_empty() {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        } else {
            root.canonicalize().unwrap_or_else(|_| root.to_path_buf())
        };
        let s = path.display().to_string();
        if !s.is_empty() {
            self.citation_root = Some(s);
        } else {
            self.citation_root = None;
        }
        self
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
    pub fn citation_root(&self) -> Option<&str> {
        self.citation_root.as_deref()
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
        // ORDER 606-h9vy — every authority VALUE must be substantiated by the
        // cited span, not merely accompany a span that names the packet. This
        // is what turns a fabricated status/order, or a stale base span cited
        // for a fragment-won field, into a hard rejection instead of a
        // well-formed lie. `packet_id` is already covered by `span_key` above.
        if c.kind == CitationKind::Plan {
            for (key, value) in &c.authority {
                if key == "packet_id" {
                    continue;
                }
                if !span_substantiates(&span, key, value) {
                    violations.push(format!(
                        "{}:{}-{}: cited span does not substantiate authority {}={} — TAMPERED or stale authority",
                        c.path, c.line_start, c.line_end, key, value
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

/// ORDER 606-h9vy — does `span` substantiate `key = value`? Two grammars are
/// accepted, matching the two shapes a plan value legitimately lives in: a
/// packet-block field line (`status: ready`, optionally quoted, optionally
/// carrying a trailing comment) and a fragment LWW status entry
/// (`field: status` on one line, `value: ready` on another).
fn span_substantiates(span: &str, key: &str, value: &str) -> bool {
    let has_field_line = |k: &str, v: &str| {
        let forms = [
            format!("{k}: {v}"),
            format!("{k}: '{v}'"),
            format!("{k}: \"{v}\""),
        ];
        span.lines().any(|l| {
            let t = l.trim_start().trim_start_matches("- ").trim_end();
            forms.iter().any(|f| {
                t == f.as_str()
                    || (t.starts_with(f.as_str()) && t[f.len()..].trim_start().starts_with('#'))
            })
        })
    };
    has_field_line(key, value) || (has_field_line("field", key) && has_field_line("value", value))
}

// ── question -> deterministic query ─────────────────────────────────────────

/// The CLOSED set of questions rung 1 can answer. Anything outside it is
/// `unsupported` — there is deliberately no fallback that guesses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    BlockedBy(String),
    DependenciesOf(String),
    Closure(String),
    Status(String),
    Ready {
        role: Option<String>,
        release: Option<String>,
    },
    /// ORDER 606-xu52 — the cold-start question: at most five cited,
    /// release-aware, role-compatible, dependency-clear, unleased claimable
    /// packets, ranked deterministically. The natural aliases are exactly
    /// "what's next?" and the "what <release> work can I do on <role>?"
    /// family.
    Next {
        role: Option<String>,
        release: Option<String>,
    },
    Burndown(String),
    UnsupportedConstraint(String),
}

/// Strip the punctuation an agent types around a reference.
fn clean_token(t: &str) -> &str {
    t.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '-')))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DependencyDirection {
    Upstream,
    Downstream,
}

/// Infer edge direction from word order around the resolved packet token.
///
/// `what is blocked by X` asks for consumers downstream of X, while `what is
/// X blocked by` asks for X's prerequisites. Treating the shared phrase as an
/// unordered keyword reverses one of those questions with total confidence.
fn dependency_direction(
    tokens: &[String],
    reference_at: Option<usize>,
    phrase: &[&str],
) -> Option<DependencyDirection> {
    let reference_at = reference_at?;
    let phrase_at = tokens
        .windows(phrase.len())
        .position(|window| window.iter().map(String::as_str).eq(phrase.iter().copied()))?;
    if phrase_at < reference_at {
        Some(DependencyDirection::Downstream)
    } else if reference_at < phrase_at {
        Some(DependencyDirection::Upstream)
    } else {
        None
    }
}

/// Deterministic intent classification. NO model, NO fuzzy matching: keyword
/// presence plus "which token in this question names a packet the ledger
/// actually has". A question naming no resolvable packet is refused rather
/// than answered about some nearby packet.
pub fn classify(ledger: &Ledger, question: &str) -> Option<Intent> {
    let lower = question.to_ascii_lowercase();
    let tokens: Vec<&str> = question
        .split_whitespace()
        .map(clean_token)
        .filter(|t| !t.is_empty())
        .collect();
    let resolved = tokens
        .iter()
        .enumerate()
        .find(|(_, token)| ledger.resolve(token).is_some());
    let reference_at = resolved.map(|(at, _)| at);
    let reference = resolved.map(|(_, token)| (*token).to_string());
    let lower_tokens: Vec<String> = tokens
        .iter()
        .map(|token| token.to_ascii_lowercase())
        .collect();
    let blocked_by_direction =
        dependency_direction(&lower_tokens, reference_at, &["blocked", "by"]);
    let waiting_on_direction =
        dependency_direction(&lower_tokens, reference_at, &["waiting", "on"]);
    let depends_on_direction =
        dependency_direction(&lower_tokens, reference_at, &["depends", "on"])
            .or_else(|| dependency_direction(&lower_tokens, reference_at, &["depend", "on"]));

    let wants_closure = lower.contains("closure")
        || lower.contains("downstream")
        || lower.contains("transitive")
        || lower.contains("everything blocked by");
    let wants_blocked = matches!(blocked_by_direction, Some(DependencyDirection::Downstream))
        || matches!(waiting_on_direction, Some(DependencyDirection::Downstream))
        || matches!(depends_on_direction, Some(DependencyDirection::Downstream))
        || lower.contains("blocked-by");
    let wants_dependencies = lower.contains("what blocks")
        || lower.contains("blocked on")
        || lower.contains("blocked-on")
        || lower.contains("dependencies of")
        || lower.contains("prerequisites of")
        || matches!(blocked_by_direction, Some(DependencyDirection::Upstream))
        || matches!(waiting_on_direction, Some(DependencyDirection::Upstream))
        || matches!(depends_on_direction, Some(DependencyDirection::Upstream));
    let wants_burndown = lower.contains("burndown")
        || lower.contains("children of")
        || lower.contains("milestone")
        || lower.contains("release target");
    // ORDER 606-xu52: "work can i do" belongs to the ranked NEXT surface, not
    // the flat ready listing — "what v0.5 work can I do on linux?" is one of
    // plan_next's two exact natural aliases. "ready"/"pick up" wordings keep
    // the plain enumeration.
    let wants_next = lower.contains("what's next")
        || lower.contains("whats next")
        || lower.contains("what is next")
        || lower.contains("work can i do");
    let wants_ready = lower.contains("ready")
        || lower.contains("what can i pick up")
        || lower.contains("work can i pick up");

    let release = match release_in(ledger, question) {
        Ok(release) => release,
        Err(constraint) if wants_ready || wants_next => {
            return Some(Intent::UnsupportedConstraint(constraint));
        }
        Err(_) => None,
    };

    if let Some(r) = reference {
        if wants_closure {
            return Some(Intent::Closure(r));
        }
        if wants_blocked {
            return Some(Intent::BlockedBy(r));
        }
        if wants_dependencies {
            return Some(Intent::DependenciesOf(r));
        }
        if wants_burndown {
            return Some(Intent::Burndown(r));
        }
        if wants_next {
            return Some(Intent::Next {
                role: role_in(ledger, &lower),
                release,
            });
        }
        if wants_ready {
            return Some(Intent::Ready {
                role: role_in(ledger, &lower),
                release,
            });
        }
        return Some(Intent::Status(r));
    }
    if wants_next {
        return Some(Intent::Next {
            role: role_in(ledger, &lower),
            release,
        });
    }
    if wants_ready {
        return Some(Intent::Ready {
            role: role_in(ledger, &lower),
            release,
        });
    }
    None
}

fn release_in(ledger: &Ledger, question: &str) -> Result<Option<String>, String> {
    let mut releases: Vec<String> = ledger
        .packets
        .iter()
        .filter_map(|p| p.get("desired_release").and_then(serde_yaml::Value::as_str))
        .map(str::to_string)
        .collect();
    releases.sort();
    releases.dedup();

    let mut selected: Option<String> = None;
    for raw in question.split_whitespace().map(clean_token) {
        if let Some(release) = releases.iter().find(|release| release.as_str() == raw) {
            if let Some(first) = selected.as_deref()
                && first != release
            {
                return Err(format!(
                    "multiple release constraints are unsupported ('{first}' and '{release}')"
                ));
            }
            selected = Some(release.clone());
            continue;
        }
        if looks_like_release(raw) {
            return Err(format!(
                "unknown release constraint '{raw}' (known desired_release values: {})",
                releases.join(",")
            ));
        }
    }
    Ok(selected)
}

fn looks_like_release(token: &str) -> bool {
    let Some(version) = token.strip_prefix('v').or_else(|| token.strip_prefix('V')) else {
        return false;
    };
    let parts: Vec<&str> = version.split('.').collect();
    parts.len() >= 2
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
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
        .map(|p| Freshness::for_corpus(p, ledger.corpus_files()))
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

    if let Intent::UnsupportedConstraint(reason) = &intent {
        return Envelope::unsupported(reason, freshness);
    }

    if let Intent::Next { role, release } = &intent {
        return answer_next(
            ledger,
            role.as_deref(),
            release.as_deref(),
            None,
            source_rel,
        );
    }

    let (headline, packets): (String, Vec<&serde_yaml::Value>) = match &intent {
        Intent::BlockedBy(r) => (
            format!("packets directly blocked by '{r}'"),
            ledger.blocked_by(r),
        ),
        Intent::DependenciesOf(r) => (
            format!("direct unsatisfied prerequisites blocking '{r}'"),
            ledger.dependencies_of(r).unwrap_or_default(),
        ),
        Intent::Closure(r) => (
            format!("packets transitively downstream of '{r}'"),
            ledger.blocked_by_closure(r),
        ),
        Intent::Burndown(r) => (
            format!("release-target children of '{r}'"),
            ledger.milestone_children(r),
        ),
        Intent::Ready { role, release } => {
            let mut packets = ledger.ready(role.as_deref());
            if let Some(release) = release {
                packets.retain(|p| {
                    p.get("desired_release").and_then(serde_yaml::Value::as_str)
                        == Some(release.as_str())
                });
            }
            let headline = match (role, release) {
                (Some(role), Some(release)) => {
                    format!("ready packets for pickup_role '{role}' in desired_release '{release}'")
                }
                (Some(role), None) => format!("ready packets for pickup_role '{role}'"),
                (None, Some(release)) => {
                    format!("ready packets in desired_release '{release}'")
                }
                (None, None) => "ready packets".to_string(),
            };
            (headline, packets)
        }
        Intent::Status(r) => (
            format!("status of '{r}'"),
            ledger.resolve(r).into_iter().collect(),
        ),
        Intent::UnsupportedConstraint(_) => unreachable!("handled before query execution"),
        Intent::Next { .. } => unreachable!("handled before query execution"),
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

    let mut body = String::from("order\tstatus\tdesired_release\trelease_target\tpacket_id\n");
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
        let desired_release = p
            .get("desired_release")
            .and_then(serde_yaml::Value::as_str)
            .unwrap_or("-");
        let release_target = p
            .get("release_target")
            .and_then(serde_yaml::Value::as_str)
            .unwrap_or("-");
        let mut fields: Vec<(&str, String)> =
            vec![("order", order.clone()), ("status", status.to_string())];
        if desired_release != "-" {
            fields.push(("desired_release", desired_release.to_string()));
        }
        if release_target != "-" {
            fields.push(("release_target", release_target.to_string()));
        }
        let Some(row_citations) = packet_row_citations(ledger, &id, fields, source_rel) else {
            // A row we cannot point at is a row we do not report. Reporting it
            // uncited would be an unsupported claim smuggled into a supported
            // envelope.
            uncitable.push(id);
            continue;
        };
        body.push_str(&format!(
            "{order}\t{status}\t{desired_release}\t{release_target}\t{id}\n"
        ));
        citations.extend(row_citations);
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

// ── ORDER 606-h9vy/606-xu52: provenance-aware row citations ─────────────────

/// Citations for ONE packet row, citing the source that actually WON each
/// folded field (order 606-h9vy). The packet's origin span — its base block,
/// or the fragment item that created a fragment-born packet — substantiates
/// every field the fold did not override; each LWW-overridden field is cited
/// to the fragment status entry that won it, NEVER to the stale base span.
/// Returns `None` when no source span exists anywhere, in which case the row
/// must be omitted rather than reported uncited.
fn packet_row_citations(
    ledger: &Ledger,
    id: &str,
    fields: Vec<(&str, String)>,
    source_rel: &str,
) -> Option<Vec<Citation>> {
    let (origin_path, line_start, line_end) = ledger
        .span_of(id)
        .map(|(s, e)| (source_rel.to_string(), s, e))
        .or_else(|| {
            ledger.origin_source_of(id).map(|src| {
                (
                    fragment_rel(source_rel, &src.fragment_name),
                    src.line_start,
                    src.line_end,
                )
            })
        })?;
    let mut citations = Vec::new();
    let mut origin_authority = BTreeMap::new();
    origin_authority.insert("packet_id".to_string(), id.to_string());
    for (field, value) in fields {
        match ledger.field_source_of(id, field) {
            Some(src) => {
                // The winning fragment entry substantiates exactly this
                // field; it gets its own citation so the origin span is
                // never claimed to say a value it does not contain.
                let mut authority = BTreeMap::new();
                authority.insert("packet_id".to_string(), id.to_string());
                authority.insert(field.to_string(), value);
                citations.push(Citation::new(
                    fragment_rel(source_rel, &src.fragment_name),
                    src.line_start,
                    src.line_end,
                    CitationKind::Plan,
                    authority,
                ));
            }
            None => {
                origin_authority.insert(field.to_string(), value);
            }
        }
    }
    citations.push(Citation::new(
        origin_path,
        line_start,
        line_end,
        CitationKind::Plan,
        origin_authority,
    ));
    Some(citations)
}

// ── ORDER 606-xu52: the deterministic plan_next selector ────────────────────

/// Hard cap on plan_next results. A cold agent needs the top few claimable
/// actions, not a queue dump; five is the committed contract and both the CLI
/// and the MCP schema refuse more.
pub const NEXT_LIMIT_MAX: usize = 5;

/// Committed size budget for the plan_next ANSWER TEXT in bytes. The envelope
/// is a cold-start surface read by agents with fresh contexts; a result that
/// grows with the backlog defeats it. Pinned by tests on both the fixture and
/// the real ledger.
pub const NEXT_ANSWER_BYTE_BUDGET: usize = 4096;

/// Per-row cap on the next-action snippet, in characters.
const NEXT_ACTION_SNIPPET_CHARS: usize = 160;

fn priority_rank(p: &serde_yaml::Value) -> u8 {
    match crate::str_field(p, "priority") {
        Some("p0") => 0,
        Some("p1") => 1,
        Some("p2") => 2,
        Some("p3") => 3,
        _ => 9,
    }
}

/// The deterministic ranking key (packet 606-xu52's committed tuple): active
/// release and the eligibility filters gate BEFORE ranking; among eligible
/// rows the order is (priority, release-targeted first, order prefix, order
/// token, packet_id) — a total order, so two hosts render identical results
/// from identical ledgers.
fn next_ranking_key(ledger: &Ledger, p: &serde_yaml::Value) -> (u8, u8, u64, String, String) {
    let order_token = p
        .get("order")
        .map(|v| match v {
            serde_yaml::Value::Number(n) => n.to_string(),
            serde_yaml::Value::String(s) => s.clone(),
            _ => "~".into(),
        })
        .unwrap_or_else(|| "~".into());
    let order_prefix = order_token
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse::<u64>()
        .unwrap_or(u64::MAX);
    (
        priority_rank(p),
        u8::from(crate::str_field(p, "release_target").is_none()),
        order_prefix,
        order_token,
        ledger.id_of(p),
    )
}

/// One-line, bounded rendering of the packet's own next step.
fn next_action_snippet(p: &serde_yaml::Value) -> String {
    let raw = crate::str_field(p, "next_action")
        .or_else(|| crate::str_field(p, "handoff_note"))
        .or_else(|| crate::str_field(p, "outcome"))
        .or_else(|| crate::str_field(p, "title"))
        .unwrap_or("see packet");
    let one_line = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate(&one_line, NEXT_ACTION_SNIPPET_CHARS)
}

/// ORDER 606-xu52 — the cold-start selector. At most [`NEXT_LIMIT_MAX`] cited,
/// release-aware, role-compatible, dependency-clear, unleased `ready` packets,
/// each with the reason it ranked and its concrete next action.
///
/// Exclusions (each one a class the packet's exit criteria name): packets with
/// unmet dependencies; incompatible `pickup_role`; a live `lease` or an
/// `owned_files` scope intersecting an active claim; terminal/non-ready work;
/// `kind: milestone` packets and criteria holders (anything another packet
/// names as its `release_target`) — those hold criteria, they are never
/// claims.
///
/// The release defaults from the folded `## ACTIVE RELEASE` heading beside the
/// index; a packet with no `desired_release` counts only when the filter
/// release IS the active one (unmarked open packets default to the active
/// release, `methodology/distributed-work.yaml` → version_aware_release_planning).
/// No release anywhere is a typed refusal, never an unscoped dump.
pub fn answer_next(
    ledger: &Ledger,
    role: Option<&str>,
    release: Option<&str>,
    limit: Option<usize>,
    source_rel: &str,
) -> Envelope {
    let freshness = ledger
        .source_path()
        .map(|p| Freshness::for_corpus(p, ledger.corpus_files()))
        .unwrap_or_else(|| Freshness::new("unknown".into(), "unknown".into()));
    let limit = limit.unwrap_or(NEXT_LIMIT_MAX).clamp(1, NEXT_LIMIT_MAX);

    let active = ledger
        .source_path()
        .and_then(Path::parent)
        .map(|d| d.join("loop_status.md"))
        .and_then(|ls| crate::loop_status::active_release(&ls));
    let Some(release) = release.map(str::to_string).or_else(|| active.clone()) else {
        return Envelope::unsupported(
            "no claimable work can be selected: no explicit release was given and the folded \
             loop status declares no ACTIVE RELEASE",
            freshness,
        );
    };
    let release_is_active = active.as_deref() == Some(release.as_str());

    // Criteria holders: anything ANOTHER packet names as its release_target.
    let criteria_holders: std::collections::BTreeSet<String> = ledger
        .packets
        .iter()
        .filter_map(|p| crate::str_field(p, "release_target"))
        .map(str::to_string)
        .collect();
    // File scopes under an active claim: owned_files of every leased or
    // in-flight packet.
    let mut claimed_files: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for p in &ledger.packets {
        let leased = p.get("lease").is_some_and(|v| !v.is_null());
        let in_flight = matches!(
            crate::str_field(p, "status"),
            Some("in_progress" | "claimed")
        );
        if leased || in_flight {
            for f in crate::str_list(p, "owned_files") {
                claimed_files.insert(f);
            }
        }
    }

    let mut eligible: Vec<&serde_yaml::Value> = ledger
        .ready(role)
        .into_iter()
        .filter(|p| {
            let id = ledger.id_of(p);
            let release_ok = match crate::str_field(p, "desired_release") {
                Some(r) => r == release,
                None => release_is_active,
            };
            release_ok
                && crate::str_field(p, "kind") != Some("milestone")
                && !criteria_holders.contains(&id)
                && ledger.dependencies_of(&id).is_some_and(|d| d.is_empty())
                && !p.get("lease").is_some_and(|v| !v.is_null())
                && !crate::str_list(p, "owned_files")
                    .iter()
                    .any(|f| claimed_files.contains(f))
        })
        .collect();
    eligible.sort_by_key(|p| next_ranking_key(ledger, p));
    let total_eligible = eligible.len();
    eligible.truncate(limit);

    let role_part = role
        .map(|r| format!(" for pickup_role '{r}'"))
        .unwrap_or_default();
    if eligible.is_empty() {
        return Envelope::unsupported(
            format!(
                "no claimable work{role_part} in desired_release '{release}' after excluding \
                 milestones, criteria holders, leased or file-claimed scopes, and unmet \
                 dependencies"
            ),
            freshness,
        );
    }

    let mut body = format!(
        "next claimable work{role_part} in desired_release '{release}' (top {} of {} eligible):\n",
        eligible.len(),
        total_eligible
    );
    let mut citations = Vec::new();
    for (rank, p) in eligible.iter().enumerate() {
        let id = ledger.id_of(p);
        let order = p
            .get("order")
            .map(|v| match v {
                serde_yaml::Value::Number(n) => n.to_string(),
                serde_yaml::Value::String(s) => s.clone(),
                _ => "?".into(),
            })
            .unwrap_or_else(|| "?".into());
        let priority = crate::str_field(p, "priority").unwrap_or("-");
        let mut why: Vec<String> = vec![format!("priority {priority}")];
        if let Some(target) = crate::str_field(p, "release_target") {
            why.push(format!("targets {target}"));
        }
        why.push("deps clear".to_string());
        why.push("unleased".to_string());
        let mut fields: Vec<(&str, String)> =
            vec![("order", order.clone()), ("status", "ready".to_string())];
        if let Some(r) = crate::str_field(p, "desired_release") {
            fields.push(("desired_release", r.to_string()));
        }
        if let Some(t) = crate::str_field(p, "release_target") {
            fields.push(("release_target", t.to_string()));
        }
        let Some(row_citations) = packet_row_citations(ledger, &id, fields, source_rel) else {
            // Same rule as every other row surface: a row we cannot point at
            // is a row we do not offer as a claim.
            continue;
        };
        citations.extend(row_citations);
        body.push_str(&format!(
            "{}. {order}\t{id}\twhy: {}\n   next: {}\n",
            rank + 1,
            why.join(", "),
            next_action_snippet(p)
        ));
    }

    // The committed budget is structural (bounded rows x bounded snippets),
    // and enforced: a result that cannot fit is truncated at a row boundary
    // rather than shipped oversize.
    while body.len() > NEXT_ANSWER_BYTE_BUDGET {
        match body.rfind("\n") {
            Some(cut) if cut > 0 => body.truncate(cut),
            _ => break,
        }
    }

    Envelope::supported(body, citations, Confidence::Exact, freshness)
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
    // A linked worktree's private gitdir holds HEAD but shares refs and
    // packed-refs through the COMMON directory named by its `commondir` file
    // (order 606-h9vy). Resolve the ref against the private dir first, then
    // the common one — the layouts where each applies are disjoint.
    let common = std::fs::read_to_string(git_dir.join("commondir"))
        .ok()
        .map(|raw| {
            let p = Path::new(raw.trim());
            if p.is_absolute() {
                p.to_path_buf()
            } else {
                git_dir.join(p)
            }
        });
    let ref_dirs = std::iter::once(git_dir.to_path_buf()).chain(common);
    let mut packed_candidates = Vec::new();
    for dir in ref_dirs {
        if let Ok(sha) = std::fs::read_to_string(dir.join(reference)) {
            return Some(sha.trim().to_string());
        }
        packed_candidates.push(dir.join("packed-refs"));
    }
    packed_candidates.into_iter().find_map(|packed_path| {
        let packed = std::fs::read_to_string(packed_path).ok()?;
        packed.lines().find_map(|l| {
            let (sha, name) = l.split_once(' ')?;
            (name.trim() == reference).then(|| sha.trim().to_string())
        })
    })
}

fn file_mtime_epoch(path: &Path) -> Option<i64> {
    Some(
        std::fs::metadata(path)
            .ok()?
            .modified()
            .ok()?
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_secs() as i64,
    )
}

/// ORDER 606-h9vy — the repo-relative path of a fragment, derived from the
/// label the citations use for the index it sits beside:
/// `plan/index.yaml` + `20260807t0-x-h.yaml` -> `plan/index.d/20260807t0-x-h.yaml`.
/// Mirrors `fragments::fragment_dir`, which derives the directory from the
/// index file stem.
fn fragment_rel(source_rel: &str, fragment_name: &str) -> String {
    let (dir, file) = match source_rel.rsplit_once('/') {
        Some((dir, file)) => (Some(dir), file),
        None => (None, source_rel),
    };
    let stem = file.strip_suffix(".yaml").unwrap_or(file);
    match dir {
        Some(dir) => format!("{dir}/{stem}.d/{fragment_name}"),
        None => format!("{stem}.d/{fragment_name}"),
    }
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

    fn fixture_ledger(name: &str, raw: &str) -> (Ledger, PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "tillandsias-plan-answer-{name}-{}.yaml",
            std::process::id()
        ));
        std::fs::write(&path, raw).expect("write answer fixture");
        let ledger = Ledger::load(&path).expect("load answer fixture");
        (ledger, path)
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

    /// ORDER 606-h9vy — shape (g): a REAL span that names the packet must
    /// still be refused when an authority VALUE is fabricated. Before this,
    /// verify substantiated only the packet_id line, so `status: whatever`
    /// rode along unchecked — a well-formed lie.
    #[test]
    fn fabricated_authority_values_are_refused_even_on_a_real_span() {
        let ledger = live_ledger();
        let env = answer_question(&ledger, "status of 394a", "plan/index.yaml");
        assert_eq!(env.confidence(), Confidence::Exact);
        let good = &env.citations()[0];
        let root = repo_root();

        for (key, forged) in [
            ("status", "definitely-not-what-the-span-says"),
            ("order", "999999-zzzz"),
        ] {
            let mut tampered = good.authority().clone();
            tampered.insert(key.to_string(), forged.to_string());
            let bad = Envelope::supported(
                env.answer(),
                vec![Citation::new(
                    good.path().into(),
                    good.line_start(),
                    good.line_end(),
                    CitationKind::Plan,
                    tampered,
                )],
                Confidence::Exact,
                fresh(),
            );
            assert!(
                verify(&bad, &root)
                    .iter()
                    .any(|v| v.contains("does not substantiate authority")),
                "a fabricated authority {key} must be refused"
            );
        }
    }

    /// ORDER 606-h9vy — the two substantiation grammars, and the prefix trap.
    #[test]
    fn span_substantiation_accepts_both_grammars_and_rejects_prefixes() {
        // Packet-block grammar, with and without a trailing stamp comment.
        assert!(span_substantiates("      status: ready", "status", "ready"));
        assert!(span_substantiates(
            "      status: ready  # freshness: audited",
            "status",
            "ready"
        ));
        assert!(span_substantiates("      order: '394'", "order", "394"));
        // Fragment LWW-entry grammar.
        assert!(span_substantiates(
            "  - packet_id: x\n    field: status\n    value: in_progress",
            "status",
            "in_progress"
        ));
        // A value prefix is NOT substantiation.
        assert!(!span_substantiates("      status: ready", "status", "read"));
        // A contradictory value is not substantiation either.
        assert!(!span_substantiates(
            "      status: ready",
            "status",
            "in_progress"
        ));
        // The LWW grammar needs BOTH halves — a lone `field:` line proves
        // nothing about the value.
        assert!(!span_substantiates(
            "    field: status\n    other: x",
            "status",
            "in_progress"
        ));
    }

    /// ORDER 606-h9vy — freshness must resolve the HEAD sha through a linked
    /// worktree's `commondir` indirection: the private gitdir holds HEAD, but
    /// the ref it names lives in the shared common directory.
    #[test]
    fn head_sha_resolves_through_a_worktree_commondir_layout() {
        let d = std::env::temp_dir().join(format!("tilland-commondir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let sha = "1234567890abcdef1234567890abcdef12345678";
        std::fs::create_dir_all(d.join("main/.git/refs/heads")).expect("mkdir");
        std::fs::create_dir_all(d.join("main/.git/worktrees/wt")).expect("mkdir");
        std::fs::create_dir_all(d.join("wt/plan")).expect("mkdir");
        std::fs::write(d.join("main/.git/refs/heads/b"), format!("{sha}\n")).expect("ref");
        std::fs::write(d.join("main/.git/worktrees/wt/HEAD"), "ref: refs/heads/b\n").expect("head");
        std::fs::write(d.join("main/.git/worktrees/wt/commondir"), "../..\n").expect("commondir");
        std::fs::write(
            d.join("wt/.git"),
            format!("gitdir: {}\n", d.join("main/.git/worktrees/wt").display()),
        )
        .expect("gitfile");
        std::fs::write(d.join("wt/plan/index.yaml"), "packets: []\n").expect("index");

        let f = Freshness::for_source(&d.join("wt/plan/index.yaml"));
        assert_eq!(
            f.source_commit(),
            sha,
            "the ref named by the worktree HEAD resolves in the COMMON dir"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// ORDER 606-xu52 — plan_next stays inside its committed byte budget on
    /// the REAL ledger (a cold-start surface must not grow with the backlog)
    /// and renders byte-identically across independent loads of the fixture
    /// corpus, with the release defaulting from the folded ACTIVE RELEASE and
    /// the five-row cap holding against a sixth eligible packet.
    #[test]
    fn plan_next_is_bounded_deterministic_and_release_defaulted() {
        let real =
            Ledger::load_with_fragments(&repo_root().join("plan/index.yaml")).expect("loads");
        let live = answer_next(&real, None, Some("v0.5"), None, "plan/index.yaml");
        assert!(
            live.answer().len() <= NEXT_ANSWER_BYTE_BUDGET,
            "plan_next over budget on the real ledger: {} bytes",
            live.answer().len()
        );

        let fix = repo_root()
            .join("openspec/litmus-tests/groundtruth/fixtures/plan-next/plan/index.yaml");
        let a = answer_next(
            &Ledger::load_with_fragments(&fix).expect("fixture loads"),
            None,
            None,
            None,
            "plan/index.yaml",
        );
        let b = answer_next(
            &Ledger::load_with_fragments(&fix).expect("fixture loads"),
            None,
            None,
            None,
            "plan/index.yaml",
        );
        assert_eq!(a.answer(), b.answer(), "two loads must render identically");
        assert_eq!(a.citations(), b.citations());
        assert!(
            a.answer().contains("desired_release 'v9.9'"),
            "release must default from the fixture's folded ACTIVE RELEASE: {}",
            a.answer()
        );
        assert!(
            a.answer().contains("(top 5 of 6 eligible)"),
            "five-row cap against six eligible: {}",
            a.answer()
        );
        assert!(a.answer().len() <= NEXT_ANSWER_BYTE_BUDGET);
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
            classify(&ledger, "what blocks forge-local-experts-milestone"),
            Some(Intent::DependenciesOf(_))
        ));
        assert!(matches!(
            classify(&ledger, "everything downstream of 394a"),
            Some(Intent::Closure(_))
        ));
        assert!(matches!(
            classify(&ledger, "what is ready for linux"),
            Some(Intent::Ready { role: Some(r), release: None }) if r == "linux"
        ));
        // ORDER 606-xu52: this exact wording is one of plan_next's two natural
        // aliases — it classifies to the RANKED surface, not the flat listing.
        assert!(matches!(
            classify(&ledger, "what v0.5 work can I do on linux?"),
            Some(Intent::Next { role: Some(r), release: Some(v) })
                if r == "linux" && v == "v0.5"
        ));
        assert!(matches!(
            classify(&ledger, "what's next?"),
            Some(Intent::Next {
                role: None,
                release: None
            })
        ));
        assert!(matches!(
            classify(&ledger, "what v9.9 work can I do on linux?"),
            Some(Intent::UnsupportedConstraint(reason))
                if reason.contains("unknown release constraint 'v9.9'")
        ));
        assert!(matches!(
            classify(&ledger, "what V0.5 work can I do on linux?"),
            Some(Intent::UnsupportedConstraint(reason))
                if reason.contains("unknown release constraint 'V0.5'")
        ));
        assert!(matches!(
            classify(&ledger, "what v0.5 v9.9 work can I do on linux?"),
            Some(Intent::UnsupportedConstraint(reason))
                if reason.contains("unknown release constraint 'v9.9'")
        ));
        assert!(matches!(
            classify(&ledger, "what v0.5 v0.6 work can I do on linux?"),
            Some(Intent::UnsupportedConstraint(reason))
                if reason.contains("multiple release constraints are unsupported")
        ));
        assert!(matches!(classify(&ledger, "394a"), Some(Intent::Status(_))));
        assert!(classify(&ledger, "how do I feel today").is_none());
    }

    #[test]
    fn dependency_word_order_preserves_upstream_and_downstream_direction() {
        let ledger = live_ledger();
        for question in [
            "what is forge-local-experts-milestone blocked by?",
            "what is forge-local-experts-milestone waiting on?",
            "what does forge-local-experts-milestone depend on?",
        ] {
            assert!(
                matches!(classify(&ledger, question), Some(Intent::DependenciesOf(_))),
                "packet-before-relation wording must query upstream: {question}"
            );
        }
        for question in [
            "what is blocked by forge-local-experts-milestone?",
            "what is waiting on forge-local-experts-milestone?",
            "what depends on forge-local-experts-milestone?",
        ] {
            assert!(
                matches!(classify(&ledger, question), Some(Intent::BlockedBy(_))),
                "relation-before-packet wording must query downstream: {question}"
            );
        }
    }

    #[test]
    fn release_ready_answer_never_leaks_another_release() {
        let (ledger, path) = fixture_ledger(
            "release-filter",
            "steps:\n  - packet_id: v05-ready\n    order: 1\n    status: ready\n    pickup_role: linux\n    desired_release: v0.5\n  - packet_id: v06-ready\n    order: 2\n    status: ready\n    pickup_role: linux\n    desired_release: v0.6\n",
        );
        let env = answer_question(&ledger, "what v0.5 work can I do on linux?", "fixture.yaml");
        assert_eq!(env.confidence(), Confidence::Exact, "{}", env.answer());
        assert!(!env.citations().is_empty());
        for citation in env.citations() {
            assert_eq!(
                citation
                    .authority()
                    .get("desired_release")
                    .map(String::as_str),
                Some("v0.5"),
                "every cited row must retain the exact release constraint: {:?}",
                citation.authority()
            );
        }
        assert!(env.answer().contains("v05-ready"));
        assert!(!env.answer().contains("v06-ready"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn milestone_upstream_answer_excludes_satisfied_and_downstream_packets() {
        let (ledger, path) = fixture_ledger(
            "upstream",
            "steps:\n  - packet_id: open-prerequisite\n    order: 1\n    status: in_progress\n  - packet_id: satisfied-prerequisite\n    order: 2\n    status: completed\n  - packet_id: target-milestone\n    order: 3\n    status: ready\n    depends_on: [open-prerequisite, satisfied-prerequisite]\n  - packet_id: downstream-consumer\n    order: 4\n    status: ready\n    depends_on: [target-milestone]\n",
        );
        for question in [
            "what blocks target-milestone",
            "what is target-milestone blocked by?",
            "what is target-milestone waiting on?",
        ] {
            let env = answer_question(&ledger, question, "fixture.yaml");
            assert_eq!(env.confidence(), Confidence::Exact, "{}", env.answer());
            let ids: Vec<&str> = env
                .citations()
                .iter()
                .filter_map(|c| c.authority().get("packet_id").map(String::as_str))
                .collect();
            assert_eq!(ids, vec!["open-prerequisite"], "{question}");
            assert!(!env.answer().contains("satisfied-prerequisite"));
            assert!(!env.answer().contains("downstream-consumer"));
        }

        let downstream = answer_question(
            &ledger,
            "what is blocked by target-milestone?",
            "fixture.yaml",
        );
        assert_eq!(
            downstream.confidence(),
            Confidence::Exact,
            "{}",
            downstream.answer()
        );
        let ids: Vec<&str> = downstream
            .citations()
            .iter()
            .filter_map(|c| c.authority().get("packet_id").map(String::as_str))
            .collect();
        assert_eq!(ids, vec!["downstream-consumer"]);
        assert!(!downstream.answer().contains("open-prerequisite"));
        let _ = std::fs::remove_file(path);
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
