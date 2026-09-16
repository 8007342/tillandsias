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
    /// The ANSWER PROSE to build the envelope from, when the case needs to
    /// control it. Omitted by default, which keeps the grader synthesising one
    /// exactly as before.
    ///
    /// ORDER 865-h4tn — WITHOUT THIS THE SUITE CANNOT EXPRESS A REFUSAL.
    /// `spec::build_envelope` keeps a chunk only if the answer CONTAINS that
    /// chunk's key (spec.rs:1079) and refuses only when none survive
    /// (spec.rs:1095). The synthesised answer, `spec::retrieval_only_answer`,
    /// emits one `- {key} [path:start-end]` line per chunk — so it contains
    /// EVERY key by construction, every chunk always survives, and no case can
    /// ever grade `unsupported`, whatever it asks.
    ///
    /// Measured before this field existed: "what is the flibber flobber
    /// protocol and how do I bake sourdough", run through the grader's own
    /// answer construction over the real index, graded `retrieved` — citing
    /// `fn basic_recipe()` in the VM layer and a Windows smoke-test recipe,
    /// because "recipe" sits near "sourdough". The expert offered a function
    /// that builds a VM image as evidence about baking bread and the harness
    /// called it a pass.
    ///
    /// In production the prose comes from a real model, which may legitimately
    /// answer without echoing an identifier — that is how `unsupported` is
    /// reachable at all. Substituting a constant chosen to always satisfy the
    /// check under test made the one behaviour the suite most needed to pin the
    /// one behaviour it could not exercise.
    #[serde(default)]
    pub answer: Option<String>,
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

/// The result of grading one case. `failures` EMPTY and `stale` EMPTY means PASS.
#[derive(Debug)]
pub struct Outcome {
    pub id: String,
    pub engine: String,
    pub failures: Vec<String>,
    /// ORDER 1229-2862 — citations that are SOUND at the frame they were read
    /// in and wrong in this checkout. A third outcome beside pass and fail,
    /// accounted exactly the way 888-miiy accounts a skip: named per case,
    /// counted in the summary, and counted in the denominator.
    ///
    /// NOT A PASS: the answer really is unusable here, and calling it green
    /// would certify line numbers a reader cannot follow. NOT A FAIL either:
    /// nothing is wrong with the answer, the index is behind the code, and
    /// reddening for a host artifact is the false red this order removes.
    pub stale: Vec<String>,
}

impl Outcome {
    /// Graded and green. A stale case is NOT passed — see [`Outcome::stale`].
    pub fn passed(&self) -> bool {
        self.failures.is_empty() && self.stale.is_empty()
    }

    /// Purely stale: no genuine failure, at least one stale citation.
    ///
    /// REAL FAILURES DOMINATE, and that asymmetry is load-bearing. If a case
    /// with both a genuine failure and a stale citation counted as STALE, a
    /// stale index would become a place for real regressions to hide — worse
    /// than the false red this order exists to remove, because a false red at
    /// least says something is wrong.
    pub fn is_stale(&self) -> bool {
        self.failures.is_empty() && !self.stale.is_empty()
    }
}

/// What grading one case found, separated by KIND (order 1229-2862).
#[derive(Debug, Default)]
pub struct GradeFindings {
    pub failures: Vec<String>,
    pub stale: Vec<String>,
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
    // DELEGATES, and folds the two buckets back together. Callers on this
    // signature keep EXACTLY today's strictness: a stale citation was reported
    // as a failure before 1229-2862 and still is here. Separating the two is
    // opt-in via `grade_envelope_audited`, so this cannot become a fail-open
    // door for a caller that has not been taught the difference.
    let found = grade_envelope_audited(envelope, expect, root);
    let mut all = found.failures;
    all.extend(found.stale);
    all
}

/// Grade ONE envelope, separating genuine failures from frame-stale citations
/// (order 1229-2862).
///
/// The argument contract above is unchanged and deliberately so — no corpus, no
/// ledger, no engine. Only the RETURN is richer, which is the 920-pxg6 move
/// next door: a sibling that carries what the older form had nowhere to put.
pub fn grade_envelope_audited(envelope: &Envelope, expect: &Expect, root: &Path) -> GradeFindings {
    // 1232-wire3: one view per graded envelope. GitView::run is fail-soft by
    // construction — git missing, root not a repository, object unfetched all
    // yield None — so building it can never turn a gradeable case into an error.
    let view = crate::gitref::GitView::new(root);
    let mut stale: Vec<String> = Vec::new();
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
            // ORDER 1232-wire3. BEFORE CALLING THIS A FAILURE, ASK THE FRAME.
            //
            // `citation_matches` reads the WORKING TREE, so an index published
            // before the code moved fails an expectation that is satisfied at
            // the commit the span was actually extracted from. Measured on
            // macuahuitl-fedora 2026-09-16: spec-inference-tier-mechanism-is-in-code
            // reported "no citation satisfies {... span_contains=fn
            // effective_inference_tier ...}" while BOTH needles were present in
            // the cited span at 5bef283cb, the index's own commit. The same
            // citation was simultaneously "(also stale)" to the verifier and a
            // hard miss to this matcher, and that disagreement is the tell that
            // one of the two was reading the wrong bytes.
            //
            // THIS CANNOT MAKE A RED CASE GREEN. It only moves a finding from
            // `failures` to `stale`, and only when the needles are genuinely
            // present at a frame that resolves. An expectation wrong at every
            // commit, and one whose frame cannot be consulted at all, both stay
            // failures — citation_matches_at_frame collapses those two into Err
            // deliberately, because an unanswerable question is not an acquittal.
            let rescued = cited.iter().find_map(|c| {
                citation_matches_at_frame(c, want, envelope, &view)
                    .ok()
                    .map(|frame| (c, frame))
            });
            match rescued {
                Some((c, frame)) => stale.push(format!(
                    "{}:{}-{}: satisfies {} at {} — but NOT in this checkout; THIS SPAN MOVED, the expectation is sound and the index is behind the code",
                    c.path(),
                    c.line_start(),
                    c.line_end(),
                    want.render(),
                    &frame[..frame.len().min(12)],
                )),
                None => failures.push(format!(
                    "no citation satisfies {} — cited: [{}]{}",
                    want.render(),
                    summarize(cited),
                    nearest(&why)
                )),
            }
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
        // ORDER 1229-2862: `audit`, not the frame-blind `verify`.
        //
        // main.rs chose `audit` for verify-answer and said why in place — "the
        // reader-side audit, not the frame-blind `verify`". Grading was left on
        // the other side of that distinction, so 801-g9nn's whole stale-vs-
        // fabricated separation was unreachable from `grade` and a sound
        // citation read through a moved file was certified as a fabrication.
        //
        // This is not a relaxation. `frame_holds` rescues a finding ONLY when
        // the span genuinely verifies at the named commit; an unresolvable
        // frame, a missing path there, or a span that was never right anywhere
        // all stay violations. Measured on yoga 2026-09-16 against the real
        // drift: correct frame -> stale; mistyped sha -> FABRICATED; a span
        // valid at no commit -> FABRICATED.
        let verdict = answer::audit(envelope, root);
        for v in verdict.violations {
            failures.push(format!("394b verify: {v}"));
        }
        for sv in verdict.stale {
            stale.push(format!("394b verify: {sv}"));
        }
    }

    GradeFindings { failures, stale }
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
    span_needles(c, m, &span)
}

/// The needle half of [`citation_matches`], against a span the caller supplies.
///
/// Split out by 1232-wire3 so the working-tree check and the frame check are
/// the SAME check over different bytes. Two copies would drift, and the drift
/// would show up as a frame rescue that accepts something HEAD would refuse.
fn span_needles(c: &Citation, m: &CitationMatch, span: &str) -> Result<(), String> {
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

/// ORDER 1232-wire3 — does this citation satisfy `m` AT ITS OWN FRAME?
///
/// `Ok(frame)` means every needle is present in the span as that commit holds
/// it: the expectation is satisfied and the READER is standing somewhere else.
/// `Err` means it is not satisfied there either, or the frame could not be
/// consulted at all — and those two collapse deliberately, because an
/// unanswerable question is not an acquittal. The caller must therefore treat
/// every `Err` as a genuine failure, which is what keeps this from laundering.
///
/// The path/kind/authority checks are NOT re-run here: they are properties of
/// the citation record, not of any file, so they cannot be stale. Only the
/// span read moves.
fn citation_matches_at_frame(
    c: &Citation,
    m: &CitationMatch,
    envelope: &Envelope,
    view: &crate::gitref::GitView,
) -> Result<String, String> {
    let Some((frame, span)) = answer::span_at_frame(c, envelope, view) else {
        return Err("no frame to consult".to_string());
    };
    span_needles(c, m, &span)?;
    Ok(frame)
}

/// ORDER 879-gidx, hoisted by 920-pxg6: the ladder itself now lives in
/// [`crate::spec_index`] (the grounded pipeline reads the same entry this
/// grader grades against). This wrapper keeps the 888-miiy distinction that
/// belongs to GRADING: an ABSENT index is a host capability gap (the case is
/// SKIPPED and named), while a STALE index stays a hard error in the loader.
fn resolve_spec_index_dir() -> Result<String, String> {
    crate::spec_index::resolve_dir().ok_or_else(|| {
        // 888-miiy: ABSENT index is a host capability gap -> the case is
        // SKIPPED and named. A STALE index (the loader's arity refusal)
        // stays a hard error.
        format!("{ENGINE_UNAVAILABLE}spec.answer needs a built index: no rung of the resolution ladder (TILLANDSIAS_SPEC_INDEX_DIR, FORGE_SPEC_INDEX_DIR, FORGE_SPEC_INDEX_ROOT, the podman volume, the checkout's target/, XDG cache) names a directory containing vectors.jsonl — scripts/spec-index-ensure.sh builds and publishes one (801-a2by)")
            .to_string()
    })
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
    /// ORDER 1229-2862 — the FRAME the loaded entry serves answers from.
    ///
    /// Cached beside the vectors it belongs to, because it is a property of the
    /// published entry and not of this process. Dropping it was the defect: the
    /// envelope then took `Freshness::for_source`, i.e. THIS CHECKOUT'S HEAD,
    /// and stamped it onto spans the index read at a different commit.
    spec_freshness: Option<crate::answer::Freshness>,
}

/// ORDER 888-miiy. Marks an engine error as a HOST CAPABILITY GAP rather than
/// a defect — the one distinction that decides whether a case is SKIPPED or the
/// whole run is a HARNESS ERROR.
///
/// The line this exists for: `spec.answer` needs a built embedding index, and a
/// host with no embedding endpoint has none. That is a fact about the HOST, not
/// about the code or the query set, and it aborted the entire glob invocation —
/// so on 2026-08-25 the release coordinator's `./build.sh --ci-full` went red on
/// one step out of 2007 for having no ollama running.
///
/// WHAT MUST *NOT* CARRY THIS PREFIX, and it is the whole safety argument: a
/// STALE index (vectors not aligned with chunks), a missing declared corpus, an
/// unknown engine, a case with no `query_vec`, unreadable data. Every one of
/// those is a real defect that a skip would hide, and every one keeps returning
/// a bare `Err` that still aborts with rc=2. "The index is wrong" and "this host
/// has no index" look similar and mean opposite things.
pub const ENGINE_UNAVAILABLE: &str = "engine-unavailable: ";

/// True when an engine error is a host capability gap (see [`ENGINE_UNAVAILABLE`]).
///
/// A function rather than a scattered `starts_with` so there is exactly one
/// place that decides, and so the sentinel cannot drift out of sync with its
/// readers.
#[must_use]
pub fn is_engine_unavailable(msg: &str) -> bool {
    msg.starts_with(ENGINE_UNAVAILABLE)
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
            spec_freshness: None,
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
            // 920-pxg6: the loader (read errors, and the arity refusal that
            // keeps a shifted pairing from grading as plausible-and-wrong)
            // lives in spec_index::SpecIndexEntry now; only the caching and
            // the ENGINE_UNAVAILABLE framing above stay grading-specific.
            let dir = resolve_spec_index_dir()?;
            let entry = crate::spec_index::SpecIndexEntry::load_dir(Path::new(&dir))?;
            // 1229-2862: TAKE THE FRAME BEFORE DESTRUCTURING. `entry.freshness()`
            // borrows the entry, so it must be read here rather than reconstructed
            // later from a path — reconstructing it from a path is precisely the
            // `Freshness::for_source` mistake this order removes.
            self.spec_freshness = Some(entry.freshness());
            self.spec_vectors = Some(entry.vectors);
            self.spec_chunks = Some(entry.chunks);
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
                // ORDER 917-6iwv: the SAME width the pipeline serves, not a
                // second literal beside it. This line read `6` while
                // pipeline::RETRIEVE_K was independently `6`; nothing compared
                // them, so the grader could certify a width no caller gets.
                // A grader measuring a configuration the product does not serve
                // is worse than no grader, because its number looks like
                // evidence.
                let top = crate::spec::top_k(&qvec, vectors, crate::pipeline::RETRIEVE_K);
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
                // 865-h4tn: a case may supply its OWN prose. The synthesised
                // fallback lists every chunk key, which is what makes the
                // retrieval-only floor deterministic — and also what made
                // `unsupported` unreachable for every case in the suite.
                let answer = match case.answer.as_deref() {
                    Some(a) => a.to_string(),
                    None => crate::spec::retrieval_only_answer(&plain),
                };
                // ORDER 1229-2862. THE FRAME IS THE INDEX'S, NOT THIS CHECKOUT'S.
                //
                // This read `build_envelope_scored(&answer, &picked, &root)`,
                // whose freshness is `Freshness::for_source(root)` — git_head_sha
                // of the checkout this process stands in (answer.rs:335). The
                // spans came out of a published entry built at a DIFFERENT commit,
                // so the envelope claimed a frame in which its own line numbers had
                // never been read. Once code moved under the index, 801-g9nn's
                // frame check re-read the span at the reader's HEAD, found the
                // wrong bytes, and reported a sound citation as FABRICATED.
                //
                // 920-pxg6 built this sibling for exactly this caller and nothing
                // ever called it from here. `entry.freshness()` is the entry's own
                // `.commit` + chunks.jsonl mtime, or the literal `unknown` for a
                // frameless entry — never a fabricated sha, and never HEAD.
                let freshness = self
                    .spec_freshness
                    .clone()
                    .expect("spec_index() caches the frame beside the vectors");
                Ok(crate::spec::build_envelope_scored_with_freshness(
                    &answer, &picked, freshness,
                ))
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
            // 1229-2862: the audited form here too, so the structure survives
            // for in-crate callers. `passed()` is unchanged for every case:
            // before, a stale citation was a failure and the case was not
            // passed; now it is stale and the case is still not passed. What
            // changes is only that the reason is no longer flattened away.
            let found = grade_envelope_audited(&envelope, &case.expect, &root);
            out.push(Outcome {
                id: case.id.clone(),
                engine: case.engine.clone(),
                failures: found.failures,
                stale: found.stale,
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

    /// ORDER 879-gidx. The macuahuitl incident replayed: a stale exact-dir
    /// override (a Windows path on a Linux host) must be SKIPPED, and the
    /// durable tier's published entry taken instead — the override healing
    /// rather than poisoning is the entire fix.
    #[test]
    fn stale_spec_index_override_heals_to_the_durable_tier() {
        let tmp = std::env::temp_dir().join(format!("gidx-heal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let entry = tmp.join("root/abc123");
        std::fs::create_dir_all(&entry).unwrap();
        std::fs::write(entry.join("vectors.jsonl"), "[0.1]\n").unwrap();
        std::fs::write(tmp.join("root/current"), "abc123\n").unwrap();

        let got = crate::spec_index::resolve_from(
            &[(
                "FORGE_SPEC_INDEX_DIR",
                Some("/mnt/c/Users/nobody/tillandsias/target/spec-index".into()),
            )],
            &[(
                "xdg-cache",
                Some(tmp.join("root").to_string_lossy().into_owned()),
            )],
        );
        assert_eq!(
            got.as_deref(),
            Some(tmp.join("root/abc123").to_string_lossy().as_ref()),
            "the stale override must be skipped and the published entry resolved"
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// A VALID exact dir still wins over every root rung — the forge's
    /// injected read-only mount must keep its priority.
    #[test]
    fn valid_exact_dir_outranks_the_roots() {
        let tmp = std::env::temp_dir().join(format!("gidx-exact-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        let exact = tmp.join("exact");
        std::fs::create_dir_all(&exact).unwrap();
        std::fs::write(exact.join("vectors.jsonl"), "[0.1]\n").unwrap();
        let decoy = tmp.join("root/zzz");
        std::fs::create_dir_all(&decoy).unwrap();
        std::fs::write(decoy.join("vectors.jsonl"), "[0.2]\n").unwrap();
        std::fs::write(tmp.join("root/current"), "zzz\n").unwrap();

        let got = crate::spec_index::resolve_from(
            &[(
                "TILLANDSIAS_SPEC_INDEX_DIR",
                Some(exact.to_string_lossy().into_owned()),
            )],
            &[(
                "xdg-cache",
                Some(tmp.join("root").to_string_lossy().into_owned()),
            )],
        );
        assert_eq!(got.as_deref(), Some(exact.to_string_lossy().as_ref()));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// NEGATIVE CONTROL: with every rung empty or unusable the resolver
    /// returns None — the caller's needs-a-built-index refusal must still be
    /// reachable, or a missing index would grade as a mysterious read error.
    #[test]
    fn no_usable_rung_resolves_nothing() {
        assert_eq!(
            crate::spec_index::resolve_from(
                &[("FORGE_SPEC_INDEX_DIR", Some("/nonexistent/dir".into()))],
                &[("xdg-cache", Some("/also/nonexistent".into()))],
            ),
            None
        );
        assert_eq!(crate::spec_index::resolve_from(&[], &[]), None);
    }

    // ── ORDER 1229-2862: the frame the grader reads a span in ────────────────

    /// The world macuahuitl-fedora measured on 2026-09-16: an index published
    /// at commit `a`, code that moved at commit `b`, and a reader at `b`.
    fn repo_where_the_span_moves(tag: &str) -> (crate::gitref::testrepo::Repo, String, String) {
        let r = crate::gitref::testrepo::repo(tag);
        r.write(
            "openspec/specs/x/spec.md",
            "intro\n## egress-default-deny\nbody\n",
        );
        let a = r.commit("a");
        // Three lines land above it, so the heading moves 2 -> 5. Nothing about
        // the content changes; only its offset does.
        r.write(
            "openspec/specs/x/spec.md",
            "new\nnew\nnew\nintro\n## egress-default-deny\nbody\n",
        );
        let b = r.commit("b");
        (r, a, b)
    }

    fn moved_span_envelope(commit: &str) -> Envelope {
        serde_json::from_value(serde_json::json!({
            "answer": "The egress-default-deny section says to deny by default.",
            "citations": [{
                "path": "openspec/specs/x/spec.md",
                "line_start": 2, "line_end": 2,
                "kind": "spec",
                "authority": { "key": "egress-default-deny" },
            }],
            "freshness": { "source_commit": commit, "indexed_at": "2026-09-14T00:00:00Z" },
            "confidence": "retrieved",
        }))
        .expect("envelope deserializes")
    }

    fn verify_only_expect() -> Expect {
        serde_json::from_value(serde_json::json!({ "confidence": "retrieved" }))
            .expect("expect deserializes")
    }

    /// THE DEFECT, GRADED. A citation sound at the index's commit and wrong in
    /// this checkout must land in `stale`, never in `failures`.
    #[test]
    fn a_span_that_moved_grades_stale_and_not_fabricated() {
        let (r, a, b) = repo_where_the_span_moves("gt-moved");
        r.checkout(&b); // the reader is ahead of the index

        let found =
            grade_envelope_audited(&moved_span_envelope(&a), &verify_only_expect(), r.path());
        assert!(
            found.failures.is_empty(),
            "a span that verifies at its own commit must not be a failure: {:?}",
            found.failures
        );
        assert_eq!(
            found.stale.len(),
            1,
            "expected exactly one stale finding: {found:?}"
        );
        assert!(
            found.stale[0].contains("VERIFIES at"),
            "the stale finding must say where it does hold: {:?}",
            found.stale
        );
    }

    /// NEGATIVE CONTROL: the frame must not launder a real fabrication. Same
    /// repo, same reader, same named commit — a span that is wrong THERE TOO.
    #[test]
    fn a_span_wrong_at_its_own_commit_is_still_a_failure() {
        let (r, a, b) = repo_where_the_span_moves("gt-fabricated");
        r.checkout(&b);

        let mut env = serde_json::to_value(moved_span_envelope(&a)).expect("serialize");
        env["citations"][0]["line_start"] = serde_json::json!(3);
        env["citations"][0]["line_end"] = serde_json::json!(3);
        let env: Envelope = serde_json::from_value(env).expect("envelope deserializes");

        let found = grade_envelope_audited(&env, &verify_only_expect(), r.path());
        assert!(
            found.stale.is_empty(),
            "a span that holds at NO commit must not be rescued as stale: {:?}",
            found.stale
        );
        assert!(
            !found.failures.is_empty(),
            "a fabricated citation must stay a failure"
        );
        assert!(
            found.failures.iter().any(|f| f.contains("FABRICATED")),
            "{:?}",
            found.failures
        );
    }

    /// The OLD signature keeps exactly today's strictness: a stale citation was
    /// a failure before this order and is still one through `grade_envelope`.
    /// Without this, separating the buckets would silently relax every caller
    /// that was never taught the third outcome.
    #[test]
    fn the_unaudited_signature_still_reports_a_stale_citation() {
        let (r, a, b) = repo_where_the_span_moves("gt-folded");
        r.checkout(&b);

        let failures = grade_envelope(&moved_span_envelope(&a), &verify_only_expect(), r.path());
        assert_eq!(
            failures.len(),
            1,
            "the folded form must still surface it: {failures:?}"
        );
    }

    /// A case carrying BOTH a genuine failure and a stale citation is a FAIL.
    /// If it graded STALE, a stale index would become somewhere real
    /// regressions sit quietly — worse than the false red this order removes.
    #[test]
    fn a_real_failure_dominates_a_stale_citation() {
        let outcome = Outcome {
            id: "x".into(),
            engine: "spec.answer".into(),
            failures: vec!["394b verify: something genuinely wrong".into()],
            stale: vec!["394b verify: ... VERIFIES at abc123".into()],
        };
        assert!(!outcome.passed(), "not a pass");
        assert!(
            !outcome.is_stale(),
            "a case with a genuine failure must grade FAIL, not STALE"
        );
    }

    /// WIRE 2, AT THE CALLER. The spec.answer engine must stamp the INDEX's
    /// frame, not this checkout's HEAD.
    ///
    /// Deliberately NOT a test that hands `build_envelope_scored_with_freshness`
    /// a freshness and checks it comes back: the defect was a CALLER picking the
    /// wrong subject, and a test that supplies the subject is green by
    /// construction. This one drives `Harness::run` and reads the frame off the
    /// envelope that comes out, which is the only place the caller's choice is
    /// observable.
    #[test]
    fn the_spec_engine_stamps_the_index_frame_not_the_readers_head() {
        let r = crate::gitref::testrepo::repo("gt-frame");
        r.write(
            "openspec/specs/x/spec.md",
            "intro\n## egress-default-deny\nbody\n",
        );
        let head = r.commit("a");

        // A published entry whose commit is NOT this checkout's HEAD.
        const INDEX_COMMIT: &str = "5bef283cb08e23b80cd8c4e761f38158decc370d";
        assert_ne!(INDEX_COMMIT, head, "the fixture must differ from HEAD");
        let idx = r.path().join("published-index");
        std::fs::create_dir_all(&idx).expect("mkdir index");
        let chunk = serde_json::json!({
            "id": 0,
            "path": "openspec/specs/x/spec.md",
            "line_start": 2, "line_end": 2,
            "kind": "spec",
            "key": "egress-default-deny",
            "content_hash": "deadbeef",
            "text": "## egress-default-deny",
        });
        std::fs::write(idx.join("chunks.jsonl"), format!("{chunk}\n")).expect("chunks");
        std::fs::write(idx.join("vectors.jsonl"), "[1.0,0.0]\n").expect("vectors");
        std::fs::write(idx.join(".commit"), format!("{INDEX_COMMIT}\n")).expect("commit marker");
        std::fs::write(r.path().join("q.json"), "[1.0,0.0]").expect("query vector");

        let case: Case = serde_json::from_value(serde_json::json!({
            "id": "frame-probe",
            "engine": "spec.answer",
            "query": "egress default",
            "query_vec": "q.json",
            "expect": { "confidence": "retrieved" },
        }))
        .expect("case deserializes");

        let prev = std::env::var("TILLANDSIAS_SPEC_INDEX_DIR").ok();
        // SAFETY: restored before this test returns; no sibling reads it.
        unsafe { std::env::set_var("TILLANDSIAS_SPEC_INDEX_DIR", &idx) };
        let mut h = Harness::new(
            r.path().to_path_buf(),
            r.path().join("plan/index.yaml"),
            "plan/index.yaml".to_string(),
        );
        let envelope = h.run(&case);
        match prev {
            Some(v) => unsafe { std::env::set_var("TILLANDSIAS_SPEC_INDEX_DIR", v) },
            None => unsafe { std::env::remove_var("TILLANDSIAS_SPEC_INDEX_DIR") },
        }

        let envelope = envelope.expect("the spec engine answers from the published entry");
        assert_eq!(
            envelope.freshness().source_commit(),
            INDEX_COMMIT,
            "the envelope must carry the INDEX's commit"
        );
        assert_ne!(
            envelope.freshness().source_commit(),
            head,
            "stamping the reader's HEAD is the 1229-2862 defect: spans read at one \
             commit were being attributed to another"
        );
    }

    // ── ORDER 1232-wire3: the EXPECTATION path's frame ───────────────────────

    /// An expectation whose span_contains needle sits in the cited span at the
    /// index's commit and NOT at the reader's HEAD. macuahuitl-fedora's
    /// remaining red, reduced to a fixture.
    #[test]
    fn an_expectation_satisfied_at_the_frame_grades_stale_not_missing() {
        let (r, a, b) = repo_where_the_span_moves("gt-expect-moved");
        r.checkout(&b);

        let expect: Expect = serde_json::from_value(serde_json::json!({
            "confidence": "retrieved",
            "verify": false,
            "citations_include": [{
                "path": "openspec/specs/x/spec.md",
                "span_contains": ["egress-default-deny"],
            }],
        }))
        .expect("expect deserializes");

        let found = grade_envelope_audited(&moved_span_envelope(&a), &expect, r.path());
        assert!(
            found.failures.is_empty(),
            "an expectation satisfied at its own frame must not be a failure: {:?}",
            found.failures
        );
        assert_eq!(found.stale.len(), 1, "{found:?}");
        assert!(
            found.stale[0].contains("THIS SPAN MOVED"),
            "{:?}",
            found.stale
        );
    }

    /// NEGATIVE CONTROL: an expectation wrong at EVERY commit stays a hard
    /// failure. Without this the frame lookup is a way to make red cases green.
    #[test]
    fn an_expectation_wrong_at_every_commit_is_still_a_failure() {
        let (r, a, b) = repo_where_the_span_moves("gt-expect-bogus");
        r.checkout(&b);

        let expect: Expect = serde_json::from_value(serde_json::json!({
            "confidence": "retrieved",
            "verify": false,
            "citations_include": [{
                "path": "openspec/specs/x/spec.md",
                "span_contains": ["a-needle-that-was-never-anywhere"],
            }],
        }))
        .expect("expect deserializes");

        let found = grade_envelope_audited(&moved_span_envelope(&a), &expect, r.path());
        assert!(
            found.stale.is_empty(),
            "must not be rescued: {:?}",
            found.stale
        );
        assert_eq!(found.failures.len(), 1, "{found:?}");
        assert!(
            found.failures[0].contains("no citation satisfies"),
            "{:?}",
            found.failures
        );
    }

    /// NEGATIVE CONTROL: an UNRESOLVABLE frame is not an acquittal. The span
    /// would satisfy the needle if the commit could be read, but it cannot be,
    /// and 801-g9nn's rule is that an unaskable question never rescues.
    #[test]
    fn an_unresolvable_frame_is_not_an_acquittal() {
        let (r, _a, b) = repo_where_the_span_moves("gt-expect-unfetched");
        r.checkout(&b);

        // A well-formed sha that names no object in this repository.
        let absent = "0123456789abcdef0123456789abcdef01234567";
        let expect: Expect = serde_json::from_value(serde_json::json!({
            "confidence": "retrieved",
            "verify": false,
            "citations_include": [{
                "path": "openspec/specs/x/spec.md",
                "span_contains": ["egress-default-deny"],
            }],
        }))
        .expect("expect deserializes");

        let found = grade_envelope_audited(&moved_span_envelope(absent), &expect, r.path());
        assert!(
            found.stale.is_empty(),
            "an unresolvable frame must not rescue: {:?}",
            found.stale
        );
        assert!(!found.failures.is_empty(), "must stay a failure");
    }

    /// The exclude path is a SAFETY property and 1232-wire3 must not touch it:
    /// "no citation may match this" is what stops a return-everything
    /// regression from satisfying the include list. A frame rescue there would
    /// let a forbidden citation through on the grounds that it is forbidden
    /// somewhere else.
    #[test]
    fn the_exclude_path_is_unchanged_by_the_frame_rescue() {
        let (r, a, b) = repo_where_the_span_moves("gt-exclude");
        r.checkout(&b);

        // Forbid what the citation carries AT ITS FRAME but not at HEAD. The
        // exclusion reads HEAD, so it must NOT fire — and it must not become
        // stale either; exclusion has no third outcome.
        let expect: Expect = serde_json::from_value(serde_json::json!({
            "confidence": "retrieved",
            "verify": false,
            "citations_exclude": [{
                "path": "openspec/specs/x/spec.md",
                "span_contains": ["egress-default-deny"],
            }],
        }))
        .expect("expect deserializes");

        let found = grade_envelope_audited(&moved_span_envelope(&a), &expect, r.path());
        assert!(
            found.stale.is_empty(),
            "exclusion has no stale outcome: {:?}",
            found.stale
        );
        assert!(
            found.failures.is_empty(),
            "the span does not match at HEAD, so the exclusion must not fire: {:?}",
            found.failures
        );
    }
}
