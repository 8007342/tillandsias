//! tillandsias-plan — agent-facing CLI over the plan ledger engine.
//!
//! Slice 1 (read-only): query + integrity check. The edit surface
//! (claim/event-append/status-flip with validated flushes) is slice 2.
//!
//! @trace spec:spec-traceability

use std::path::{Path, PathBuf};
use tillandsias_plan::{Ledger, Schema, answer, edit, groundtruth, methodology, spec};

fn usage() -> ! {
    eprintln!(
        "usage: tillandsias-plan [--index <path>] <command>\n\
         commands:\n\
           check                     integrity + schema validation (exit 1 on violations)\n\
           status <id|order>         one packet's status line\n\
           blocked-by <id|order>     packets directly blocked by X\n\
           blocked-closure <id|order> everything transitively downstream of X\n\
           ready [role]              ready packets (optionally for a pickup role)\n\
           burndown <milestone>      release-target children with statuses\n\
           answer <question...>      the CITED answer envelope as JSON (order 394b)\n\
           verify-answer [--root D]  read an envelope on stdin; exit 1 if any citation\n\
                                     does not resolve or its span does not contain the claim\n\
           methodology [--root D] [--file S] <yaml.path>\n\
                                     ORDER 394c. YAML path query over methodology.yaml and\n\
                                     methodology/**/*.yaml. Prints the 394b envelope: the\n\
                                     matched block plus a resolvable file:line. An unknown\n\
                                     path is confidence=unsupported, never a guess.\n\
           methodology-ask [--root D] [--file S] <question...>\n\
                                     route a canonical discipline question to its YAML path,\n\
                                     then answer it. Unrouted questions are unsupported.\n\
           methodology-index [--root D]\n\
                                     every indexed path with its file:line (the query surface)\n\
           append-event <id|order> <type> <summary> --ts <ISO> [--agent A] [--host H]\n\
                                     append an event, VALIDATED before flush (refuses a broken ledger)\n\
           grade [--root D] [--case ID] [--envelope F|-] [--list-engines] [SET.yaml ...]\n\
                                     ORDER 394d. Grade the experts against the COMMITTED ground\n\
                                     truth. Defaults to openspec/litmus-tests/groundtruth/\n\
                                     expert-groundtruth-rung1.yaml; pass more query sets (or a\n\
                                     glob) to grade further corpora with the same harness.\n\
                                     --envelope grades ONE case against an envelope captured\n\
                                     elsewhere (e.g. off the MCP server). Exit 1 = graded RED,\n\
                                     exit 2 = the harness could not run at all."
    );
    std::process::exit(2);
}

/// ORDER 523 (R2). Emit an envelope only after it verifies against the root its
/// own citations are relative to — and downgrade to `unsupported` naming the
/// violations when it does not.
///
/// `answer::verify` existed and was exercised only by `verify-answer` and the
/// litmus, i.e. by whoever chose to run it. Nothing on the RUNTIME path called
/// it, so an envelope could be emitted with `confidence: exact` carrying a
/// citation that `verify-answer` would refuse against the same checkout —
/// reachable in practice because the MCP wrapper probes several candidate index
/// locations and caches the first non-empty one, so the root the paths were built
/// against need not be the root a reader resolves them from.
///
/// Running the verifier at the exit point makes it unavoidable: the emitter and
/// the checker can no longer disagree about the same envelope, because the
/// emitter IS a checker.
///
/// Exits 0 in every case, including a downgrade: `unsupported` is a well-formed
/// answer, and the forge-plan MCP wrapper runs under `set -e` where a non-zero
/// status kills the server mid-request. The envelope is the signal.
fn emit_verified_envelope(envelope: answer::Envelope, root: &Path) {
    match serde_json::to_string_pretty(&self_verified(envelope, root)) {
        Ok(json) => println!("{json}"),
        Err(e) => {
            eprintln!("error: serialize envelope: {e}");
            std::process::exit(1);
        }
    }
}

/// The pure half of [`emit_verified_envelope`], split out so the downgrade is
/// unit-testable without capturing stdout. Returns the envelope unchanged when it
/// verifies, and a self-refusal naming every violation when it does not.
fn self_verified(envelope: answer::Envelope, root: &Path) -> answer::Envelope {
    let envelope = if envelope.confidence() != answer::Confidence::Unsupported {
        envelope.with_citation_root(root)
    } else {
        envelope
    };
    let violations = answer::verify(&envelope, root);
    if violations.is_empty() {
        return envelope;
    }
    answer::Envelope::unsupported(
        format!(
            "this answer FAILED its own citation check against {} and was withheld \
             ({} violation(s)): {}",
            root.display(),
            violations.len(),
            violations.join("; ")
        ),
        envelope.freshness().clone(),
    )
}

/// The repo-relative path the citations carry. A citation must name a path a
/// READER can open from the checkout root, so an absolute or `../`-laden
/// `--index` is reduced to its `plan/index.yaml`-shaped tail.
///
/// The tail is only ever used as a LABEL: `verify-answer` re-resolves it
/// against the root and re-reads the span, so a wrong label is caught there
/// rather than being trusted — and since order 523 the emitter runs that same
/// check itself before printing, so a wrong label is caught at emission too.
fn citation_path(index: &Path, root: &Path) -> String {
    if let Ok(rel) = index.strip_prefix(root) {
        return rel.to_string_lossy().replace('\\', "/");
    }
    let comps: Vec<String> = index
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect();
    match comps.iter().rposition(|c| c == "plan") {
        Some(i) => comps[i..].join("/"),
        None => index.to_string_lossy().replace('\\', "/"),
    }
}

/// The checkout the citation paths are resolved against: the parent of the
/// index's `plan/` directory, falling back to the process cwd.
fn root_for(index: &Path) -> PathBuf {
    let candidate = index
        .parent()
        .and_then(Path::parent)
        .filter(|p| !p.as_os_str().is_empty())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    candidate.canonicalize().unwrap_or(candidate)
}

fn line(ledger: &Ledger, p: &serde_yaml::Value) -> String {
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
    format!("{order}\t{status}\t{id}")
}

/// Distinguish "resolves, blocks nothing" from "does not resolve" for the
/// list-shaped queries, which otherwise report both as an empty stdout.
/// Diagnostic only — stdout and the exit code are untouched.
fn warn_if_unresolved(ledger: &Ledger, reference: &str) {
    if ledger.resolve(reference).is_none() {
        eprintln!(
            "warning: no packet matches '{reference}' — the empty result below means UNRESOLVED, not 'nothing depends on it'"
        );
    }
}

/// ORDER 394d — `grade`. Returns the PROCESS EXIT CODE, kept distinct on
/// purpose:
///   0 — every graded case matched its committed expected answer;
///   1 — at least one case is RED (the harness worked and disagreed);
///   2 — the harness could not run (missing/foreign/empty query set, unknown
///       engine, unreadable corpus).
///
/// Collapsing 1 and 2 is how a grading gate rots into a no-op: "the query set
/// file moved" would then read exactly like "the experts are correct".
fn run_grade(args: &[String], index: &Path) -> i32 {
    let mut index = index.to_path_buf();
    let mut root = root_for(&index);
    let mut root_explicit = false;
    let mut only_case: Option<String> = None;
    let mut envelope_src: Option<String> = None;
    let mut sets: Vec<PathBuf> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--root" => {
                i += 1;
                if let Some(r) = args.get(i) {
                    root = PathBuf::from(r);
                    root_explicit = true;
                }
            }
            // Accepted HERE as well as in the leading position. `--index` is
            // otherwise only legal before the subcommand, and a misplaced one
            // used to be swallowed as a query-set path — a flag that silently
            // becomes a filename is how a grading run ends up reading the
            // wrong ledger.
            "--index" => {
                i += 1;
                if let Some(p) = args.get(i) {
                    index = PathBuf::from(p);
                    if !root_explicit {
                        root = root_for(&index);
                    }
                }
            }
            "--case" => {
                i += 1;
                only_case = args.get(i).cloned();
            }
            "--envelope" => {
                i += 1;
                envelope_src = args.get(i).cloned();
            }
            "--list-engines" => {
                for (name, what) in groundtruth::ENGINES {
                    println!("{name}\t{what}");
                }
                return 0;
            }
            other if other.starts_with('-') => {
                // An UNKNOWN flag is a hard stop, never a positional path: a
                // typo'd `--cases` swallowed as a query-set filename would
                // grade the wrong thing and report it as an ordinary miss.
                eprintln!(
                    "HARNESS ERROR: unknown option {other:?} for `grade` (known: --root, --index, --case, --envelope, --list-engines)"
                );
                return 2;
            }
            other => sets.push(PathBuf::from(other)),
        }
        i += 1;
    }
    if sets.is_empty() {
        sets.push(root.join("openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml"));
    }

    let query_sets = match groundtruth::load_all(&sets) {
        Ok(q) => q,
        Err(e) => {
            eprintln!("HARNESS ERROR: {e}");
            return 2;
        }
    };
    let selected: Vec<&groundtruth::Case> = query_sets
        .iter()
        .flat_map(|q| q.cases.iter())
        .filter(|c| only_case.as_deref().is_none_or(|id| c.id == id))
        .collect();
    if selected.is_empty() {
        eprintln!(
            "HARNESS ERROR: --case {:?} matches no case in {}",
            only_case.unwrap_or_default(),
            sets.iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
        return 2;
    }

    let started = std::time::Instant::now();
    let mut outcomes: Vec<groundtruth::Outcome> = Vec::new();

    if let Some(src) = envelope_src {
        // ENVELOPE MODE: grade a captured envelope — the one an agent actually
        // received, e.g. off the MCP server — against the SAME committed
        // expectation the in-process run uses. Same bar, different transport.
        if selected.len() != 1 {
            eprintln!(
                "HARNESS ERROR: --envelope grades exactly one case; {} are selected (pass --case ID)",
                selected.len()
            );
            return 2;
        }
        let raw = if src == "-" {
            let mut buf = String::new();
            match std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf) {
                Ok(_) => buf,
                Err(e) => {
                    eprintln!("HARNESS ERROR: read envelope from stdin: {e}");
                    return 2;
                }
            }
        } else {
            match std::fs::read_to_string(&src) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("HARNESS ERROR: read envelope {src}: {e}");
                    return 2;
                }
            }
        };
        let envelope: answer::Envelope = match serde_json::from_str(&raw) {
            Ok(e) => e,
            Err(e) => {
                // A malformed envelope is a graded FAILURE, not a harness
                // error: "the tool returned something that is not an envelope"
                // is exactly the order-456 dead-on-arrival regression this
                // harness exists to catch.
                outcomes.push(groundtruth::Outcome {
                    id: selected[0].id.clone(),
                    engine: format!("{} (captured envelope)", selected[0].engine),
                    failures: vec![format!("input is not an answer envelope: {e}")],
                });
                report(&outcomes, &sets, started);
                return 1;
            }
        };
        outcomes.push(groundtruth::Outcome {
            id: selected[0].id.clone(),
            engine: format!("{} (captured envelope)", selected[0].engine),
            failures: groundtruth::grade_envelope(&envelope, &selected[0].expect, &root),
        });
    } else {
        let index_rel = citation_path(&index, &root);
        let mut harness = groundtruth::Harness::new(root.clone(), index.clone(), index_rel);
        for case in &selected {
            let envelope = match harness.run(case) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("HARNESS ERROR: {e}");
                    return 2;
                }
            };
            outcomes.push(groundtruth::Outcome {
                id: case.id.clone(),
                engine: case.engine.clone(),
                failures: groundtruth::grade_envelope(&envelope, &case.expect, &root),
            });
        }
    }

    let failed = report(&outcomes, &sets, started);
    i32::from(failed > 0)
}

/// Print the per-case verdicts plus ONE machine-readable summary line, and
/// return the failure count.
fn report(
    outcomes: &[tillandsias_plan::groundtruth::Outcome],
    sets: &[PathBuf],
    started: std::time::Instant,
) -> usize {
    let mut failed = 0;
    for o in outcomes {
        if o.passed() {
            println!("PASS  {}  [{}]", o.id, o.engine);
            continue;
        }
        failed += 1;
        println!("FAIL  {}  [{}]", o.id, o.engine);
        for f in &o.failures {
            println!("        - {f}");
        }
    }
    println!(
        "groundtruth-result: sets={} total={} pass={} fail={} elapsed_ms={}",
        sets.len(),
        outcomes.len(),
        outcomes.len() - failed,
        failed,
        started.elapsed().as_millis()
    );
    failed
}

// ── order 547 index I/O helpers (JSONL / JSON, dependency-only serde_json) ───

fn read_chunks(path: &Path) -> Vec<spec::Chunk> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<spec::Chunk>(line) {
            Ok(c) => out.push(c),
            Err(e) => {
                eprintln!("error: {}:{}: not a chunk record: {e}", path.display(), n + 1);
                std::process::exit(1);
            }
        }
    }
    out
}

fn read_chunks_array(path: &Path) -> Vec<spec::Chunk> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    serde_json::from_str::<Vec<spec::Chunk>>(&text).unwrap_or_else(|e| {
        eprintln!("error: {} is not a JSON array of chunks: {e}", path.display());
        std::process::exit(1);
    })
}

fn read_vectors(path: &Path) -> Vec<Vec<f32>> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    let mut out = Vec::new();
    for (n, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Vec<f32>>(line) {
            Ok(v) => out.push(v),
            Err(e) => {
                eprintln!("error: {}:{}: not a float vector: {e}", path.display(), n + 1);
                std::process::exit(1);
            }
        }
    }
    out
}

fn read_query_vec(path: &Path) -> Vec<f32> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: read {}: {e}", path.display());
        std::process::exit(1);
    });
    serde_json::from_str::<Vec<f32>>(text.trim()).unwrap_or_else(|e| {
        eprintln!("error: {} is not a JSON float array: {e}", path.display());
        std::process::exit(1);
    })
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut index = PathBuf::from("plan/index.yaml");
    if args.first().map(String::as_str) == Some("--index") {
        args.remove(0);
        if args.is_empty() {
            usage();
        }
        index = PathBuf::from(args.remove(0));
    }
    if args.is_empty() {
        usage();
    }

    // ORDER 394b. `verify-answer` deliberately runs BEFORE the ledger is
    // loaded: it audits an envelope's citations against the CHECKOUT, and a
    // verifier that needed the corpus it is auditing could not be pointed at
    // an envelope captured elsewhere.
    if args[0] == "verify-answer" {
        let mut root = root_for(&index);
        let mut root_explicit = false;
        if let Some(i) = args.iter().position(|a| a == "--root")
            && let Some(r) = args.get(i + 1)
        {
            root = PathBuf::from(r);
            root_explicit = true;
        }
        let mut raw = String::new();
        if let Err(e) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut raw) {
            eprintln!("error: read stdin: {e}");
            std::process::exit(1);
        }
        let envelope: answer::Envelope = match serde_json::from_str(&raw) {
            Ok(e) => e,
            Err(e) => {
                // A malformed envelope is a FAILED verification, never a pass.
                eprintln!("REFUSED: input is not an answer envelope: {e}");
                std::process::exit(1);
            }
        };
        if !root_explicit && let Some(r) = envelope.citation_root() {
            root = PathBuf::from(r);
        }
        let violations = answer::verify(&envelope, &root);
        if violations.is_empty() {
            println!(
                "ok: envelope verified — {} citation(s) resolve, confidence={:?}",
                envelope.citations().len(),
                envelope.confidence()
            );
            return;
        }
        eprintln!("REFUSED: {} citation violation(s):", violations.len());
        for v in &violations {
            eprintln!("  violation: {v}");
        }
        std::process::exit(1);
    }

    // ORDER 394d. `grade` runs BEFORE the ledger load for the same reason
    // `verify-answer` does: it owns its corpora (it loads each at most once and
    // reuses it across cases), and a query set that grades only the methodology
    // corpus must still run in a checkout whose plan ledger is broken.
    if args[0] == "grade" {
        std::process::exit(run_grade(&args[1..], &index));
    }

    // ORDER 394c. The methodology corpus is a DIFFERENT corpus from the plan
    // ledger, so these subcommands run before (and independently of) the
    // ledger load — a checkout with a broken or absent plan/index.yaml must
    // still be able to answer a runtime-language-policy question.
    //
    // (Deliberately NOT spelling that question out here: order 394b's
    // no-python litmus step word-greps this file, and the canonical question
    // this engine answers names the very interpreter the policy bans. The
    // question itself lives in methodology.rs::CANONICAL_QUESTIONS, whose
    // no-interpreter guarantee is asserted structurally instead — the module
    // spawns no subprocess at all.)
    if args[0].starts_with("methodology") {
        let mut root = root_for(&index);
        let mut file_filter: Option<String> = None;
        let mut rest: Vec<String> = Vec::new();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--root" => {
                    i += 1;
                    if let Some(r) = args.get(i) {
                        root = PathBuf::from(r);
                    }
                }
                "--file" => {
                    i += 1;
                    file_filter = args.get(i).cloned();
                }
                other => rest.push(other.to_string()),
            }
            i += 1;
        }
        let corpus = match methodology::Corpus::load(&root) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        };
        for (file, err) in corpus.parse_errors() {
            eprintln!("warning: {file} does not parse as YAML ({err}) — its spans are suspect");
        }
        if args[0] == "methodology-index" {
            for f in &corpus.files {
                for e in &f.entries {
                    println!("{}:{}-{}\t{}", f.rel, e.line_start, e.line_end, e.path);
                }
            }
            return;
        }
        let query = rest.join(" ");
        // EXIT 0 EVEN WHEN UNSUPPORTED, for the same reason `answer` does: the
        // MCP wrapper runs under `set -e` and the envelope IS the signal.
        let envelope = match args[0].as_str() {
            "methodology" => {
                methodology::answer_path_query(&corpus, &query, file_filter.as_deref())
            }
            "methodology-ask" => {
                methodology::answer_question(&corpus, &query, file_filter.as_deref())
            }
            _ => usage(),
        };
        // ORDER 523 (R2): self-verify before emitting. The methodology corpus
        // root IS the checkout, so citations resolve against `root`.
        emit_verified_envelope(envelope, &root);
        return;
    }

    // ORDER 547. The whole-spec RAG corpus (openspec/specs + cheatsheets +
    // methodology) is a DIFFERENT corpus from the plan ledger, so — like
    // `methodology` — these run before (and independently of) the ledger load.
    // The crate stays network-free: `spec-index` chunks, `spec-retrieve` does
    // cosine top-k over caller-supplied embeddings, `spec-envelope` builds a
    // verifiable answer envelope. Embedding + synthesis are the caller's shell
    // job over `/v1`.
    if args[0].starts_with("spec-") {
        let mut root = root_for(&index);
        let mut out: Option<PathBuf> = None;
        let mut index_dir: Option<PathBuf> = None;
        let mut query_vec: Option<PathBuf> = None;
        let mut chunks_json: Option<PathBuf> = None;
        let mut answer_file: Option<PathBuf> = None;
        let mut k = 8usize;
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--root" => {
                    i += 1;
                    if let Some(r) = args.get(i) {
                        root = PathBuf::from(r);
                    }
                }
                "--out" => {
                    i += 1;
                    out = args.get(i).map(PathBuf::from);
                }
                "--index-dir" => {
                    i += 1;
                    index_dir = args.get(i).map(PathBuf::from);
                }
                "--query-vec" => {
                    i += 1;
                    query_vec = args.get(i).map(PathBuf::from);
                }
                "--chunks-json" => {
                    i += 1;
                    chunks_json = args.get(i).map(PathBuf::from);
                }
                "--answer-file" => {
                    i += 1;
                    answer_file = args.get(i).map(PathBuf::from);
                }
                "--k" => {
                    i += 1;
                    if let Some(v) = args.get(i) {
                        k = v.parse().unwrap_or(8);
                    }
                }
                other => {
                    eprintln!("error: unknown flag for {}: {other}", args[0]);
                    std::process::exit(2);
                }
            }
            i += 1;
        }

        match args[0].as_str() {
            "spec-index" => {
                let Some(out_dir) = out else {
                    eprintln!("error: spec-index requires --out <dir>");
                    std::process::exit(2);
                };
                if let Err(e) = std::fs::create_dir_all(&out_dir) {
                    eprintln!("error: cannot create {}: {e}", out_dir.display());
                    std::process::exit(1);
                }
                let chunks = spec::chunk_corpus(&root);
                let chunks_path = out_dir.join("chunks.jsonl");
                let mut body = String::new();
                for c in &chunks {
                    match serde_json::to_string(c) {
                        Ok(line) => {
                            body.push_str(&line);
                            body.push('\n');
                        }
                        Err(e) => {
                            eprintln!("error: serialize chunk {}: {e}", c.id);
                            std::process::exit(1);
                        }
                    }
                }
                if let Err(e) = std::fs::write(&chunks_path, body) {
                    eprintln!("error: write {}: {e}", chunks_path.display());
                    std::process::exit(1);
                }
                println!(
                    "spec-index: {} chunks -> {}",
                    chunks.len(),
                    chunks_path.display()
                );
                return;
            }
            "spec-retrieve" => {
                let Some(dir) = index_dir else {
                    eprintln!("error: spec-retrieve requires --index-dir <dir>");
                    std::process::exit(2);
                };
                let Some(qv) = query_vec else {
                    eprintln!("error: spec-retrieve requires --query-vec <file>");
                    std::process::exit(2);
                };
                let chunks = read_chunks(&dir.join("chunks.jsonl"));
                let vectors = read_vectors(&dir.join("vectors.jsonl"));
                if chunks.len() != vectors.len() {
                    eprintln!(
                        "error: index is inconsistent — {} chunks but {} vectors (re-run spec-index + embed)",
                        chunks.len(),
                        vectors.len()
                    );
                    std::process::exit(1);
                }
                let query = read_query_vec(&qv);
                let top = spec::top_k(&query, &vectors, k);
                let selected: Vec<&spec::Chunk> = top.iter().map(|(idx, _)| &chunks[*idx]).collect();
                match serde_json::to_string_pretty(&selected) {
                    Ok(s) => println!("{s}"),
                    Err(e) => {
                        eprintln!("error: serialize retrieval result: {e}");
                        std::process::exit(1);
                    }
                }
                return;
            }
            "spec-envelope" => {
                let Some(cj) = chunks_json else {
                    eprintln!("error: spec-envelope requires --chunks-json <file>");
                    std::process::exit(2);
                };
                let chunks = read_chunks_array(&cj);
                let answer = match &answer_file {
                    Some(f) => std::fs::read_to_string(f).unwrap_or_default(),
                    None => {
                        let mut buf = String::new();
                        let _ = std::io::Read::read_to_string(&mut std::io::stdin(), &mut buf);
                        buf
                    }
                };
                let envelope = spec::build_envelope(answer.trim(), &chunks, &root);
                emit_verified_envelope(envelope, &root);
                return;
            }
            other => {
                eprintln!("error: unknown spec subcommand '{other}'");
                std::process::exit(2);
            }
        }
    }

    let ledger = match Ledger::load(&index) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    let schema_path = index
        .parent()
        .map(|d| d.join("schema.yaml"))
        .unwrap_or_else(|| PathBuf::from("plan/schema.yaml"));
    let schema = Schema::load(&schema_path).unwrap_or_else(|_| Schema::minimal());

    match args[0].as_str() {
        "check" => {
            // INVARIANT CORE (ids + references) hard-gates: a live dangling
            // reference means the graph is a lie. SCHEMA drift (status enum,
            // required fields) is ADVISORY — the schema is evolving data
            // (operator 2026-07-17), so drift is surfaced, not blocked;
            // deliberate flushes through slice 2 will normalize it.
            let report = ledger.check_integrity(&schema.reference_fields);
            for w in &report.warnings {
                eprintln!("warning (organic reference debt): {w}");
            }
            for s in ledger.validate_against_schema(&schema) {
                eprintln!("advisory (schema drift): {s}");
            }
            if report.violations.is_empty() {
                println!(
                    "ok: {} packets, ids unique, live references sound",
                    ledger.packets.len()
                );
            } else {
                for v in &report.violations {
                    eprintln!("violation: {v}");
                }
                std::process::exit(1);
            }
        }
        "status" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            match ledger.resolve(reference) {
                Some(p) => println!("{}", line(&ledger, p)),
                None => {
                    eprintln!("error: no packet matches '{reference}'");
                    std::process::exit(1);
                }
            }
        }
        "blocked-by" | "blocked-closure" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            // Order 516: these queries answer with an empty stdout both when
            // the reference resolves and blocks nothing AND when it does not
            // resolve at all — the second case reads as "no such work", which
            // is exactly the false negative that got 394a/392a filed. Say so
            // on stderr. The exit code is deliberately left alone so existing
            // callers (litmus pipelines, the forge-plan MCP wrapper) keep
            // their contract.
            warn_if_unresolved(&ledger, reference);
            let packets = if args[0] == "blocked-by" {
                ledger.blocked_by(reference)
            } else {
                ledger.blocked_by_closure(reference)
            };
            for p in packets {
                println!("{}", line(&ledger, p));
            }
        }
        "ready" => {
            for p in ledger.ready(args.get(1).map(String::as_str)) {
                println!("{}", line(&ledger, p));
            }
        }
        "burndown" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            warn_if_unresolved(&ledger, reference);
            for p in ledger.milestone_children(reference) {
                println!("{}", line(&ledger, p));
            }
        }
        "answer" => {
            // ORDER 394b. The envelope is the ONLY output shape: a question
            // this engine cannot answer deterministically comes back as
            // `confidence: "unsupported"` with an empty citation list, never
            // as prose an agent might mistake for a finding.
            //
            // EXIT 0 EVEN WHEN UNSUPPORTED, deliberately: `unsupported` is a
            // well-formed answer, and the forge-plan MCP wrapper runs under
            // `set -e` where a non-zero status kills the server mid-request
            // (see forge-plan.sh::plan_query). The envelope IS the signal.
            let question = args[1..].join(" ");
            if question.trim().is_empty() {
                usage();
            }
            let root = root_for(&index);
            let envelope =
                answer::answer_question(&ledger, &question, &citation_path(&index, &root));
            // ORDER 523 (R2): self-verify against the SAME root the citation
            // paths were built relative to. This is the exact disagreement that
            // was observed — an index reached through a probe path yielded
            // confidence=exact with a citation `verify-answer` refused.
            emit_verified_envelope(envelope, &root);
        }
        "append-event" => {
            // append-event <ref> <type> <summary> --ts <ISO> [--agent A] [--host H]
            let mut positional: Vec<String> = Vec::new();
            let mut ts: Option<String> = None;
            let mut agent = "unknown".to_string();
            let mut host = "linux".to_string();
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--ts" => {
                        i += 1;
                        ts = args.get(i).cloned();
                    }
                    "--agent" => {
                        i += 1;
                        agent = args.get(i).cloned().unwrap_or(agent);
                    }
                    "--host" => {
                        i += 1;
                        host = args.get(i).cloned().unwrap_or(host);
                    }
                    other => positional.push(other.to_string()),
                }
                i += 1;
            }
            if positional.len() < 3 {
                usage();
            }
            let (reference, etype, summary) = (&positional[0], &positional[1], &positional[2]);
            let Some(ts) = ts else {
                eprintln!(
                    "error: --ts <ISO8601> is required (the tool does not invent timestamps)"
                );
                std::process::exit(2);
            };
            let Some(target) = ledger.resolve(reference).map(|p| ledger.id_of(p)) else {
                eprintln!("error: no packet matches '{reference}'");
                std::process::exit(1);
            };
            let block = edit::event_block(etype, &ts, &agent, &host, summary);
            let raw = match std::fs::read_to_string(&index) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", index.display());
                    std::process::exit(1);
                }
            };
            let candidate = match edit::append_event(&raw, &target, &block) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            };
            // FLUSH GUARD: never write a broken ledger (order-263 by construction).
            let violations = edit::validate_candidate(
                &candidate,
                ledger.archived_ids(),
                &schema.reference_fields,
            );
            if !violations.is_empty() {
                eprintln!("REFUSED: this edit would break the ledger:");
                for v in &violations {
                    eprintln!("  violation: {v}");
                }
                std::process::exit(1);
            }
            if let Err(e) = std::fs::write(&index, candidate) {
                eprintln!("error: write {}: {e}", index.display());
                std::process::exit(1);
            }
            println!("appended {etype} event to {target}");
        }
        _ => usage(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
    use std::collections::BTreeMap;

    /// ORDER 523 (R2). `answer::verify` existed but nothing on the RUNTIME path
    /// called it, so the emitter and the checker could disagree about the same
    /// envelope: an answer could ship `confidence: exact` carrying a citation
    /// `verify-answer` would refuse against the same checkout. Self-verifying at
    /// the exit point makes the verifier unavoidable — but only if the downgrade
    /// actually fires, which is what this pins.
    #[test]
    fn a_failing_envelope_is_downgraded_to_unsupported_naming_the_violations() {
        let dir = std::env::temp_dir().join(format!("tilland-523-sv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("mk root");
        let fresh = Freshness::new("deadbeef".to_string(), "2026-07-29T00:00:00Z".to_string());

        // A citation into a file that does not exist under `root` — precisely the
        // shape of the observed defect, where the paths were built against one
        // root and resolved against another.
        let mut authority = BTreeMap::new();
        authority.insert("packet_id".to_string(), "demo".to_string());
        let bogus = Citation::new(
            "plan/does-not-exist.yaml".to_string(),
            1,
            5,
            CitationKind::Plan,
            authority,
        );
        let envelope = Envelope::supported(
            "some confident prose",
            vec![bogus],
            Confidence::Exact,
            fresh.clone(),
        );
        // Precondition: it really did construct as a supported answer.
        assert_eq!(envelope.confidence(), Confidence::Exact);

        let out = self_verified(envelope, &dir);
        assert_eq!(
            out.confidence(),
            Confidence::Unsupported,
            "an envelope whose citation cannot resolve MUST be withheld, got: {}",
            out.answer()
        );
        assert!(
            out.citations().is_empty(),
            "a withheld answer must carry zero citations"
        );
        assert!(
            out.answer().starts_with("unsupported:"),
            "the refusal must use the pinned rendering, got: {}",
            out.answer()
        );
        assert!(
            out.answer().contains("FAILED its own citation check"),
            "the refusal must say the answer failed ITS OWN check, got: {}",
            out.answer()
        );

        // And a genuinely verifiable envelope passes through untouched.
        std::fs::create_dir_all(dir.join("plan")).expect("mk plan dir");
        std::fs::write(
            dir.join("plan/real.yaml"),
            "packet_id: demo\nstatus: ready\nline3: x\nline4: y\nline5: z\n",
        )
        .expect("write real file");
        let mut authority2 = BTreeMap::new();
        authority2.insert("packet_id".to_string(), "demo".to_string());
        let good = Citation::new(
            "plan/real.yaml".to_string(),
            1,
            2,
            CitationKind::Plan,
            authority2,
        );
        let ok_env = Envelope::supported("demo is ready", vec![good], Confidence::Exact, fresh);
        let passed = self_verified(ok_env.clone(), &dir);
        assert_eq!(
            passed,
            ok_env.with_citation_root(&dir),
            "a verifiable envelope must pass through byte-identical"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn citation_root_is_carried_and_derivable() {
        let dir = std::env::temp_dir().join(format!("tilland-523-cr-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("plan")).expect("mk plan dir");
        std::fs::write(
            dir.join("plan/real.yaml"),
            "packet_id: demo\nstatus: ready\nline3: x\nline4: y\nline5: z\n",
        )
        .expect("write real file");

        let fresh = Freshness::new("deadbeef".to_string(), "2026-07-29T00:00:00Z".to_string());
        let mut authority = BTreeMap::new();
        authority.insert("packet_id".to_string(), "demo".to_string());
        let good = Citation::new(
            "plan/real.yaml".to_string(),
            1,
            2,
            CitationKind::Plan,
            authority,
        );
        let canonical_dir = dir.canonicalize().expect("canonicalize dir");
        let ok_env = Envelope::supported(
            "demo is ready",
            vec![good.clone()],
            Confidence::Exact,
            fresh,
        );
        let verified = self_verified(ok_env, &dir);
        let root_str = verified.citation_root().expect("citation_root present");
        assert!(!root_str.is_empty(), "citation_root must be non-empty");
        let root_path = Path::new(root_str);
        assert!(
            root_path.is_absolute(),
            "citation_root must be absolute: {root_str}"
        );
        assert!(
            root_path.is_dir(),
            "citation_root must be an existing directory: {root_str}"
        );
        assert_eq!(
            verified.citation_root(),
            Some(canonical_dir.display().to_string().as_str())
        );

        let json = serde_json::to_string(&verified).expect("json");
        let deserialized: Envelope = serde_json::from_str(&json).expect("deserialized");
        assert_eq!(
            deserialized.citation_root(),
            Some(canonical_dir.display().to_string().as_str())
        );

        let violations = answer::verify(
            &deserialized,
            Path::new(deserialized.citation_root().unwrap()),
        );
        assert!(
            violations.is_empty(),
            "derived root verify must pass: {:?}",
            violations
        );

        // Test passing relative path ".": citation_root must canonicalize to non-empty absolute dir
        let rel_env = Envelope::supported(
            "demo is ready",
            vec![],
            Confidence::Retrieved,
            Freshness::new("a".to_string(), "b".to_string()),
        )
        .with_citation_root(Path::new("."));
        let rel_root = rel_env.citation_root().expect("rel citation_root present");
        assert!(
            !rel_root.is_empty(),
            "relative citation_root must be non-empty"
        );
        assert!(
            Path::new(rel_root).is_absolute(),
            "relative citation_root must canonicalize to absolute"
        );
        assert!(
            Path::new(rel_root).is_dir(),
            "relative citation_root must point to an existing directory"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}
