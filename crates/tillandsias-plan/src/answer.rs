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
use crate::gitref::{self, GitView, Relation};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
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
// `Eq` is deliberately NOT derived (order 821-73es): `score` is an f32, and
// f32 has no total equality. Nothing needed `Eq` — no HashSet/HashMap keyed
// on a citation, no trait bound requiring it — so dropping it costs nothing,
// while `PartialEq` keeps every assert_eq! in the tests working.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    /// ORDER 801-g9nn — the commit whose blob this span was extracted from.
    ///
    /// `line_start`/`line_end` are only meaningful relative to a version of the
    /// file, and until this field existed the envelope named none: an agent
    /// handed `openspec/specs/forge-offline/spec.md:45-49` opened line 45 in ITS
    /// OWN checkout, and if the file had moved it read the wrong lines with full
    /// confidence. With a mirror-backed index shared by concurrent harnesses
    /// (801-a2by) the two frames routinely differ, and since 803-su4n the corpus
    /// includes CODE, where a stale line number is a wrong edit rather than a
    /// wrong quote.
    ///
    /// ADDITIVE AND ABSENT WHEN UNKNOWN. A citation from a corpus with no commit
    /// behind it (a scratch checkout, a fixture) omits the field entirely rather
    /// than writing a placeholder that later reads as a real rev. Absent means
    /// "no frame is claimed", which is honest; a fabricated sha would not be.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    commit: Option<String>,
    /// ORDER 821-73es — how well this span actually matched the query.
    ///
    /// Cosine top-k ALWAYS returns k results, so `confidence: retrieved` means
    /// "k chunks were found", not "the corpus covers this". Without a number,
    /// nothing downstream could tell those apart: a question the corpus knows
    /// nothing about came back with six real, verifiable citations. This is the
    /// signal a consumer needs to decide otherwise.
    ///
    /// ADDITIVE AND ABSENT WHEN UNKNOWN, exactly like `commit` above. A
    /// deterministic expert (plan, methodology) has no similarity to report and
    /// omits the field rather than writing 1.0, which would read as a perfect
    /// match rather than as "not applicable".
    ///
    /// Carrying it is NOT refusing on it. No threshold is applied anywhere yet;
    /// measurement on this host put the usable band at 0.693-0.720 against near
    /// misses, a 0.027 margin too thin to pick a fleet-wide number from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    score: Option<f32>,
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
            commit: None,
            score: None,
        }
    }

    /// ORDER 821-73es — stamp how well this span matched the query.
    ///
    /// A value outside [-1, 1], or NaN, is DROPPED rather than stored — the
    /// same discipline `with_commit` uses below. A cosine similarity cannot be
    /// 3.0, so a number that says so is a bug in the caller, and recording it
    /// would hand a threshold something that is not a similarity at all.
    pub fn with_score(mut self, score: f32) -> Self {
        self.score = (score.is_finite() && (-1.0..=1.0).contains(&score)).then_some(score);
        self
    }

    /// ORDER 801-g9nn — stamp the frame this span was read in. A value that is
    /// not a plain object name is DROPPED rather than stored, so the field can
    /// never carry `unknown`, a ref name, or a command-line argument into the
    /// verifier.
    pub fn with_commit(mut self, commit: impl AsRef<str>) -> Self {
        let c = commit.as_ref();
        self.commit = gitref::looks_like_sha(c).then(|| c.to_string());
        self
    }

    /// The commit this span was extracted from, when one is known.
    pub fn commit(&self) -> Option<&str> {
        self.commit.as_deref()
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
                .or_else(|| self.authority.get("key").cloned())
                .ok_or_else(|| {
                    format!(
                        "{}:{}-{}: plan citation carries no authority.packet_id or authority.key, so nothing can be verified against its span",
                        self.path, self.line_start, self.line_end
                    )
                }),
            // METHODOLOGY KEYS ARE SYNTHESISED, NOT LITERAL, and requiring them
            // verbatim withheld three quarters of this corpus as FABRICATED.
            //
            // A methodology `authority.key` is a DOTTED PATH built by walking
            // the YAML tree — `philosophy.core_principle`, `distributed_work.
            // order_number_assignment`. No YAML file contains that string
            // anywhere: the document holds only the leaf, `core_principle:`,
            // indented under its parents. Every other kind's key IS literal in
            // its span — a spec carries its own trace annotation naming the
            // capability, cheatsheets a heading, code a symbol — which is why
            // this went unnoticed. (Do not write a literal example of that
            // annotation here: the ghost-trace gate reads it as a reference to
            // a spec that does not exist, which is how this comment first
            // turned the build red.)
            //
            // MEASURED 2026-08-23 over 50 in-corpus questions through the real
            // spec-retrieve -> spec-envelope path:
            //     methodology   4 passed, 12 WITHHELD   (75%)
            //     spec         11 passed,  0 withheld
            //     cheatsheet   17 passed,  0 withheld
            //     code          6 passed,  0 withheld
            // The methodology corpus is this project's declared source of truth
            // (CLAUDE.md), so the corpus most likely to be asked an
            // authoritative question was the one answering "unsupported" — and
            // a withheld answer is indistinguishable from a corpus that simply
            // does not know, which is how it stayed invisible.
            //
            // The leaf plus its colon is the strongest token that CAN appear.
            // It is weaker than a full-path match and deliberately so: combined
            // with the path and the line span it still proves the span is that
            // key's own block rather than a passing mention, and a check that
            // cannot ever pass proves nothing at all. The stronger fix is for
            // the indexer to record a literal key; until then this fails for
            // the right reason instead of always.
            CitationKind::Methodology => self
                .authority
                .get("key")
                .map(|k| {
                    // TWO PRODUCERS, TWO KEY SHAPES, and only one of them was
                    // ever checkable.
                    //
                    // methodology.rs:456 stores `hit.decl` — the literal YAML
                    // DECLARATION token, `rule:`, colon included, chosen
                    // deliberately (its comment: "span.contains(\"rule\") would
                    // be satisfied by almost any 10 lines of the corpus"). That
                    // shape is already correct and must be passed through
                    // untouched; appending a colon to it yields `rule::`, which
                    // matches nothing.
                    //
                    // spec.rs builds the SAME CitationKind from index chunks
                    // and stores the dotted YAML PATH instead —
                    // `philosophy.core_principle` — which appears in no file,
                    // because it is synthesised by walking the tree. Every
                    // methodology answer served through the RAG path therefore
                    // failed as FABRICATED.
                    if k.ends_with(':') {
                        k.clone()
                    } else {
                        format!("{}:", k.rsplit('.').next().unwrap_or(k))
                    }
                })
                .ok_or_else(|| {
                    format!(
                        "{}:{}-{}: methodology citation carries no authority.key, so its span cannot be checked",
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

    /// RAG freshness timestamp in local time: `"RAG(hh:mm:ss)"`.
    /// Returns `"RAG(unknown)"` when `indexed_at` is unparseable.
    pub fn rag_timestamp(&self) -> String {
        if self.indexed_at == "unknown" {
            return "RAG(unknown)".to_string();
        }
        // Parse ISO 8601 and convert to local time
        match chrono::DateTime::parse_from_rfc3339(&self.indexed_at) {
            Ok(dt) => {
                let local: chrono::DateTime<chrono::Local> = dt.with_timezone(&chrono::Local);
                format!("RAG({})", local.format("%H:%M:%S"))
            }
            Err(_) => "RAG(unknown)".to_string(),
        }
    }

    /// Staleness indicator: returns `true` if the corpus is older than the
    /// given threshold (in seconds). Default threshold: 3600 (1 hour).
    pub fn is_stale(&self, threshold_secs: i64) -> bool {
        if self.indexed_at == "unknown" {
            return true;
        }
        match chrono::DateTime::parse_from_rfc3339(&self.indexed_at) {
            Ok(dt) => {
                let now = chrono::Utc::now();
                let age = now.signed_duration_since(dt);
                age.num_seconds() > threshold_secs
            }
            Err(_) => true,
        }
    }

    /// RAG freshness with staleness: `"RAG(hh:mm:ss)"` or `"RAG(hh:mm:ss stale)"`.
    pub fn rag_timestamp_with_staleness(&self, threshold_secs: i64) -> String {
        let ts = self.rag_timestamp();
        if ts == "RAG(unknown)" {
            return ts;
        }
        if self.is_stale(threshold_secs) {
            // Replace closing paren with " stale)"
            format!("{} stale)", ts.trim_end_matches(')'))
        } else {
            ts
        }
    }
}

/// ORDER 801-g9nn — where the READER stands relative to the frame this answer
/// was computed in, and which of its citations do not survive the difference.
///
/// This is deliberately NOT a version number. Git is a DAG with a partial
/// order: two concurrent branches are genuinely unordered, and a `vNNNN` that
/// implied otherwise would be a confident lie in exactly the situation that
/// needs the truth. What is derivable is a RELATIONSHIP between two named
/// commits, and that is what this carries.
///
/// The `drifted` list is the operational payload. `relation` alone says the
/// frames differ; `drifted` says which citations' line numbers therefore do not
/// transfer — which is the difference between "be careful" and "do not open
/// line 45 in your tree, it is not the line 45 this answer read".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CallerRelation {
    /// The reader's HEAD, or the literal `unknown` when it could not be read.
    caller_head: String,
    /// The commit the answer was computed from, or `unknown`.
    answer_commit: String,
    relation: Relation,
    /// Cited paths whose bytes differ between `answer_commit` and what is on
    /// disk in the reader's checkout. Sorted, de-duplicated. NON-EMPTY MEANS THE
    /// LINE NUMBERS FOR THOSE PATHS ARE NOT VALID HERE.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    drifted: Vec<String>,
    /// Cited paths the reader's checkout does not contain at all. With a shared
    /// index this is the normal shape of a citation from the reader's FUTURE:
    /// the file exists at `answer_commit` and has never been fetched here.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    absent_here: Vec<String>,
}

impl CallerRelation {
    /// ORDER 801-g9nn — the EMITTER's version: ancestry only, both file lists
    /// deliberately empty.
    ///
    /// An expert answering in its own checkout can derive where the reader's
    /// HEAD sits in the DAG — that is a fact about two commits and needs no
    /// access to the reader. It emphatically CANNOT derive `drifted`, because
    /// drift is measured against the reader's WORKING TREE, which the emitter
    /// has never seen and which may carry uncommitted edits to the very files
    /// being cited. Filling those lists from the emitter's own tree would
    /// produce an empty, reassuring, and meaningless answer. The reader
    /// completes them with [`relate`]; until then the silence is honest.
    pub fn ancestry_only(view: &GitView, caller_head: &str, answer_commit: &str) -> Self {
        Self {
            relation: gitref::classify(view, Some(caller_head), Some(answer_commit)),
            caller_head: caller_head.to_string(),
            answer_commit: answer_commit.to_string(),
            drifted: Vec::new(),
            absent_here: Vec::new(),
        }
    }

    pub fn caller_head(&self) -> &str {
        &self.caller_head
    }
    pub fn answer_commit(&self) -> &str {
        &self.answer_commit
    }
    pub fn relation(&self) -> Relation {
        self.relation
    }
    pub fn drifted(&self) -> &[String] {
        &self.drifted
    }
    pub fn absent_here(&self) -> &[String] {
        &self.absent_here
    }

    /// Are this answer's citations safe to open at their stated line numbers in
    /// the reader's checkout? True only when the frames agree AND nothing moved.
    ///
    /// `unknown` is NOT trustworthy: an unverified frame is not a matching one,
    /// and the whole defect class this order closes is a reader treating
    /// "nobody checked" as "checked and fine".
    pub fn spans_transfer(&self) -> bool {
        self.relation == Relation::Same && self.drifted.is_empty() && self.absent_here.is_empty()
    }

    /// One pinned, machine-branchable line for a human or a log. The leading
    /// token is the relation, so `grep -c '^caller-relation: same'` is a test.
    pub fn render(&self) -> String {
        let mut s = format!(
            "caller-relation: {} (caller_head={}, answer_commit={})",
            self.relation.as_str(),
            short(&self.caller_head),
            short(&self.answer_commit)
        );
        if !self.drifted.is_empty() {
            s.push_str(&format!(
                "\n  DRIFTED — these line numbers are NOT valid in your checkout: {}",
                self.drifted.join(", ")
            ));
        }
        if !self.absent_here.is_empty() {
            s.push_str(&format!(
                "\n  ABSENT HERE — cited at {} but not present in your checkout; fetch: {}",
                short(&self.answer_commit),
                self.absent_here.join(", ")
            ));
        }
        s
    }
}

fn short(sha: &str) -> String {
    if gitref::looks_like_sha(sha) {
        sha.chars().take(12).collect()
    } else {
        sha.to_string()
    }
}

/// ORDER 801-g9nn — derive the reader's position from a checkout on disk.
///
/// `root` is the READER's checkout, which is emphatically not assumed to be the
/// one that produced the envelope. Every step fails soft: no git, no
/// repository, or an unfetched object yields [`Relation::Unknown`] or
/// [`Relation::Unfetched`] and an empty drift list, never a fabricated `same`.
///
/// DRIFT IS MEASURED AGAINST THE WORKING TREE, not against the reader's HEAD
/// commit, because the working tree is what the reader will actually open. An
/// uncommitted edit to a cited file moves its line numbers just as surely as a
/// merge does, and an answer that called that `same` would be wrong in the only
/// way that matters.
pub fn relate(envelope: &Envelope, root: &Path) -> CallerRelation {
    let view = GitView::new(root);
    let caller_head = view.head();
    let answer_commit = envelope_commit(envelope);
    let relation = classify_relation(&view, caller_head.as_deref(), answer_commit.as_deref());

    let mut drifted = BTreeSet::new();
    let mut absent_here = BTreeSet::new();
    for c in &envelope.citations {
        // A path that escapes the checkout is a separate, harder violation that
        // `verify` already reports; do not hand it to git.
        let rel = Path::new(&c.path);
        if c.path.is_empty()
            || rel.is_absolute()
            || rel
                .components()
                .any(|p| matches!(p, Component::ParentDir | Component::Prefix(_)))
        {
            continue;
        }
        let here = std::fs::read_to_string(root.join(rel)).ok();
        let frame = c.commit.as_deref().or(answer_commit.as_deref());
        let there = frame.and_then(|sha| view.file_at(sha, &c.path));
        match (here, there) {
            (None, Some(_)) => {
                absent_here.insert(c.path.clone());
            }
            (Some(h), Some(t)) if h != t => {
                drifted.insert(c.path.clone());
            }
            // (Some, None): the frame is unfetched or the path did not exist
            // there. Nothing is provable, so nothing is claimed — `relation`
            // already carries `unfetched` when that is why.
            // (None, None): unresolvable on both sides; `verify` owns it.
            _ => {}
        }
    }

    CallerRelation {
        caller_head: caller_head.unwrap_or_else(|| "unknown".to_string()),
        answer_commit: answer_commit.unwrap_or_else(|| "unknown".to_string()),
        relation,
        drifted: drifted.into_iter().collect(),
        absent_here: absent_here.into_iter().collect(),
    }
}

/// Split out so a test can drive the classification without a filesystem.
fn classify_relation(view: &GitView, head: Option<&str>, answer: Option<&str>) -> Relation {
    gitref::classify(view, head, answer)
}

/// The frame an envelope as a whole was computed in: `freshness.source_commit`
/// when it is a real object name, otherwise the first commit any citation
/// carries. Returns `None` rather than a placeholder when neither exists.
fn envelope_commit(envelope: &Envelope) -> Option<String> {
    let fresh = &envelope.freshness.source_commit;
    if gitref::looks_like_sha(fresh) {
        return Some(fresh.clone());
    }
    envelope
        .citations
        .iter()
        .find_map(|c| c.commit.clone())
        .filter(|c| gitref::looks_like_sha(c))
}

/// The answer envelope. FIELDS ARE PRIVATE ON PURPOSE — see the module doc.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    answer: String,
    citations: Vec<Citation>,
    freshness: Freshness,
    confidence: Confidence,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    citation_root: Option<String>,
    /// ORDER 796-4ydb — corpus files the fold COULD NOT READ, repo-relative.
    ///
    /// Non-empty means this answer is drawn from a partial corpus: the named
    /// fragments did not parse, so anything filed in them is missing from the
    /// ledger the answer was computed against. It is deliberately NOT folded
    /// into `confidence`. `confidence: exact` is a claim about the CITATION —
    /// the cited span exists and says what is quoted — and that claim stays
    /// true; the failure mode here is OMISSION, which needs its own word.
    /// Collapsing the two would either overstate the citation's weakness or,
    /// worse, let a caller conclude from `exact` that nothing was missed.
    ///
    /// ADDITIVE AND ABSENT WHEN CLEAN: a corpus that parsed whole serializes
    /// byte-identically to before this field existed, so no consumer pinning
    /// the envelope shape sees a change until there is something to report.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    skipped_sources: Vec<String>,
    /// ORDER 801-g9nn — where the READER stands relative to this answer's frame.
    ///
    /// STAMPED ONLY WHEN A READER IS KNOWN, and absent otherwise. The expert
    /// process answers from ITS checkout, which need not be the asking agent's:
    /// the MCP server serves a main checkout while a fork asks from a worktree
    /// several commits away. Defaulting this to `same` because the emitter
    /// happens to be self-consistent would manufacture exactly the false
    /// assurance the order exists to remove, so an unknown reader gets NO field
    /// rather than a reassuring one. The reader re-derives it for itself with
    /// `verify-answer`, which is where the claim becomes falsifiable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    caller_relation: Option<CallerRelation>,
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
            skipped_sources: Vec::new(),
            caller_relation: None,
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
            skipped_sources: Vec::new(),
            caller_relation: None,
        }
    }

    /// ORDER 796-4ydb — stamp the corpus files the fold could not read.
    ///
    /// Applied at EMISSION, after any downgrade to [`Envelope::unsupported`],
    /// because the incompleteness is a property of the corpus rather than of
    /// the answer: a refusal computed from a partial ledger is still a refusal
    /// computed from a partial ledger, and rebuilding the envelope must not
    /// drop that. Empty input is a no-op.
    pub fn with_skipped_sources(mut self, skipped: Vec<String>) -> Self {
        self.skipped_sources = skipped;
        self
    }

    /// The corpus files that did not parse and are therefore absent from this
    /// answer. Empty means the fold read the whole corpus.
    pub fn skipped_sources(&self) -> &[String] {
        &self.skipped_sources
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

    /// ORDER 801-g9nn — stamp every citation that has no frame of its own with
    /// the commit this answer was computed from.
    ///
    /// The DEFAULT is correct for the deterministic layer, where the engine
    /// reads the corpus out of the working tree at query time, so the frame IS
    /// the checkout's HEAD. It is NOT correct for a retrieved answer served from
    /// an index built elsewhere, which is why [`Citation::with_commit`] can
    /// override per citation and why this never overwrites an existing value:
    /// a shared warm index knows its own build commit and the process reading it
    /// does not.
    pub fn with_default_citation_commit(mut self, commit: &str) -> Self {
        if !gitref::looks_like_sha(commit) {
            return self;
        }
        for c in &mut self.citations {
            if c.commit.is_none() {
                c.commit = Some(commit.to_string());
            }
        }
        self
    }

    /// ORDER 801-g9nn — attach the reader's position. See the field doc for why
    /// this is never defaulted.
    pub fn with_caller_relation(mut self, relation: CallerRelation) -> Self {
        self.caller_relation = Some(relation);
        self
    }

    pub fn caller_relation(&self) -> Option<&CallerRelation> {
        self.caller_relation.as_ref()
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
///
/// PURE AND FRAME-BLIND ON PURPOSE. It reads only the working tree and spawns
/// nothing, so it stays usable where git is not — and so the EMITTER, which
/// answers from the very tree it just read, keeps its cheap self-check
/// unchanged. The frame-aware reader-side audit is [`audit`].
pub fn verify(envelope: &Envelope, root: &Path) -> Vec<String> {
    verify_inner(envelope, root, None, &mut Vec::new())
}

/// The shared body. `rescue` is `Some` only on the reader-side [`audit`] path;
/// with `None` every finding stays a violation and the behaviour is exactly
/// what it was before order 801-g9nn.
fn verify_inner(
    envelope: &Envelope,
    root: &Path,
    rescue: Option<&GitView>,
    stale: &mut Vec<String>,
) -> Vec<String> {
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
            let unreadable = format!(
                "{}: citation path does not resolve to a readable file ({})",
                c.path,
                full.display()
            );
            match rescue {
                // ORDER 801-g9nn — the load-bearing case. A citation into a file
                // this checkout does not have is INDISTINGUISHABLE from a
                // fabricated one until somebody checks the frame it was read in.
                // With the frame named and reachable, the span can be re-read at
                // its own commit: if it holds there, the citation is not a lie,
                // the reader is simply not standing where the answer was
                // computed. That is a fetch instruction, not a refusal.
                Some(view) if frame_holds(c, envelope, view) == Some(true) => {
                    stale.push(format!("{unreadable} — but the span VERIFIES at {}; you do not have this commit, fetch it", frame_label(c, envelope)));
                }
                _ => violations.push(unreadable),
            }
            continue;
        };
        let lines: Vec<&str> = text.lines().collect();
        if c.line_start == 0 || c.line_end < c.line_start {
            // Malformed in EVERY frame — an inverted range cites nothing
            // anywhere, so there is nothing for a commit to rescue.
            violations.push(format!(
                "{}:{}-{}: citation line range is empty or inverted",
                c.path, c.line_start, c.line_end
            ));
            continue;
        }
        if c.line_end > lines.len() {
            let past_eof = format!(
                "{}:{}-{}: citation line range runs past end of file ({} lines)",
                c.path,
                c.line_start,
                c.line_end,
                lines.len()
            );
            match rescue {
                Some(view) if frame_holds(c, envelope, view) == Some(true) => {
                    stale.push(format!(
                        "{past_eof} — but the span VERIFIES at {}; the file SHRANK under you",
                        frame_label(c, envelope)
                    ));
                }
                _ => violations.push(past_eof),
            }
            continue;
        }
        let span = lines[c.line_start - 1..c.line_end].join("\n");
        let mut span_findings = Vec::new();
        match c.span_key() {
            Err(e) => span_findings.push(e),
            Ok(key) => {
                if !span.contains(&key) {
                    span_findings.push(format!(
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
                if key == "packet_id" || key == "section" || key == "key" {
                    continue;
                }
                if !span_substantiates(&span, key, value) {
                    span_findings.push(format!(
                        "{}:{}-{}: cited span does not substantiate authority {}={} — TAMPERED or stale authority",
                        c.path, c.line_start, c.line_end, key, value
                    ));
                }
            }
        }
        if !span_findings.is_empty()
            && let Some(view) = rescue
            && frame_holds(c, envelope, view) == Some(true)
        {
            // Same rescue as above, for the subtler and more dangerous shape:
            // the path still exists here, the range is still in bounds, and the
            // lines say something ELSE. Read at face value that is a fabricated
            // citation; read against its frame it is a moved span, which is
            // precisely the "reads the wrong lines and acts on them with full
            // confidence" failure this order was filed for.
            let at = frame_label(c, envelope);
            stale.extend(span_findings.drain(..).map(|f| {
                format!(
                    "{} — but the span VERIFIES at {at}; THIS SPAN MOVED, your line numbers are stale",
                    without_verdict(&f)
                )
            }));
        }
        violations.append(&mut span_findings);

        // Frame-INDEPENDENT: whether the answer text mentions the claim has
        // nothing to do with which commit the reader is on, so it is never
        // rescued.
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

/// Drop the VERDICT a rescued finding no longer carries, keeping the fact it
/// reported. A stale finding that still ends in `FABRICATED citation` tells the
/// reader the opposite of what the line concludes, and a message that argues
/// with itself gets read as the scarier half.
fn without_verdict(finding: &str) -> &str {
    for tail in [" — FABRICATED citation", " — TAMPERED or stale authority"] {
        if let Some(head) = finding.strip_suffix(tail) {
            return head;
        }
    }
    finding
}

/// The frame a single citation was read in: its own `commit` when it has one,
/// otherwise the envelope's. Rendered for a message.
fn frame_label(c: &Citation, envelope: &Envelope) -> String {
    match c.commit.as_deref().or(envelope_commit(envelope).as_deref()) {
        Some(sha) => short(sha),
        None => "unknown".to_string(),
    }
}

/// ORDER 801-g9nn — does this citation hold AT ITS OWN COMMIT?
///
/// `Some(true)` means the span at that commit contains everything the citation
/// claims: the citation is sound and the READER is in a different frame.
/// `Some(false)` means it does not hold even there — a real fabrication, which
/// the frame excuse must not launder. `None` means the question could not be
/// asked (no commit named, object never fetched, path absent there), and an
/// unaskable question is never an acquittal.
fn frame_holds(c: &Citation, envelope: &Envelope, view: &GitView) -> Option<bool> {
    let frame = c.commit.clone().or_else(|| envelope_commit(envelope))?;
    let text = view.file_at(&frame, &c.path)?;
    let lines: Vec<&str> = text.lines().collect();
    if c.line_start == 0 || c.line_end < c.line_start || c.line_end > lines.len() {
        return Some(false);
    }
    let span = lines[c.line_start - 1..c.line_end].join("\n");
    let Ok(key) = c.span_key() else {
        return Some(false);
    };
    if !span.contains(&key) {
        return Some(false);
    }
    if c.kind == CitationKind::Plan {
        for (key, value) in &c.authority {
            if key == "packet_id" || key == "section" || key == "key" {
                continue;
            }
            if !span_substantiates(&span, key, value) {
                return Some(false);
            }
        }
    }
    Some(true)
}

/// ORDER 801-g9nn — the reader-side audit: [`verify`] plus the frame the
/// citations were read in.
///
/// `violations` keeps its meaning exactly — these citations are unsound and the
/// envelope must not be trusted. `stale` is the NEW bucket and the point of the
/// order: citations that are sound at their own commit and wrong here. Collapsing
/// the two in either direction loses information the reader needs. Calling a
/// stale citation FABRICATED slanders a correct answer and teaches agents to
/// ignore the verifier; calling a fabricated one stale hands a lie a fetch
/// instruction and a clean bill of health.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Audit {
    pub violations: Vec<String>,
    pub stale: Vec<String>,
    pub relation: CallerRelation,
}

impl Audit {
    /// Does this envelope's evidence hold for THIS reader, right here? Requires
    /// both buckets empty: a stale citation resolves to different bytes than the
    /// answer was built from, which is not a pass.
    pub fn trustworthy_here(&self) -> bool {
        self.violations.is_empty() && self.stale.is_empty()
    }
}

/// Audit an envelope against the READER's checkout, consulting the commit DAG.
///
/// This is what `verify-answer` runs. It differs from [`verify`] in exactly one
/// way: when a citation fails here, its own commit is asked whether it held
/// THERE, and a citation that did is reported as stale rather than fabricated.
/// Everything git cannot establish stays a violation — the frame is an
/// explanation, never an excuse.
pub fn audit(envelope: &Envelope, root: &Path) -> Audit {
    let view = GitView::new(root);
    let mut stale = Vec::new();
    let mut violations = verify_inner(envelope, root, Some(&view), &mut stale);
    let relation = relate(envelope, root);

    // The stamped relation is a CLAIM, so it gets checked like every other
    // claim in this envelope. It is only contradicted when this checkout can
    // independently derive the same comparison: a relation computed for a
    // different reader is not wrong just because we are not that reader, and an
    // object we have never fetched cannot refute anything.
    if let Some(stamped) = &envelope.caller_relation {
        let derived = gitref::classify(
            &view,
            Some(stamped.caller_head.as_str()),
            Some(stamped.answer_commit.as_str()),
        );
        if !matches!(derived, Relation::Unknown | Relation::Unfetched)
            && derived != stamped.relation
        {
            violations.push(format!(
                "caller_relation claims '{}' between {} and {}, but this checkout derives '{}' — FABRICATED relation",
                stamped.relation.as_str(),
                short(&stamped.caller_head),
                short(&stamped.answer_commit),
                derived.as_str()
            ));
        }
    }

    Audit {
        violations,
        stale,
        relation,
    }
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
    // ORDER 757-yi8c: "ready" must match as a TOKEN, not a substring.
    // `lower.contains("ready")` fired on "alREADY", so the duplicate-detection
    // question "is there already a packet about the forge image missing the
    // hostname executable?" — whose only other routing signal was the role
    // word "forge" — was answered with the entire ready-for-forge listing,
    // served as exact. A semantically unrelated exact answer is worse than an
    // honest unsupported (2026-08-15 failed-forge handoff, priority 4).
    let wants_ready = lower_tokens.iter().any(|t| t == "ready")
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
        // ORDER 706-f7mq. Fallback to modular semantic explanation over plan documents
        let root = ledger
            .source_path()
            .and_then(|p| p.parent())
            .and_then(|p| p.parent())
            .unwrap_or_else(|| Path::new("."));
        let provider = crate::semantic_expert::PlanSectionProvider::new(root);
        let explainer = crate::semantic_expert::SemanticExplainer::default();
        if let Some(env) = explainer.explain_query(&provider, question, &freshness) {
            return env;
        }

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

    // The `provenance` column is how a caller tells HISTORY from live work.
    //
    // Added as a SIXTH COLUMN rather than folded into `status`, and always
    // emitted rather than only when something archived shows up. Both choices
    // are about not lying to a parser: a consumer indexing fields 0..4 reads
    // exactly what it read before, and a column that appears only sometimes
    // would make `live` unstated — leaving "no marker" to mean both "live" and
    // "this build predates the marker". An archived row rendered as if it were
    // live is a worse answer than the refusal this whole change replaces,
    // because it sends an agent to work that is already finished.
    let mut body =
        String::from("order\tstatus\tdesired_release\trelease_target\tpacket_id\tprovenance\n");
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
        let provenance = if ledger.is_archived(&id) {
            "archived"
        } else {
            "live"
        };
        body.push_str(&format!(
            "{order}\t{status}\t{desired_release}\t{release_target}\t{id}\t{provenance}\n"
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
        })
        // ARCHIVED work cites the archive file it actually lives in. Third and
        // last, so nothing about a live packet's citation changes: an archived
        // packet has no base span and no fragment origin, which is precisely
        // why every one of these rows used to be dropped as uncitable and the
        // answer downgraded to `unsupported`. The path is openable and the
        // span verifies against it under the same order-523 self-check as any
        // other citation — history is cited, never asserted.
        .or_else(|| {
            ledger
                .archived_span_of(id)
                .map(|(file, start, end)| (archive_rel(source_rel, file), start, end))
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

/// The EFFECTIVE `next_action`: the newest of the packet field and any event
/// carrying one.
///
/// ORDER 864-r9wt FIXED THIS FOR THE `next-action` SUBCOMMAND AND MISSED THIS
/// CALLER — found by the 2026-08-24 fleet retrospective, and this caller is the
/// higher-traffic one. `packets:` is a G-Set, so cycles update `next_action`
/// by APPENDING EVENTS; the packet-level field keeps whatever the row was born
/// with. `plan_next` is the selector — the primary work-pull surface every
/// host reads — and its per-row "next:" snippet was serving that original
/// value, arbitrarily stale, while the live queue sat in events beneath it.
/// The coordinator itself acted on a twenty-hour-stale queue this way before
/// the subcommand existed; every OTHER host kept getting the stale text after.
///
/// The packet field is untimestamped and therefore the OLDEST candidate — it
/// never wins a tie, being the one value guaranteed never to have been updated.
pub fn effective_next_action(p: &serde_yaml::Value) -> Option<(String, Option<String>)> {
    let mut best: Option<String> = crate::str_field(p, "next_action").map(str::to_string);
    // ORDER 877-lwts: when the field arrived through the set-field LWW
    // channel, the fold records its timestamp as `next_action_ts`, and the
    // field competes on equal clock terms with the event channel. A packet
    // whose field is the hand-authored original still has no ts and yields to
    // any event, as before.
    let mut best_ts = if best.is_some() {
        crate::str_field(p, "next_action_ts")
            .unwrap_or("")
            .to_string()
    } else {
        String::new()
    };
    if let Some(evs) = p.get("events").and_then(serde_yaml::Value::as_sequence) {
        for e in evs {
            let Some(na) = e.get("next_action").and_then(serde_yaml::Value::as_str) else {
                continue;
            };
            // ISO-8601 UTC sorts lexicographically; the ledger writes it so.
            let ts = e
                .get("ts")
                .and_then(serde_yaml::Value::as_str)
                .unwrap_or("");
            if best.is_none() || ts > best_ts.as_str() {
                best_ts = ts.to_string();
                best = Some(na.to_string());
            }
        }
    }
    best.map(|v| {
        (
            v,
            if best_ts.is_empty() {
                None
            } else {
                Some(best_ts)
            },
        )
    })
}

/// One-line, bounded rendering of the packet's own next step.
fn next_action_snippet(p: &serde_yaml::Value) -> String {
    let effective = effective_next_action(p).map(|(v, _)| v);
    let raw = effective
        .as_deref()
        .or_else(|| crate::str_field(p, "handoff_note"))
        .or_else(|| crate::str_field(p, "outcome"))
        .or_else(|| crate::str_field(p, "title"))
        .unwrap_or("see packet");
    let one_line = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate(&one_line, NEXT_ACTION_SNIPPET_CHARS)
}

/// Which rows count as OWNING the paths in their `owned_files`. The two scopes
/// are genuinely different questions and both are load-bearing, so naming them
/// is cheaper than two folds that drift.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OwnershipScope {
    /// Rows under an ACTIVE claim: a live `lease`, or `status: in_progress` /
    /// `claimed`. What [`answer_next`] must exclude — handing two agents the
    /// same file scope is a merge conflict the selector could have prevented.
    ActiveClaims,
    /// Every OPEN row: any packet whose status is not terminal
    /// ([`crate::is_terminal_status`]). Strictly wider than `ActiveClaims`,
    /// and it is the scope the ARRIVAL rule is written over —
    /// `methodology/distributed-work.yaml` →
    /// `new_row_only_if_independently_schedulable` reads "it names owned_files
    /// no OPEN row already owns", not "no claimed row".
    OpenRows,
}

/// The `owned_files` ownership index over `scope`: file path → the packet_ids
/// that declare it. Sorted throughout, so two hosts render identical results
/// from identical ledgers.
///
/// ONE COMPUTATION, TWO READERS, on purpose. [`answer_next`] built this fold
/// inline and consumed only the KEY SET; the arrival-routing check (order
/// 831-ezea, `scripts/check-arrival-routing.sh`) needs the same fold plus the
/// owner names, and re-deriving "who owns this file" beside the selector is
/// exactly how an invariant with two implementations acquires two answers.
/// 831-ezea's own design note claims a second copy already exists at
/// `main.rs:3195`; it does not — that line is the `check` arm — so this is the
/// first and, deliberately, the only fold of `owned_files` in the crate.
pub fn owned_file_owners(
    ledger: &Ledger,
    scope: OwnershipScope,
) -> BTreeMap<String, BTreeSet<String>> {
    let mut index: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for p in &ledger.packets {
        let selected = match scope {
            OwnershipScope::ActiveClaims => {
                let leased = p.get("lease").is_some_and(|v| !v.is_null());
                let in_flight = matches!(
                    crate::str_field(p, "status"),
                    Some("in_progress" | "claimed")
                );
                leased || in_flight
            }
            // A packet with NO status counts as open. `status` is a
            // required_field, so this is a malformed row rather than a
            // terminal one, and treating an unreadable row as closed would
            // silently shrink the set the arrival rule is measured against.
            OwnershipScope::OpenRows => {
                !crate::str_field(p, "status").is_some_and(crate::is_terminal_status)
            }
        };
        if !selected {
            continue;
        }
        let id = ledger.id_of(p);
        for f in crate::str_list(p, "owned_files") {
            index.entry(f).or_default().insert(id.clone());
        }
    }
    index
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
    // in-flight packet. The fold lives in [`owned_file_owners`] — this call
    // site wants only the key set, the arrival-routing check wants the owners
    // too, and one fold serves both.
    let claimed_files: BTreeSet<String> = owned_file_owners(ledger, OwnershipScope::ActiveClaims)
        .into_keys()
        .collect();

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
                && p.get("lease").is_none_or(|v| v.is_null())
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
    // ORDER 801-g9nn — START AT `source` WHEN IT IS ALREADY A DIRECTORY.
    //
    // Unconditionally taking `.parent()` silently skips the repository whose
    // root was handed in. `spec::build_envelope` passes the checkout root, so
    // the spec expert's `freshness.source_commit` was resolved from one
    // directory ABOVE the checkout: `unknown` in the ordinary case, and — found
    // here on 2026-08-18 — the WRONG repository's HEAD when the checkout is a
    // linked worktree nested inside its main one, which is how a fork agent
    // runs. An answer stamped with a commit from a different repository is the
    // very defect this order exists to remove, one level further out.
    let mut dir = if source.is_dir() {
        source
    } else {
        source.parent()?
    };
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

/// The repo-relative path of an archive file, derived from the index's own
/// repo-relative path exactly as [`fragment_rel`] below derives a fragment's:
/// `plan/index.yaml` + `packets-2026-07.yaml` -> `plan/archive/packets-2026-07.yaml`.
///
/// Derived rather than stored because the ledger holds absolute paths and a
/// citation must be repo-relative — the same reason `fragment_rel` exists.
fn archive_rel(source_rel: &str, archive_file: &str) -> String {
    match source_rel.rsplit_once('/') {
        Some((dir, _)) => format!("{dir}/archive/{archive_file}"),
        None => format!("archive/{archive_file}"),
    }
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

/// `YYYY-MM-DDTHH:MM:SSZ` -> Unix seconds. The inverse of
/// [`epoch_to_iso8601`], added for order 719-kgr5: a `--ts` the tooling accepts
/// on trust cannot be compared against the host clock, and eleven consecutive
/// windows cycles wrote invented timestamps that drifted up to 8.6 hours ahead
/// of their own commits before anything noticed.
///
/// Deliberately strict about SHAPE. It accepts only the exact form this ledger
/// writes; a lenient parser here would let a subtly different string through
/// and reintroduce the ordering corruption by another door. Returns None on
/// anything it does not fully understand, and the callers refuse rather than
/// guess.
pub fn iso8601_to_epoch(iso: &str) -> Option<i64> {
    let b = iso.as_bytes();
    if b.len() != 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
        || b[19] != b'Z'
    {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> { iso.get(from..to)?.parse::<i64>().ok() };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || s > 60 {
        return None;
    }
    Some(days_from_civil(y, mo as u32, d as u32) * 86_400 + h * 3600 + mi * 60 + s)
}

/// Hinnant's days-from-civil, the exact inverse of [`civil_from_days`].
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 }.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 } as i64;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
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

    /// 864-r9wt's second half, found by the 2026-08-24 retrospective: the
    /// `next-action` subcommand learned to take the newest EVENT, but
    /// `plan_next`'s per-row snippet — the selector, the surface every host
    /// reads — kept serving the packet FIELD, which is the value guaranteed
    /// never to have been updated. Pin the snippet to the effective value.
    #[test]
    fn next_snippet_prefers_the_newest_event_over_the_stale_field() {
        let p: serde_yaml::Value = serde_yaml::from_str(
            r#"
packet_id: q
next_action: "STALE original queue from birth"
events:
  - type: progress
    ts: "2026-08-01T00:00:00Z"
    next_action: "older event"
  - type: progress
    ts: "2026-08-24T00:00:00Z"
    next_action: "the live queue"
  - type: note
    ts: "2026-08-25T00:00:00Z"
"#,
        )
        .expect("packet parses");
        assert_eq!(
            effective_next_action(&p).map(|(v, _)| v).as_deref(),
            Some("the live queue")
        );
        assert!(
            next_action_snippet(&p).contains("the live queue"),
            "the selector snippet must carry the effective value"
        );
        assert!(
            !next_action_snippet(&p).contains("STALE"),
            "the birth value must not survive an event update"
        );

        // No events carrying next_action -> the field is genuinely current.
        let bare: serde_yaml::Value =
            serde_yaml::from_str("packet_id: r\nnext_action: only value\n").unwrap();
        assert_eq!(
            effective_next_action(&bare).map(|(v, _)| v).as_deref(),
            Some("only value")
        );
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

    /// ORDER 757-yi8c. "alREADY" must not trigger the ready listing: a
    /// duplicate-detection question whose only other signal is a role word
    /// ("forge") was answered with the entire ready-for-forge listing served
    /// as exact. The classifier must not read Ready intent out of it; the
    /// token form still must.
    #[test]
    fn already_is_not_a_ready_intent_but_the_ready_token_still_is() {
        let ledger = live_ledger();
        let misroute = classify(
            &ledger,
            "is there already a packet about the forge image missing the hostname executable?",
        );
        assert!(
            !matches!(
                misroute,
                Some(Intent::Ready { .. }) | Some(Intent::Next { .. })
            ),
            "'already' + a role word must not route to the ready/next listing, got {misroute:?}"
        );
        let token = classify(&ledger, "ready packets for forge");
        assert!(
            matches!(token, Some(Intent::Ready { .. })),
            "the literal 'ready' token must keep routing to the ready listing, got {token:?}"
        );
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

        // (e) a citation for a packet the answer never mentions.
        //
        // Cited against "plan/index.yaml" and NOT against `good.path()`,
        // because `span_of` reads the ledger's own source file and pairing its
        // line numbers with some other file's path describes no citation at
        // all. The two were the same file until `status of 394a` could answer
        // from the archive; after an archival sweep `good.path()` is
        // plan/archive/*.yaml, the index-derived range lands past that file's
        // end, and verify short-circuits on "past end of file" — so this case
        // stopped exercising the decorative check it exists for and started
        // re-testing case (b). Naming the span's real file restores it: the
        // citation is now well-formed, in-bounds, and genuinely does contain
        // the packet it claims. The only thing wrong with it is that the
        // answer never mentions that packet, which is the point.
        auth.insert("packet_id".into(), "plan-yaml-compiled-editor".into());
        let span = ledger
            .span_of("plan-yaml-compiled-editor")
            .expect("a real packet has a span");
        let decorative = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                "plan/index.yaml".into(),
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

    /// ORDER 831-ezea. The two ownership scopes are DIFFERENT SETS and the
    /// difference is load-bearing: the selector excludes ACTIVE CLAIMS, the
    /// arrival rule reads every OPEN row. A regression that collapsed
    /// `OpenRows` onto `ActiveClaims` would leave
    /// `scripts/check-arrival-routing.sh` reporting green over an almost-empty
    /// set on any ledger where nothing happens to be in flight — the exact
    /// green-over-nothing failure 831-ezea was filed against.
    #[test]
    fn owned_file_owners_separates_active_claims_from_open_rows() {
        let raw = concat!(
            "steps:\n",
            "  - packet_id: claimed-row\n    order: 990\n    status: in_progress\n",
            "    owned_files: [flake.nix]\n",
            "  - packet_id: open-row\n    order: 991\n    status: ready\n",
            "    owned_files: [flake.nix, build.sh]\n",
            "  - packet_id: closed-row\n    order: 992\n    status: completed\n",
            "    owned_files: [build.sh]\n",
        );
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("parses");

        let active = owned_file_owners(&ledger, OwnershipScope::ActiveClaims);
        assert_eq!(
            active.keys().map(String::as_str).collect::<Vec<_>>(),
            ["flake.nix"]
        );
        assert_eq!(
            active["flake.nix"]
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["claimed-row"]
        );

        let open = owned_file_owners(&ledger, OwnershipScope::OpenRows);
        // A TERMINAL row is not an owner: `closed-row` also names build.sh and
        // must not appear, or the rule would route new work away from files
        // nobody is holding.
        assert_eq!(
            open["build.sh"]
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["open-row"]
        );
        // flake.nix is CONTENDED across the claimed row and the merely-open
        // one. Only the wider scope sees the second owner, which is the whole
        // reason the arrival check does not reuse the narrow one.
        assert_eq!(
            open["flake.nix"]
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["claimed-row", "open-row"]
        );
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

    /// Order 719-kgr5. The skew guard is only as good as this parser: a value
    /// it silently misreads becomes a skew it silently mis-measures.
    #[test]
    fn iso8601_parsing_round_trips_and_refuses_what_it_does_not_understand() {
        for secs in [
            0_i64,
            1_000_000_000,
            1_709_164_800,
            1_753_660_800,
            1_786_000_000,
        ] {
            let iso = epoch_to_iso8601(secs);
            assert_eq!(iso8601_to_epoch(&iso), Some(secs), "round trip for {iso}");
        }

        // The real values from the drift report, so the guard is anchored to
        // the measurement that produced it: a claimed 22:05:00Z against a
        // commit at 13:28:29Z is 8h36m31s, not a rounding difference.
        let claimed = iso8601_to_epoch("2026-08-13T22:05:00Z").expect("claimed parses");
        let actual = iso8601_to_epoch("2026-08-13T13:28:29Z").expect("actual parses");
        assert_eq!(claimed - actual, 8 * 3600 + 36 * 60 + 31);

        // NEGATIVE CONTROL: shapes the ledger never writes are refused rather
        // than half-read. A lenient parser here would reintroduce the ordering
        // corruption through a door the guard does not watch.
        for bad in [
            "",
            "2026-08-13",
            "2026-08-13T22:05:00",       // no zone
            "2026-08-13T22:05:00+00:00", // right instant, wrong shape
            "2026-08-13t22:05:00z",      // the compact-name casing
            "2026-13-01T00:00:00Z",      // month 13
            "2026-08-13T24:05:00Z",      // hour 24
            "not-a-timestamp-at-all",
        ] {
            assert_eq!(iso8601_to_epoch(bad), None, "must refuse {bad:?}");
        }
    }

    // ---- ORDER 796-4ydb: the envelope reports a partial corpus -----------

    #[test]
    fn a_whole_corpus_serializes_the_envelope_exactly_as_before() {
        // The additive half. `skipped_sources` must be ABSENT — not `[]` —
        // when there is nothing to report, so the field costs nothing to every
        // consumer pinning this shape until the day it matters.
        let e = Envelope::unsupported("nothing", fresh());
        let json = serde_json::to_string(&e).expect("serializes");
        assert!(
            !json.contains("skipped_sources"),
            "clean corpus must not mention it: {json}"
        );
    }

    #[test]
    fn a_partial_corpus_names_what_the_fold_could_not_read() {
        let e = Envelope::unsupported("nothing", fresh())
            .with_skipped_sources(vec!["plan/index.d/broken.yaml".to_string()]);
        assert_eq!(
            e.skipped_sources(),
            &["plan/index.d/broken.yaml".to_string()]
        );
        let json = serde_json::to_string(&e).expect("serializes");
        assert!(
            json.contains("\"skipped_sources\":[\"plan/index.d/broken.yaml\"]"),
            "a caller must be able to read this without parsing prose: {json}"
        );
    }

    #[test]
    fn incompleteness_is_reported_beside_confidence_not_folded_into_it() {
        // A DELIBERATE SEPARATION, worth pinning because collapsing it looks
        // tidier. `confidence: exact` is a claim about the CITATION -- the
        // cited span exists and says what is quoted -- and a skipped fragment
        // does not falsify it. The failure mode is OMISSION, which needs its
        // own word: downgrading to `unsupported` would withhold a correct
        // answer, and leaving `exact` alone with no other field would let a
        // caller conclude nothing was missed.
        let e = Envelope::supported(
            "alpha is ready",
            vec![Citation::new(
                "plan/index.yaml".to_string(),
                1,
                2,
                CitationKind::Plan,
                BTreeMap::new(),
            )],
            Confidence::Exact,
            fresh(),
        )
        .with_skipped_sources(vec!["plan/index.d/broken.yaml".to_string()]);
        assert_eq!(e.confidence(), Confidence::Exact);
        assert_eq!(e.skipped_sources().len(), 1);
    }

    // ── ORDER 801-g9nn — the frame a citation was read in ────────────────────
    //
    // Every test below runs against a REAL repository with REAL commits. The
    // whole subject is what git says about two commits, so a mock would only
    // confirm that the test and the implementation share an assumption.

    use crate::gitref::testrepo::{Repo, repo};

    const KEY: &str = "Egress allowlist";

    /// An envelope as it arrives at `verify-answer`: deserialized from JSON,
    /// having crossed a tool boundary and lost every type-level guarantee.
    /// Built this way on purpose — a hand-constructed `Envelope` could not carry
    /// the fabricated `caller_relation` the tamper tests need.
    fn envelope_json(
        answer_text: &str,
        path: &str,
        line_start: usize,
        line_end: usize,
        key: &str,
        commit: &str,
        caller_relation: Option<serde_json::Value>,
    ) -> Envelope {
        let mut v = serde_json::json!({
            "answer": answer_text,
            "citations": [{
                "path": path,
                "line_start": line_start,
                "line_end": line_end,
                "kind": "spec",
                "authority": { "key": key },
                "commit": commit,
            }],
            "freshness": { "source_commit": commit, "indexed_at": "2026-08-18T00:00:00Z" },
            "confidence": "retrieved",
        });
        if let Some(cr) = caller_relation {
            v["caller_relation"] = cr;
        }
        serde_json::from_value(v).expect("envelope deserializes")
    }

    /// `a` has no `spec.md`; `b` adds it with the key on line 2.
    fn repo_where_the_file_arrives_later(tag: &str) -> (Repo, String, String) {
        let r = repo(tag);
        r.write("README.md", "seed\n");
        let a = r.commit("a");
        r.write(
            "openspec/specs/x/spec.md",
            &format!("intro\n## {KEY}\nbody\n"),
        );
        let b = r.commit("b");
        (r, a, b)
    }

    /// THE CASE THE ORDER WAS FILED FOR, end to end.
    ///
    /// A shared, mirror-backed index lets the expert answer from a commit the
    /// asking agent has never checked out. The cited file is simply not there.
    /// Served bare that is a line number into nothing, and — critically — it is
    /// byte-for-byte the same symptom as a fabricated path. With the frame
    /// named, the two separate: this one is SOUND, the reader is just not
    /// standing where the answer was computed.
    #[test]
    fn a_citation_in_the_callers_future_is_stale_with_a_fetch_instruction_not_a_fabrication() {
        let (r, a, b) = repo_where_the_file_arrives_later("future");
        r.checkout(&a); // the reader is at `a` and has never seen the file

        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            None,
        );

        // The frame-blind verifier can only call this unresolvable. That is the
        // old behaviour and it is preserved exactly.
        let blind = verify(&env, r.path());
        assert_eq!(
            blind.len(),
            1,
            "frame-blind verify still refuses: {blind:?}"
        );
        assert!(blind[0].contains("does not resolve"), "{blind:?}");

        // The frame-aware audit tells the reader what to DO.
        let verdict = audit(&env, r.path());
        assert!(
            verdict.violations.is_empty(),
            "a sound citation from the future must not be reported as a violation: {:?}",
            verdict.violations
        );
        assert_eq!(verdict.stale.len(), 1, "{:?}", verdict.stale);
        assert!(
            verdict.stale[0].contains("fetch"),
            "the stale finding must say what to do: {}",
            verdict.stale[0]
        );
        assert!(!verdict.trustworthy_here());
        assert_eq!(verdict.relation.relation(), Relation::Behind);
        assert_eq!(verdict.relation.absent_here(), ["openspec/specs/x/spec.md"]);
        assert!(!verdict.relation.spans_transfer());
        assert!(
            verdict
                .relation
                .render()
                .starts_with("caller-relation: behind")
        );
    }

    /// The subtler and more dangerous shape: the file is still here, the range
    /// is still in bounds, and the lines say something ELSE. Since 803-su4n put
    /// CODE in the corpus, this is the one that becomes a wrong edit.
    #[test]
    fn a_span_that_moved_under_the_reader_is_stale_and_names_the_drifted_path() {
        let r = repo("moved");
        r.write("openspec/specs/x/spec.md", &format!("## {KEY}\ndeny\n"));
        let a = r.commit("a");
        // Ten lines land above it; the span at 1-2 now says something else.
        r.write(
            "openspec/specs/x/spec.md",
            &format!("{}## {KEY}\ndeny\n", "preamble\n".repeat(10)),
        );
        let b = r.commit("b");
        assert_ne!(a, b);

        let env = envelope_json(
            &format!("The {KEY} section denies by default."),
            "openspec/specs/x/spec.md",
            1,
            2,
            KEY,
            &a, // read at `a`, where 1-2 IS the section
            None,
        );

        let verdict = audit(&env, r.path()); // reader is at `b`
        assert!(
            verdict.violations.is_empty(),
            "a moved span is not a fabrication: {:?}",
            verdict.violations
        );
        assert_eq!(verdict.stale.len(), 1, "{:?}", verdict.stale);
        assert!(
            verdict.stale[0].contains("THIS SPAN MOVED"),
            "{}",
            verdict.stale[0]
        );
        assert_eq!(verdict.relation.relation(), Relation::Ahead);
        assert_eq!(verdict.relation.drifted(), ["openspec/specs/x/spec.md"]);
    }

    /// THE NEGATIVE CONTROL, and the reason the rescue is written as a question
    /// to git rather than a trust of the envelope.
    ///
    /// A citation that holds NOWHERE — not here, not at the commit it names —
    /// must stay a violation. If naming a commit were enough to be excused, the
    /// field would be a laundering mechanism: every fabricated citation would
    /// arrive with a sha attached and a clean bill of health.
    #[test]
    fn a_fabricated_span_is_not_laundered_by_naming_a_commit() {
        let r = repo("fabricated");
        r.write("openspec/specs/x/spec.md", &format!("## {KEY}\ndeny\n"));
        let a = r.commit("a");
        r.write(
            "openspec/specs/x/spec.md",
            &format!("{}## {KEY}\ndeny\n", "preamble\n".repeat(10)),
        );
        let b = r.commit("b");

        // Claims a section that appears at NEITHER commit.
        let env = envelope_json(
            "The Ingress allowlist section permits everything.",
            "openspec/specs/x/spec.md",
            1,
            2,
            "Ingress allowlist",
            &a,
            None,
        );
        let verdict = audit(&env, r.path());
        assert_eq!(
            verdict.stale.len(),
            0,
            "a span that holds nowhere must not be excused as stale: {:?}",
            verdict.stale
        );
        assert!(
            verdict.violations.iter().any(|v| v.contains("FABRICATED")),
            "{:?}",
            verdict.violations
        );

        // Same shape, but the commit is one this checkout has never fetched:
        // an unanswerable question is not an acquittal either.
        let elsewhere = repo("fabricated-elsewhere");
        elsewhere.write("f", "z\n");
        let never_fetched = elsewhere.commit("z");
        let env2 = envelope_json(
            "The Ingress allowlist section permits everything.",
            "openspec/specs/x/spec.md",
            1,
            2,
            "Ingress allowlist",
            &never_fetched,
            None,
        );
        let verdict2 = audit(&env2, r.path());
        assert_eq!(verdict2.stale.len(), 0, "{:?}", verdict2.stale);
        assert!(
            verdict2.violations.iter().any(|v| v.contains("FABRICATED")),
            "{:?}",
            verdict2.violations
        );
        assert_eq!(verdict2.relation.relation(), Relation::Unfetched);
        assert_eq!(b, r.git(&["rev-parse", "HEAD"]));
    }

    /// The other way a citation can hold nowhere: a range that runs off the end
    /// of the file AT THE COMMIT IT NAMES.
    ///
    /// Found by a mutation that the first draft of the laundering control
    /// survived. That control cites lines 1-2 of a two-line file, so the
    /// out-of-range branch inside the rescue was never reached and could be
    /// flipped to `Some(true)` — "any span git cannot slice is fine" — with every
    /// test still green. A rescue is only as strong as its narrowest untested
    /// path.
    #[test]
    fn a_range_past_the_end_of_the_file_at_its_own_commit_is_not_rescued() {
        let r = repo("past-eof-at-frame");
        r.write("openspec/specs/x/spec.md", &format!("## {KEY}\ndeny\n"));
        let a = r.commit("a");
        r.write(
            "openspec/specs/x/spec.md",
            &format!("{}## {KEY}\ndeny\n", "filler\n".repeat(10)),
        );
        r.commit("b");

        // 50-60 exists at NEITHER commit; the file is 2 lines at `a` and 12 at `b`.
        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            50,
            60,
            KEY,
            &a,
            None,
        );
        let verdict = audit(&env, r.path());
        assert_eq!(
            verdict.stale.len(),
            0,
            "a range that exists at no commit must not be excused as a moved span: {:?}",
            verdict.stale
        );
        assert!(
            verdict
                .violations
                .iter()
                .any(|v| v.contains("runs past end of file")),
            "{:?}",
            verdict.violations
        );
    }

    /// A file that genuinely SHRANK under the reader is the rescuable twin of
    /// the test above, and pairing them is what keeps the past-EOF branch from
    /// collapsing to a single answer in either direction.
    #[test]
    fn a_file_that_shrank_under_the_reader_is_stale_not_a_violation() {
        let r = repo("shrank");
        r.write(
            "openspec/specs/x/spec.md",
            &format!("{}## {KEY}\ndeny\n", "filler\n".repeat(10)),
        );
        let a = r.commit("a");
        r.write("openspec/specs/x/spec.md", "tiny\n");
        r.commit("b");

        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            11,
            12,
            KEY,
            &a,
            None,
        );
        let verdict = audit(&env, r.path());
        assert!(verdict.violations.is_empty(), "{:?}", verdict.violations);
        assert_eq!(verdict.stale.len(), 1, "{:?}", verdict.stale);
        assert!(verdict.stale[0].contains("SHRANK"), "{}", verdict.stale[0]);
    }

    /// A stamped relation is a CLAIM and gets checked like every other claim.
    #[test]
    fn a_stamped_caller_relation_that_the_dag_contradicts_is_a_violation() {
        let (r, a, b) = repo_where_the_file_arrives_later("tampered-relation");
        r.checkout(&b);

        let honest = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            Some(serde_json::json!({
                "caller_head": a, "answer_commit": b, "relation": "behind"
            })),
        );
        let clean = audit(&honest, r.path());
        assert!(clean.violations.is_empty(), "{:?}", clean.violations);

        let lying = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            Some(serde_json::json!({
                "caller_head": a, "answer_commit": b, "relation": "same"
            })),
        );
        let caught = audit(&lying, r.path());
        assert!(
            caught
                .violations
                .iter()
                .any(|v| v.contains("FABRICATED relation")),
            "{:?}",
            caught.violations
        );
    }

    /// A relation this checkout cannot independently derive is NOT contradicted.
    /// An envelope answered for someone else, carrying commits we have never
    /// fetched, is not wrong just because we cannot check it — and silently
    /// refusing it would make the field unusable across harnesses, which is the
    /// only place it matters.
    #[test]
    fn an_underivable_stamped_relation_is_left_alone_rather_than_refused() {
        let (r, _a, b) = repo_where_the_file_arrives_later("foreign-relation");
        let elsewhere = repo("foreign-other");
        elsewhere.write("f", "z\n");
        let foreign = elsewhere.commit("z");

        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            Some(serde_json::json!({
                "caller_head": foreign, "answer_commit": b, "relation": "diverged"
            })),
        );
        let verdict = audit(&env, r.path());
        assert!(
            verdict.violations.is_empty(),
            "an unfetched caller_head cannot refute anything: {:?}",
            verdict.violations
        );
    }

    /// `same` is the only clean bill of health, and it has to be REACHABLE —
    /// otherwise the field would be a permanent warning nobody reads.
    #[test]
    fn a_reader_standing_on_the_answers_commit_is_same_and_spans_transfer() {
        let (r, _a, b) = repo_where_the_file_arrives_later("same");
        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            None,
        );
        let verdict = audit(&env, r.path());
        assert!(verdict.trustworthy_here(), "{verdict:?}");
        assert_eq!(verdict.relation.relation(), Relation::Same);
        assert!(verdict.relation.spans_transfer());
        assert!(verdict.relation.drifted().is_empty());
    }

    /// Drift is measured against the WORKING TREE, not the reader's HEAD commit.
    /// An uncommitted edit moves line numbers exactly as a merge does, and an
    /// answer that called that `same` would be wrong in the only way that
    /// matters — the reader is about to open the file, not the commit.
    #[test]
    fn an_uncommitted_edit_drifts_even_when_the_commits_agree() {
        let (r, _a, b) = repo_where_the_file_arrives_later("dirty");
        let env = envelope_json(
            &format!("The {KEY} section says to deny by default."),
            "openspec/specs/x/spec.md",
            1,
            3,
            KEY,
            &b,
            None,
        );
        assert!(audit(&env, r.path()).relation.spans_transfer());

        r.write(
            "openspec/specs/x/spec.md",
            &format!("{}## {KEY}\nbody\n", "inserted\n".repeat(4)),
        );
        let dirty = audit(&env, r.path());
        assert_eq!(
            dirty.relation.relation(),
            Relation::Same,
            "the commits still agree"
        );
        assert_eq!(
            dirty.relation.drifted(),
            ["openspec/specs/x/spec.md"],
            "but the bytes on disk do not"
        );
        assert!(
            !dirty.relation.spans_transfer(),
            "'same' plus drift must not read as safe"
        );
    }

    /// The default stamp fills only what has no frame, so an index that knows
    /// its own build commit is never overwritten by the reading process's HEAD.
    #[test]
    fn the_default_citation_commit_never_overwrites_a_retrieved_frame() {
        let index_commit = "1111111111111111111111111111111111111111";
        let process_head = "2222222222222222222222222222222222222222";
        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), KEY.to_string());
        let stamped = Citation::new(
            "a.md".to_string(),
            1,
            2,
            CitationKind::Spec,
            authority.clone(),
        )
        .with_commit(index_commit);
        let bare = Citation::new("b.md".to_string(), 1, 2, CitationKind::Spec, authority);

        let env = Envelope::supported(
            KEY,
            vec![stamped, bare],
            Confidence::Retrieved,
            Freshness::new(index_commit.to_string(), "2026-08-18T00:00:00Z".to_string()),
        )
        .with_default_citation_commit(process_head);
        assert_eq!(env.citations()[0].commit(), Some(index_commit));
        assert_eq!(env.citations()[1].commit(), Some(process_head));

        // A non-sha is dropped rather than stored: no `unknown`, no ref name,
        // and nothing that could become a command-line argument.
        let junk = Citation::new(
            "c.md".to_string(),
            1,
            2,
            CitationKind::Spec,
            BTreeMap::new(),
        )
        .with_commit("HEAD");
        assert_eq!(junk.commit(), None);
    }

    /// A checkout ROOT resolves to that checkout's HEAD, not to whatever
    /// repository happens to enclose it.
    ///
    /// Found by an end-to-end exercise of `spec-envelope`, not by reading the
    /// code: the spec expert stamped `freshness.source_commit` with the MAIN
    /// checkout's HEAD while running inside a linked worktree six commits away,
    /// because `for_source` was given a directory and took its parent. Nothing
    /// was red — the envelope verified, the sha was a real sha, and it named the
    /// wrong repository.
    #[test]
    fn freshness_for_a_checkout_root_is_that_checkouts_head() {
        let outer = repo("nested-outer");
        outer.write("f", "outer\n");
        let outer_head = outer.commit("outer");

        // A second repository nested inside the first, exactly as a linked
        // worktree under .claude/worktrees/ sits inside its main checkout.
        let inner_dir = outer.path().join("nested/inner");
        std::fs::create_dir_all(&inner_dir).expect("mkdir inner");
        let git = |args: &[&str]| {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&inner_dir)
                .args(args)
                .output()
                .expect("git");
            assert!(out.status.success(), "git {args:?}");
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.email", "l@t.invalid"]);
        git(&["config", "user.name", "l"]);
        std::fs::write(inner_dir.join("g"), "inner\n").expect("write");
        git(&["add", "-A"]);
        git(&["commit", "-q", "--no-verify", "-m", "inner"]);
        let inner_head = git(&["rev-parse", "HEAD"]);
        assert_ne!(inner_head, outer_head);

        let fresh = Freshness::for_source(&inner_dir);
        assert_eq!(
            fresh.source_commit(),
            inner_head,
            "a root must resolve to its own HEAD, not the enclosing repository's"
        );
        // A FILE inside it keeps resolving as it always did.
        let fresh_file = Freshness::for_source(&inner_dir.join("g"));
        assert_eq!(fresh_file.source_commit(), inner_head);
    }

    /// An envelope with no frame at all still serializes to the pre-801-g9nn
    /// shape, byte for byte. Both fields are additive and absent when unknown,
    /// which is what keeps every existing key-set pin honest instead of merely
    /// updated.
    #[test]
    fn an_unframed_envelope_serializes_exactly_as_it_did_before() {
        let ledger = live_ledger();
        let env = answer_question(&ledger, "status of 394a", "plan/index.yaml");
        let v = serde_json::to_value(&env).expect("serializes");
        let obj = v.as_object().expect("object");
        assert!(!obj.contains_key("caller_relation"));
        assert!(
            !v["citations"][0]
                .as_object()
                .expect("citation object")
                .contains_key("commit")
        );
    }
}
