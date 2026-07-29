//! Order 394c — the METHODOLOGY EXPERT, layer 0.
//!
//! Ratified contract (`plan/issues/experts-construction-research-2026-07-29.md`
//! §5 + §7.1, operator-ratified 2026-07-29):
//!
//! > **Methodology — L0, no model for rung 1.** `methodology.yaml` is a
//! > 290-line YAML whose invariants are *named keys*; the honest query is a
//! > path lookup returning the block plus `file:line`, not a paraphrase. The
//! > `methodology/` directory (453 KB ≈ 113 k tokens) does not fit any
//! > tiny-model context, which settles the matter.
//!
//! and §7.1, which SUPERSEDED the wave-1 "Modelfile stuffing" design:
//! *"Replaced by L0 path query (§5, slice 394.3)."*
//!
//! So this module is a **path query**, not a retriever and not a summarizer.
//! It answers in 394b's [`crate::answer::Envelope`], which means every answer
//! is either (a) a verbatim block of the corpus with a resolvable
//! `path:line_start-line_end`, or (b) `confidence: unsupported`. There is no
//! third outcome and deliberately no ranking: a ranked "closest key" answer
//! would be a guess wearing a citation.
//!
//! # Why the index is built from TEXT, not from `serde_yaml`
//!
//! A citation without a line range is decoration (394b). `serde_yaml` discards
//! source positions entirely — it cannot tell you where `forge_cycle_budget`
//! lives. The plan ledger already solves this by scanning the raw text
//! (`Ledger::spans`); this module generalises that scan to arbitrary block YAML.
//! `serde_yaml` is still used, but only as a *validator*: a file that does not
//! parse is reported, because indexing a malformed file would produce spans
//! nobody can trust. NO NEW DEPENDENCY, NO NEW CRATE — both are explicit
//! constraints of the ratified slice.
//!
//! # What is citable
//!
//! Only **mapping keys**. A sequence *item* is not citable on its own: its
//! span would begin with `- `, so there would be no token in the span that
//! could be checked against the claim, and 394b's `span_key` rule would have
//! nothing to verify. Sequence items still get a `[n]` path segment so nested
//! keys stay uniquely addressable (`bar_raise_governance.rules[0].…`), and the
//! list as a whole is cited through its owning key.
//!
//! @trace spec:spec-traceability
//! @trace order:394, order:394c

use crate::answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// One citable YAML node: a dotted path and the INCLUSIVE, 1-indexed line
/// range of its block in the file it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    /// The key VERBATIM, carried rather than re-derived from `path`.
    ///
    /// Splitting the dotted path on its last `.` looks equivalent and is not:
    /// `methodology.authority.non_authoritative_files.CLAUDE.md`
    /// (methodology.yaml:9) would yield `md`, which appears nowhere in the
    /// span — 394b's `verify` would then reject this engine's own truthful
    /// citation as FABRICATED. The corpus-wide index self-check below found
    /// exactly that, which is why the key is stored, not inferred.
    pub key: String,
    /// The key's DECLARATION TOKEN exactly as it appears at `line_start`
    /// (`rule:`, `"The Tlatoāni":`). This — not the bare key — is what a
    /// citation asks 394b's verifier to find inside the cited span: `rule` is
    /// a word that occurs in methodology prose constantly, so requiring only
    /// the word would make the span check satisfiable by almost any ten lines
    /// of the corpus, i.e. decorative.
    pub decl: String,
    pub line_start: usize,
    pub line_end: usize,
}

/// One corpus file plus its index.
#[derive(Debug)]
pub struct CorpusFile {
    /// Repo-relative, forward-slashed — a citation must name a path a reader
    /// can open from the checkout root.
    pub rel: String,
    pub entries: Vec<Entry>,
    pub line_count: usize,
    /// `Some` when `serde_yaml` refused the file. The text index is still
    /// built (a partially-broken file is still greppable), but the parse
    /// failure is surfaced so nobody mistakes a mis-scan for methodology.
    pub parse_error: Option<String>,
}

/// The methodology corpus: `methodology.yaml` plus every `*.yaml` under
/// `methodology/`, recursively.
#[derive(Debug)]
pub struct Corpus {
    root: PathBuf,
    pub files: Vec<CorpusFile>,
}

/// A single query hit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    pub file: String,
    pub path: String,
    /// The verbatim key.
    pub key: String,
    /// The declaration token 394b checks against the cited span.
    pub decl: String,
    pub line_start: usize,
    pub line_end: usize,
}

/// How the query matched. Recorded so the answer can say WHY these lines are
/// the answer — an agent that cannot tell an exact hit from a suffix hit
/// cannot tell whether it asked the right question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchKind {
    /// The query IS the full dotted path.
    Exact,
    /// The query is a segment-aligned suffix of the path (`forge_cycle_budget`
    /// matching `distributed_work.…​.forge_cycle_budget`).
    Suffix,
    /// The query contained `*` and matched segment-wise against the tail.
    Wildcard,
}

impl MatchKind {
    fn label(self) -> &'static str {
        match self {
            MatchKind::Exact => "exact-path",
            MatchKind::Suffix => "path-suffix",
            MatchKind::Wildcard => "wildcard",
        }
    }
}

/// Rendering caps. A query like `methodology` legitimately matches a block of
/// hundreds of lines; the CITATION always carries the true full range, so a
/// truncated rendering never narrows the evidence — it only shortens the
/// transcript, and it says so.
const MAX_HITS_RENDERED: usize = 20;
const MAX_LINES_PER_HIT: usize = 200;

impl Corpus {
    /// Load and index the corpus rooted at a checkout. Fails only when the
    /// checkout has no methodology corpus at all — the caller must be able to
    /// distinguish "this project has no methodology" from "your path is wrong".
    pub fn load(root: &Path) -> Result<Self, String> {
        let mut rels: Vec<String> = Vec::new();
        if root.join("methodology.yaml").is_file() {
            rels.push("methodology.yaml".to_string());
        }
        collect_yaml(&root.join("methodology"), root, 0, &mut rels);
        rels.sort();
        rels.dedup();
        if rels.is_empty() {
            return Err(format!(
                "no methodology corpus under {} (expected methodology.yaml and/or methodology/**/*.yaml)",
                root.display()
            ));
        }

        let mut files = Vec::new();
        for rel in rels {
            let Ok(text) = std::fs::read_to_string(root.join(&rel)) else {
                continue;
            };
            let parse_error = serde_yaml::from_str::<serde_yaml::Value>(&text)
                .err()
                .map(|e| e.to_string());
            files.push(CorpusFile {
                entries: index_text(&text),
                line_count: text.lines().count(),
                rel,
                parse_error,
            });
        }
        Ok(Self {
            root: root.to_path_buf(),
            files,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn entry_count(&self) -> usize {
        self.files.iter().map(|f| f.entries.len()).sum()
    }

    /// Files `serde_yaml` refused. Empty at HEAD; asserted by a test.
    pub fn parse_errors(&self) -> Vec<(&str, &str)> {
        self.files
            .iter()
            .filter_map(|f| f.parse_error.as_deref().map(|e| (f.rel.as_str(), e)))
            .collect()
    }

    /// Resolve a path query. TIERED AND TOTAL: exact hits win outright; only
    /// if there are none do suffix hits count; wildcards only apply when the
    /// query actually contains `*`. Every hit of the winning tier is returned
    /// — the complete match set, never a "best" one, because picking a best
    /// among equals is the guess this module exists to refuse.
    pub fn query(&self, q: &str, file_filter: Option<&str>) -> (Vec<Hit>, MatchKind) {
        let q = q.trim().trim_matches('.');
        if q.is_empty() {
            // `ends_with("")` is true for every path; an empty query would
            // "match" the entire corpus. It is a refusal, not a wildcard.
            return (Vec::new(), MatchKind::Exact);
        }
        let considered = |f: &CorpusFile| match file_filter {
            Some(sub) if !sub.is_empty() => f.rel.contains(sub),
            _ => true,
        };

        let mut exact = Vec::new();
        let mut suffix = Vec::new();
        let mut wildcard = Vec::new();
        let wants_wildcard = q.contains('*');
        let q_segments: Vec<&str> = q.split('.').collect();

        for f in self.files.iter().filter(|f| considered(f)) {
            for e in &f.entries {
                let hit = || Hit {
                    file: f.rel.clone(),
                    path: e.path.clone(),
                    key: e.key.clone(),
                    decl: e.decl.clone(),
                    line_start: e.line_start,
                    line_end: e.line_end,
                };
                if e.path == q {
                    exact.push(hit());
                    continue;
                }
                if e.path.ends_with(q) && e.path.as_bytes()[e.path.len() - q.len() - 1] == b'.' {
                    suffix.push(hit());
                    continue;
                }
                if wants_wildcard && wildcard_tail_match(&e.path, &q_segments) {
                    wildcard.push(hit());
                }
            }
        }

        for v in [&mut exact, &mut suffix, &mut wildcard] {
            v.sort_by(|a, b| (&a.file, a.line_start).cmp(&(&b.file, b.line_start)));
            v.dedup();
        }
        if !exact.is_empty() {
            return (exact, MatchKind::Exact);
        }
        if !suffix.is_empty() {
            return (suffix, MatchKind::Suffix);
        }
        (wildcard, MatchKind::Wildcard)
    }

    /// Keys whose NAME contains the last segment of a failed query. This is
    /// navigation, never an answer: it is only ever rendered inside an
    /// `unsupported` envelope, with no citations, precisely so a near miss can
    /// never be mistaken for a hit.
    pub fn near_misses(&self, q: &str) -> Vec<String> {
        let needle = q
            .trim()
            .trim_matches('.')
            .rsplit('.')
            .next()
            .unwrap_or("")
            .replace('*', "")
            .to_ascii_lowercase();
        if needle.len() < 3 {
            return Vec::new();
        }
        let mut out: Vec<String> = Vec::new();
        for f in &self.files {
            for e in &f.entries {
                if e.key.to_ascii_lowercase().contains(&needle) {
                    out.push(format!("{}:{} {}", f.rel, e.line_start, e.path));
                }
            }
        }
        out.sort();
        out.dedup();
        out.truncate(8);
        out
    }

    /// Freshness for the whole corpus: the git commit plus the mtime of the
    /// most recently written corpus file. An L0 engine has no index, so
    /// "indexed_at" IS "when the corpus was last written" — the same honest
    /// reading 394b applies to the ledger.
    pub fn freshness(&self) -> Freshness {
        let newest = self
            .files
            .iter()
            .map(|f| self.root.join(&f.rel))
            .max_by_key(|p| {
                std::fs::metadata(p)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs())
                    .unwrap_or(0)
            });
        match newest {
            Some(p) => Freshness::for_source(&p),
            None => Freshness::new("unknown".into(), "unknown".into()),
        }
    }

    fn read_span(&self, hit: &Hit) -> Option<String> {
        let text = std::fs::read_to_string(self.root.join(&hit.file)).ok()?;
        let lines: Vec<&str> = text.lines().collect();
        if hit.line_start == 0 || hit.line_end > lines.len() || hit.line_end < hit.line_start {
            return None;
        }
        Some(lines[hit.line_start - 1..hit.line_end].join("\n"))
    }
}

/// Answer a PATH QUERY as a 394b envelope.
///
/// EXIT CRITERION (iii) lives here: a query that resolves to nothing comes
/// back `unsupported` with an empty citation list. It never falls back to a
/// nearby key, and the `Envelope` constructor makes the alternative
/// unrepresentable anyway (zero citations downgrades and discards the prose).
pub fn answer_path_query(corpus: &Corpus, query: &str, file_filter: Option<&str>) -> Envelope {
    let freshness = corpus.freshness();
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Envelope::unsupported("no YAML path was supplied", freshness);
    }

    let (hits, kind) = corpus.query(trimmed, file_filter);
    if hits.is_empty() {
        let mut reason = format!(
            "no methodology YAML path matches {trimmed:?} (searched {} keys across {} file(s){})",
            corpus.entry_count(),
            corpus.files.len(),
            match file_filter {
                Some(f) if !f.is_empty() => format!(", restricted to files containing {f:?}"),
                _ => String::new(),
            }
        );
        let near = corpus.near_misses(trimmed);
        if !near.is_empty() {
            reason.push_str(&format!(
                ". Keys whose NAME contains that token — offered for navigation only, NOT as an answer: {}",
                near.join("; ")
            ));
        }
        return Envelope::unsupported(reason, freshness);
    }

    let rendered = hits.len().min(MAX_HITS_RENDERED);
    let mut body = format!(
        "methodology path query {trimmed:?} — {} match(es) [{}]\n",
        hits.len(),
        kind.label()
    );
    let mut citations = Vec::new();
    for hit in hits.iter().take(rendered) {
        let Some(span) = corpus.read_span(hit) else {
            // A span we cannot re-read is a span we do not report: emitting it
            // would put an unverifiable claim inside a supported envelope.
            continue;
        };
        let mut shown: Vec<&str> = span.lines().collect();
        let truncated = shown.len() > MAX_LINES_PER_HIT;
        if truncated {
            shown.truncate(MAX_LINES_PER_HIT);
        }
        body.push_str(&format!(
            "\n=== {} :: {}\n{}:{}-{}\n{}\n",
            hit.file,
            hit.path,
            hit.file,
            hit.line_start,
            hit.line_end,
            shown.join("\n")
        ));
        if truncated {
            body.push_str(&format!(
                "… ({} more line(s) in the cited range — the citation covers the WHOLE block)\n",
                hit.line_end - hit.line_start + 1 - MAX_LINES_PER_HIT
            ));
        }
        let mut authority = BTreeMap::new();
        // `key` is what 394b's `verify` checks against BOTH the span and the
        // answer text — it is the falsifiability hook, not a label. It carries
        // the DECLARING COLON on purpose: `rule` is a word that appears in
        // methodology prose everywhere, so `span.contains("rule")` would be
        // satisfied by almost any 10 lines of the corpus and the check would
        // be decorative. `span.contains("rule:")` demands the YAML declaration
        // token, which only appears where the key is actually declared.
        authority.insert("key".to_string(), hit.decl.clone());
        authority.insert("yaml_path".to_string(), hit.path.clone());
        authority.insert("match".to_string(), kind.label().to_string());
        citations.push(Citation::new(
            hit.file.clone(),
            hit.line_start,
            hit.line_end,
            CitationKind::Methodology,
            authority,
        ));
    }
    if hits.len() > rendered {
        body.push_str(&format!(
            "\n… {} further match(es) not rendered; narrow the query or pass a file filter.\n",
            hits.len() - rendered
        ));
    }

    // Downgrades to `unsupported` automatically if nothing turned out citable.
    Envelope::supported(body, citations, Confidence::Exact, freshness)
}

// ── canonical discipline questions ──────────────────────────────────────────

/// The committed question index: `(required tokens, YAML path query)`.
///
/// THIS TABLE MAPS A QUESTION TO A *PATH*, NEVER TO AN ANSWER. The answer text
/// and the `file:line` are re-derived from the corpus on every call, so if a
/// rule is rewritten the answer changes with it, and if a rule is DELETED the
/// route returns `unsupported` rather than a stale claim — which is exactly
/// what the test below detects.
///
/// Routing is deterministic and non-ranked: an entry matches when EVERY one of
/// its tokens is a substring of the lowercased question, and a question is
/// routed only when EXACTLY ONE entry matches. Zero matches or an ambiguous
/// two are both refusals. There is no scoring, no stemming and no fallback,
/// because every one of those is a mechanism for answering a question that was
/// not actually asked.
pub const CANONICAL_QUESTIONS: &[(&[&str], &str)] = &[
    (&["forge", "cycle"], "forge_cycle_budget.rule"),
    (&["python"], "tlatoani_hard_no_python.rule"),
    (&["base64"], "base64_script_injection_ban.rule"),
    (&["scan", "bar"], "bar_raise_governance.authority"),
    (
        &["mechanism", "intent"],
        "obsolete_mechanism_live_intent.dispositions",
    ),
    (&["issue"], "issue_filing_mandate.rule"),
    (
        &["branch", "macos"],
        "multi_host_development.platform_branches",
    ),
    (&["push", "merge"], "pre_push_gate.rule"),
    (&["obsolete", "close"], "closure_preconditions"),
    (&["dirty", "clean"], "clean_workspace_discipline.rule"),
];

/// Deterministically route a natural-language discipline question to a path
/// query. `None` means REFUSE — the caller must not fall back to anything.
pub fn route(question: &str) -> Option<&'static str> {
    let lower = question.to_ascii_lowercase();
    let mut matched: Vec<&'static str> = CANONICAL_QUESTIONS
        .iter()
        .filter(|(tokens, _)| tokens.iter().all(|t| lower.contains(t)))
        .map(|(_, path)| *path)
        .collect();
    matched.sort();
    matched.dedup();
    match matched.len() {
        1 => Some(matched[0]),
        _ => None,
    }
}

/// Answer a QUESTION: route it to a path, then answer the path. An unrouted
/// question is `unsupported` and says which paths it could have taken, so the
/// agent can re-ask as a path query instead of being told "no".
pub fn answer_question(corpus: &Corpus, question: &str, file_filter: Option<&str>) -> Envelope {
    match route(question) {
        Some(path) => answer_path_query(corpus, path, file_filter),
        None => {
            let candidates: Vec<String> = CANONICAL_QUESTIONS
                .iter()
                .map(|(tokens, path)| format!("{} -> {path}", tokens.join("+")))
                .collect();
            Envelope::unsupported(
                format!(
                    "no canonical methodology question matches {:?} unambiguously. \
                     This engine is a YAML PATH QUERY — ask it a path (e.g. \
                     `forge_cycle_budget.rule`) rather than prose. Routed forms: {}",
                    question,
                    candidates.join("; ")
                ),
                corpus.freshness(),
            )
        }
    }
}

// ── the text indexer ────────────────────────────────────────────────────────

fn collect_yaml(dir: &Path, root: &Path, depth: usize, out: &mut Vec<String>) {
    if depth > 8 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut paths: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
    paths.sort();
    for p in paths {
        if p.is_dir() {
            collect_yaml(&p, root, depth + 1, out);
            continue;
        }
        let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "yaml" && ext != "yml" {
            continue;
        }
        if let Ok(rel) = p.strip_prefix(root) {
            out.push(rel.to_string_lossy().replace('\\', "/"));
        }
    }
}

struct Frame {
    indent: usize,
    decl: String,
    /// Segment as it appears in a dotted path (`[3]` for a sequence item).
    seg: String,
    full: String,
    start: usize,
    seq_next: usize,
}

fn join_path(parent: &str, seg: &str) -> String {
    if parent.is_empty() {
        seg.to_string()
    } else if seg.starts_with('[') {
        format!("{parent}{seg}")
    } else {
        format!("{parent}.{seg}")
    }
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start_matches(' ').len()
}

/// Pop and CLOSE frames while `pred` holds. Sequence-item frames are popped
/// but never emitted (see the module doc: their span has no checkable token).
fn pop_while(
    stack: &mut Vec<Frame>,
    entries: &mut Vec<Entry>,
    end: usize,
    pred: impl Fn(&Frame) -> bool,
) {
    while stack.last().map(&pred).unwrap_or(false) {
        let f = stack.pop().expect("checked by last()");
        if !f.seg.starts_with('[') {
            entries.push(Entry {
                path: f.full,
                key: f.seg,
                decl: f.decl,
                line_start: f.start,
                line_end: end.max(f.start),
            });
        }
    }
}

/// Split `key: rest` (or a quoted key). `None` for anything that is not a
/// block-mapping key line — prose, plain sequence scalars, flow collections.
fn split_key(s: &str) -> Option<(String, String, &str)> {
    let first = s.chars().next()?;
    let (key, decl, after) = if first == '"' || first == '\'' {
        let end = s[1..].find(first)? + 1;
        let rest = &s[end + 1..];
        if !rest.starts_with(':') {
            return None;
        }
        // The DECLARATION TOKEN is taken verbatim, quotes included:
        // `"The Tlatoāni":` (methodology/distributed-work.yaml:845) declares a
        // key whose bare form `The Tlatoāni:` appears NOWHERE in the file, so
        // a citation built from the bare key would fail its own span check.
        (s[1..end].to_string(), s[..=end + 1].to_string(), &rest[1..])
    } else {
        let mut cut = None;
        for (p, c) in s.char_indices() {
            if c == ':' {
                let next = s[p + 1..].chars().next();
                if next.is_none() || next == Some(' ') {
                    cut = Some(p);
                    break;
                }
            }
        }
        let p = cut?;
        (
            s[..p].trim_end().to_string(),
            s[..=p].to_string(),
            &s[p + 1..],
        )
    };
    if key.is_empty()
        || key.contains(['{', '}', '[', ']', ',', '#'])
        || key.starts_with('&')
        || key.starts_with('*')
        || key.starts_with('!')
    {
        return None;
    }
    Some((key, decl, after))
}

/// `> …` / `| …` with the optional chomping and explicit-indent indicators.
/// Everything more-indented after such a key is OPAQUE TEXT — the single most
/// important rule in this scanner, because methodology prose is written in
/// folded scalars and is full of colons that would otherwise index as keys.
fn opens_block_scalar(rest: &str) -> bool {
    let t = rest.trim_start();
    let mut chars = t.chars();
    if !matches!(chars.next(), Some('>') | Some('|')) {
        return false;
    }
    let tail: String = chars.collect();
    let tail = tail.trim();
    let tail = tail.trim_start_matches(['+', '-']);
    let tail = tail.trim_start_matches(|c: char| c.is_ascii_digit());
    tail.is_empty() || tail.starts_with('#')
}

fn wildcard_tail_match(path: &str, q_segments: &[&str]) -> bool {
    let segs: Vec<&str> = path.split('.').collect();
    if q_segments.len() > segs.len() {
        return false;
    }
    let tail = &segs[segs.len() - q_segments.len()..];
    tail.iter()
        .zip(q_segments.iter())
        .all(|(s, q)| *q == "*" || s == q)
}

/// Index one YAML text into citable mapping-key spans.
pub fn index_text(text: &str) -> Vec<Entry> {
    let lines: Vec<&str> = text.lines().collect();
    let mut entries: Vec<Entry> = Vec::new();
    let mut stack: Vec<Frame> = Vec::new();
    let mut root_seq_next: usize = 0;
    let mut last_content: usize = 0;
    let mut block: Option<usize> = None;

    for (i, raw) in lines.iter().enumerate() {
        let ln = i + 1;
        let is_blank = raw.trim().is_empty();

        if let Some(block_indent) = block {
            if is_blank {
                continue;
            }
            if indent_of(raw) > block_indent {
                last_content = ln;
                continue;
            }
            block = None;
        }
        if is_blank {
            continue;
        }
        let indent = indent_of(raw);
        let trimmed = raw[indent..].trim_end();
        if trimmed.starts_with('#') {
            continue;
        }
        // The line that CLOSES a block ends it at the previous content line.
        let end = last_content;

        if trimmed == "---" || trimmed == "..." {
            pop_while(&mut stack, &mut entries, end, |_| true);
            root_seq_next = 0;
            last_content = ln;
            continue;
        }
        last_content = ln;

        let mut content_indent = indent;
        let mut rest = trimmed;

        if trimmed == "-" || trimmed.starts_with("- ") {
            // Deeper frames close; a SIBLING sequence item at the same indent
            // closes too. Everything shallower is the parent.
            pop_while(&mut stack, &mut entries, end, |f| {
                f.indent > indent || (f.indent == indent && f.seg.starts_with('['))
            });
            let n = match stack.last_mut() {
                Some(parent) => {
                    let n = parent.seq_next;
                    parent.seq_next += 1;
                    n
                }
                None => {
                    let n = root_seq_next;
                    root_seq_next += 1;
                    n
                }
            };
            let seg = format!("[{n}]");
            let parent_full = stack.last().map(|f| f.full.as_str()).unwrap_or("");
            let full = join_path(parent_full, &seg);
            stack.push(Frame {
                indent,
                seg,
                decl: String::new(),
                full,
                start: ln,
                seq_next: 0,
            });
            if trimmed == "-" {
                continue;
            }
            let after_dash = &trimmed[2..];
            content_indent = indent + 2 + (after_dash.len() - after_dash.trim_start().len());
            rest = after_dash.trim_start();
            if rest.is_empty() || rest.starts_with('#') {
                continue;
            }
        }

        let Some((key, decl, value)) = split_key(rest) else {
            continue;
        };
        pop_while(&mut stack, &mut entries, end, |f| {
            f.indent >= content_indent
        });
        let parent_full = stack.last().map(|f| f.full.as_str()).unwrap_or("");
        let full = join_path(parent_full, &key);
        stack.push(Frame {
            indent: content_indent,
            seg: key,
            decl,
            full,
            start: ln,
            seq_next: 0,
        });
        if opens_block_scalar(value) {
            block = Some(content_indent);
        }
    }

    pop_while(&mut stack, &mut entries, last_content, |_| true);
    entries.sort_by(|a, b| (a.line_start, &a.path).cmp(&(b.line_start, &b.path)));
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::answer::verify;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
    }

    fn corpus() -> Corpus {
        Corpus::load(&repo_root()).expect("the live methodology corpus loads")
    }

    /// The 10 canonical discipline questions of EXIT CRITERION (i), each paired
    /// with the YAML path it must resolve to and a VERBATIM fragment of the
    /// governing rule that EXIT CRITERION (ii) requires to be inside the cited
    /// span.
    ///
    /// The expected text is deliberately a quote from the corpus, not a
    /// paraphrase: if the rule is rewritten this test goes red and a human
    /// re-reads it, which is the only honest way to keep an expert's answers
    /// tied to the methodology they claim to speak for.
    const CANONICAL: &[(&str, &str, &str)] = &[
        (
            "may a forge cycle drain two packets?",
            "distributed_work.worker_agent_protocol.forge_cycle_budget.rule",
            "drain AT MOST ONE plan packet per cycle",
        ),
        (
            "is Python allowed in a committed script?",
            "methodology.runtime_language_policy.tlatoani_hard_no_python.rule",
            "Python is not allowed for Tillandsias runtime",
        ),
        (
            "may I embed a script in base64?",
            "methodology.runtime_language_policy.base64_script_injection_ban.rule",
            "base64-encoded string literals",
        ),
        (
            "who may raise the scan bar?",
            "bar_raise_governance.authority",
            "MUST approve every time",
        ),
        (
            "what happens to a dead mechanism with a live intent?",
            "philosophy.obsolete_mechanism_live_intent.dispositions",
            "mechanism_dead_intent_live",
        ),
        (
            "must I file an issue I observed outside my scope?",
            "methodology.cooperative_work_discipline.issue_filing_mandate.rule",
            "MUST be filed as a",
        ),
        (
            "which branch does macOS checkpoint to?",
            "multi_host_development.platform_branches",
            "macos: osx-next",
        ),
        (
            "must I merge origin/linux-next before pushing windows-next?",
            "multi_host_development.pull_merge_cadence.pre_push_gate.rule",
            "resolve all conflicts LOCALLY before",
        ),
        (
            "may I close a packet as obsolete?",
            "philosophy.obsolete_mechanism_live_intent.closure_preconditions",
            "the mechanism is verifiably absent at",
        ),
        (
            "may I start work in a dirty workspace without cleaning it?",
            "methodology.clean_workspace_discipline.rule",
            "MUST start and end with a completely clean work state",
        ),
    ];

    /// EXIT CRITERIA (i) AND (ii) TOGETHER.
    ///
    /// (i) each question routes to EXACTLY ONE path, answers with
    ///     `confidence: exact`, and carries a citation whose `file:line` the
    ///     394b verifier resolves;
    /// (ii) the cited span — re-read straight off disk here, NOT taken from the
    ///     envelope — contains the governing rule text verbatim.
    #[test]
    fn all_ten_canonical_questions_answer_with_an_exact_path_and_a_resolvable_file_line() {
        let corpus = corpus();
        let root = repo_root();
        assert_eq!(CANONICAL.len(), 10, "the packet asks for TEN questions");
        for (question, expected_path, governing_text) in CANONICAL {
            let routed = route(question)
                .unwrap_or_else(|| panic!("{question:?} must route to exactly one path"));
            let env = answer_question(&corpus, question, None);
            assert_eq!(
                env.confidence(),
                Confidence::Exact,
                "{question:?} (routed to {routed:?}) answered: {}",
                env.answer()
            );
            assert!(
                verify(&env, &root).is_empty(),
                "{question:?}: {:#?}",
                verify(&env, &root)
            );

            let c = env
                .citations()
                .iter()
                .find(|c| {
                    c.authority().get("yaml_path").map(String::as_str) == Some(*expected_path)
                })
                .unwrap_or_else(|| {
                    panic!(
                        "{question:?} must cite {expected_path}; cited {:?}",
                        env.citations()
                            .iter()
                            .map(|c| c.authority().get("yaml_path"))
                            .collect::<Vec<_>>()
                    )
                });

            // The file:line must be RENDERED in the answer an agent reads, not
            // merely present in the JSON — the whole point is that a human or
            // agent can open the exact lines.
            let anchor = format!("{}:{}-{}", c.path(), c.line_start(), c.line_end());
            assert!(
                env.answer().contains(&anchor),
                "{question:?}: answer must render the anchor {anchor}"
            );

            // EXIT (ii), independently re-derived from the file.
            let text = std::fs::read_to_string(root.join(c.path())).expect("cited file opens");
            let lines: Vec<&str> = text.lines().collect();
            let span = lines[c.line_start() - 1..c.line_end()].join("\n");
            assert!(
                span.contains(governing_text),
                "{question:?}: the cited span {anchor} must contain the governing rule text \
                 {governing_text:?}, got:\n{span}"
            );
        }
    }

    /// EXIT CRITERION (iii). A path nobody defined is a refusal, and the
    /// refusal must not smuggle in the block of a neighbouring key.
    #[test]
    fn an_unknown_path_returns_unsupported_never_a_guess() {
        let corpus = corpus();
        for q in [
            "does_not_exist_anywhere.rule",
            "methodology.runtime_language_policy.tlatoani_hard_no_ruby",
            "forge_cycle",            // a PREFIX of a real key — the tempting miss
            "forge_cycle_budget.rul", // a typo one character from a real path
            "",
            "...",
        ] {
            let env = answer_path_query(&corpus, q, None);
            assert_eq!(
                env.confidence(),
                Confidence::Unsupported,
                "{q:?} must be refused, got: {}",
                env.answer()
            );
            assert!(env.citations().is_empty(), "{q:?} must cite nothing");
            assert!(env.answer().starts_with("unsupported:"), "{q:?}");
            assert!(
                verify(&env, &repo_root()).is_empty(),
                "a refusal is still a well-formed envelope"
            );
            // The refusal must not contain the neighbouring rule's PROSE.
            assert!(
                !env.answer().contains("drain AT MOST ONE plan packet"),
                "{q:?}: a near miss leaked the neighbouring block as if it were an answer"
            );
        }
    }

    /// The router refuses both the unknown and the AMBIGUOUS. A question that
    /// matches two canonical routes is not answered about whichever came first.
    #[test]
    fn an_unrouted_or_ambiguous_question_is_refused() {
        let corpus = corpus();
        assert!(route("what is the airspeed velocity of an unladen swallow").is_none());
        assert!(
            route("is python allowed in base64").is_none(),
            "two routes match — that is ambiguity, not an answer"
        );
        for q in [
            "what is the airspeed velocity of an unladen swallow",
            "is python allowed in base64",
        ] {
            let env = answer_question(&corpus, q, None);
            assert_eq!(env.confidence(), Confidence::Unsupported);
            assert!(env.citations().is_empty());
            assert!(verify(&env, &repo_root()).is_empty());
        }
    }

    /// THE INDEX'S OWN FALSIFIABILITY. Every entry must START at a line that
    /// literally declares its key, and end inside the file. If the scanner
    /// mis-attributes a span, every citation built on it is a fabrication —
    /// so this is checked across the WHOLE corpus, not a fixture.
    #[test]
    fn every_indexed_entry_starts_at_its_own_key_line_and_ends_in_bounds() {
        let corpus = corpus();
        let root = repo_root();
        let mut checked = 0usize;
        for f in &corpus.files {
            let text = std::fs::read_to_string(root.join(&f.rel)).expect("corpus file opens");
            let lines: Vec<&str> = text.lines().collect();
            for e in &f.entries {
                assert!(
                    e.line_start >= 1 && e.line_end >= e.line_start,
                    "{f:?} {e:?}"
                );
                assert!(
                    e.line_end <= lines.len(),
                    "{}:{}-{} runs past {} lines",
                    f.rel,
                    e.line_start,
                    e.line_end,
                    lines.len()
                );
                let raw = lines[e.line_start - 1].trim_start();
                let raw = raw.strip_prefix("- ").unwrap_or(raw).trim_start();
                let key = e.key.as_str();
                assert!(
                    raw.starts_with(key)
                        || raw.starts_with(&format!("\"{key}\""))
                        || raw.starts_with(&format!("'{key}'")),
                    "{}:{} does not declare {key:?} (path {}), line is {raw:?}",
                    f.rel,
                    e.line_start,
                    e.path
                );
                // The DECLARATION TOKEN `key:` is what a citation from this
                // entry will ask 394b's verifier to find in the span. If any
                // entry in the corpus could not satisfy it, this engine would
                // emit citations its own verifier rejects.
                assert!(
                    lines[e.line_start - 1].contains(&e.decl),
                    "{}:{} cannot satisfy the span check for declaration {:?}: {raw:?}",
                    f.rel,
                    e.line_start,
                    e.decl
                );
                assert!(
                    e.decl.ends_with(':') && e.decl.contains(key),
                    "{}:{} declaration {:?} must be the key plus its colon",
                    f.rel,
                    e.line_start,
                    e.decl
                );
                checked += 1;
            }
        }
        assert!(
            checked > 3_000,
            "the corpus index collapsed to {checked} entries — the scanner regressed"
        );
    }

    /// THE SCANNER'S HARDEST RULE. Methodology prose lives in folded scalars
    /// and is full of colons; indexing one of those lines as a key would
    /// invent a YAML path that does not exist and cite prose as governance.
    #[test]
    fn folded_scalar_prose_is_never_indexed_as_a_key() {
        let raw = "\
policy:
  rule: >
    Operator directive 2026-07-02: this is the normal workflow.
    Note: colons inside folded prose are TEXT, not keys.
  checker: scripts/check-no-python-scripts.sh
literal:
  block: |
    key_that_is_not_a_key: value
  tail: done
";
        let entries = index_text(raw);
        let paths: Vec<&str> = entries.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(
            paths,
            vec![
                "policy",
                "policy.rule",
                "policy.checker",
                "literal",
                "literal.block",
                "literal.tail"
            ]
        );
        let rule = entries.iter().find(|e| e.path == "policy.rule").unwrap();
        assert_eq!(
            (rule.line_start, rule.line_end),
            (2, 4),
            "a folded scalar's span covers its whole body"
        );
        assert!(
            !paths.iter().any(|p| p.contains("Operator directive")
                || p.contains("Note")
                || p.contains("key_that_is_not_a_key")),
            "prose leaked into the path index: {paths:?}"
        );
    }

    /// Sequence items get a `[n]` segment so nested keys stay uniquely
    /// addressable, but the item itself is NOT citable: its span starts with
    /// `- `, so there would be no token in it to check a claim against.
    #[test]
    fn sequence_items_are_addressable_but_only_mapping_keys_are_citable() {
        let raw = "\
rules:
  - first_rule: >
      do the thing
  - second_rule: >
      do the other thing
plain_list:
  - alpha
  - beta
";
        let entries = index_text(raw);
        let paths: Vec<&str> = entries.iter().map(|e| e.path.as_str()).collect();
        assert_eq!(
            paths,
            vec![
                "rules",
                "rules[0].first_rule",
                "rules[1].second_rule",
                "plain_list"
            ]
        );
        assert!(
            !paths.iter().any(|p| p.ends_with(']')),
            "a bare sequence item must not be citable: {paths:?}"
        );
        let second = entries
            .iter()
            .find(|e| e.path == "rules[1].second_rule")
            .unwrap();
        assert_eq!((second.line_start, second.line_end), (4, 5));
    }

    /// A citation is only evidence if the check CAN fail. These are the three
    /// ways a methodology citation could be fabricated; each must be refused.
    #[test]
    fn a_fabricated_methodology_citation_is_refused() {
        let corpus = corpus();
        let root = repo_root();
        let env = answer_path_query(&corpus, "tlatoani_hard_no_python.rule", None);
        assert_eq!(env.confidence(), Confidence::Exact);
        let good = &env.citations()[0];

        // (a) the range shifted off the rule — resolvable, in-bounds, wrong.
        let shifted = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                1,
                2,
                CitationKind::Methodology,
                good.authority().clone(),
            )],
            Confidence::Exact,
            corpus.freshness(),
        );
        assert!(
            verify(&shifted, &root)
                .iter()
                .any(|v| v.contains("FABRICATED")),
            "a span that does not declare the key must be refused: {:#?}",
            verify(&shifted, &root)
        );

        // (b) a file that does not exist.
        let nowhere = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                "methodology/invented-by-the-test.yaml".into(),
                1,
                2,
                CitationKind::Methodology,
                good.authority().clone(),
            )],
            Confidence::Exact,
            corpus.freshness(),
        );
        assert!(
            verify(&nowhere, &root)
                .iter()
                .any(|v| v.contains("does not resolve"))
        );

        // (c) a citation carrying no `key` at all is unfalsifiable, so it is a
        // violation in itself — a future citation kind cannot ship uncheckable.
        let keyless = Envelope::supported(
            env.answer(),
            vec![Citation::new(
                good.path().into(),
                good.line_start(),
                good.line_end(),
                CitationKind::Methodology,
                BTreeMap::new(),
            )],
            Confidence::Exact,
            corpus.freshness(),
        );
        assert!(
            verify(&keyless, &root)
                .iter()
                .any(|v| v.contains("no authority.key"))
        );
    }

    /// Every answer this engine can produce must survive the 394b verifier.
    /// Sampled across the whole corpus rather than a fixture, because a
    /// scanner bug would show up in an obscure file, not the one we wrote the
    /// test against.
    #[test]
    fn a_stratified_sample_of_the_whole_corpus_answers_verifiably() {
        let corpus = corpus();
        let root = repo_root();
        let mut sampled = 0usize;
        for (i, f) in corpus.files.iter().enumerate() {
            // one deterministic entry per file, rotated so different depths get
            // exercised across the corpus
            if f.entries.is_empty() {
                continue;
            }
            let e = &f.entries[(i * 7) % f.entries.len()];
            let env = answer_path_query(&corpus, &e.path, Some(&f.rel));
            assert_eq!(
                env.confidence(),
                Confidence::Exact,
                "{}:{} {} answered: {}",
                f.rel,
                e.line_start,
                e.path,
                env.answer()
            );
            let violations = verify(&env, &root);
            assert!(
                violations.is_empty(),
                "{}:{} {}: {violations:#?}",
                f.rel,
                e.line_start,
                e.path
            );
            sampled += 1;
        }
        assert!(sampled >= 50, "only {sampled} files sampled");
    }

    /// `serde_yaml` is the corpus's independent parser. A file it refuses is a
    /// file whose spans nobody should trust, so the set of such files is
    /// pinned as a SUBSET of what is known-broken at HEAD: fixing one keeps
    /// this green, breaking a new one turns it red.
    #[test]
    fn no_new_methodology_file_stops_parsing_as_yaml() {
        let corpus = corpus();
        // Known defect at HEAD: methodology_provenance.claims[5] declares
        // `limits:` twice (methodology/provenance.yaml:222). Reported to the
        // coordinator for filing under the issue_filing_mandate.
        const KNOWN_BROKEN: &[&str] = &["methodology/provenance.yaml"];
        let unexpected: Vec<(&str, &str)> = corpus
            .parse_errors()
            .into_iter()
            .filter(|(rel, _)| !KNOWN_BROKEN.contains(rel))
            .collect();
        assert!(
            unexpected.is_empty(),
            "methodology files stopped parsing: {unexpected:#?}"
        );
    }

    /// The corpus really is both roots, and both are reachable from one query
    /// surface. A regression that silently dropped `methodology/**` would leave
    /// every discipline question answerable only from the 290-line root file.
    #[test]
    fn the_corpus_spans_the_root_file_and_the_directory_tree() {
        let corpus = corpus();
        assert!(corpus.files.iter().any(|f| f.rel == "methodology.yaml"));
        assert!(
            corpus
                .files
                .iter()
                .any(|f| f.rel == "methodology/distributed-work.yaml")
        );
        assert!(
            corpus
                .files
                .iter()
                .any(|f| f.rel.starts_with("methodology/bootstrap/")),
            "the recursive walk must reach methodology/bootstrap/"
        );
        assert!(corpus.entry_count() > 3_000);
    }

    /// Path resolution is TIERED: an exact full-path query is never diluted by
    /// the suffix matches that would also have hit.
    #[test]
    fn an_exact_path_wins_over_every_suffix_match() {
        let corpus = corpus();
        let (suffix_hits, kind) = corpus.query("rule", None);
        assert_eq!(kind, MatchKind::Suffix);
        assert!(
            suffix_hits.len() > 20,
            "`rule` is a common key: {}",
            suffix_hits.len()
        );
        let (exact_hits, kind) = corpus.query(
            "methodology.runtime_language_policy.tlatoani_hard_no_python.rule",
            None,
        );
        assert_eq!(kind, MatchKind::Exact);
        assert_eq!(exact_hits.len(), 1);
        assert_eq!(exact_hits[0].file, "methodology.yaml");
    }
}
