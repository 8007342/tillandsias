//! tillandsias-plan — agent-facing CLI over the plan ledger engine.
//!
//! Slice 1 (read-only): query + integrity check. The edit surface
//! (claim/event-append/status-flip with validated flushes) is slice 2.
//!
//! @trace spec:spec-traceability

use std::path::{Path, PathBuf};
use tillandsias_plan::{Ledger, Schema, answer, edit, groundtruth, methodology};

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

/// The repo-relative path the citations carry. A citation must name a path a
/// READER can open from the checkout root, so an absolute or `../`-laden
/// `--index` is reduced to its `plan/index.yaml`-shaped tail.
///
/// The tail is only ever used as a LABEL: `verify-answer` re-resolves it
/// against the root and re-reads the span, so a wrong label is caught there
/// rather than being trusted.
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
    index
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
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
        if let Some(i) = args.iter().position(|a| a == "--root")
            && let Some(r) = args.get(i + 1)
        {
            root = PathBuf::from(r);
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
        match serde_json::to_string_pretty(&envelope) {
            Ok(json) => println!("{json}"),
            Err(e) => {
                eprintln!("error: serialize envelope: {e}");
                std::process::exit(1);
            }
        }
        return;
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
            match serde_json::to_string_pretty(&envelope) {
                Ok(json) => println!("{json}"),
                Err(e) => {
                    eprintln!("error: serialize envelope: {e}");
                    std::process::exit(1);
                }
            }
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
