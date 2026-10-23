// @trace order:547
// (formerly spec:fat-spec-corpus-index — a ghost name no spec file ever
// carried; order 547 below is the owning provenance, re-pointed by 877)
//! Order 547 — network-free RAG index over the whole-spec corpus.
//!
//! One engine, split at the network boundary (per the order-544/548 design):
//! chunking, flat-vector storage, cosine top-k, and envelope construction live
//! HERE (Rust, network-free, falsifiable); embedding and synthesis happen
//! OUTSIDE the crate (shell over `/v1`). Every retrieved chunk carries the
//! [`crate::answer::Citation`] shape (`kind = spec|cheatsheet|methodology`,
//! `authority.key = <section heading>`), so [`crate::answer::verify`] applies
//! unchanged — the crate cannot emit an uncited confident answer, and a
//! synthesizer cannot smuggle in a span the checkout does not contain.
//!
//! The corpus (~950k tokens: 340 openspec specs + 266 cheatsheets + 56
//! methodology yaml) fits no model context, so the fat spec expert retrieves a
//! few cited chunks and only then synthesizes prose over them.

use crate::answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

/// One retrievable, span-addressable passage. `key` is a literal substring of
/// the passage (its section heading), so a citation built from it always
/// resolves under [`crate::answer::verify`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chunk {
    pub id: usize,
    /// Repo-relative path (POSIX separators).
    pub path: String,
    /// 1-indexed, inclusive.
    pub line_start: usize,
    /// 1-indexed, inclusive.
    pub line_end: usize,
    /// `spec` | `cheatsheet` | `methodology`.
    pub kind: String,
    /// The section heading / top-level key. Appears verbatim in the span and is
    /// used as the citation `authority.key`.
    pub key: String,
    /// Change-detection hash of the passage text (order 552 delta re-embed).
    pub content_hash: String,
    /// The passage text — what the caller embeds and feeds to synthesis.
    pub text: String,
}

/// A chunk plus its cosine similarity to the query (order 821-73es).
///
/// A WRAPPER rather than a field on [`Chunk`], for two reasons. `Chunk` derives
/// `Eq`, which `f32` cannot satisfy — and more importantly a similarity is a
/// property of one RETRIEVAL, not of the passage, so storing it on the passage
/// would put a query-dependent number into chunks.jsonl where it means nothing.
///
/// `serde(flatten)` keeps the emitted JSON shape identical to a bare chunk with
/// one extra key, so `spec-envelope`, which deserializes `Vec<Chunk>`, still
/// reads this output unchanged: serde ignores the unknown `score` key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoredChunk {
    #[serde(flatten)]
    pub chunk: Chunk,
    pub score: f32,
}

/// The per-chunk inclusion floor: a retrieved chunk scoring below it is not
/// citation-worthy. Default is the 920-pxg6 first cut; tune per-host with
/// TILLANDSIAS_RETRIEVE_MIN_SCORE (an unparseable value falls back, same as
/// the pipeline always did).
pub fn retrieve_min_score() -> f32 {
    std::env::var("TILLANDSIAS_RETRIEVE_MIN_SCORE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.45)
}

/// The coverage floor, applied to the BEST retrieved score: below it the
/// question is out of corpus coverage, whatever the per-chunk floor above
/// would keep. One scalar cannot answer both questions — measured on darwin
/// 2026-08-29 (n=30): covered best-scores 0.65-0.87, off-topic probes
/// 0.48-0.60, so the single 0.45 floor refused nothing while 0.62 refuses
/// every measured probe. Tune per-host with TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR.
pub fn refusal_floor() -> f32 {
    std::env::var("TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.62)
}

// ── ORDER 1820-m2kq: margin + lexical-overlap refusal, calibrated ───────────
//
// CALIBRATION (scripts/refusal-calibration/measure-margin-bands.sh, macuahuitl
// 2026-10-23, nomic-embed-text no prefix, live index generation at commit
// 2c19c076 — 32,251 chunks, k=8, relabelled-561 ground truth in=458 near=33
// far=70). Band means: margin (best − median of top-8) in 0.042 / near 0.030 /
// far 0.024; lexical overlap in 0.50 / near 0.34 / far 0.09.
//
//   floor-only (0.62)               in answered 450/458  near refused 4/33  far 59/70
//   + flat AND lexically silent     in answered 450/458  near refused 5/33  far 59/70
//
// THE MARGIN ALONE IS DOMINATED and stays off by default: every solo margin
// floor > 0 costs in-corpus answers before it refuses one more near miss
// (0.005: 447 in / 5 near; 0.010: 430 / 8), and at matched false-refusal a
// raised absolute floor refuses MORE out-of-corpus questions (margin 0.020 →
// 359 in / 26 out-of-corpus answered; floor 0.685 → 356 / 19). In-corpus top-k
// are often flat too — near-duplicate chunks — so flatness alone is not a
// near-miss signature. Lexical overlap alone is no better (zero-overlap:
// 444 in / 35 out vs floor 0.625: 445 / 36). Their CONJUNCTION is the one
// operating point that is no worse than the floor at equal false refusal: a
// flat top-k (margin < 0.015) whose best chunk shares none of the query's
// content words (overlap < 0.05). The gain is ONE near miss on n=33 — thin,
// recorded as such; the rule's value is that it moves no in-corpus answer.

/// Solo margin floor on best − median(top-k): 0 = off (measured dominated,
/// see the calibration block above). TILLANDSIAS_RETRIEVE_MARGIN_FLOOR.
pub const DEFAULT_MARGIN_FLOOR: f32 = 0.0;

/// The margin under which a lexically silent best chunk refuses
/// (TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN). Calibrated: 0.015 is the widest
/// value that keeps in-corpus answered at the floor rule's 450/458.
pub const DEFAULT_LEXICAL_MARGIN: f32 = 0.015;

/// The lexical-overlap floor (TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR): fraction of
/// query content terms found in the best chunk. 0.05 means "none matched" for
/// any query of up to 20 content terms.
pub const DEFAULT_LEXICAL_FLOOR: f32 = 0.05;

/// The margin is undefined on a top-k too short to have a field: with fewer
/// scores than this the margin rule abstains (the absolute floor still holds).
pub const MARGIN_MIN_K: usize = 4;

/// @trace order:1820-m2kq. The margin floor on best − median(top-k). Tune
/// per-host with TILLANDSIAS_RETRIEVE_MARGIN_FLOOR (0 disables; an
/// unparseable value falls back, like the sibling floors).
pub fn retrieve_margin_floor() -> f32 {
    std::env::var("TILLANDSIAS_RETRIEVE_MARGIN_FLOOR")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MARGIN_FLOOR)
}

/// @trace order:1820-m2kq. The lexical-overlap floor: the fraction of the
/// query's content terms that occur in the best chunk. Tune per-host with
/// TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR (0 disables).
pub fn retrieve_lexical_floor() -> f32 {
    std::env::var("TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_LEXICAL_FLOOR)
}

/// @trace order:1820-m2kq. The margin under which a lexically silent best
/// chunk refuses. Tune per-host with TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN
/// (0 disables the conjunctive rule).
pub fn retrieve_lexical_margin() -> f32 {
    std::env::var("TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_LEXICAL_MARGIN)
}

/// The refusal thresholds, read together so the pipeline and the
/// `spec-floor` arm cannot disagree about which knobs are live.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RefusalThresholds {
    /// Per-chunk citation floor (TILLANDSIAS_RETRIEVE_MIN_SCORE).
    pub min_score: f32,
    /// Absolute floor on the best score — the OUTER bound
    /// (TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR).
    pub refusal: f32,
    /// Solo floor on best − median(top-k) (TILLANDSIAS_RETRIEVE_MARGIN_FLOOR).
    pub margin: f32,
    /// Floor on query-term overlap with the best chunk
    /// (TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR) — applies only under
    /// `lexical_margin`.
    pub lexical: f32,
    /// The margin under which the lexical floor applies
    /// (TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN).
    pub lexical_margin: f32,
}

impl RefusalThresholds {
    pub fn from_env() -> Self {
        RefusalThresholds {
            min_score: retrieve_min_score(),
            refusal: refusal_floor(),
            margin: retrieve_margin_floor(),
            lexical: retrieve_lexical_floor(),
            lexical_margin: retrieve_lexical_margin(),
        }
    }

    /// The two absolute floors with the calibrated margin/lexical defaults.
    pub fn with_floors(min_score: f32, refusal: f32) -> Self {
        RefusalThresholds {
            min_score,
            refusal,
            margin: DEFAULT_MARGIN_FLOOR,
            lexical: DEFAULT_LEXICAL_FLOOR,
            lexical_margin: DEFAULT_LEXICAL_MARGIN,
        }
    }

    /// Only the absolute floors — the pre-1820 rule, the calibration baseline.
    pub fn floor_only(self) -> Self {
        RefusalThresholds {
            margin: 0.0,
            lexical: 0.0,
            lexical_margin: 0.0,
            ..self
        }
    }
}

/// Which rule refused a retrieval — named in the refusal reason so an operator
/// knows which knob to turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalRule {
    /// The best score is under the absolute refusal floor (or nothing came back).
    BelowFloor,
    /// The best score does not stand out of its own top-k: a flat neighbourhood.
    FlatMargin,
    /// The top-k is flat (margin under `lexical_margin`) AND the best chunk
    /// shares (almost) none of the query's content words.
    NoLexicalOverlap,
    /// The per-chunk floor left nothing citation-worthy.
    Starved,
}

impl RefusalRule {
    pub fn as_str(self) -> &'static str {
        match self {
            RefusalRule::BelowFloor => "below-floor",
            RefusalRule::FlatMargin => "flat-margin",
            RefusalRule::NoLexicalOverlap => "no-lexical-overlap",
            RefusalRule::Starved => "starved",
        }
    }
}

/// The typed outcome of applying the retrieval floors to ONE retrieval.
#[derive(Debug, Clone)]
pub enum FloorDecision {
    /// Covered: the citation-worthy chunks that survive the per-chunk floor.
    Keep(Vec<ScoredChunk>),
    /// Out of coverage: `best` is the highest score seen (0.0 when the
    /// retrieval was empty), for the refusal message; `rule` names which
    /// signal refused.
    OutOfCoverage { best: f32, rule: RefusalRule },
}

/// The signals the refusal rule reads off one retrieval (order 1820-m2kq).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RefusalSignals {
    pub best: f32,
    /// Median of the top-k scores (None below [`MARGIN_MIN_K`]).
    pub median: Option<f32>,
    /// best − median (None below [`MARGIN_MIN_K`]).
    pub margin: Option<f32>,
    /// Fraction of the query's content terms found in the best chunk (None
    /// when there is no query, or it has no content terms).
    pub lexical: Option<f32>,
    /// How many content terms the query has.
    pub query_terms: usize,
}

/// Query words that carry no topic, skipped by [`query_content_terms`] (one
/// whitespace-separated string so rustfmt keeps the list compact).
const STOPWORDS: &str = "\
    a about after all also am an and any are as at be been before being between both but \
    by can could did do does doing each else for from get gets got had has have having \
    here how i if in into is it its just like may me might more most must my need no not \
    of on one only or other our out over should so some something such than that the their \
    them then there these they this those to under up us use used uses using via want was \
    way we were what when where whether which while who why will with without would you \
    your tillandsias project actually anything there's what's it's don't doesn't";

fn word_tokens(s: &str) -> impl Iterator<Item = String> + '_ {
    s.split(|c: char| !(c.is_alphanumeric() || c == '\''))
        .map(|w| w.trim_matches('\'').to_lowercase())
        .filter(|w| !w.is_empty())
}

/// A crude, deterministic stem: enough to make "rollbacks"/"rollback" and
/// "caching"/"cache" meet, not a linguistic claim.
fn stem(w: &str) -> &str {
    for suf in ["ing", "ies", "es", "ed", "s"] {
        if w.len() > suf.len() + 3
            && let Some(base) = w.strip_suffix(suf)
        {
            return base;
        }
    }
    w
}

/// The query's content terms: lowercased words of 3+ characters that are not
/// stopwords, stemmed, deduplicated in first-seen order.
pub fn query_content_terms(query: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for w in word_tokens(query) {
        if w.chars().count() < 3 || STOPWORDS.split_whitespace().any(|s| s == w) {
            continue;
        }
        let s = stem(&w).to_string();
        if !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Fraction of `query`'s content terms that occur in `chunk` (text, key and
/// path). A term matches a chunk word that starts with its stem. None when the
/// query has no content terms — an empty set cannot be "zero overlap".
pub fn lexical_overlap(query: &str, chunk: &Chunk) -> Option<f32> {
    let terms = query_content_terms(query);
    if terms.is_empty() {
        return None;
    }
    let hay: std::collections::BTreeSet<String> = word_tokens(&chunk.text)
        .chain(word_tokens(&chunk.key))
        .chain(word_tokens(&chunk.path))
        .collect();
    let matched = terms
        .iter()
        .filter(|t| hay.iter().any(|w| w.starts_with(t.as_str())))
        .count();
    Some(matched as f32 / terms.len() as f32)
}

/// Median of a score slice (mean of the two middle values for even n).
fn median(scores: &[f32]) -> f32 {
    let mut v: Vec<f32> = scores.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

/// Read the refusal signals off one retrieval. `scored` is the raw top-k
/// (before the per-chunk floor), in any order.
pub fn refusal_signals(scored: &[ScoredChunk], query: Option<&str>) -> RefusalSignals {
    let top = scored.iter().max_by(|a, b| {
        a.score
            .partial_cmp(&b.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let best = top.map(|sc| sc.score).unwrap_or(0.0);
    let (median, margin) = if scored.len() >= MARGIN_MIN_K {
        let scores: Vec<f32> = scored.iter().map(|sc| sc.score).collect();
        let m = median(&scores);
        (Some(m), Some(best - m))
    } else {
        (None, None)
    };
    let query_terms = query.map(|q| query_content_terms(q).len()).unwrap_or(0);
    let lexical = match (query, top) {
        (Some(q), Some(sc)) => lexical_overlap(q, &sc.chunk),
        _ => None,
    };
    RefusalSignals {
        best,
        median,
        margin,
        lexical,
        query_terms,
    }
}

/// ORDER 821-73es — the ONE coverage decision, shared by the grounded
/// pipeline (`pipeline::run_grounded`) and the `spec-floor` CLI arm that the
/// shell spec_answer path calls, so the two surfaces cannot drift. Cosine
/// top-k ALWAYS returns k chunks; without this gate an out-of-corpus question
/// dresses k real-but-irrelevant citations as a confident answer.
///
/// SCOPE, so the number is not over-read: the floors stop the FAR band only.
/// Measured near-misses overlap the in-corpus band (824-6qxh, relabelled
/// n=561: overlap 0.2058, thresholds refuted on five axes), so near-miss
/// refusal belongs to the 853-6gz3 validation layer — a bigger floor here
/// would refuse real questions before it refused plausible-but-unanswerable
/// ones.
pub fn apply_retrieval_floors(
    scored: Vec<ScoredChunk>,
    min_score: f32,
    refusal: f32,
) -> FloorDecision {
    apply_refusal_rule(
        scored,
        None,
        &RefusalThresholds::with_floors(min_score, refusal),
    )
}

/// ORDER 1820-m2kq — the coverage decision with the margin and lexical
/// signals. The absolute floor stays the OUTER bound (checked first, so a far
/// question is refused exactly as before); the margin and lexical checks only
/// ever ADD refusals inside it. `query` is optional: without it the lexical
/// check abstains (the `spec-floor` arm called with no `--query`).
pub fn apply_refusal_rule(
    scored: Vec<ScoredChunk>,
    query: Option<&str>,
    t: &RefusalThresholds,
) -> FloorDecision {
    let sig = refusal_signals(&scored, query);
    let best = sig.best;
    if scored.is_empty() || best < t.refusal {
        return FloorDecision::OutOfCoverage {
            best,
            rule: RefusalRule::BelowFloor,
        };
    }
    if let Some(m) = sig.margin
        && m < t.margin
    {
        return FloorDecision::OutOfCoverage {
            best,
            rule: RefusalRule::FlatMargin,
        };
    }
    // Flat AND lexically silent: both weak signals together (calibrated; see
    // the block above DEFAULT_MARGIN_FLOOR). Either alone abstains.
    if let (Some(m), Some(l)) = (sig.margin, sig.lexical)
        && m < t.lexical_margin
        && l < t.lexical
    {
        return FloorDecision::OutOfCoverage {
            best,
            rule: RefusalRule::NoLexicalOverlap,
        };
    }
    let kept: Vec<ScoredChunk> = scored
        .into_iter()
        .filter(|sc| sc.score >= t.min_score)
        .collect();
    if kept.is_empty() {
        return FloorDecision::OutOfCoverage {
            best,
            rule: RefusalRule::Starved,
        };
    }
    FloorDecision::Keep(kept)
}

/// The out-of-coverage refusal reason — ONE string for both surfaces, naming
/// the measured score and both tuning knobs. `domain` is "full" for
/// whole-corpus retrieval.
pub fn out_of_coverage_reason(domain: &str, best: f32, refusal: f32) -> String {
    format!(
        "nothing in the {domain} corpus is similar enough to this question (best score {best:.2} < refusal floor {refusal:.2}) — likely out of coverage; TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR (coverage) and TILLANDSIAS_RETRIEVE_MIN_SCORE (per-chunk) tune the floors"
    )
}

/// ORDER 1820-m2kq — the refusal reason for whichever rule fired. The
/// absolute-floor and starved cases keep [`out_of_coverage_reason`]'s exact
/// string; the margin and lexical cases name their own knob.
pub fn refusal_reason(domain: &str, best: f32, rule: RefusalRule, t: &RefusalThresholds) -> String {
    match rule {
        RefusalRule::BelowFloor | RefusalRule::Starved => {
            out_of_coverage_reason(domain, best, t.refusal)
        }
        RefusalRule::FlatMargin => format!(
            "the best {domain}-corpus match (score {best:.2}) does not stand out of its own top-k (margin over the median < {:.2}) — a flat neighbourhood, likely a near miss out of coverage; TILLANDSIAS_RETRIEVE_MARGIN_FLOOR tunes it (0 disables)",
            t.margin
        ),
        RefusalRule::NoLexicalOverlap => format!(
            "the best {domain}-corpus match (score {best:.2}) shares none of the question's content words (overlap < {:.2}) inside a flat top-k (margin < {:.2}) — topically close, specifically silent, likely a near miss out of coverage; TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR and TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN tune it (0 disables)",
            t.lexical, t.lexical_margin
        ),
    }
}

/// A dependency-free, non-cryptographic content hash for change detection.
fn hash_hex(s: &str) -> String {
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    format!("{:016x}", h.finish())
}

fn citation_kind_of(kind: &str) -> CitationKind {
    match kind {
        "methodology" => CitationKind::Methodology,
        "cheatsheet" => CitationKind::Cheatsheet,
        "code" => CitationKind::Code,
        _ => CitationKind::Spec,
    }
}

/// The corpus roots and the citation-kind each maps to. Kept as data so a new
/// corpus is one row, not a code change.
pub const CORPUS_ROOTS: &[(&str, &str)] = &[
    ("openspec/specs", "spec"),
    ("cheatsheets", "cheatsheet"),
    ("docs/cheatsheets", "cheatsheet"),
    ("methodology", "methodology"),
    // Order 803-su4n. Code was the one corpus the expert could not see, and it
    // is the corpus agents actually ask about: of the questions that consumed a
    // whole session on macuahuitl — how the inference tier is chosen, what a
    // podman mock returns, why a preflight conflated timeout with exec failure
    // — every single one was code, so the L1 expert was structurally absent for
    // exactly the class of question that cost the most hours.
    //
    // NOTE for anyone adding the next root: the comment above says a new corpus
    // is "one row, not a code change". That is true for prose and FALSE for
    // code. A bare row inherits want_ext=["md"] and chunk_markdown, so `crates`
    // would have matched zero files and silently indexed nothing — the failure
    // would have looked like an empty result, not an error.
    ("crates", "code"),
    ("scripts", "code"),
    // The third root the packet named, and the one that carried its own
    // worked example. 803-su4n's Q2 scorecard says the tier MECHANISM is
    // invisible because "entrypoint.sh:165 reads TILLANDSIAS_INFERENCE_TIER" is
    // code — and that file is `images/inference/entrypoint.sh`, which lives
    // under neither `crates` nor `scripts`. Indexing those two roots answered
    // the question from the HOST side (the Rust launcher) and left the
    // CONTAINER side, the literal line the packet cited, still unretrievable.
    ("images", "code"),
];

/// Maps each corpus root to its domain name. Domains enable per-domain RAG
/// indexes so that, e.g., a cheatsheet expert is not influenced by code and
/// vice versa. Used by `--domain` filtering in spec-index and spec-retrieve.
pub const CORPUS_DOMAINS: &[(&str, &str)] = &[
    ("cheatsheets", "cheatsheet"),
    ("docs/cheatsheets", "cheatsheet"),
    ("openspec/specs", "spec"),
    ("methodology", "methodology"),
    ("crates", "code"),
    ("scripts", "code"),
    ("images", "code"),
];

/// Resolve a corpus root to its domain name.
pub fn domain_of_root(root: &str) -> &'static str {
    CORPUS_DOMAINS
        .iter()
        .find(|(r, _)| *r == root)
        .map(|(_, d)| *d)
        .unwrap_or("unknown")
}

/// Paths pruned from the corpus even though they sit under a root.
///
/// `images/default/cheatsheets/` is a BYTE-IDENTICAL copy of `cheatsheets/`
/// (verified with `diff -rq`: it is staged into the forge image at build time),
/// and `cheatsheets` is already a corpus root. Indexing both would seat two
/// identical chunks at every rank — halving the useful width of a top-k, since
/// the second slot teaches the synthesizer nothing the first did not — and pay
/// the embed bill twice for it.
///
/// TODAY THIS PRUNE REMOVES NOTHING, and that is stated rather than hidden: the
/// copy is markdown-only and the `code` kind wants `rs`/`sh`, so the extension
/// filter already excludes it by accident. The prune is here so the day someone
/// widens `want_ext` — or adds an `("images", "cheatsheet")` row — the
/// duplication stays a decision instead of a silent regression. Its test is
/// therefore written against [`is_pruned`], the RULE, not against the corpus: a
/// corpus-level assertion passes vacuously today and so proves nothing (that is
/// not a guess — the first version of this test survived emptying the list).
const CORPUS_PRUNE_PREFIXES: &[&str] = &["images/default/cheatsheets/"];

/// Is this repo-relative path excluded from the corpus by [`CORPUS_PRUNE_PREFIXES`]?
fn is_pruned(rel: &str) -> bool {
    CORPUS_PRUNE_PREFIXES.iter().any(|p| rel.starts_with(p))
}

/// Extension-less filenames that are still code. A Containerfile is the build
/// recipe for an image and is the best answer in the tree to "what is actually
/// in this container" — and it has no extension at all, so an extension-only
/// walker silently misses every one of them.
const CORPUS_CODE_FILENAMES: &[&str] = &["Containerfile", "Dockerfile"];

/// Extensions the `code` corpora index. ORDER 810-k8jy.
///
/// `ps1` and `hcl` were added 2026-08-22. Both already lived INSIDE a code root
/// — 7 PowerShell files under `scripts/`, 14 HCL under `images/` — and were
/// excluded by nothing but this list, which is what made the gap invisible: the
/// walker returns them as "no files matched" rather than as "declined".
///
/// ps1 is the whole Windows build and install surface (install-windows.ps1,
/// build-windows-tray.ps1). 803-su4n's argument for indexing code at all was
/// that the questions costing the most hours were code questions; Windows
/// questions are code questions, and the fleet-rejoin plan has Windows coming
/// back. Its chunking works by accident and the accident is worth naming:
/// `code_boundary`'s shell branch already accepts `function name`, which is
/// PowerShell's exact syntax.
///
/// hcl is the Vault policy set — the only place "what is this role actually
/// allowed to do" is written down. It gets NO boundary detection (`path "x" {`
/// matches neither the Rust nor the shell rule), so an HCL file becomes one
/// span subdivided by the character budget. That is imperfect and it is still
/// strictly better than absent: bounded, retrievable, and honest about which
/// file it came from.
/// SELinux policy — `te` (type enforcement), `fc` (file contexts), `if`
/// (interfaces), `cil`. Six files, and the third class 810-k8jy named by hand.
/// Same argument as hcl: this is where "what is this container actually
/// permitted to do" is written, and it is written nowhere else. Also no
/// boundary detection, so each becomes one budget-bounded span.
const CORPUS_CODE_EXTS: &[&str] = &["rs", "sh", "ps1", "hcl", "fish", "te", "fc", "if", "cil"];

/// File classes DELIBERATELY not indexed, with the reason. ORDER 810-k8jy.
///
/// The packet's deliverable is "either a boundary rule per remaining file
/// class, or a recorded decision that the class is not worth retrieving — the
/// point is that the gap stops being invisible". This list is the second half.
/// scripts/check-corpus-coverage.sh reads it, so a class that is neither
/// indexed nor declined shows up as a question instead of as silence.
///
/// Each of these is a judgement, not a fact, and each can be reversed by moving
/// its extension into [`CORPUS_CODE_EXTS`] and deleting the row.
pub const CORPUS_DECLINED: &[(&str, &str)] = &[
    (
        "toml",
        "dependency manifests and locale tables. Cargo.toml is version pins, \
         which cosine similarity answers worse than reading the file; and \
         locales/*.toml ships in ZERO artifacts (792-7bt5) so indexing it would \
         retrieve strings no tray renders.",
    ),
    (
        "json",
        "configs and test fixtures — .mcp.json, litmus payloads. Structured \
         data with almost no natural-language content to embed; a question \
         about MCP registration is answered by the overlay script that WRITES \
         the json, which is already indexed.",
    ),
    (
        "txt",
        "registries, one entry per line: capabilities.txt, the brew allowlist, \
         test-known-red.txt. Embedding a list produces a vector that means \
         nothing in particular. These need REFERENTIAL-INTEGRITY gates, not \
         retrieval — and capabilities.txt already has one.",
    ),
    ("svg", "tray icons. Vector art has no prose."),
    (
        "ps1xml",
        "PowerShell formatting descriptors, generated. No prose.",
    ),
    ("png", "raster art. No prose."),
    ("icns", "macOS icon bundle. No prose."),
    ("ico", "Windows icon. No prose."),
    (
        "entitlements",
        "an Apple plist of capability booleans. The REASONS live in \
         build-macos-tray.sh and the specs, both indexed; the plist is the \
         machine-readable echo.",
    ),
    ("framework", "a macOS framework stub path, not a document."),
    (
        "manifest",
        "a Windows application manifest — XML capability declarations, same \
         shape and same reasoning as entitlements.",
    ),
    (
        "Caddyfile",
        "the reverse-proxy config. One file, and openspec/specs/\
         reverse-proxy-internal is the indexed prose that explains it.",
    ),
    (
        "conf",
        "squid.conf. Same as Caddyfile: the spec that explains it is indexed, \
         and the config is 4 directives whose meaning is not in the file.",
    ),
    (
        "rc",
        "a dotfile-shaped runtime config staged into an image. No prose.",
    ),
    (
        "base",
        "a Containerfile FROM-line fragment, meaningless in isolation.",
    ),
    ("core", "an image-layer fragment, same as base."),
    (
        "example",
        "a sample env file. Its keys are documented in the scripts that read \
         them, which are indexed.",
    ),
    (
        "template",
        "a substitution skeleton — its content is placeholders.",
    ),
    ("stamp", "a build marker, one line, generated."),
    (
        "awk",
        "one 30-line filter. Declined as a SINGLE-FILE LANGUAGE: adding an \
         extension to the corpus is cheap, but each one also widens what the \
         chunker must handle sensibly, and a lone file cannot pay for that. \
         If a second .awk appears, revisit — the coverage report will keep \
         showing the class either way.",
    ),
    (
        "c",
        "one TLS test-server fixture. Single-file language, as awk.",
    ),
    (
        "js",
        "one browser-injection shim. Single-file language, as awk.",
    ),
    ("rb", "one archive helper. Single-file language, as awk."),
];

/// Walk the whole-spec corpus under `root` and return every chunk. Missing
/// roots are skipped (an off-Tillandsias project simply has fewer corpora), not
/// an error — the same open-world discipline the ledger uses.
pub fn chunk_corpus(root: &Path) -> Vec<Chunk> {
    let mut chunks: Vec<Chunk> = Vec::new();
    let mut next_id = 0usize;
    for (rel_root, kind) in CORPUS_ROOTS {
        let dir = root.join(rel_root);
        if !dir.is_dir() {
            continue;
        }
        let want_ext: &[&str] = match *kind {
            "methodology" => &["yaml", "yml"],
            "code" => CORPUS_CODE_EXTS,
            _ => &["md"],
        };
        // Only `code` has extension-less members; a prose root asking for
        // `Containerfile` would be a bug, not a feature.
        let want_names: &[&str] = if *kind == "code" {
            CORPUS_CODE_FILENAMES
        } else {
            &[]
        };
        let mut files = walk_files(&dir, want_ext, want_names);
        files.sort(); // deterministic ordering => stable chunk ids for a given tree
        for file in files {
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let rel = to_repo_relative(root, &file);
            if is_pruned(&rel) {
                continue;
            }
            let file_chunks = match *kind {
                "methodology" => chunk_yaml(&rel, kind, &text),
                "code" => chunk_code(&rel, kind, &text),
                _ => chunk_markdown(&rel, kind, &text),
            };
            for mut c in file_chunks {
                c.id = next_id;
                next_id += 1;
                chunks.push(c);
            }
        }
    }
    chunks
}

/// Walk the corpus under `root` and return only chunks whose domain matches
/// `domain`. When `domain` is None, returns all chunks (backward compatible).
pub fn chunk_corpus_filtered(root: &Path, domain: Option<&str>) -> Vec<Chunk> {
    let all = chunk_corpus(root);
    match domain {
        None => all,
        Some(d) => all
            .into_iter()
            .filter(|c| {
                CORPUS_DOMAINS
                    .iter()
                    .any(|(r, dom)| *dom == d && c.path.starts_with(r))
            })
            .collect(),
    }
}

/// Collect files under `dir` matching either an extension in `exts` or an exact
/// basename in `names`. The `names` arm exists because the highest-value file in
/// `images/` has no extension at all (see [`CORPUS_CODE_FILENAMES`]).
fn walk_files(dir: &Path, exts: &[&str], names: &[&str]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            let ext_match = p
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|ext| exts.iter().any(|w| w.eq_ignore_ascii_case(ext)));
            let name_match = p
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| names.iter().any(|w| w.eq_ignore_ascii_case(n)));
            if ext_match || name_match {
                out.push(p);
            }
        }
    }
    out
}

fn to_repo_relative(root: &Path, file: &Path) -> String {
    let rel = file.strip_prefix(root).unwrap_or(file);
    rel.to_string_lossy().replace('\\', "/")
}

/// The heading text (`## Egress allowlist` -> `Egress allowlist`), or `None`
/// for a non-heading line. Markdown ATX headings only (`#`..`######`).
fn md_heading(line: &str) -> Option<&str> {
    let t = line.trim_start();
    if !t.starts_with('#') {
        return None;
    }
    let after = t.trim_start_matches('#');
    // Require the `#` run to be followed by a space — `#foo` is not a heading.
    if !after.starts_with(' ') {
        return None;
    }
    let h = after.trim();
    if h.is_empty() { None } else { Some(h) }
}

/// The first line of every YAML chunk's `text` (order 1822-dmwz).
///
/// A chunk cut out of the middle of a document loses what it is ABOUT: a
/// nested YAML `rule:` never says whose rule. Both rankers — the embedder and
/// BM25 — then score the passage without its subject. The breadcrumb restores
/// it: `§ <path> > <top key> > <sub key>`.
///
/// It lives IN `text`, not in a new field, so the embedding producer
/// (scripts/spec-index-ensure.sh embeds `.text`) picks it up with no change,
/// and `line_start..line_end` still addresses exactly the file span — the
/// breadcrumb is a label, never a citation. [`Chunk::body`] strips it.
///
/// MARKDOWN CHUNKS CARRY NONE, AND THAT WAS MEASURED, NOT ASSUMED. Two
/// variants were embedded with nomic-embed-text on macuahuitl 2026-10-23 —
/// the full `§ path > H1 > H2 > H3` chain, and the last two headings only —
/// and BOTH turned the gated join case `spec-forge-isolation-and-egress`
/// (openspec/litmus-tests/groundtruth/spec-rung1.yaml) red under dense-only
/// retrieval: on a short `#### Scenario:` chunk the breadcrumb is half the
/// text, the embedding moves toward the boilerplate (`… Specification >
/// Requirements > Requirement: …`) and the scenario that carries the rule
/// drops out of the top 12. With no markdown breadcrumb the case stays
/// green; the YAML breadcrumbs (the exit criterion) cost it nothing.
pub const BREADCRUMB_MARK: &str = "§ ";

/// A breadcrumb longer than this is cut: it is a label, and a label that eats
/// the YAML budget would starve the span it labels.
const MAX_BREADCRUMB_CHARS: usize = 200;

fn breadcrumb(rel_path: &str, parts: &[&str]) -> String {
    let mut s = format!("{BREADCRUMB_MARK}{rel_path}");
    for p in parts {
        s.push_str(" > ");
        s.push_str(p);
    }
    if s.chars().count() > MAX_BREADCRUMB_CHARS {
        s = s.chars().take(MAX_BREADCRUMB_CHARS).collect();
    }
    s
}

impl Chunk {
    /// The passage without its breadcrumb line — the bytes of the cited span.
    /// Chunks that carry no breadcrumb (code) are returned whole.
    pub fn body(&self) -> &str {
        if self.text.starts_with(BREADCRUMB_MARK) {
            self.text.split_once('\n').map(|(_, b)| b).unwrap_or("")
        } else {
            &self.text
        }
    }
}

/// Per-file markdown structure: which lines are REAL headings (a `#` line
/// inside a fenced code block is a shell comment, not a heading — before
/// 1822-dmwz every `# install deps` in a ```bash block opened a chunk keyed on
/// the comment, splitting the code block away from the prose that explains it).
struct MdOutline {
    heading: Vec<bool>,
}

fn md_outline(lines: &[&str]) -> MdOutline {
    let mut heading = vec![false; lines.len()];
    let mut fence: Option<&str> = None;
    // YAML front matter (`---` … `---` at the top) is metadata: its `# …`
    // lines are YAML comments. Measured: a front-matter comment in
    // cheatsheets/runtime/macos-vz-guest-boot-baseline.md ("# bundled,
    // following the crdt-ledger-fragments precedent") became a one-line H1
    // chunk that out-ranked the CRDT sheet itself for a CRDT question.
    let front_matter_end = if lines.first().is_some_and(|l| l.trim() == "---") {
        lines
            .iter()
            .skip(1)
            .position(|l| l.trim() == "---")
            .map(|p| p + 1)
    } else {
        None
    };
    for (i, l) in lines.iter().enumerate() {
        if front_matter_end.is_some_and(|end| i <= end) {
            continue;
        }
        let t = l.trim_start();
        let marker = if t.starts_with("```") {
            Some("```")
        } else if t.starts_with("~~~") {
            Some("~~~")
        } else {
            None
        };
        if let Some(m) = marker {
            match fence {
                None => fence = Some(m),
                Some(open) if open == m => fence = None,
                Some(_) => {}
            }
            continue;
        }
        if fence.is_some() {
            continue;
        }
        if md_heading(l).is_some() {
            heading[i] = true;
        }
    }
    MdOutline { heading }
}

/// An H1 whose own body is at most this many characters of real prose is a
/// TITLE CARD, not a section.
const TITLE_CARD_MAX_CHARS: usize = 400;

/// ORDER 1822-dmwz. Drop the section boundary right after a TITLE CARD — an
/// H1 whose body (blank and `@trace` lines aside) is a short lead and which is
/// followed directly by a deeper heading — so the title travels with the
/// document's first real section instead of standing alone.
///
/// Measured symptom: for "how do I run docker in the forge", retrieval cited
/// cheatsheets/runtime/forge-constraints.md lines 18-23 — the title and its
/// "Use when" line, which repeat the question's words and state no rule —
/// while the rule ("There is NO docker and NO nested container daemon") sat
/// alone in the next chunk with none of the title's vocabulary. The title
/// card is what both rankers match; the first section is what the reader
/// needs. Folding gives one chunk that is both. H1 only, so the many
/// `## Requirements` / `### Requirement:` pairs in specs keep their spans.
///
/// Returns `(section start, key line)`. A folded chunk is KEYED on its first
/// real section's heading, not the title: the key is what a citation names
/// and what the cheatsheet scorer's key bonus reads, and "The three primitives
/// you actually need" is the thing cited, not "Concurrent Git".
fn fold_title_cards(heads: &[usize], lines: &[&str]) -> Vec<(usize, usize)> {
    let depth = |i: usize| {
        lines[i]
            .trim_start()
            .chars()
            .take_while(|c| *c == '#')
            .count()
    };
    let mut out = Vec::with_capacity(heads.len());
    let mut skip_next = false;
    for (n, &h) in heads.iter().enumerate() {
        if skip_next {
            skip_next = false;
            continue;
        }
        out.push((h, h));
        let Some(&next) = heads.get(n + 1) else {
            continue;
        };
        if depth(h) != 1 || depth(next) <= 1 {
            continue;
        }
        let body: usize = lines[h + 1..next]
            .iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty() && !l.starts_with("@trace"))
            .map(str::len)
            .sum();
        if body <= TITLE_CARD_MAX_CHARS {
            skip_next = true;
            if let Some(last) = out.last_mut() {
                last.1 = next;
            }
        }
    }
    out
}

/// Section chunker for Markdown: each chunk spans a heading line to the line
/// before the next heading (or EOF). Content before the first heading becomes a
/// preamble chunk keyed on the first non-empty line. `key` is always a literal
/// substring of the chunk span. No breadcrumb (see [`BREADCRUMB_MARK`]).
pub fn chunk_markdown(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let outline = md_outline(&lines);
    // Boundary line indices (0-based) where a new section starts.
    let heads: Vec<usize> = (0..lines.len()).filter(|&i| outline.heading[i]).collect();
    let starts = fold_title_cards(&heads, &lines);
    let mut chunks = Vec::new();
    // Preamble (before the first heading), if it has any non-blank content.
    let first_heading = starts.first().map(|s| s.0).unwrap_or(lines.len());
    if first_heading > 0
        && let Some(k) = lines[..first_heading].iter().find(|l| !l.trim().is_empty())
    {
        let key = distinctive_key(k.trim());
        push_chunk(&mut chunks, rel_path, kind, 1, first_heading, &key, &lines);
    }
    for (idx, &(s, key_line)) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).map(|n| n.0).unwrap_or(lines.len());
        let key = md_heading(lines[key_line]).unwrap_or("section").to_string();
        if key_line != s {
            let len: usize = lines[s..end].iter().map(|l| l.len() + 1).sum();
            if len > MAX_YAML_CHUNK_CHARS {
                // Too big to travel together: unfold, so the budget split
                // never strands the section's key outside the title's span.
                let title = md_heading(lines[s]).unwrap_or("section").to_string();
                push_chunk(&mut chunks, rel_path, kind, s + 1, key_line, &title, &lines);
                push_md_span(
                    &mut chunks,
                    rel_path,
                    kind,
                    key_line + 1,
                    end,
                    &key,
                    &lines,
                    &outline,
                );
                continue;
            }
        }
        // s is 0-based; citation lines are 1-indexed inclusive.
        //
        // ORDER 797-qv4z, third and last path. A markdown section between two
        // headings has no inner bound, so a long heading-free stretch runs past
        // the embedder's 6000-character cut exactly as the YAML and code paths
        // did.
        //
        // I DECLINED THIS ONCE, ON A BAD ESTIMATE. The stated reason was that a
        // third budget "would reshape ~20,000 chunks to recover 11,191
        // characters". Measured afterwards: a 4000-char budget touches NINE of
        // 9,357 markdown chunks — 0.1%, not 20,000. A budget only splits what
        // exceeds it, which I asserted without checking. The cost was three
        // orders of magnitude smaller than the number I refused on.
        push_md_span(
            &mut chunks,
            rel_path,
            kind,
            s + 1,
            end,
            &key,
            &lines,
            &outline,
        );
    }
    chunks
}

/// Emit `[start, end]` as markdown chunks, subdividing when a section runs past
/// [`MAX_YAML_CHUNK_CHARS`].
///
/// Splits at DEEPER headings first, so a chunk stays a coherent subsection and
/// its citation still names something a reader recognises. Only a section with
/// no inner heading falls back to line windows — that is genuinely
/// undifferentiated prose, and prose has no better seam.
#[allow(clippy::too_many_arguments)]
fn push_md_span(
    out: &mut Vec<Chunk>,
    rel_path: &str,
    kind: &str,
    line_start: usize,
    line_end: usize,
    key: &str,
    lines: &[&str],
    outline: &MdOutline,
) {
    if line_end < line_start {
        return;
    }
    let len: usize = lines[line_start - 1..line_end]
        .iter()
        .map(|l| l.len() + 1)
        .sum();
    if len <= MAX_YAML_CHUNK_CHARS {
        push_chunk(out, rel_path, kind, line_start, line_end, key, lines);
        return;
    }

    // The heading that opens this span sets the depth to beat; anything deeper
    // is a subsection of it and a legitimate cut.
    let own_depth = lines[line_start - 1]
        .chars()
        .take_while(|c| *c == '#')
        .count();
    let cuts: Vec<usize> = (line_start..line_end)
        .filter(|&i| {
            let d = lines[i].chars().take_while(|c| *c == '#').count();
            d > own_depth && outline.heading[i]
        })
        .collect();

    if !cuts.is_empty() {
        let first = cuts[0];
        if first > line_start - 1 {
            push_chunk(out, rel_path, kind, line_start, first, key, lines);
        }
        for (n, &c) in cuts.iter().enumerate() {
            let end = cuts.get(n + 1).copied().unwrap_or(line_end);
            let sub = md_heading(lines[c]).unwrap_or("section").to_string();
            push_md_span(out, rel_path, kind, c + 1, end, &sub, lines, outline);
        }
        return;
    }

    let mut s = line_start;
    while s <= line_end {
        let mut e = s;
        let mut acc = 0usize;
        while e <= line_end && acc + lines[e - 1].len() < MAX_YAML_CHUNK_CHARS {
            acc += lines[e - 1].len() + 1;
            e += 1;
        }
        if e == s {
            e = s + 1;
        }
        push_chunk(out, rel_path, kind, s, e - 1, key, lines);
        s = e;
    }
}

/// Section chunker for YAML: each chunk spans a top-level (column-0) key to the
/// line before the next top-level key. `key` is the top-level key name, a
/// literal substring of the span. `text` leads with the key breadcrumb and the
/// whole text fits [`MAX_YAML_CHUNK_CHARS_BREADCRUMBED`].
pub fn chunk_yaml(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    let mut starts: Vec<usize> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if is_top_level_key(l) {
            starts.push(i);
        }
    }
    if starts.is_empty() {
        // A yaml file with no column-0 key: keyed on the first non-blank line,
        // so nothing is silently dropped.
        if let Some(k) = lines.iter().find(|l| !l.trim().is_empty()) {
            let key = distinctive_key(k.trim());
            let mut chunks = Vec::new();
            push_yaml_span(
                &mut chunks,
                rel_path,
                kind,
                1,
                lines.len().max(1),
                &key,
                &[],
                &lines,
            );
            return chunks;
        }
        return Vec::new();
    }
    let mut chunks = Vec::new();
    for (idx, &s) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).copied().unwrap_or(lines.len());
        let key = top_level_key_name(lines[s]);
        push_yaml_span(
            &mut chunks,
            rel_path,
            kind,
            s + 1,
            end,
            &key,
            std::slice::from_ref(&key),
            &lines,
        );
    }
    chunks
}

/// The largest markdown chunk this indexer will emit, in characters.
///
/// ORDER 797-qv4z. It exists because the EMBEDDER truncates and says nothing.
/// scripts/spec-index-ensure.sh feeds the embedding endpoint
/// `((.text // "") | .[0:$max])` with max = 6000, while chunks.jsonl keeps the
/// FULL text — so an oversized chunk gets a vector built from its first 6000
/// characters and a citation that claims the whole span. Retrieval matches on a
/// prefix; the reader is shown the lot.
///
/// Measured on the live index 2026-08-22, before this fix: 129 chunks over the
/// limit holding 1,106,377 characters, of which 332,377 (30%) were never
/// embedded. The five worst were all methodology files, and
/// methodology/distributed-work.yaml — 102,265 bytes in TWO chunks — had 5.9%
/// of itself embedded. The packet recorded 11 chunks and 168,137 characters
/// when it was filed; both roughly doubled while nobody was measuring.
///
/// 4000, not 6000, so a chunk that grows slightly between index builds does not
/// silently cross the embedder's cut. The margin is the point.
///
/// YAML chunks now use the tighter [`MAX_YAML_CHUNK_CHARS_BREADCRUMBED`]; the
/// name is historical and the markdown path still reads it.
const MAX_YAML_CHUNK_CHARS: usize = 4000;

/// ORDER 1822-dmwz. Every YAML chunk — breadcrumb INCLUDED — fits this.
///
/// 4000 characters of methodology YAML is a dozen sibling rules in one vector,
/// and a small embedder averages them into a direction none of them points in;
/// the measured symptom is a flat score distribution where the right rule and
/// its neighbours tie. ~800–1200 characters is one rule with its context, and
/// the breadcrumb carries the context the cut removed.
pub const MAX_YAML_CHUNK_CHARS_BREADCRUMBED: usize = 1200;

/// Emit `[start, end]` as chunks, subdividing at deeper indentation until each
/// fits [`MAX_YAML_CHUNK_CHARS_BREADCRUMBED`] with its breadcrumb.
///
/// WHY THE OLD CODE UNDER-SPLIT: `chunk_yaml` cuts at COLUMN-0 keys only.
/// A methodology file has a handful of them, so everything beneath one becomes
/// a single chunk no matter how large — 102 KB in two pieces, while
/// openspec/specs/git-mirror-service/spec.md, of comparable size, chunked into
/// 64 because the MARKDOWN path splits on headings. The YAML path had no
/// budget at all.
///
/// Subdividing at the next indentation level keeps chunks semantically whole:
/// a nested key and its block travel together, which is what makes a citation
/// worth reading. The line-window fallback is last and deliberately crude — a
/// block with no inner keys is prose, and prose has no better seam.
#[allow(clippy::too_many_arguments)]
fn push_yaml_span(
    out: &mut Vec<Chunk>,
    rel_path: &str,
    kind: &str,
    line_start: usize,
    line_end: usize,
    key: &str,
    path_keys: &[String],
    lines: &[&str],
) {
    if line_end < line_start {
        return;
    }
    let parts: Vec<&str> = path_keys.iter().map(String::as_str).collect();
    let crumb = breadcrumb(rel_path, &parts);
    // The span budget is what the breadcrumb (and its newline) leave.
    let budget = MAX_YAML_CHUNK_CHARS_BREADCRUMBED.saturating_sub(crumb.len() + 1);
    let len: usize = lines[line_start - 1..line_end]
        .iter()
        .map(|l| l.len() + 1)
        .sum::<usize>()
        .saturating_sub(1);
    if len <= budget {
        push_chunk_with(
            out,
            rel_path,
            kind,
            line_start,
            line_end,
            key,
            lines,
            Some(&crumb),
        );
        return;
    }

    // Find the shallowest indentation INSIDE this span that yields more than
    // one key. Shallowest first keeps the pieces as large — and as coherent —
    // as the budget allows.
    for indent in [2usize, 4, 6, 8, 10, 12] {
        let mut cuts: Vec<usize> = Vec::new();
        for (i, &l) in lines.iter().enumerate().take(line_end).skip(line_start) {
            let trimmed = l.trim_start();
            if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('-') {
                continue;
            }
            if l.len() - trimmed.len() == indent && trimmed.contains(':') {
                cuts.push(i);
            }
        }
        if cuts.is_empty() {
            continue;
        }
        // The head — the parent key line and anything before the first cut —
        // stays with the parent so the block is not orphaned from its name.
        let first = cuts[0];
        if first > line_start - 1 {
            push_yaml_span(
                out, rel_path, kind, line_start, first, key, path_keys, lines,
            );
        }
        for (n, &c) in cuts.iter().enumerate() {
            let end = cuts.get(n + 1).copied().unwrap_or(line_end);
            let sub = lines[c].trim().trim_end_matches(':');
            let sub = sub.split(':').next().unwrap_or(sub).trim();
            let sub_key = format!("{key}.{sub}");
            let mut sub_path = path_keys.to_vec();
            sub_path.push(sub.to_string());
            push_yaml_span(out, rel_path, kind, c + 1, end, &sub_key, &sub_path, lines);
        }
        return;
    }

    // No inner keys: fall back to fixed line windows so an enormous prose block
    // is still embedded in full rather than truncated to its first 6000 chars.
    let mut s = line_start;
    while s <= line_end {
        let mut e = s;
        let mut acc = 0usize;
        while e <= line_end && acc + lines[e - 1].len() <= budget {
            acc += lines[e - 1].len() + 1;
            e += 1;
        }
        if e == s {
            // One line longer than the whole budget: emit it in character
            // pieces, each citing that one line, so no chunk breaks the budget.
            let line: Vec<char> = lines[s - 1].chars().collect();
            for piece in line.chunks(budget.max(1)) {
                let body: String = piece.iter().collect();
                if body.trim().is_empty() {
                    continue;
                }
                let text = format!("{crumb}\n{body}");
                out.push(Chunk {
                    id: 0,
                    path: rel_path.to_string(),
                    line_start: s,
                    line_end: s,
                    kind: kind.to_string(),
                    key: key.to_string(),
                    content_hash: hash_hex(&text),
                    text,
                });
            }
            s += 1;
            continue;
        }
        push_chunk_with(out, rel_path, kind, s, e - 1, key, lines, Some(&crumb));
        s = e;
    }
}

/// A column-0, non-comment line of the form `name:` or `name: value`.
fn is_top_level_key(line: &str) -> bool {
    if line.is_empty() {
        return false;
    }
    let b = line.as_bytes()[0];
    if b == b' ' || b == b'\t' || b == b'#' || b == b'-' {
        return false;
    }
    match line.find(':') {
        Some(pos) => {
            let name = &line[..pos];
            !name.is_empty() && !name.contains(' ')
        }
        None => false,
    }
}

fn top_level_key_name(line: &str) -> String {
    match line.find(':') {
        Some(pos) => line[..pos].trim().to_string(),
        None => line.trim().to_string(),
    }
}

/// Trim a raw line into a citation key: bounded length so it stays a realistic
/// token a synthesizer can echo, while remaining a literal substring of the
/// span it is drawn from.
fn distinctive_key(raw: &str) -> String {
    let cleaned = raw
        .trim_start_matches(['#', '-', '─', '=', ' ', '\t'])
        .trim();
    // Trailing rule characters carry no information and eat the 80-char budget
    // a banner's actual title needs. Trimming an affix keeps the key a literal
    // substring of the span, which is the invariant `verify` rests on.
    let cleaned = cleaned.trim_end_matches(['-', '─', '=', ' ', '\t']).trim();
    let cleaned = if cleaned.is_empty() {
        raw.trim()
    } else {
        cleaned
    };
    cleaned.chars().take(80).collect()
}

/// A span longer than this is split, so one 800-line function does not become
/// one un-embeddable chunk. The embedder truncates long inputs, so an oversized
/// chunk silently loses its tail — and the tail is where the interesting branch
/// usually is.
const MAX_CODE_SPAN_LINES: usize = 120;

/// Is this line the start of a named, citable code construct?
///
/// Deliberately LINE-BASED rather than a parse. A real parser would be more
/// precise and would also mean this crate can never index a language it cannot
/// parse; the corpus is a retrieval aid, not a compiler, and a boundary that is
/// occasionally one line off still lands the reader inside the right function.
/// The invariant that actually matters is the one `verify` depends on: the key
/// must be a literal substring of the span it names.
fn code_boundary(line: &str, is_rust: bool) -> bool {
    let t = line.trim_start();
    if is_rust {
        // `pub`, `pub(crate)`, `async`, `unsafe`, `const`, `default` may precede.
        let mut rest = t;
        for prefix in [
            "pub(crate) ",
            "pub(super) ",
            "pub ",
            "default ",
            "const ",
            "async ",
            "unsafe ",
            "extern ",
        ] {
            while let Some(stripped) = rest.strip_prefix(prefix) {
                rest = stripped;
            }
        }
        rest.starts_with("fn ")
            || rest.starts_with("impl ")
            || rest.starts_with("impl<")
            || rest.starts_with("struct ")
            || rest.starts_with("enum ")
            || rest.starts_with("trait ")
            || rest.starts_with("mod ")
            || rest.starts_with("macro_rules!")
    } else {
        // Shell: `name() {`, `name ()`, or `function name`.
        if t.starts_with("function ") {
            return true;
        }
        let name: String = t
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        if name.is_empty() {
            return false;
        }
        let after = t[name.len()..].trim_start();
        after.starts_with("()")
    }
}

/// Does `s` contain a run of `n` or more identical rule characters?
fn has_rule_run(s: &str, n: usize) -> bool {
    let mut run = 0usize;
    let mut last = '\0';
    for c in s.chars() {
        if c == '-' || c == '=' || c == '─' {
            if c == last {
                run += 1;
            } else {
                run = 1;
                last = c;
            }
            if run >= n {
                return true;
            }
        } else {
            run = 0;
            last = '\0';
        }
    }
    false
}

/// Is this a column-0 shell SECTION BANNER — `# ── Preload policy ──────`?
///
/// The packet asked for "function / SECTION for shell" and the first cut only
/// did functions. That is not a cosmetic gap: `images/inference/entrypoint.sh`
/// is 600 lines with exactly ONE function, so function-only chunking degraded
/// it to five fixed 120-line windows — the mid-construct citation this whole
/// packet exists to prevent, reappearing in the very file the packet cited.
/// Measured across `images` + `scripts`: 787 banner comments, and 9.1% of shell
/// chunks were landing exactly on the 120-line cap.
///
/// A TITLE IS REQUIRED. A bare `# ----------------` is a separator, and a
/// citation keyed on a row of dashes tells the reader nothing about where they
/// have been sent — which is the Q3 failure with extra steps.
fn shell_section_banner(line: &str) -> bool {
    if !line.starts_with('#') {
        return false;
    }
    let body = &line[1..];
    has_rule_run(body, 3) && body.chars().any(|c| c.is_alphabetic())
}

/// Section chunker for CODE (order 803-su4n): each chunk spans one named
/// construct — a Rust `fn`/`impl`/`struct`/`enum`/`trait`/`mod`, or a shell
/// function — from its signature to the line before the next one.
///
/// WHY BOUNDARIES AND NOT FIXED WINDOWS. A fixed window lands citations
/// mid-function, and a citation a reader cannot act on is the failure this
/// packet's own scorecard recorded (Q3: right file, wrong span, and nothing in
/// the answer signalled it). The signature line is both the boundary and the
/// key, so every citation names the thing it points at.
///
/// The FILE PREAMBLE is chunked too, and that is not an afterthought: in this
/// repo the header comment above the first function routinely carries the
/// rationale — the order number, the incident, the reason a check exists — that
/// nothing else in the tree records.
pub fn chunk_code(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    if is_containerfile(rel_path) {
        return chunk_containerfile(rel_path, kind, text);
    }
    let is_rust = rel_path.ends_with(".rs");
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }

    // (line index, opened by a section banner rather than a named construct)
    let mut marks: Vec<(usize, bool)> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if code_boundary(l, is_rust) {
            marks.push((i, false));
        } else if !is_rust && shell_section_banner(l) {
            // Shell only. Rust already has dense fn/impl boundaries (2.4% of
            // Rust chunks hit the cap, against 9.1% for shell), and a banner
            // sitting directly above a doc comment would split that doc comment
            // off the item it documents — a regression paid for a small gain.
            marks.push((i, true));
        }
    }

    // A banner that opens nothing is not a citable unit: it steals the opening
    // line of the construct beneath it and leaves a one-line chunk whose whole
    // content is a rule. Keep a banner only when it actually heads a body.
    let mut starts: Vec<usize> = Vec::new();
    for (idx, &(line_idx, is_banner)) in marks.iter().enumerate() {
        let next = marks
            .get(idx + 1)
            .map(|(n, _)| *n)
            .unwrap_or_else(|| lines.len());
        if is_banner && next.saturating_sub(line_idx) < 3 {
            continue;
        }
        starts.push(line_idx);
    }

    let mut chunks = Vec::new();
    let first = starts.first().copied().unwrap_or(lines.len());
    if first > 0 && lines[..first].iter().any(|l| !l.trim().is_empty()) {
        push_code_span(&mut chunks, rel_path, kind, 1, first, &lines);
    }
    for (idx, &s) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).copied().unwrap_or(lines.len());
        push_code_span(&mut chunks, rel_path, kind, s + 1, end, &lines);
    }
    chunks
}

// ── Containerfile ───────────────────────────────────────────────────────────

/// `Containerfile`, `Containerfile.dev`, `Dockerfile`, …
fn is_containerfile(rel_path: &str) -> bool {
    let base = rel_path.rsplit('/').next().unwrap_or(rel_path);
    CORPUS_CODE_FILENAMES
        .iter()
        .any(|n| base == *n || base.starts_with(&format!("{n}.")))
}

/// Column-0 Dockerfile instruction keywords.
const CONTAINERFILE_INSTRUCTIONS: &[&str] = &[
    "FROM",
    "RUN",
    "COPY",
    "ADD",
    "ENV",
    "ARG",
    "WORKDIR",
    "USER",
    "ENTRYPOINT",
    "CMD",
    "LABEL",
    "EXPOSE",
    "VOLUME",
    "HEALTHCHECK",
    "SHELL",
    "STOPSIGNAL",
    "ONBUILD",
    "MAINTAINER",
];

/// Would this line open a new instruction, ignoring continuation state?
/// Column 0 only — an indented `RUN` is inside a heredoc or a continuation, and
/// treating it as a boundary would cut a shell pipeline in half.
fn containerfile_instruction(line: &str) -> bool {
    if line.starts_with(' ') || line.starts_with('\t') {
        return false;
    }
    let first = line.split_whitespace().next().unwrap_or("");
    CONTAINERFILE_INSTRUCTIONS.contains(&first)
}

/// The 0-based indices of the lines that open an instruction, with
/// `\`-continuations held inside the instruction they continue.
///
/// SEPARATE FROM THE CHUNKER ON PURPOSE. `HEALTHCHECK … \` / `CMD …` puts an
/// instruction keyword at column 0 on a continuation line, and if that opened a
/// boundary the healthcheck would be cited as two unrelated halves. Coalescing
/// usually reabsorbs such a boundary, which means the bug is invisible at chunk
/// level and a chunk-level test of it passes whether the guard is there or not
/// — measured, not assumed: that test survived deleting the guard. The rule is
/// therefore asserted here, where it lives.
fn containerfile_boundaries(lines: &[&str]) -> Vec<usize> {
    let mut starts: Vec<usize> = Vec::new();
    let mut continued = false;
    for (i, l) in lines.iter().enumerate() {
        if !continued && containerfile_instruction(l) {
            starts.push(i);
        }
        continued = l.trim_end().ends_with('\\');
    }
    starts
}

/// Instructions are coalesced until a group reaches this many lines.
///
/// Measured, not guessed: `images/default/Containerfile` is 217 lines of which
/// the majority are single-line `COPY`s. One chunk per instruction would make
/// ~40 one-line chunks per image — each too small to carry meaning into an
/// embedding, and each competing for a top-k slot. Coalescing keeps a citation
/// landing on an instruction line (never mid-`RUN`) while giving the chunk
/// enough text to retrieve on.
const MIN_CONTAINERFILE_SPAN_LINES: usize = 12;

/// Section chunker for Containerfiles (order 803-su4n, third root).
///
/// A Containerfile has neither functions nor headings, so both existing
/// chunkers degrade to fixed 120-line windows on it — the mid-construct
/// citation this packet exists to prevent. The boundary here is the column-0
/// instruction, with `\`-continuations held inside their instruction so a
/// multi-line `RUN` is never split at a `&&`.
pub fn chunk_containerfile(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }
    let starts = containerfile_boundaries(&lines);

    let mut chunks = Vec::new();
    // The header comment above the first FROM is where this repo records which
    // order added an image and why — same reason the other chunkers keep it.
    let first = starts.first().copied().unwrap_or(lines.len());
    if first > 0 && lines[..first].iter().any(|l| !l.trim().is_empty()) {
        push_code_span(&mut chunks, rel_path, kind, 1, first, &lines);
    }
    let mut i = 0usize;
    while i < starts.len() {
        let group_start = starts[i];
        let mut j = i + 1;
        while j < starts.len() && starts[j] - group_start < MIN_CONTAINERFILE_SPAN_LINES {
            j += 1;
        }
        let end = starts.get(j).copied().unwrap_or(lines.len());
        push_code_span(&mut chunks, rel_path, kind, group_start + 1, end, &lines);
        i = j;
    }
    chunks
}

/// Push one code span, splitting it if it exceeds [`MAX_CODE_SPAN_LINES`].
///
/// Each piece takes its OWN key — the first non-blank line of that piece —
/// rather than inheriting the signature. Inheriting would be friendlier to read
/// and would break `verify`: the signature is not a substring of the second
/// half, so every continuation citation would fail to resolve.
fn push_code_span(
    out: &mut Vec<Chunk>,
    rel_path: &str,
    kind: &str,
    line_start: usize,
    line_end: usize,
    lines: &[&str],
) {
    let mut start = line_start;
    while start <= line_end {
        // ORDER 797-qv4z. A LINE budget does not bound CHARACTERS, and the
        // embedder cuts on characters. 120 lines of a wide shell script or a
        // comment-heavy Rust file runs well past the 6000-char truncation in
        // scripts/spec-index-ensure.sh, so the tail of the span gets a vector
        // that never saw it. Measured after the YAML fix landed: 61 .sh and
        // 52 .rs chunks were still over the cut, holding 102,710 unembedded
        // characters between them.
        //
        // So take whichever limit binds FIRST. The line cap stays because it is
        // what keeps a citation readable; the char cap is what keeps it
        // truthful.
        let mut end = std::cmp::min(start + MAX_CODE_SPAN_LINES - 1, line_end);
        let mut acc = 0usize;
        for i in start..=end {
            acc += lines[i - 1].len() + 1;
            if acc > MAX_YAML_CHUNK_CHARS && i > start {
                end = i - 1;
                break;
            }
        }
        let key = lines[start - 1..end]
            .iter()
            .find(|l| !l.trim().is_empty())
            .map(|l| distinctive_key(l.trim()))
            .unwrap_or_else(|| "section".to_string());
        push_chunk(out, rel_path, kind, start, end, &key, lines);
        start = end + 1;
    }
}

fn push_chunk(
    out: &mut Vec<Chunk>,
    rel_path: &str,
    kind: &str,
    line_start: usize,
    line_end: usize,
    key: &str,
    lines: &[&str],
) {
    push_chunk_with(out, rel_path, kind, line_start, line_end, key, lines, None);
}

/// [`push_chunk`] with an optional breadcrumb line prefixed to `text` (order
/// 1822-dmwz). The line range — the citation — is the span alone.
#[allow(clippy::too_many_arguments)]
fn push_chunk_with(
    out: &mut Vec<Chunk>,
    rel_path: &str,
    kind: &str,
    line_start: usize,
    line_end: usize,
    key: &str,
    lines: &[&str],
    crumb: Option<&str>,
) {
    if line_end < line_start {
        return;
    }
    let span = lines[line_start - 1..line_end].join("\n");
    if span.trim().is_empty() {
        return;
    }
    let span = match crumb {
        Some(c) => format!("{c}\n{span}"),
        None => span,
    };
    out.push(Chunk {
        id: 0, // assigned by chunk_corpus
        path: rel_path.to_string(),
        line_start,
        line_end,
        kind: kind.to_string(),
        key: key.to_string(),
        content_hash: hash_hex(&span),
        text: span,
    });
}

// ── cosine retrieval ────────────────────────────────────────────────────────

/// Cosine similarity. Returns 0.0 for a zero or mismatched-length vector rather
/// than NaN, so ranking never silently corrupts on a bad embedding.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for i in 0..a.len() {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na.sqrt() * nb.sqrt())
}

/// Brute-force top-k by cosine (the corpus is only a few thousand chunks, so an
/// ANN index is not yet warranted — recorded as a scaling risk in order 547).
/// Returns `(chunk_index, score)` sorted by descending score.
pub fn top_k(query: &[f32], vectors: &[Vec<f32>], k: usize) -> Vec<(usize, f32)> {
    let mut scored: Vec<(usize, f32)> = vectors
        .iter()
        .enumerate()
        .map(|(i, v)| (i, cosine(query, v)))
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(k);
    scored
}

// ── lexical channel + fusion (order 1822-dmwz) ──────────────────────────────
//
// @trace order:1822-dmwz
//
// Dense cosine alone has two measured weaknesses on this corpus. Its score
// distribution is FLAT (the right chunk and its neighbours tie within a few
// hundredths), and it BLURS exact identifiers — order tokens, script names,
// env vars, `docker` — which are precisely what agents ask with. BM25 recovers
// exact terms; reciprocal-rank fusion combines the two lists by RANK, so no
// score calibration between a cosine and a BM25 number is ever needed.
//
// Hand-rolled on purpose: the corpus is a few tens of thousands of chunks, an
// inverted index over it builds in well under a second, and the workspace
// carries no search engine dependency worth adding for that.

/// Words that carry no retrieval signal. The cheatsheet scorer's list, plus a
/// few pronouns and fillers.
const LEXICAL_STOP_WORDS: &[&str] = &[
    "what", "which", "where", "when", "why", "how", "is", "are", "was", "were", "do", "does",
    "did", "the", "a", "an", "and", "or", "in", "on", "to", "of", "for", "with", "by", "from",
    "at", "about", "can", "i", "you", "we", "my", "your", "it", "its", "this", "that", "be", "as",
    "if", "so", "there", "here", "into", "then", "than", "me", "our", "us",
];

/// Lower-cased retrieval tokens. A compound identifier is kept WHOLE
/// (`spec-index-ensure.sh`, `tillandsias_embed_model`, `1822-dmwz`) and also
/// split into its parts, so both an exact-identifier question and a
/// plain-words question match it. Path segments are tokens of their own.
pub fn lexical_tokens(s: &str) -> Vec<String> {
    fn keep(t: &str) -> bool {
        t.len() >= 2 && !LEXICAL_STOP_WORDS.contains(&t)
    }
    let mut out = Vec::new();
    let lower = s.to_lowercase();
    for raw in lower.split(|c: char| !(c.is_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'))) {
        for seg in raw.split('/') {
            let seg = seg.trim_matches(|c: char| !c.is_alphanumeric());
            if seg.is_empty() {
                continue;
            }
            if keep(seg) {
                out.push(seg.to_string());
            }
            let parts: Vec<&str> = seg
                .split(['-', '_', '.'])
                .filter(|p| !p.is_empty())
                .collect();
            if parts.len() > 1 {
                for p in parts {
                    if keep(p) {
                        out.push(p.to_string());
                    }
                }
            }
        }
    }
    out
}

const BM25_K1: f32 = 1.2;
const BM25_B: f32 = 0.75;

/// A BM25 inverted index over a fixed document list (index-aligned with the
/// chunks it was built from).
#[derive(Debug, Default)]
pub struct Bm25 {
    postings: HashMap<String, Vec<(u32, u32)>>,
    doc_len: Vec<f32>,
    avgdl: f32,
    legacy_chunks: bool,
}

impl Bm25 {
    pub fn build(docs: &[&str]) -> Self {
        let mut postings: HashMap<String, Vec<(u32, u32)>> = HashMap::new();
        let mut doc_len = Vec::with_capacity(docs.len());
        for (i, d) in docs.iter().enumerate() {
            let toks = lexical_tokens(d);
            doc_len.push(toks.len() as f32);
            let mut tf: BTreeMap<String, u32> = BTreeMap::new();
            for t in toks {
                *tf.entry(t).or_default() += 1;
            }
            for (t, n) in tf {
                postings.entry(t).or_default().push((i as u32, n));
            }
        }
        let avgdl = if doc_len.is_empty() {
            0.0
        } else {
            doc_len.iter().sum::<f32>() / doc_len.len() as f32
        };
        Bm25 {
            postings,
            doc_len,
            avgdl,
            legacy_chunks: false,
        }
    }

    /// Index chunks by their breadcrumbed text. A chunk with no breadcrumb
    /// (code) gets its path prepended, so `pipeline.rs` is a findable term.
    pub fn from_chunks(chunks: &[Chunk]) -> Self {
        let docs: Vec<String> = chunks
            .iter()
            .map(|c| {
                if c.text.starts_with(BREADCRUMB_MARK) {
                    c.text.clone()
                } else {
                    format!("{}\n{}", c.path, c.text)
                }
            })
            .collect();
        let refs: Vec<&str> = docs.iter().map(String::as_str).collect();
        let mut bm = Self::build(&refs);
        // A vocabulary probe, not an mtime: an index whose methodology chunks
        // carry no breadcrumb was chunked BEFORE 1822-dmwz (see
        // `hybrid_top_k` for why that matters).
        let has_yaml = chunks.iter().any(|c| c.kind == "methodology");
        bm.legacy_chunks = has_yaml
            && !chunks
                .iter()
                .any(|c| c.kind == "methodology" && c.text.starts_with(BREADCRUMB_MARK));
        bm
    }

    /// True when built from an index chunked before 1822-dmwz.
    pub fn legacy_chunks(&self) -> bool {
        self.legacy_chunks
    }

    pub fn len(&self) -> usize {
        self.doc_len.len()
    }

    pub fn is_empty(&self) -> bool {
        self.doc_len.is_empty()
    }

    /// The query's weighted terms: each distinct token at weight 1.0, plus
    /// indexed VARIANTS of it at 0.5 — a term sharing a ≥5-character prefix and
    /// differing by at most three trailing characters (`dockerd` ↔ `docker`,
    /// `images` ↔ `image`). A crude stemmer, but one that cannot invent a word
    /// the corpus does not contain. Sorted, so scoring is order-stable.
    fn query_terms(&self, query: &str) -> Vec<(String, f32)> {
        let mut base: Vec<String> = lexical_tokens(query);
        base.sort();
        base.dedup();
        let mut terms: BTreeMap<String, f32> = BTreeMap::new();
        for q in &base {
            terms.insert(q.clone(), 1.0);
        }
        for q in &base {
            if q.len() < 5 || q.contains(['-', '_', '.']) {
                continue;
            }
            for t in self.postings.keys() {
                if t == q || terms.contains_key(t) {
                    continue;
                }
                let (short, long) = if t.len() < q.len() { (t, q) } else { (q, t) };
                if short.len() >= 5
                    && long.len() - short.len() <= 3
                    && long.starts_with(short.as_str())
                {
                    terms.entry(t.clone()).or_insert(0.5);
                }
            }
        }
        terms.into_iter().collect()
    }

    /// The top `k` documents by BM25 for `query`, restricted to `selected`
    /// when given. Only documents sharing at least one term are returned.
    /// Sorted by descending score; ties break on the smaller index.
    pub fn rank(&self, query: &str, selected: Option<&[usize]>, k: usize) -> Vec<(usize, f32)> {
        let n = self.doc_len.len();
        if n == 0 || k == 0 {
            return Vec::new();
        }
        let mut scores = vec![0.0f32; n];
        for (term, weight) in self.query_terms(query) {
            let Some(post) = self.postings.get(&term) else {
                continue;
            };
            let df = post.len() as f32;
            let idf = (1.0 + (n as f32 - df + 0.5) / (df + 0.5)).ln();
            for &(d, tf) in post {
                let tf = tf as f32;
                let dl = self.doc_len[d as usize];
                let norm = BM25_K1 * (1.0 - BM25_B + BM25_B * dl / self.avgdl.max(1.0));
                scores[d as usize] += weight * idf * tf * (BM25_K1 + 1.0) / (tf + norm);
            }
        }
        let mut out: Vec<(usize, f32)> = match selected {
            Some(sel) => sel
                .iter()
                .filter(|&&i| i < n && scores[i] > 0.0)
                .map(|&i| (i, scores[i]))
                .collect(),
            None => scores
                .iter()
                .enumerate()
                .filter(|(_, s)| **s > 0.0)
                .map(|(i, s)| (i, *s))
                .collect(),
        };
        out.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(&b.0))
        });
        out.truncate(k);
        out
    }
}

/// The RRF constant from Cormack et al. (2009). Large enough that rank 1 and
/// rank 2 of one list do not dominate agreement between lists.
pub const RRF_K: f32 = 60.0;

/// How deep each channel's ranking goes into the fusion. Past ~50 a chunk's
/// RRF contribution (1/(60+50)) cannot lift it into a top-8 on its own.
pub const HYBRID_DEPTH: usize = 50;

/// Reciprocal-rank fusion: `score(d) = Σ 1 / (k + rank_i(d))`, ranks 1-based.
/// Deterministic: ties break on the better single-list rank, then on the
/// smaller index — never on hash or input-list order.
pub fn rrf_fuse(rankings: &[Vec<usize>], k: f32) -> Vec<(usize, f32)> {
    let ranked: Vec<Vec<(usize, usize)>> = rankings
        .iter()
        .map(|l| l.iter().enumerate().map(|(r, &id)| (id, r)).collect())
        .collect();
    rrf_fuse_ranked(&ranked, k)
}

/// Competition ranks (0-based) for a score-sorted list: equal scores share
/// the better rank, so a TIE in one channel carries no order into the fusion
/// and the other channel decides it. Without this, a dense tie would be
/// broken by corpus order and RRF would treat that accident as evidence.
pub fn tied_ranks(sorted: &[(usize, f32)]) -> Vec<(usize, usize)> {
    let mut out = Vec::with_capacity(sorted.len());
    for (pos, &(id, s)) in sorted.iter().enumerate() {
        let r = match (pos, out.last()) {
            (p, Some(&(_, prev_r))) if p > 0 && sorted[p - 1].1 == s => prev_r,
            _ => pos,
        };
        out.push((id, r));
    }
    out
}

/// [`rrf_fuse`] over explicit `(id, 0-based rank)` lists, so tied items can
/// share a rank (see [`tied_ranks`]).
pub fn rrf_fuse_ranked(rankings: &[Vec<(usize, usize)>], k: f32) -> Vec<(usize, f32)> {
    let mut acc: BTreeMap<usize, (f32, usize)> = BTreeMap::new();
    for list in rankings {
        for &(id, r) in list {
            let e = acc.entry(id).or_insert((0.0, usize::MAX));
            e.0 += 1.0 / (k + (r + 1) as f32);
            e.1 = e.1.min(r);
        }
    }
    let mut out: Vec<(usize, f32, usize)> = acc.into_iter().map(|(i, (s, b))| (i, s, b)).collect();
    out.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.2.cmp(&b.2))
            .then(a.0.cmp(&b.0))
    });
    out.into_iter().map(|(i, s, _)| (i, s)).collect()
}

/// The operational kill switch: `TILLANDSIAS_RETRIEVE_LEXICAL=0` turns the
/// BM25 channel off and [`hybrid_top_k`] returns the dense ranking unchanged —
/// a rollback that needs no rebuild, and the A/B control for measuring it.
pub fn lexical_channel_enabled() -> bool {
    std::env::var("TILLANDSIAS_RETRIEVE_LEXICAL")
        .ok()
        .as_deref()
        != Some("0")
}

/// Does the question carry an EXACT IDENTIFIER — the thing BM25 recovers and
/// a small embedder blurs? A token with an internal `-` `_` `/` `.` or `:`
/// (`spec-index-ensure.sh`, `1822-dmwz`, `TILLANDSIAS_EMBED_MODEL`,
/// `crates/x`), a token mixing letters and digits (`v0.5`, `k8s`), an
/// all-digit token of 3+ (`11434`), a camelCase token (`GetLayout`), or a
/// `backticked` span.
///
/// THE GATE APPLIES ONLY ON A LEGACY INDEX. Measured on spec-rung1 with the
/// index every host already has (chunked before this order): for the prose
/// join question "how does the forge stay isolated from the host and control
/// outbound network access?", fusing BM25 displaced dense #7
/// (openspec/specs/forge-offline/spec.md, the governing requirement) and the
/// gated case went red. On an index rebuilt with this order's chunker the
/// same fusion is green and lifts in-corpus recall, so it is ungated there.
/// A legacy index (detected by [`Bm25::legacy_chunks`], a vocabulary probe)
/// fuses only for identifier questions — so a host grading before its index
/// is rebuilt keeps every prose question byte-identical to dense-only.
pub fn query_has_identifier(query: &str) -> bool {
    if query.contains('`') {
        return true;
    }
    query.split_whitespace().any(|raw| {
        let t = raw.trim_matches(|c: char| !c.is_alphanumeric());
        if t.len() < 2 {
            return false;
        }
        let internal_sep = t
            .char_indices()
            .any(|(i, c)| i > 0 && i + 1 < t.len() && matches!(c, '-' | '_' | '/' | '.' | ':'));
        let has_digit = t.chars().any(|c| c.is_ascii_digit());
        let has_alpha = t.chars().any(|c| c.is_alphabetic());
        let all_digit_long = t.len() >= 3 && t.chars().all(|c| c.is_ascii_digit());
        let camel = t
            .chars()
            .zip(t.chars().skip(1))
            .any(|(a, b)| a.is_lowercase() && b.is_uppercase());
        internal_sep || (has_digit && has_alpha) || all_digit_long || camel
    })
}

/// Hybrid top-k over `selected`: dense cosine and BM25 rankings, each
/// [`HYBRID_DEPTH`] deep, fused by [`rrf_fuse`]. Returns `(index, COSINE)` in
/// FUSED order (with the dense head protected — see the body) — the score carried out is the cosine, so the calibrated
/// refusal floors ([`apply_retrieval_floors`]) keep their meaning; RRF decides
/// only which chunks and in what order. With no lexical hit at all the result
/// is exactly the dense ranking.
pub fn hybrid_top_k(
    query_text: &str,
    query_vec: &[f32],
    vectors: &[Vec<f32>],
    lexical: &Bm25,
    selected: &[usize],
    k: usize,
) -> Vec<(usize, f32)> {
    let mut dense: Vec<(usize, f32)> = selected
        .iter()
        .filter(|&&i| i < vectors.len())
        .map(|&i| (i, cosine(query_vec, &vectors[i])))
        .collect();
    dense.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let lex = if lexical.len() == vectors.len()
        && lexical_channel_enabled()
        && (!lexical.legacy_chunks() || query_has_identifier(query_text))
    {
        lexical.rank(query_text, Some(selected), HYBRID_DEPTH)
    } else {
        // A lexical index that is not aligned with the vectors would fuse
        // indices from two different corpora — refuse the channel, keep dense.
        Vec::new()
    };
    if lex.is_empty() {
        dense.truncate(k);
        return dense;
    }
    let cos: HashMap<usize, f32> = dense.iter().copied().collect();
    let depth = HYBRID_DEPTH.min(dense.len());
    let dense_ranked = tied_ranks(&dense[..depth]);
    let lex_ranked = tied_ranks(&lex);
    let fused = rrf_fuse_ranked(&[dense_ranked, lex_ranked], RRF_K);

    // THE DENSE HEAD IS PROTECTED. Plain RRF over a 50-deep lexical list
    // favours any chunk that appears in BOTH lists over a chunk that is
    // dense-only, however high it ranks densely. Measured on spec-rung1:
    // the code chunk holding `fn effective_inference_tier` is dense #4 and
    // absent from the BM25 top-50 (a 120-line span is long, and BM25
    // normalises by length), so plain RRF dropped it out of the top-8 in
    // favour of spec prose that merely repeats the question's words. The
    // packet's adoption rule is that recall must not drop, so the first
    // `k - slots` dense chunks are kept unconditionally and the lexical
    // channel competes, by fused rank, for the remaining `slots` only.
    let slots = lexical_slots(k);
    let mut chosen: Vec<usize> = dense.iter().take(k - slots).map(|d| d.0).collect();
    for (i, _) in &fused {
        if chosen.len() >= k {
            break;
        }
        if !chosen.contains(i) {
            chosen.push(*i);
        }
    }
    // Present the chosen set in FUSED order, so an exact-identifier hit that
    // both channels agree on leads.
    let rank_of: HashMap<usize, usize> = fused
        .iter()
        .enumerate()
        .map(|(r, (i, _))| (*i, r))
        .collect();
    chosen.sort_by_key(|i| rank_of.get(i).copied().unwrap_or(usize::MAX));
    chosen
        .into_iter()
        .map(|i| (i, cos.get(&i).copied().unwrap_or(0.0)))
        .collect()
}

/// How many of a top-`k` the lexical channel may claim beyond the protected
/// dense head: a quarter, at least one (k=8 → 2, k=5 → 1).
pub fn lexical_slots(k: usize) -> usize {
    (k / 4).max(1).min(k)
}

// ── envelope construction (verifiable) ──────────────────────────────────────

/// Build an answer envelope from `answer` prose plus the retrieved `chunks`,
/// KEEPING ONLY the citations whose key the answer text actually mentions
/// (non-decorative) — the same falsifiability the deterministic layer enforces.
/// If no citation survives, the result is [`Envelope::unsupported`], never a
/// guess. `source` drives the freshness block.
/// Build an envelope from chunks that carry their retrieval score.
///
/// Additive sibling of [`build_envelope`] (order 821-73es): existing callers —
/// the cheatsheet path, the deterministic experts — have no similarity to
/// report and keep using the unscored form, which omits the field rather than
/// inventing 1.0.
pub fn build_envelope_scored(answer: &str, scored: &[ScoredChunk], source: &Path) -> Envelope {
    build_envelope_scored_with_freshness(answer, scored, Freshness::for_source(source))
}

/// The scored builder with an EXPLICIT freshness frame (order 920-pxg6).
///
/// The grounded pipeline answers from a published index entry, whose frame is
/// the entry's own `.commit` + `chunks.jsonl` mtime (801-g9nn) — NOT anything
/// derivable from a path in this process's checkout, which is what
/// [`Freshness::for_source`] reports. Same only-if-used citation filter, same
/// downgrade-to-unsupported; the two builders cannot drift because the
/// path-taking form above delegates here.
pub fn build_envelope_scored_with_freshness(
    answer: &str,
    scored: &[ScoredChunk],
    freshness: Freshness,
) -> Envelope {
    let mut citations = Vec::new();
    for sc in scored {
        let c = &sc.chunk;
        if !answer.contains(&c.key) {
            continue;
        }
        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), c.key.clone());
        citations.push(
            Citation::new(
                c.path.clone(),
                c.line_start,
                c.line_end,
                citation_kind_of(&c.kind),
                authority,
            )
            .with_score(sc.score),
        );
    }
    if citations.is_empty() {
        return Envelope::unsupported(
            "no retrieved chunk was actually used by the answer",
            freshness,
        );
    }
    Envelope::supported(answer, citations, Confidence::Retrieved, freshness)
}

pub fn build_envelope(answer: &str, chunks: &[Chunk], source: &Path) -> Envelope {
    let freshness = Freshness::for_source(source);
    let mut citations = Vec::new();
    for c in chunks {
        // Only cite what the prose used: keeps the envelope honest and makes
        // verify() pass (claim_key must appear in the answer).
        if !answer.contains(&c.key) {
            continue;
        }
        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), c.key.clone());
        citations.push(Citation::new(
            c.path.clone(),
            c.line_start,
            c.line_end,
            citation_kind_of(&c.kind),
            authority,
        ));
    }
    if citations.is_empty() {
        return Envelope::unsupported(
            "no retrieved chunk was actually used by the answer",
            freshness,
        );
    }
    Envelope::supported(answer, citations, Confidence::Retrieved, freshness)
}

/// A retrieval-only fallback answer: a cited digest of the top chunks whose keys
/// are, by construction, present in the text — so [`build_envelope`] keeps every
/// citation and the envelope verifies without any model in the loop. This is the
/// fail-soft floor when no synthesis endpoint is reachable.
pub fn retrieval_only_answer(chunks: &[Chunk]) -> String {
    let mut s = String::from("Relevant spec sections (retrieval-only, no synthesis):\n");
    for c in chunks {
        s.push_str(&format!(
            "- {} [{}:{}-{}]\n",
            c.key, c.path, c.line_start, c.line_end
        ));
    }
    s
}

/// Answer a cheatsheet question deterministically by scoring matching sections
/// across the cheatsheet corpus and returning a verifiable answer envelope.
pub fn answer_cheatsheet_query(root: &Path, chunks: &[Chunk], query: &str) -> Envelope {
    let lower = query.to_ascii_lowercase();
    const STOP_WORDS: &[&str] = &[
        "what", "which", "where", "when", "why", "how", "is", "are", "was", "were", "do", "does",
        "did", "the", "a", "an", "and", "or", "in", "on", "to", "of", "for", "with", "by", "from",
        "at", "about", "can", "i", "you", "we", "my", "your",
    ];

    let query_tokens: Vec<&str> = lower
        .split_whitespace()
        .map(|t| t.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_')))
        .filter(|t| !t.is_empty() && t.len() > 1 && !STOP_WORDS.contains(t))
        .collect();

    if query_tokens.is_empty() {
        return Envelope::unsupported(
            "unsupported: empty query",
            Freshness::for_source(&root.join("cheatsheets")),
        );
    }

    let cheatsheet_chunks: Vec<&Chunk> = chunks.iter().filter(|c| c.kind == "cheatsheet").collect();

    if cheatsheet_chunks.is_empty() {
        return Envelope::unsupported(
            "unsupported: no cheatsheet chunks available in corpus",
            Freshness::for_source(&root.join("cheatsheets")),
        );
    }

    let mut scored: Vec<(&Chunk, usize)> = cheatsheet_chunks
        .iter()
        .map(|&c| {
            let mut score = 0usize;
            // 1822-dmwz: a chunk whose span opens on an H1 that is NOT its
            // key is a folded title card (see `fold_title_cards`): it is
            // content, so it keeps the section bonus, and its title counts
            // as heading text alongside the key.
            let first = c.body().trim_start().lines().next().unwrap_or("");
            let h1 = first.starts_with("# ").then(|| md_heading(first)).flatten();
            let folded_title = h1.filter(|h| *h != c.key);
            let key_lower = match folded_title {
                Some(t) => format!("{} {}", c.key, t).to_ascii_lowercase(),
                None => c.key.to_ascii_lowercase(),
            };
            let path_lower = c.path.to_ascii_lowercase();
            let text_lower = c.text.to_ascii_lowercase();
            let is_main_title = h1.is_some() && folded_title.is_none();

            let mut key_hits = 0usize;
            let mut text_hits = 0usize;

            for &token in &query_tokens {
                if path_lower.contains(token) {
                    score += 5;
                }
                if key_lower.contains(token) || (token.len() > 4 && key_lower.contains(&token[..4]))
                {
                    score += 25;
                    key_hits += 1;
                }
                if text_lower.contains(token)
                    || (token.len() > 4 && text_lower.contains(&token[..4]))
                {
                    score += 10;
                    text_hits += 1;
                }
            }

            if key_hits > 0 && text_hits > 0 {
                score += 25;
            }
            if !is_main_title && key_hits > 0 {
                score += 30;
            }

            (c, score)
        })
        .collect();

    scored.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.path.cmp(&b.0.path)));

    // ORDER 1822-dmwz. The heuristic above still decides WHETHER the corpus
    // answers (a chunk must reach 35), but no longer alone WHICH chunk: among
    // the chunks that pass that gate, its ranking is fused by RRF with a BM25
    // ranking, which weighs a term by its rarity and a chunk by its length —
    // the two things the flat +25/+10 scheme cannot see, and the reason a
    // short title chunk that repeats the question's words outranked the rule.
    // IDF is taken over the WHOLE cheatsheet corpus (a term's rarity is a
    // corpus property); only the gated chunks are ranked.
    let gated: Vec<(&Chunk, usize)> = scored.iter().copied().filter(|s| s.1 >= 35).collect();
    let pick = if gated.len() > 1 {
        let owned: Vec<Chunk> = cheatsheet_chunks.iter().map(|c| (*c).clone()).collect();
        let bm = Bm25::from_chunks(&owned);
        let pos: HashMap<*const Chunk, usize> = cheatsheet_chunks
            .iter()
            .enumerate()
            .map(|(i, c)| (*c as *const Chunk, i))
            .collect();
        let heur: Vec<(usize, f32)> = gated
            .iter()
            .map(|(c, s)| (pos[&(*c as *const Chunk)], *s as f32))
            .collect();
        let sel: Vec<usize> = heur.iter().map(|h| h.0).collect();
        let lex = bm.rank(query, Some(&sel), sel.len());
        let fused = rrf_fuse_ranked(&[tied_ranks(&heur), tied_ranks(&lex)], RRF_K);
        fused.first().map(|(i, _)| (cheatsheet_chunks[*i], 0usize))
    } else {
        gated.first().copied()
    };

    if let Some((best_chunk, _score)) = pick {
        let answer = format!("Section: {}\n\n{}", best_chunk.key, best_chunk.text);
        let mut authority = BTreeMap::new();
        authority.insert("key".to_string(), best_chunk.key.clone());
        let citation = Citation::new(
            best_chunk.path.clone(),
            best_chunk.line_start,
            best_chunk.line_end,
            CitationKind::Cheatsheet,
            authority,
        );
        let freshness = Freshness::for_source(&root.join(&best_chunk.path));
        Envelope::supported(answer, vec![citation], Confidence::Exact, freshness)
    } else {
        Envelope::unsupported(
            format!("unsupported: no cheatsheet section matches query {query:?}"),
            Freshness::for_source(&root.join("cheatsheets")),
        )
    }
}

/// Report every file class under a corpus root and how the indexer treats it.
/// ORDER 810-k8jy.
///
/// The packet's complaint was not that HCL and PowerShell were missing — it was
/// that their absence was INVISIBLE. `walk_files` returns "no match" for a
/// declined class and for a class nobody has considered, and those are the same
/// silence. This turns the second one into a question.
///
/// Returns `(extension, count, verdict)` sorted by count, verdict being
/// `indexed`, `declined:<reason>` or `UNCLASSIFIED`.
pub fn corpus_coverage(root: &Path) -> Vec<(String, usize, String)> {
    let mut seen: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for (rel_root, _kind) in CORPUS_ROOTS {
        let dir = root.join(rel_root);
        if !dir.is_dir() {
            continue;
        }
        let mut stack = vec![dir];
        while let Some(d) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else {
                continue;
            };
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    // target/ and .git/ are build and VCS state, never corpus.
                    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                    if name != "target" && !name.starts_with('.') {
                        stack.push(p);
                    }
                    continue;
                }
                let rel = to_repo_relative(root, &p);
                if is_pruned(&rel) {
                    continue;
                }
                let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                // Only real extensions. Two shapes are deliberately skipped
                // because reporting them is noise, not news:
                //   * a dotfile (`.gitkeep`, `.zshrc`) — Path::extension reads
                //     the whole name as an extension, so every one appears as
                //     its own class;
                //   * an extension-LESS file whose name merely contains dots
                //     (`tillandsias-headless-x86_64-unknown-linux-musl`), which
                //     reads as a `.musl` class that does not exist.
                // Extension-less files that ARE corpus members are handled by
                // CORPUS_CODE_FILENAMES, which is an exact-name list.
                if name.starts_with('.') {
                    continue;
                }
                let Some(ext) = p.extension().and_then(|x| x.to_str()) else {
                    continue;
                };
                let ext = ext.to_string();
                if ext.is_empty() || ext.contains('-') {
                    continue;
                }
                *seen.entry(ext).or_insert(0) += 1;
            }
        }
    }
    let indexed: std::collections::BTreeSet<&str> = CORPUS_CODE_EXTS
        .iter()
        .copied()
        .chain(["yaml", "yml", "md"])
        .chain(CORPUS_CODE_FILENAMES.iter().copied())
        .collect();
    let mut out: Vec<(String, usize, String)> = seen
        .into_iter()
        .map(|(ext, n)| {
            let verdict = if indexed.contains(ext.as_str()) {
                "indexed".to_string()
            } else if let Some((_, why)) = CORPUS_DECLINED.iter().find(|(e, _)| *e == ext) {
                format!("declined:{why}")
            } else {
                "UNCLASSIFIED".to_string()
            };
            (ext, n, verdict)
        })
        .collect();
    out.sort_by_key(|(_, n, _)| std::cmp::Reverse(*n));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// This package's directory in the checkout that RUNS the test, read at
    /// runtime. Compile-time `env!("CARGO_MANIFEST_DIR")` names the checkout
    /// that COMPILED the binary, and with a shared CARGO_TARGET_DIR cargo
    /// reuses that binary from another worktree, because it does not track
    /// the env-dep it set itself (1590-j20f, 1605-42nh).
    fn manifest_dir() -> PathBuf {
        PathBuf::from(
            std::env::var("CARGO_MANIFEST_DIR").expect("cargo test sets CARGO_MANIFEST_DIR"),
        )
    }

    fn floor_chunk(id: usize, score: f32) -> ScoredChunk {
        ScoredChunk {
            chunk: Chunk {
                id,
                path: "openspec/specs/x/spec.md".into(),
                line_start: 1,
                line_end: 2,
                kind: "spec".into(),
                key: format!("Requirement: k{id}"),
                content_hash: "h".into(),
                text: format!("Requirement: k{id}\nbody"),
            },
            score,
        }
    }

    /// ORDER 821-73es. A covered retrieval keeps exactly the chunks above the
    /// per-chunk floor — the below-floor tail is dropped, not refused.
    #[test]
    fn floors_keep_covered_retrieval_and_drop_below_min_chunks() {
        let scored = vec![
            floor_chunk(0, 0.80),
            floor_chunk(1, 0.50),
            floor_chunk(2, 0.30),
        ];
        match apply_retrieval_floors(scored, 0.45, 0.62) {
            FloorDecision::Keep(kept) => {
                assert_eq!(kept.len(), 2, "the 0.30 chunk must be dropped");
                assert!(kept.iter().all(|sc| sc.score >= 0.45));
            }
            FloorDecision::OutOfCoverage { best, .. } => {
                panic!("a 0.80 best is covered, got OutOfCoverage {{ best: {best} }}")
            }
        }
    }

    /// ORDER 821-73es. The sourdough shape: k real chunks, none similar
    /// enough. The decision is out-of-coverage carrying the best score, never
    /// a kept set of irrelevant-but-real citations.
    #[test]
    fn floors_refuse_when_best_is_under_the_refusal_floor() {
        let scored = vec![floor_chunk(0, 0.57), floor_chunk(1, 0.55)];
        match apply_retrieval_floors(scored, 0.45, 0.62) {
            FloorDecision::OutOfCoverage { best, .. } => {
                assert!(
                    (best - 0.57).abs() < 1e-6,
                    "best must be reported, got {best}"
                );
            }
            FloorDecision::Keep(kept) => {
                panic!("0.57 < 0.62 must refuse, kept {} chunks", kept.len())
            }
        }
    }

    /// An empty retrieval is out of coverage with best 0.0 — the same verdict
    /// the pipeline always reached via `.first().unwrap_or(0.0)`.
    #[test]
    fn floors_refuse_empty_retrieval_with_best_zero() {
        match apply_retrieval_floors(Vec::new(), 0.45, 0.62) {
            FloorDecision::OutOfCoverage { best, .. } => assert_eq!(best, 0.0),
            FloorDecision::Keep(_) => panic!("an empty retrieval must refuse"),
        }
    }

    /// A pathological min_score above the refusal floor can starve a covered
    /// retrieval; that is out-of-coverage (nothing citation-worthy survives),
    /// mirroring the pipeline's empty-scored continue.
    #[test]
    fn floors_refuse_when_min_score_starves_a_covered_retrieval() {
        let scored = vec![floor_chunk(0, 0.70)];
        match apply_retrieval_floors(scored, 0.90, 0.62) {
            FloorDecision::OutOfCoverage { best, .. } => assert!((best - 0.70).abs() < 1e-6),
            FloorDecision::Keep(_) => panic!("a starved retrieval must refuse"),
        }
    }

    fn topk(scores: &[f32]) -> Vec<ScoredChunk> {
        scores
            .iter()
            .enumerate()
            .map(|(i, s)| floor_chunk(i, *s))
            .collect()
    }

    const FLAT: [f32; 8] = [0.700, 0.698, 0.697, 0.695, 0.694, 0.692, 0.690, 0.689];
    const PEAKED: [f32; 8] = [0.800, 0.720, 0.690, 0.670, 0.660, 0.650, 0.640, 0.630];
    /// A measured near miss (relabelled-561): none of its content words occur
    /// in a `floor_chunk`.
    const SILENT_Q: &str = "When is v1.0 scheduled to ship?";
    /// Shares "spec", "requirement" and "body" with every `floor_chunk`.
    const OVERLAP_Q: &str = "What does the spec requirement body say?";

    fn defaults() -> RefusalThresholds {
        RefusalThresholds::with_floors(0.45, 0.62)
    }

    /// @trace order:1820-m2kq. A FLAT top-k — best well above the absolute
    /// floor (0.700 ≥ 0.62) but no higher than its own field (median 0.6945)
    /// — whose best chunk shares none of the question's words is the
    /// near-miss shape: topically close to a neighbourhood, specifically
    /// answered by none of it. Refused; the absolute floor alone answered it.
    #[test]
    fn margin_refusal_flat_topk_refuses() {
        let d = apply_refusal_rule(topk(&FLAT), Some(SILENT_Q), &defaults());
        assert!(
            matches!(
                d,
                FloorDecision::OutOfCoverage {
                    rule: RefusalRule::NoLexicalOverlap,
                    ..
                }
            ),
            "flat top-k + lexically silent best chunk must refuse, got {d:?}"
        );
        // ... and the floor-only rule (the pre-1820 behaviour) answered it.
        let old = apply_refusal_rule(topk(&FLAT), Some(SILENT_Q), &defaults().floor_only());
        assert!(matches!(old, FloorDecision::Keep(_)), "{old:?}");
    }

    /// @trace order:1820-m2kq. A PEAKED top-k — one chunk clearly ahead of the
    /// field (margin 0.135) — is the in-corpus shape and answers even when the
    /// wording shares nothing: dense retrieval legitimately matches synonyms.
    #[test]
    fn margin_refusal_peaked_topk_answers() {
        match apply_refusal_rule(topk(&PEAKED), Some(SILENT_Q), &defaults()) {
            FloorDecision::Keep(kept) => assert_eq!(kept.len(), 8),
            other => panic!("a peaked top-k must answer, got {other:?}"),
        }
    }

    /// @trace order:1820-m2kq. Flatness ALONE does not refuse by default —
    /// calibration measured a solo margin floor dominated (in-corpus top-k
    /// are often flat over near-duplicate chunks). A flat top-k whose best
    /// chunk carries the question's words answers.
    #[test]
    fn margin_refusal_flat_topk_with_lexical_overlap_answers() {
        let d = apply_refusal_rule(topk(&FLAT), Some(OVERLAP_Q), &defaults());
        assert!(matches!(d, FloorDecision::Keep(_)), "{d:?}");
        // No query (the spec-floor arm without --query): lexical abstains.
        let d = apply_retrieval_floors(topk(&FLAT), 0.45, 0.62);
        assert!(matches!(d, FloorDecision::Keep(_)), "{d:?}");
    }

    /// @trace order:1820-m2kq. The solo margin knob, when an operator sets
    /// it, refuses a flat top-k with no query at all.
    #[test]
    fn margin_refusal_solo_margin_knob_refuses_flat() {
        let t = RefusalThresholds {
            margin: 0.02,
            ..defaults()
        };
        let d = apply_refusal_rule(topk(&FLAT), None, &t);
        assert!(
            matches!(
                d,
                FloorDecision::OutOfCoverage {
                    rule: RefusalRule::FlatMargin,
                    ..
                }
            ),
            "{d:?}"
        );
    }

    /// @trace order:1820-m2kq. The absolute floor stays the OUTER bound and is
    /// checked first: a far question refuses as below-floor whatever its
    /// margin or overlap.
    #[test]
    fn margin_refusal_keeps_the_absolute_floor_outermost() {
        let far = topk(&[0.60, 0.40, 0.39, 0.38, 0.37]);
        match apply_refusal_rule(far, Some(OVERLAP_Q), &defaults()) {
            FloorDecision::OutOfCoverage { best, rule } => {
                assert_eq!(rule, RefusalRule::BelowFloor);
                assert!((best - 0.60).abs() < 1e-6);
            }
            other => panic!("{other:?}"),
        }
    }

    /// @trace order:1820-m2kq. Zero lexical overlap is FLAGGED as Some(0.0) —
    /// distinct from None (a query with no content terms cannot be "zero
    /// overlap"), and the signals carry the margin over the median.
    #[test]
    fn lexical_overlap_zero_is_flagged_and_signals_carry_the_margin() {
        let c = floor_chunk(0, 0.7).chunk;
        assert_eq!(lexical_overlap(SILENT_Q, &c), Some(0.0));
        assert_eq!(lexical_overlap(OVERLAP_Q, &c), Some(0.75));
        assert_eq!(lexical_overlap("what is it?", &c), None);
        assert_eq!(
            query_content_terms("Rollbacks of the rollback"),
            vec!["rollback"]
        );
        let sig = refusal_signals(&topk(&FLAT), Some(SILENT_Q));
        assert_eq!(sig.lexical, Some(0.0));
        assert_eq!(sig.query_terms, 2);
        let m = sig.margin.expect("k=8 has a margin");
        assert!((m - (0.700 - 0.6945)).abs() < 1e-4, "{m}");
        // Below MARGIN_MIN_K the margin abstains.
        let short = refusal_signals(&topk(&[0.7, 0.7, 0.7]), Some(SILENT_Q));
        assert_eq!(short.margin, None);
    }

    /// @trace order:1820-m2kq. Each rule names its own knob in the reason.
    #[test]
    fn refusal_reason_names_the_rule_that_fired() {
        let t = defaults();
        let r = refusal_reason("full", 0.70, RefusalRule::NoLexicalOverlap, &t);
        assert!(r.contains("TILLANDSIAS_RETRIEVE_LEXICAL_FLOOR"), "{r}");
        assert!(r.contains("TILLANDSIAS_RETRIEVE_LEXICAL_MARGIN"), "{r}");
        let r = refusal_reason("full", 0.70, RefusalRule::FlatMargin, &t);
        assert!(r.contains("TILLANDSIAS_RETRIEVE_MARGIN_FLOOR"), "{r}");
        let r = refusal_reason("full", 0.57, RefusalRule::BelowFloor, &t);
        assert_eq!(r, out_of_coverage_reason("full", 0.57, 0.62));
    }

    /// The refusal reason names both tuning knobs and the two scores — it is
    /// the one string the pipeline and spec-floor both serve.
    #[test]
    fn out_of_coverage_reason_names_both_knobs_and_the_scores() {
        let reason = out_of_coverage_reason("full", 0.57, 0.62);
        assert!(reason.contains("full corpus"), "{reason}");
        assert!(reason.contains("out of coverage"), "{reason}");
        assert!(reason.contains("0.57"), "{reason}");
        assert!(reason.contains("0.62"), "{reason}");
        assert!(
            reason.contains("TILLANDSIAS_RETRIEVE_REFUSAL_FLOOR"),
            "{reason}"
        );
        assert!(
            reason.contains("TILLANDSIAS_RETRIEVE_MIN_SCORE"),
            "{reason}"
        );
    }

    /// Order 920-pxg6 (R4/R5). The explicit-freshness builder keeps ONLY the
    /// citations the prose used — subset usage strips the rest — and the
    /// supplied frame passes through untouched (never a HEAD derived here).
    #[test]
    fn with_freshness_builder_keeps_only_used_citations_and_the_given_frame() {
        let chunk = |id: usize, key: &str| Chunk {
            id,
            path: "openspec/specs/x/spec.md".into(),
            line_start: 1,
            line_end: 2,
            kind: "spec".into(),
            key: key.into(),
            content_hash: "h".into(),
            text: format!("{key}\nbody"),
        };
        let scored = vec![
            ScoredChunk {
                chunk: chunk(0, "Requirement: used"),
                score: 0.9,
            },
            ScoredChunk {
                chunk: chunk(1, "Requirement: decorative"),
                score: 0.8,
            },
        ];
        let frame = Freshness::new(
            "abcdef1234567890abcdef1234567890abcdef12".to_string(),
            "2026-08-28T00:00:00Z".to_string(),
        );
        let env = build_envelope_scored_with_freshness(
            "the answer leans on Requirement: used",
            &scored,
            frame.clone(),
        );
        assert_eq!(env.citations().len(), 1, "only the used citation survives");
        assert_eq!(
            env.citations()[0]
                .authority()
                .get("key")
                .map(String::as_str),
            Some("Requirement: used")
        );
        assert_eq!(env.freshness(), &frame, "the supplied frame passes through");

        // Zero usage downgrades — prose that used nothing ships no citations.
        let env = build_envelope_scored_with_freshness("free-floating prose", &scored, frame);
        assert_eq!(env.confidence(), Confidence::Unsupported);
        assert!(env.citations().is_empty());
    }

    /// Order 821-73es. The score has to reach the CITATION, not just the
    /// retrieval output — a number that stops at the CLI is a number no
    /// consumer of the envelope can threshold on.
    #[test]
    fn a_scored_envelope_puts_the_score_on_its_citations() {
        let c = Chunk {
            id: 0,
            path: "openspec/specs/x/spec.md".into(),
            line_start: 1,
            line_end: 2,
            kind: "spec".into(),
            key: "Requirement: X".into(),
            content_hash: "h".into(),
            text: "Requirement: X\nbody".into(),
        };
        let scored = vec![ScoredChunk {
            chunk: c.clone(),
            score: 0.7196,
        }];
        let env = build_envelope_scored("uses Requirement: X", &scored, Path::new("."));
        let json = serde_json::to_string(&env).expect("serialize");
        assert!(
            json.contains("\"score\""),
            "citation carries a score: {json}"
        );
        assert!(
            json.contains("0.7196"),
            "the measured value survives: {json}"
        );

        // The UNSCORED builder must omit the field rather than invent one. A
        // deterministic expert has no similarity to report, and writing 1.0
        // would read as a perfect match instead of "not applicable".
        let plain = build_envelope("uses Requirement: X", &[c], Path::new("."));
        let pjson = serde_json::to_string(&plain).expect("serialize");
        assert!(
            !pjson.contains("score"),
            "unscored envelope invented one: {pjson}"
        );
    }

    /// A similarity outside [-1, 1] is not a similarity. Storing it would hand
    /// a future threshold a number that cannot mean what it claims.
    #[test]
    fn an_impossible_score_is_dropped_not_recorded() {
        let c = Chunk {
            id: 0,
            path: "openspec/specs/x/spec.md".into(),
            line_start: 1,
            line_end: 2,
            kind: "spec".into(),
            key: "Requirement: X".into(),
            content_hash: "h".into(),
            text: "Requirement: X".into(),
        };
        for bad in [3.0f32, -2.0, f32::NAN, f32::INFINITY] {
            let env = build_envelope_scored(
                "uses Requirement: X",
                &[ScoredChunk {
                    chunk: c.clone(),
                    score: bad,
                }],
                Path::new("."),
            );
            let json = serde_json::to_string(&env).expect("serialize");
            assert!(
                !json.contains("\"score\""),
                "kept an impossible score {bad}: {json}"
            );
        }
    }

    /// Order 821-73es. The score rides on a wrapper, and `spec-envelope`
    /// deserializes `Vec<Chunk>` from the SAME bytes — so the flattened shape
    /// must stay readable as a plain chunk. If this breaks, retrieval keeps
    /// working and the envelope silently loses every citation, which is the
    /// quietest possible regression.
    #[test]
    fn a_scored_chunk_still_deserializes_as_a_plain_chunk() {
        let c = Chunk {
            id: 7,
            path: "openspec/specs/x/spec.md".into(),
            line_start: 3,
            line_end: 9,
            kind: "spec".into(),
            key: "Requirement: X".into(),
            content_hash: "abc".into(),
            text: "body".into(),
        };
        let scored = ScoredChunk {
            chunk: c.clone(),
            score: 0.71,
        };
        let json = serde_json::to_string(&scored).expect("serialize");
        assert!(json.contains("\"score\":0.71"), "score is emitted: {json}");
        let back: Chunk = serde_json::from_str(&json).expect("reads as a plain Chunk");
        assert_eq!(back, c, "the chunk half round-trips unchanged");
    }

    /// The index must NOT gain a score column: a similarity is a property of
    /// one retrieval, not of the passage, and writing it into chunks.jsonl
    /// would make the stored corpus query-dependent.
    #[test]
    fn the_index_record_carries_no_score() {
        let chunks = chunk_markdown("openspec/specs/x/spec.md", "spec", "## H\nbody\n");
        let json = serde_json::to_string(&chunks[0]).expect("serialize");
        assert!(
            !json.contains("score"),
            "index record gained a score: {json}"
        );
    }

    /// The invariant `answer::verify` rests on, asserted for CODE: every chunk's
    /// key must appear verbatim in the span it names. This is the test that
    /// makes the long-span split safe — a continuation piece inherits no
    /// signature, so if it ever took the parent's key this would fail.
    #[test]
    fn code_chunk_keys_are_in_their_span() {
        let rust = "//! header rationale\n\nuse std::fs;\n\npub fn alpha(x: u32) -> u32 {\n    x + 1\n}\n\nimpl Beta {\n    fn inner(&self) {}\n}\n";
        let sh = "#!/usr/bin/env bash\n# why this exists\nset -eu\n\nmain() {\n  echo hi\n}\n\nhelper () {\n  echo there\n}\n";
        for (path, text) in [("crates/x/src/a.rs", rust), ("scripts/b.sh", sh)] {
            let chunks = chunk_code(path, "code", text);
            assert!(!chunks.is_empty(), "{path} produced no chunks");
            let lines: Vec<&str> = text.lines().collect();
            for c in &chunks {
                let span = lines[c.line_start - 1..c.line_end].join("\n");
                assert!(
                    span.contains(&c.key),
                    "{path}: key {:?} not in span {:?}",
                    c.key,
                    span
                );
            }
        }
    }

    #[test]
    fn code_chunks_on_named_constructs_and_keeps_the_file_preamble() {
        let rust = "//! header rationale worth citing\n\npub fn alpha() {}\n\nimpl Beta {\n    fn inner(&self) {}\n}\n";
        let chunks = chunk_code("crates/x/src/a.rs", "code", rust);
        // The preamble carries the WHY and is routinely the only place it is
        // written down, so it must be retrievable.
        assert!(
            chunks.iter().any(|c| c.text.contains("header rationale")),
            "file preamble was dropped: {:?}",
            chunks.iter().map(|c| &c.key).collect::<Vec<_>>()
        );
        assert!(chunks.iter().any(|c| c.key.contains("fn alpha")));
        assert!(chunks.iter().any(|c| c.key.contains("impl Beta")));

        let sh = "#!/usr/bin/env bash\n# rationale\n\nmain() {\n  echo hi\n}\n\nfunction helper {\n  echo there\n}\n";
        let sc = chunk_code("scripts/b.sh", "code", sh);
        assert!(sc.iter().any(|c| c.key.contains("main()")));
        assert!(sc.iter().any(|c| c.key.contains("function helper")));
    }

    /// NEGATIVE CONTROL for the boundary detector: prose and ordinary
    /// statements must NOT open a chunk, or the corpus fragments into noise and
    /// every citation lands on a random line.
    #[test]
    fn code_boundaries_do_not_fire_on_ordinary_lines() {
        for line in [
            "    let fn_name = 1;",
            "// fn commented_out() {}",
            "    x.impl_detail();",
            "echo 'main() is a string'",
            "    return 0",
        ] {
            assert!(
                !code_boundary(line, true) || line.trim_start().starts_with("fn "),
                "rust boundary fired on {line:?}"
            );
        }
        assert!(!code_boundary("echo hello", false), "shell fired on echo");
        assert!(
            !code_boundary("  # comment", false),
            "shell fired on comment"
        );
    }

    /// An oversized construct is split rather than truncated by the embedder,
    /// and the split pieces stay contiguous and in order.
    #[test]
    fn oversized_code_span_is_split_contiguously() {
        let mut src = String::from("pub fn huge() {\n");
        for i in 0..(MAX_CODE_SPAN_LINES * 2) {
            src.push_str(&format!("    let v{i} = {i};\n"));
        }
        src.push_str("}\n");
        let chunks = chunk_code("crates/x/src/h.rs", "code", &src);
        assert!(
            chunks.len() >= 2,
            "expected a split, got {} chunk(s)",
            chunks.len()
        );
        for w in chunks.windows(2) {
            assert_eq!(
                w[1].line_start,
                w[0].line_end + 1,
                "split left a gap or overlap"
            );
        }
        for c in &chunks {
            assert!(
                c.line_end - c.line_start < MAX_CODE_SPAN_LINES,
                "piece longer than the cap"
            );
        }
    }

    /// A straight-line shell script with ONE function must not collapse into
    /// fixed windows. This is `images/inference/entrypoint.sh` in miniature —
    /// the file the packet's own Q2 cited, 600 lines with a single function.
    #[test]
    fn shell_section_banners_open_chunks() {
        let mut sh = String::from("#!/usr/bin/env bash\n# preamble rationale\nset -eu\n\n");
        sh.push_str("# ── Preload policy (order 392a) ──────────────────\n");
        for i in 0..30 {
            sh.push_str(&format!("PRELOAD_{i}=1\n"));
        }
        sh.push_str("# --- Tier detection ---\n");
        for i in 0..30 {
            sh.push_str(&format!("TIER_{i}=1\n"));
        }
        let chunks = chunk_code("images/inference/entrypoint.sh", "code", &sh);
        assert!(
            chunks.iter().any(|c| c.key.contains("Preload policy")),
            "banner section missing: {:?}",
            chunks.iter().map(|c| &c.key).collect::<Vec<_>>()
        );
        assert!(chunks.iter().any(|c| c.key.contains("Tier detection")));
        // Keys are titles, not rows of rule characters.
        for c in &chunks {
            assert!(
                !c.key.starts_with('─') && !c.key.ends_with('─') && !c.key.ends_with('-'),
                "key still carries rule characters: {:?}",
                c.key
            );
        }
        // Invariant `verify` rests on, restated for banners.
        let lines: Vec<&str> = sh.lines().collect();
        for c in &chunks {
            let span = lines[c.line_start - 1..c.line_end].join("\n");
            assert!(span.contains(&c.key), "key {:?} not in span", c.key);
        }
    }

    /// A banner sitting directly on top of a function must NOT open its own
    /// chunk — it would steal the signature line and leave a chunk whose entire
    /// content is a rule, which is a citation pointing at nothing.
    #[test]
    fn banner_directly_above_a_function_does_not_steal_its_signature() {
        let sh = concat!(
            "#!/usr/bin/env bash\n",
            "set -eu\n",
            "\n",
            "# ── Helpers ──────────────────\n",
            "do_thing() {\n",
            "  echo hi\n",
            "}\n",
        );
        let chunks = chunk_code("scripts/x.sh", "code", sh);
        let sig = chunks
            .iter()
            .find(|c| c.key.contains("do_thing()"))
            .expect("function chunk missing");
        assert!(
            sig.text.contains("echo hi"),
            "signature chunk lost its body: {:?}",
            sig.text
        );
        assert!(
            !chunks.iter().any(|c| c.key == "Helpers"),
            "naked banner became its own chunk"
        );
    }

    /// NEGATIVE CONTROL for the banner detector. These are the lines that
    /// litter every script in the tree; if any of them opened a chunk, the
    /// shell corpus would shred into unciteable fragments.
    #[test]
    fn shell_banner_does_not_fire_on_ordinary_comments() {
        for line in [
            "#!/usr/bin/env bash",
            "# @trace spec:forge-environment-discoverability",
            "# shellcheck disable=SC2086",
            "# supports --dry-run and --force",
            "# ------------------------------", // a rule with no title
            "echo '# --- not a comment ---'",
            "  # ── indented, inside a function ──",
            "",
        ] {
            assert!(!shell_section_banner(line), "banner fired on {line:?}");
        }
        assert!(shell_section_banner("# ── Preload policy ──────"));
        assert!(shell_section_banner("# --- Discover validator ---"));
        assert!(shell_section_banner("# === Config ==="));
    }

    /// The prune RULE, not its effect on today's corpus. `images/default/
    /// cheatsheets/` is a byte-identical copy of the `cheatsheets` root; two
    /// identical chunks at every rank halve the useful width of a top-k. Today
    /// the extension filter already excludes it, so a corpus-level assertion is
    /// vacuous — asserting the rule is what can actually go red.
    #[test]
    fn duplicated_cheatsheet_copy_is_pruned() {
        assert!(is_pruned("images/default/cheatsheets/runtime/podman.md"));
        assert!(is_pruned("images/default/cheatsheets/build/anything.sh"));
        // Negative controls: the rest of the image tree must stay indexable.
        assert!(!is_pruned("images/inference/entrypoint.sh"));
        assert!(!is_pruned("images/default/lib-common.sh"));
        assert!(!is_pruned("cheatsheets/runtime/podman.md"));
        assert!(!is_pruned("images/default/Containerfile"));
    }

    /// A Containerfile is extension-less, so an extension-only walker skipped
    /// all seven of them. Assert the name arm matches and the extension arm is
    /// still exclusive — a `names` list that leaked into the prose roots would
    /// index a Containerfile as a spec.
    #[test]
    fn walk_matches_extensionless_names_without_widening_extensions() {
        let dir = std::env::temp_dir().join(format!("tsp-walk-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("Containerfile"), "FROM x\n").unwrap();
        std::fs::write(dir.join("sub/entrypoint.sh"), "main() { :; }\n").unwrap();
        std::fs::write(dir.join("sub/notes.md"), "# no\n").unwrap();

        let mut got = walk_files(&dir, &["sh"], CORPUS_CODE_FILENAMES)
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect::<Vec<_>>();
        got.sort();
        assert_eq!(got, vec!["Containerfile", "entrypoint.sh"]);

        // Prose roots pass an empty names list and must not pick it up.
        let prose = walk_files(&dir, &["md"], &[]);
        assert_eq!(
            prose.len(),
            1,
            "md walk should see only notes.md: {prose:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A Containerfile has neither `fn` nor `##`, so both older chunkers
    /// degrade to fixed windows on it. Assert the boundary is the instruction,
    /// that a `\`-continuation is held inside its instruction (splitting a
    /// multi-line RUN at a `&&` is the mid-construct citation this packet
    /// exists to prevent), and that the header rationale survives.
    #[test]
    fn containerfile_chunks_on_instructions_and_holds_continuations() {
        let cf = concat!(
            "# order 803 rationale line\n",
            "# second header line\n",
            "\n",
            "FROM registry.example/base:1\n",
            "RUN microdnf install -y bash curl \\\n",
            "    && microdnf clean all \\\n",
            "    && rm -rf /var/cache\n",
            "COPY entrypoint.sh /usr/local/bin/entrypoint.sh\n",
            "USER 1000:1000\n",
            "EXPOSE 11434\n",
            "ENV HOME=/home/ollama\n",
            // The idiom the continuation guard exists for: a column-0 `CMD`
            // that is the SECOND LINE of a HEALTHCHECK, not an instruction of
            // its own. Without the guard this opens a chunk and the healthcheck
            // is cited as two unrelated halves.
            "HEALTHCHECK --interval=5s --retries=12 \\\n",
            "CMD curl -sf http://127.0.0.1:11434/api/version || exit 1\n",
            "ENTRYPOINT [\"/usr/local/bin/entrypoint.sh\"]\n",
        );
        let chunks = chunk_containerfile("images/inference/Containerfile", "code", cf);
        assert!(
            chunks
                .iter()
                .any(|c| c.text.contains("order 803 rationale")),
            "Containerfile header dropped"
        );
        // No chunk may OPEN on a continuation line.
        for c in &chunks {
            let head = c.text.lines().next().unwrap_or("").trim_start();
            assert!(!head.starts_with("&&"), "a chunk opened mid-RUN: {head:?}");
        }
        // The continuation rule itself, asserted at boundary level. Coalescing
        // usually reabsorbs a spurious boundary, so a chunk-level assertion
        // here would pass with the guard deleted — it did, under mutation.
        let cf_lines: Vec<&str> = cf.lines().collect();
        let bounds = containerfile_boundaries(&cf_lines);
        let cmd_line = cf_lines
            .iter()
            .position(|l| l.starts_with("CMD curl"))
            .expect("fixture lost its HEALTHCHECK continuation");
        assert!(
            !bounds.contains(&cmd_line),
            "the CMD continuation of a HEALTHCHECK opened a boundary: {bounds:?}"
        );
        assert!(
            bounds.contains(&(cmd_line - 1)),
            "the HEALTHCHECK itself must still be a boundary"
        );
        // Keys stay literal substrings — the invariant `verify` rests on.
        let lines: Vec<&str> = cf.lines().collect();
        for c in &chunks {
            let span = lines[c.line_start - 1..c.line_end].join("\n");
            assert!(span.contains(&c.key), "key {:?} not in span", c.key);
        }
        // Coalescing: single-line COPY/USER/EXPOSE must not each be a chunk.
        assert!(
            chunks.len() <= 3,
            "expected coalesced groups, got {} chunks: {:?}",
            chunks.len(),
            chunks.iter().map(|c| &c.key).collect::<Vec<_>>()
        );
        // And chunk_code must route here by filename, not by extension.
        assert_eq!(
            chunk_code("images/inference/Containerfile", "code", cf).len(),
            chunks.len()
        );
    }

    /// NEGATIVE CONTROL: an indented instruction word (inside a heredoc, or a
    /// shell line in a RUN) is not a boundary, and neither is prose.
    #[test]
    fn containerfile_boundaries_do_not_fire_on_indented_or_prose_lines() {
        for line in [
            "    RUN this is inside a heredoc",
            "  COPY nothing",
            "# FROM in a comment",
            "echo FROM",
            "",
        ] {
            assert!(
                !containerfile_instruction(line),
                "boundary fired on {line:?}"
            );
        }
        assert!(containerfile_instruction("FROM scratch"));
        assert!(containerfile_instruction("HEALTHCHECK --interval=5s CMD x"));
    }

    /// `images/default/cheatsheets/` is a byte-identical copy of the
    /// `cheatsheets` root. Two identical chunks at every rank halve the useful
    /// width of a top-k, so the prune is a retrieval-quality property, not
    /// housekeeping — assert it rather than relying on today's extension list.
    #[test]
    fn pruned_prefixes_are_not_indexed() {
        let root = manifest_dir().join("../..");
        if !root.join("images/default/cheatsheets").is_dir() {
            return; // open-world: an off-Tillandsias checkout simply has no copy
        }
        let chunks = chunk_corpus(&root);
        assert!(!chunks.is_empty(), "corpus is empty");
        let leaked: Vec<&str> = chunks
            .iter()
            .map(|c| c.path.as_str())
            .filter(|p| p.starts_with("images/default/cheatsheets/"))
            .take(3)
            .collect();
        assert!(
            leaked.is_empty(),
            "pruned prefix leaked into corpus: {leaked:?}"
        );
        // …and `images/` IS indexed, so the prune is not a mute.
        assert!(
            chunks
                .iter()
                .any(|c| c.path == "images/inference/entrypoint.sh"),
            "images/ root indexed nothing outside the prune"
        );
        // The extension-less arm has to survive the WHOLE dispatch, not just a
        // direct walk_files call — the second thing mutation control caught.
        assert!(
            chunks
                .iter()
                .any(|c| c.path == "images/inference/Containerfile"),
            "no Containerfile reached the corpus: the extension-less name arm is \
             not wired through chunk_corpus"
        );
    }

    #[test]
    fn markdown_chunk_keys_are_in_their_span() {
        let text =
            "preamble line\n\n## Purpose\nbody a\nbody b\n\n## Egress allowlist\ndeny by default\n";
        let chunks = chunk_markdown("openspec/specs/x/spec.md", "spec", text);
        assert!(
            chunks.len() >= 3,
            "preamble + 2 headings, got {}",
            chunks.len()
        );
        for c in &chunks {
            let lines: Vec<&str> = text.lines().collect();
            let span = lines[c.line_start - 1..c.line_end].join("\n");
            assert!(
                span.contains(&c.key),
                "key {:?} not in span {:?}",
                c.key,
                span
            );
        }
        // Heading keys are stripped of the '#' markers.
        assert!(chunks.iter().any(|c| c.key == "Egress allowlist"));
    }

    #[test]
    fn yaml_chunk_keys_are_top_level_and_in_span() {
        let text = "methodology:\n  version: v1\n  rule: keep terse\nruntime_language_policy:\n  tlatoani_hard_no_python:\n    rule: no python\n";
        let chunks = chunk_yaml("methodology.yaml", "methodology", text);
        assert_eq!(chunks.len(), 2, "two top-level keys");
        assert_eq!(chunks[0].key, "methodology");
        assert_eq!(chunks[1].key, "runtime_language_policy");
        let lines: Vec<&str> = text.lines().collect();
        for c in &chunks {
            let span = lines[c.line_start - 1..c.line_end].join("\n");
            assert!(span.contains(&c.key));
        }
    }

    #[test]
    fn cosine_ranks_the_aligned_vector_first() {
        let q = vec![1.0f32, 0.0, 0.0];
        let vecs = vec![
            vec![0.0f32, 1.0, 0.0],  // orthogonal
            vec![0.9f32, 0.1, 0.0],  // aligned
            vec![-1.0f32, 0.0, 0.0], // opposite
        ];
        let top = top_k(&q, &vecs, 2);
        assert_eq!(top[0].0, 1, "aligned vector must rank first");
        assert!(top[0].1 > top[1].1);
    }

    #[test]
    fn cosine_is_zero_on_length_mismatch_not_nan() {
        assert_eq!(cosine(&[1.0, 2.0], &[1.0]), 0.0);
        assert_eq!(cosine(&[], &[]), 0.0);
    }

    #[test]
    fn envelope_drops_decorative_citations() {
        let chunks = vec![Chunk {
            id: 0,
            path: "openspec/specs/x/spec.md".into(),
            line_start: 1,
            line_end: 2,
            kind: "spec".into(),
            key: "Egress allowlist".into(),
            content_hash: "0".into(),
            text: "## Egress allowlist\ndeny".into(),
        }];
        // Answer never mentions the key -> unsupported (no decorative citation).
        let env = build_envelope("something unrelated", &chunks, Path::new("."));
        assert_eq!(env.confidence(), Confidence::Unsupported);
        // Answer mentions the key -> one retrieved citation.
        let env2 = build_envelope(
            "The Egress allowlist denies by default.",
            &chunks,
            Path::new("."),
        );
        assert_eq!(env2.confidence(), Confidence::Retrieved);
        assert_eq!(env2.citations().len(), 1);
    }

    #[test]
    fn cheatsheet_query_answers_and_verifies() {
        let text = "# Concurrent Git\n\n## The three primitives you actually need\n- G-Set\n- LWW-Register\n";
        let chunks = chunk_markdown(
            "cheatsheets/concurrent-git/crdt-ledger-fragments.md",
            "cheatsheet",
            text,
        );
        let root = manifest_dir().join("../..");
        let env = answer_cheatsheet_query(&root, &chunks, "three primitives CRDT");
        assert_eq!(env.confidence(), Confidence::Exact);
        assert_eq!(env.citations().len(), 1);
        assert_eq!(env.citations()[0].kind(), CitationKind::Cheatsheet);
    }

    #[test]
    fn retrieval_only_answer_contains_every_key() {
        let chunks = vec![
            Chunk {
                id: 0,
                path: "a.md".into(),
                line_start: 1,
                line_end: 1,
                kind: "spec".into(),
                key: "Alpha".into(),
                content_hash: "0".into(),
                text: "Alpha".into(),
            },
            Chunk {
                id: 1,
                path: "b.md".into(),
                line_start: 1,
                line_end: 1,
                kind: "spec".into(),
                key: "Beta".into(),
                content_hash: "0".into(),
                text: "Beta".into(),
            },
        ];
        let ans = retrieval_only_answer(&chunks);
        let env = build_envelope(&ans, &chunks, Path::new("."));
        assert_eq!(
            env.citations().len(),
            2,
            "retrieval-only keeps all citations"
        );
    }
}

/// ORDER 1822-dmwz — hybrid retrieval and chunk hygiene. The packet's guard is
/// `cargo test -p tillandsias-plan hybrid_rrf_and_chunk_breadcrumbs`; every
/// test here was written against the pre-fix code and failed there.
/// @trace order:1822-dmwz
#[cfg(test)]
mod hybrid_rrf_and_chunk_breadcrumbs {
    use super::*;

    fn chunk(id: usize, path: &str, text: &str) -> Chunk {
        Chunk {
            id,
            path: path.to_string(),
            line_start: 1,
            line_end: 1,
            kind: "cheatsheet".to_string(),
            key: "k".to_string(),
            content_hash: String::new(),
            text: text.to_string(),
        }
    }

    #[test]
    fn bm25_ranks_the_exact_identifier_first() {
        let chunks = vec![
            chunk(
                0,
                "a.md",
                "how the index is built and published for experts",
            ),
            chunk(1, "b.md", "the spec index lives in a durable podman volume"),
            chunk(2, "c.md", "run scripts/spec-index-ensure.sh to rebuild it"),
        ];
        let bm = Bm25::from_chunks(&chunks);
        let top = bm.rank("what does spec-index-ensure.sh do", None, 3);
        assert_eq!(
            top.first().map(|t| t.0),
            Some(2),
            "the chunk carrying the exact identifier must rank first: {top:?}"
        );
    }

    #[test]
    fn hybrid_breaks_a_dense_tie_with_the_lexical_channel() {
        // Dense cannot tell these apart (identical vectors) — the flat score
        // distribution the packet measured. Dense-only keeps corpus order and
        // puts chunk 0 first; the lexical channel must lift the chunk that
        // actually names the env var.
        let chunks = vec![
            chunk(
                0,
                "a.md",
                "the embedder model is chosen at index build time",
            ),
            chunk(1, "b.md", "a model marker is written beside the vectors"),
            chunk(
                2,
                "c.md",
                "TILLANDSIAS_EMBED_MODEL overrides the embedder model",
            ),
        ];
        let vectors = vec![vec![1.0f32, 0.0]; 3];
        let bm = Bm25::from_chunks(&chunks);
        let dense = top_k(&[1.0, 0.0], &vectors, 3);
        assert_eq!(
            dense[0].0, 0,
            "precondition: dense alone ties and keeps corpus order"
        );
        let all: Vec<usize> = (0..3).collect();
        let hybrid = hybrid_top_k(
            "what does TILLANDSIAS_EMBED_MODEL set",
            &[1.0, 0.0],
            &vectors,
            &bm,
            &all,
            3,
        );
        assert_eq!(
            hybrid[0].0, 2,
            "lexical channel must break the tie: {hybrid:?}"
        );
        // The score carried out is still the COSINE, so the refusal floors
        // keep their calibrated meaning.
        assert!((hybrid[0].1 - 1.0).abs() < 1e-6);
    }

    #[test]
    fn a_prose_question_is_served_dense_only() {
        for q in [
            "how does the forge stay isolated from the host and control outbound network access?",
            "how is the inference accelerator tier selected, and what makes it fall back to CPU?",
        ] {
            assert!(!query_has_identifier(q), "{q}");
        }
        for q in [
            "what does spec-index-ensure.sh do",
            "status of 1822-dmwz",
            "what is TILLANDSIAS_EMBED_MODEL",
            "why does GetLayout freeze",
            "is v0.5 cut",
            "what listens on 11434",
            "what does `plan_next` return",
        ] {
            assert!(query_has_identifier(q), "{q}");
        }
        // On a LEGACY index (methodology chunks without breadcrumbs) a prose
        // question's hybrid IS the dense ranking, even where BM25 disagrees.
        let mut legacy_yaml = chunk(2, "methodology/m.yaml", "rule: keep it terse");
        legacy_yaml.kind = "methodology".to_string();
        let mut chunks = vec![
            chunk(0, "a.md", "unrelated words entirely"),
            chunk(1, "b.md", "forge isolation network access host"),
            legacy_yaml,
        ];
        let vectors = vec![vec![1.0f32, 0.0], vec![0.6, 0.8], vec![0.0, 1.0]];
        let q = "how does the forge isolate network access from the host";
        let bm = Bm25::from_chunks(&chunks);
        assert!(bm.legacy_chunks());
        let hybrid = hybrid_top_k(q, &[1.0, 0.0], &vectors, &bm, &[0, 1, 2], 2);
        assert_eq!(hybrid, top_k(&[1.0, 0.0], &vectors, 2));
        // The same corpus chunked by this order's chunker fuses: the chunk BM25
        // prefers leads.
        chunks[2].text = format!("{BREADCRUMB_MARK}methodology/m.yaml > rule\nrule: keep it terse");
        let bm = Bm25::from_chunks(&chunks);
        assert!(!bm.legacy_chunks());
        let hybrid = hybrid_top_k(q, &[1.0, 0.0], &vectors, &bm, &[0, 1, 2], 2);
        assert_eq!(hybrid[0].0, 1, "{hybrid:?}");
    }

    #[test]
    fn rrf_combines_two_rankings_deterministically() {
        let fused = rrf_fuse(&[vec![0, 1, 2], vec![2, 0, 3]], RRF_K);
        let order: Vec<usize> = fused.iter().map(|f| f.0).collect();
        assert_eq!(order, vec![0, 2, 1, 3]);
        let expect0 = 1.0 / (RRF_K + 1.0) + 1.0 / (RRF_K + 2.0);
        assert!((fused[0].1 - expect0).abs() < 1e-6);
        // A perfect tie resolves the same way whichever list comes first.
        let a = rrf_fuse(&[vec![5, 7], vec![7, 5]], RRF_K);
        let b = rrf_fuse(&[vec![7, 5], vec![5, 7]], RRF_K);
        assert_eq!(a, b);
        assert_eq!(a[0].0, 5, "ties break on the smaller index");
    }

    #[test]
    fn markdown_splits_under_headings_and_ignores_fenced_comments() {
        // The H1 body is long enough to be a real section, not a title card.
        let intro = "intro words that make a real lead section. ".repeat(12);
        let text = format!(
            "# Forge constraints\n\n{intro}\n\n## Summary\n\nThere is NO docker here.\n\n### Detail\n\nmore text\n\n```bash\n# not a heading, a shell comment\necho hi\n```\n\n## Pitfalls\n\n- x\n"
        );
        let text = text.as_str();
        let chunks = chunk_markdown("cheatsheets/runtime/x.md", "cheatsheet", text);
        let keys: Vec<&str> = chunks.iter().map(|c| c.key.as_str()).collect();
        assert_eq!(
            keys,
            vec!["Forge constraints", "Summary", "Detail", "Pitfalls"],
            "one chunk per real heading; a `#` comment inside a fence is not one"
        );
        let detail = chunks.iter().find(|c| c.key == "Detail").expect("Detail");
        assert!(
            detail.text.contains("echo hi") && detail.text.contains("more text"),
            "the code block stays with the prose that explains it"
        );
        // Markdown text is exactly the cited span (no breadcrumb: measured to
        // regress dense retrieval — see BREADCRUMB_MARK).
        let lines: Vec<&str> = text.lines().collect();
        for c in &chunks {
            let span = lines[c.line_start - 1..c.line_end].join("\n");
            assert!(span.contains(&c.key), "{c:?}");
            assert_eq!(c.text, span);
        }
    }

    #[test]
    fn a_title_card_travels_with_the_first_section() {
        // The forge-constraints shape: H1, a trace line, a one-line lead, then
        // the rule paragraph under an H2.
        let text = "# Forge hard constraints (can I run docker here?)\n\n@trace spec:forge-offline\n\n**Use when**: you wonder whether you can run docker.\n\n## Summary\n\nThere is NO docker and NO nested container daemon.\n\n## Provenance\n\n- x\n";
        let chunks = chunk_markdown("cheatsheets/runtime/f.md", "cheatsheet", text);
        let first = &chunks[0];
        assert_eq!(first.line_start, 1);
        assert!(
            first.text.contains("can I run docker here?") && first.text.contains("NO docker"),
            "the title and the rule must be ONE chunk: {chunks:#?}"
        );
        assert_eq!(first.key, "Summary", "keyed on the section, not the title");
        assert_eq!(chunks.len(), 2, "title+Summary, Provenance: {chunks:#?}");
        assert!(
            chunks.iter().any(|c| c.key == "Provenance"),
            "later sections stay split"
        );
        // The cheatsheet expert cites the folded chunk for the docker question.
        let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo")).join("../..");
        let env = answer_cheatsheet_query(&root, &chunks, "can I run docker in the forge?");
        assert_eq!(env.confidence(), Confidence::Exact);
        assert_eq!(env.citations()[0].line_start(), 1);
    }

    #[test]
    fn front_matter_comments_are_not_headings() {
        let text = "---\ntags: [x]\n# a yaml comment, not a title\nstatus: current\n---\n\n# Real title\n\nlong enough lead paragraph. ".to_string()
            + &"words ".repeat(90)
            + "\n\n## Section\n\nbody\n";
        let chunks = chunk_markdown("cheatsheets/x.md", "cheatsheet", &text);
        assert!(
            !chunks.iter().any(|c| c.key.contains("yaml comment")),
            "{:?}",
            chunks.iter().map(|c| &c.key).collect::<Vec<_>>()
        );
        assert!(chunks.iter().any(|c| c.key == "Real title"));
    }

    #[test]
    fn yaml_chunks_fit_the_budget_and_lead_with_their_breadcrumb() {
        let mut text = String::from("order_id_allocation:\n  rule: >\n");
        for i in 0..80 {
            text.push_str(&format!(
                "    line {i} of a long folded rule about order ids\n"
            ));
        }
        text.push_str("  examples:\n");
        for i in 0..40 {
            text.push_str(&format!("    - example {i} with some padding words\n"));
        }
        text.push_str("other: 1\n");
        let path = "methodology/distributed-work.yaml";
        let chunks = chunk_yaml(path, "methodology", &text);
        assert!(
            chunks.len() > 2,
            "the oversized key must split: {}",
            chunks.len()
        );
        for c in &chunks {
            assert!(
                c.text.chars().count() <= MAX_YAML_CHUNK_CHARS_BREADCRUMBED,
                "{} chars",
                c.text.len()
            );
            let first = c.text.lines().next().unwrap_or("");
            assert!(first.starts_with(&format!("§ {path} > ")), "{first:?}");
        }
        assert!(
            chunks.iter().any(|c| c
                .text
                .starts_with("§ methodology/distributed-work.yaml > order_id_allocation > rule\n")),
            "nested key appears in the breadcrumb"
        );
    }

    #[test]
    fn every_methodology_chunk_in_the_real_corpus_fits_and_is_breadcrumbed() {
        let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo")).join("../..");
        let chunks = chunk_corpus(&root);
        let yaml: Vec<&Chunk> = chunks.iter().filter(|c| c.kind == "methodology").collect();
        assert!(yaml.len() > 100, "corpus present");
        for c in yaml {
            assert!(
                c.text.chars().count() <= MAX_YAML_CHUNK_CHARS_BREADCRUMBED,
                "{}:{}-{} is {} chars",
                c.path,
                c.line_start,
                c.line_end,
                c.text.chars().count()
            );
            assert!(c.text.starts_with(&format!("§ {}", c.path)), "{}", c.path);
        }
    }
}
