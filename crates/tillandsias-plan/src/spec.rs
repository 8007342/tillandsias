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
        push_md_span(&mut chunks, rel_path, kind, s + 1, end, &key, &lines);
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
fn push_md_span(
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
            d > own_depth && md_heading(lines[i]).is_some()
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
            push_md_span(out, rel_path, kind, c + 1, end, &sub, lines);
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
        push_yaml_span(&mut chunks, rel_path, kind, s + 1, end, &key, &lines);
    }
    chunks
}

/// The largest chunk this indexer will emit, in characters.
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
const MAX_YAML_CHUNK_CHARS: usize = 4000;

/// Emit `[start, end]` as chunks, subdividing at deeper indentation until each
/// fits [`MAX_YAML_CHUNK_CHARS`].
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
fn push_yaml_span(
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
    let len: usize = lines[line_start - 1..line_end]
        .iter()
        .map(|l| l.len() + 1)
        .sum();
    if len <= MAX_YAML_CHUNK_CHARS {
        push_chunk(out, rel_path, kind, line_start, line_end, key, lines);
        return;
    }

    // Find the shallowest indentation INSIDE this span that yields more than
    // one key. Shallowest first keeps the pieces as large — and as coherent —
    // as the budget allows.
    for indent in [2usize, 4, 6, 8] {
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
        if cuts.len() < 2 {
            continue;
        }
        // The head — the parent key line and anything before the first cut —
        // stays with the parent so the block is not orphaned from its name.
        let first = cuts[0];
        if first > line_start - 1 {
            push_chunk(out, rel_path, kind, line_start, first, key, lines);
        }
        for (n, &c) in cuts.iter().enumerate() {
            let end = cuts.get(n + 1).copied().unwrap_or(line_end);
            let sub = lines[c].trim().trim_end_matches(':');
            let sub_key = format!("{key}.{}", sub.split(':').next().unwrap_or(sub).trim());
            push_yaml_span(out, rel_path, kind, c + 1, end, &sub_key, lines);
        }
        return;
    }

    // No inner keys: fall back to fixed line windows so an enormous prose block
    // is still embedded in full rather than truncated to its first 6000 chars.
    let mut s = line_start;
    while s <= line_end {
        let mut e = s;
        let mut acc = 0usize;
        while e <= line_end && acc + lines[e - 1].len() < MAX_YAML_CHUNK_CHARS {
            acc += lines[e - 1].len() + 1;
            e += 1;
        }
        if e == s {
            e = s + 1; // one line longer than the budget: emit it alone
        }
        push_chunk(out, rel_path, kind, s, e - 1, key, lines);
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
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
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
