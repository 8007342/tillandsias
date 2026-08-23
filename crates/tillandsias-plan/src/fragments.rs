// @trace methodology/distributed-work.yaml
// @cheatsheet concurrent-git/crdt-ledger-fragments.md
//
//! Conflict-free additive writes to the plan ledger.
//!
//! # Why this exists
//!
//! `methodology/distributed-work.yaml` → `crdt_principles.append_only_history`
//! has always required this: *"Plan-ledger files are append-only. Agents add
//! events to the end of a log section; they do not rewrite earlier entries.
//! Current state is the fold (left-fold) of the event sequence keyed by stable
//! ID."* The IMPLEMENTATION was the opposite — one monolithic `plan/index.yaml`
//! that every host edits in place — so every concurrent filing produced a git
//! text conflict a human had to adjudicate. That happened three times in one
//! session on 2026-07-31/08-01.
//!
//! Collision-free order IDs removed the SEMANTIC half of that pain (no
//! renumbering, no reference chasing). This removes the MECHANICAL half: hosts
//! write NEW files that only they could have named, so git has nothing to merge.
//!
//! # The design in one paragraph
//!
//! `plan/index.yaml` is a compacted BASE. `plan/index.d/*.yaml` are FRAGMENTS:
//! append-only, immutable once written, each named
//! `<utc>-<suffix>-<host>.yaml`. A read is `base ⊕ fold(fragments)`. Compaction
//! folds fragments into the base and deletes exactly the ones it folded.
//!
//! # The three CRDT primitives, and why each field uses the one it does
//!
//! * `packets:` — a **G-Set** keyed by `packet_id`. Union is commutative,
//!   associative and idempotent, so two hosts adding different packets both win
//!   and adding the same packet twice yields one packet.
//! * `events:` — a **G-Set of events** keyed by `(packet_id, event identity)`.
//!   Events are immutable facts; you never edit one, you add another.
//! * `status:` — an **LWW-Register**. Only one value can survive, so the winner
//!   is chosen deterministically by `(ts, host)`, never by arrival order.
//!
//! Applying LWW to a LIST would silently discard the loser's entries, which is
//! why events are a set and not a register. That distinction is the whole
//! correctness argument and must not be blurred.
//!
//! # Determinism rules that are easy to break
//!
//! Fragments fold in `(ts, filename)` order, never directory order — the
//! filesystem does not promise an order, and two hosts folding differently would
//! compute different states from identical inputs, which presents as
//! corruption rather than as a sorting bug.
//!
//! The fold is IDEMPOTENT. Folding a fragment whose contents already reached the
//! base must be a no-op, or a partially-completed compaction duplicates events.

use crate::Ledger;
use serde_yaml::{Mapping, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// Directory holding fragments, as a sibling of the base index.
///
/// `plan/index.yaml` → `plan/index.d/`. The `.d` suffix is the long-standing
/// unix convention for "a directory of things that are logically one file"
/// (`conf.d`, `cron.d`), which makes the relationship self-describing to anyone
/// who has administered a unix system.
pub fn fragment_dir(index: &Path) -> PathBuf {
    let stem = index
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "index".to_string());
    index
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!("{stem}.d"))
}

/// One fragment file, already parsed.
#[derive(Debug, Clone)]
pub struct Fragment {
    /// Sort key. Taken from the FILENAME rather than the file's own `ts` field,
    /// so a fragment cannot influence its own fold position by claiming a
    /// convenient timestamp — the name is fixed at creation and visible in git.
    pub name: String,
    pub path: PathBuf,
    pub doc: Value,
    /// The file's raw text, retained because serde_yaml discards positions:
    /// winning-source spans (order 606-h9vy) are recovered from this text by
    /// the same list-item scanning discipline base spans use.
    pub raw: String,
}

/// Every fragment beside `index`, in deterministic fold order.
///
/// Best-effort by design: a missing directory simply means no fragments, and an
/// unreadable or malformed fragment is SKIPPED rather than failing the load.
/// The ledger is the surface agents query constantly; one bad fragment must not
/// make the whole plan unreadable. Malformed fragments are reported separately
/// by [`malformed`] so they are visible rather than silently ignored.
pub fn load_all(index: &Path) -> Vec<Fragment> {
    let dir = fragment_dir(index);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out: Vec<Fragment> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("yaml"))
        .filter_map(|p| {
            let raw = std::fs::read_to_string(&p).ok()?;
            let doc: Value = serde_yaml::from_str(&raw).ok()?;
            Some(Fragment {
                name: p.file_name()?.to_string_lossy().to_string(),
                path: p,
                doc,
                raw,
            })
        })
        .collect();
    // (name) IS the (ts, suffix, host) tuple — the naming convention puts the
    // UTC stamp first precisely so a lexical sort is a chronological one.
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Fragment paths that exist but could not be parsed.
///
/// Skipping a malformed fragment keeps the ledger readable; skipping it QUIETLY
/// would lose work with no signal, which is the failure this project refuses on
/// principle. Callers surface these as warnings.
pub fn malformed(index: &Path) -> Vec<PathBuf> {
    let dir = fragment_dir(index);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut bad: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("yaml"))
        .filter(|p| {
            std::fs::read_to_string(p)
                .ok()
                .and_then(|raw| serde_yaml::from_str::<Value>(&raw).ok())
                .is_none()
        })
        .collect();
    bad.sort();
    bad
}

/// ORDER 606-h9vy — the 1-indexed INCLUSIVE line span of the list item under
/// the top-level `section:` key whose block contains `packet_id: <packet_id>`
/// and every needle in `must_contain`. This is how winning-source spans are
/// recovered from a fragment file: serde_yaml discards positions, so the span
/// comes from the same text-scanning discipline base spans use (`packet_spans`
/// / `edit::item_span`).
///
/// The returned span always contains the `packet_id: <id>` line — the same
/// load-bearing property base spans guarantee — so a citation built from it
/// can never point at a region that does not name the packet it claims.
pub fn fragment_item_span(
    raw: &str,
    section: &str,
    packet_id: &str,
    must_contain: &[&str],
) -> Option<(usize, usize)> {
    let lines: Vec<&str> = raw.lines().collect();
    let header = format!("{section}:");
    let section_start = lines.iter().position(|l| l.trim_end() == header.as_str())?;

    // Items are `- ` list entries indented under the section header; the first
    // one seen fixes the item indent for the whole section. The section ends at
    // the next non-blank line at column 0 (the next top-level key).
    let mut item_indent: Option<usize> = None;
    let mut items: Vec<(usize, usize)> = Vec::new(); // 0-indexed inclusive
    let mut current_start: Option<usize> = None;
    let mut section_end = lines.len();
    for (i, line) in lines.iter().enumerate().skip(section_start + 1) {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            continue;
        }
        let indent = line.len() - trimmed.len();
        if indent == 0 {
            section_end = i;
            break;
        }
        if trimmed.starts_with("- ") {
            match item_indent {
                None => item_indent = Some(indent),
                Some(want) if indent != want => continue,
                Some(_) => {}
            }
            if let Some(start) = current_start.take() {
                items.push((start, i - 1));
            }
            current_start = Some(i);
        }
    }
    if let Some(start) = current_start {
        items.push((start, section_end - 1));
    }

    let id_needle = format!("packet_id: {packet_id}");
    for (start, end) in items {
        // Trim trailing blank lines so the span stays tight around real text.
        let mut end = end;
        while end > start && lines[end].trim().is_empty() {
            end -= 1;
        }
        let block = lines[start..=end].join("\n");
        let names_packet = block
            .lines()
            .any(|l| l.trim_start().trim_start_matches("- ").trim_end() == id_needle);
        if names_packet && must_contain.iter().all(|n| block.contains(n)) {
            return Some((start + 1, end + 1));
        }
    }
    None
}

/// Stable identity of an event, for idempotent folding.
///
/// Two copies of the same event — which a re-applied fragment or a retried
/// append produces — must collapse to one. Identity is the tuple that a
/// legitimate duplicate shares and two genuinely different events do not.
fn event_identity(packet_id: &str, event: &Value) -> String {
    let f = |k: &str| {
        event
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("-")
            .to_string()
    };
    format!(
        "{packet_id}\u{1}{}\u{1}{}\u{1}{}\u{1}{}",
        f("type"),
        f("ts"),
        f("agent_id"),
        f("summary")
    )
}

/// ORDER 606-h9vy — which fragment WON each folded decision. Side-band output
/// of [`fold_with_sources`]: recording it cannot perturb the merged Value, so
/// the fold's purity/commutativity/idempotence pins are untouched.
#[derive(Debug, Clone, Default)]
pub struct FoldProvenance {
    /// packet_id -> index (into the fold's fragment slice) of the fragment
    /// that CREATED a fragment-born packet.
    pub new_packets: std::collections::BTreeMap<String, usize>,
    /// `packet_id\u{1}field` -> (fragment index, winning ts, winning host) of
    /// the LWW entry that won that field. Exactly the winner the fold applied,
    /// including first-wins-on-tie for equal `(ts, host)`.
    pub lww_wins: std::collections::BTreeMap<String, (usize, String, String)>,
}

/// Apply every fragment to a base document, returning the merged document.
///
/// PURE: same inputs always yield the same output, which is what lets any host
/// compact and get a result every other host agrees with.
pub fn fold(base: &Value, fragments: &[Fragment]) -> Value {
    fold_with_sources(base, fragments).0
}

/// Does `frag` carry a `falsified` event for `pid`? The falsified event is the
/// ONLY sanctioned move DOWN the closure ladder (order 650-dq6u), so the fold
/// accepts a rank-lowering status write only when the same fragment records it.
fn fragment_falsifies(frag: &Fragment, pid: &str) -> bool {
    let Some(events) = frag.doc.get("events").and_then(Value::as_sequence) else {
        return false;
    };
    events.iter().any(|e| {
        e.get("packet_id").and_then(Value::as_str) == Some(pid)
            && e.get("event")
                .and_then(|ev| ev.get("type"))
                .and_then(Value::as_str)
                == Some("falsified")
    })
}

/// Rank-aware LWW decision for the `status` field (686-7qcm / 650-dq6u).
/// Returns whether the incoming status entry should replace the current winner.
///
/// The closure ladder implemented<completed<verified<done is a monotone
/// lattice: you climb UP freely and move DOWN only through a `falsified` event.
/// `obsoleted`/`failed` are LATERAL terminals (supersession / attempt-ended),
/// not rungs, and are decided by plain LWW. Every remaining value is a WORKING
/// state (ready/pending/in_progress/blocked/needs_clarification), the floor
/// beneath the ladder.
///
///   prev rung  vs incoming rung   → higher wins; equal = LWW; lower = falsified
///   prev working vs incoming rung → UP onto the ladder: incoming wins
///   prev rung  vs incoming working → DOWN off the ladder: needs falsified
///   anything involving a lateral terminal, or working-vs-working → plain LWW
///
/// This keeps the fold's notion of "down the ladder" aligned with the
/// set-field write gate, so a stale working-state write can never silently
/// clobber a verified/done rung regardless of arrival order.
fn status_entry_wins(
    incoming: Option<&str>,
    incoming_ts: &str,
    incoming_host: &str,
    incoming_falsified: bool,
    prev: Option<&str>,
    prev_ts: &str,
    prev_host: &str,
) -> bool {
    let lww = || (incoming_ts, incoming_host) > (prev_ts, prev_host);
    let (Some(inc), Some(pv)) = (incoming, prev) else {
        return lww();
    };
    let is_lateral = |s: &str| matches!(s, "obsoleted" | "failed");
    // A lateral terminal on either side is not a ladder move: plain LWW.
    if is_lateral(inc) || is_lateral(pv) {
        return lww();
    }
    match (crate::closure_rank(inc), crate::closure_rank(pv)) {
        // Both on the ladder: monotone. Higher wins, equal LWW, lower falsified.
        (Some(i), Some(p)) => {
            if i > p {
                true
            } else if i < p {
                incoming_falsified
            } else {
                lww()
            }
        }
        // Climbing UP from a working state onto the ladder: always accept —
        // recording that verification happened does not need a newer clock.
        (Some(_), None) => true,
        // Moving DOWN off the ladder to a working state: needs falsified.
        (None, Some(_)) => incoming_falsified,
        // Working state vs working state: plain LWW.
        (None, None) => lww(),
    }
}

/// [`fold`] plus the provenance of every winning decision. The merged Value is
/// byte-for-byte the one `fold` returns; provenance is sidecar state consumed
/// by `Ledger::load_with_fragments` to attribute citations (order 606-h9vy).
pub fn fold_with_sources(base: &Value, fragments: &[Fragment]) -> (Value, FoldProvenance) {
    let mut provenance = FoldProvenance::default();
    let mut merged = base.clone();

    // Identities already present in the base, so re-folding an already-compacted
    // fragment adds nothing. This is what makes a partially-completed compaction
    // safe to re-run.
    let mut seen_events: BTreeSet<String> = BTreeSet::new();
    let mut base_packets: BTreeSet<String> = BTreeSet::new();
    {
        let mut packets = Vec::new();
        crate::collect_packets(&merged, &mut packets);
        for p in &packets {
            if let Some(id) = p.get("packet_id").and_then(Value::as_str) {
                base_packets.insert(id.to_string());
                if let Some(evs) = p.get("events").and_then(Value::as_sequence) {
                    for e in evs {
                        seen_events.insert(event_identity(id, e));
                    }
                }
            }
        }
    }

    // LWW state, resolved across ALL fragments before anything is written, so
    // the winner does not depend on application order. The fragment index
    // rides along so provenance records the same winner the fold applies.
    let mut lww: std::collections::BTreeMap<String, (String, String, Value, usize)> =
        std::collections::BTreeMap::new();

    let mut new_packets: Vec<Value> = Vec::new();
    let mut new_events: Vec<(String, Value)> = Vec::new();

    for (frag_idx, frag) in fragments.iter().enumerate() {
        // G-Set: new packets. A packet_id already present anywhere WINS from the
        // base — re-adding is a no-op, never an overwrite, because overwriting
        // would make the result depend on fold order.
        if let Some(ps) = frag.doc.get("packets").and_then(Value::as_sequence) {
            for p in ps {
                if let Some(id) = p.get("packet_id").and_then(Value::as_str)
                    && !base_packets.contains(id)
                    && !new_packets
                        .iter()
                        .any(|q| q.get("packet_id").and_then(Value::as_str) == Some(id))
                {
                    new_packets.push(p.clone());
                    provenance.new_packets.insert(id.to_string(), frag_idx);
                }
            }
        }

        // G-Set: events appended to existing packets.
        if let Some(evs) = frag.doc.get("events").and_then(Value::as_sequence) {
            for entry in evs {
                let Some(pid) = entry.get("packet_id").and_then(Value::as_str) else {
                    continue;
                };
                let Some(event) = entry.get("event") else {
                    continue;
                };
                let ident = event_identity(pid, event);
                if seen_events.insert(ident) {
                    new_events.push((pid.to_string(), event.clone()));
                }
            }
        }

        // LWW-Register: whole-field updates, highest (ts, host) wins — EXCEPT
        // the `status` field, whose closure ladder (order 650-dq6u) is a
        // monotone lattice: a more-verified rung wins regardless of write
        // order, and the ONLY move DOWN the ladder is a fragment that also
        // carries a `falsified` event for that packet. This makes "a stale
        // in_progress clobbers done" and "completed overwrites verified"
        // structurally impossible in the fold, not merely refused at write
        // time (686-7qcm; the set-field gate is the write-time half).
        if let Some(us) = frag.doc.get("status").and_then(Value::as_sequence) {
            for u in us {
                let (Some(pid), Some(field), Some(value)) = (
                    u.get("packet_id").and_then(Value::as_str),
                    u.get("field").and_then(Value::as_str),
                    u.get("value"),
                ) else {
                    continue;
                };
                let ts = u
                    .get("ts")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let host = u
                    .get("host")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let key = format!("{pid}\u{1}{field}");
                let better = match lww.get(&key) {
                    None => true,
                    Some((prev_ts, prev_host, prev_val, _)) => {
                        if field == "status" {
                            status_entry_wins(
                                value.as_str(),
                                &ts,
                                &host,
                                fragment_falsifies(frag, pid),
                                prev_val.as_str(),
                                prev_ts,
                                prev_host,
                            )
                        } else {
                            (ts.as_str(), host.as_str()) > (prev_ts.as_str(), prev_host.as_str())
                        }
                    }
                };
                if better {
                    lww.insert(key, (ts, host, value.clone(), frag_idx));
                }
            }
        }
    }

    for (key, (ts, host, _, frag_idx)) in &lww {
        provenance
            .lww_wins
            .insert(key.clone(), (*frag_idx, ts.clone(), host.clone()));
    }

    append_packets(&mut merged, new_packets);
    apply_to_packets(&mut merged, &new_events, &lww);
    (merged, provenance)
}

/// Walk the document applying event appends and LWW field wins in place.
fn apply_to_packets(
    doc: &mut Value,
    events: &[(String, Value)],
    lww: &std::collections::BTreeMap<String, (String, String, Value, usize)>,
) {
    match doc {
        Value::Mapping(m) => {
            let is_packet = m.contains_key(Value::String("packet_id".into()));
            if is_packet {
                let id = m
                    .get(Value::String("packet_id".into()))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();

                for (key, (_, _, value, _)) in lww {
                    let mut parts = key.split('\u{1}');
                    if parts.next() == Some(id.as_str())
                        && let Some(field) = parts.next()
                    {
                        m.insert(Value::String(field.to_string()), value.clone());
                    }
                }

                let mine: Vec<&Value> = events
                    .iter()
                    .filter(|(pid, _)| *pid == id)
                    .map(|(_, e)| e)
                    .collect();
                if !mine.is_empty() {
                    let slot = m
                        .entry(Value::String("events".into()))
                        .or_insert_with(|| Value::Sequence(Vec::new()));
                    if let Value::Sequence(seq) = slot {
                        for e in mine {
                            seq.push(e.clone());
                        }
                    }
                }
                return;
            }
            for (_, v) in m.iter_mut() {
                apply_to_packets(v, events, lww);
            }
        }
        Value::Sequence(s) => {
            for v in s.iter_mut() {
                apply_to_packets(v, events, lww);
            }
        }
        _ => {}
    }
}

/// Append brand-new packets to the sequence that already holds packets, so a
/// merged document has exactly the shape `collect_packets` already walks.
fn append_packets(doc: &mut Value, new_packets: Vec<Value>) {
    if new_packets.is_empty() {
        return;
    }
    if let Some(seq) = find_packet_sequence(doc) {
        seq.extend(new_packets);
        return;
    }
    // No existing packet list (an empty or unusual base): create one rather than
    // dropping the packets, which would lose filed work silently.
    if let Value::Mapping(m) = doc {
        m.insert(
            Value::String("packets".into()),
            Value::Sequence(new_packets),
        );
    }
}

fn find_packet_sequence(doc: &mut Value) -> Option<&mut Vec<Value>> {
    match doc {
        Value::Sequence(s) => {
            if s.iter().any(|v| v.get("packet_id").is_some()) {
                return Some(s);
            }
            for v in s.iter_mut() {
                if let Some(found) = find_packet_sequence(v) {
                    return Some(found);
                }
            }
            None
        }
        Value::Mapping(m) => {
            for (_, v) in m.iter_mut() {
                if let Some(found) = find_packet_sequence(v) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// Build a fragment document from parts. Any empty section is omitted so a
/// fragment stays readable in a diff.
pub fn fragment_doc(packets: Vec<Value>, events: Vec<Value>, status: Vec<Value>) -> Value {
    let mut m = Mapping::new();
    if !packets.is_empty() {
        m.insert(Value::String("packets".into()), Value::Sequence(packets));
    }
    if !events.is_empty() {
        m.insert(Value::String("events".into()), Value::Sequence(events));
    }
    if !status.is_empty() {
        m.insert(Value::String("status".into()), Value::Sequence(status));
    }
    Value::Mapping(m)
}

/// Fragment filename: `<utc-compact>-<suffix>-<host>.yaml`.
///
/// UTC FIRST so a lexical sort is chronological — the fold depends on it. The
/// random suffix makes the name collision-free without coordination (the same
/// reasoning as order-token allocation), and the host makes a stray fragment
/// traceable to whoever wrote it.
pub fn fragment_name(utc_compact: &str, suffix: &str, host: &str) -> String {
    fragment_filename(utc_compact, suffix, host, "yaml")
}

/// The [`crate::loop_status`] overlay's fragment name: the same UTC-first,
/// collision-free contract as [`fragment_name`], with the `.md` extension the
/// prose overlay reads.
pub fn fragment_name_md(utc_compact: &str, suffix: &str, host: &str) -> String {
    fragment_filename(utc_compact, suffix, host, "md")
}

fn fragment_filename(utc_compact: &str, suffix: &str, host: &str, ext: &str) -> String {
    let safe = |s: &str| -> String {
        s.chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect()
    };
    format!(
        "{}-{}-{}.{ext}",
        safe(utc_compact),
        safe(suffix),
        safe(host)
    )
}

/// ORDER 775-b4qz (extends 832-698m). The `value:` entry of a set-field LWW
/// row, rendered so ANY UTF-8 sentence survives the fold: the scalar goes
/// through serde_yaml (a `: `, `#`, leading `- ` or quote cannot escape the
/// key), multi-line continuation lines are re-indented under the column-4 key,
/// and a bare YAML-1.1 timestamp is quoted so the mirror's Psych 5 pre-receive
/// gate (627-c9c2) accepts the fragment it lands in.
pub fn lww_value_lines(value: &str) -> String {
    let rendered = serde_yaml::to_string(value)
        .unwrap_or_else(|_| format!("{value:?}"))
        .trim_end()
        .trim_start_matches("--- ")
        .trim()
        .to_string();
    let mut lines = rendered.lines();
    let head = lines.next().unwrap_or_default().to_string();
    let mut emitted = quote_timestamp_line(&format!("    value: {head}"));
    emitted.push('\n');
    for line in lines {
        if line.is_empty() {
            emitted.push('\n');
        } else {
            emitted.push_str(&format!("    {line}\n"));
        }
    }
    emitted
}

/// ORDER 775-b4qz. The complete body of a set-field fragment, extracted from
/// the CLI arm so the round-trip unit tests exercise the exact bytes
/// production writes. `event_blocks` is `(type, single-line summary)` pairs;
/// callers strip newlines before passing summaries in.
pub fn set_field_fragment_body(
    pid: &str,
    field: &str,
    value: &str,
    ts: &str,
    host: &str,
    event_blocks: &[(String, String)],
) -> String {
    let mut body = String::new();
    body.push_str("# Ledger fragment — append-only, IMMUTABLE once written.\n");
    body.push_str("# Written by: tillandsias-plan set-field (order 636-9m79).\n");
    body.push_str("#\n");
    body.push_str("# The LWW channel below is named `status:` for historical reasons but\n");
    body.push_str("# corrects ANY field (642-fedr). Re-declaring the packet under\n");
    body.push_str("# `packets:` would be a G-Set no-op and would silently do nothing.\n");
    body.push_str("status:\n");
    body.push_str(&format!("  - packet_id: {pid}\n"));
    body.push_str(&format!("    field: {field}\n"));
    body.push_str(&lww_value_lines(value));
    body.push_str(&format!("    ts: \"{ts}\"\n"));
    body.push_str(&format!("    host: {host}\n"));
    if !event_blocks.is_empty() {
        body.push_str("\nevents:\n");
        for (etype, summary) in event_blocks {
            body.push_str(&format!("  - packet_id: {pid}\n"));
            body.push_str("    event:\n");
            body.push_str(&format!("      type: {etype}\n"));
            body.push_str(&format!("      ts: \"{ts}\"\n"));
            body.push_str(&format!("      host: {host}\n"));
            body.push_str(&format!("      summary: >\n        {summary}\n"));
        }
    }
    body
}

/// ORDER 775-b4qz, exit criterion 2 — the write-time half of the malformed-
/// fragment defence. Re-parse a just-written fragment with the SAME parser the
/// fold uses ([`load_all`]'s `serde_yaml::from_str`) and confirm the LWW row
/// it claims to carry reads back byte-identical. The defect class this closes
/// is exit-0-on-corruption: `set-field` printed `ok:` twice on this host while
/// writing fragments the fold silently skipped.
pub fn verify_written_lww(path: &Path, pid: &str, field: &str, expect: &str) -> Result<(), String> {
    let raw =
        std::fs::read_to_string(path).map_err(|e| format!("re-read of written fragment: {e}"))?;
    let doc: Value = serde_yaml::from_str(&raw)
        .map_err(|e| format!("fragment does not parse with the fold's parser: {e}"))?;
    let row = doc
        .get("status")
        .and_then(Value::as_sequence)
        .and_then(|rows| {
            rows.iter().find(|r| {
                r.get("packet_id").and_then(Value::as_str) == Some(pid)
                    && r.get("field").and_then(Value::as_str) == Some(field)
            })
        });
    match row.and_then(|r| r.get("value")) {
        Some(Value::String(s)) if s == expect => Ok(()),
        Some(Value::String(s)) => Err(format!(
            "value round-trip mismatch: wrote {expect:?}, fragment reads back {s:?}"
        )),
        Some(other) => Err(format!(
            "value parsed as non-string {other:?} — the scalar escaped its key"
        )),
        None => Err(format!(
            "no parseable status row for {pid}.{field} in the written fragment"
        )),
    }
}

/// Parse-only verification for written fragments carrying no LWW row (the
/// note-recording no-op path): same parser as the fold, no read-back target.
pub fn verify_written_parses(path: &Path) -> Result<(), String> {
    let raw =
        std::fs::read_to_string(path).map_err(|e| format!("re-read of written fragment: {e}"))?;
    serde_yaml::from_str::<Value>(&raw)
        .map(|_| ())
        .map_err(|e| format!("fragment does not parse with the fold's parser: {e}"))
}

/// The compaction verdict: the merged base plus exactly which fragments it
/// consumed.
///
/// Returning the NAMES is the whole point. Compaction must delete precisely the
/// fragments it folded — never a glob — because a fragment written by another
/// host mid-compaction has not been folded, and removing it would silently
/// destroy filed work. That is the classic GC-versus-writer race and the single
/// most likely way to lose data in this design.
pub struct Compaction {
    pub merged: Value,
    pub consumed: Vec<PathBuf>,
    /// Fragments compaction REFUSED to consume, with the records of theirs that
    /// did not reach the base (order 843-624y). Surfacing these is the point: a
    /// fragment the fold cannot absorb is a defect to fix, not a file to
    /// silently delete or silently keep forever.
    pub refused: Vec<(PathBuf, Vec<String>)>,
}

/// Which of `frag`'s records did NOT reach `result`?
///
/// ORDER 843-624y. THE CONTRACT ON [`Compaction`] SAYS "the fragments it
/// FOLDED". Both compaction paths used to compute
/// `fragments.iter().map(|f| f.path.clone())` — the fragments it LOADED — and
/// then delete exactly that list. Every fragment whose content the fold did not
/// absorb was therefore removed from the repo having contributed nothing.
///
/// That is not hypothetical. `git show
/// 9d12276ca^:plan/index.d/20260814t200300z-736-macos-control-wire-evidence.yaml`
/// resolves and carries `packet_id: v04-release-gate-macos-e2e-evidence, order:
/// 735-6iki`; its text appears nowhere under plan/ today. A v0.4 release-gate
/// closure, deleted by the garbage collector. 1,144 fragment files have been
/// deleted across history and nothing distinguished the folded from the eaten.
///
/// THE SIBLING ALREADY DOES THIS CORRECTLY, 300 lines away:
/// `loop_status::verify_compaction` walks every fragment section and refuses
/// with "compaction would LOSE fragment {} section `{}`". This is that check,
/// for the ledger's record shapes.
///
/// Deliberately NOT flagged: a `status:` write that lost LWW. Losing a
/// last-writer race is the designed semantics, not data loss — the packet is
/// present and the write is simply not the winner. Flagging it would refuse
/// nearly every real compaction and the guard would be switched off within a
/// day. What IS flagged is a status write whose packet does not exist at all,
/// because that write was discarded rather than outranked.
fn fragment_coverage_gaps(result: &Value, frag: &Fragment) -> Vec<String> {
    let mut gaps = Vec::new();
    let mut packets = Vec::new();
    crate::collect_packets(result, &mut packets);

    let mut ids: BTreeSet<&str> = BTreeSet::new();
    let mut events: BTreeSet<String> = BTreeSet::new();
    for p in &packets {
        if let Some(id) = p.get("packet_id").and_then(Value::as_str) {
            ids.insert(id);
            if let Some(evs) = p.get("events").and_then(Value::as_sequence) {
                for e in evs {
                    events.insert(event_identity(id, e));
                }
            }
        }
    }

    if let Some(ps) = frag.doc.get("packets").and_then(Value::as_sequence) {
        for p in ps {
            match p.get("packet_id").and_then(Value::as_str) {
                Some(id) if !ids.contains(id) => {
                    gaps.push(format!("packet `{id}` declared under `packets:`"))
                }
                None => gaps.push("a `packets:` entry carrying no packet_id".to_string()),
                _ => {}
            }
        }
    }

    if let Some(evs) = frag.doc.get("events").and_then(Value::as_sequence) {
        for entry in evs {
            let Some(pid) = entry.get("packet_id").and_then(Value::as_str) else {
                gaps.push("an `events:` entry carrying no packet_id".to_string());
                continue;
            };
            // A list item under `events:` with no `event:` block is a packet
            // DEFINITION written under the wrong key (812-d45t). The fold
            // `continue`s past it in silence. Order 801-kqme lost three whole
            // follow-up packets exactly this way.
            let Some(event) = entry.get("event") else {
                // TWO DIFFERENT MISTAKES REACH THIS LINE and they are repaired
                // differently, so they are named differently (866-pvsx). A
                // DEFINITION here is a packet written under the wrong key: move
                // it to `packets:`. Anything else is a directive the fold has no
                // handler for — usually a hand-written guess at a key the
                // set-field subcommand would have emitted correctly — and the
                // repair is to rewrite the entry, not relocate it.
                //
                // Reporting both as 812-d45t was itself misleading: it sent me
                // looking for a lost packet definition when what I had written
                // was a bogus `set_field:` key.
                let definition_fields: Vec<&str> = ["order", "title", "kind", "deliverable"]
                    .into_iter()
                    .filter(|k| entry.get(*k).is_some())
                    .collect();
                if definition_fields.is_empty() {
                    let mut unknown: Vec<String> = entry
                        .as_mapping()
                        .map(|m| {
                            m.keys()
                                .filter_map(Value::as_str)
                                .filter(|k| *k != "packet_id")
                                .map(str::to_string)
                                .collect()
                        })
                        .unwrap_or_default();
                    unknown.sort_unstable();
                    let named = if unknown.is_empty() {
                        "no payload key at all".to_string()
                    } else {
                        format!("unrecognized key(s) {}", unknown.join(", "))
                    };
                    gaps.push(format!(
                        "an `events:` entry for `{pid}` with no `event:` block and {named} — the fold has no handler for it and skips it in silence, so this write did NOT land (866-pvsx); use the `set-field` subcommand rather than hand-writing the entry"
                    ));
                } else {
                    gaps.push(format!(
                        "an `events:` entry for `{pid}` with no `event:` block but definition field(s) {} — a packet DEFINITION under the wrong key (812-d45t); move it under `packets:`",
                        definition_fields.join(", ")
                    ));
                }
                continue;
            };
            if !events.contains(&event_identity(pid, event)) {
                // NAME THE CONSEQUENCE, NOT THE SHAPE. This used to read "that
                // packet is not in the fold, so the event was discarded",
                // which describes a mechanism and reads as bookkeeping. One
                // such fragment sat in this overlay for FOURTEEN HOURS being
                // reported on every single compaction, and three separate
                // cycle reports — mine and the macOS host's — classified it as
                // a benign permanent refusal worth an eventual tombstone. It
                // was a coordinator finding filed against
                // `macos-onboarding-defect-sweep`, one word short of
                // `macos-host-onboarding-defect-sweep`. Nobody reading that
                // packet ever saw it. The refusal was correct and the wording
                // is what made it easy to file away.
                gaps.push(format!(
                    "an event for `{pid}` — NO SUCH PACKET, so this event is attached to nothing and no reader of any packet will ever see it; check the id for a typo"
                ));
            }
        }
    }

    if let Some(us) = frag.doc.get("status").and_then(Value::as_sequence) {
        for u in us {
            if let Some(pid) = u.get("packet_id").and_then(Value::as_str)
                && !ids.contains(pid)
            {
                gaps.push(format!(
                    "a `status:` write for `{pid}` — no such packet in the fold, so the write was discarded"
                ));
            }
        }
    }

    // The `capabilities:` channel is READ by `fold_capabilities` and never
    // WRITTEN by either compaction path, so it has no base representation at
    // all. Consuming such a fragment destroys 100% of the channel rather than
    // the ~1% the parse-failure case loses. Measured 2026-08-21:
    // `capability-matrix` reports 0 rows while packet 808-7yrd, which declared
    // the channel delivered, reads `completed`.
    // ORDER 846-idhn. This was an UNCONDITIONAL refusal, correct while the
    // renderer had no idea the channel existed. Now that compaction serialises
    // `capabilities:` into the base, the honest question is the same one every
    // other channel is asked: does the CANDIDATE carry this fragment's rows?
    //
    // The key is (host_id, locus), NOT the row verbatim. Capability rows are
    // LWW by (ts, host), so a fragment's row legitimately LOSES to a newer one
    // for the same host and locus — that is superseded, not lost, and
    // demanding the exact row back would refuse every fragment a later probe
    // has replaced.
    if let Some(rows) = frag.doc.get("capabilities").and_then(Value::as_sequence) {
        let mut present: BTreeSet<(String, String)> = BTreeSet::new();
        if let Some(base_rows) = result.get("capabilities").and_then(Value::as_sequence) {
            for r in base_rows {
                let host_id = r
                    .get("document")
                    .and_then(|d| d.get("host"))
                    .and_then(|h| h.get("host_id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let locus = r.get("locus").and_then(Value::as_str).unwrap_or_default();
                present.insert((host_id.to_string(), locus.to_string()));
            }
        }
        for r in rows {
            let host_id = r
                .get("document")
                .and_then(|d| d.get("host"))
                .and_then(|h| h.get("host_id"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let locus = r.get("locus").and_then(Value::as_str).unwrap_or_default();
            if host_id.is_empty() {
                gaps.push(
                    "a `capabilities:` row whose document carries no host.host_id, so nothing can be matched against the base".to_string(),
                );
            } else if !present.contains(&(host_id.to_string(), locus.to_string())) {
                gaps.push(format!(
                    "a `capabilities:` row for {host_id}/{locus} — the compacted base carries no row for that host and locus, so consuming this fragment would lose it"
                ));
            }
        }
    }

    gaps
}

/// ORDER 866-pvsx. The same coverage question [`compact`] asks, asked at READ
/// time instead of at garbage-collection time, for every fragment currently in
/// the overlay.
///
/// WHY THIS EXISTS WHEN `fragment_coverage_gaps` ALREADY DID. The detection was
/// never the missing piece — I filed 866-pvsx believing the fold had no idea
/// these entries existed, and that was wrong. `fragment_coverage_gaps` catches
/// this shape precisely. What it does with the answer is refuse to DELETE the
/// fragment, which protects the bytes on disk and tells the author nothing. It
/// only runs when a compaction runs, and compaction runs when the fragment
/// COUNT makes it eligible — so a dropped entry stays unreported for as long as
/// the overlay stays small, which is indefinitely.
///
/// MEASURED, by making the mistake (lenovinha, 2026-08-23). I hand-wrote a
/// `set_field:` key into an events entry to release a claim. The fold does not
/// know that key, so it skipped the entry; `yq` parsed the file, the
/// closure-evidence and misplaced-definition passes were both silent — the
/// latter correctly, since it requires definition fields and mine carried none
/// — and `check` reported `ok: 550 packets, ids unique, live references
/// sound`. The packet count even ROSE, because the `packets:` half of the same
/// fragment folded perfectly. Every signal available to me said the write had
/// landed. The claim was still open, and I found that only because I happened
/// to re-list live claims afterwards.
///
/// The consequence is not cosmetic: fragments are immutable and five hosts
/// write them concurrently, so nothing will ever re-apply the dropped
/// directive. A host that believes it released a claim and did not strands that
/// packet from both `ready` queries and burndown until the 24h reaper runs —
/// 641-e2qa, reached by an honest typo rather than by an abandoned cycle.
///
/// Returns one entry per fragment that has gaps, in load order, so a caller can
/// name the file AND the specific entry. Empty for a clean overlay, so the
/// common case costs a caller nothing.
/// A base that does not parse yields NO gaps rather than a panic: `check` has
/// its own, louder answer for that, and this pass must never be the thing that
/// makes an unreadable ledger fail differently.
pub fn overlay_coverage_gaps(index: &Path) -> Vec<(PathBuf, Vec<String>)> {
    let Ok(raw) = std::fs::read_to_string(index) else {
        return Vec::new();
    };
    let Ok(base) = serde_yaml::from_str::<Value>(&raw) else {
        return Vec::new();
    };
    let fragments = load_all(index);
    let merged = fold(&base, &fragments);
    fragments
        .iter()
        .filter_map(|f| {
            let gaps = fragment_coverage_gaps(&merged, f);
            (!gaps.is_empty()).then(|| (f.path.clone(), gaps))
        })
        .collect()
}

/// Fold every fragment into the base and report what was consumed.
///
/// Does NOT touch the filesystem — the caller validates the candidate and writes
/// it. A compaction that emits a malformed base is worse than no compaction, so
/// the parse/integrity gate belongs between this and the write.
pub fn compact(base: &Value, index: &Path) -> Compaction {
    let fragments = load_all(index);
    let merged = fold(base, &fragments);
    let mut consumed = Vec::new();
    let mut refused = Vec::new();
    for f in &fragments {
        let gaps = fragment_coverage_gaps(&merged, f);
        if gaps.is_empty() {
            consumed.push(f.path.clone());
        } else {
            refused.push((f.path.clone(), gaps));
        }
    }
    Compaction {
        merged,
        consumed,
        refused,
    }
}

/// The format-preserving compaction verdict: the candidate base TEXT plus
/// exactly which fragments it consumed. The same delete-by-name contract as
/// [`Compaction`] — never a glob, or a fragment written by another host
/// mid-compaction is silently destroyed.
#[derive(Debug)]
pub struct CompactionText {
    pub candidate: String,
    pub consumed: Vec<PathBuf>,
    /// Fragments compaction REFUSED to consume, with the records of theirs that
    /// the rendered candidate does not carry (order 843-624y).
    pub refused: Vec<(PathBuf, Vec<String>)>,
}
/// Format-preserving, text-level compaction.
///
/// Folds every fragment the way [`fold`] does, then renders the DELTA as text
/// edits on the untouched base text:
///
///   * brand-new packets are APPENDED as canonical `    - ` list items, so the
///     base keeps every comment and every byte of existing indentation;
///   * events are routed through [`crate::edit::push_event`], the same
///     format-preserving text edit the live ledger uses for appends;
///   * LWW field wins are applied by targeted line replacement inside the
///     target packet's own span.
///
/// The base is never re-serialized, so format preservation holds BY
/// CONSTRUCTION rather than by careful serialization. The caller still gates
/// the candidate with parse + integrity before writing it.
///
/// The filesystem is untouched here; the caller writes `candidate` and deletes
/// exactly `consumed`. Fail-closed: every refusal leaves the base intact.
pub fn compact_text(index: &Path) -> Result<CompactionText, String> {
    let raw =
        std::fs::read_to_string(index).map_err(|e| format!("read {}: {e}", index.display()))?;
    let base: Value =
        serde_yaml::from_str(&raw).map_err(|e| format!("base ledger does not parse: {e}"))?;
    let fragments = load_all(index);
    if fragments.is_empty() {
        return Ok(CompactionText {
            candidate: raw,
            consumed: Vec::new(),
            refused: Vec::new(),
        });
    }
    let merged = fold(&base, &fragments);

    // The G-Set / LWW deltas, derived from the fold OUTPUT so the rendered text
    // can never disagree with the CRDT state every other host computes.
    let mut base_packets: BTreeSet<String> = BTreeSet::new();
    let mut base_events: BTreeSet<String> = BTreeSet::new();
    {
        let mut ps = Vec::new();
        crate::collect_packets(&base, &mut ps);
        for p in &ps {
            if let Some(id) = p.get("packet_id").and_then(Value::as_str) {
                base_packets.insert(id.to_string());
                if let Some(evs) = p.get("events").and_then(Value::as_sequence) {
                    for e in evs {
                        base_events.insert(event_identity(id, e));
                    }
                }
            }
        }
    }
    let mut merged_packets = Vec::new();
    crate::collect_packets(&merged, &mut merged_packets);

    // 1. New packets: in the merged document, absent from the base.
    let new_packets: Vec<Value> = merged_packets
        .iter()
        .filter(|p| {
            p.get("packet_id")
                .and_then(Value::as_str)
                .is_some_and(|id| !base_packets.contains(id))
        })
        .cloned()
        .collect();

    // 2. New events: identities in the merged document, absent from the base.
    //
    // Only events on packets that EXIST IN THE BASE are pushed here. An event
    // on a packet added by a fragment is already folded INTO that packet's
    // value by `fold`, so `render_item` emits it — pushing it again would
    // duplicate it (verified live: 582-26mm rendered its appended event twice).
    let mut new_events: Vec<(String, Value)> = Vec::new();
    for p in &merged_packets {
        let Some(id) = p.get("packet_id").and_then(Value::as_str) else {
            continue;
        };
        if !base_packets.contains(id) {
            continue;
        }
        if let Some(evs) = p.get("events").and_then(Value::as_sequence) {
            for e in evs {
                if base_events.insert(event_identity(id, e)) {
                    new_events.push((id.to_string(), e.clone()));
                }
            }
        }
    }

    // 3. LWW field wins, recomputed exactly as `fold` resolves them, filtered
    //    to packets that exist in the merged document and to wins that change
    //    the base text (a win over the same value needs no edit).
    let mut lww: std::collections::BTreeMap<String, (String, String, Value)> =
        std::collections::BTreeMap::new();
    for frag in &fragments {
        let Some(us) = frag.doc.get("status").and_then(Value::as_sequence) else {
            continue;
        };
        for u in us {
            let (Some(pid), Some(field), Some(value)) = (
                u.get("packet_id").and_then(Value::as_str),
                u.get("field").and_then(Value::as_str),
                u.get("value"),
            ) else {
                continue;
            };
            let ts = u
                .get("ts")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let host = u
                .get("host")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let key = format!("{pid}\u{1}{field}");
            let better = match lww.get(&key) {
                None => true,
                Some((prev_ts, prev_host, _)) => {
                    (ts.as_str(), host.as_str()) > (prev_ts.as_str(), prev_host.as_str())
                }
            };
            if better {
                lww.insert(key, (ts, host, value.clone()));
            }
        }
    }
    let lww_wins: Vec<(String, String, Value)> = lww
        .into_iter()
        .filter(|(key, (_, _, value))| {
            let mut parts = key.split('\u{1}');
            let (Some(pid), Some(field)) = (parts.next(), parts.next()) else {
                return false;
            };
            let in_merged = merged_packets
                .iter()
                .any(|p| p.get("packet_id").and_then(Value::as_str) == Some(pid));
            // A fragment-born packet is rendered from the already-folded
            // `merged_packets` value above, so its winning LWW fields are
            // already present in the appended item. Re-applying them as a
            // targeted base-text edit is redundant. Only packets that existed
            // in the compacted base need an in-place LWW edit.
            in_merged
                && base_packets.contains(pid)
                && base_value(&base, pid, field) != Some(value.clone())
        })
        .map(|(key, (_, _, value))| {
            let mut parts = key.split('\u{1}');
            (
                parts.next().unwrap().to_string(),
                parts.next().unwrap().to_string(),
                value,
            )
        })
        .collect();

    // ---- Render the delta as text edits on the untouched base text. ----

    // Drop trailing blank lines so appended packets sit directly under the
    // final packet item rather than after a gap; the file ends with one `\n`.
    let mut out: Vec<String> = raw.lines().map(String::from).collect();
    while out.last().is_some_and(|l| l.trim().is_empty()) {
        out.pop();
    }

    if !new_packets.is_empty() {
        // Fail-closed anchor: the final 4-space list item must be a packet item
        // running to the end of the file, or appending would land the new items
        // inside whatever OTHER list follows. On this ledger the packet sequence
        // is the final section, so that is the shape compaction requires.
        let last_item = out
            .iter()
            .rposition(|l| l.starts_with("    - "))
            .ok_or_else(|| {
                "refusing to compact: the base has no `    - ` packet item to append after"
                    .to_string()
            })?;
        let is_packet_item = (last_item..out.len()).any(|i| {
            let t = out[i].trim();
            t.starts_with("packet_id:") || t.starts_with("- packet_id:")
        });
        if !is_packet_item {
            return Err(
                "refusing to compact: the final list item in the base is not a packet item, so \
                 appending new packets would land in the wrong section"
                    .to_string(),
            );
        }
        for p in &new_packets {
            out.push(render_item(p));
        }
    }

    // `render_item` ends its item with `\n`, so a naive `join("\n")` plus a
    // trailing `+ "\n"` would leave a blank line after the last appended packet.
    // Normalize to exactly one trailing `\n` so a second (no-op) compaction
    // produces byte-identical output.
    let mut candidate_lines: Vec<String> = out.join("\n").lines().map(String::from).collect();
    while candidate_lines.last().is_some_and(|l| l.trim().is_empty()) {
        candidate_lines.pop();
    }
    let mut candidate = candidate_lines.join("\n") + "\n";

    for (pid, ev) in &new_events {
        candidate = crate::edit::push_event(&candidate, pid, &render_list_item(ev, 8))?;
    }

    let mut lines: Vec<String> = candidate.lines().map(String::from).collect();
    for (pid, field, value) in &lww_wins {
        apply_lww(&mut lines, pid, field, value)?;
    }
    candidate = lines.join("\n") + "\n";

    // ORDER 846-idhn — GIVE THE `capabilities:` CHANNEL A BASE REPRESENTATION.
    //
    // Until now this renderer emitted packets, events and LWW field writes and
    // simply had no idea the channel existed, so `fold_capabilities` read rows
    // that nothing could ever write back. Compaction therefore refused every
    // fragment carrying one, permanently: measured 2026-08-23, 12 of 16
    // fragments were unfoldable for this reason alone and the overlay could not
    // drain below them. It grows by one per host per capability refresh, and
    // the fleet is now seven hosts across two loci each.
    //
    // FOLDED AT WRITE TIME, NOT APPENDED. Reusing `fold_capabilities` rather
    // than concatenating rows keeps the base bounded at (host_id, locus) pairs
    // instead of growing once per refresh, and it means the base and the live
    // matrix are produced by THE SAME LWW rule — a second implementation of
    // "which row wins" is exactly how two readers come to disagree.
    //
    // Precedence is the ROW's own (ts, host), never fragment order, so the
    // synthetic base fragment below can sit anywhere in the slice.
    {
        let base_doc: Value = serde_yaml::from_str(&candidate).unwrap_or(Value::Null);
        let mut all: Vec<Fragment> = Vec::new();
        if base_doc.get("capabilities").is_some() {
            all.push(Fragment {
                name: "0000-base".to_string(),
                path: PathBuf::from("plan/index.yaml"),
                doc: base_doc,
                raw: String::new(),
            });
        }
        all.extend(fragments.iter().cloned());
        let (matrix, _skipped) = fold_capabilities(&all);
        if !matrix.is_empty() {
            let rows: Vec<Value> = matrix
                .values()
                .map(|e| {
                    let mut m = serde_yaml::Mapping::new();
                    m.insert("ts".into(), Value::String(e.ts.clone()));
                    m.insert("host".into(), Value::String(e.host.clone()));
                    m.insert("locus".into(), Value::String(e.locus.clone()));
                    m.insert("document".into(), e.document.clone());
                    Value::Mapping(m)
                })
                .collect();
            let body = serde_yaml::to_string(&Value::Sequence(rows))
                .map_err(|e| format!("refusing to compact: cannot render capabilities: {e}"))?;
            // TWO THINGS SERDE GETS WRONG FOR THIS LEDGER, both found by folding
            // the real base and watching what broke.
            //
            // (1) UNQUOTED TIMESTAMPS. serde drops quotes from a string that
            // looks unambiguous, but a bare ISO-8601 scalar is inferred as a
            // Time by Psych, and `YAML.load_file` (safe_load in Psych 5)
            // refuses to construct one: the whole base became unparseable to
            // every ruby tool in this repo, and the archiver is one. This is the
            // known class in
            // plan/issues/compaction-folds-unquoted-timestamps-past-the-fragment-gate-2026-08-13.md,
            // reproduced by a new writer. Quote every date-like scalar.
            //
            // (2) SEQUENCE ITEMS AT COLUMN 0. `- ts:` is legal YAML under a
            // top-level key but it broke IDEMPOTENCE: the replace-existing-block
            // pass below strips lines that begin with whitespace, so a SECOND
            // fold removed `capabilities:` and orphaned every `- ` item after
            // it. Indenting the sequence makes the block uniformly
            // whitespace-led, so stripping it is exact and folding twice is a
            // no-op — which is the property the idempotency test checks.
            let mut rendered = String::from("capabilities:\n");
            for line in body.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                let quoted = quote_datelike_scalar(line);
                rendered.push_str("  ");
                rendered.push_str(&quoted);
                rendered.push('\n');
            }
            // Replace any existing top-level block rather than appending a
            // second one: two `capabilities:` keys is not a merge, it is a
            // document where the later silently wins and the earlier is lost.
            let mut kept: Vec<String> = Vec::new();
            let mut in_block = false;
            for l in candidate.lines() {
                if l == "capabilities:" {
                    in_block = true;
                    continue;
                }
                if in_block {
                    if l.starts_with(' ') || l.trim().is_empty() {
                        continue;
                    }
                    in_block = false;
                }
                kept.push(l.to_string());
            }
            while kept.last().is_some_and(|l| l.trim().is_empty()) {
                kept.pop();
            }
            // PREPEND, NEVER APPEND — 862-cq3x, and the reason is one line
            // elsewhere in this function.
            //
            // New packets are added with `out.push(render_item(p))`, i.e. at
            // the END of the document. The `rposition("    - ")` above only
            // VALIDATES that the last list item is a packet item; it does not
            // aim the insertion. That was correct for as long as the document
            // ended with the packets list. Appending `capabilities:` after it
            // broke exactly that invariant: the NEXT compaction pushed a
            // `    - packet_id:` line after the capabilities mapping, and the
            // candidate stopped parsing — "did not find expected key at line
            // 37474 column 7". macos hit it first (862-cq3x) and called it
            // placement; it is, though one level further out than the block's
            // own indentation.
            //
            // A top-level key's ORDER is semantically irrelevant to YAML, so
            // putting the channel first costs nothing and keeps the document
            // ending in the packets list, which is what every other writer
            // here assumes.
            candidate = rendered.trim_end().to_string() + "\n" + &kept.join("\n") + "\n";
        }
    }

    // ORDER 843-624y. Coverage is checked against the RE-PARSED CANDIDATE, not
    // against `merged`, and the distinction is the whole fix on this path. The
    // failure mode here is not that the fold missed something — it is that the
    // RENDERER dropped something the fold held. `capabilities:` is exactly
    // that: fold_capabilities reads it, no writer emits it, so it lives in
    // `merged` and never in the text that replaces the base. Checking against
    // `merged` would call that covered and delete the only copy.
    let written: Value = serde_yaml::from_str(&candidate)
        .map_err(|e| format!("compaction candidate does not parse: {e}"))?;
    let mut consumed = Vec::new();
    let mut refused = Vec::new();
    for f in &fragments {
        let gaps = fragment_coverage_gaps(&written, f);
        if gaps.is_empty() {
            consumed.push(f.path.clone());
        } else {
            refused.push((f.path.clone(), gaps));
        }
    }
    Ok(CompactionText {
        candidate,
        consumed,
        refused,
    })
}

/// The value a packet carries for a whole field, for deciding whether an LWW
/// win changes the base text. `None` means the field is absent.
fn base_value(doc: &Value, pid: &str, field: &str) -> Option<Value> {
    let mut ps = Vec::new();
    crate::collect_packets(doc, &mut ps);
    ps.iter()
        .find(|p| p.get("packet_id").and_then(Value::as_str) == Some(pid))
        .and_then(|p| p.get(field))
        .cloned()
}

/// Render a packet value as one canonical `    - ` list item.
///
/// serde_yaml CANNOT be used to render the whole packet, because it emits a
/// nested block sequence's items at the SAME column as their key (verified on
/// the live fragments: `capability_tags:`/`events:` items came out at the key's
/// column, not one level deeper). The ledger's canonical style — and the shape
/// `edit::item_span` / `edit::push_event` assume — is keys at 6, list items at
/// 8. A packet rendered the serde_yaml way puts events at 6-space, which
/// `push_event` then misreads as packet fields and splits. So the top level is
/// emitted here field-by-field; values are still serialized by serde_yaml and
/// indented to their canonical column.
fn render_item(v: &Value) -> String {
    let m = v.as_mapping().expect("a folded packet is a mapping");
    let mut out = String::new();
    let mut first = true;
    for (k, val) in m.iter() {
        let key = k.as_str().unwrap_or("<non-string-key>");
        if first {
            // The first field sits on the item's dash line, exactly like the
            // ledger's `- packet_id: x` / `- order: N` openings. Its value is a
            // scalar in practice; anything else renders under the dash.
            first = false;
            match scalar_text(val) {
                Some(s) => out.push_str(&format!("    - {key}: {s}\n")),
                None => out.push_str(&format!(
                    "    - {key}:{}\n",
                    render_value(val, 6).trim_end_matches('\n')
                )),
            }
        } else {
            out.push_str(&emit_field(key, 6, val));
        }
    }
    out
}

/// Does this string have the YAML 1.1 timestamp shape (`2026-08-13` or
/// `2026-08-13T23:36:42Z`)?
///
/// ORDER 729-biik. serde_yaml is a YAML **1.2** writer, where such a scalar is
/// just a string and needs no quotes. Ruby's Psych is a YAML **1.1** reader,
/// where the same bare scalar resolves to `Time` — a class `safe_load` refuses.
/// So the fold could emit a base that every Rust consumer reads and the 440
/// status-vocab gate cannot load at all. It happened twice: 231 scalars on
/// 2026-08-13, then 51 more the next fold, AFTER order 720-24u6 taught the
/// fragment gate to refuse hand-authored bare timestamps. That fix was correct
/// and incomplete — the second batch came from the fold's own serializer, which
/// re-emits event mappings rather than copying their text, so no fragment gate
/// could ever have seen them.
fn is_yaml11_timestamp(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() < 10 {
        return false;
    }
    let digit = |i: usize| b[i].is_ascii_digit();
    digit(0)
        && digit(1)
        && digit(2)
        && digit(3)
        && b[4] == b'-'
        && digit(5)
        && digit(6)
        && b[7] == b'-'
        && digit(8)
        && digit(9)
        && (b.len() == 10 || b[10] == b'T' || b[10] == b' ')
}

/// Quote a bare timestamp scalar on a rendered `key: value` line. Applied to
/// serde-serialized blocks, which never pass through `scalar_text`.
fn quote_timestamp_line(line: &str) -> String {
    let Some((head, value)) = line.split_once(": ") else {
        return line.to_string();
    };
    if is_yaml11_timestamp(value) {
        format!("{head}: \"{value}\"")
    } else {
        line.to_string()
    }
}

/// A single-line YAML rendering of `v`, or `None` when it cannot be one line.
fn scalar_text(v: &Value) -> Option<String> {
    // A YAML-1.1 timestamp must carry quotes into the base; see above.
    if let Value::String(s) = v
        && is_yaml11_timestamp(s)
    {
        return Some(format!("\"{s}\""));
    }
    let s = serde_yaml::to_string(v).ok()?;
    let s = s.trim_end();
    if s.contains('\n') {
        None
    } else {
        Some(s.to_string())
    }
}

/// Render the value of `key:` at column `keycol` in the ledger's canonical
/// style: scalars inline, empty lists as `[]`, block lists at `keycol + 2`,
/// multi-line strings as literal blocks with content at `keycol + 2`.
fn emit_field(key: &str, keycol: usize, v: &Value) -> String {
    let indent = " ".repeat(keycol);
    match v {
        Value::Sequence(seq) if !seq.is_empty() => {
            let mut out = format!("{indent}{key}:\n");
            for item in seq {
                out.push_str(&render_list_item(item, keycol + 2));
            }
            out
        }
        _ => format!(
            "{indent}{key}:{}\n",
            render_value(v, keycol).trim_end_matches('\n')
        ),
    }
}

/// The text that follows a `key:` for the value `v` positioned so the key text
/// sits at column `keycol`: either ` value` on the same line, or newline plus
/// continuation lines at `keycol + 2`. Returns a string ENDING in `\n`.
fn render_value(v: &Value, keycol: usize) -> String {
    match v {
        Value::String(s) if s.contains('\n') => format!(" {}\n", block_scalar(s, keycol + 2)),
        Value::Sequence(seq) if !seq.is_empty() => {
            let mut out = String::new();
            for item in seq {
                out.push('\n');
                out.push_str(&render_list_item(item, keycol + 2));
            }
            out
        }
        _ => match scalar_text(v) {
            Some(s) => format!(" {s}\n"),
            None => {
                // A nested non-scalar, non-sequence value (a mapping): serialize
                // and indent each line to the continuation column.
                let ser = serde_yaml::to_string(v).expect("a value serializes");
                let pad = " ".repeat(keycol + 2);
                let mut out = String::new();
                for l in ser.lines() {
                    out.push('\n');
                    out.push_str(&pad);
                    out.push_str(l);
                }
                out.push('\n');
                out
            }
        },
    }
}

/// One item of a block sequence whose dash sits at column `indent`. Returns a
/// string ending in `\n`.
fn render_list_item(item: &Value, indent: usize) -> String {
    let pad = " ".repeat(indent);
    match item {
        Value::Mapping(_) => {
            // serde_yaml renders a flat mapping list-item as `- key: v` with
            // nested fields and block content correctly indented relative to the
            // dash — exactly the event shape. Re-prefix the whole block to our
            // column.
            let s = serde_yaml::to_string(&vec![item.clone()]).expect("a mapping item serializes");
            let s = s.trim_end_matches('\n');
            s.lines()
                .map(|l| format!("{pad}{}\n", quote_timestamp_line(l)))
                .collect()
        }
        Value::String(s) if s.contains('\n') => format!("{pad}- {}\n", block_scalar(s, indent + 4)),
        _ => match scalar_text(item) {
            Some(s) => format!("{pad}- {s}\n"),
            None => {
                // A nested non-mapping item (never in this ledger): serialize
                // and indent each line at indent + 2.
                let ser = serde_yaml::to_string(item).expect("a value serializes");
                let pad2 = " ".repeat(indent + 2);
                let mut out = format!("{pad}-\n");
                for l in ser.lines() {
                    out.push_str(&pad2);
                    out.push_str(l);
                    out.push('\n');
                }
                out
            }
        },
    }
}

/// A YAML literal block scalar (`|` / `|-`) whose continuation lines sit at
/// `indent`, preserving the string byte-for-byte. The ledger writes `>` folded
/// scalars, which do NOT round-trip internal newlines, so folding is refused —
/// literal is the only style that is exact.
fn block_scalar(s: &str, indent: usize) -> String {
    let (chomp, body) = if s.ends_with('\n') {
        ("|", s.strip_suffix('\n').unwrap_or(s))
    } else {
        ("|-", s)
    };
    let pad = " ".repeat(indent);
    let mut out = format!("{chomp}\n");
    for l in body.split('\n') {
        out.push_str(&pad);
        out.push_str(l);
        out.push('\n');
    }
    out
}

/// Apply one LWW field win by replacing that field's exact text span inside the
/// target packet, or inserting a canonically-rendered field when it is absent.
///
/// This remains a targeted text edit rather than a YAML round-trip: continuation
/// lines belong to the field while they are indented deeper than the six-space
/// packet-field column. That lets sequences and block strings fold without
/// touching any other field, comment, or packet byte.
fn apply_lww(lines: &mut Vec<String>, pid: &str, field: &str, value: &Value) -> Result<(), String> {
    let raw = lines.join("\n");
    let (start, end) = crate::edit::item_span(&raw, pid)
        .ok_or_else(|| format!("LWW target packet_id '{pid}' not found in candidate"))?;
    let rendered: Vec<String> = emit_field(field, 6, value)
        .lines()
        .map(String::from)
        .collect();
    let key_prefix = format!("      {field}:");
    match (start..end).find(|&i| lines[i].starts_with(&key_prefix)) {
        Some(li) => {
            let field_end = (li + 1..end)
                .find(|&i| {
                    let line = &lines[i];
                    !line.trim().is_empty() && line.bytes().take_while(|b| *b == b' ').count() <= 6
                })
                .unwrap_or(end);
            lines.splice(li..field_end, rendered);
        }
        None => {
            lines.splice(start + 1..start + 1, rendered);
        }
    }
    Ok(())
}

/// Drift signals that make compaction eligible, for the meta-orchestration step.
///
/// Reported rather than enforced: compaction is OPTIONAL. An uncompacted ledger
/// is slower to read, never wrong, so this must never sit on the critical path
/// of filing work.
pub struct Drift {
    pub fragment_count: usize,
    pub total_bytes: u64,
    pub malformed_count: usize,
}

impl Drift {
    /// Thresholds are judgement, not correctness. These are deliberately loose:
    /// compaction rewrites the base, which is the one operation that CAN
    /// conflict, so doing it often would reintroduce the problem this design
    /// removes.
    pub fn eligible(&self) -> bool {
        self.fragment_count >= 25 || self.total_bytes >= 256 * 1024 || self.malformed_count > 0
    }

    pub fn verdict(&self) -> String {
        let reason = if self.malformed_count > 0 {
            "malformed-fragments"
        } else if self.fragment_count >= 25 {
            "fragment-count"
        } else if self.total_bytes >= 256 * 1024 {
            "total-bytes"
        } else {
            "-"
        };
        format!(
            "compaction: eligible={} fragments={} bytes={} malformed={} reason={}",
            self.eligible(),
            self.fragment_count,
            self.total_bytes,
            self.malformed_count,
            reason
        )
    }
}

pub fn drift(index: &Path) -> Drift {
    let fragments = load_all(index);
    let malformed_count = malformed(index).len();
    let total_bytes = fragments
        .iter()
        .filter_map(|f| std::fs::metadata(&f.path).ok())
        .map(|m| m.len())
        .sum();
    Drift {
        fragment_count: fragments.len(),
        total_bytes,
        malformed_count,
    }
}

impl Ledger {
    /// Fragment-aware load: `base ⊕ fold(fragments)`.
    ///
    /// Every read path MUST come through here. A reader that forgets fragments
    /// reports a stale ledger with total confidence, and if the CLI, the MCP
    /// server and the expert disagree about what the plan says, the retrieval
    /// surface is worse than useless.
    pub fn load_with_fragments(path: &Path) -> Result<Self, String> {
        // Load the BASE first and keep its ledger wholesale, so `spans` stay
        // byte-exact against the real plan/index.yaml.
        //
        // THE MISTAKE THIS AVOIDS, found by the order-523 self-verifier the same
        // day it was written: an earlier version folded base+fragments into one
        // document, re-SERIALIZED it, and parsed that. Spans were then computed
        // over the serialized text, whose line numbers correspond to no file on
        // disk, so EVERY citation — including for packets that had never been
        // near a fragment — pointed at wrong lines in plan/index.yaml. The
        // verifier caught it and downgraded the answers, reporting "FABRICATED
        // citation", which is exactly right and exactly what it exists for. The
        // net effect was that adding fragments silently disabled the cited-answer
        // surface, i.e. the expert's entire reason to exist.
        //
        // So the base ledger is never rebuilt. Fragment content is layered ON
        // TOP of it.
        let mut ledger = Self::load(path)?;
        let fragments = load_all(path);
        // Freshness input set: EVERY fragment file beside the index, parseable
        // or not — a malformed fragment still changes the corpus, and hiding it
        // from freshness would make its absence from answers look current.
        let mut corpus_files: Vec<PathBuf> = std::fs::read_dir(fragment_dir(path))
            .map(|entries| {
                entries
                    .flatten()
                    .map(|e| e.path())
                    .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("yaml"))
                    .collect()
            })
            .unwrap_or_default();
        corpus_files.sort();
        // ORDER 796-4ydb — the fold's own record of what it could not read.
        // Derived from the SAME directory listing as `corpus_files` (a file
        // present in the corpus that `load_all` did not yield is one that could
        // not be read or parsed) rather than by re-scanning with `malformed`:
        // two scans of a directory other hosts append to can disagree, and the
        // disagreement would land exactly on the fragment being reported.
        let parsed: std::collections::BTreeSet<&Path> =
            fragments.iter().map(|f| f.path.as_path()).collect();
        let skipped: Vec<PathBuf> = corpus_files
            .iter()
            .filter(|p| !parsed.contains(p.as_path()))
            .cloned()
            .collect();
        if fragments.is_empty() {
            // NOT necessarily an empty directory: a corpus whose fragments ALL
            // fail to parse arrives here too, and that is the worst case, not
            // the trivial one. It must carry `skipped` like any other.
            ledger.set_fragment_sources(
                std::collections::BTreeMap::new(),
                std::collections::BTreeMap::new(),
                corpus_files,
                skipped,
            );
            return Ok(ledger);
        }

        let base_doc: Value = {
            let raw = std::fs::read_to_string(path)
                .map_err(|e| format!("read {}: {e}", path.display()))?;
            serde_yaml::from_str(&raw).map_err(|e| format!("parse: {e}"))?
        };
        let (merged, provenance) = fold_with_sources(&base_doc, &fragments);

        // Replace the packet list with the folded one so queries see everything,
        // while `spans` and `source_path` remain those of the base parse.
        let mut folded_packets = Vec::new();
        crate::collect_packets(&merged, &mut folded_packets);
        ledger.packets = folded_packets;
        // The lookup indexes were built over the BASE packet list, so replacing
        // `packets` without rebuilding them leaves every fragment-only packet
        // unresolvable — present in the list, invisible to `status`. Rebuild them
        // over the folded list, preserving the same ambiguity policy the base
        // parse applies (duplicates are dropped, never resolved arbitrarily).
        ledger.reindex();

        // ORDER 606-h9vy — CITABILITY NOW EXTENDS TO FRAGMENT CONTENT via
        // per-packet source attribution. `span_of` still returns None for a
        // fragment-only packet (base spans stay byte-exact against the real
        // plan/index.yaml, the order-523 invariant), but the ledger now carries
        // a sidecar source map naming the WINNING fragment file and span:
        //
        //   * a fragment-born packet's origin is the fragment item that
        //     created it (`origin_source_of`);
        //   * an LWW-overridden field's source is the fragment status entry
        //     that won the fold (`field_source_of`) — never the stale base
        //     span, which still shows the value the fragment replaced.
        //
        // Spans are recovered from the fragment's retained raw text and always
        // contain the `packet_id: <id>` line, so the order-523 verifier can
        // substantiate them exactly like base spans.
        let mut origin_sources = std::collections::BTreeMap::new();
        for (pid, idx) in &provenance.new_packets {
            let frag = &fragments[*idx];
            if let Some((start, end)) = fragment_item_span(&frag.raw, "packets", pid, &[]) {
                origin_sources.insert(
                    pid.clone(),
                    crate::FieldSource {
                        fragment_name: frag.name.clone(),
                        line_start: start,
                        line_end: end,
                    },
                );
            }
        }
        let mut field_sources = std::collections::BTreeMap::new();
        for (key, (idx, ts, host)) in &provenance.lww_wins {
            let frag = &fragments[*idx];
            let mut parts = key.split('\u{1}');
            let (Some(pid), Some(field)) = (parts.next(), parts.next()) else {
                continue;
            };
            // Disambiguate between entries for the same (packet, field) inside
            // one fragment by requiring the winning ts/host to appear in the
            // block. Empty ts/host (legal, they default to "" in the fold)
            // cannot be required — the field needle alone identifies the entry.
            let field_needle = format!("field: {field}");
            let mut needles: Vec<&str> = vec![field_needle.as_str()];
            if !ts.is_empty() {
                needles.push(ts.as_str());
            }
            if !host.is_empty() {
                needles.push(host.as_str());
            }
            if let Some((start, end)) = fragment_item_span(&frag.raw, "status", pid, &needles) {
                field_sources.insert(
                    key.clone(),
                    crate::FieldSource {
                        fragment_name: frag.name.clone(),
                        line_start: start,
                        line_end: end,
                    },
                );
            }
        }
        ledger.set_fragment_sources(origin_sources, field_sources, corpus_files, skipped);
        Ok(ledger)
    }
}

/// One host's contribution to the fleet capability matrix (order 808-7yrd).
#[derive(Debug, Clone, PartialEq)]
pub struct CapabilityEntry {
    /// The machine this row describes — `HostInfo.host_id` (order 808-43mw).
    pub host_id: String,
    /// WHICH EXECUTION CONTEXT observed it, e.g. `in-guest`, `windows-host`.
    ///
    /// Half of the fold key, and the half that is easy to think unnecessary.
    /// See [`fold_capabilities`] for the collision it prevents.
    pub locus: String,
    /// LWW timestamp, and with `host` the deterministic tiebreak.
    pub ts: String,
    /// The writing host kind, matching every other channel's `host:` field.
    pub host: String,
    /// The contributed `CapabilityDocument`, carried verbatim.
    pub document: Value,
    /// Fragment this row came from, so a reader can cite it.
    pub source: String,
}

/// A `capabilities:` row that could not be folded, and why.
///
/// Returned rather than dropped: a row silently discarded is indistinguishable
/// from a host that never contributed, which is the failure mode this whole
/// channel exists to avoid one level up.
#[derive(Debug, Clone, PartialEq)]
pub struct SkippedCapabilityRow {
    pub source: String,
    pub reason: String,
}

/// Fold the `capabilities:` channel into the fleet matrix (order 808-7yrd).
///
/// # Why this is a fourth channel and not a fourth mechanism
///
/// The matrix needs exactly what `plan/index.d` already provides: append-only
/// fragments, deterministic `(ts, filename)` fold order, and a register whose
/// winner is chosen by `(ts, host)` rather than by arrival. Building a parallel
/// store would mean a second compaction, a second malformed-file policy and a
/// second determinism argument, each able to drift from the one beside it. So
/// this rides the SAME fragment files and the SAME ordering, and differs only
/// in its keyspace.
///
/// # The key is `(host_id, locus)`, and the second half is not decoration
///
/// 808-43mw had to land first: before it a `CapabilityDocument` could not say
/// which machine it described, and `kernel_release` is not a substitute because
/// two WSL2 guests report the same one.
///
/// But `host_id` ALONE is not enough, and the reason was found by trying to
/// implement 809-7e4m on top of this channel rather than by reasoning about it.
/// On Windows a single machine is observed from TWO execution contexts: the
/// WSL2 guest sees the CPU and the paravirtual GPU; Windows sees the NPU, the
/// true GPU name and the machine's real RAM (the guest reports its 7.3 GB VM
/// slice against 15.2 GB installed). Both contributions describe machine
/// `yolanda`, so both carry the same `host_id`.
///
/// Keyed on `host_id` alone, the second contribution SILENTLY REPLACES the
/// first — measured, not hypothesised: contributing a Windows-side row erased
/// the CPU and the GPU from the matrix entirely, leaving a machine that appeared
/// to have one unusable NPU and nothing else. That is data loss dressed as an
/// update.
///
/// 808-7yrd's premise — "single writer per key by construction, so LWW never
/// arbitrates a real conflict" — is TRUE, but only once the key includes the
/// locus. With `(host_id, locus)` each key really does have one writer: the
/// guest owns `(yolanda, in-guest)`, Windows owns `(yolanda, windows-host)`,
/// and neither can clobber the other. Assembling a machine's complete row from
/// its several loci is then the consumer's job, done with everything present,
/// rather than a merge that happens to run in the right order.
///
/// # LWW here is a backstop, not the mechanism
///
/// Within one key there is one writer, so LWW decides exactly one thing: which
/// of that writer's successive probes is current. That is why plain `(ts, host)`
/// is right and the status channel's monotone closure ladder is NOT — capability
/// rows have no ranking, a later probe simply describes the machine as it is
/// now.
///
/// # Nothing is dropped in silence
///
/// A row missing `host_id` or `locus` cannot be keyed, and is returned in the
/// skipped list rather than discarded or folded under a blank key. Folding
/// under a blank key would collect every unidentifiable contribution into one
/// row presenting as a host whose hardware kept changing; discarding it quietly
/// would make a misfiled contribution look exactly like a host that never
/// contributed. Both are the failure this channel exists to prevent.
///
/// Separate from [`fold`] deliberately: a capability row is not a packet, and
/// merging it into the packet document would put hardware state in a ledger
/// whose every other entry is work.
pub fn fold_capabilities(
    fragments: &[Fragment],
) -> (
    std::collections::BTreeMap<(String, String), CapabilityEntry>,
    Vec<SkippedCapabilityRow>,
) {
    let mut matrix: std::collections::BTreeMap<(String, String), CapabilityEntry> =
        std::collections::BTreeMap::new();
    let mut skipped: Vec<SkippedCapabilityRow> = Vec::new();

    for frag in fragments {
        let Some(rows) = frag.doc.get("capabilities").and_then(Value::as_sequence) else {
            continue;
        };
        for row in rows {
            let Some(document) = row.get("document") else {
                skipped.push(SkippedCapabilityRow {
                    source: frag.name.clone(),
                    reason: "row carries no `document:`".to_string(),
                });
                continue;
            };
            // host_id is read from the DOCUMENT, not from a sibling key that
            // could disagree with it. One source of truth for identity.
            let Some(host_id) = document
                .get("host")
                .and_then(|h| h.get("host_id"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            else {
                skipped.push(SkippedCapabilityRow {
                    source: frag.name.clone(),
                    reason: "document has no `host.host_id` (predates 808-43mw?)".to_string(),
                });
                continue;
            };
            // The locus is on the ROW, not in the document: it describes the
            // OBSERVATION, and one probe binary can be run from either side.
            let Some(locus) = row
                .get("locus")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            else {
                skipped.push(SkippedCapabilityRow {
                    source: frag.name.clone(),
                    reason: format!(
                        "row for host_id `{host_id}` has no `locus:` — refusing to key it, \
                         because a second context observing the same machine would overwrite it"
                    ),
                });
                continue;
            };
            let ts = row
                .get("ts")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let host = row
                .get("host")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();

            let key = (host_id.to_string(), locus.to_string());
            let incoming = CapabilityEntry {
                host_id: host_id.to_string(),
                locus: locus.to_string(),
                ts,
                host,
                document: document.clone(),
                source: frag.name.clone(),
            };
            let better = match matrix.get(&key) {
                None => true,
                Some(prev) => {
                    (incoming.ts.as_str(), incoming.host.as_str())
                        > (prev.ts.as_str(), prev.host.as_str())
                }
            };
            if better {
                matrix.insert(key, incoming);
            }
        }
    }

    (matrix, skipped)
}

/// Why two measurements may not be ranked against each other (order 810-jeg7).
#[derive(Debug, Clone, PartialEq)]
pub enum Comparability {
    /// Same workload, same locus: a ranking is meaningful.
    Comparable,
    /// One or both carry no locus, so nothing is known about where they ran.
    RefusedUnlocated,
    /// Both located, but at different loci.
    RefusedDifferentLoci(String, String),
    /// Different workloads, which is not a slower machine but a different question.
    RefusedDifferentWorkloads(String, String),
}

impl Comparability {
    pub fn is_comparable(&self) -> bool {
        matches!(self, Comparability::Comparable)
    }

    /// A one-line reason, for a reader that has to explain the refusal.
    pub fn reason(&self) -> String {
        match self {
            Comparability::Comparable => "comparable".to_string(),
            Comparability::RefusedUnlocated => {
                "refused: a measurement without a locus cannot be placed".to_string()
            }
            Comparability::RefusedDifferentLoci(a, b) => {
                format!("refused: different loci ({a} vs {b})")
            }
            Comparability::RefusedDifferentWorkloads(a, b) => {
                format!("refused: different workloads ({a} vs {b})")
            }
        }
    }
}

/// May these two measurements be ranked against each other? (order 810-jeg7)
///
/// # Why this refuses instead of warning
///
/// This host measured the SAME suite on the SAME machine at two loci and the
/// hop cost 5-10% on the embed arm — the same order as the cross-host
/// differences the fleet matrix exists to detect. It did not merely add noise:
/// it INVERTED a reported conclusion. Yolanda had been reported
/// "indistinguishable" from yoga on the prefill-shaped arm; measured at a
/// common locus it is FASTER. The original reading survived because two errors
/// cancelled, which is the worst kind of wrong because nothing about it looks
/// wrong.
///
/// A warning attached to a number that is still ranked gets read as a caveat on
/// a result. A refusal has no such failure mode: there is no ranking to
/// misread. So the matrix declines rather than annotates.
///
/// # An absent locus is refused, not defaulted
///
/// `MeasurementRecord.locus` is `Option` at the SCHEMA layer so that writers
/// predating the field keep recording (see 808-43mw). That compatibility must
/// not leak upward into the comparison: defaulting an unlabelled record to
/// "probably the usual locus" would manufacture exactly the false comparability
/// this exists to prevent. Schema permits absence; the matrix requires
/// presence. PROBE-9 states that split.
///
/// # Workload mismatch refuses too
///
/// 810-jeg7 names the locus, but `workload_suite` landed in the same bump for
/// the same reason and a reader that refuses on locus while silently ranking
/// across workloads keeps the hole open on the other axis. Two suites are not a
/// faster and a slower machine; they are different questions.
pub fn measurements_comparable(a: &Value, b: &Value) -> Comparability {
    let field = |v: &Value, k: &str| {
        v.get(k)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };

    let (Some(la), Some(lb)) = (field(a, "locus"), field(b, "locus")) else {
        return Comparability::RefusedUnlocated;
    };
    if la != lb {
        return Comparability::RefusedDifferentLoci(la, lb);
    }
    // Two records that both omit the suite are treated as the same unknown
    // workload rather than refused: the locus check has already established
    // they were observed the same way, and 810-jeg7's claim is about locus.
    // Refusing here would reject every pre-808-43mw pair for a reason that
    // packet does not make.
    match (field(a, "workload_suite"), field(b, "workload_suite")) {
        (Some(wa), Some(wb)) if wa != wb => Comparability::RefusedDifferentWorkloads(wa, wb),
        (Some(wa), None) => Comparability::RefusedDifferentWorkloads(wa, "unstated".to_string()),
        (None, Some(wb)) => Comparability::RefusedDifferentWorkloads("unstated".to_string(), wb),
        _ => Comparability::Comparable,
    }
}

/// Split a document's measurements into those the matrix will accept and those
/// it refuses, with a reason for each refusal (order 810-jeg7).
///
/// Returned as a partition rather than filtered in place: a measurement dropped
/// without a reason is indistinguishable from a measurement never taken, which
/// is the same silent-loss failure the capability channel's skipped-row list
/// exists to prevent one level up.
pub fn partition_measurements(document: &Value) -> (Vec<Value>, Vec<(Value, String)>) {
    let mut accepted = Vec::new();
    let mut refused = Vec::new();
    let Some(ms) = document.get("measurements").and_then(Value::as_sequence) else {
        return (accepted, refused);
    };
    for m in ms {
        match m
            .get("locus")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            Some(_) => accepted.push(m.clone()),
            None => refused.push((
                m.clone(),
                "no locus: the matrix cannot place this measurement".to_string(),
            )),
        }
    }
    (accepted, refused)
}

/// The schedulable unit of the matrix: `(device_class, lane, engine)`
/// (order 808-7yrd).
///
/// `legacy_tier` is DERIVED and never authoritative — a single string cannot
/// express "this GPU is present but has no lane", which is the state every WSL2
/// host is in. A scheduler asks which triples a host offers; it does not read a
/// tier and hope.
///
/// A device contributes its triples only when `usable` is true AND it has at
/// least one lane. A present-unusable device (806-2r4s) therefore contributes
/// NOTHING here while remaining fully visible in the document — which is the
/// entire point of recording it: "present but unschedulable" and "absent" are
/// different engineering problems and must not collapse to the same emptiness.
pub fn schedulable_triples(document: &Value) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    let Some(devices) = document.get("devices").and_then(Value::as_sequence) else {
        return out;
    };
    // The optional third coordinate on an engine (order 850-bif2): which
    // lanes it is reachable on. Absent means every lane — the semantics of
    // every row filed before the field existed, and of host-PATH binaries. A
    // containerized engine (the fleet's ollama inside tillandsias-inference)
    // says ["container"], so it can never mint a host-native triple.
    type EngineView<'a> = (&'a str, Vec<&'a str>, Option<Vec<&'a str>>);
    let engines: Vec<EngineView> = document
        .get("engines")
        .and_then(Value::as_sequence)
        .map(|es| {
            es.iter()
                .filter_map(|e| {
                    let name = e.get("name").and_then(Value::as_str)?;
                    let classes = e
                        .get("supported_device_classes")
                        .and_then(Value::as_sequence)
                        .map(|cs| cs.iter().filter_map(Value::as_str).collect())
                        .unwrap_or_default();
                    let lanes = e
                        .get("lanes")
                        .and_then(Value::as_sequence)
                        .map(|ls| ls.iter().filter_map(Value::as_str).collect());
                    Some((name, classes, lanes))
                })
                .collect()
        })
        .unwrap_or_default();

    for d in devices {
        if d.get("usable").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let Some(class) = d.get("device_class").and_then(Value::as_str) else {
            continue;
        };
        let Some(lanes) = d.get("lanes").and_then(Value::as_sequence) else {
            continue;
        };
        for lane in lanes.iter().filter_map(Value::as_str) {
            for (engine, classes, engine_lanes) in &engines {
                let lane_ok = engine_lanes.as_ref().is_none_or(|els| els.contains(&lane));
                if lane_ok && classes.contains(&class) {
                    out.push((class.to_string(), lane.to_string(), (*engine).to_string()));
                }
            }
        }
    }
    out.sort();
    out.dedup();
    out
}
#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "\
packets:
    - packet_id: alpha
      order: 100
      status: ready
      events:
        - type: filed
          ts: \"2026-01-01T00:00:00Z\"
          agent_id: origin
          summary: born
";

    fn base() -> Value {
        serde_yaml::from_str(BASE).expect("base parses")
    }

    fn frag(name: &str, yaml: &str) -> Fragment {
        Fragment {
            name: name.to_string(),
            path: PathBuf::from(name),
            doc: serde_yaml::from_str(yaml).expect("fragment parses"),
            raw: yaml.to_string(),
        }
    }

    fn packet_ids(doc: &Value) -> Vec<String> {
        let mut ps = Vec::new();
        crate::collect_packets(doc, &mut ps);
        let mut ids: Vec<String> = ps
            .iter()
            .filter_map(|p| p.get("packet_id").and_then(Value::as_str))
            .map(str::to_string)
            .collect();
        ids.sort();
        ids
    }

    fn events_of(doc: &Value, id: &str) -> Vec<String> {
        let mut ps = Vec::new();
        crate::collect_packets(doc, &mut ps);
        ps.iter()
            .find(|p| p.get("packet_id").and_then(Value::as_str) == Some(id))
            .and_then(|p| p.get("events").and_then(Value::as_sequence).cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|e| e.get("summary").and_then(Value::as_str))
            .map(str::to_string)
            .collect()
    }

    fn field(doc: &Value, id: &str, key: &str) -> String {
        let mut ps = Vec::new();
        crate::collect_packets(doc, &mut ps);
        ps.iter()
            .find(|p| p.get("packet_id").and_then(Value::as_str) == Some(id))
            .and_then(|p| p.get(key).and_then(Value::as_str))
            .unwrap_or("<missing>")
            .to_string()
    }

    const HOST_A: &str = "packets:\n  - packet_id: beta\n    order: 581-aaaa\n    status: ready\n";
    const HOST_B: &str = "packets:\n  - packet_id: gamma\n    order: 581-bbbb\n    status: ready\n";

    #[test]
    fn set_field_body_round_trips_hostile_prose() {
        // ORDER 775-b4qz exit criterion 1, exact list: a value containing
        // ": ", "#", a leading "- ", and a double quote must re-fold
        // byte-identical. Plus the two shapes that each broke a prior fix:
        // multi-line prose (832-698m's follow-up) and a bare YAML-1.1
        // timestamp (the mirror's Psych gate, 627-c9c2).
        let cases = [
            "Wave 2: (1) seed the row",
            "# looks like a comment but is prose",
            "- looks like a list item",
            "she said \"push it\" and left",
            "REFUTED: see notes\n\n  - indented dash # hash tail\nfinal line: done",
            "2026-08-23T11:00:00Z",
        ];
        for value in cases {
            let body = set_field_fragment_body(
                "alpha",
                "next_action",
                value,
                "2026-08-23T00:00:00Z",
                "t",
                &[],
            );
            let merged = fold(&base(), &[frag("1-t.yaml", &body)]);
            assert_eq!(
                field(&merged, "alpha", "next_action"),
                value,
                "round-trip for {value:?}"
            );
        }
    }

    #[test]
    fn set_field_body_round_trips_value_beside_events() {
        // The --reason/--evidence channel rides in the same fragment; the row
        // must still read back when event blocks follow it.
        let value = "Fix the gate: quote everything";
        let body = set_field_fragment_body(
            "alpha",
            "status",
            value,
            "2026-08-23T00:00:00Z",
            "t",
            &[(
                "note".to_string(),
                "claimed: because reasons # with tail".to_string(),
            )],
        );
        let merged = fold(&base(), &[frag("1-t.yaml", &body)]);
        assert_eq!(field(&merged, "alpha", "status"), value);
        assert!(
            events_of(&merged, "alpha")
                .iter()
                .any(|s| s.contains("because reasons"))
        );
    }

    #[test]
    fn verify_written_lww_accepts_good_and_refuses_corrupt() {
        // ORDER 775-b4qz exit criterion 2: the exit-0-on-corruption shape.
        // A good body verifies; the OLD raw interpolation (`value: Wave 2:
        // (1) …`) must be refused by the same parser the fold uses.
        let dir = std::env::temp_dir().join(format!(
            "tillandsias-775-b4qz-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).expect("tempdir");
        let good = dir.join("good.yaml");
        let value = "Wave 2: (1) seed the row";
        std::fs::write(
            &good,
            set_field_fragment_body(
                "alpha",
                "next_action",
                value,
                "2026-08-23T00:00:00Z",
                "t",
                &[],
            ),
        )
        .expect("write good");
        assert_eq!(
            verify_written_lww(&good, "alpha", "next_action", value),
            Ok(())
        );
        // Wrong expectation → mismatch, not Ok.
        assert!(verify_written_lww(&good, "alpha", "next_action", "other").is_err());

        let bad = dir.join("bad.yaml");
        std::fs::write(
            &bad,
            "status:\n  - packet_id: alpha\n    field: next_action\n    value: Wave 2: (1) seed\n    ts: \"2026-08-23T00:00:00Z\"\n    host: t\n",
        )
        .expect("write bad");
        assert!(verify_written_lww(&bad, "alpha", "next_action", "Wave 2: (1) seed").is_err());
        assert!(verify_written_parses(&bad).is_err());
        assert_eq!(verify_written_parses(&good), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn concurrent_packet_adds_from_two_hosts_both_survive() {
        // The scenario this whole module exists for: two hosts filing at once.
        // Under the monolithic ledger this is a git conflict a human resolves.
        let merged = fold(
            &base(),
            &[frag("1-a.yaml", HOST_A), frag("2-b.yaml", HOST_B)],
        );
        assert_eq!(packet_ids(&merged), vec!["alpha", "beta", "gamma"]);
    }

    #[test]
    fn the_fold_is_commutative_the_defining_crdt_property() {
        // Order of arrival must not change the result. If this fails, two hosts
        // compute different states from identical inputs, which presents as data
        // corruption rather than as a sorting bug.
        let ab = fold(
            &base(),
            &[frag("1-a.yaml", HOST_A), frag("2-b.yaml", HOST_B)],
        );
        let ba = fold(
            &base(),
            &[frag("2-b.yaml", HOST_B), frag("1-a.yaml", HOST_A)],
        );
        assert_eq!(packet_ids(&ab), packet_ids(&ba));
    }

    #[test]
    fn the_fold_is_idempotent_so_a_half_finished_compaction_is_safe() {
        // Compaction folds then deletes. If it dies between the two, the next
        // fold sees fragments whose contents are ALREADY in the base. Folding
        // them again must add nothing, or every crash duplicates events.
        let ev = "events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: \"2026-02-02T00:00:00Z\"\n      agent_id: h1\n      summary: probe\n";
        let once = fold(&base(), &[frag("1-a.yaml", ev)]);
        assert_eq!(events_of(&once, "alpha"), vec!["born", "probe"]);

        let twice = fold(&once, &[frag("1-a.yaml", ev)]);
        assert_eq!(
            events_of(&twice, "alpha"),
            vec!["born", "probe"],
            "re-folding an already-merged fragment must be a no-op"
        );
    }

    #[test]
    fn events_from_two_hosts_on_one_packet_both_survive() {
        // Events are a G-SET, not a register. Treating them as last-writer-wins
        // would silently discard one host's evidence — the subtlest way to lose
        // work in this design.
        let a = "events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: \"2026-02-02T00:00:00Z\"\n      agent_id: h1\n      summary: from-a\n";
        let b = "events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: \"2026-02-02T00:00:01Z\"\n      agent_id: h2\n      summary: from-b\n";
        let merged = fold(&base(), &[frag("1-a.yaml", a), frag("2-b.yaml", b)]);
        let evs = events_of(&merged, "alpha");
        assert!(
            evs.contains(&"from-a".to_string()) && evs.contains(&"from-b".to_string()),
            "both hosts' events must survive: {evs:?}"
        );
    }

    #[test]
    fn status_is_last_writer_wins_and_the_winner_does_not_depend_on_order() {
        // A status field CAN only hold one value, so the winner must be chosen
        // deterministically by (ts, host) rather than by who was applied last.
        let older = "status:\n  - packet_id: alpha\n    field: status\n    value: claimed\n    ts: \"2026-03-01T00:00:00Z\"\n    host: aaa\n";
        let newer = "status:\n  - packet_id: alpha\n    field: status\n    value: completed\n    ts: \"2026-03-02T00:00:00Z\"\n    host: bbb\n";

        let forward = fold(&base(), &[frag("1-a.yaml", older), frag("2-b.yaml", newer)]);
        let reverse = fold(&base(), &[frag("2-b.yaml", newer), frag("1-a.yaml", older)]);
        assert_eq!(field(&forward, "alpha", "status"), "completed");
        assert_eq!(
            field(&reverse, "alpha", "status"),
            "completed",
            "the newer write must win regardless of fold order"
        );
    }

    #[test]
    fn fragment_only_packet_accepts_lifecycle_updates_and_events() {
        let added = "packets:\n  - packet_id: gamma\n    order: 585-v2fa\n    status: ready\n";
        let claimed = "status:\n  - packet_id: gamma\n    field: status\n    value: claimed\n    ts: \"2026-03-01T00:00:00Z\"\n    host: aaa\nevents:\n  - packet_id: gamma\n    event:\n      type: claim\n      ts: \"2026-03-01T00:00:00Z\"\n      agent_id: h1\n      summary: claimed\n";
        let completed = "status:\n  - packet_id: gamma\n    field: status\n    value: completed\n    ts: \"2026-03-02T00:00:00Z\"\n    host: bbb\nevents:\n  - packet_id: gamma\n    event:\n      type: completed\n      ts: \"2026-03-02T00:00:00Z\"\n      agent_id: h2\n      summary: completed\n";

        let in_progress = fold(
            &base(),
            &[frag("1-add.yaml", added), frag("2-claim.yaml", claimed)],
        );
        assert_eq!(field(&in_progress, "gamma", "status"), "claimed");
        assert_eq!(events_of(&in_progress, "gamma"), vec!["claimed"]);

        let done = fold(
            &base(),
            &[
                frag("1-add.yaml", added),
                frag("2-claim.yaml", claimed),
                frag("3-complete.yaml", completed),
            ],
        );
        assert_eq!(field(&done, "gamma", "status"), "completed");
        assert_eq!(events_of(&done, "gamma"), vec!["claimed", "completed"]);
    }

    #[test]
    fn a_packet_already_in_the_base_is_never_overwritten_by_a_fragment() {
        // Re-adding must be a no-op, not an overwrite: an overwrite would make
        // the result depend on fold order, breaking commutativity.
        let dup = "packets:\n  - packet_id: alpha\n    order: 999\n    status: completed\n";
        let merged = fold(&base(), &[frag("1-a.yaml", dup)]);
        assert_eq!(packet_ids(&merged), vec!["alpha"], "no duplicate packet");
        assert_eq!(
            field(&merged, "alpha", "status"),
            "ready",
            "the base wins for G-Set re-adds; status changes go through the LWW channel"
        );
    }

    #[test]
    fn compaction_reports_exactly_what_it_consumed() {
        // It must delete BY NAME, never by glob: a fragment written by another
        // host mid-compaction has not been folded, and globbing it away would
        // silently destroy filed work.
        let dir = std::env::temp_dir().join(format!("tilland-frag-{}", std::process::id()));
        let d = dir.join("plan");
        std::fs::create_dir_all(d.join("index.d")).expect("mkdir");
        let index = d.join("index.yaml");
        std::fs::write(&index, BASE).expect("write base");
        std::fs::write(
            d.join("index.d").join("20260801t0000z-aaaa-h1.yaml"),
            HOST_A,
        )
        .expect("write frag");

        let base_doc: Value = serde_yaml::from_str(BASE).expect("parse");
        let c = compact(&base_doc, &index);
        assert_eq!(c.consumed.len(), 1, "exactly the one fragment present");
        assert!(packet_ids(&c.merged).contains(&"beta".to_string()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fragment_names_sort_chronologically_because_the_fold_depends_on_it() {
        let early = fragment_name("20260801T0100Z", "aaaa", "linux-mutable");
        let late = fragment_name("20260801T0200Z", "bbbb", "osx");
        assert!(early < late, "utc-first naming must sort chronologically");
        assert!(
            !fragment_name("2026-08-01T01:00Z", "a/b", "host name").contains(['/', ':', ' ']),
            "a fragment name must be filesystem-safe"
        );
    }

    #[test]
    fn a_malformed_fragment_is_skipped_but_reported_never_silently_dropped() {
        let dir = std::env::temp_dir().join(format!("tilland-bad-{}", std::process::id()));
        let d = dir.join("plan");
        std::fs::create_dir_all(d.join("index.d")).expect("mkdir");
        let index = d.join("index.yaml");
        std::fs::write(&index, BASE).expect("write base");
        std::fs::write(
            d.join("index.d").join("20260801t0000z-aaaa-h1.yaml"),
            HOST_A,
        )
        .expect("ok");
        std::fs::write(
            d.join("index.d").join("20260801t0001z-bbbb-h2.yaml"),
            "{{{ not yaml",
        )
        .expect("bad");

        assert_eq!(load_all(&index).len(), 1, "the good fragment still loads");
        assert_eq!(
            malformed(&index).len(),
            1,
            "the bad one is REPORTED — skipping quietly would lose work with no signal"
        );
        assert!(
            drift(&index).eligible(),
            "a malformed fragment makes compaction eligible"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_fragment_dir_leaves_the_base_untouched() {
        let merged = fold(&base(), &[]);
        assert_eq!(packet_ids(&merged), vec!["alpha"]);
        assert_eq!(events_of(&merged, "alpha"), vec!["born"]);
    }

    // ── Rank-aware status merge (686-7qcm / 650-dq6u closure ladder) ─────────
    // These pin `status_entry_wins` directly: the higher closure rung wins
    // regardless of arrival order, and only a falsified move goes down.

    #[test]
    fn higher_rung_wins_regardless_of_timestamp_order() {
        // verified(older) vs completed(newer): verified is higher, must win
        // EVEN though completed carries the later timestamp — proves order
        // independence in the "newer is lower" arrival.
        assert!(!status_entry_wins(
            Some("completed"),
            "2026-02-02T00:00:00Z",
            "h",
            false,
            Some("verified"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
        // The reverse arrival (verified newer than completed): still wins.
        assert!(status_entry_wins(
            Some("verified"),
            "2026-02-02T00:00:00Z",
            "h",
            false,
            Some("completed"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
    }

    #[test]
    fn a_stale_working_state_cannot_clobber_a_terminal_rung() {
        // in_progress written LATER than done must NOT win without falsified —
        // the classic "stale in_progress clobbers done" the fold must prevent.
        assert!(!status_entry_wins(
            Some("in_progress"),
            "2026-03-03T00:00:00Z",
            "h",
            false,
            Some("done"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
        // With a falsified event in the same fragment, the downgrade is allowed.
        assert!(status_entry_wins(
            Some("ready"),
            "2026-03-03T00:00:00Z",
            "h",
            true,
            Some("done"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
    }

    #[test]
    fn a_lower_rung_needs_falsified_but_a_higher_one_does_not() {
        // completed cannot overwrite verified without falsified…
        assert!(!status_entry_wins(
            Some("completed"),
            "2026-05-05T00:00:00Z",
            "h",
            false,
            Some("verified"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
        // …but WITH a falsified event it may (a re-attempt after refutation).
        assert!(status_entry_wins(
            Some("completed"),
            "2026-05-05T00:00:00Z",
            "h",
            true,
            Some("verified"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
    }

    #[test]
    fn equal_rung_and_working_states_use_plain_lww() {
        // equal rung → later (ts,host) wins
        assert!(status_entry_wins(
            Some("completed"),
            "2026-02-02T00:00:00Z",
            "h",
            false,
            Some("completed"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
        // two working states → plain LWW, newer wins
        assert!(status_entry_wins(
            Some("blocked"),
            "2026-02-02T00:00:00Z",
            "h",
            false,
            Some("ready"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
    }

    #[test]
    fn obsoleted_and_failed_are_lateral_terminal_moves_not_downgrades() {
        // obsoleted (supersession) may overwrite a ranked terminal by plain LWW
        // without a falsified event — it is not a rung retraction.
        assert!(status_entry_wins(
            Some("obsoleted"),
            "2026-04-04T00:00:00Z",
            "h",
            false,
            Some("done"),
            "2026-01-01T00:00:00Z",
            "h",
        ));
    }

    #[test]
    fn rank_aware_merge_is_commutative_end_to_end() {
        // Two fragments, one lifting alpha ready->verified (with evidence event)
        // and one stale ready re-declaration; the verified wins no matter which
        // fragment sorts later.
        let verified = "\
status:
    - packet_id: alpha
      field: status
      value: verified
      ts: \"2026-06-06T00:00:00Z\"
      host: a
";
        let stale_ready = "\
status:
    - packet_id: alpha
      field: status
      value: ready
      ts: \"2026-07-07T00:00:00Z\"
      host: b
";
        for order in [
            vec![frag("01", verified), frag("02", stale_ready)],
            vec![frag("01", stale_ready), frag("02", verified)],
        ] {
            let merged = fold(&base(), &order);
            let got = merged["packets"][0]["status"].as_str().unwrap();
            assert_eq!(got, "verified", "verified must survive a later stale ready");
        }
    }
}

#[cfg(test)]
mod overlay_citation_tests {
    use super::*;

    /// A base ledger with the same 4-space item shape the real one uses, so
    /// spans are computed exactly as in production.
    const BASE_FILE: &str = "\
plan_index:
  steps:
    - packet_id: alpha
      order: 100
      status: ready
    - packet_id: beta
      order: 101
      status: ready
";

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tilland-overlay-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("plan/index.d")).expect("mkdir");
        std::fs::write(d.join("plan/index.yaml"), BASE_FILE).expect("write base");
        d
    }

    #[test]
    fn overlay_preserves_exact_base_spans_so_citations_stay_verifiable() {
        // THE REGRESSION THIS PINS. An earlier overlay folded base+fragments,
        // RE-SERIALIZED the result, and parsed that — so spans were line numbers
        // into a string matching no file on disk. Every citation then pointed at
        // the wrong lines of plan/index.yaml, including for packets that had
        // never been near a fragment, and the order-523 verifier correctly
        // refused them as FABRICATED. Adding fragments silently disabled the
        // cited-answer surface, which is the expert's entire reason to exist.
        let d = scratch("spans");
        let index = d.join("plan/index.yaml");

        let before = Ledger::load(&index).expect("base loads");
        let span_before = before.span_of("alpha").expect("alpha has a span");

        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let after = Ledger::load_with_fragments(&index).expect("overlay loads");
        assert_eq!(
            after.span_of("alpha"),
            Some(span_before),
            "adding a fragment must not move an existing packet's span — that span \
             is a byte-offset into plan/index.yaml and is what makes a citation \
             verifiable"
        );

        // And the span must still contain the packet's own id line in the REAL
        // file, which is the property the verifier actually checks.
        let raw = std::fs::read_to_string(&index).expect("read base");
        let lines: Vec<&str> = raw.lines().collect();
        let (s, e) = span_before;
        assert!(
            lines[s - 1..e]
                .iter()
                .any(|l| l.contains("packet_id: alpha")),
            "the cited span must contain the id it is offered as evidence for"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_fragment_only_packet_is_queryable_but_carries_no_fabricated_span() {
        // Queryable is required — otherwise filing to a fragment loses the work.
        // A BASE span is deliberately absent: the packet is not in
        // plan/index.yaml, so any line range there would be fiction. Since
        // order 606-h9vy its citable origin is the FRAGMENT file instead —
        // see `a_fragment_only_packet_cites_the_fragment_that_created_it`.
        let d = scratch("frag");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        assert!(
            l.resolve("gamma").is_some(),
            "a fragment-only packet must be queryable by id"
        );
        assert!(
            l.resolve("102").is_some(),
            "and by its order token, or agents cannot reference it"
        );
        assert_eq!(
            l.span_of("gamma"),
            None,
            "a fragment-only packet must have NO span — inventing one produces a \
             citation that does not resolve, which is worse than no citation"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn overlay_indexes_are_rebuilt_so_base_packets_still_resolve_too() {
        // Replacing the packet list without rebuilding the lookup indexes left
        // fragment packets present-but-invisible; rebuilding them incorrectly
        // could equally lose the base ones. Both must resolve.
        let d = scratch("both");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        for id in ["alpha", "beta", "gamma"] {
            assert!(
                l.resolve(id).is_some(),
                "{id} must resolve through the overlay"
            );
        }
        for order in ["100", "101", "102"] {
            assert!(
                l.resolve(order).is_some(),
                "order {order} must resolve through the overlay"
            );
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    // ── ORDER 606-h9vy: winning-source attribution ──────────────────────────

    fn frag(name: &str, yaml: &str) -> Fragment {
        Fragment {
            name: name.to_string(),
            path: PathBuf::from(name),
            doc: serde_yaml::from_str(yaml).expect("fragment parses"),
            raw: yaml.to_string(),
        }
    }

    #[test]
    fn fold_provenance_records_the_same_winner_the_fold_applies() {
        let base = serde_yaml::from_str(BASE_FILE).expect("base parses");
        let frags = vec![
            frag(
                "20260801t0100z-aaaa-h1.yaml",
                "status:\n  - packet_id: alpha\n    field: status\n    value: in_progress\n    ts: \"2026-08-01T01:00:00Z\"\n    host: h1\n",
            ),
            frag(
                "20260801t0200z-bbbb-h2.yaml",
                "status:\n  - packet_id: alpha\n    field: status\n    value: completed\n    ts: \"2026-08-01T02:00:00Z\"\n    host: h2\npackets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
            ),
        ];
        let (merged, prov) = fold_with_sources(&base, &frags);

        // The later ts wins the fold; provenance must name the SAME fragment.
        let mut ps = Vec::new();
        crate::collect_packets(&merged, &mut ps);
        let alpha = ps
            .iter()
            .find(|p| p.get("packet_id").and_then(Value::as_str) == Some("alpha"))
            .expect("alpha folded");
        assert_eq!(
            alpha.get("status").and_then(Value::as_str),
            Some("completed")
        );
        let (idx, ts, host) = prov
            .lww_wins
            .get("alpha\u{1}status")
            .expect("winner recorded");
        assert_eq!(
            (*idx, ts.as_str(), host.as_str()),
            (1, "2026-08-01T02:00:00Z", "h2")
        );
        assert_eq!(prov.new_packets.get("gamma"), Some(&1));

        // Tie on (ts, host): the FIRST fragment in name-sorted order keeps the
        // slot, and provenance must record that same first-wins choice.
        let tie = vec![
            frag(
                "20260801t0100z-aaaa-h1.yaml",
                "status:\n  - packet_id: alpha\n    field: status\n    value: blocked\n    ts: \"2026-08-01T03:00:00Z\"\n    host: same\n",
            ),
            frag(
                "20260801t0200z-bbbb-h2.yaml",
                "status:\n  - packet_id: alpha\n    field: status\n    value: obsoleted\n    ts: \"2026-08-01T03:00:00Z\"\n    host: same\n",
            ),
        ];
        let (tied, prov) = fold_with_sources(&base, &tie);
        let mut ps = Vec::new();
        crate::collect_packets(&tied, &mut ps);
        let alpha = ps
            .iter()
            .find(|p| p.get("packet_id").and_then(Value::as_str) == Some("alpha"))
            .expect("alpha folded");
        assert_eq!(alpha.get("status").and_then(Value::as_str), Some("blocked"));
        let (idx, _, _) = prov
            .lww_wins
            .get("alpha\u{1}status")
            .expect("tie winner recorded");
        assert_eq!(*idx, 0, "provenance must record the first-wins tie choice");
    }

    #[test]
    fn fragment_item_span_locates_items_and_always_contains_the_id_line() {
        let raw = "\
# fragment header comment
status:
  - packet_id: alpha
    field: status
    value: in_progress
    ts: \"2026-08-01T01:00:00Z\"
    host: h1
  - packet_id: alpha
    field: owned_files
    value: []
    ts: \"2026-08-01T01:00:00Z\"
    host: h1

packets:
  - packet_id: gamma
    order: 102
    status: ready
";
        let (s, e) =
            fragment_item_span(raw, "status", "alpha", &["field: status"]).expect("status entry");
        let block: Vec<&str> = raw.lines().collect();
        let span = block[s - 1..e].join("\n");
        assert!(span.contains("packet_id: alpha"));
        assert!(span.contains("field: status"));
        assert!(
            !span.contains("owned_files"),
            "the span must be the ONE entry that substantiates the field, not the whole section"
        );

        let (s, e) = fragment_item_span(raw, "packets", "gamma", &[]).expect("packet item");
        let span = block[s - 1..e].join("\n");
        assert!(span.contains("packet_id: gamma"));
        assert!(span.contains("status: ready"));

        assert_eq!(
            fragment_item_span(raw, "status", "nonexistent", &[]),
            None,
            "an absent packet must locate nothing rather than a nearby block"
        );
    }

    #[test]
    fn a_fragment_only_packet_cites_the_fragment_that_created_it() {
        let d = scratch("origin");
        let index = d.join("plan/index.yaml");
        let frag_name = "20260801t0100z-aaaa-h1.yaml";
        std::fs::write(
            d.join("plan/index.d").join(frag_name),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        let src = l
            .origin_source_of("gamma")
            .expect("fragment-born packet must carry its winning origin");
        assert_eq!(src.fragment_name, frag_name);
        // The load-bearing property, identical to base spans: the span must
        // contain the packet's own id line IN THE REAL FRAGMENT FILE.
        let raw = std::fs::read_to_string(d.join("plan/index.d").join(frag_name)).expect("read");
        let lines: Vec<&str> = raw.lines().collect();
        assert!(
            lines[src.line_start - 1..src.line_end]
                .iter()
                .any(|l| l.contains("packet_id: gamma")),
            "the origin span must contain the id it is offered as evidence for"
        );
        assert!(
            l.origin_source_of("alpha").is_none(),
            "a base packet's origin is its base span, never a fragment"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_lww_override_cites_the_winning_fragment_never_the_stale_base_span() {
        let d = scratch("lww");
        let index = d.join("plan/index.yaml");
        let frag_name = "20260801t0100z-aaaa-h1.yaml";
        std::fs::write(
            d.join("plan/index.d").join(frag_name),
            "status:\n  - packet_id: alpha\n    field: status\n    value: in_progress\n    ts: \"2026-08-01T01:00:00Z\"\n    host: h1\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        let src = l
            .field_source_of("alpha", "status")
            .expect("the overridden field must carry its winning source");
        assert_eq!(src.fragment_name, frag_name);

        // End to end: the exact answer must cite the fragment for status and
        // must NOT claim the contradictory base value anywhere.
        let envelope = crate::answer::answer_question(&l, "status of alpha", "plan/index.yaml");
        assert_eq!(envelope.confidence(), crate::answer::Confidence::Exact);
        assert!(envelope.answer().contains("in_progress"));
        let frag_rel = format!("plan/index.d/{frag_name}");
        assert!(
            envelope.citations().iter().any(|c| c.path() == frag_rel
                && c.authority().get("status").map(String::as_str) == Some("in_progress")),
            "status must be cited to the winning fragment; citations: {:?}",
            envelope
                .citations()
                .iter()
                .map(|c| (c.path().to_string(), c.authority().clone()))
                .collect::<Vec<_>>()
        );
        assert!(
            !envelope
                .citations()
                .iter()
                .any(|c| c.authority().get("status").map(String::as_str) == Some("ready")),
            "no citation may claim the stale base value for an overridden field"
        );
        // And the whole envelope must survive the order-523 verifier against
        // the real files on disk.
        let violations = crate::answer::verify(&envelope, &d);
        assert!(
            violations.is_empty(),
            "the provenance-cited envelope must verify: {violations:?}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn answers_over_a_folded_corpus_omit_no_rows() {
        // The zero-omitted-row property: with winning-source attribution there
        // is no longer any folded packet the answer engine cannot point at, so
        // the "row(s) omitted" NOTE must never fire for a folded corpus.
        let d = scratch("omit");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        let envelope = crate::answer::answer_question(&l, "what is ready?", "plan/index.yaml");
        assert_eq!(envelope.confidence(), crate::answer::Confidence::Exact);
        assert!(
            !envelope.answer().contains("omitted"),
            "no row may be omitted for lack of a source span: {}",
            envelope.answer()
        );
        for id in ["alpha", "beta", "gamma"] {
            assert!(
                envelope.answer().contains(id),
                "{id} must be reported in the ready answer"
            );
            assert!(
                envelope.citations().iter().any(|c| c
                    .authority()
                    .get("packet_id")
                    .map(String::as_str)
                    == Some(id)),
                "{id} must be cited"
            );
        }
        let violations = crate::answer::verify(&envelope, &d);
        assert!(violations.is_empty(), "must verify: {violations:?}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn freshness_is_derived_from_base_plus_fragments() {
        let d = scratch("fresh");
        let index = d.join("plan/index.yaml");

        // Age the base file so the fragment's mtime is strictly newer.
        let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
        std::fs::File::options()
            .write(true)
            .open(&index)
            .expect("open base")
            .set_modified(old)
            .expect("age base");

        let before = Ledger::load_with_fragments(&index).expect("loads");
        let f0 = crate::answer::answer_question(&before, "status of alpha", "plan/index.yaml")
            .freshness()
            .clone();

        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "status:\n  - packet_id: alpha\n    field: status\n    value: in_progress\n    ts: \"2026-08-01T01:00:00Z\"\n    host: h1\n",
        )
        .expect("write fragment");

        let after = Ledger::load_with_fragments(&index).expect("loads");
        let f1 = crate::answer::answer_question(&after, "status of alpha", "plan/index.yaml")
            .freshness()
            .clone();
        assert_ne!(
            f0.indexed_at(),
            f1.indexed_at(),
            "adding a fragment must change the corpus freshness"
        );
        assert!(
            f1.indexed_at() > f0.indexed_at(),
            "the folded corpus is NEWER than the base alone: {} -> {}",
            f0.indexed_at(),
            f1.indexed_at()
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    // ---- ORDER 796-4ydb: the fold carries what it could not read ----------

    #[test]
    fn a_clean_fold_reports_nothing_skipped() {
        // THE NON-VACUITY HALF, and the one that keeps this cheap: a corpus
        // that parses whole must be indistinguishable from before this field
        // existed. If this ever fails, every caller starts paying attention to
        // a condition that is not happening.
        let d = scratch("skipped-clean");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260817t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write fragment");

        let l = Ledger::load_with_fragments(&index).expect("overlay loads");
        assert!(l.fold_is_complete(), "a parseable corpus was folded whole");
        assert!(l.skipped_fragments().is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_unparseable_fragment_is_named_by_the_fold_that_skipped_it() {
        // THE DEFECT. The fold has always skipped a fragment it cannot parse —
        // correctly, so one bad file cannot make the whole plan unreadable —
        // but the skip lived only in a stderr sentence printed by whichever
        // caller re-scanned the directory. The result carried no trace, so
        // every consumer answered from a partial ledger at full confidence.
        let d = scratch("skipped-bad");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260817t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: gamma\n    order: 102\n    status: ready\n",
        )
        .expect("write good fragment");
        let bad = d.join("plan/index.d/20260817t0200z-bbbb-h1.yaml");
        std::fs::write(
            &bad,
            "status:\n  - packet_id: alpha\n    field: status\n    value: completed\n    [unclosed\n",
        )
        .expect("write bad fragment");

        let l = Ledger::load_with_fragments(&index).expect("a bad fragment must NOT fail the load");
        assert!(
            !l.fold_is_complete(),
            "the fold skipped a fragment and must say so"
        );
        assert_eq!(
            l.skipped_fragments(),
            &[bad.clone()][..],
            "exactly the unreadable file, named"
        );
        // And the GOOD fragment still folded: degrading is not refusing.
        assert!(
            l.resolve("gamma").is_some(),
            "a readable fragment beside a broken one must still fold"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_corpus_of_only_unparseable_fragments_still_reports_them() {
        // THE WORST CASE TAKES THE EARLY RETURN. When no fragment parses,
        // `load_all` yields an empty vec and the fold short-circuits before the
        // merge — the same branch an EMPTY directory takes. A skipped-set
        // computed only on the merge path would report nothing here, i.e. would
        // go silent exactly when the whole overlay is missing.
        let d = scratch("skipped-all-bad");
        let index = d.join("plan/index.yaml");
        let bad = d.join("plan/index.d/20260817t0300z-cccc-h1.yaml");
        std::fs::write(&bad, "packets: [unclosed\n").expect("write bad fragment");

        let l = Ledger::load_with_fragments(&index).expect("loads");
        assert_eq!(
            l.skipped_fragments(),
            &[bad][..],
            "an all-malformed corpus takes the empty-fragments early return, and must \
             still carry the skip"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn the_skipped_set_agrees_with_the_standalone_malformed_scan() {
        // The fold derives its skipped set by DIFFERENCE (corpus minus what
        // `load_all` yielded) rather than by calling `malformed`, so that one
        // directory listing backs both and a concurrent write cannot make the
        // two disagree about the very file being reported. That is only safe
        // while the two definitions of "unreadable" stay identical — this
        // pins them together.
        let d = scratch("skipped-agrees");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260817t0400z-dddd-h1.yaml"),
            "packets:\n  - packet_id: delta\n    order: 103\n    status: ready\n",
        )
        .expect("write good");
        std::fs::write(
            d.join("plan/index.d/20260817t0500z-eeee-h1.yaml"),
            "packets: [unclosed\n",
        )
        .expect("write bad");
        // A non-.yaml neighbour is not part of the corpus at all, by either route.
        std::fs::write(d.join("plan/index.d/README.md"), "not a fragment\n").expect("write note");

        let l = Ledger::load_with_fragments(&index).expect("loads");
        assert_eq!(l.skipped_fragments(), malformed(&index).as_slice());
        let _ = std::fs::remove_dir_all(&d);
    }
}

#[cfg(test)]
mod compaction_text_tests {
    use super::*;

    const COMMITTED: &str = "\
# operator decision ratified 2026-07-21: EXPERTS does not gate v0.4
plan_index:
  version: v1
  steps:
    - packet_id: alpha
      order: 100
      status: ready
      # a comment inside a packet must survive too
      events:
        - type: filed
          ts: \"2026-01-01T00:00:00Z\"
          agent_id: origin
          host: linux
          summary: born
";

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tilland-ctext-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("plan/index.d")).expect("mkdir");
        std::fs::write(d.join("plan/index.yaml"), COMMITTED).expect("write base");
        d
    }

    /// Every base `    - ` item survives, in order, in the candidate — the
    /// property a serde_yaml round-trip destroys by re-indenting to column 0.
    fn assert_items_preserved(base: &str, candidate: &str) {
        let base_items: Vec<&str> = base.lines().filter(|l| l.starts_with("    - ")).collect();
        let cand_items: Vec<&str> = candidate
            .lines()
            .filter(|l| l.starts_with("    - "))
            .collect();
        let mut idx = 0;
        for b in &base_items {
            let pos = cand_items[idx..]
                .iter()
                .position(|x| x == b)
                .unwrap_or_else(|| panic!("base item lost or reordered: {b:?}"));
            idx += pos + 1;
        }
    }

    /// The rendered text must parse to EXACTLY the same packets (and per-packet
    /// events) as the Value-domain fold — the strongest possible guarantee that
    /// compaction did not change state while preserving format.
    fn assert_fold_equivalent(index: &Path, base_raw: &str) {
        let base_doc: Value = serde_yaml::from_str(base_raw).expect("base parses");
        let merged = fold(&base_doc, &load_all(index));
        let candidate = compact_text(index).expect("compacts").candidate;
        let cand_doc: Value = serde_yaml::from_str(&candidate).expect("candidate parses");
        let mut cp = Vec::new();
        crate::collect_packets(&cand_doc, &mut cp);
        let mut mp = Vec::new();
        crate::collect_packets(&merged, &mut mp);
        assert_eq!(cp, mp, "the rendered text must fold to the same state");
    }

    #[test]
    fn compaction_preserves_comments_and_indentation_and_matches_the_fold() {
        let d = scratch("fold");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: beta\n    order: 581-aaaa\n    status: ready\n    depends_on: [alpha]\n    outcome: >\n      multiline\n      outcome text\n",
        )
        .expect("fragment 1");
        std::fs::write(
            d.join("plan/index.d/20260801t0200z-bbbb-h2.yaml"),
            "events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: \"2026-02-02T00:00:00Z\"\n      agent_id: h1\n      host: linux\n      summary: probe\nstatus:\n  - packet_id: beta\n    field: status\n    value: claimed\n    ts: \"2026-03-01T00:00:00Z\"\n    host: h2\n",
        )
        .expect("fragment 2");

        let c = compact_text(&index).expect("format-preserving compaction succeeds");

        for comment in COMMITTED
            .lines()
            .filter(|l| l.trim_start().starts_with('#'))
        {
            assert!(
                c.candidate.contains(comment),
                "comment must survive: {comment:?}"
            );
        }
        assert_items_preserved(COMMITTED, &c.candidate);

        // The candidate is semantically identical to the Value-domain fold, and
        // must still accept future text edits — the two shapes a round-trip used
        // to break.
        assert_fold_equivalent(&index, COMMITTED);
        let block =
            crate::edit::event_block("note", "2026-03-01T00:00:00Z", "h3", "linux", "after");
        crate::edit::push_event(&c.candidate, "alpha", &block).expect("events still append");
        crate::edit::append_event(&c.candidate, "beta", &block).expect("events still prepend");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn fragment_born_packet_bakes_non_scalar_lww_winners_into_its_new_item() {
        let d = scratch("fragment-nonscalar-lww");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: beta\n    order: 581-aaaa\n    status: ready\n    depends_on: []\n    next_action: initial\n",
        )
        .expect("packet fragment");
        std::fs::write(
            d.join("plan/index.d/20260801t0200z-bbbb-h2.yaml"),
            "status:\n  - packet_id: beta\n    field: depends_on\n    value: [alpha, gamma]\n    ts: \"2026-03-01T00:00:00Z\"\n    host: h2\n  - packet_id: beta\n    field: next_action\n    value: |\n      first line\n      second line\n    ts: \"2026-03-01T00:00:00Z\"\n    host: h2\n",
        )
        .expect("non-scalar LWW fragment");

        let c = compact_text(&index).expect("fragment packet compacts");
        assert!(
            c.candidate
                .contains("      depends_on:\n        - alpha\n        - gamma\n"),
            "the winning sequence must be rendered in the new packet: {}",
            c.candidate
        );
        assert!(
            c.candidate
                .contains("      next_action: |\n        first line\n        second line\n"),
            "the winning multi-line value must be rendered in the new packet: {}",
            c.candidate
        );
        assert_fold_equivalent(&index, COMMITTED);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn base_packet_lww_replaces_only_the_non_scalar_field_span() {
        let d = scratch("base-nonscalar-lww");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "status:\n  - packet_id: alpha\n    field: depends_on\n    value: [beta, gamma]\n    ts: \"2026-03-01T00:00:00Z\"\n    host: h1\n  - packet_id: alpha\n    field: next_action\n    value: |\n      first line\n      second line\n    ts: \"2026-03-01T00:00:00Z\"\n    host: h1\n",
        )
        .expect("non-scalar LWW fragment");

        let c = compact_text(&index).expect("base packet non-scalars compact");
        assert!(
            c.candidate
                .contains("      depends_on:\n        - beta\n        - gamma\n"),
            "the sequence must be inserted as one field span: {}",
            c.candidate
        );
        assert!(
            c.candidate
                .contains("      next_action: |\n        first line\n        second line\n"),
            "the block string must be inserted as one field span: {}",
            c.candidate
        );
        for comment in COMMITTED
            .lines()
            .filter(|l| l.trim_start().starts_with('#'))
        {
            assert!(
                c.candidate.contains(comment),
                "comment must survive: {comment:?}"
            );
        }
        assert_fold_equivalent(&index, COMMITTED);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn compaction_is_idempotent_so_a_half_finished_run_is_safe() {
        let d = scratch("idem");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: beta\n    order: 581-aaaa\n    status: ready\n",
        )
        .expect("fragment");

        let first = compact_text(&index).expect("first pass");
        std::fs::write(&index, &first.candidate).expect("write folded base");

        let second = compact_text(&index).expect("second pass");
        assert_eq!(
            second.candidate, first.candidate,
            "re-folding an already-compacted base must be a no-op"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The fold RE-SERIALIZES event mappings rather than copying their text, so
    /// it is itself a writer of timestamps — and serde_yaml, a YAML 1.2 writer,
    /// emits `ts: 2026-08-13T23:36:42Z` bare. Ruby's Psych reads YAML 1.1, where
    /// that scalar is a `Time` instance and `safe_load` refuses the whole file,
    /// so the 440 status-vocab gate could not load the base it had just folded.
    ///
    /// This is the SECOND occurrence. Order 720-24u6 taught the fragment gate to
    /// refuse hand-authored bare timestamps after 231 landed; 51 more arrived on
    /// the next fold, from a writer no fragment gate can see. Assert on the
    /// rendered TEXT — a Value-domain assertion cannot distinguish the two
    /// spellings, which is exactly why this went unnoticed.
    #[test]
    fn a_folded_event_timestamp_is_quoted_so_yaml11_readers_do_not_see_a_time() {
        let d = scratch("tsquote");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: \"2026-08-13T23:36:42Z\"\n      host: h1\n      summary: folded\n",
        )
        .expect("fragment");

        let candidate = compact_text(&index).expect("compacts").candidate;
        assert!(
            candidate.contains("ts: \"2026-08-13T23:36:42Z\""),
            "the fold must quote the timestamp it re-serializes; got:\n{candidate}"
        );
        assert!(
            !candidate
                .lines()
                .any(|l| l.trim_start().starts_with("ts: 2026-")),
            "no bare timestamp may reach the base:\n{candidate}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn compaction_refuses_when_the_final_list_item_is_not_a_packet() {
        let d = scratch("anchor");
        let index = d.join("plan/index.yaml");
        std::fs::write(
            d.join("plan/index.d/20260801t0100z-aaaa-h1.yaml"),
            "packets:\n  - packet_id: beta\n    order: 581-aaaa\n    status: ready\n",
        )
        .expect("fragment");
        // The base ends with a NON-packet list; appending packets there would
        // land them in the wrong section.
        std::fs::write(
            &index,
            "plan_index:\n  steps:\n    - packet_id: alpha\n      order: 100\n      status: ready\n  tags:\n    - alpha\n    - beta\n",
        )
        .expect("write base with trailing list");

        let err = compact_text(&index).expect_err("must refuse");
        assert!(
            err.contains("not a packet item"),
            "refusal must name the bad anchor: {err}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn compaction_on_the_real_ledger_preserves_every_comment_and_item() {
        // The packet's exit criterion, applied to the actual repo state: fold a
        // COPY of plan/index.yaml + its real fragments and diff the text. This
        // is deliberately LIVE — a compaction that quietly destroys a comment or
        // re-indents an item on the real ledger is the bug this feature exists
        // to prevent, and it must not pass CI.
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plan/index.yaml");
        let raw = std::fs::read_to_string(&repo).expect("live base loads");
        let d = scratch("live");
        let index = d.join("plan/index.yaml");
        std::fs::write(&index, &raw).expect("copy base");
        if let Ok(entries) = std::fs::read_dir(repo.parent().unwrap().join("index.d")) {
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) == Some("yaml")
                    && let Ok(content) = std::fs::read_to_string(&p)
                {
                    std::fs::write(d.join("plan/index.d").join(p.file_name().unwrap()), content)
                        .expect("copy fragment");
                }
            }
        }

        let c = compact_text(&index).expect("real ledger compacts");
        for comment in raw.lines().filter(|l| l.trim_start().starts_with('#')) {
            assert!(
                c.candidate.contains(comment),
                "real-ledger comment must survive: {comment:?}"
            );
        }
        assert_items_preserved(&raw, &c.candidate);
        assert_fold_equivalent(&index, &raw);
        let _ = std::fs::remove_dir_all(&d);
    }

    // ── 846-idhn EXIT CRITERION 3 ───────────────────────────────────────────
    //
    // "A fragment carrying each known top-level key survives fold -> compact ->
    // fold byte-equivalently, SO THE NEXT CHANNEL ADDED CANNOT REPEAT THIS."
    //
    // The defect being generalised away is 843-624y: `capabilities:` was read by
    // the folder and written by nobody, so compaction CONSUMED those fragments
    // and deleted them — destroying 100% of the channel. yolanda's only two rows
    // were lost that way. Per-channel fixes do not prevent the next channel from
    // arriving with the same hole, and 864-p2rk landed the same shape again on
    // the same day (a cache key that failed to cover one of its own inputs).
    //
    // So there are two assertions here, and the second is the one that
    // generalises: every channel round-trips, AND the set of channels under test
    // is provably the set the folder actually reads.

    /// The full observable state of a ledger: the packet document AND the
    /// capability matrix, which lives outside `fold` on purpose.
    fn full_state(index: &Path) -> (Vec<Value>, Vec<String>) {
        let base_raw = std::fs::read_to_string(index).unwrap_or_default();
        let base: Value = serde_yaml::from_str(&base_raw).unwrap_or(Value::Null);
        let frags = load_all(index);

        let merged = fold(&base, &frags);
        let mut packets = Vec::new();
        crate::collect_packets(&merged, &mut packets);

        // The base is spliced in exactly as the production callers do it
        // (main.rs capability-matrix, fragments.rs:1272). That duplication is
        // itself filed as 864-v8kr; this test must mirror production, not
        // improve on it, or it would pass against a fold no caller performs.
        let mut cap_frags = frags;
        if base.get("capabilities").is_some() {
            cap_frags.insert(
                0,
                Fragment {
                    name: "0000-base".to_string(),
                    path: index.to_path_buf(),
                    doc: base.clone(),
                    raw: base_raw,
                },
            );
        }
        let (matrix, _) = fold_capabilities(&cap_frags);
        let caps: Vec<String> = matrix.keys().map(|(h, l)| format!("{h}/{l}")).collect();

        (packets, caps)
    }

    /// Every top-level channel a fragment may carry survives compaction.
    #[test]
    fn every_known_fragment_channel_survives_a_compaction_round_trip() {
        for (channel, body) in CHANNEL_PROBES {
            let d = scratch(&format!("chan-{channel}"));
            let index = d.join("plan/index.yaml");
            std::fs::write(d.join("plan/index.d/1-probe.yaml"), body).expect("write probe");

            let before = full_state(&index);

            // Publish the compaction the way `compact` does: the candidate
            // becomes the base and the folded fragments are deleted.
            let candidate = compact_text(&index)
                .unwrap_or_else(|e| panic!("channel {channel} failed to compact: {e}"))
                .candidate;
            std::fs::write(&index, &candidate).expect("publish candidate");
            for entry in std::fs::read_dir(d.join("plan/index.d")).expect("read frag dir") {
                std::fs::remove_file(entry.expect("entry").path()).expect("delete folded fragment");
            }

            let after = full_state(&index);

            assert_eq!(
                before.0, after.0,
                "channel `{channel}`: packet state did not survive fold -> compact -> fold"
            );
            assert_eq!(
                before.1, after.1,
                "channel `{channel}`: capability rows did not survive fold -> compact -> fold"
            );
            let _ = std::fs::remove_dir_all(&d);
        }
    }

    /// THE ASSERTION THAT GENERALISES. Read this file's own source, find every
    /// top-level key the folder pulls out of a fragment, and require it to be
    /// covered above. Adding a channel to the folder without adding a probe
    /// fails here — which is the only mechanism that makes the next channel
    /// safe rather than merely making this one safe.
    #[test]
    fn the_set_of_fragment_channels_under_test_is_the_set_the_folder_reads() {
        let src = include_str!("fragments.rs");
        let mut read: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        for (pat, _) in [("frag.doc.get(\"", 0), ("d.doc.get(\"", 0)] {
            let mut rest = src;
            while let Some(i) = rest.find(pat) {
                rest = &rest[i + pat.len()..];
                if let Some(j) = rest.find('"') {
                    read.insert(rest[..j].to_string());
                }
            }
        }
        let covered: std::collections::BTreeSet<String> = CHANNEL_PROBES
            .iter()
            .map(|(c, _)| (*c).to_string())
            .collect();
        let uncovered: Vec<&String> = read.difference(&covered).collect();
        assert!(
            uncovered.is_empty(),
            "the folder reads fragment channel(s) {uncovered:?} that no round-trip probe covers.\n\
             Add a probe to CHANNEL_PROBES. This is 846-idhn exit criterion 3: a channel the\n\
             folder reads and compaction does not write is silently destroyed (843-624y)."
        );
    }

    /// One probe per channel. Kept as a const so the coverage assertion above
    /// can enumerate it.
    const CHANNEL_PROBES: &[(&str, &str)] = &[
        (
            "packets",
            "packets:\n  - packet_id: zeta\n    order: 900\n    status: ready\n",
        ),
        (
            "events",
            "events:\n  - packet_id: alpha\n    event:\n      type: note\n      \
             ts: \"2026-02-02T00:00:00Z\"\n      agent_id: probe\n      summary: channel probe\n",
        ),
        (
            "status",
            "status:\n  - packet_id: alpha\n    field: status\n    value: implemented\n    \
             ts: \"2026-02-02T00:00:00Z\"\n    host: probe\n",
        ),
        (
            "capabilities",
            "capabilities:\n  - ts: \"2026-02-02T00:00:00Z\"\n    host: linux\n    \
             locus: in-guest\n    document:\n      schema_version: 2\n      legacy_tier: cpu\n      \
             devices: []\n      engines: []\n      measurements: []\n      host:\n        \
             is_battery_present: true\n        kernel_release: 6.1.0-probe\n        \
             host_id: probe-host\n        host_id_source: node-name\n        host_kind: linux\n      \
             timestamp: \"2026-02-02T00:00:00Z\"\n",
        ),
    ];
}

#[cfg(test)]
mod capability_matrix_tests {
    use super::*;

    fn frag(name: &str, yaml: &str) -> Fragment {
        Fragment {
            name: name.to_string(),
            path: PathBuf::from(name),
            doc: serde_yaml::from_str(yaml).expect("fixture parses"),
            raw: yaml.to_string(),
        }
    }

    /// A contribution as a host actually writes it: the whole document under
    /// `document:`, identity read from inside it.
    fn row(host_id: &str, ts: &str, host: &str, tier: &str) -> String {
        row_at(host_id, ts, host, tier, "in-guest")
    }

    fn row_at(host_id: &str, ts: &str, host: &str, tier: &str, locus: &str) -> String {
        let mut s = String::new();
        s.push_str("capabilities:\n");
        s.push_str(&format!("  - ts: \"{ts}\"\n"));
        s.push_str(&format!("    host: {host}\n"));
        s.push_str(&format!("    locus: {locus}\n"));
        s.push_str("    document:\n");
        s.push_str("      schema_version: 2\n");
        s.push_str(&format!("      legacy_tier: {tier}\n"));
        s.push_str("      devices: []\n");
        s.push_str("      engines: []\n");
        s.push_str("      measurements: []\n");
        s.push_str("      host:\n");
        s.push_str("        is_battery_present: true\n");
        s.push_str("        kernel_release: 6.18.33.2-microsoft-standard-WSL2\n");
        s.push_str(&format!("        host_id: {host_id}\n"));
        s.push_str("        host_id_source: node-name\n");
        s.push_str("        host_kind: linux\n");
        s.push_str(&format!("      timestamp: \"{ts}\"\n"));
        s
    }

    /// THE PROPERTY THE MATRIX EXISTS FOR: two hosts contribute and BOTH
    /// survive. An LWW applied across hosts instead of per-host would keep one
    /// and silently drop the other.
    #[test]
    fn two_hosts_both_survive_the_fold() {
        let frags = vec![
            frag(
                "a-linux.yaml",
                &row("yoga", "2026-08-18T10:00:00Z", "linux", "cpu"),
            ),
            frag(
                "b-windows.yaml",
                &row("yolanda", "2026-08-18T10:00:00Z", "windows", "cpu"),
            ),
        ];
        let (m, _skipped) = fold_capabilities(&frags);
        assert_eq!(m.len(), 2, "one row per host_id");
        assert!(m.contains_key(&("yoga".to_string(), "in-guest".to_string())));
        assert!(m.contains_key(&("yolanda".to_string(), "in-guest".to_string())));
    }

    /// Two WSL2 guests share a kernel release exactly. They must NOT collapse.
    #[test]
    fn hosts_sharing_a_kernel_release_do_not_collapse() {
        let frags = vec![
            frag(
                "a.yaml",
                &row("yolanda", "2026-08-18T10:00:00Z", "windows", "cpu"),
            ),
            frag(
                "b.yaml",
                &row("esmeraldinha", "2026-08-18T10:00:00Z", "windows", "cpu"),
            ),
        ];
        let (m, _skipped) = fold_capabilities(&frags);
        assert_eq!(m.len(), 2);
        assert_eq!(
            m[&("yolanda".to_string(), "in-guest".to_string())].document["host"]["kernel_release"],
            m[&("esmeraldinha".to_string(), "in-guest".to_string())].document["host"]["kernel_release"],
            "the kernel collision is real"
        );
    }

    /// Within ONE host's own key, the later contribution is current. This is
    /// the only thing LWW decides here — a re-probe describes the machine as it
    /// is now, so there is no ranking to preserve.
    #[test]
    fn a_hosts_later_contribution_replaces_its_earlier_one() {
        let frags = vec![
            frag(
                "a.yaml",
                &row("yolanda", "2026-08-18T09:00:00Z", "windows", "cpu"),
            ),
            frag(
                "b.yaml",
                &row("yolanda", "2026-08-18T11:00:00Z", "windows", "gpu-rocm"),
            ),
        ];
        let (m, _skipped) = fold_capabilities(&frags);
        assert_eq!(m.len(), 1);
        assert_eq!(
            m[&("yolanda".to_string(), "in-guest".to_string())].document["legacy_tier"],
            Value::String("gpu-rocm".into())
        );
    }

    /// Order of arrival must not decide. Folding the same set reversed gives
    /// the same answer, or two hosts compute different matrices from identical
    /// inputs — which presents as corruption, not as a sorting bug.
    #[test]
    fn the_fold_is_order_independent() {
        let a = frag(
            "a.yaml",
            &row("yolanda", "2026-08-18T09:00:00Z", "windows", "cpu"),
        );
        let b = frag(
            "b.yaml",
            &row("yolanda", "2026-08-18T11:00:00Z", "windows", "gpu-rocm"),
        );
        let (forward, _) = fold_capabilities(&[a.clone(), b.clone()]);
        let (backward, _) = fold_capabilities(&[b, a]);
        assert_eq!(forward, backward);
    }

    /// Equal timestamps are broken by host deterministically, never by arrival.
    #[test]
    fn an_exact_timestamp_tie_is_broken_by_host() {
        let ts = "2026-08-18T10:00:00Z";
        let linux = frag("a.yaml", &row("shared", ts, "linux", "cpu"));
        let windows = frag("b.yaml", &row("shared", ts, "windows", "gpu-rocm"));
        let (forward, _) = fold_capabilities(&[linux.clone(), windows.clone()]);
        let (backward, _) = fold_capabilities(&[windows, linux]);
        assert_eq!(forward, backward, "the tiebreak must not depend on order");
        assert_eq!(
            forward[&("shared".to_string(), "in-guest".to_string())].host,
            "windows",
            "the higher host string wins, deterministically"
        );
    }

    /// A row that cannot name its machine is SKIPPED, never folded under a
    /// blank key — which would collect every unidentifiable contribution into
    /// one row that reads as a host whose hardware kept changing.
    #[test]
    fn a_row_without_a_host_id_is_skipped() {
        let mut yaml = String::new();
        yaml.push_str("capabilities:\n");
        yaml.push_str("  - ts: \"2026-08-18T10:00:00Z\"\n");
        yaml.push_str("    host: windows\n");
        yaml.push_str("    document:\n");
        yaml.push_str("      schema_version: 1\n");
        yaml.push_str("      legacy_tier: cpu\n");
        yaml.push_str("      host:\n");
        yaml.push_str("        is_battery_present: false\n");
        yaml.push_str("        kernel_release: 6.18.33.2-microsoft-standard-WSL2\n");
        let (m, skipped) = fold_capabilities(&[frag("v1.yaml", &yaml)]);
        assert_eq!(skipped.len(), 1, "the unkeyable row must be reported");
        assert!(m.is_empty(), "a v1 document has no key to fold on");
    }

    /// Fragments with no `capabilities:` key are untouched — the channel is
    /// additive and every existing fragment must remain valid.
    #[test]
    fn fragments_without_the_channel_are_ignored() {
        let yaml = "packets:\n  - packet_id: alpha\n    order: 999-zzzz\n    status: ready\n";
        assert!(fold_capabilities(&[frag("plain.yaml", yaml)]).0.is_empty());
    }

    /// THE REGRESSION THIS KEY EXISTS FOR, and it was found by implementing
    /// 809-7e4m on top of the channel rather than by reasoning about it.
    ///
    /// On Windows one machine is observed from TWO contexts: the WSL2 guest
    /// sees the CPU and the paravirtual GPU, Windows sees the NPU. Both
    /// describe machine `yolanda`, so both carry the same host_id. Keyed on
    /// host_id alone the second contribution silently replaced the first and
    /// the CPU and GPU vanished from the matrix — data loss dressed as an
    /// update. Keyed on (host_id, locus) both survive.
    #[test]
    fn two_contexts_observing_one_machine_do_not_overwrite_each_other() {
        let guest = frag(
            "guest.yaml",
            &row_at(
                "yolanda",
                "2026-08-18T10:00:00Z",
                "windows",
                "cpu",
                "in-guest",
            ),
        );
        let win = frag(
            "windows.yaml",
            &row_at(
                "yolanda",
                "2026-08-18T11:00:00Z",
                "windows",
                "cpu",
                "windows-host",
            ),
        );
        let (m, skipped) = fold_capabilities(&[guest, win]);

        assert!(skipped.is_empty(), "both rows are keyable");
        assert_eq!(
            m.len(),
            2,
            "one machine, two loci, two rows — the LATER row must not replace the earlier"
        );
        assert!(m.contains_key(&("yolanda".to_string(), "in-guest".to_string())));
        assert!(m.contains_key(&("yolanda".to_string(), "windows-host".to_string())));
        assert_eq!(
            m[&("yolanda".to_string(), "in-guest".to_string())].host_id,
            m[&("yolanda".to_string(), "windows-host".to_string())].host_id,
            "and a consumer can still tell they are the same machine"
        );
    }

    /// Within ONE locus, a host's later probe still wins — the locus key must
    /// not accidentally disable the LWW that keeps a row current.
    #[test]
    fn the_locus_key_does_not_disable_lww_within_a_locus() {
        let old = frag(
            "a.yaml",
            &row_at(
                "yolanda",
                "2026-08-18T09:00:00Z",
                "windows",
                "cpu",
                "in-guest",
            ),
        );
        let new = frag(
            "b.yaml",
            &row_at(
                "yolanda",
                "2026-08-18T11:00:00Z",
                "windows",
                "gpu-rocm",
                "in-guest",
            ),
        );
        let (m, _) = fold_capabilities(&[old, new]);
        assert_eq!(m.len(), 1, "same key, so one survives");
        assert_eq!(
            m[&("yolanda".to_string(), "in-guest".to_string())].document["legacy_tier"],
            Value::String("gpu-rocm".into())
        );
    }

    /// A row that cannot be keyed is REPORTED, never dropped in silence: a
    /// discarded row is indistinguishable from a host that never contributed,
    /// and "the matrix looks empty" is exactly the symptom a misfiled row
    /// produces.
    #[test]
    fn an_unlocated_row_is_reported_rather_than_dropped() {
        let mut yaml = String::new();
        yaml.push_str("capabilities:\n");
        yaml.push_str("  - ts: \"2026-08-18T10:00:00Z\"\n");
        yaml.push_str("    host: windows\n");
        yaml.push_str("    document:\n");
        yaml.push_str("      schema_version: 2\n");
        yaml.push_str("      legacy_tier: cpu\n");
        yaml.push_str("      host:\n");
        yaml.push_str("        host_id: yolanda\n");
        let (m, skipped) = fold_capabilities(&[frag("nolocus.yaml", &yaml)]);
        assert!(m.is_empty(), "an unlocated row must not be keyed");
        assert_eq!(skipped.len(), 1, "and must be reported");
        assert_eq!(skipped[0].source, "nolocus.yaml");
        assert!(
            skipped[0].reason.contains("locus"),
            "the reason must name the missing field, got: {}",
            skipped[0].reason
        );
    }
    // ---- the schedulable unit ----

    fn doc_with_devices(devices: &str) -> Value {
        let mut s = String::new();
        s.push_str("devices:\n");
        s.push_str(devices);
        s.push_str("engines:\n");
        s.push_str("  - name: ollama\n");
        s.push_str("    backend: llama-server\n");
        s.push_str("    supported_device_classes: [cpu, gpu]\n");
        serde_yaml::from_str(&s).expect("fixture parses")
    }

    /// Order 850-bif2: an engine that declares its lanes mints triples only
    /// on them; an engine without the field keeps the pre-existing
    /// every-lane semantics (every row filed before the field existed).
    #[test]
    fn engine_lanes_scope_triples_and_absent_lanes_mean_every_lane() {
        let mut s = String::new();
        s.push_str("devices:\n");
        s.push_str(
            "  - device_class: gpu\n    usable: true\n    lanes: [container, host-native]\n",
        );
        s.push_str("engines:\n");
        s.push_str("  - name: ollama\n");
        s.push_str("    backend: llama-server\n");
        s.push_str("    supported_device_classes: [cpu, gpu]\n");
        s.push_str("    lanes: [container]\n");
        let doc: Value = serde_yaml::from_str(&s).expect("fixture parses");
        assert_eq!(
            schedulable_triples(&doc),
            vec![(
                "gpu".to_string(),
                "container".to_string(),
                "ollama".to_string()
            )],
            "a container-lane engine must not mint a host-native triple"
        );

        // Same document, engine lanes ABSENT: both device lanes pair.
        let legacy = doc_with_devices(
            "  - device_class: gpu\n    usable: true\n    lanes: [container, host-native]\n",
        );
        assert_eq!(schedulable_triples(&legacy).len(), 2);
    }

    /// The schedulable unit is the TRIPLE, not the tier.
    #[test]
    fn triples_come_from_usable_devices_with_lanes() {
        let doc = doc_with_devices(
            "  - device_class: cpu\n    usable: true\n    lanes: [container, host-native]\n",
        );
        assert_eq!(
            schedulable_triples(&doc),
            vec![
                (
                    "cpu".to_string(),
                    "container".to_string(),
                    "ollama".to_string()
                ),
                (
                    "cpu".to_string(),
                    "host-native".to_string(),
                    "ollama".to_string()
                ),
            ]
        );
    }

    /// THE 806-2r4s CASE, and the reason present-unusable records are worth
    /// emitting at all: this host's GPU is REAL and REPORTED, and contributes
    /// no schedulable triple. "Present but unschedulable" stays visible in the
    /// document while correctly offering the scheduler nothing.
    #[test]
    fn a_present_unusable_device_contributes_no_triple_but_stays_visible() {
        let doc = doc_with_devices(
            "  - device_class: cpu\n    usable: true\n    lanes: [container]\n  - device_class: gpu\n    usable: false\n    unusable_reason: wsl2-no-dri-render-node\n    lanes: []\n",
        );
        let triples = schedulable_triples(&doc);
        assert_eq!(
            triples,
            vec![(
                "cpu".to_string(),
                "container".to_string(),
                "ollama".to_string()
            )]
        );
        assert!(
            !triples.iter().any(|(c, _, _)| c == "gpu"),
            "an unusable GPU must not be schedulable"
        );
        let devices = doc["devices"].as_sequence().unwrap();
        assert_eq!(
            devices.len(),
            2,
            "but it is still REPORTED, which is the point"
        );
    }

    /// A usable device with no lane is equally unschedulable. `usable: true`
    /// alone is not a lane, and reading it as one is how a scheduler routes to
    /// a device it cannot open.
    #[test]
    fn usable_without_a_lane_is_not_schedulable() {
        let doc = doc_with_devices("  - device_class: gpu\n    usable: true\n    lanes: []\n");
        assert!(schedulable_triples(&doc).is_empty());
    }

    /// An engine that does not support the class contributes no triple, so the
    /// pairing is a real capability rather than a cross product.
    #[test]
    fn an_engine_that_does_not_support_the_class_yields_no_triple() {
        let mut s = String::new();
        s.push_str("devices:\n");
        s.push_str("  - device_class: npu\n    usable: true\n    lanes: [host-native]\n");
        s.push_str("engines:\n");
        s.push_str("  - name: ollama\n");
        s.push_str("    backend: llama-server\n");
        s.push_str("    supported_device_classes: [cpu, gpu]\n");
        let doc: Value = serde_yaml::from_str(&s).expect("fixture parses");
        assert!(
            schedulable_triples(&doc).is_empty(),
            "no engine claims npu, so there is nothing to schedule on it"
        );
    }
}

#[cfg(test)]
mod measurement_comparability_tests {
    use super::*;

    fn m(locus: Option<&str>, suite: Option<&str>, decode: f64) -> Value {
        let mut s = String::new();
        s.push_str("device: cpu\nengine: ollama\n");
        s.push_str(&format!("decode_tps: {decode}\n"));
        if let Some(l) = locus {
            s.push_str(&format!("locus: {l}\n"));
        }
        if let Some(w) = suite {
            s.push_str(&format!("workload_suite: {w}\n"));
        }
        serde_yaml::from_str(&s).expect("fixture parses")
    }

    /// THE MEASUREMENT THIS RULE COMES FROM. Same suite, same machine, two
    /// loci, 5-10% apart on the embed arm — and that gap once inverted a
    /// cross-host conclusion. These must not be ranked.
    #[test]
    fn two_loci_are_refused_even_for_the_same_suite_and_machine() {
        let in_guest = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let mirrored = m(Some("host-side-via-mirror"), Some("802-2536-v1"), 87.2);
        let v = measurements_comparable(&in_guest, &mirrored);
        assert!(!v.is_comparable());
        assert_eq!(
            v,
            Comparability::RefusedDifferentLoci(
                "in-guest".to_string(),
                "host-side-via-mirror".to_string()
            )
        );
        assert!(v.reason().contains("different loci"));
    }

    /// Same locus, same suite: this is the case a ranking is FOR.
    #[test]
    fn one_locus_and_one_suite_is_comparable() {
        let a = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let b = m(Some("in-guest"), Some("802-2536-v1"), 109.1);
        assert!(measurements_comparable(&a, &b).is_comparable());
    }

    /// An absent locus is REFUSED, never defaulted. The schema keeps the field
    /// optional so pre-808-43mw writers keep recording; that compatibility must
    /// not leak upward into a comparison, because defaulting would manufacture
    /// exactly the false comparability this exists to prevent.
    #[test]
    fn an_unlocated_measurement_is_refused_not_defaulted() {
        let located = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let bare = m(None, Some("802-2536-v1"), 87.2);
        assert_eq!(
            measurements_comparable(&located, &bare),
            Comparability::RefusedUnlocated
        );
        assert_eq!(
            measurements_comparable(&bare, &located),
            Comparability::RefusedUnlocated,
            "the refusal is symmetric"
        );
        assert_eq!(
            measurements_comparable(&bare, &bare),
            Comparability::RefusedUnlocated,
            "two unlocated records are not comparable merely by both being unlocated"
        );
    }

    /// An empty-string locus is absence, not a locus named "".
    #[test]
    fn an_empty_locus_counts_as_absent() {
        let a = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let empty: Value = serde_yaml::from_str(
            "device: cpu\nengine: ollama\ndecode_tps: 87.2\nlocus: \"\"\nworkload_suite: 802-2536-v1\n",
        )
        .expect("fixture parses");
        assert_eq!(
            measurements_comparable(&a, &empty),
            Comparability::RefusedUnlocated
        );
    }

    /// Different workloads are a different question, not a faster machine.
    /// 810-jeg7 names the locus, but workload_suite landed in the same bump for
    /// the same reason, and refusing on one axis while silently ranking on the
    /// other keeps the hole open.
    #[test]
    fn different_workloads_are_refused_at_a_common_locus() {
        let a = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let b = m(Some("in-guest"), Some("some-other-suite"), 300.0);
        let v = measurements_comparable(&a, &b);
        assert!(!v.is_comparable());
        assert!(v.reason().contains("different workloads"));
    }

    /// A stated suite against an unstated one is refused: "unstated" is not a
    /// wildcard that matches whatever it is compared against.
    #[test]
    fn a_stated_suite_against_an_unstated_one_is_refused() {
        let stated = m(Some("in-guest"), Some("802-2536-v1"), 91.6);
        let unstated = m(Some("in-guest"), None, 87.2);
        assert!(!measurements_comparable(&stated, &unstated).is_comparable());
    }

    /// Two records that BOTH omit the suite stay comparable: the locus check
    /// already established they were observed the same way, and refusing here
    /// would reject every pre-808-43mw pair for a reason 810-jeg7 does not make.
    #[test]
    fn two_records_both_omitting_the_suite_remain_comparable() {
        let a = m(Some("in-guest"), None, 91.6);
        let b = m(Some("in-guest"), None, 87.2);
        assert!(measurements_comparable(&a, &b).is_comparable());
    }

    /// Refused measurements are PARTITIONED with a reason, never dropped: a
    /// measurement discarded silently is indistinguishable from one never
    /// taken.
    #[test]
    fn unlocated_measurements_are_partitioned_with_a_reason() {
        let doc: Value = serde_yaml::from_str(
            "measurements:\n  - device: cpu\n    engine: ollama\n    locus: in-guest\n  - device: gpu\n    engine: ollama\n",
        )
        .expect("fixture parses");
        let (accepted, refused) = partition_measurements(&doc);
        assert_eq!(accepted.len(), 1);
        assert_eq!(refused.len(), 1);
        assert!(
            refused[0].1.contains("locus"),
            "the reason must name the missing field, got: {}",
            refused[0].1
        );
    }

    /// A document with no measurements partitions to two empty lists rather
    /// than erroring — an unmeasured host is a normal state.
    #[test]
    fn a_document_without_measurements_partitions_empty() {
        let doc: Value = serde_yaml::from_str("devices: []\n").expect("fixture parses");
        let (accepted, refused) = partition_measurements(&doc);
        assert!(accepted.is_empty() && refused.is_empty());
    }
}

/// Quote a bare ISO-8601 scalar so Psych cannot infer a `Time` from it.
///
/// serde_yaml emits `ts: 2026-08-23T04:38:31Z` without quotes because the
/// string is unambiguous to serde. It is not unambiguous to ruby: Psych's
/// scalar scanner constructs a `Time`, and `YAML.load_file` (safe_load since
/// Psych 5) then refuses the document with `Tried to load unspecified class:
/// Time`. One such scalar makes the entire base unreadable to every ruby tool
/// in this repo, the plan archiver included.
///
/// Conservative by construction: it rewrites only a `key: value` line whose
/// value is date-shaped and not already quoted, and leaves everything else —
/// including block scalars, comments and nested keys — byte-identical.
fn quote_datelike_scalar(line: &str) -> String {
    let Some(colon) = line.find(": ") else {
        return line.to_string();
    };
    let (key, rest) = line.split_at(colon + 2);
    let value = rest.trim_end();
    if value.starts_with('"') || value.starts_with('\'') || value.is_empty() {
        return line.to_string();
    }
    // YYYY-MM-DD, optionally followed by a time. Anything else is left alone.
    let b = value.as_bytes();
    let date_shaped = b.len() >= 10
        && b[0..4].iter().all(u8::is_ascii_digit)
        && b[4] == b'-'
        && b[5..7].iter().all(u8::is_ascii_digit)
        && b[7] == b'-'
        && b[8..10].iter().all(u8::is_ascii_digit);
    if !date_shaped {
        return line.to_string();
    }
    format!("{key}\"{value}\"")
}

/// ORDER 866-pvsx. The read-time coverage report: an entry the fold cannot use
/// must be NAMED, and the two ways an `events:` entry goes unusable must be
/// told apart, because they are repaired differently.
#[cfg(test)]
mod overlay_coverage_gap_tests {
    use super::*;

    const BASE: &str = "\
plan_index:
  version: v1
  steps:
    - packet_id: an-existing-packet
      order: 001-aaaa
      status: ready
      title: a packet that already exists in the base
";

    fn scratch(tag: &str, fragment: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("tilland-ocg-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("plan/index.d")).expect("mkdir");
        std::fs::write(d.join("plan/index.yaml"), BASE).expect("write base");
        std::fs::write(d.join("plan/index.d/20260823t200000z-t.yaml"), fragment)
            .expect("write frag");
        d
    }

    fn gaps_for(tag: &str, fragment: &str) -> Vec<String> {
        let d = scratch(tag, fragment);
        overlay_coverage_gaps(&d.join("plan/index.yaml"))
            .into_iter()
            .flat_map(|(_, g)| g)
            .collect()
    }

    /// THE DEFECT THAT MOTIVATED THE ORDER, reproduced exactly: a hand-written
    /// directive key the fold has no handler for. Before this pass, every gate
    /// reported success and the write did not land.
    #[test]
    fn unrecognized_directive_key_is_named_with_the_key() {
        let gaps = gaps_for(
            "unknown-key",
            "events:\n  - packet_id: an-existing-packet\n    set_field:\n      status: ready\n",
        );
        assert_eq!(gaps.len(), 1, "expected exactly one gap, got {gaps:?}");
        assert!(
            gaps[0].contains("set_field"),
            "must name the offending key: {gaps:?}"
        );
        assert!(
            gaps[0].contains("866-pvsx"),
            "must cite its own order: {gaps:?}"
        );
        assert!(
            !gaps[0].contains("812-d45t"),
            "must NOT be reported as a misplaced definition — that sends the reader \
             looking for a lost packet: {gaps:?}"
        );
    }

    /// The sibling shape keeps its own, different diagnosis: this one really is
    /// a packet definition under the wrong key and the repair is to relocate it.
    #[test]
    fn misplaced_definition_keeps_the_812_diagnosis() {
        let gaps = gaps_for(
            "misplaced-def",
            "events:\n  - packet_id: a-brand-new-packet\n    order: 002-bbbb\n    title: t\n    kind: bug\n",
        );
        assert_eq!(gaps.len(), 1, "expected exactly one gap, got {gaps:?}");
        assert!(gaps[0].contains("812-d45t"), "{gaps:?}");
        assert!(
            gaps[0].contains("packets:"),
            "must say where to move it: {gaps:?}"
        );
        assert!(!gaps[0].contains("866-pvsx"), "{gaps:?}");
    }

    /// An entry with a packet_id and nothing else is still a dropped write, and
    /// must not fall through the key-naming branch into an empty list.
    #[test]
    fn entry_with_no_payload_at_all_is_still_reported() {
        let gaps = gaps_for("bare", "events:\n  - packet_id: an-existing-packet\n");
        assert_eq!(gaps.len(), 1, "{gaps:?}");
        assert!(gaps[0].contains("no payload key at all"), "{gaps:?}");
    }

    /// THE NEGATIVE CONTROL. A well-formed event reports nothing — without this
    /// the pass could be firing on everything and the tests above would still
    /// pass, which is the failure mode a guard this noisy would be switched off
    /// for within a day.
    #[test]
    fn a_well_formed_event_reports_nothing() {
        let gaps = gaps_for(
            "clean",
            "events:\n  - packet_id: an-existing-packet\n    event:\n      type: progress\n      \
             ts: \"2026-08-23T20:00:00Z\"\n      agent_id: t\n      host: linux\n      summary: s\n",
        );
        assert!(
            gaps.is_empty(),
            "clean overlay must be silent, got {gaps:?}"
        );
    }

    /// An unreadable base yields no gaps rather than a panic — `check` has its
    /// own louder answer for that, and this pass must never change how an
    /// unreadable ledger fails.
    #[test]
    fn unparseable_base_yields_no_gaps_instead_of_panicking() {
        let d = scratch("badbase", "events:\n  - packet_id: an-existing-packet\n");
        std::fs::write(d.join("plan/index.yaml"), "\tnot: [valid\n").expect("write bad base");
        assert!(overlay_coverage_gaps(&d.join("plan/index.yaml")).is_empty());
    }
}
