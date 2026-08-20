//! ORDER 394d — the ground-truth grading harness for the expert family.
//!
//! # What this is
//!
//! A COMMITTED query set (questions + the exact answers they must produce) and
//! a grader that runs the deterministic L0 engines against it. It is the
//! grading gate order 393's decision record left as a residual, and the
//! falsifiable accuracy bar orders 457 (cheatsheet expert) and 400 (code
//! expert) inherit instead of inventing one each.
//!
//! # Why the schema has no corpus in it
//!
//! The whole value of a shared bar is that a second corpus cannot quietly
//! lower it. So NOTHING in [`Expect`] names methodology, the plan ledger, or
//! any corpus: an expectation is written against the 394b **envelope** —
//! confidence, citation count, citation kind, citation fields, the text of the
//! cited span re-read from disk, and the answer prose. [`grade_envelope`] takes
//! `(&Envelope, &Expect, &Path)` and NOTHING ELSE — it is structurally
//! incapable of special-casing a corpus, which is the property that makes
//! "reusable verbatim" a fact rather than an intention.
//!
//! Adding a corpus is therefore two edits and no new grading logic:
//!   1. one row in [`ENGINES`] plus one arm in [`Harness::run`];
//!   2. a new `*.yaml` query set in `openspec/litmus-tests/groundtruth/`.
//! `tillandsias-plan grade openspec/litmus-tests/groundtruth/*.yaml` then
//! grades it with the same binary, the same schema and the same litmus.
//!
//! # Why the grader cannot be vacuously green
//!
//! Every way a grading harness normally rots is refused here:
//!   * an EMPTY case list is an error, not "0 failures";
//!   * DUPLICATE case ids across all supplied query sets are an error (the
//!     silent way a case gets shadowed and stops being graded);
//!   * `deny_unknown_fields` everywhere: a MISSPELLED expectation key is a
//!     parse error, not an expectation that is silently never checked — that
//!     is the single most common way an assertion becomes decoration;
//!   * an unknown `engine` is an ERROR naming the registration site, never a
//!     skipped case;
//!   * every case additionally runs 394b's [`answer::verify`] against the
//!     checkout, so a case can never pass on a citation that does not resolve.
//!
//! @trace spec:spec-traceability
//! @trace order:394, order:394d
//! @trace order:456 (exit criterion 3 — correct packets for the active release)

use crate::Ledger;
use crate::answer::{self, Citation, CitationKind, Confidence, Envelope};
use crate::methodology;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The registered engines, `(name, what it queries)`.
///
/// THIS IS THE PLUG-IN POINT for orders 457 and 400. A query set naming an
/// engine that is not in this table is rejected with a message that points
/// here, so a new corpus fails loudly at the registration site instead of
/// being silently skipped.
pub const ENGINES: &[(&str, &str)] = &[
    (
        "spec.answer",
        "the whole-spec RAG corpus via spec::top_k + spec::build_envelope over a CALLER-SUPPLIED query vector (orders 547/551)",
    ),
    (
        "plan.answer",
        "plan/index.yaml via answer::answer_question (order 394b)",
    ),
    (
        "methodology.ask",
        "methodology.yaml + methodology/**/*.yaml via methodology::answer_question — canonical question routing (order 394c)",
    ),
    (
        "methodology.path",
        "methodology.yaml + methodology/**/*.yaml via methodology::answer_path_query — dotted YAML path (order 394c)",
    ),
    (
        "cheatsheet.ask",
        "cheatsheets/**/*.md via spec::answer_cheatsheet_query (order 707-tiqw)",
    ),
];

/// The one place the format version is pinned. A query set from a future
/// schema is REFUSED rather than partially understood.
pub const QUERY_SET_VERSION: u32 = 1;

// ── the committed query-set schema ──────────────────────────────────────────

/// One committed query set. Corpus-agnostic by construction — see the module
/// doc.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuerySet {
    pub version: u32,
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// The ledger THIS SET must be graded against, repo-relative (order
    /// 786-kjke). Absent (the common case) means "whatever `--index` the run
    /// supplies", which is the live ledger by default.
    ///
    /// THIS DOES NOT WEAKEN THE MODULE'S no-corpus INVARIANT, and the
    /// distinction is the whole reason it is safe. That invariant is about
    /// [`Expect`]: an expectation may never name a corpus, so a second corpus
    /// cannot quietly lower the bar, and [`grade_envelope`] still takes
    /// `(&Envelope, &Expect, &Path)` and nothing else. This field is not an
    /// expectation and the grader never reads it — it only tells the RUNNER
    /// which ledger to hand the engine, which is exactly the fact that
    /// previously lived in a file-header comment no machine could read.
    ///
    /// WHY IT EXISTS. `grade openspec/litmus-tests/groundtruth/*.yaml` — the
    /// obvious invocation — graded the two fixture-backed sets against the
    /// LIVE ledger and reported `pass=22 fail=6`, every one of those six a
    /// FALSE red (observed 2026-08-17; correctly graded the true state is
    /// 28/28). The contract was documented only in each file's header, so the
    /// tool cheerfully did the wrong thing and blamed the expert. That is the
    /// 741-2izr shape — a false red trains readers to discount the signal —
    /// landing on the accuracy harness the fleet's `expert_accuracy:` metric
    /// rests on.
    #[serde(default)]
    pub corpus: Option<String>,
    pub cases: Vec<Case>,
}

/// One graded question.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    /// Unique across every query set handed to one run.
    pub id: String,
    /// A name from [`ENGINES`].
    pub engine: String,
    /// The question or path, VERBATIM as an agent would ask it.
    pub query: String,
    /// Prose: the regression this case exists to catch. Never graded — it is
    /// what a human reads when the case goes red.
    #[serde(default)]
    pub why: String,
    /// Repo-relative path to a JSON array of floats: the EMBEDDING of `query`.
    ///
    /// Required by `spec.answer` and meaningless to the other engines. It is
    /// committed rather than computed because this crate is network-free by
    /// construction (spec.rs:2) and `spec-retrieve` is already specified as
    /// "network-free cosine top-k over CALLER-SUPPLIED embeddings" — so the
    /// grader supplies the vector exactly as every other caller does. The
    /// alternative, having the grader make an HTTP call, would trade
    /// determinism for nothing; grading a lexical path instead would be worse
    /// still, because a green grade would then certify a path production never
    /// runs.
    ///
    /// It pins the set to an embedding model (768-dim nomic-embed-text here).
    /// That is a managed fact, not a new one: check-dev-embed-model-agreement.sh
    /// exists so the producer and the query path cannot name different models.
    /// A model change re-embeds the set; it does not rewrite it.
    #[serde(default)]
    pub query_vec: Option<String>,
    pub expect: Expect,
}

/// The expected answer. Written against the ENVELOPE, never against a corpus.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    /// Required. `unsupported` is a first-class expected answer: refusing is
    /// the behaviour half of this contract, so it is graded, not tolerated.
    pub confidence: Confidence,
    /// Defaults: 1 for a supported answer, 0 for `unsupported`.
    #[serde(default)]
    pub min_citations: Option<usize>,
    #[serde(default)]
    pub max_citations: Option<usize>,
    /// Every citation must carry this kind.
    #[serde(default)]
    pub citation_kind: Option<CitationKind>,
    /// Each entry must be satisfied by AT LEAST ONE citation.
    #[serde(default)]
    pub citations_include: Vec<CitationMatch>,
    /// Each entry must be satisfied by NO citation. This is what stops a
    /// "return everything" regression from satisfying `citations_include`.
    #[serde(default)]
    pub citations_exclude: Vec<CitationMatch>,
    #[serde(default)]
    pub answer_contains: Vec<String>,
    /// Text the answer MUST NOT contain — how a refusal is held to not leaking
    /// the neighbouring block as if it were the answer.
    #[serde(default)]
    pub answer_excludes: Vec<String>,
    /// Run 394b's citation verifier over the envelope. Default ON, and there
    /// is no reason to turn it off except to document a known-broken corpus.
    #[serde(default = "yes")]
    pub verify: bool,
}

fn yes() -> bool {
    true
}

/// A predicate over ONE citation.
///
/// `path`, `kind` and `span_contains` are the envelope-level fields; EVERY
/// OTHER KEY is matched against the citation's open `authority` map. That is
/// what keeps the schema corpus-agnostic: a plan citation is pinned with
/// `packet_id`/`order`/`status`, a methodology citation with
/// `yaml_path`/`key`, and a future cheatsheet or code citation with whatever
/// authority keys it carries — with no change to this struct.
#[derive(Debug, Deserialize)]
pub struct CitationMatch {
    /// Repo-relative path the citation must carry.
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub kind: Option<CitationKind>,
    /// Text that must appear in the cited span, RE-READ FROM DISK at grading
    /// time. This is the load-bearing assertion: it is what makes a citation
    /// evidence rather than a well-formed pointer at the wrong lines.
    #[serde(default)]
    pub span_contains: Vec<String>,
    #[serde(flatten)]
    pub authority: BTreeMap<String, String>,
}

impl CitationMatch {
    fn render(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(p) = &self.path {
            parts.push(format!("path={p}"));
        }
        if let Some(k) = &self.kind {
            parts.push(format!("kind={k:?}"));
        }
        for (k, v) in &self.authority {
            parts.push(format!("{k}={v}"));
        }
        for s in &self.span_contains {
            parts.push(format!("span_contains={:?}", truncate(s, 48)));
        }
        format!("{{{}}}", parts.join(", "))
    }
}

// ── grading ─────────────────────────────────────────────────────────────────

/// The result of grading one case. `failures` EMPTY means PASS.
#[derive(Debug)]
pub struct Outcome {
    pub id: String,
    pub engine: String,
    pub failures: Vec<String>,
}

impl Outcome {
    pub fn passed(&self) -> bool {
        self.failures.is_empty()
    }
}

type SpanCache = BTreeMap<String, Option<Vec<String>>>;

/// Grade ONE envelope against ONE expectation. Returns the failures; EMPTY is
/// a pass.
///
/// THE SIGNATURE IS THE CONTRACT: `(&Envelope, &Expect, &Path)` — no corpus,
/// no ledger, no engine. Grading cannot know which expert produced the
/// envelope, so a new expert cannot be graded more leniently than an old one.
/// `root` is the checkout the citation paths resolve against.
pub fn grade_envelope(envelope: &Envelope, expect: &Expect, root: &Path) -> Vec<String> {
    let mut failures: Vec<String> = Vec::new();
    let mut cache: SpanCache = BTreeMap::new();

    if envelope.confidence() != expect.confidence {
        failures.push(format!(
            "confidence: expected {:?}, got {:?}",
            expect.confidence,
            envelope.confidence()
        ));
    }

    let cited = envelope.citations();
    let min = expect
        .min_citations
        .unwrap_or(if expect.confidence == Confidence::Unsupported {
            0
        } else {
            1
        });
    if cited.len() < min {
        failures.push(format!(
            "citations: expected at least {min}, got {}",
            cited.len()
        ));
    }
    if let Some(max) = expect.max_citations
        && cited.len() > max
    {
        failures.push(format!(
            "citations: expected at most {max}, got {}",
            cited.len()
        ));
    }

    if let Some(want) = expect.citation_kind {
        for c in cited {
            if c.kind() != want {
                failures.push(format!(
                    "citation {}:{}-{} has kind {:?}, expected every citation to be {want:?}",
                    c.path(),
                    c.line_start(),
                    c.line_end(),
                    c.kind()
                ));
                break;
            }
        }
    }

    for want in &expect.citations_include {
        let mut why: Vec<String> = Vec::new();
        let hit = cited
            .iter()
            .any(|c| match citation_matches(c, want, root, &mut cache) {
                Ok(()) => true,
                Err(reason) => {
                    why.push(reason);
                    false
                }
            });
        if !hit {
            failures.push(format!(
                "no citation satisfies {} — cited: [{}]{}",
                want.render(),
                summarize(cited),
                nearest(&why)
            ));
        }
    }

    for forbid in &expect.citations_exclude {
        if let Some(c) = cited
            .iter()
            .find(|c| citation_matches(c, forbid, root, &mut cache).is_ok())
        {
            failures.push(format!(
                "citation {}:{}-{} matches the FORBIDDEN pattern {}",
                c.path(),
                c.line_start(),
                c.line_end(),
                forbid.render()
            ));
        }
    }

    for needle in &expect.answer_contains {
        if !envelope.answer().contains(needle.as_str()) {
            failures.push(format!(
                "answer does not contain {:?}",
                truncate(needle, 72)
            ));
        }
    }
    for needle in &expect.answer_excludes {
        if envelope.answer().contains(needle.as_str()) {
            failures.push(format!(
                "answer LEAKS forbidden text {:?}",
                truncate(needle, 72)
            ));
        }
    }

    if expect.verify {
        for v in answer::verify(envelope, root) {
            failures.push(format!("394b verify: {v}"));
        }
    }

    failures
}

/// `Ok(())` when the citation satisfies every constraint; `Err` names the
/// FIRST one it failed, which is what gets surfaced as the near-miss hint.
fn citation_matches(
    c: &Citation,
    m: &CitationMatch,
    root: &Path,
    cache: &mut SpanCache,
) -> Result<(), String> {
    if let Some(p) = &m.path
        && c.path() != p
    {
        return Err(format!("path {} != {p}", c.path()));
    }
    if let Some(k) = m.kind
        && c.kind() != k
    {
        return Err(format!("kind {:?} != {k:?}", c.kind()));
    }
    for (key, want) in &m.authority {
        match c.authority().get(key) {
            Some(got) if got == want => {}
            Some(got) => {
                return Err(format!(
                    "authority.{key} = {:?}, expected {:?}",
                    truncate(got, 48),
                    truncate(want, 48)
                ));
            }
            None => return Err(format!("citation carries no authority.{key}")),
        }
    }
    if m.span_contains.is_empty() {
        return Ok(());
    }
    let Some(lines) = read_lines(root, c.path(), cache) else {
        return Err(format!("{}: cited file does not resolve", c.path()));
    };
    if c.line_start() == 0 || c.line_end() < c.line_start() || c.line_end() > lines.len() {
        return Err(format!(
            "{}:{}-{}: cited range is out of bounds (file has {} lines)",
            c.path(),
            c.line_start(),
            c.line_end(),
            lines.len()
        ));
    }
    let span = lines[c.line_start() - 1..c.line_end()].join("\n");
    for needle in &m.span_contains {
        if !span.contains(needle.as_str()) {
            return Err(format!(
                "{}:{}-{}: cited span does not contain {:?}",
                c.path(),
                c.line_start(),
                c.line_end(),
                truncate(needle, 56)
            ));
        }
    }
    Ok(())
}

fn read_lines<'a>(root: &Path, rel: &str, cache: &'a mut SpanCache) -> Option<&'a Vec<String>> {
    if !cache.contains_key(rel) {
        let loaded = std::fs::read_to_string(root.join(rel))
            .ok()
            .map(|t| t.lines().map(str::to_string).collect::<Vec<String>>());
        cache.insert(rel.to_string(), loaded);
    }
    cache.get(rel).and_then(Option::as_ref)
}

fn summarize(cited: &[Citation]) -> String {
    let shown: Vec<String> = cited
        .iter()
        .take(4)
        .map(|c| format!("{}:{}-{}", c.path(), c.line_start(), c.line_end()))
        .collect();
    if cited.len() > 4 {
        format!("{}, +{} more", shown.join(", "), cited.len() - 4)
    } else {
        shown.join(", ")
    }
}

/// The closest miss, so a red case says WHY rather than only THAT.
fn nearest(why: &[String]) -> String {
    match why.first() {
        Some(first) => format!("; closest miss: {first}"),
        None => String::new(),
    }
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    s.chars().take(n).collect::<String>() + "…"
}

// ── the harness ─────────────────────────────────────────────────────────────

/// Loads each corpus AT MOST ONCE and answers every case from it. Loading the
/// 22k-line ledger or the 57-file methodology corpus per case is the
/// difference between a harness that fits the 60s in-forge budget and one that
/// gets disabled.
pub struct Harness {
    root: PathBuf,
    index: PathBuf,
    index_rel: String,
    ledger: Option<Ledger>,
    corpus: Option<methodology::Corpus>,
    cheatsheets: Option<Vec<crate::spec::Chunk>>,
    spec_vectors: Option<Vec<Vec<f32>>>,
    spec_chunks: Option<Vec<crate::spec::Chunk>>,
}

impl Harness {
    pub fn new(root: PathBuf, index: PathBuf, index_rel: String) -> Self {
        Self {
            root,
            index,
            index_rel,
            ledger: None,
            corpus: None,
            cheatsheets: None,
            spec_vectors: None,
            spec_chunks: None,
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn ledger(&mut self) -> Result<&Ledger, String> {
        if self.ledger.is_none() {
            // ORDER 606-h9vy — the FOLDED loader, exactly like the CLI answer
            // path. A base-only harness grades an expert against a ledger no
            // agent actually sees: fragment-born packets are invisible and LWW
            // overrides read stale, which is the stale-reader divergence
            // `load_with_fragments`' own doc warns about.
            self.ledger = Some(Ledger::load_with_fragments(&self.index)?);
        }
        Ok(self.ledger.as_ref().expect("just loaded"))
    }

    fn corpus(&mut self) -> Result<&methodology::Corpus, String> {
        if self.corpus.is_none() {
            self.corpus = Some(methodology::Corpus::load(&self.root)?);
        }
        Ok(self.corpus.as_ref().expect("just loaded"))
    }

    /// The embedding vectors, index-aligned with `chunk_corpus(root)`.
    ///
    /// The chunks are re-derived from the repo (deterministic: sorted files,
    /// sequential ids), so they are hermetic; only the VECTORS are host state,
    /// because 19k x 768 floats is not a thing to commit. The alignment between
    /// them is what the index's fingerprint guarantees, so a count mismatch is
    /// refused rather than graded — a shifted pairing answers plausibly and
    /// wrongly, which is the one failure mode a grader must never certify.
    fn spec_index(&mut self) -> Result<(&[crate::spec::Chunk], &[Vec<f32>]), String> {
        if self.spec_vectors.is_none() {
            let dir = std::env::var("TILLANDSIAS_SPEC_INDEX_DIR")
                .or_else(|_| std::env::var("FORGE_SPEC_INDEX_DIR"))
                .map_err(|_| {
                    "spec.answer needs a built index: set TILLANDSIAS_SPEC_INDEX_DIR to a                      directory containing vectors.jsonl (scripts/spec-index-ensure.sh builds one)"
                        .to_string()
                })?;
            let path = PathBuf::from(&dir).join("vectors.jsonl");
            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("read {}: {e}", path.display()))?;
            let mut out: Vec<Vec<f32>> = Vec::new();
            for (n, line) in text.lines().enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                out.push(serde_json::from_str::<Vec<f32>>(line).map_err(|e| {
                    format!("{}:{}: not a float vector: {e}", path.display(), n + 1)
                })?);
            }
            self.spec_vectors = Some(out);

            let cpath = PathBuf::from(&dir).join("chunks.jsonl");
            let ctext = std::fs::read_to_string(&cpath)
                .map_err(|e| format!("read {}: {e}", cpath.display()))?;
            let mut cs: Vec<crate::spec::Chunk> = Vec::new();
            for (n, line) in ctext.lines().enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                cs.push(serde_json::from_str(line).map_err(|e| {
                    format!("{}:{}: not a chunk record: {e}", cpath.display(), n + 1)
                })?);
            }
            self.spec_chunks = Some(cs);
        }
        let got = self.spec_vectors.as_ref().expect("just loaded").len();
        let want = self.spec_chunks.as_ref().expect("just loaded").len();
        if got != want {
            return Err(format!(
                "index is stale: {got} vectors for {want} chunks. The vectors must be                  index-aligned with chunk_corpus(root); rebuild with                  scripts/spec-index-ensure.sh"
            ));
        }
        Ok((
            self.spec_chunks.as_ref().expect("just loaded"),
            self.spec_vectors.as_ref().expect("just loaded"),
        ))
    }

    fn cheatsheets(&mut self) -> Result<&[crate::spec::Chunk], String> {
        if self.cheatsheets.is_none() {
            self.cheatsheets = Some(crate::spec::chunk_corpus(&self.root));
        }
        Ok(self.cheatsheets.as_ref().expect("just loaded"))
    }

    /// Produce the envelope a case's engine answers with.
    ///
    /// `Err` is an ENVIRONMENTAL failure (unknown engine, unreadable corpus) —
    /// never a graded result, because a harness that reports "the corpus is
    /// missing" as a failed expectation teaches agents to ignore red.
    pub fn run(&mut self, case: &Case) -> Result<Envelope, String> {
        match case.engine.as_str() {
            "plan.answer" => {
                let rel = self.index_rel.clone();
                let ledger = self.ledger()?;
                Ok(answer::answer_question(ledger, &case.query, &rel))
            }
            "methodology.ask" => {
                let corpus = self.corpus()?;
                Ok(methodology::answer_question(corpus, &case.query, None))
            }
            "methodology.path" => {
                let corpus = self.corpus()?;
                Ok(methodology::answer_path_query(corpus, &case.query, None))
            }
            "spec.answer" => {
                let rel = case.query_vec.as_deref().ok_or_else(|| {
                    format!(
                        "case {:?} uses spec.answer but has no query_vec; the grader supplies                          the embedding (this crate is network-free)",
                        case.id
                    )
                })?;
                let root = self.root.clone();
                let qpath = root.join(rel);
                let qtext = std::fs::read_to_string(&qpath)
                    .map_err(|e| format!("read {}: {e}", qpath.display()))?;
                let qvec: Vec<f32> = serde_json::from_str(&qtext)
                    .map_err(|e| format!("{}: not a float vector: {e}", qpath.display()))?;
                // BOTH sides from the index, written by one run over one tree.
                // Re-deriving chunks from the repo was the first shape and it is
                // wrong: `crates/` is IN the corpus, so editing any Rust file
                // shifts the pairing. Caught immediately — adding this engine
                // took the tree to 19485 chunks against 19483 stored vectors.
                let (chunks, vectors) = self.spec_index()?;
                let top = crate::spec::top_k(&qvec, vectors, 6);
                let picked: Vec<crate::spec::ScoredChunk> = top
                    .iter()
                    .map(|(i, sc)| crate::spec::ScoredChunk {
                        chunk: chunks[*i].clone(),
                        score: *sc,
                    })
                    .collect();
                // The retrieval-only answer is the documented zero-token floor
                // and is what makes this deterministic. What is graded is the
                // citation set, not the prose (this packet's own criterion).
                let plain: Vec<crate::spec::Chunk> =
                    picked.iter().map(|p| p.chunk.clone()).collect();
                let answer = crate::spec::retrieval_only_answer(&plain);
                Ok(crate::spec::build_envelope_scored(&answer, &picked, &root))
            }
            "cheatsheet.ask" => {
                let root = self.root.clone();
                let chunks = self.cheatsheets()?;
                Ok(crate::spec::answer_cheatsheet_query(
                    &root,
                    chunks,
                    &case.query,
                ))
            }
            other => Err(format!(
                "unknown engine {other:?} in case {:?}. Registered engines: {}. \
                 Register a new corpus in crates/tillandsias-plan/src/groundtruth.rs \
                 (ENGINES + Harness::run) — the grading logic itself needs no change.",
                case.id,
                ENGINES
                    .iter()
                    .map(|(n, _)| *n)
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
        }
    }
}

/// Parse one query set. Rejects a foreign schema version and an empty case
/// list — "0 cases, 0 failures" is the classic green-by-vacuum.
pub fn load_query_set(path: &Path) -> Result<QuerySet, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("read query set {}: {e}", path.display()))?;
    let qs: QuerySet = serde_yaml::from_str(&raw)
        .map_err(|e| format!("parse query set {}: {e}", path.display()))?;
    if qs.version != QUERY_SET_VERSION {
        return Err(format!(
            "{}: query-set version {} is not {QUERY_SET_VERSION}",
            path.display(),
            qs.version
        ));
    }
    if qs.cases.is_empty() {
        return Err(format!(
            "{}: query set has ZERO cases — an empty ground truth grades everything green",
            path.display()
        ));
    }
    Ok(qs)
}

/// Load every query set and refuse duplicate case ids across all of them.
pub fn load_all(paths: &[PathBuf]) -> Result<Vec<QuerySet>, String> {
    if paths.is_empty() {
        return Err("no query set supplied".to_string());
    }
    let mut sets = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for p in paths {
        let qs = load_query_set(p)?;
        for c in &qs.cases {
            if !seen.insert(c.id.clone()) {
                return Err(format!(
                    "{}: duplicate case id {:?} — a shadowed case silently stops being graded",
                    p.display(),
                    c.id
                ));
            }
        }
        sets.push(qs);
    }
    Ok(sets)
}

/// Grade every case of every set. `Err` is environmental (see [`Harness::run`]).
pub fn grade_all(harness: &mut Harness, sets: &[QuerySet]) -> Result<Vec<Outcome>, String> {
    let mut out = Vec::new();
    for qs in sets {
        for case in &qs.cases {
            let envelope = harness.run(case)?;
            let root = harness.root().to_path_buf();
            out.push(Outcome {
                id: case.id.clone(),
                engine: case.engine.clone(),
                failures: grade_envelope(&envelope, &case.expect, &root),
            });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn committed_set() -> PathBuf {
        repo_root().join("openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml")
    }

    /// EVERY committed corpus, one entry per registered engine's query set.
    ///
    /// Order 551 registered the `spec.answer` engine and added its cases in a
    /// SEPARATE file, `spec-rung1.yaml`, but the representation test still read
    /// only `committed_set()` — so the engine was registered, never graded, and
    /// the test that exists to catch exactly that went red instead of the
    /// corpus being found. It was doing its job; it simply had no way to see
    /// the second file.
    ///
    /// Listed explicitly rather than globbed: the other two files in that
    /// directory (fragment-provenance, plan-next) are scoped query sets, not
    /// per-engine corpora, and sweeping the directory would silently change
    /// what "represented" means the next time someone adds one.
    fn committed_sets() -> Vec<PathBuf> {
        let root = repo_root().join("openspec/litmus-tests/groundtruth");
        vec![
            root.join("expert-groundtruth-rung1.yaml"),
            root.join("spec-rung1.yaml"),
        ]
    }

    fn harness() -> Harness {
        Harness::new(
            repo_root(),
            repo_root().join("plan/index.yaml"),
            "plan/index.yaml".to_string(),
        )
    }

    /// ORDER 606-xu52 — the plan_next query set is GREEN at HEAD, graded
    /// against its committed immutable fixture corpus (the live ready set
    /// churns with every claim, so ordering can only be pinned there). The
    /// adjacency needles inside the set are the deterministic-ordering proof.
    #[test]
    fn the_plan_next_query_set_is_green_at_head() {
        let root = repo_root().join("openspec/litmus-tests/groundtruth/fixtures/plan-next");
        let mut harness = Harness::new(
            root.clone(),
            root.join("plan/index.yaml"),
            "plan/index.yaml".to_string(),
        );
        let sets =
            load_all(&[repo_root()
                .join("openspec/litmus-tests/groundtruth/expert-groundtruth-plan-next.yaml")])
            .expect("the plan-next query set loads");
        let outcomes = grade_all(&mut harness, &sets).expect("every engine is registered");
        let red: Vec<&Outcome> = outcomes.iter().filter(|o| !o.passed()).collect();
        assert!(
            red.is_empty(),
            "plan-next ground truth is RED: {:?}",
            red.iter()
                .map(|o| format!("{}: {}", o.id, o.failures.join(" | ")))
                .collect::<Vec<_>>()
        );
    }

    /// ORDER 606-h9vy — the fragment-provenance query set is GREEN at HEAD,
    /// graded against its own committed immutable fixture corpus (never the
    /// live ledger, whose fragments compaction folds away).
    #[test]
    fn the_fragment_provenance_query_set_is_green_at_head() {
        let root =
            repo_root().join("openspec/litmus-tests/groundtruth/fixtures/fragment-provenance");
        let mut harness = Harness::new(
            root.clone(),
            root.join("plan/index.yaml"),
            "plan/index.yaml".to_string(),
        );
        let sets = load_all(&[repo_root().join(
            "openspec/litmus-tests/groundtruth/expert-groundtruth-fragment-provenance.yaml",
        )])
        .expect("the fragment-provenance query set loads");
        let outcomes = grade_all(&mut harness, &sets).expect("every engine is registered");
        let red: Vec<&Outcome> = outcomes.iter().filter(|o| !o.passed()).collect();
        assert!(
            red.is_empty(),
            "fragment-provenance ground truth is RED: {:?}",
            red.iter()
                .map(|o| format!("{}: {}", o.id, o.failures.join(" | ")))
                .collect::<Vec<_>>()
        );
    }

    /// EXIT (ii): the committed query set is GREEN at HEAD.
    #[test]
    fn the_committed_query_set_is_green_at_head() {
        let sets = load_all(&[committed_set()]).expect("the committed query set loads");
        let outcomes = grade_all(&mut harness(), &sets).expect("every engine is registered");
        let red: Vec<&Outcome> = outcomes.iter().filter(|o| !o.passed()).collect();
        assert!(
            red.is_empty(),
            "ground truth is RED: {:?}",
            red.iter()
                .map(|o| format!("{}: {}", o.id, o.failures.join(" | ")))
                .collect::<Vec<_>>()
        );
        assert!(
            outcomes.len() >= 16,
            "the query set shrank to {} cases — a shrinking bar is a lowered bar",
            outcomes.len()
        );
    }

    /// ORDER 707-tiqw: cheatsheet ground-truth falsification. A wrong expected
    /// span in a cheatsheet case must go RED.
    #[test]
    fn a_wrong_expected_cheatsheet_span_turns_a_passing_case_red() {
        let mut h = harness();
        let case: Case = serde_yaml::from_str(
            r#"
id: cheatsheet-falsification-probe
engine: cheatsheet.ask
query: "what three primitives are needed for CRDT ledger fragments?"
expect:
  confidence: exact
  citation_kind: cheatsheet
  citations_include:
    - path: cheatsheets/concurrent-git/crdt-ledger-fragments.md
      kind: cheatsheet
      span_contains: ["G-Set"]
"#,
        )
        .expect("probe case parses");
        let env = h.run(&case).expect("engine registered");
        assert!(
            grade_envelope(&env, &case.expect, &repo_root()).is_empty(),
            "the probe must be GREEN before it is falsified"
        );

        let wrong: Case = serde_yaml::from_str(
            r#"
id: cheatsheet-falsification-probe
engine: cheatsheet.ask
query: "what three primitives are needed for CRDT ledger fragments?"
expect:
  confidence: exact
  citation_kind: cheatsheet
  citations_include:
    - path: cheatsheets/concurrent-git/crdt-ledger-fragments.md
      kind: cheatsheet
      span_contains: ["FABRICATED NONEXISTENT CRDT PRIMITIVE SPAN"]
"#,
        )
        .expect("probe case parses");
        let failures = grade_envelope(&env, &wrong.expect, &repo_root());
        assert!(
            !failures.is_empty(),
            "a fabricated cheatsheet span was graded GREEN — the harness cannot fail"
        );
    }

    /// BOTH corpora are actually exercised. A query set that quietly lost all
    /// its plan cases would still be "green", and the plan expert would stop
    /// being graded without anything going red.
    #[test]
    fn both_corpora_are_represented_in_the_committed_set() {
        let sets = load_all(&committed_sets()).expect("loads");
        let engines: BTreeSet<&str> = sets
            .iter()
            .flat_map(|s| s.cases.iter())
            .map(|c| c.engine.as_str())
            .collect();
        for (name, _) in ENGINES {
            assert!(
                engines.contains(name),
                "engine {name} is registered but has no committed ground-truth case"
            );
        }
    }

    /// EXIT (iii) at the unit level: a WRONG expected answer must go RED. The
    /// harness is worthless if it cannot be made to fail, so the falsification
    /// is a test, not a manual ritual.
    #[test]
    fn a_wrong_expected_span_turns_a_passing_case_red() {
        let mut h = harness();
        let case: Case = serde_yaml::from_str(
            r#"
id: falsification-probe
engine: methodology.ask
query: "may a forge cycle drain two packets?"
expect:
  confidence: exact
  citations_include:
    - path: methodology/distributed-work.yaml
      span_contains: ["MAY drain more than one plan packet"]
"#,
        )
        .expect("probe case parses");
        let env = h.run(&case).expect("engine registered");
        assert!(
            grade_envelope(&env, &case.expect, &repo_root()).is_empty(),
            "the probe must be GREEN before it is falsified"
        );

        let wrong: Case = serde_yaml::from_str(
            r#"
id: falsification-probe
engine: methodology.ask
query: "may a forge cycle drain two packets?"
expect:
  confidence: exact
  citations_include:
    - path: methodology/distributed-work.yaml
      span_contains: ["drain AS MANY plan packets as you like per cycle"]
"#,
        )
        .expect("probe case parses");
        let failures = grade_envelope(&env, &wrong.expect, &repo_root());
        assert!(
            !failures.is_empty(),
            "a fabricated expected answer was graded GREEN — the harness cannot fail"
        );
    }

    /// A misspelled expectation key must be a PARSE ERROR. If it were ignored,
    /// the case would still say PASS while checking nothing.
    #[test]
    fn a_misspelled_expectation_key_is_refused_not_ignored() {
        let err = serde_yaml::from_str::<Case>(
            r#"
id: typo
engine: methodology.ask
query: "x"
expect:
  confidence: exact
  answer_contain: ["typo — the real key is answer_contains"]
"#,
        )
        .expect_err("a typo'd expectation key must not parse");
        assert!(
            err.to_string().contains("answer_contain"),
            "the parse error must name the offending key, got: {err}"
        );
    }

    #[test]
    fn an_empty_query_set_is_an_error_not_a_pass() {
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-groundtruth-empty-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let p = dir.join("empty.yaml");
        std::fs::write(&p, "version: 1\nname: empty\ncases: []\n").expect("write");
        let err = load_query_set(&p).expect_err("an empty query set must be refused");
        assert!(err.contains("ZERO cases"), "got: {err}");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_unknown_engine_names_the_registration_site() {
        let case: Case = serde_yaml::from_str(
            "id: future\nengine: code.ask\nquery: x\nexpect:\n  confidence: exact\n",
        )
        .expect("parses");
        let err = harness()
            .run(&case)
            .expect_err("an unknown engine must fail loudly");
        assert!(err.contains("groundtruth.rs"), "got: {err}");
        assert!(err.contains("plan.answer"), "got: {err}");
    }

    /// The corpus-agnosticism claim, pinned where it can rot: grade an
    /// envelope from a corpus this crate has NO engine for, carrying an
    /// authority key nothing here emits, over a checkout this crate does not
    /// own. If grading ever grew a corpus branch, this stops working — which
    /// is the point. This is the mechanical half of EXIT (iv).
    #[test]
    fn grading_works_on_a_corpus_this_crate_does_not_own() {
        use crate::answer::{Citation, Freshness};

        // A synthetic checkout: a "cheatsheet" corpus that no engine in this
        // crate can produce, read at grading time like any other.
        let root = std::env::temp_dir().join(format!(
            "tillandsias-groundtruth-foreign-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(root.join("docs/cheatsheets")).expect("scratch checkout");
        std::fs::write(
            root.join("docs/cheatsheets/podman.md"),
            "# podman\n\ntopic: rootless-storage\nThe forge NEVER runs a rootful podman.\n",
        )
        .expect("write foreign corpus");

        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), "topic: rootless-storage".to_string());
        authority.insert("cheatsheet".to_string(), "podman".to_string());
        let env = Envelope::supported(
            "rootless only — see topic: rootless-storage",
            vec![Citation::new(
                "docs/cheatsheets/podman.md".to_string(),
                3,
                4,
                CitationKind::Cheatsheet,
                authority,
            )],
            Confidence::Exact,
            Freshness::new("synthetic".into(), "synthetic".into()),
        );
        let expect: Expect = serde_yaml::from_str(
            r#"
confidence: exact
citation_kind: cheatsheet
citations_include:
  - path: docs/cheatsheets/podman.md
    kind: cheatsheet
    cheatsheet: podman
    span_contains: ["NEVER runs a rootful podman"]
"#,
        )
        .expect("parses");
        let green = grade_envelope(&env, &expect, &root);

        // …and the same foreign corpus is FALSIFIABLE with no grader change.
        let wrong: Expect = serde_yaml::from_str(
            r#"
confidence: exact
citations_include:
  - path: docs/cheatsheets/podman.md
    span_contains: ["the forge runs a rootful podman"]
"#,
        )
        .expect("parses");
        let red = grade_envelope(&env, &wrong, &root);

        std::fs::remove_dir_all(&root).ok();
        assert!(
            green.is_empty(),
            "a future corpus must be gradeable with no change to the grader: {green:?}"
        );
        assert!(
            !red.is_empty(),
            "a future corpus must also be FALSIFIABLE with no change to the grader"
        );
    }
}
