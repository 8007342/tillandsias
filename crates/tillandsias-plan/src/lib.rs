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
/// CRDT fragment overlay — conflict-free ADDITIVE writes to the ledger, so
/// concurrent hosts never produce a merge a human must adjudicate. Implements
/// `methodology/distributed-work.yaml` → `crdt_principles.append_only_history`,
/// which required exactly this and which the monolithic index file never was.
pub mod fragments;
/// ORDER 394d — the committed ground-truth query set and its grader.
pub mod groundtruth;
/// ORDER 582-nqw5 — the same fragment overlay applied to `plan/loop_status.md`.
/// Prose, not keyed records, so the CRDT is chosen per section rather than
/// assumed from the index overlay: the dated host-scoped `## Cycle` entries are
/// a G-SET keyed by their heading, the operator-owned `## Direction` and
/// `## ACTIVE RELEASE` sections are LWW-REGISTER written only by the operator,
/// and every other section is base-only. See the module doc for the full
/// justification and the fail-closed guards.
pub mod loop_status;
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
    /// Integer order -> packet_id. Only numeric orders index here (a
    /// `provisional` or suffixed token is not a `u64`), and only UNAMBIGUOUS
    /// ones — see `by_order_token` for why, and `allocate` for the scheme that
    /// stops new collisions being created.
    by_order: BTreeMap<u64, String>,
    /// Normalized order TOKEN -> packet_id. Order 516: child orders are
    /// written `394a` / `392b`, which YAML parses as STRINGS, so
    /// `Value::as_u64` never sees them and `by_order` cannot hold them —
    /// yet `burndown` prints exactly those tokens. This index carries every
    /// order in its textual form (numeric ones included, so a quoted
    /// `"394"` resolves too) and is consulted only AFTER the integer path,
    /// leaving numeric lookup byte-identical.
    ///
    /// UNIQUE TOKENS ONLY. 28 live packets carry the SENTINEL
    /// `order: provisional`, and six integer orders are double-booked
    /// (160, 196, 197, 201, 224, 294); mapping an ambiguous token to whichever
    /// packet happened to be parsed last would answer a query with an arbitrary
    /// packet, which is a worse lie than the honest miss this packet was
    /// filed to fix. Ambiguous tokens are dropped and stay unresolvable.
    ///
    /// `by_order` NOW APPLIES THE SAME POLICY. It did not originally, and since
    /// `resolve` consults the integer path first, this refusal was unreachable
    /// for exactly the collisions that exist in practice — the crate did the
    /// very thing this comment calls a worse lie. Callers turn the resulting
    /// miss into a useful message with [`Ledger::ambiguous_claimants`].
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
    /// ORDER 606-h9vy — per-packet WINNING-SOURCE attribution for the fragment
    /// overlay. SIDECAR STATE on purpose: injecting provenance keys into the
    /// packet Values would violate the open-world round-trip and leak into the
    /// edit/compaction text paths. Empty for a base-only load.
    ///
    /// packet_id -> span of the fragment item that CREATED a fragment-born
    /// packet. Base packets never appear here (base always wins the G-Set).
    origin_sources: BTreeMap<String, FieldSource>,
    /// `packet_id\u{1}field` -> span of the fragment status entry that WON the
    /// LWW fold for that field. Exactly the winner `fragments::fold` picked,
    /// including its first-wins-on-tie behavior.
    field_sources: BTreeMap<String, FieldSource>,
    /// Every fragment file beside the index (parseable or not) at load time.
    /// Freshness is derived over base PLUS this set, so adding a fragment
    /// changes `indexed_at` even before anything reads its content.
    corpus_files: Vec<PathBuf>,
}

/// One winning source for a folded packet or field: the fragment FILE (by
/// name, so the caller can render it relative to whatever label it uses for
/// the index) plus the 1-indexed inclusive line span that substantiates the
/// value. The span always contains the `packet_id: <id>` line, mirroring the
/// base-span invariant citations rely on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldSource {
    /// Fragment FILENAME (e.g. `20260807t000000z-x-linux.yaml`), not a path:
    /// the repo-relative rendering depends on the caller's index label.
    pub fragment_name: String,
    /// 1-indexed, inclusive.
    pub line_start: usize,
    /// 1-indexed, inclusive.
    pub line_end: usize,
}

pub fn str_field<'a>(packet: &'a Value, key: &str) -> Option<&'a str> {
    packet.get(key).and_then(Value::as_str)
}

pub fn str_list(packet: &Value, key: &str) -> Vec<String> {
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

/// ORDER 626-zmhz — the folded counts for one release, exactly as the
/// release-list prose renders them: `total` is every packet whose
/// `desired_release` matches `release` exactly (the same filter
/// `query --release` applies), and `open` is the nonterminal subset — anything
/// that is not a terminal outcome (`completed`, `obsoleted`). Counting terminal
/// statuses this way mirrors the v0.5 audit's definition (`64 completed, 2
/// obsoleted, and 188 nonterminal`) and stays stable as new packets land.
pub fn count_release(ledger: &Ledger, release: &str) -> (u64, u64) {
    let mut total: u64 = 0;
    let mut open: u64 = 0;
    for packet in &ledger.packets {
        if str_field(packet, "desired_release") != Some(release) {
            continue;
        }
        total += 1;
        let status = str_field(packet, "status").unwrap_or("");
        if !matches!(status, "completed" | "obsoleted") {
            open += 1;
        }
    }
    (open, total)
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
        // order -> (packet_id, how many packets claim it). COUNTED, then
        // filtered, exactly like `by_order_token` below.
        //
        // This index used to be a bare `by_order.insert(order, id)`, i.e.
        // last-write-wins with no ambiguity detection — while its sibling
        // `by_order_token` carefully counted claims and dropped ambiguous ones,
        // for a reason stated in that field's own doc comment: answering with
        // "whichever packet happened to be parsed last would answer a query with
        // an arbitrary packet, which is a worse lie than the honest miss".
        //
        // Because `resolve()` consults the INTEGER path first, that honest
        // refusal was unreachable for exactly the collisions that actually
        // exist. `status 160` returned one confident answer while two other
        // packets equally claimed order 160, and nothing said so. The policy was
        // implemented on one index and not the other, so the crate did the very
        // thing its comment calls a worse lie.
        let mut order_claims: BTreeMap<u64, (String, usize)> = BTreeMap::new();
        // token -> (packet_id, how many packets claim it). Count first, then
        // keep only the unambiguous ones (see `by_order_token`).
        let mut token_claims: BTreeMap<String, (String, usize)> = BTreeMap::new();
        for (idx, p) in packets.iter().enumerate() {
            if let Some(id) = str_field(p, "packet_id") {
                by_id.insert(id.to_string(), idx);
                if let Some(order) = p.get("order").and_then(Value::as_u64) {
                    order_claims
                        .entry(order)
                        .and_modify(|(_, n)| *n += 1)
                        .or_insert((id.to_string(), 1));
                }
                if let Some(token) = p.get("order").and_then(order_token) {
                    token_claims
                        .entry(token)
                        .and_modify(|(_, n)| *n += 1)
                        .or_insert((id.to_string(), 1));
                }
            }
        }
        let by_order: BTreeMap<u64, String> = order_claims
            .into_iter()
            .filter(|(_, (_, n))| *n == 1)
            .map(|(order, (id, _))| (order, id))
            .collect();
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
            origin_sources: BTreeMap::new(),
            field_sources: BTreeMap::new(),
            corpus_files: Vec::new(),
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

    /// ORDER 606-h9vy — the fragment item that CREATED a fragment-born packet,
    /// or `None` for base packets (whose citable origin is `span_of`). The two
    /// are disjoint by construction: the G-Set never lets a fragment overwrite
    /// a base packet, so a packet has a base span or a fragment origin, never
    /// both.
    pub fn origin_source_of(&self, packet_id: &str) -> Option<&FieldSource> {
        self.origin_sources.get(packet_id)
    }

    /// ORDER 606-h9vy — the fragment status entry that WON the LWW fold for
    /// `field` on `packet_id`, or `None` when the current value comes from the
    /// packet's own block (base or fragment-born). An exact answer must cite
    /// this winner for the field, never the stale base span.
    pub fn field_source_of(&self, packet_id: &str, field: &str) -> Option<&FieldSource> {
        self.field_sources.get(&format!("{packet_id}\u{1}{field}"))
    }

    /// Every fragment file that was beside the index at load time, parseable
    /// or not. Empty for a base-only load. Freshness derives from base plus
    /// this whole set — a malformed fragment still changes the corpus.
    pub fn corpus_files(&self) -> &[PathBuf] {
        &self.corpus_files
    }

    pub(crate) fn set_fragment_sources(
        &mut self,
        origin_sources: BTreeMap<String, FieldSource>,
        field_sources: BTreeMap<String, FieldSource>,
        corpus_files: Vec<PathBuf>,
    ) {
        self.origin_sources = origin_sources;
        self.field_sources = field_sources;
        self.corpus_files = corpus_files;
    }

    /// Rebuild the lookup indexes from the current `packets`, leaving `spans`
    /// and `source_path` untouched.
    ///
    /// Used by the fragment overlay, which replaces the packet list with the
    /// folded one but must NOT disturb spans — those are byte-offsets into the
    /// base file and are what make citations verifiable. Rebuilding them from a
    /// merged in-memory document would produce line numbers matching no file,
    /// which the order-523 self-verifier correctly reports as a FABRICATED
    /// citation.
    ///
    /// Applies exactly the same ambiguity policy as `parse`: an order claimed by
    /// more than one packet is DROPPED from both order indexes rather than
    /// resolved to whichever was seen last.
    pub(crate) fn reindex(&mut self) {
        let mut by_id = BTreeMap::new();
        let mut order_claims: BTreeMap<u64, (String, usize)> = BTreeMap::new();
        let mut token_claims: BTreeMap<String, (String, usize)> = BTreeMap::new();
        for (idx, p) in self.packets.iter().enumerate() {
            if let Some(id) = str_field(p, "packet_id") {
                by_id.insert(id.to_string(), idx);
                if let Some(order) = p.get("order").and_then(Value::as_u64) {
                    order_claims
                        .entry(order)
                        .and_modify(|(_, n)| *n += 1)
                        .or_insert((id.to_string(), 1));
                }
                if let Some(token) = p.get("order").and_then(order_token) {
                    token_claims
                        .entry(token)
                        .and_modify(|(_, n)| *n += 1)
                        .or_insert((id.to_string(), 1));
                }
            }
        }
        self.by_id = by_id;
        self.by_order = order_claims
            .into_iter()
            .filter(|(_, (_, n))| *n == 1)
            .map(|(order, (id, _))| (order, id))
            .collect();
        self.by_order_token = token_claims
            .into_iter()
            .filter(|(_, (_, n))| *n == 1)
            .map(|(token, (id, _))| (token, id))
            .collect();
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

    /// Every packet claiming `reference` as its order, when more than one does.
    ///
    /// Exists so an ambiguous lookup can FAIL INFORMATIVELY. Dropping ambiguous
    /// orders from the indexes is right — answering `status 160` with one of
    /// three packets is a lie — but the resulting miss would otherwise read as
    /// "no such work", which is equally false and is the precise failure mode
    /// order 516 was filed to remove from this surface. The order exists; it
    /// just does not identify a single packet, and the caller needs to be told
    /// which packet_ids to disambiguate between.
    ///
    /// Returns an empty vec for an unambiguous or absent reference, so callers
    /// can branch on `is_empty()` to distinguish "genuinely unknown" from
    /// "known but ambiguous".
    pub fn ambiguous_claimants(&self, reference: &str) -> Vec<String> {
        let wanted = normalize_order_token(reference);
        let mut ids: Vec<String> = self
            .packets
            .iter()
            .filter(|p| {
                p.get("order")
                    .and_then(order_token)
                    .is_some_and(|t| t == wanted)
            })
            .filter_map(|p| str_field(p, "packet_id").map(str::to_string))
            .collect();
        if ids.len() < 2 {
            return Vec::new();
        }
        ids.sort();
        ids
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
    /// The three lookups are ordered id -> integer order -> order token. Both
    /// order paths now drop AMBIGUOUS claims, so a reference shared by several
    /// packets is an honest miss rather than an arbitrary hit; use
    /// [`Self::ambiguous_claimants`] to explain such a miss instead of reporting
    /// a bare "no packet matches", which would be false — the order exists, it
    /// just does not identify one packet.
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

    /// The target packet's direct, unsatisfied `depends_on` prerequisites —
    /// i.e. what X is blocked ON, rather than the downstream packets X blocks.
    ///
    /// `None` means the target reference did not resolve. `Some([])` means the
    /// target is real and has no outstanding direct prerequisite. Declared
    /// dependency order is preserved. Archived dependencies and active
    /// `completed`/`obsoleted` packets are satisfied; every other active status
    /// remains visible because it still prevents the edge from being satisfied.
    pub fn dependencies_of(&self, reference: &str) -> Option<Vec<&Value>> {
        let target = self.resolve(reference)?;
        let mut seen = BTreeSet::new();
        let mut result = Vec::new();

        for dependency in str_list(target, "depends_on") {
            if !seen.insert(dependency.clone()) || self.archived_ids.contains(&dependency) {
                continue;
            }
            let Some(packet) = self.resolve(&dependency) else {
                // Referential soundness rejects this state in `check`; never
                // fabricate a row when a malformed live ledger slips through.
                continue;
            };
            if matches!(str_field(packet, "status"), Some("completed" | "obsoleted")) {
                continue;
            }
            result.push(packet);
        }

        Some(result)
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

        // Order tokens must be unique too, and until now nothing checked.
        //
        // `check` reported "ok: N packets, ids unique, live references sound"
        // over a ledger carrying SIX double-booked orders (160, 196, 197, 201,
        // 224, 294) because it validated packet_id and never looked at `order`.
        // A guard that cannot see the defect it exists to prevent is this
        // project's own named anti-pattern, and this one had been blind since
        // the field was introduced.
        //
        // WARNING, NOT VIOLATION — deliberately. Six collisions already exist at
        // HEAD; promoting them straight to violations would fail `check` on a
        // clean checkout and block every cycle on unrelated historical debt.
        // The warning names them so they are visible and disposable, and the
        // gate tightens once they are resolved (see
        // plan/issues/work-order-id-collision-free-design-2026-08-01.md §4 and
        // packet duplicate-order-numbers-are-silently-unaddressable).
        //
        // The `provisional` SENTINEL is exempt: it is explicitly a
        // not-yet-assigned marker carried by 28 packets, so many packets sharing
        // it is its intended use, not a collision.
        let mut order_claims: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for p in &self.packets {
            if let Some(token) = p.get("order").and_then(order_token)
                && token != "provisional"
                && let Some(id) = str_field(p, "packet_id")
            {
                order_claims.entry(token).or_default().push(id.to_string());
            }
        }
        for (token, ids) in &order_claims {
            if ids.len() > 1 {
                report.warnings.push(format!(
                    "duplicate order '{}' claimed by {} packets ({}) — \
                     unaddressable by order; reference these by packet_id",
                    token,
                    ids.len(),
                    ids.join(", ")
                ));
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

pub(crate) fn collect_packets(value: &Value, out: &mut Vec<Value>) {
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
/// Collision-free order-token allocation for concurrent filing.
///
/// THE PROBLEM THIS REPLACES. "Next free order" is computed from a ledger
/// SNAPSHOT that is stale the moment another host commits, so two hosts filing
/// in the same window deterministically pick the same number. It happened twice
/// in one session (560-562, then 568-570), and six collisions already sit at
/// HEAD unnoticed.
///
/// Renumbering after the fact is the expensive half: order numbers leak into
/// code comments, `@trace order:` headers (30 in the tree), and COMMIT
/// MESSAGES, which can never be corrected. So the fix cannot be "detect and
/// renumber" — it has to be "never collide".
///
/// THE SCHEME: `<seq>-<suffix>`, e.g. `575-k3f9`, allocated once and NEVER
/// normalized. The `<seq>` prefix keeps rough chronology and human familiarity
/// and is explicitly NON-AUTHORITATIVE — two hosts both picking 575 produce
/// `575-k3f9` and `575-m2p1`, two distinct permanent identifiers that need no
/// reconciliation. That is the operator's own criterion ("we don't need work
/// orders to be fully numerically sequential, only unique") taken to its
/// conclusion: once sequence is not required, normalization has nothing left to
/// achieve, and normalization is precisely what costs.
///
/// Ordering is not lost — `events[].ts` and git history carry it, as the
/// operator noted. See `plan/issues/work-order-id-collision-free-design-2026-08-01.md`.
///
/// No schema change is needed: `order` already accepts strings (`392a`, `484e`)
/// and `order_token` already normalizes any scalar.
pub mod allocate {
    use super::Ledger;
    use std::collections::BTreeSet;
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};

    /// Suffix alphabet, deliberately 32 symbols with the visually ambiguous ones
    /// removed (`l`/`1`, `o`/`0`). These tokens get read off a terminal, said out
    /// loud, and retyped into `plan_status`; a suffix that resolves to a
    /// different packet when misread would reintroduce the ambiguity this whole
    /// scheme exists to remove.
    const ALPHABET: &[u8] = b"abcdefghijkmnpqrstuvwxyz23456789";

    /// Suffix length. 32^4 = 1_048_576 values, and the suffix only has to
    /// separate packets that chose the SAME prefix — realistically two or three
    /// hosts within the same hour. Four characters keep the token sayable while
    /// putting the collision probability far below the noise floor, and unlike
    /// today a full-token collision is DETECTED (see `mint`) rather than
    /// silently resolved to whichever packet parsed last.
    const SUFFIX_LEN: usize = 4;

    /// Entropy source. NOT cryptographic and does not need to be: this is a
    /// disambiguator between cooperating hosts, not a secret. `RandomState` is
    /// seeded from the OS per process and is available in std, so this adds no
    /// dependency to a crate that deliberately carries only three.
    fn random_suffix() -> String {
        let mut out = String::with_capacity(SUFFIX_LEN);
        let mut hasher = RandomState::new().build_hasher();
        hasher.write_usize(SUFFIX_LEN);
        let mut bits = hasher.finish();
        for _ in 0..SUFFIX_LEN {
            out.push(ALPHABET[(bits % ALPHABET.len() as u64) as usize] as char);
            bits /= ALPHABET.len() as u64;
            if bits < ALPHABET.len() as u64 {
                // Refresh from a fresh RandomState rather than reusing depleted
                // low bits, which would bias the tail of the suffix.
                let mut h = RandomState::new().build_hasher();
                h.write_u64(bits);
                bits = h.finish();
            }
        }
        out
    }

    /// The highest integer order prefix present, so a freshly minted token sorts
    /// after everything already filed.
    ///
    /// Reads the PREFIX of every token, so `575-k3f9` and `392b` both advance
    /// the counter — otherwise the first suffixed packet would leave the next
    /// allocation stuck behind it forever.
    pub fn highest_prefix(ledger: &Ledger) -> u64 {
        ledger
            .packets
            .iter()
            .filter_map(|p| p.get("order").and_then(super::order_token))
            .filter_map(|t| {
                let digits: String = t.chars().take_while(char::is_ascii_digit).collect();
                digits.parse::<u64>().ok()
            })
            .max()
            .unwrap_or(0)
    }

    /// Mint a collision-free order token.
    ///
    /// Retries on the (vanishingly unlikely) case that the minted token is
    /// already claimed — a real check against the ledger, so the guarantee does
    /// not rest on probability alone. Gives up after a bounded number of
    /// attempts rather than looping forever, because an exhausted alphabet is a
    /// bug worth reporting, not a condition to spin on.
    pub fn mint(ledger: &Ledger, prefix: Option<u64>) -> Result<String, String> {
        mint_avoiding(ledger, prefix, &BTreeSet::new())
    }

    /// Mint a token that collides with neither the LEDGER nor `reserved`.
    ///
    /// WHY `reserved` EXISTS. `mint` alone guarantees only that a token is
    /// unused *in the ledger*. Tokens minted but not yet written back are
    /// invisible to it, so an agent filing several packets in one pass — the
    /// common case, and what this author did minting three in a row — could draw
    /// the same suffix twice and never be told.
    ///
    /// The exposure is small but real, and it is bounded by the birthday
    /// problem rather than by the retry loop: with a 4-character suffix over a
    /// 32-symbol alphabet there are 32^4 = 1_048_576 values, so N unwritten
    /// mints collide with probability ≈ N²/2_097_152 — about 0.005% for ten,
    /// but ~11% for five hundred. Widening the suffix would trade away the
    /// readability the format exists for; tracking what this process already
    /// issued costs nothing and removes the failure entirely for a single
    /// filer.
    ///
    /// Cross-host concurrent unwritten mints remain probabilistic, which is the
    /// design's accepted trade: coordination-free allocation is the whole point,
    /// and at realistic concurrency the probability is far below the rate at
    /// which the ledger is committed.
    pub fn mint_avoiding(
        ledger: &Ledger,
        prefix: Option<u64>,
        reserved: &BTreeSet<String>,
    ) -> Result<String, String> {
        let seq = prefix.unwrap_or_else(|| highest_prefix(ledger) + 1);
        for _ in 0..64 {
            let token = format!("{seq}-{}", random_suffix());
            if !reserved.contains(&token)
                && ledger.resolve(&token).is_none()
                && ledger.ambiguous_claimants(&token).is_empty()
            {
                return Ok(token);
            }
        }
        Err(format!(
            "could not mint an unclaimed order token for prefix {seq} in 64 attempts \
             — this indicates a bug, not exhaustion"
        ))
    }

    /// Mint `count` tokens guaranteed distinct from each other and from the
    /// ledger — the shape an agent filing a batch of packets actually needs.
    pub fn mint_batch(
        ledger: &Ledger,
        prefix: Option<u64>,
        count: usize,
    ) -> Result<Vec<String>, String> {
        let mut issued: BTreeSet<String> = BTreeSet::new();
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            let token = mint_avoiding(ledger, prefix, &issued)?;
            issued.insert(token.clone());
            out.push(token);
        }
        Ok(out)
    }
}

pub mod edit {
    use super::Ledger;
    use std::collections::BTreeSet;

    /// Locate a packet item's line span `[start, end)` in `raw`, by the same
    /// list-item boundary scan every edit below uses. `start`/`end` are
    /// indices into `raw.lines()`; the span is the item's own lines (fields,
    /// events, everything) up to the next list item of ANY shape, or EOF.
    ///
    /// Items are located by LIST-ITEM BOUNDARY, not by assuming `packet_id` is
    /// the item's first key. Both of the original locators keyed off the
    /// literal "- packet_id:", which is only how an item renders when
    /// `packet_id` happens to be its FIRST key. 19 of the ledger's packets are
    /// written `- order: N` with `packet_id` on the following line, and for
    /// those:
    ///
    ///   1. the START search failed, so `append-event` reported
    ///      "packet_id '<id>' not found" for a packet that plainly exists and
    ///      that `status <id>` resolves fine — a misleading message hiding a
    ///      read/write asymmetry, and one that silently made ~4% of the ledger
    ///      unable to receive evidence at all;
    ///
    ///   2. worse, the END search skipped those items as span boundaries. A
    ///      packet_id-first packet followed by an order-first one therefore
    ///      got a span running PAST its own end, so an event could be inserted
    ///      into the NEXT packet's `events:` block — silent cross-packet
    ///      corruption, in the one code path whose entire purpose is to make
    ///      hand-edit corruption impossible.
    ///
    /// Item boundaries are unambiguous at this indentation, so use them.
    pub fn item_span(raw: &str, target_id: &str) -> Option<(usize, usize)> {
        let lines: Vec<&str> = raw.lines().collect();
        let is_item = |l: &str| l.starts_with("    - ");
        let item_starts: Vec<usize> = (0..lines.len()).filter(|&i| is_item(lines[i])).collect();

        let want_key = format!("packet_id: {target_id}");
        for (n, &s) in item_starts.iter().enumerate() {
            let e = item_starts.get(n + 1).copied().unwrap_or(lines.len());
            // A key line reads "packet_id: x" normally, but "- packet_id: x"
            // when it is the item's FIRST key. Strip the list marker so both
            // shapes compare equal — matching only one of them is precisely
            // how this function came to serve 460 packets and silently refuse
            // the other 19.
            let hit = (s..e).any(|i| {
                let t = lines[i].trim();
                t == want_key || t.strip_prefix("- ") == Some(want_key.as_str())
            });
            if hit {
                return Some((s, e));
            }
        }
        None
    }

    /// Insert `event_block` as the FIRST entry under the target packet's
    /// `events:` list, preserving all surrounding formatting. `event_block`
    /// is the event's already-8-space-indented lines, newline-terminated
    /// (see [`event_block`]). Creates the `events:` block if the packet has
    /// none. Does NOT validate — the caller flushes only after
    /// [`validate_candidate`] returns no violations.
    pub fn append_event(raw: &str, target_id: &str, event_block: &str) -> Result<String, String> {
        let mut lines: Vec<String> = raw.lines().map(String::from).collect();
        let (start, end) = item_span(raw, target_id)
            .ok_or_else(|| format!("packet_id '{target_id}' not found"))?;
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

    /// Insert `event_block` as the LAST entry under the target packet's
    /// `events:` list, preserving all surrounding formatting and leaving any
    /// existing events in place. The complement of [`append_event`] (which
    /// inserts first), used by compaction so the folded text keeps the same
    /// event ORDER the CRDT fold produced. Creates the `events:` block if the
    /// packet has none. Does NOT validate.
    pub fn push_event(raw: &str, target_id: &str, event_block: &str) -> Result<String, String> {
        let mut lines: Vec<String> = raw.lines().map(String::from).collect();
        let (start, end) = item_span(raw, target_id)
            .ok_or_else(|| format!("packet_id '{target_id}' not found"))?;
        let block: Vec<String> = event_block.lines().map(String::from).collect();
        if block.is_empty() {
            return Err("empty event block".to_string());
        }
        match (start..end).find(|&i| lines[i] == "      events:") {
            Some(ei) => {
                // The events sequence runs from the header to the next packet
                // field (a line at exactly 6-space) or to the item's end. Only
                // the FIRST line of an event is a `- ` dash — its fields are
                // indented deeper — so "the last dash line" is the START of the
                // last event, and inserting there splits it (duplicate-key
                // corruption, caught by the parse gate). Insert after the whole
                // block instead.
                let insert_at = (ei + 1..end)
                    .find(|&i| lines[i].starts_with("      ") && !lines[i].starts_with("        "))
                    .unwrap_or(end);
                for (k, bl) in block.iter().enumerate() {
                    lines.insert(insert_at + k, bl.clone());
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

    /// ORDER 626-zmhz exit criterion 3. A packet that lands as a FRAGMENT must
    /// change the release counts the release-list prose is supposed to mirror,
    /// and the renderer must produce a different canonical line — otherwise a
    /// count gate that reads only the base would call stale prose current with
    /// total confidence. Folds, not greps.
    #[test]
    fn a_packet_fragment_changes_the_rendered_release_count() {
        let d = std::env::temp_dir().join(format!("tilland-count-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let index = d.join("plan/index.yaml");
        std::fs::create_dir_all(d.join("plan/index.d")).expect("mkdir");
        std::fs::write(
            &index,
            "plan_index:\n  steps:\n    - order: 900\n      packet_id: alpha\n      title: \"A\"\n      status: completed\n      desired_release: v0.5\n    - order: 901\n      packet_id: beta\n      title: \"B\"\n      status: ready\n      desired_release: v0.5\n    - order: 902\n      packet_id: gamma\n      title: \"C\"\n      status: ready\n      desired_release: v0.6\n",
        )
        .expect("write base");

        let before = Ledger::load_with_fragments(&index).expect("base overlay loads");
        let (open0, total0) = count_release(&before, "v0.5");
        assert_eq!((open0, total0), (1, 2), "v0.5: one ready + one completed");

        std::fs::write(
            d.join("plan/index.d/20260809t0100z-new-v05.yaml"),
            "packets:\n  - packet_id: delta\n    order: 903\n    title: \"D\"\n    status: pending\n    desired_release: v0.5\n",
        )
        .expect("write fragment");

        let after = Ledger::load_with_fragments(&index).expect("folded overlay loads");
        let (open1, total1) = count_release(&after, "v0.5");
        assert_eq!(
            (open1, total1),
            (2, 3),
            "the fragment packet must be counted"
        );

        let canonical_before = crate::loop_status::render_count_line(open0, total0);
        let canonical_after = crate::loop_status::render_count_line(open1, total1);
        assert_ne!(
            canonical_before, canonical_after,
            "a new packet fragment must change the rendered count line"
        );
        assert_eq!(canonical_after, "(2 open / 3 total tagged)");

        let _ = std::fs::remove_dir_all(&d);
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
    fn dependencies_of_returns_only_direct_unsatisfied_prerequisites_in_declared_order() {
        let raw = r#"
steps:
  - packet_id: ready-dep
    order: 910
    status: ready
  - packet_id: completed-dep
    order: 911
    status: completed
  - packet_id: obsoleted-dep
    order: 912
    status: obsoleted
  - packet_id: failed-dep
    order: 913
    status: failed
  - packet_id: target
    order: 914
    status: pending
    depends_on: [failed-dep, completed-dep, archived-dep, ready-dep, obsoleted-dep, failed-dep]
  - packet_id: downstream
    order: 915
    status: ready
    depends_on: [target]
"#;
        let archived = ["archived-dep".to_string()].into_iter().collect();
        let ledger = Ledger::parse(raw, archived).expect("synthetic ledger parses");

        let upstream: Vec<String> = ledger
            .dependencies_of("target")
            .expect("target resolves")
            .iter()
            .map(|p| ledger.id_of(p))
            .collect();
        assert_eq!(upstream, vec!["failed-dep", "ready-dep"]);
        assert_eq!(
            ledger
                .dependencies_of("completed-dep")
                .expect("leaf resolves")
                .len(),
            0,
            "a real leaf is distinguishable from an unknown target"
        );
        assert!(ledger.dependencies_of("not-real").is_none());

        let downstream: Vec<String> = ledger
            .blocked_by("target")
            .iter()
            .map(|p| ledger.id_of(p))
            .collect();
        assert_eq!(
            downstream,
            vec!["downstream"],
            "adding the upstream query must not change downstream semantics"
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
        assert!(
            a.contains("summary: probe"),
            "alpha did not receive the event"
        );

        // order-first: the shape that silently could not receive evidence.
        let b = edit::append_event(raw, "beta", block).expect("beta must resolve");
        assert!(
            b.contains("summary: probe"),
            "beta did not receive the event"
        );

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

#[cfg(test)]
mod order_identity_tests {
    use super::*;

    /// A ledger where two packets claim the same order — the live shape at HEAD
    /// (160, 196, 197, 201, 224, 294) and the shape two hosts produce when they
    /// file concurrently.
    const COLLIDED: &str = "\
packets:
    - packet_id: alpha
      order: 160
      status: ready
    - packet_id: beta
      order: 160
      status: ready
    - packet_id: gamma
      order: 161
      status: ready
";

    #[test]
    fn a_duplicated_order_resolves_to_nothing_rather_than_an_arbitrary_packet() {
        // THE REGRESSION THIS PINS. `by_order` was a bare insert, so it was
        // last-write-wins and `status 160` returned ONE confident answer while
        // another packet equally claimed 160. The sibling index `by_order_token`
        // already refused such tokens, for the reason stated in its own doc
        // comment — answering arbitrarily "is a worse lie than the honest miss".
        // Because resolve() consults the integer path FIRST, that refusal was
        // unreachable for exactly the collisions that exist in practice.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        assert!(
            ledger.resolve("160").is_none(),
            "an ambiguous order must not resolve to an arbitrary claimant"
        );
        assert!(
            ledger.resolve("161").is_some(),
            "an unambiguous order must still resolve"
        );
        assert!(
            ledger.resolve("alpha").is_some() && ledger.resolve("beta").is_some(),
            "packet_id is the identity and must resolve for BOTH colliding packets"
        );
    }

    #[test]
    fn an_ambiguous_miss_can_name_its_claimants() {
        // A bare "no packet matches" would be false — order 160 exists. The
        // caller needs the packet_ids to disambiguate between.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        assert_eq!(
            ledger.ambiguous_claimants("160"),
            vec!["alpha".to_string(), "beta".to_string()],
            "an ambiguous order names every claimant, sorted"
        );
        assert!(
            ledger.ambiguous_claimants("161").is_empty(),
            "an unambiguous order has no claimants to disambiguate"
        );
        assert!(
            ledger.ambiguous_claimants("9999").is_empty(),
            "a genuinely unknown reference is not 'ambiguous' — callers branch on this \
             to tell 'unknown' from 'known but ambiguous'"
        );
    }

    #[test]
    fn check_reports_duplicate_orders_it_previously_could_not_see() {
        // `check` printed "ok: N packets, ids unique, live references sound" over
        // six real collisions, because it validated packet_id and never looked at
        // `order`.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        let report = ledger.check_integrity(&[]);
        assert!(
            report
                .warnings
                .iter()
                .any(|w| w.contains("duplicate order '160'")
                    && w.contains("alpha")
                    && w.contains("beta")),
            "check must name the duplicated order AND its claimants: {:?}",
            report.warnings
        );
        assert!(
            report.violations.is_empty(),
            "duplicates are WARNINGS: six already exist at HEAD, and promoting them \
             to violations would fail check on a clean checkout"
        );
    }

    #[test]
    fn the_provisional_sentinel_is_not_a_collision() {
        // 28 live packets carry `order: provisional`. Many packets sharing it is
        // its intended use, so flagging it would bury the real duplicates under
        // noise from a working feature.
        let raw = "\
packets:
    - packet_id: a
      order: provisional
      status: ready
    - packet_id: b
      order: provisional
      status: ready
";
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("fixture parses");
        let report = ledger.check_integrity(&[]);
        assert!(
            !report
                .warnings
                .iter()
                .any(|w| w.contains("duplicate order")),
            "the provisional sentinel must be exempt: {:?}",
            report.warnings
        );
    }

    #[test]
    fn minted_tokens_are_unique_and_do_not_collide_across_hosts_on_one_prefix() {
        // The concurrent-filing case: two hosts that both computed the same
        // "next free order" from their own stale snapshot. Under the old scheme
        // that is a guaranteed collision; under this one it is two distinct,
        // permanent identifiers needing no reconciliation.
        //
        // THIS TEST USED TO BE FLAKY, AND THE TEST WAS THE BUG. It drew 500
        // tokens from `mint` and asserted every one distinct. `mint` guarantees
        // only that a token is unused IN THE LEDGER — tokens minted and not yet
        // written back are invisible to it — so 500 unwritten draws is a pure
        // birthday experiment over 32^4 values and collides ~11% of the time by
        // construction. It failed 3 runs in 12 and intermittently reddened two
        // unrelated litmus tests that shell out to `cargo test`.
        //
        // Asserting a guarantee the design does not make is worse than not
        // testing it: the red is real but the diagnosis points at `mint`, which
        // is behaving exactly as specified. So the batch guarantee now has an
        // API that actually provides it (`mint_batch`), and this test asserts
        // the contract `mint` really offers.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        for _ in 0..200 {
            let token = allocate::mint(&ledger, Some(575)).expect("mint succeeds");
            assert!(
                token.starts_with("575-"),
                "an explicit prefix must be honored: {token}"
            );
            assert!(
                ledger.resolve(&token).is_none(),
                "mint's actual contract: never return a token the LEDGER already \
                 claims — {token}"
            );
        }
    }

    #[test]
    fn a_minted_batch_is_internally_distinct_which_mint_alone_cannot_promise() {
        // The realistic failure this closes: one agent filing several packets in
        // one pass draws several tokens before any of them reach the ledger, so
        // `mint` cannot see its own earlier draws. Three-in-a-row is the common
        // case (and what the author of this module did).
        //
        // 500 is deliberately far past any real batch — at that size the naive
        // approach collides ~11% of the time, so this both proves the guarantee
        // and would catch a regression that quietly dropped the reservation set.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        let batch = allocate::mint_batch(&ledger, Some(575), 500).expect("batch mints");
        let unique: BTreeSet<&String> = batch.iter().collect();
        assert_eq!(
            unique.len(),
            batch.len(),
            "every token in a batch must be distinct from every other"
        );
        for t in &batch {
            assert!(t.starts_with("575-"), "prefix honored: {t}");
            assert!(ledger.resolve(t).is_none(), "and unused in the ledger: {t}");
        }
    }

    #[test]
    fn minting_never_reuses_an_order_already_in_the_ledger() {
        // Probability is not the guarantee — the ledger is checked.
        let ledger = Ledger::parse(COLLIDED, BTreeSet::new()).expect("fixture parses");
        for _ in 0..200 {
            let token = allocate::mint(&ledger, None).expect("mint succeeds");
            assert!(
                ledger.resolve(&token).is_none(),
                "minted a token that already resolves: {token}"
            );
        }
    }

    #[test]
    fn the_next_prefix_advances_past_suffixed_and_child_orders() {
        // If highest_prefix only understood bare integers, the FIRST suffixed
        // packet would leave every later allocation stuck behind it.
        let raw = "\
packets:
    - packet_id: a
      order: 100
      status: ready
    - packet_id: b
      order: 575-k3f9
      status: ready
    - packet_id: c
      order: 392b
      status: ready
";
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("fixture parses");
        assert_eq!(
            allocate::highest_prefix(&ledger),
            575,
            "a suffixed order must advance the counter like any other"
        );
    }

    #[test]
    fn a_suffixed_order_is_addressable_exactly_like_an_integer_one() {
        // The scheme is worthless if agents cannot look the token up.
        let raw = "\
packets:
    - packet_id: suffixed
      order: 575-k3f9
      status: ready
";
        let ledger = Ledger::parse(raw, BTreeSet::new()).expect("fixture parses");
        assert!(
            ledger.resolve("575-k3f9").is_some(),
            "a suffixed order must resolve"
        );
        assert!(
            ledger.resolve("575-K3F9").is_some(),
            "and resolve case-insensitively, like every other order token"
        );
        assert!(
            ledger.resolve("575").is_none(),
            "the PREFIX alone must not resolve — it is non-authoritative and \
             several packets may share it"
        );
    }
}
