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
use std::path::Path;

pub struct Ledger {
    /// Raw packet mappings in file order (open-world: everything survives).
    pub packets: Vec<Value>,
    /// packet_id -> index into `packets`.
    by_id: BTreeMap<String, usize>,
    /// order number -> packet_id (orders can be "provisional"; only
    /// numeric orders index here).
    by_order: BTreeMap<u64, String>,
    /// packet_ids that have been ARCHIVED (completed and moved to
    /// plan/archive/). A depends_on pointing at an archived packet is a
    /// SATISFIED dependency, not a dangling reference — referential
    /// soundness resolves against active ∪ archived.
    archived_ids: BTreeSet<String>,
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
        Self::parse(&raw, archived_ids).map_err(|e| format!("{}: {e}", path.display()))
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
        for (idx, p) in packets.iter().enumerate() {
            if let Some(id) = str_field(p, "packet_id") {
                by_id.insert(id.to_string(), idx);
                if let Some(order) = p.get("order").and_then(Value::as_u64) {
                    by_order.insert(order, id.to_string());
                }
            }
        }
        Ok(Self {
            packets,
            by_id,
            by_order,
            archived_ids,
        })
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

    /// Resolve a user-facing reference: a packet_id, or a bare order number.
    pub fn resolve(&self, reference: &str) -> Option<&Value> {
        if let Some(&idx) = self.by_id.get(reference) {
            return Some(&self.packets[idx]);
        }
        reference
            .parse::<u64>()
            .ok()
            .and_then(|n| self.by_order.get(&n))
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
        let want = format!("- packet_id: {target_id}");
        let start = lines
            .iter()
            .position(|l| l.trim() == want)
            .ok_or_else(|| format!("packet_id '{target_id}' not found"))?;
        // The packet span ends at the next top-level packet list item or EOF.
        let end = (start + 1..lines.len())
            .find(|&i| lines[i].starts_with("    - packet_id:"))
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
        assert!(
            ledger.blocked_by("902").is_empty(),
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
