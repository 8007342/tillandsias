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

/// Apply every fragment to a base document, returning the merged document.
///
/// PURE: same inputs always yield the same output, which is what lets any host
/// compact and get a result every other host agrees with.
pub fn fold(base: &Value, fragments: &[Fragment]) -> Value {
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
    // the winner does not depend on application order.
    let mut lww: std::collections::BTreeMap<String, (String, String, Value)> =
        std::collections::BTreeMap::new();

    let mut new_packets: Vec<Value> = Vec::new();
    let mut new_events: Vec<(String, Value)> = Vec::new();

    for frag in fragments {
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

        // LWW-Register: whole-field updates, highest (ts, host) wins.
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
                    Some((prev_ts, prev_host, _)) => {
                        (ts.as_str(), host.as_str()) > (prev_ts.as_str(), prev_host.as_str())
                    }
                };
                if better {
                    lww.insert(key, (ts, host, value.clone()));
                }
            }
        }
    }

    append_packets(&mut merged, new_packets);
    apply_to_packets(&mut merged, &new_events, &lww);
    merged
}

/// Walk the document applying event appends and LWW field wins in place.
fn apply_to_packets(
    doc: &mut Value,
    events: &[(String, Value)],
    lww: &std::collections::BTreeMap<String, (String, String, Value)>,
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

                for (key, (_, _, value)) in lww {
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
}

/// Fold every fragment into the base and report what was consumed.
///
/// Does NOT touch the filesystem — the caller validates the candidate and writes
/// it. A compaction that emits a malformed base is worse than no compaction, so
/// the parse/integrity gate belongs between this and the write.
pub fn compact(base: &Value, index: &Path) -> Compaction {
    let fragments = load_all(index);
    let consumed = fragments.iter().map(|f| f.path.clone()).collect();
    Compaction {
        merged: fold(base, &fragments),
        consumed,
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

    let consumed = fragments.iter().map(|f| f.path.clone()).collect();
    Ok(CompactionText {
        candidate,
        consumed,
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

/// A single-line YAML rendering of `v`, or `None` when it cannot be one line.
fn scalar_text(v: &Value) -> Option<String> {
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
            s.lines().map(|l| format!("{pad}{l}\n")).collect()
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
        if fragments.is_empty() {
            return Ok(ledger);
        }

        let base_doc: Value = {
            let raw = std::fs::read_to_string(path)
                .map_err(|e| format!("read {}: {e}", path.display()))?;
            serde_yaml::from_str(&raw).map_err(|e| format!("parse: {e}"))?
        };
        let merged = fold(&base_doc, &fragments);

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

        // CITABILITY IS DELIBERATELY NOT EXTENDED TO FRAGMENT CONTENT.
        //
        // A packet that exists only in a fragment has no span in plan/index.yaml,
        // so `span_of` returns None and the answer engine declines to cite it
        // rather than inventing a line range. That is the correct trade: the
        // packet is fully queryable (status / ready / check / blocked-by), and it
        // becomes citable the moment compaction folds it into the base and it
        // acquires a real span.
        //
        // The alternative — citing the fragment file — is a genuine improvement
        // and needs per-packet source attribution, which `Ledger` does not carry
        // (`source_path` is one path for the whole ledger). Tracked by packet
        // format-preserving-ledger-compaction. Until then, refusing to cite is
        // honest; a citation that does not resolve is worse than no citation, and
        // the verifier would reject it anyway.
        Ok(ledger)
    }
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
        // A SPAN is deliberately absent: the packet is not in plan/index.yaml, so
        // any line range would be fiction. It becomes citable once compaction
        // folds it into the base and it acquires a real span.
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
}
