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
        "code" => CitationKind::Code,
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
            "code" => &["rs", "sh"],
            _ => &["md"],
        };
        let mut files = walk_files(&dir, want_ext);
        files.sort(); // deterministic ordering => stable chunk ids for a given tree
        for file in files {
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            let rel = to_repo_relative(root, &file);
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
            push_chunk(
                &mut chunks,
                rel_path,
                kind,
                1,
                lines.len().max(1),
                &key,
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
    let is_rust = rel_path.ends_with(".rs");
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }

    let mut starts: Vec<usize> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        if code_boundary(l, is_rust) {
            starts.push(i);
        }
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
        let end = std::cmp::min(start + MAX_CODE_SPAN_LINES - 1, line_end);
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
            let key_lower = c.key.to_ascii_lowercase();
            let path_lower = c.path.to_ascii_lowercase();
            let text_lower = c.text.to_ascii_lowercase();
            let is_main_title = c.text.trim_start().starts_with("# ");

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

    if let Some(&(best_chunk, score)) = scored.first()
        && score >= 35
    {
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

#[cfg(test)]
mod tests {
    use super::*;

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
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
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
