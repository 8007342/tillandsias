//! tillandsias-plan — agent-facing CLI over the plan ledger engine.
//!
//! Slice 1 (read-only): query + integrity check. The edit surface
//! (claim/event-append/status-flip with validated flushes) is slice 2.
//!
//! @trace spec:spec-traceability

use std::path::PathBuf;
use tillandsias_plan::{Ledger, Schema, edit};

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
           append-event <id|order> <type> <summary> --ts <ISO> [--agent A] [--host H]\n\
                                     append an event, VALIDATED before flush (refuses a broken ledger)"
    );
    std::process::exit(2);
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
            for p in ledger.milestone_children(reference) {
                println!("{}", line(&ledger, p));
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
