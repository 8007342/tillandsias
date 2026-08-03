//! tillandsias-plan — agent-facing CLI over the plan ledger engine.
//!
//! Slice 1 (read-only): query + integrity check. The edit surface
//! (claim/event-append/status-flip with validated flushes) is slice 2.
//!
//! @trace spec:spec-traceability

use std::path::{Path, PathBuf};
use tillandsias_plan::{
    Ledger, Schema, answer, edit, groundtruth, loop_status, methodology, spec, str_field, str_list,
};

/// ORDER 569. The capability manifest, embedded from the crate's own
/// `capabilities.txt` at COMPILE TIME.
///
/// `include_str!` is the load-bearing part: the list travels INSIDE the
/// artifact, so `tillandsias-plan capabilities` describes the sources this
/// binary was built from — not the sources sitting in whatever checkout happens
/// to be mounted next to it. A stale binary therefore reports a stale (or, if it
/// predates this order, an absent) capability set, which is exactly the signal
/// order 531 lacked when a pre-expert build stamped `experts: ready` and every
/// `plan_answer` came back `confidence=unsupported`.
///
/// The forge reads the SAME filename out of the mounted checkout to learn what a
/// relaunch would provide. One file, two readers — see capabilities.txt for why
/// this is data rather than a Rust array. If it becomes a Rust array again, the
/// shell side has to hardcode a second copy and the two will drift.
const CAPABILITY_MANIFEST: &str = include_str!("../capabilities.txt");

/// The manifest's tokens, comments and blank lines stripped.
fn capability_tokens() -> Vec<&'static str> {
    CAPABILITY_MANIFEST
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect()
}

const USAGE: &str = concat!(
    "usage: tillandsias-plan [--index <path>] <command>\n",
    "         commands:\n",
    "           capabilities              ORDER 569. Print this binary's subcommand capability set,\n",
    "                                     one token per line on stdout and nothing else. The set is\n",
    "                                     embedded at COMPILE time, so it describes the sources this\n",
    "                                     artifact was built from. A binary WITHOUT this subcommand\n",
    "                                     predates order 569 and its capabilities are unknowable —\n",
    "                                     that absence is itself the stale-binary signal the forge\n",
    "                                     wrapper branches on.\n",
    "           check                     integrity + schema validation (exit 1 on violations)\n",
    "           next-order [prefix]       mint a COLLISION-FREE order token for a new packet\n",
    "                                     (<seq>-<suffix>, e.g. 581-k3f9). Never compute the\n",
    "                                     'next free order' yourself: that reads a ledger snapshot\n",
    "                                     which is stale the moment another host commits, so\n",
    "                                     concurrent filers pick the SAME number. The minted token\n",
    "                                     is PERMANENT — never renumber it. A prefix shared by two\n",
    "                                     packets is normal. See methodology/distributed-work.yaml\n",
    "                                     -> order_id_allocation.\n",
    "           status <id|order>         one packet's status line\n",
    "           blocked-by <id|order>     packets directly blocked by X\n",
    "           blocked-closure <id|order> everything transitively downstream of X\n",
    "           ready [role]              ready packets (optionally for a pickup role)\n",
    "           query [--status S] [--role R] [--tag T]... [--limit N] [--json]\n",
    "                                     ORDER 582-26mm. THE generic filtered reader over the\n",
    "                                     FOLDED ledger (base ⊕ plan/index.d/ fragments): the only\n",
    "                                     correct way to enumerate packets by status / pickup_role /\n",
    "                                     capability_tags. project-info plan_query and drain-queue\n",
    "                                     both route here; a reader that forgets fragments reports a\n",
    "                                     stale ledger with total confidence. TSV by default\n",
    "                                     (order<TAB>packet_id<TAB>desired_release<TAB>tags); --json\n",
    "                                     emits the plan_query projection array.\n",
    "           burndown <milestone>      release-target children with statuses\n",
    "           answer <question...>      the CITED answer envelope as JSON (order 394b)\n",
    "           verify-answer [--root D]  read an envelope on stdin; exit 1 if any citation\n",
    "                                     does not resolve or its span does not contain the claim\n",
    "           methodology [--root D] [--file S] <yaml.path>\n",
    "                                     ORDER 394c. YAML path query over methodology.yaml and\n",
    "                                     methodology/**/*.yaml. Prints the 394b envelope: the\n",
    "                                     matched block plus a resolvable file:line. An unknown\n",
    "                                     path is confidence=unsupported, never a guess.\n",
    "           methodology-ask [--root D] [--file S] <question...>\n",
    "                                     route a canonical discipline question to its YAML path,\n",
    "                                     then answer it. Unrouted questions are unsupported.\n",
    "           methodology-index [--root D]\n",
    "                                     every indexed path with its file:line (the query surface)\n",
    "           append-event <id|order> <type> <summary> --ts <ISO> [--agent A] [--host H]\n",
    "                                     append an event, VALIDATED before flush (refuses a broken ledger)\n",
    "           grade [--root D] [--case ID] [--envelope F|-] [--list-engines] [SET.yaml ...]\n",
    "                                     ORDER 394d. Grade the experts against the COMMITTED ground\n",
    "                                     truth. Defaults to openspec/litmus-tests/groundtruth/\n",
    "                                     expert-groundtruth-rung1.yaml; pass more query sets (or a\n",
    "                                     glob) to grade further corpora with the same harness.\n",
    "                                     --envelope grades ONE case against an envelope captured\n",
    "                                     elsewhere (e.g. off the MCP server). Exit 1 = graded RED,\n",
    "                                     exit 2 = the harness could not run at all.\n",
    "           spec-index --out <dir> [--root D]\n",
    "                                     ORDER 547. Chunk the whole-spec corpus into <dir>/chunks.jsonl\n",
    "           spec-retrieve --index-dir <dir> --query-vec <f> [--k N]\n",
    "                                     network-free cosine top-k over caller-supplied embeddings\n",
    "           spec-envelope --chunks-json <f> [--answer-file F] [--root D]\n",
    "                                     build a VERIFIED envelope keeping only the citations the\n",
    "                                     answer actually used\n",
    "           fragments                 report the append-only plan/index.d/ overlay: which\n",
    "                                     fragments are live, which are malformed, and whether\n",
    "                                     compaction is eligible\n",
    "           compact                   fold every fragment into the base ledger and delete\n",
    "                                     exactly the ones folded (refuses a lossy rewrite)\n",
    "           loop-status [--index plan/loop_status.md]\n",
    "                                     ORDER 582-nqw5. THE loop_status reader: the folded view\n",
    "                                     (base ⊕ loop_status.d/ fragments). The only correct way to\n",
    "                                     read loop_status — a reader that forgets fragments reports\n",
    "                                     a stale status with total confidence.\n",
    "           loop-status-append [--ts ISO] [--host H] [--suffix S] [--file F]\n",
    "                                     ORDER 582-nqw5. Append ONE `## Cycle …` section (stdin or\n",
    "                                     --file) as a NEW fragment file — concurrent hosts each write\n",
    "                                     their own path, so appending status no longer conflicts.\n",
    "                                     Refuses `## Direction` and every other non-cycle heading.\n",
    "           loop-status-compact        ORDER 582-nqw5. Fold fragments into loop_status and delete\n",
    "                                     exactly the ones folded, gated on: nothing dropped, nothing\n",
    "                                     lost, operator-owned sections byte-identical, fold idempotent\n",
    "           loop-status-fragments      ORDER 582-nqw5. Report the loop_status.d/ overlay: live\n",
    "                                     fragments, malformed ones, and whether compaction is eligible\n"
);

fn usage() -> ! {
    eprintln!("{USAGE}");
    std::process::exit(2);
}

/// ORDER 569. An unrecognised subcommand is its OWN named failure, distinct from
/// the missing-operand `usage()` above.
///
/// Both used to funnel into `usage()`, which made "this binary cannot do that"
/// indistinguishable from "you forgot an argument" — and the pre-394b binary
/// order 531 shipped was worse still: it printed usage on STDOUT and exited 0,
/// so the MCP wrapper could not tell incapability from success without sniffing
/// the shape of the output. Naming the condition, listing what this artifact CAN
/// do, and exiting non-zero is what lets the wrapper (and a human reading a
/// terminal) say "wrong binary" instead of "wrong question".
///
/// If this is deleted, an agent whose forge carries a stale expert gets a usage
/// dump where it asked for an answer, and the capability probe in
/// images/default/lib-expert-capability.sh loses its negative control.
fn unknown_subcommand(name: &str) -> ! {
    eprintln!(
        "error: unknown subcommand '{name}' — this tillandsias-plan was built from sources \
         that do not provide it."
    );
    eprintln!("  this binary can do: {}", capability_tokens().join(", "));
    eprintln!(
        "  if you expected '{name}' to exist, the ARTIFACT is stale relative to the checkout: \
         rebuild it (cargo build --release -p tillandsias-plan) or relaunch the forge."
    );
    eprintln!("{USAGE}");
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

/// Print one line, exiting cleanly if the reader has gone away.
///
/// WHY THIS IS NOT `println!`. Rust's `println!` PANICS on a write error, so
/// piping any list-producing command into `head` — which every agent and every
/// shell wrapper does constantly — closes the pipe and makes this binary abort
/// with exit 101 and a backtrace note on stderr:
///
///     thread 'main' panicked at library/std/src/io/stdio.rs
///     failed printing to stdout: Broken pipe (os error 32)
///
/// That is a correctness problem, not an aesthetic one. `forge-plan.sh` runs
/// under `set -euo pipefail`, and order 456 already recorded a case where a
/// non-zero exit from this binary killed the MCP server mid-session. A tool
/// whose output is routinely piped must treat a closed reader the way every
/// other unix tool does: stop writing and exit successfully.
///
/// Resetting SIGPIPE to SIG_DFL is the conventional fix, but it needs `libc`,
/// and this crate carries exactly three dependencies on purpose. Handling the
/// error costs nothing and keeps that promise.
fn emit(text: &str) {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    if let Err(e) = writeln!(out, "{text}") {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            // The reader closed early (`| head`). Nothing is wrong.
            std::process::exit(0);
        }
        eprintln!("error: write to stdout: {e}");
        std::process::exit(1);
    }
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

/// ORDER 582-26mm. Filter the FOLDED ledger by status (exact), pickup_role
/// (case-insensitive substring), capability_tags (every given tag must be
/// present), then cap at `limit`. Reproduces project-info.sh plan_query's
/// contract so the yq/jq direct reader could be retired without changing what
/// the MCP tool returns. `limit == 0` is treated as "no cap" so a caller can
/// ask for every match.
fn query_packets<'a>(
    ledger: &'a Ledger,
    status: Option<&str>,
    role: Option<&str>,
    tags: &[String],
    limit: usize,
) -> Vec<&'a serde_yaml::Value> {
    ledger
        .packets
        .iter()
        .filter(|p| match status {
            Some(s) => str_field(p, "status") == Some(s),
            None => true,
        })
        .filter(|p| match role {
            Some(r) => {
                let want = r.to_ascii_lowercase();
                str_field(p, "pickup_role")
                    .map(|pr| pr.to_ascii_lowercase().contains(&want))
                    .unwrap_or(false)
            }
            None => true,
        })
        .filter(|p| {
            let have = str_list(p, "capability_tags");
            tags.iter().all(|t| have.contains(t))
        })
        .filter(|_| limit == 0 || true)
        .take(if limit == 0 { usize::MAX } else { limit })
        .collect()
}

/// Distinguish "resolves, blocks nothing" from "does not resolve" for the
/// list-shaped queries, which otherwise report both as an empty stdout.
/// Diagnostic only — stdout and the exit code are untouched.
fn warn_if_unresolved(ledger: &Ledger, reference: &str) {
    if ledger.resolve(reference).is_none() {
        eprintln!("warning: {}", unresolved_reason(ledger, reference));
        eprintln!("warning: the empty result below means UNRESOLVED, not 'nothing depends on it'");
    }
}

/// Why a reference did not resolve, distinguishing the two cases a bare
/// "no packet matches" conflates.
///
/// An AMBIGUOUS order (several packets claim it) is not an unknown reference —
/// the order exists, it just does not identify one packet. Reporting that as
/// "no packet matches" tells an agent there is no such work, which is false and
/// is exactly the false-negative class order 516 removed from this surface.
/// Naming the claimants also gives the caller the packet_ids to use instead,
/// which are unique by construction.
fn unresolved_reason(ledger: &Ledger, reference: &str) -> String {
    let claimants = ledger.ambiguous_claimants(reference);
    if claimants.is_empty() {
        return format!("no packet matches '{reference}'");
    }
    format!(
        "'{}' is claimed by {} packets and identifies none of them: {}. \
         Reference one by packet_id — packet_ids are unique, order numbers are not.",
        reference,
        claimants.len(),
        claimants.join(", ")
    )
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

/// ORDER 582-nqw5. The loop_status overlay commands. `base` is the target
/// document (`plan/loop_status.md` unless `--index` named something else); the
/// fragment store is its `*.d/` sibling, exactly like the index overlay.
fn run_loop_status(args: &[String], base: &Path) {
    match args[0].as_str() {
        "loop-status" => {
            // The READER — the only correct way to read loop_status, for the
            // same reason every ledger read goes through load_with_fragments: a
            // reader that forgets fragments reports a stale status with total
            // confidence.
            for bad in loop_status::malformed(base) {
                eprintln!(
                    "warning: loop_status fragment {} is malformed and was SKIPPED — its contents are not in the view below",
                    bad.display()
                );
            }
            let raw = match std::fs::read_to_string(base) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            match loop_status::fold_text(&raw, &loop_status::load_all(base)) {
                Ok(view) => {
                    // Graceful on a closed pipe: a viewer piped through
                    // `head`/`rg` must not panic mid-stream. Other write
                    // errors are real and reported.
                    use std::io::Write;
                    let mut out = std::io::stdout().lock();
                    match out.write_all(view.as_bytes()) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => {}
                        Err(e) => {
                            eprintln!("error: write stdout: {e}");
                            std::process::exit(1);
                        }
                    }
                }
                Err(e) => {
                    eprintln!("error: fold {}: {e}", base.display());
                    std::process::exit(1);
                }
            }
        }
        "loop-status-fragments" => {
            // Report the overlay's state and whether compaction is eligible.
            // Read-only: compaction itself is a separate, deliberate act.
            let d = loop_status::drift(base);
            println!("{}", d.verdict());
            for f in loop_status::load_all(base) {
                emit(&format!("fragment: {}", f.name));
            }
            for bad in loop_status::malformed(base) {
                emit(&format!("malformed: {}", bad.display()));
            }
        }
        "loop-status-compact" => {
            // Fold every fragment into the base and delete EXACTLY the ones
            // folded — the same delete-by-name contract as `compact`: never a
            // glob, or a fragment written by another host mid-compaction is
            // silently destroyed.
            let c = match loop_status::compact(base) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — {e}\n\x20 the base is UNCHANGED and every \
                         fragment is intact — the loop-status view is already transparent, so \
                         nothing is blocked by staying uncompacted"
                    );
                    std::process::exit(1);
                }
            };
            if c.consumed.is_empty() {
                println!("ok: nothing to compact (0 fragments)");
                return;
            }
            // The gate: prose has no YAML to parse, so the structural gate must
            // prove nothing dropped, nothing lost, the operator-owned sections
            // byte-identical, and the fold idempotent — see
            // loop_status::validate_candidate.
            let base_raw = match std::fs::read_to_string(base) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("error: read {}: {e}", base.display());
                    std::process::exit(1);
                }
            };
            let fragments = loop_status::load_all(base);
            if let Err(e) = loop_status::validate_candidate(&base_raw, &c.candidate, &fragments) {
                eprintln!(
                    "error: compaction REFUSED — {e}; the base is unchanged and every fragment is intact"
                );
                std::process::exit(1);
            }
            if let Err(e) = std::fs::write(base, &c.candidate) {
                eprintln!("error: write {}: {e}", base.display());
                std::process::exit(1);
            }
            let mut removed = 0usize;
            for p in &c.consumed {
                match std::fs::remove_file(p) {
                    Ok(()) => removed += 1,
                    Err(e) => eprintln!(
                        "warning: could not remove folded fragment {}: {e}",
                        p.display()
                    ),
                }
            }
            println!(
                "ok: compacted {} fragment(s) into {} ({} removed)",
                c.consumed.len(),
                base.display(),
                removed
            );
        }
        "loop-status-append" => {
            // The WRITER surface. Takes one cycle entry on stdin (or --file),
            // validates it (refusing `## Direction` and every other non-cycle
            // heading), and writes it as a NEW fragment file — the concurrent
            // write that used to conflict on the shared base now lands on a
            // per-host path.
            let mut raw = String::new();
            if let Some(i) = args.iter().position(|a| a == "--file")
                && let Some(f) = args.get(i + 1)
            {
                raw = match std::fs::read_to_string(f) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("error: read {}: {e}", f);
                        std::process::exit(1);
                    }
                };
            } else if let Err(e) = std::io::Read::read_to_string(&mut std::io::stdin(), &mut raw) {
                eprintln!("error: read stdin: {e}");
                std::process::exit(1);
            }
            let mut ts = loop_status::utc_compact_now();
            if let Some(i) = args.iter().position(|a| a == "--ts")
                && let Some(v) = args.get(i + 1)
            {
                ts = loop_status::iso_to_compact(v);
            }
            let host = args
                .iter()
                .position(|a| a == "--host")
                .and_then(|i| args.get(i + 1))
                .cloned()
                .unwrap_or_else(|| {
                    std::env::var("TILLANDSIAS_HOST_KIND").unwrap_or_else(|_| "host".to_string())
                });
            let suffix = args
                .iter()
                .position(|a| a == "--suffix")
                .and_then(|i| args.get(i + 1))
                .cloned()
                .unwrap_or_else(|| {
                    format!(
                        "{:08x}",
                        std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.subsec_nanos())
                            .unwrap_or(0)
                    )
                });
            match loop_status::append(base, &raw, &ts, &suffix, &host) {
                Ok(path) => println!("ok: wrote {}", path.display()),
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        other => unknown_subcommand(other),
    }
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
                eprintln!(
                    "error: {}:{}: not a chunk record: {e}",
                    path.display(),
                    n + 1
                );
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
        eprintln!(
            "error: {} is not a JSON array of chunks: {e}",
            path.display()
        );
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
                eprintln!(
                    "error: {}:{}: not a float vector: {e}",
                    path.display(),
                    n + 1
                );
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
    let mut index_explicit = false;
    if args.first().map(String::as_str) == Some("--index") {
        args.remove(0);
        if args.is_empty() {
            usage();
        }
        index = PathBuf::from(args.remove(0));
        index_explicit = true;
    }
    if args.is_empty() {
        usage();
    }

    // ORDER 569. `capabilities` runs FIRST and touches nothing — no ledger, no
    // methodology corpus, no filesystem at all beyond the embedded manifest.
    //
    // That is the whole point: the forge wrapper asks a binary what it can do
    // BEFORE it knows whether an index exists, and on a checkout whose plan
    // ledger may be broken or absent. A capability probe that could fail for an
    // unrelated reason would be indistinguishable from a stale binary, which is
    // exactly the ambiguity this order exists to remove.
    //
    // STDOUT CARRIES ONLY THE TOKENS, one per line, exit 0. The shell side
    // validates that shape (`^[a-z][a-z0-9-]*$`) and treats anything else —
    // a usage dump, a warning, an empty stream — as "this binary predates the
    // manifest", which is its own named state rather than a guess.
    if args[0] == "capabilities" {
        for token in capability_tokens() {
            emit(token);
        }
        return;
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
            // Order 569: `methodology-<something-we-do-not-have>` is an
            // INCAPABILITY, not a malformed invocation. Saying so is what lets a
            // caller tell a stale artifact from a bad question.
            other => unknown_subcommand(other),
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
                let selected: Vec<&spec::Chunk> =
                    top.iter().map(|(idx, _)| &chunks[*idx]).collect();
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

    // ORDER 582-nqw5. The loop_status overlay is a DIFFERENT corpus from the
    // plan ledger — prose, not keyed records — so its commands run before (and
    // independently of) the ledger load: a checkout with a broken
    // plan/index.yaml must still be able to read, append, and compact its
    // loop_status. The target defaults to plan/loop_status.md unless `--index`
    // named something else explicitly.
    if matches!(
        args[0].as_str(),
        "loop-status" | "loop-status-append" | "loop-status-compact" | "loop-status-fragments"
    ) {
        let base = if index_explicit {
            index.clone()
        } else {
            PathBuf::from(loop_status::DEFAULT_BASE)
        };
        run_loop_status(&args, &base);
        return;
    }

    // FRAGMENT-AWARE by default. Every read path must go through the same
    // overlay: a reader that forgets fragments reports a stale ledger with total
    // confidence, and if the CLI, the MCP server and the expert disagree about
    // what the plan says, the retrieval surface is worse than useless.
    let ledger = match Ledger::load_with_fragments(&index) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };
    // A fragment that cannot be parsed is SKIPPED so one bad file never makes
    // the whole plan unreadable — but skipping it quietly would lose filed work
    // with no signal, which this project refuses on principle.
    for bad in tillandsias_plan::fragments::malformed(&index) {
        eprintln!(
            "warning: ledger fragment {} does not parse and was SKIPPED — its contents are not in the answers below",
            bad.display()
        );
    }

    let schema_path = index
        .parent()
        .map(|d| d.join("schema.yaml"))
        .unwrap_or_else(|| PathBuf::from("plan/schema.yaml"));
    let schema = Schema::load(&schema_path).unwrap_or_else(|_| Schema::minimal());

    match args[0].as_str() {
        "fragments" => {
            // Report the overlay's state and whether compaction is eligible.
            // Read-only: compaction itself is a separate, deliberate act.
            let d = tillandsias_plan::fragments::drift(&index);
            println!("{}", d.verdict());
            for f in tillandsias_plan::fragments::load_all(&index) {
                emit(&format!("fragment: {}", f.name));
            }
            for bad in tillandsias_plan::fragments::malformed(&index) {
                emit(&format!("malformed: {}", bad.display()));
            }
        }
        "compact" => {
            // Fold every fragment into the base and delete EXACTLY the ones
            // folded.
            //
            // Two rules make this safe, and both are easy to break:
            //   1. Delete by NAME, never by glob. A fragment written by another
            //      host while this ran has not been folded, and globbing it away
            //      would silently destroy filed work — the classic
            //      GC-versus-writer race.
            //   2. VALIDATE the candidate before replacing the base. A
            //      compaction that emits a malformed base is worse than no
            //      compaction at all.
            //
            // The fold itself is TEXT-LEVEL and format-preserving
            // (fragments::compact_text): the base is never re-serialized, so
            // every comment and the exact item indentation survive BY
            // CONSTRUCTION, and the appended packets/events are emitted in the
            // shape `edit::append_event`/`push_event` recognize. A YAML
            // round-trip would drop ~120 operator comment lines and re-indent
            // list items to column 0, silently breaking every future event
            // append — the refusal-to-round-trip rationale that preceded this
            // implementation is recorded in packet
            // format-preserving-ledger-compaction.
            let c = match tillandsias_plan::fragments::compact_text(&index) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — {e}\n\x20 the base is UNCHANGED and every \
                         fragment is intact — reading is already transparent, so nothing is \
                         blocked by staying uncompacted"
                    );
                    std::process::exit(1);
                }
            };
            if c.consumed.is_empty() {
                println!("ok: nothing to compact (0 fragments)");
                return;
            }
            // The gate: the merged ledger must load AND pass integrity before it
            // is allowed to replace a working base.
            //
            // The candidate is validated with the SAME archived-id set the live
            // loader uses. An empty set here would flag every `depends_on` that
            // points at an archived (done) packet as an unresolved reference,
            // refusing a compaction `plan check` would have accepted — verified
            // live 2026-08-03 on agent-login-flows-research / encrypted-
            // control-channel-research, both archived in plan/archive/.
            match Ledger::parse(&c.candidate, ledger.archived_ids().clone()) {
                Ok(l) => {
                    let report = l.check_integrity(&schema.reference_fields);
                    if !report.violations.is_empty() {
                        eprintln!(
                            "error: compaction REFUSED — the merged ledger violates integrity ({} violation(s)); the base is unchanged and every fragment is intact:",
                            report.violations.len()
                        );
                        for v in &report.violations {
                            eprintln!("  {v}");
                        }
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    eprintln!(
                        "error: compaction REFUSED — the merged ledger does not parse ({e}); the base is unchanged and every fragment is intact"
                    );
                    std::process::exit(1);
                }
            }
            if let Err(e) = std::fs::write(&index, &c.candidate) {
                eprintln!("error: write {}: {e}", index.display());
                std::process::exit(1);
            }
            let mut removed = 0usize;
            for p in &c.consumed {
                match std::fs::remove_file(p) {
                    Ok(()) => removed += 1,
                    Err(e) => eprintln!(
                        "warning: could not remove folded fragment {}: {e}",
                        p.display()
                    ),
                }
            }
            println!(
                "ok: compacted {} fragment(s) into {} ({} removed)",
                c.consumed.len(),
                index.display(),
                removed
            );
        }
        "next-order" => {
            // Mint a collision-free order token for a NEW packet.
            //
            // Replaces "read the ledger, add one" — which is computed from a
            // snapshot that goes stale the moment another host commits, and so
            // makes two hosts filing in the same window pick the SAME number
            // deterministically. That happened twice in one session.
            //
            // Prints ONE token on stdout and nothing else, so it composes:
            //   order: $(tillandsias-plan next-order)
            // args[0] is the subcommand. The optional prefix is the first
            // POSITIONAL operand after it — flags and their values must be
            // skipped, or `next-order --count 5` reads "--count" as the prefix
            // and refuses a perfectly valid invocation.
            let positional: Vec<&String> = {
                let mut out = Vec::new();
                let mut i = 1usize;
                while i < args.len() {
                    if args[i] == "--count" {
                        i += 2; // the flag and its value
                        continue;
                    }
                    out.push(&args[i]);
                    i += 1;
                }
                out
            };
            let prefix = match positional.first() {
                None => None,
                Some(a) => match a.parse::<u64>() {
                    Ok(n) => Some(n),
                    // A non-numeric operand is a MISTAKE, not "use the default".
                    // Silently ignoring it would mint a token under a different
                    // prefix than the caller asked for and print it as if it had
                    // complied — the caller would only find out when the token
                    // did not sort where they expected.
                    Err(_) => {
                        eprintln!(
                            "error: prefix must be a number, got '{a}' \
                             (omit it to continue from the highest existing prefix)"
                        );
                        std::process::exit(2);
                    }
                },
            };
            // `--count N` mints N tokens in ONE invocation, guaranteed distinct
            // from each other.
            //
            // This is the surface that actually needs it. `mint` only knows what
            // is in the LEDGER, so tokens not yet written back are invisible to
            // it — and calling `next-order` N times means N separate PROCESSES,
            // none of which can see the others' draws. Filing a batch of packets
            // (the common case) is therefore exactly the unprotected shape, and
            // one invocation is the only place the guarantee can be made.
            let count = match args.iter().position(|a| a == "--count") {
                None => 1usize,
                Some(i) => match args.get(i + 1).and_then(|n| n.parse::<usize>().ok()) {
                    Some(n) if n >= 1 => n,
                    _ => {
                        eprintln!("error: --count requires a positive integer");
                        std::process::exit(2);
                    }
                },
            };
            match tillandsias_plan::allocate::mint_batch(&ledger, prefix, count) {
                Ok(tokens) => {
                    for t in tokens {
                        emit(t.as_str());
                    }
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
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
                    eprintln!("error: {}", unresolved_reason(&ledger, reference));
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
                emit(&line(&ledger, p));
            }
        }
        "query" => {
            // ORDER 582-26mm. The generic filtered reader over the FOLDED
            // ledger — the single correct way to enumerate packets by
            // status/role/tag without opening plan/index.yaml directly.
            // project-info.sh's plan_query (yq) and drain-queue.sh (awk) both
            // read the BASE only and reported a stale ledger with total
            // confidence; both now route here. The filter semantics below
            // reproduce plan_query's contract exactly: exact status, pickup_role
            // as a case-insensitive substring, capability_tags all-must-match,
            // then a limit.
            let mut status: Option<String> = None;
            let mut role: Option<String> = None;
            let mut tags: Vec<String> = Vec::new();
            let mut limit: usize = 20;
            let mut json = false;
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--status" => {
                        i += 1;
                        status = args.get(i).cloned();
                    }
                    "--role" => {
                        i += 1;
                        role = args.get(i).cloned();
                    }
                    "--tag" => {
                        i += 1;
                        if let Some(t) = args.get(i) {
                            tags.push(t.clone());
                        }
                    }
                    "--limit" => {
                        i += 1;
                        if let Some(n) = args.get(i).and_then(|s| s.parse().ok()) {
                            limit = n;
                        }
                    }
                    "--json" => json = true,
                    other => {
                        eprintln!("error: unknown query flag: {other}");
                        std::process::exit(2);
                    }
                }
                i += 1;
            }
            let matched = query_packets(&ledger, status.as_deref(), role.as_deref(), &tags, limit);
            if json {
                let arr: Vec<serde_json::Value> = matched
                    .iter()
                    .map(|p| {
                        let mut obj = serde_json::Map::new();
                        for key in [
                            "packet_id",
                            "order",
                            "title",
                            "status",
                            "kind",
                            "pickup_role",
                            "capability_tags",
                            "deliverable",
                            "depends_on",
                        ] {
                            if let Some(v) = p.get(key) {
                                obj.insert(
                                    key.to_string(),
                                    serde_json::to_value(v).unwrap_or(serde_json::Value::Null),
                                );
                            }
                        }
                        serde_json::Value::Object(obj)
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::to_string(&serde_json::Value::Array(arr))
                        .unwrap_or_else(|_| "[]".to_string())
                );
            } else {
                for p in matched {
                    let id = ledger.id_of(p);
                    let order = p
                        .get("order")
                        .map(|v| match v {
                            serde_yaml::Value::Number(n) => n.to_string(),
                            serde_yaml::Value::String(s) => s.clone(),
                            _ => "?".into(),
                        })
                        .unwrap_or_else(|| "?".into());
                    let release = p
                        .get("desired_release")
                        .and_then(serde_yaml::Value::as_str)
                        .unwrap_or("");
                    let tags = p
                        .get("capability_tags")
                        .and_then(serde_yaml::Value::as_sequence)
                        .map(|s| {
                            s.iter()
                                .filter_map(serde_yaml::Value::as_str)
                                .collect::<Vec<_>>()
                                .join(",")
                        })
                        .unwrap_or_default();
                    emit(&format!("{order}\t{id}\t{release}\t{tags}"));
                }
            }
        }
        "ready" => {
            for p in ledger.ready(args.get(1).map(String::as_str)) {
                emit(&line(&ledger, p));
            }
        }
        "burndown" => {
            let Some(reference) = args.get(1) else {
                usage()
            };
            warn_if_unresolved(&ledger, reference);
            for p in ledger.milestone_children(reference) {
                emit(&line(&ledger, p));
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
                eprintln!("error: {}", unresolved_reason(&ledger, reference));
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
        // Order 569. Was `usage()`, which conflated "this binary cannot do that"
        // with "you forgot an operand". The wrapper needs the two apart: the
        // first means RELAUNCH/REBUILD, the second means fix the call.
        other => unknown_subcommand(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use answer::{Citation, CitationKind, Confidence, Envelope, Freshness};
    use std::collections::BTreeMap;

    /// ORDER 569. The manifest is read by THREE parties — this binary, the forge
    /// wrapper, and lib-common.sh — and two of them are shell. A token carrying a
    /// space, a comma, or an uppercase letter would parse differently on each
    /// side, so the shape is pinned here rather than discovered in a forge.
    ///
    /// Sorted + unique is not cosmetic either: the shell side compares the two
    /// capability sets as sorted token lists, and a duplicate would make a set
    /// difference report a phantom missing capability.
    #[test]
    fn the_capability_manifest_is_a_sorted_unique_shell_safe_token_list() {
        let tokens = capability_tokens();
        assert!(!tokens.is_empty(), "the capability manifest is empty");
        for t in &tokens {
            assert!(
                t.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "capability token {t:?} is not [a-z0-9-]; the shell readers split on \
                 whitespace and join with commas"
            );
            assert!(
                t.starts_with(|c: char| c.is_ascii_lowercase()),
                "capability token {t:?} must start with a lowercase letter"
            );
        }
        let mut sorted = tokens.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted, tokens,
            "capabilities.txt must be sorted and free of duplicates"
        );
        assert!(
            tokens.contains(&"capabilities"),
            "the manifest must declare `capabilities` itself — the wrapper uses its \
             PRESENCE to tell a post-569 binary from a stale one"
        );
    }

    /// ORDER 569. Every capability this binary CLAIMS must also be documented,
    /// so a human reading `--help` and a machine reading `capabilities` are told
    /// the same story.
    ///
    /// Deliberately one-directional (manifest ⊆ usage, not the reverse): a
    /// subcommand that exists but is not declared makes the expert UNDER-report
    /// itself, which is fail-safe — the wrapper simply refuses to route to it.
    /// The reverse, claiming a capability that does not dispatch, is the
    /// dangerous direction, and it is caught BEHAVIOURALLY by
    /// litmus:expert-capability-skew-honesty, which invokes every declared token.
    #[test]
    fn every_declared_capability_is_documented_in_usage() {
        for t in capability_tokens() {
            assert!(
                USAGE.contains(t),
                "capability {t:?} is declared in capabilities.txt but absent from the \
                 usage text — agents would never learn it exists"
            );
        }
    }

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

    /// ORDER 582-26mm. The generic filtered reader must reproduce plan_query's
    /// filter contract EXACTLY: exact status, pickup_role as a case-insensitive
    /// substring, capability_tags all-must-match, then a limit. These are the
    /// semantics project-info's yq/jq pipeline used, so routing that surface
    /// through the CLI changes nothing about what the MCP tool answers.
    #[test]
    fn query_packets_reproduces_plan_query_filter_semantics() {
        let led = Ledger::parse(
            "plan_index:\n  steps:\n\
             \x20 - packet_id: p1\n    order: 1\n    status: ready\n    pickup_role: linux\n    capability_tags: [plan, crdt]\n\
             \x20 - packet_id: p2\n    order: 2\n    status: blocked\n    pickup_role: windows\n    capability_tags: [plan]\n\
             \x20 - packet_id: p3\n    order: 3\n    status: ready\n    pickup_role: Linux-Mutable\n    capability_tags: [crdt, plan]\n\
             \x20 - packet_id: p4\n    order: 4\n    status: ready\n    capability_tags: []\n",
            Default::default(),
        )
        .expect("parse");

        // Exact status only.
        let ready = query_packets(&led, Some("ready"), None, &[], 0);
        assert_eq!(ids(ready), vec!["p1", "p3", "p4"]);

        // pickup_role is a case-insensitive SUBSTRING.
        let linux = query_packets(&led, None, Some("linux"), &[], 0);
        assert_eq!(ids(linux), vec!["p1", "p3"]);

        // capability_tags all-must-match, independent of order in the list.
        let crdt_plan = query_packets(&led, None, None, &["plan".into(), "crdt".into()], 0);
        assert_eq!(ids(crdt_plan), vec!["p1", "p3"]);

        // Combined filters narrow the set.
        let combo = query_packets(&led, Some("ready"), Some("linux"), &["crdt".into()], 0);
        assert_eq!(ids(combo), vec!["p1", "p3"]);

        // Limit caps the result.
        let limited = query_packets(&led, Some("ready"), None, &[], 2);
        assert_eq!(ids(limited), vec!["p1", "p3"]);

        // A packet with no capability_tags matches a tag filter only if the
        // filter is empty.
        let empty_tag = query_packets(&led, Some("ready"), None, &["plan".into()], 0);
        assert_eq!(ids(empty_tag), vec!["p1", "p3"]);
    }

    fn ids(packets: Vec<&serde_yaml::Value>) -> Vec<String> {
        packets
            .iter()
            .map(|p| {
                p.get("packet_id")
                    .and_then(serde_yaml::Value::as_str)
                    .unwrap()
                    .to_string()
            })
            .collect()
    }
}
