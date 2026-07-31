// @trace spec:fat-spec-corpus-index
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
use std::collections::BTreeMap;
use std::collections::hash_map::DefaultHasher;
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
        _ => CitationKind::Spec,
    }
}

/// The corpus roots and the citation-kind each maps to. Kept as data so a new
/// corpus is one row, not a code change.
const CORPUS_ROOTS: &[(&str, &str)] = &[
    ("openspec/specs", "spec"),
    ("cheatsheets", "cheatsheet"),
    ("docs/cheatsheets", "cheatsheet"),
    ("methodology", "methodology"),
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
        let want_ext: &[&str] = if *kind == "methodology" {
            &["yaml", "yml"]
        } else {
            &["md"]
        };
        let mut files = walk_files(&dir, want_ext);
        files.sort(); // deterministic ordering => stable chunk ids for a given tree
        for file in files {
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let rel = to_repo_relative(root, &file);
            let file_chunks = if *kind == "methodology" {
                chunk_yaml(&rel, kind, &text)
            } else {
                chunk_markdown(&rel, kind, &text)
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

fn walk_files(dir: &Path, exts: &[&str]) -> Vec<PathBuf> {
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
            } else if let Some(ext) = p.extension().and_then(|e| e.to_str())
                && exts.iter().any(|w| w.eq_ignore_ascii_case(ext))
            {
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

/// Section chunker for Markdown: each chunk spans a heading line to the line
/// before the next heading (or EOF). Content before the first heading becomes a
/// preamble chunk keyed on the first non-empty line. `key` is always a literal
/// substring of the chunk span.
pub fn chunk_markdown(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }
    // Boundary line indices (0-based) where a new section starts.
    let mut starts: Vec<usize> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if md_heading(l).is_some() {
            starts.push(i);
        }
    }
    let mut chunks = Vec::new();
    // Preamble (before the first heading), if it has any non-blank content.
    let first_heading = starts.first().copied().unwrap_or(lines.len());
    if first_heading > 0
        && let Some(k) = lines[..first_heading].iter().find(|l| !l.trim().is_empty())
    {
        let key = distinctive_key(k.trim());
        push_chunk(&mut chunks, rel_path, kind, 1, first_heading, &key, &lines);
    }
    for (idx, &s) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).copied().unwrap_or(lines.len());
        let key = md_heading(lines[s]).unwrap_or("section").to_string();
        // s is 0-based; citation lines are 1-indexed inclusive.
        push_chunk(&mut chunks, rel_path, kind, s + 1, end, &key, &lines);
    }
    chunks
}

/// Section chunker for YAML: each chunk spans a top-level (column-0) key to the
/// line before the next top-level key. `key` is the top-level key name, a
/// literal substring of the span.
pub fn chunk_yaml(rel_path: &str, kind: &str, text: &str) -> Vec<Chunk> {
    let lines: Vec<&str> = text.lines().collect();
    let mut starts: Vec<usize> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if is_top_level_key(l) {
            starts.push(i);
        }
    }
    if starts.is_empty() {
        // A yaml file with no column-0 key: one whole-file chunk keyed on the
        // first non-blank line, so nothing is silently dropped.
        if let Some(k) = lines.iter().find(|l| !l.trim().is_empty()) {
            let key = distinctive_key(k.trim());
            let mut chunks = Vec::new();
            push_chunk(&mut chunks, rel_path, kind, 1, lines.len().max(1), &key, &lines);
            return chunks;
        }
        return Vec::new();
    }
    let mut chunks = Vec::new();
    for (idx, &s) in starts.iter().enumerate() {
        let end = starts.get(idx + 1).copied().unwrap_or(lines.len());
        let key = top_level_key_name(lines[s]);
        push_chunk(&mut chunks, rel_path, kind, s + 1, end, &key, &lines);
    }
    chunks
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
    let cleaned = raw.trim_start_matches(['#', '-', ' ', '\t']).trim();
    let cleaned = if cleaned.is_empty() { raw.trim() } else { cleaned };
    cleaned.chars().take(80).collect()
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
    if line_end < line_start {
        return;
    }
    let span = lines[line_start - 1..line_end].join("\n");
    if span.trim().is_empty() {
        return;
    }
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

// ── envelope construction (verifiable) ──────────────────────────────────────

/// Build an answer envelope from `answer` prose plus the retrieved `chunks`,
/// KEEPING ONLY the citations whose key the answer text actually mentions
/// (non-decorative) — the same falsifiability the deterministic layer enforces.
/// If no citation survives, the result is [`Envelope::unsupported`], never a
/// guess. `source` drives the freshness block.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_chunk_keys_are_in_their_span() {
        let text = "preamble line\n\n## Purpose\nbody a\nbody b\n\n## Egress allowlist\ndeny by default\n";
        let chunks = chunk_markdown("openspec/specs/x/spec.md", "spec", text);
        assert!(chunks.len() >= 3, "preamble + 2 headings, got {}", chunks.len());
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
            vec![0.0f32, 1.0, 0.0], // orthogonal
            vec![0.9f32, 0.1, 0.0], // aligned
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
        let env2 = build_envelope("The Egress allowlist denies by default.", &chunks, Path::new("."));
        assert_eq!(env2.confidence(), Confidence::Retrieved);
        assert_eq!(env2.citations().len(), 1);
    }

    #[test]
    fn retrieval_only_answer_contains_every_key() {
        let chunks = vec![
            Chunk { id: 0, path: "a.md".into(), line_start: 1, line_end: 1, kind: "spec".into(), key: "Alpha".into(), content_hash: "0".into(), text: "Alpha".into() },
            Chunk { id: 1, path: "b.md".into(), line_start: 1, line_end: 1, kind: "spec".into(), key: "Beta".into(), content_hash: "0".into(), text: "Beta".into() },
        ];
        let ans = retrieval_only_answer(&chunks);
        let env = build_envelope(&ans, &chunks, Path::new("."));
        assert_eq!(env.citations().len(), 2, "retrieval-only keeps all citations");
    }
}
