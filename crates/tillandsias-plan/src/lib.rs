//! Order 398 — deterministic query/validation engine for the plan ledger.
//!
//! Design constraints (The Tlatoāni, 2026-07-17, recorded in the packet):
//!
//! * **Open-world**: the corpus grew organically; packets are kept as raw
//!   YAML mappings with typed *accessors*, never a closed struct — fields
//!   this engine does not know survive untouched and never fail a load.
//! * **Schema-as-data**: validations load from `plan/schema.yaml` in the
//!   same checkout — changing rules is a commit, never a recompile.
//! * **Invariant core**: id uniqueness and referential soundness
//!   (`depends_on` / `release_target` / `split_into` resolve) hold across
//!   schema versions; they live in code, not the schema file, and cannot
//!   be relaxed by editing data.
//!
//! Slice 1 is read-only (the PLAN EXPERT's retrieval backend + the agent
//! CLI's query/check surface). Format-preserving edits are slice 2.
//!
//! @trace spec:spec-traceability

use serde_yaml::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

pub mod answer;
/// ORDER 394d — the committed ground-truth query set and its grader.
pub mod groundtruth;
pub mod methodology;
/// ORDER 547 — network-free RAG index over the whole-spec corpus (chunking,
/// cosine retrieval, verifiable envelope construction). Embedding and synthesis
/// happen outside the crate; see `spec.rs`.
pub mod spec;

pub struct Ledger {
    /// Raw packet mappings in file order (open-world: everything survives).
    pub packets: Vec<Value>,
    /// packet_id -> index into `packets`.
    by_id: BTreeMap<String, usize>,
    /// order number -> packet_id (orders can be "provisional"; only
    /// numeric orders index here).
    by_order: BTreeMap<u64, String>,
    /// Normalized order TOKEN -> packet_id. Order 516: child orders are
    /// written `394a` / `392b`, which YAML parses as STRINGS, so
    /// `Value::as_u64` never sees them and `by_order` cannot hold them —
    /// yet `burndown` prints exactly those tokens. This index carries every
    /// order in its textual form (numeric ones included, so a quoted
    /// `"394"` resolves too) and is consulted only AFTER the integer path,
    /// leaving numeric lookup byte-identical.
    ///
    /// UNIQUE TOKENS ONLY. 26 live packets carry the SENTINEL
    /// `order: provisional` (and a handful of integer orders are
    /// double-booked); mapping an ambiguous token to whichever packet
    /// happened to be parsed last would answer a query with an arbitrary
    /// packet, which is a worse lie than the honest miss this packet was
    /// filed to fix. Ambiguous tokens are dropped and stay unresolvable.
    by_order_token: BTreeMap<String, String>,
    /// packet_ids that have been ARCHIVED (completed and moved to
    /// plan/archive/). A depends_on pointing at an archived packet is a
    /// SATISFIED dependency, not a dangling reference — referential
    /// soundness resolves against active ∪ archived.
    archived_ids: BTreeSet<String>,
    /// packet_id -> (line_start, line_end), 1-indexed and INCLUSIVE, over the
    /// raw text this ledger was parsed from. Order 394b: a citation without a
    /// line range is unverifiable, and an unverifiable citation is decoration.
    /// serde_yaml discards positions, so the span is recovered from the text
    /// by the same list-item scan `edit::append_event` uses — no new
    /// dependency, and it stays exact because we own the file's format.
    spans: BTreeMap<String, (usize, usize)>,
    /// Where the raw text came from, when it came from a file. Citations must
    /// name a path a reader can open; `parse` (used for candidate validation)
    /// has no file, so this is `None` there and citation emission refuses.
    source_path: Option<PathBuf>,
}

fn str_field<'a>(packet: &'a Value, key: &str) -> Option<&'a str> {
    packet.get(key).and_then(Value::as_str)
}

fn str_list(packet: &Value, key: &str) -> Vec<String> {
    packet
        .get(key)
        .and_then(Value::as_sequence)
        .map(|s| {
            s.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

impl Ledger {
    /// Load the ledger from a plan index file. Walks the whole YAML tree
    /// collecting every mapping that carries a `packet_id` — resilient to
    /// the organically-grown nesting around the packet list.
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw =
            std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let archived_ids = Self::collect_archived_ids(path);
        let mut ledger =
            Self::parse(&raw, archived_ids).map_err(|e| format!("{}: {e}", path.display()))?;
        ledger.source_path = Some(path.to_path_buf());
        Ok(ledger)
    }

    /// Archive awareness: sibling plan/archive/*.yaml holds completed
    /// packets. Their ids resolve dependencies (done work) but never enter
    /// the active packet list. Best-effort — a missing archive dir just
    /// means no archived ids.
    fn collect_archived_ids(path: &Path) -> BTreeSet<String> {
        let mut archived_ids = BTreeSet::new();
        if let Some(archive_dir) = path.parent().map(|d| d.join("archive"))
            && let Ok(entries) = std::fs::read_dir(&archive_dir)
        {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().and_then(|e| e.to_str()) == Some("yaml")
                    && let Ok(raw) = std::fs::read_to_string(&p)
                    && let Ok(doc) = serde_yaml::from_str::<Value>(&raw)
                {
                    let mut archived = Vec::new();
                    collect_packets(&doc, &mut archived);
                    for a in &archived {
                        if let Some(id) = str_field(a, "packet_id") {
                            archived_ids.insert(id.to_string());
                        }
                    }
                }
            }
        }
        archived_ids
    }

    /// Parse a raw ledger string with a known archived-id set — NO file IO.
    /// Used by `load` and, crucially, to validate a CANDIDATE edit before it
    /// is flushed: `serde_yaml::from_str` REJECTS duplicate mapping keys, so
    /// a candidate that would create the order-263 broken-ledger class (a
    /// second `events:`/`title:`/`order:` on one packet) fails HERE, before
    /// any bytes hit disk.
    pub fn parse(raw: &str, archived_ids: BTreeSet<String>) -> Result<Self, String> {
        let doc: Value = serde_yaml::from_str(raw).map_err(|e| format!("parse: {e}"))?;
        let mut packets = Vec::new();
        collect_packets(&doc, &mut packets);
        let mut by_id = BTreeMap::new();
        let mut by_order = BTreeMap::new();
        // token -> (packet_id, how many packets claim it). Count first, then
        // keep only the unambiguous ones (see `by_order_token`).
        let mut token_claims: BTreeMap<String, (String, usize)> = BTreeMap::new();
        for (idx, p) in packets.iter().enumerate() {
            if let Some(id) = str_field(p, "packet_id") {
                by_id.insert(id.to_string(), idx);
                if let Some(order) = p.get("order").and_then(Value::as_u64) {
                    by_order.insert(order, id.to_string());
                }
                if let Some(token) = p.get("order").and_then(order_token) {
                    token_claims
                        .entry(token)
                        .and_modify(|(_, n)| *n += 1)
                        .or_insert((id.to_string(), 1));
                }
            }
        }
        let by_order_token: BTreeMap<String, String> = token_claims
            .into_iter()
            .filter(|(_, (_, n))| *n == 1)
            .map(|(token, (id, _))| (token, id))
            .collect();
        Ok(Self {
            packets,
            by_id,
            by_order,
            by_order_token,
            archived_ids,
            spans: packet_spans(raw),
            source_path: None,
        })
    }

    /// The 1-indexed, inclusive `(line_start, line_end)` of a packet's block in
    /// the source text. The load-bearing property, pinned by
    /// [`tests::every_live_packet_has_a_span_that_contains_its_own_id`]: the
    /// span CONTAINS the `packet_id: <id>` line, so a citation built from it
    /// can never point at a region that does not say what the answer claims.
    pub fn span_of(&self, packet_id: &str) -> Option<(usize, usize)> {
        self.spans.get(packet_id).copied()
    }

    /// The file this ledger was loaded from, if any. `None` for a ledger
    /// parsed from a string (candidate validation) — such a ledger cannot
    /// produce citations, because there is no path a reader could open.
    pub fn source_path(&self) -> Option<&Path> {
        self.source_path.as_deref()
    }

    /// The active ∪ archived id space, so a candidate edit can be validated
    /// for referential soundness against the same universe `load` used.
    pub fn archived_ids(&self) -> BTreeSet<String> {
        self.archived_ids.clone()
    }

    /// A reference resolves if it names an active OR an archived packet.
    fn reference_resolves(&self, reference: &str) -> bool {
        self.by_id.contains_key(reference) || self.archived_ids.contains(reference)
    }

    /// Resolve a user-facing reference: a packet_id, a bare order number, or
    /// an alphanumeric child-order token (`394a`, `392b`).
    ///
    /// ORDER 516. Child orders are the common shape now (17 on the live
    /// ledger: 246a/b, 247a/b, 392a/b, 394a-e, 427a-c, 429a-c) and
    /// they are exactly what `burndown` prints, so an agent copying an order
    /// out of a burndown MUST get its packet back. Before this, `status 394a`
    /// answered "no packet matches" — a FALSE NEGATIVE that reads as "no such
    /// work", the worst possible failure for a retrieval surface.
    ///
    /// The three lookups are ordered id -> integer order -> order token, and
    /// the integer path is untouched, so every numeric reference resolves to
    /// byte-identically the same packet as before; the token path can only
    /// turn a former `None` into a hit.
    pub fn resolve(&self, reference: &str) -> Option<&Value> {
        if let Some(&idx) = self.by_id.get(reference) {
            return Some(&self.packets[idx]);
        }
        if let Some(idx) = reference
            .parse::<u64>()
            .ok()
            .and_then(|n| self.by_order.get(&n))
            .and_then(|id| self.by_id.get(id))
        {
            return Some(&self.packets[*idx]);
        }
        self.by_order_token
            .get(&normalize_order_token(reference))
            .and_then(|id| self.by_id.get(id))
            .map(|&idx| &self.packets[idx])
    }

    pub fn id_of(&self, packet: &Value) -> String {
        str_field(packet, "packet_id")
            .unwrap_or("<missing-id>")
            .to_string()
    }

    /// Packets whose `depends_on` names the given packet — i.e. what X
    /// blocks. The flagship expert query ("what is blocked by X").
    pub fn blocked_by(&self, reference: &str) -> Vec<&Value> {
        let Some(target) = self.resolve(reference).map(|p| self.id_of(p)) else {
            return Vec::new();
        };
        self.packets
            .iter()
            .filter(|p| str_list(p, "depends_on").contains(&target))
            .collect()
    }

    /// Transitive closure of blocked_by (everything downstream of X).
    pub fn blocked_by_closure(&self, reference: &str) -> Vec<&Value> {
        let mut seen = BTreeSet::new();
        let mut frontier: Vec<String> = self
            .resolve(reference)
            .map(|p| vec![self.id_of(p)])
            .unwrap_or_default();
        let mut result = Vec::new();
        while let Some(current) = frontier.pop() {
            for p in self.blocked_by(&current) {
                let id = self.id_of(p);
                if seen.insert(id.clone()) {
                    frontier.push(id);
                    result.push(p);
                }
            }
        }
        result
    }

    /// Ready packets, optionally filtered by pickup_role (role or "any").
    pub fn ready(&self, role: Option<&str>) -> Vec<&Value> {
        self.packets
            .iter()
            .filter(|p| str_field(p, "status") == Some("ready"))
            .filter(|p| match role {
                None => true,
                Some(r) => {
                    matches!(str_field(p, "pickup_role"), Some(pr) if pr == r || pr == "any")
                }
            })
            .collect()
    }

    /// Children of a milestone (packets whose release_target names it).
    pub fn milestone_children(&self, reference: &str) -> Vec<&Value> {
        let Some(target) = self.resolve(reference).map(|p| self.id_of(p)) else {
            return Vec::new();
        };
        self.packets
            .iter()
            .filter(|p| str_field(p, "release_target") == Some(target.as_str()))
            .collect()
    }

    /// INVARIANT CORE (not schema-relaxable): id uniqueness + reference
    /// soundness. First live run on the real ledger (2026-07-17) surfaced
    /// two ORGANIC debt classes that must not be conflated with active
    /// breakage:
    ///
    /// * prose-form references ("227 — slice 3: …" inside split_into) —
    ///   human annotations, not ids; classified by the id GRAMMAR (same
    ///   grammar as claim-ledger-node leases: `[a-z0-9._/-]+`) and
    ///   reported as WARNINGS (historical annotation debt),
    /// * dangling id-shaped references — a hard VIOLATION when the
    ///   referring packet is still live (ready/pending/claimed/blocked),
    ///   a warning on retired packets (done/failed history is documented
    ///   debt, filed for cleanup, never auto-churned).
    pub fn check_integrity(&self, reference_fields: &[String]) -> IntegrityReport {
        let mut report = IntegrityReport::default();
        let mut seen = BTreeSet::new();
        for p in &self.packets {
            let Some(id) = str_field(p, "packet_id") else {
                report
                    .violations
                    .push("packet without packet_id".to_string());
                continue;
            };
            if !seen.insert(id.to_string()) {
                report.violations.push(format!("duplicate packet_id: {id}"));
            }
        }
        for p in &self.packets {
            let id = self.id_of(p);
            let live = matches!(
                str_field(p, "status"),
                Some("ready" | "pending" | "claimed" | "blocked")
            );
            for field in reference_fields {
                let refs = match p.get(field.as_str()) {
                    Some(Value::String(s)) => vec![s.clone()],
                    Some(Value::Sequence(_)) => str_list(p, field),
                    _ => Vec::new(),
                };
                for r in refs {
                    if self.reference_resolves(&r) {
                        continue;
                    }
                    if !is_id_shaped(&r) {
                        report
                            .warnings
                            .push(format!("{id}: {field} carries a prose annotation '{r}'"));
                    } else if live {
                        report
                            .violations
                            .push(format!("{id}: {field} -> unresolved reference '{r}'"));
                    } else {
                        report.warnings.push(format!(
                            "{id} (retired): {field} -> unresolved reference '{r}'"
                        ));
                    }
                }
            }
        }
        report
    }

    /// Schema-as-data validation: field rules come from the checkout, not
    /// the binary. Unknown packet fields are NEVER violations (open-world).
    pub fn validate_against_schema(&self, schema: &Schema) -> Vec<String> {
        let mut violations = Vec::new();
        for p in &self.packets {
            let id = self.id_of(p);
            for req in &schema.required_fields {
                if p.get(req.as_str()).is_none() {
                    violations.push(format!("{id}: missing required field '{req}'"));
                }
            }
            if let Some(status) = str_field(p, "status")
                && !schema.statuses.is_empty()
                && !schema.statuses.iter().any(|s| s == status)
            {
                violations.push(format!("{id}: status '{status}' not in schema statuses"));
            }
        }
        violations
    }
}

/// Leading-space count of a line (the ledger is space-indented YAML; a tab
/// would be a YAML error long before it reached here).
fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

/// Recover each packet's `(line_start, line_end)` block from the raw ledger
/// text, 1-indexed and inclusive. ORDER 394b.
///
/// Anchoring on the `packet_id:` line alone would be WRONG: 19 of the 427 live
/// packets write `- order: N` as the list-item head and `packet_id:` as the
/// second key (e.g. plan/index.yaml:19101-19102), so the block starts one or
/// more lines ABOVE the id. The scan therefore walks back from the id line to
/// its enclosing list item, and forward to the next sibling item — the same
/// structural boundary `edit::append_event` uses to find a packet's extent.
///
/// FIRST occurrence wins. Duplicate packet_ids are already a hard integrity
/// violation (`check_integrity`); silently citing the second copy would answer
/// with a block the id lookup never selected.
fn packet_spans(raw: &str) -> BTreeMap<String, (usize, usize)> {
    let lines: Vec<&str> = raw.lines().collect();
    let mut spans: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim_start();
        let Some(rest) = trimmed
            .strip_prefix("- packet_id:")
            .or_else(|| trimmed.strip_prefix("packet_id:"))
        else {
            continue;
        };
        let id = rest.trim().trim_matches(['"', '\'']).to_string();
        if id.is_empty() {
            continue;
        }
        // The enclosing list item: this line if it IS the item head, else the
        // nearest preceding `- ` line at a strictly smaller indent.
        let (head, head_indent) = if trimmed.starts_with("- ") {
            (i, indent_of(line))
        } else {
            let my_indent = indent_of(line);
            let found = (0..i).rev().find(|&j| {
                lines[j].trim_start().starts_with("- ") && indent_of(lines[j]) < my_indent
            });
            match found {
                Some(j) => (j, indent_of(lines[j])),
                // No enclosing list item (a mapping-valued packet); the id
                // line is the best honest anchor.
                None => (i, my_indent),
            }
        };
        // The item ends at the next sibling item, or at the first non-blank
        // line that dedents out of the list.
        let mut end = lines.len();
        for (j, l) in lines.iter().enumerate().skip(head + 1) {
            if l.trim().is_empty() {
                continue;
            }
            let ind = indent_of(l);
            if ind < head_indent || (ind == head_indent && l.trim_start().starts_with("- ")) {
                end = j;
                break;
            }
        }
        // Drop trailing blank lines so the cited span is exactly the packet.
        while end > head + 1 && lines[end - 1].trim().is_empty() {
            end -= 1;
        }
        spans.entry(id).or_insert((head + 1, end));
    }
    spans
}

/// The textual form of an `order:` value, normalized for lookup. YAML types
/// `394` as a number and `394a` as a string; agents copy either token
/// verbatim out of `burndown`/`ready` output, so both must index the same
/// way. Anything else (null, a sequence, a mapping) carries no token.
fn order_token(value: &Value) -> Option<String> {
    match value {
        Value::Number(n) => Some(normalize_order_token(&n.to_string())),
        Value::String(s) => Some(normalize_order_token(s)),
        _ => None,
    }
}

/// Order tokens are matched case- and whitespace-insensitively so `394A`
/// and a token pasted with stray padding still resolve. Normalization is
/// applied identically when indexing and when looking up.
fn normalize_order_token(reference: &str) -> String {
    reference.trim().to_ascii_lowercase()
}

/// The id grammar shared with claim-ledger-node leases:
/// `^[a-z0-9._/-]+$`. Anything outside it (spaces, em-dashes, colons) is a
/// human prose annotation, not a reference.
fn is_id_shaped(reference: &str) -> bool {
    !reference.is_empty()
        && reference.chars().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '/' | '-')
        })
}

/// Outcome of the invariant-core check: violations gate (exit 1),
/// warnings document organic debt without blocking.
#[derive(Default)]
pub struct IntegrityReport {
    pub violations: Vec<String>,
    pub warnings: Vec<String>,
}

fn collect_packets(value: &Value, out: &mut Vec<Value>) {
    match value {
        Value::Mapping(m) => {
            if m.contains_key(Value::String("packet_id".into())) {
                out.push(value.clone());
            } else {
                for (_, v) in m {
                    collect_packets(v, out);
                }
            }
        }
        Value::Sequence(s) => {
            for v in s {
                collect_packets(v, out);
            }
        }
        _ => {}
    }
}

/// Schema loaded from `plan/schema.yaml` — DATA, versioned with the tree.
pub struct Schema {
    pub required_fields: Vec<String>,
    pub statuses: Vec<String>,
    pub reference_fields: Vec<String>,
}

impl Schema {
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw =
            std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        let doc: Value =
            serde_yaml::from_str(&raw).map_err(|e| format!("parse {}: {e}", path.display()))?;
        let list = |key: &str| -> Vec<String> {
            doc.get(key)
                .and_then(Value::as_sequence)
                .map(|s| {
                    s.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default()
        };
        Ok(Self {
            required_fields: list("required_fields"),
            statuses: list("statuses"),
            reference_fields: list("reference_fields"),
        })
    }

    /// Fallback when the checkout carries no schema file yet: only the
    /// invariant-core reference fields, no field rules.
    pub fn minimal() -> Self {
        Self {
            required_fields: Vec::new(),
            statuses: Vec::new(),
            reference_fields: vec![
                "depends_on".into(),
                "release_target".into(),
                "split_into".into(),
            ],
        }
    }
}

/// Slice 2: format-preserving, VALIDATED ledger edits. serde_yaml round-trip
/// is lossy (drops comments + layout) and we OWN the format, so edits are
/// SURGICAL text insertions — everything outside the touched lines stays
/// byte-identical — gated by a re-parse + integrity check so a broken ledger
/// can never reach disk. This retires the order-263 broken-ledger class (the
/// duplicate-key / glued-packet corruption that keeps biting hand edits) BY
/// CONSTRUCTION for every edit routed through the tool.
pub mod edit {
    use super::Ledger;
    use std::collections::BTreeSet;

    /// Insert `event_block` as the FIRST entry under the target packet's
    /// `events:` list, preserving all surrounding formatting. `event_block`
    /// is the event's already-8-space-indented lines, newline-terminated
    /// (see [`event_block`]). Creates the `events:` block if the packet has
    /// none. Does NOT validate — the caller flushes only after
    /// [`validate_candidate`] returns no violations.
    pub fn append_event(raw: &str, target_id: &str, event_block: &str) -> Result<String, String> {
        let mut lines: Vec<String> = raw.lines().map(String::from).collect();

        // Locate packets by LIST-ITEM BOUNDARY, not by assuming `packet_id` is
        // the item's first key.
        //
        // Both of the original locators keyed off the literal "- packet_id:",
        // which is only how an item renders when `packet_id` happens to be its
        // FIRST key. 19 of the ledger's 479 packets are written `- order: N`
        // with `packet_id` on the following line, and for those:
        //
        //   1. the START search failed, so `append-event` reported
        //      "packet_id '<id>' not found" for a packet that plainly exists and
        //      that `status <id>` resolves fine — a misleading message hiding a
        //      read/write asymmetry, and one that silently made ~4% of the ledger
        //      unable to receive evidence at all;
        //
        //   2. worse, the END search skipped those items as span boundaries. A
        //      packet_id-first packet followed by an order-first one therefore
        //      got a span running PAST its own end, so an event could be inserted
        //      into the NEXT packet's `events:` block — silent cross-packet
        //      corruption, in the one code path whose entire purpose is to make
        //      hand-edit corruption impossible.
        //
        // Item boundaries are unambiguous at this indentation, so use them.
        let is_item = |l: &str| l.starts_with("    - ");
        let item_starts: Vec<usize> = (0..lines.len()).filter(|&i| is_item(&lines[i])).collect();

        let want_key = format!("packet_id: {target_id}");
        let start = *item_starts
            .iter()
            .find(|&&s| {
                let e = item_starts
                    .iter()
                    .copied()
                    .find(|&x| x > s)
                    .unwrap_or(lines.len());
                // A key line reads "packet_id: x" normally, but "- packet_id: x"
                // when it is the item's FIRST key. Strip the list marker so both
                // shapes compare equal — matching only one of them is precisely
                // how this function came to serve 460 packets and silently refuse
                // the other 19.
                (s..e).any(|i| {
                    let t = lines[i].trim();
                    t == want_key || t.strip_prefix("- ") == Some(want_key.as_str())
                })
            })
            .ok_or_else(|| format!("packet_id '{target_id}' not found"))?;
        // The packet span ends at the next list item of ANY shape, or EOF.
        let end = item_starts
            .iter()
            .copied()
            .find(|&x| x > start)
            .unwrap_or(lines.len());
        let block: Vec<String> = event_block.lines().map(String::from).collect();
        if block.is_empty() {
            return Err("empty event block".to_string());
        }
        match (start..end).find(|&i| lines[i] == "      events:") {
            Some(ei) => {
                for (k, bl) in block.iter().enumerate() {
                    lines.insert(ei + 1 + k, bl.clone());
                }
            }
            None => {
                let mut ins = vec!["      events:".to_string()];
                ins.extend(block);
                for (k, bl) in ins.iter().enumerate() {
                    lines.insert(end + k, bl.clone());
                }
            }
        }
        Ok(lines.join("\n") + "\n")
    }

    /// The FLUSH GUARD. Returns the violations that would make `candidate` a
    /// broken ledger (empty = safe to write). Catches malformed YAML +
    /// DUPLICATE KEYS (via `Ledger::parse`, which serde_yaml rejects) and
    /// duplicate packet_ids + dangling LIVE references (via integrity).
    /// Nothing is written here.
    pub fn validate_candidate(
        candidate: &str,
        archived_ids: BTreeSet<String>,
        reference_fields: &[String],
    ) -> Vec<String> {
        match Ledger::parse(candidate, archived_ids) {
            Err(e) => vec![e],
            Ok(l) => l.check_integrity(reference_fields).violations,
        }
    }

    /// Build a well-formed 8-space-indented event list entry.
    pub fn event_block(etype: &str, ts: &str, agent_id: &str, host: &str, summary: &str) -> String {
        format!(
            "        - type: {etype}\n          ts: \"{ts}\"\n          agent_id: \"{agent_id}\"\n          host: {host}\n          summary: >\n            {summary}\n"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live_ledger() -> Ledger {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plan/index.yaml");
        Ledger::load(&path).expect("live plan/index.yaml loads")
    }

    /// A small ledger the test owns outright. Resolution, dependency and
    /// open-world behaviour are asserted HERE rather than against the live
    /// plan, so completing or archiving real work can never turn this suite
    /// red (order 438).
    fn synthetic_ledger() -> Ledger {
        let raw = r#"
plan_index:
  steps:
    - order: 900
      packet_id: alpha-packet
      title: "Alpha"
      status: ready
      depends_on: []
      provisional_id: prov-alpha
    - order: 901
      packet_id: beta-packet
      title: "Beta"
      status: ready
      depends_on: [alpha-packet]
    - order: 902
      packet_id: gamma-packet
      title: "Gamma"
      status: ready
      depends_on: [alpha-packet]
    - order: 903a
      packet_id: delta-packet/slice-a
      parent: gamma-packet
      title: "Delta slice a"
      status: ready
      depends_on: [gamma-packet]
    - order: 903b
      packet_id: delta-packet/slice-b
      parent: gamma-packet
      title: "Delta slice b"
      status: ready
      depends_on: [delta-packet/slice-a]
"#;
        Ledger::parse(raw, BTreeSet::new()).expect("synthetic ledger parses")
    }

    #[test]
    fn resolution_works_by_order_number_and_packet_id() {
        // Order 438: this used to resolve "392" and "inference-startup-cleanup"
        // against the LIVE ledger, so archiving that real packet — i.e.
        // FINISHING the work — would have failed the test. Assert the
        // mechanism on a ledger the test owns.
        let ledger = synthetic_ledger();
        assert!(
            ledger.resolve("900").is_some(),
            "order-number resolution works"
        );
        assert!(
            ledger.resolve("alpha-packet").is_some(),
            "packet_id resolution works"
        );
        assert!(
            ledger.resolve("no-such-packet").is_none(),
            "unknown ids must not resolve"
        );
    }

    /// ORDER 516 REGRESSION PIN. Before the fix `by_order` was keyed by
    /// `u64`, so a child order (`903a`) — which YAML parses as a STRING —
    /// never entered any index and `resolve` returned None: `status 394a`
    /// on the real ledger answered "no packet matches" for a packet that
    /// plainly exists. Every assertion below fails on the pre-fix resolver.
    #[test]
    fn resolution_works_by_alphanumeric_child_order() {
        let ledger = synthetic_ledger();
        let resolved = ledger
            .resolve("903a")
            .expect("an alphanumeric child order must resolve");
        assert_eq!(ledger.id_of(resolved), "delta-packet/slice-a");
        let resolved_b = ledger
            .resolve("903b")
            .expect("sibling child orders must resolve independently");
        assert_eq!(ledger.id_of(resolved_b), "delta-packet/slice-b");
        // A token copied out of burndown/ready output resolves regardless of
        // case or stray padding.
        assert_eq!(
            ledger.resolve("903A").map(|p| ledger.id_of(p)).as_deref(),
            Some("delta-packet/slice-a"),
            "child-order lookup is case-insensitive"
        );
        assert_eq!(
            ledger.resolve(" 903a ").map(|p| ledger.id_of(p)).as_deref(),
            Some("delta-packet/slice-a"),
            "child-order lookup tolerates padding"
        );
        // The graph queries are the ones agents actually run, and they all
        // funnel through resolve.
        let blocked: Vec<String> = ledger
            .blocked_by("903a")
            .iter()
            .map(|p| ledger.id_of(p))
            .collect();
        assert_eq!(
            blocked,
            vec!["delta-packet/slice-b".to_string()],
            "blocked-by resolves a child order"
        );
        let closure: Vec<String> = ledger
            .blocked_by_closure("902")
            .iter()
            .map(|p| ledger.id_of(p))
            .collect();
        assert!(
            closure.contains(&"delta-packet/slice-a".to_string())
                && closure.contains(&"delta-packet/slice-b".to_string()),
            "closure reaches child-order packets, got {closure:?}"
        );
        // Non-existent tokens must still MISS — the fix must not make
        // resolution fuzzy (e.g. by stripping the suffix and matching the
        // numeric prefix).
        assert!(
            ledger.resolve("903").is_none(),
            "the numeric prefix of a child order is NOT a packet"
        );
        assert!(
            ledger.resolve("903z").is_none(),
            "an unused child-order suffix must not resolve"
        );
    }

    /// The other half of the order-516 contract: integer lookup is
    /// UNCHANGED. Every numeric order still resolves to the same packet,
    /// and unknown numeric orders still miss.
    #[test]
    fn integer_order_lookup_is_unchanged() {
        let ledger = synthetic_ledger();
        for (order, id) in [
            ("900", "alpha-packet"),
            ("901", "beta-packet"),
            ("902", "gamma-packet"),
        ] {
            assert_eq!(
                ledger.resolve(order).map(|p| ledger.id_of(p)).as_deref(),
                Some(id),
                "integer order {order} still resolves to {id}"
            );
        }
        assert!(
            ledger.resolve("899").is_none(),
            "an unused integer order must still miss"
        );
        // packet_id continues to win over any order token.
        assert_eq!(
            ledger
                .resolve("alpha-packet")
                .map(|p| ledger.id_of(p))
                .as_deref(),
            Some("alpha-packet")
        );
    }

    /// The `order: provisional` sentinel is carried by 26 live packets. A
    /// token-indexed resolver that took last-write-wins would answer
    /// `status provisional` with an ARBITRARY packet — a false positive,
    /// which is a worse lie than the honest miss order 516 set out to fix.
    /// Ambiguous order tokens must not resolve at all.
    #[test]
    fn an_ambiguous_order_token_does_not_resolve() {
        let raw = r#"
steps:
  - order: provisional
    packet_id: prov-one
    status: ready
  - order: provisional
    packet_id: prov-two
    status: ready
  - order: 905a
    packet_id: unique-child
    status: ready
"#;
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("parses");
        assert!(
            ledger.resolve("provisional").is_none(),
            "a token claimed by several packets must stay unresolvable, not pick one"
        );
        assert_eq!(
            ledger.resolve("905a").map(|p| ledger.id_of(p)).as_deref(),
            Some("unique-child"),
            "an unambiguous child order in the same ledger still resolves"
        );
    }

    /// The live-ledger half of exit criterion 1: the real child orders named
    /// in the packet resolve through the real loader. Guarded so that
    /// archiving those packets — i.e. finishing the work — cannot turn the
    /// suite red (order 438 discipline): the assertion is that a token
    /// PRINTED by the engine resolves back, whichever tokens exist today.
    #[test]
    fn every_child_order_the_live_ledger_prints_resolves_back() {
        let ledger = live_ledger();
        let mut claims: BTreeMap<String, usize> = BTreeMap::new();
        for p in &ledger.packets {
            if let Some(token) = p.get("order").and_then(Value::as_str) {
                *claims.entry(token.to_string()).or_default() += 1;
            }
        }
        let mut unique = 0usize;
        for (token, n) in &claims {
            if *n == 1 {
                unique += 1;
                assert!(
                    ledger.resolve(token).is_some(),
                    "the live ledger prints order '{token}' but cannot resolve it"
                );
            } else {
                // e.g. the `provisional` sentinel: shared by many packets,
                // so it must stay an honest miss rather than pick one.
                assert!(
                    ledger.resolve(token).is_none(),
                    "order token '{token}' is claimed by {n} packets and must not resolve to one of them"
                );
            }
        }
        eprintln!(
            "[plan] {unique} unambiguous alphanumeric child order(s) on the live ledger, all resolvable"
        );
    }

    /// ORDER 394b — THE CITATION SUBSTRATE, pinned on the REAL ledger.
    ///
    /// Every citation the answer envelope emits is built from `span_of`, so
    /// this is the property every citation's resolvability rests on: for each
    /// of the 427 live packets the span exists, is in-bounds, and its text
    /// CONTAINS that packet's own `packet_id:` line. A span scanner that
    /// drifted off by one line, or that mis-anchored the 19 packets whose list
    /// item starts with `- order:` rather than `- packet_id:`, fails here.
    #[test]
    fn every_live_packet_has_a_span_that_contains_its_own_id() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plan/index.yaml");
        let raw = std::fs::read_to_string(&path).expect("read live ledger");
        let lines: Vec<&str> = raw.lines().collect();
        let ledger = Ledger::load(&path).expect("live ledger loads");
        let mut checked = 0usize;
        for p in &ledger.packets {
            let id = ledger.id_of(p);
            let (start, end) = ledger
                .span_of(&id)
                .unwrap_or_else(|| panic!("no span for live packet '{id}' — it cannot be cited"));
            assert!(
                start >= 1 && end >= start && end <= lines.len(),
                "packet '{id}' span {start}-{end} is out of bounds (file has {} lines)",
                lines.len()
            );
            let span = lines[start - 1..end].join("\n");
            assert!(
                span.contains(&format!("packet_id: {id}")),
                "span {}:{start}-{end} does not contain 'packet_id: {id}'",
                path.display()
            );
            checked += 1;
        }
        assert!(checked > 100, "expected a grown corpus, checked {checked}");
        eprintln!("[plan] {checked} live packet spans located and content-verified");
    }

    /// The other half: a span must be the packet's OWN block, not a superset
    /// that swallows its neighbours. Asserted structurally — consecutive
    /// packets' spans must not overlap.
    #[test]
    fn live_packet_spans_do_not_overlap() {
        let ledger = live_ledger();
        let mut spans: Vec<(usize, usize, String)> = ledger
            .packets
            .iter()
            .map(|p| {
                let id = ledger.id_of(p);
                let (s, e) = ledger.span_of(&id).expect("span exists");
                (s, e, id)
            })
            .collect();
        spans.sort();
        for w in spans.windows(2) {
            let (_, prev_end, prev_id) = &w[0];
            let (next_start, _, next_id) = &w[1];
            assert!(
                prev_end < next_start,
                "span of '{prev_id}' (ends {prev_end}) overlaps '{next_id}' (starts {next_start})"
            );
        }
    }

    #[test]
    fn live_ledger_loads_and_is_non_trivial() {
        // The only thing worth asserting against the LIVE ledger here is that
        // it still loads and is not empty. A lower bound is safe; naming
        // specific packets is not, because packets legitimately come and go.
        let ledger = live_ledger();
        assert!(ledger.packets.len() > 100, "expected a grown corpus");
    }

    #[test]
    fn live_ledger_reference_integrity_holds() {
        // The invariant core on the REAL ledger: a hard violation means a
        // LIVE packet carries a dangling id-shaped reference — every
        // downstream tool is lying about the graph. Retired-packet debt
        // and prose annotations are warnings (filed:
        // plan/issues/plan-ledger-reference-debt-2026-07-17.md).
        let ledger = live_ledger();
        let report = ledger.check_integrity(&Schema::minimal().reference_fields);
        assert!(
            report.violations.is_empty(),
            "live ledger integrity violations: {:#?}",
            report.violations
        );
        // Order 438: this used to ALSO assert `!report.warnings.is_empty()`
        // — "expected documented organic warnings until the debt filing is
        // drained". That pinned the live ledger to an INCOMPLETE state, so
        // draining plan-ledger-reference-debt-2026-07-17.md, i.e. doing the
        // cleanup, would have turned this test red. Completing work must
        // never break a test. Warnings are reported, not asserted; only
        // violations are an invariant.
        if !report.warnings.is_empty() {
            eprintln!(
                "[plan] live ledger carries {} reference warning(s) (documented debt, not a failure)",
                report.warnings.len()
            );
        }
    }

    #[test]
    fn blocked_by_answers_the_flagship_query() {
        // Order 438: previously asserted that two NAMED real packets were
        // downstream of order 392 on the live ledger. Landing or archiving
        // either of them — or legitimately re-pointing the dependency —
        // would have failed it. Assert the traversal on a graph the test
        // owns.
        let ledger = synthetic_ledger();
        let blocked: Vec<String> = ledger
            .blocked_by("900")
            .iter()
            .map(|p| ledger.id_of(p))
            .collect();
        assert!(
            blocked.contains(&"beta-packet".to_string())
                && blocked.contains(&"gamma-packet".to_string()),
            "expected both dependents of 900, got {blocked:?}"
        );
        assert!(
            !blocked.contains(&"alpha-packet".to_string()),
            "a packet must not be listed as blocked by itself, got {blocked:?}"
        );
        // Leaf named by packet_id, so this assertion stays independent of
        // order-token resolution (order 516 exercises that separately).
        assert!(
            ledger.blocked_by("delta-packet/slice-b").is_empty(),
            "a leaf packet blocks nothing"
        );
    }

    #[test]
    fn unknown_fields_survive_load() {
        // Open-world: fields this engine never declared must survive a
        // load/inspect round trip.
        //
        // Order 438: this used to require that some LIVE packet still carried
        // a `provisional_id`. Promoting the last provisional packet — a
        // desirable event — would have failed it. The synthetic ledger
        // declares the field explicitly, so the property is tested without
        // depending on the state of real work.
        let ledger = synthetic_ledger();
        assert!(
            ledger
                .packets
                .iter()
                .any(|p| p.get("provisional_id").is_some()),
            "organically-grown fields must be visible on raw packets"
        );
    }

    #[test]
    fn append_event_inserts_and_flush_guard_accepts() {
        // Slice 2: a well-formed surgical event append on the REAL ledger
        // inserts the event and passes the flush guard (parseable, ids
        // unique, references sound, packet count unchanged).
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../plan/index.yaml");
        let raw = std::fs::read_to_string(&path).expect("read live ledger");
        let ledger = live_ledger();
        let block = edit::event_block(
            "progress",
            "2026-07-18T09:00:00Z",
            "test-agent",
            "linux",
            "unit-test appended event marker XYZ",
        );
        let out = edit::append_event(&raw, "plan-yaml-compiled-editor", &block)
            .expect("append to a real packet");
        assert!(
            out.contains("unit-test appended event marker XYZ"),
            "the event was inserted into the text"
        );
        let violations = edit::validate_candidate(
            &out,
            ledger.archived_ids(),
            &Schema::minimal().reference_fields,
        );
        assert!(
            violations.is_empty(),
            "a well-formed append must pass the flush guard: {violations:?}"
        );
        let recheck = Ledger::parse(&out, ledger.archived_ids()).expect("candidate parses");
        assert_eq!(
            recheck.packets.len(),
            ledger.packets.len(),
            "an event append adds/loses no packet"
        );
    }

    #[test]
    fn flush_guard_rejects_the_order_263_duplicate_key_class() {
        // A packet mapping with two `events:` keys is EXACTLY the corruption
        // sibling pushes produced (orders 413/416, and the glued windows
        // packet). serde_yaml rejects duplicate mapping keys, so the flush
        // guard refuses it — a broken ledger can never reach disk through the
        // tool. This is the order-263 class retired by construction.
        let broken = "steps:\n  - packet_id: foo\n    status: ready\n    \
                      events:\n      - type: filed\n    events:\n      - type: progress\n";
        let violations =
            edit::validate_candidate(broken, Default::default(), &["depends_on".to_string()]);
        assert!(
            !violations.is_empty(),
            "a duplicate-key ledger must be rejected by the flush guard"
        );
        assert!(
            violations
                .iter()
                .any(|s| s.contains("duplicate") || s.to_lowercase().contains("parse")),
            "the refusal names the parse/duplicate-key failure: {violations:?}"
        );
    }

    #[test]
    fn flush_guard_rejects_a_dangling_live_reference() {
        // Referential soundness: a LIVE packet depending on a nonexistent id
        // is a hard violation — the flush guard refuses it.
        let broken = "steps:\n  - packet_id: foo\n    status: ready\n    \
                      depends_on: [does-not-exist]\n";
        let violations =
            edit::validate_candidate(broken, Default::default(), &["depends_on".to_string()]);
        assert!(
            violations.iter().any(|s| s.contains("does-not-exist")),
            "a dangling live reference must be a violation: {violations:?}"
        );
    }
}

#[cfg(test)]
mod append_event_shape_tests {
    use super::edit;

    /// The ledger writes packets in TWO shapes — `- packet_id: x` and
    /// `- order: N` with packet_id on the next line — and the writer must serve
    /// both. It served only the first for as long as append-event existed: 19 of
    /// 479 packets were unreachable, reporting "packet_id '<id>' not found" for
    /// packets that `status <id>` resolved fine.
    #[test]
    fn append_event_reaches_both_packet_shapes_and_respects_item_boundaries() {
        let raw = "\
plan_index:
  steps:
    - packet_id: alpha
      order: 1
      title: first
      events:
        - type: filed
    - order: 2
      packet_id: beta
      title: second
    - packet_id: gamma
      order: 3
      title: third
      events:
        - type: filed
";
        let block = "        - type: progress\n          summary: probe\n";

        // packet_id-first: the historically working shape.
        let a = edit::append_event(raw, "alpha", block).expect("alpha must resolve");
        assert!(a.contains("summary: probe"), "alpha did not receive the event");

        // order-first: the shape that silently could not receive evidence.
        let b = edit::append_event(raw, "beta", block).expect("beta must resolve");
        assert!(b.contains("summary: probe"), "beta did not receive the event");

        // And the event must land in BETA, not leak into gamma. The old span-end
        // search skipped order-first items as boundaries, so a packet could get a
        // span running past its own end and write into the NEXT packet's events
        // block — silent cross-packet corruption in the one path whose purpose is
        // to make hand-edit corruption impossible.
        let beta_at = b.find("packet_id: beta").expect("beta present");
        let gamma_at = b.find("packet_id: gamma").expect("gamma present");
        let probe_at = b.find("summary: probe").expect("probe present");
        assert!(
            probe_at > beta_at && probe_at < gamma_at,
            "the event landed outside beta's span (beta@{beta_at} probe@{probe_at} gamma@{gamma_at})"
        );

        // A genuinely absent id must still fail loud.
        assert!(edit::append_event(raw, "nonexistent", block).is_err());
    }
}
