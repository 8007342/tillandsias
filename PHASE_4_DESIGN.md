# Phase 4 Design: Cheatsheet Metrics Collection and Manual Compaction

@trace spec:cheatsheets-metrics-collection

**Status**: Design document. Implementation begins after Phase 2 (CI validator) and Phase 3 (verification level tracking) are complete.

**Timeline**: Phase 4 prepares the infrastructure for Phase 5 (automated compaction). This phase focuses on **metrics collection and schema** (no automation yet).

---

## Executive Summary

Phase 4 introduces a metrics collection system that tracks how agents use cheatsheets (hits, misses, success rates) WITHOUT instrumenting the released tray binary. All metrics collection happens inside forge containers (agent-side, development-time). The host-side aggregation runs post-session, feeding a unified scoring function that guides manual compaction decisions.

**Hard Boundary**: Zero runtime instrumentation in released code. Zero telemetry in the tray. Metrics are a development-time capability only.

---

## What Phase 4 Solves

The cheatsheet system (Phase 1–3) enforces consistency via specs and verification levels. But consistency is not efficiency — we can't know which cheatsheet entries are actually useful, which are stale, or which are causing so many misses that they need expansion.

Phase 4 answers these questions by measuring:

1. **Hit/miss ratio** per entry (did the agent find what it needed?)
2. **Spec binding strength** (how many active specs cite this entry?)
3. **Verification success rate** at each L-level (L0 easy; L3 hard)
4. **Token cost** (how many bytes does this entry consume in context?)
5. **Freshness** (when was it last used?)

These five signals feed a **scoring function** that recommends actions:

- **EXPAND**: entry is spec-bound but has high miss rate → needs more coverage
- **COMPACT**: entry is stable and high-scoring → compress it to save context
- **DELETE**: entry is low-scoring and not spec-bound → orphaned, remove it
- **PROTECT**: entry is high-scoring or highly cited → preserve it, prioritize in refactoring

**Key insight**: We don't need real-time metrics. Post-session analysis is fine. Agents exit the container, events are flushed, then we score. Zero impact on runtime performance.

---

## Architecture

### Three Tiers

#### Tier 1: Agent-Side Logging (Inside Forge Containers)

- **Who**: claude-code, opencode, opsx agents running inside forge
- **What**: Each agent logs one event per cheatsheet lookup
- **Where**: `/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl` (append-only JSONL)
- **When**: Immediately after the lookup resolves (hit/miss/partial/live-api)
- **How**: Wrapper function or middleware; agents call it before returning content

**Example (Rust pseudocode)**:
```rust
async fn lookup_cheatsheet(path: &str, query: &str) -> Result<String> {
    let start = Instant::now();
    let content = read_cheatsheet(path).await?;
    let (resolved, entry, confidence) = search_entry(&content, query)?;
    let elapsed_ms = start.elapsed().as_millis() as u32;
    
    // @trace spec:cheatsheets-metrics-collection
    log_cheatsheet_event(CheatsheetEvent {
        ts: now(),
        agent: "claude",
        project: env::var("TILLANDSIAS_PROJECT")?,
        cheatsheet: path,
        query: query.to_string(),
        resolved_via: resolved,  // hit | miss | partial | live-api
        cheatsheet_entry: entry,
        time_ms: elapsed_ms,
        spec: None,
        verification_level: claimed_level,
        confidence,
        chars_consumed: content.len() as u32,
    }).await?;
    
    Ok(content)
}
```

**No runtime overhead**: Logging is sequential after the lookup completes. Append-only JSONL is fast (single write, no parsing).

#### Tier 2: Phase 1 External-Logs Infrastructure (Already Built)

The tray auditor (Phase 1 work) already:
- Monitors `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl`
- Rotates files at 10 MB
- Flags leaks if new files appear
- Runs every 60 seconds

**Zero changes needed.** The forge is already declared as a producer of `cheatsheet-telemetry` in `images/default/external-logs.yaml`.

#### Tier 3: Post-Session Analysis (Host-Side)

After an agent exits a forge container:

```bash
# Host operator runs this explicitly (or via CI):
scripts/analyze-cheatsheet-metrics.sh --project tillandsias

# Reads: ~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl
# Outputs: cheatsheet-metrics-report.jsonl
# Report contains: score, action (EXPAND/COMPACT/DELETE/PROTECT), hit/miss counts
```

**Timing**: Post-session, no blocking. Reports are generated on-demand for review.

---

## Event Schema

**Location**: Each agent emits one JSON object per line to the JSONL log.

**Fields** (required unless marked optional):

| Field | Type | Meaning | Example |
|-------|------|---------|---------|
| `ts` | ISO 8601 | Event timestamp, UTC | `"2026-05-02T14:30:00Z"` |
| `agent` | `"claude" \| "opencode" \| "opsx"` | Which agent looked it up | `"claude"` |
| `project` | string | Project directory name | `"tillandsias"` |
| `cheatsheet` | string | Relative path under `/opt/cheatsheets/` | `"languages/rust.md"` |
| `query` | string | What the agent searched for | `"tokio::select! with timeout"` |
| `resolved_via` | `"hit" \| "miss" \| "partial" \| "live-api"` | How it resolved | `"hit"` |
| `cheatsheet_entry` | string \| null | Section heading that matched, or null | `"Async Patterns"` |
| `time_ms` | integer | Milliseconds to resolve | `245` |
| `spec` | string (optional) | Spec name if driven by spec requirement | `"forge-launch"` |
| `verification_level` | `"L0" \| "L1" \| "L2" \| "L3"` | Claimed verification level | `"L1"` |
| `confidence` | float (0.0–1.0) | Agent's confidence in answer | `0.85` |
| `chars_consumed` | integer | Bytes of cheatsheet actually used | `1240` |

**Semantics of `resolved_via`**:

- **`hit`**: Agent found exactly what it needed in the cheatsheet, used it directly, NO API call. Cache win.
- **`miss`**: Agent looked at cheatsheet, found nothing useful, fell back to API or gave up. Signal for expansion.
- **`partial`**: Agent found relevant info but incomplete. May or may not have called API next.
- **`live-api`**: Agent consulted cheatsheet AND called live API to verify/extend. Cheatsheet + API hit.

### Example Events

**Hit:**
```json
{"ts":"2026-05-02T14:30:15Z","agent":"claude","project":"tillandsias","cheatsheet":"languages/rust.md","query":"tokio::select! with timeout","resolved_via":"hit","cheatsheet_entry":"async-patterns","time_ms":145,"spec":"forge-launch","verification_level":"L1","confidence":0.95,"chars_consumed":1280}
```

**Miss:**
```json
{"ts":"2026-05-02T14:31:02Z","agent":"opencode","project":"my-app","cheatsheet":"languages/typescript.md","query":"TypeScript 5.7 const type parameters","resolved_via":"miss","cheatsheet_entry":null,"time_ms":320,"spec":null,"verification_level":"L0","confidence":0.0,"chars_consumed":0}
```

**Live-API (cheatsheet + verification):**
```json
{"ts":"2026-05-02T14:33:18Z","agent":"claude","project":"ai-way","cheatsheet":"runtime/local-inference.md","query":"ollama embedding model token limits","resolved_via":"live-api","cheatsheet_entry":"model-limits","time_ms":505,"spec":null,"verification_level":"L1","confidence":0.8,"chars_consumed":2156}
```

---

## Metrics Aggregation (Pseudocode)

After a session ends, the host operator (or CI pipeline) runs:

```bash
scripts/analyze-cheatsheet-metrics.sh \
  --input ~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl \
  --output cheatsheet-metrics-report.jsonl
```

### Aggregation Logic

For each unique `(cheatsheet, entry)` pair:

1. **Count outcomes** across all events:
   - `hits` = events where `resolved_via == "hit"`
   - `misses` = events where `resolved_via == "miss"`
   - `partials` = events where `resolved_via == "partial"`
   - `live_api_uses` = events where `resolved_via == "live-api"` (count as hits for scoring)

2. **Compute hit rate**:
   ```
   hit_rate = hits / (hits + misses + partials)
   ```

3. **Track spec bindings**:
   ```
   spec_binding_count = count of unique specs that cite this entry
   ```

4. **Measure size**:
   ```
   total_chars = sum of all chars_consumed for this entry
   ```

5. **Track freshness**:
   ```
   last_used = max timestamp across all events for this entry
   ```

6. **Compute score** (see below)

7. **Recommend action** based on score and signals

### Scoring Function (from Monotonic Reduction YAML)

```
score = w1 * normalized_hits
      + w2 * spec_binding_strength
      + w3 * recency_decay
      + w4 * verification_success
      - w5 * size_cost
```

**Weights (v1.0 defaults)**:

| Weight | Value | Meaning |
|--------|-------|---------|
| `w1` (hit rate) | 0.30 | Primary signal of utility |
| `w2` (spec binding) | 0.20 | Strong indicator of importance |
| `w3` (recency) | 0.15 | Recent use is signal of relevance |
| `w4` (verification success) | 0.25 | Success at claimed L-level matters |
| `w5` (size cost) | 0.10 | Minor penalty for large entries |

**Component Definitions**:

```
normalized_hits = hits / (hits + misses + partials)
                  Range: 0.0–1.0

spec_binding_strength = (spec_count + 1) / (spec_count + 2)
                        Laplace-smoothed, saturates at 1.0
                        0 specs → 0.5; 1+ specs → 0.67+

recency_decay = 1.0 / (1.0 + age_days / 7)
                Half-life: 7 days
                Today: 1.0; 49 days old: 0.5

verification_success = success_count / total_lookups
                       (Laplace-smoothed with +1/+2)
                       High if entry resolves queries at claimed level

size_cost = chars_consumed / 10000
            Normalized 0.0–1.0 range
            <1KB: ~0.1; >10KB: 1.0
```

**Score Interpretation**:

- **0.8–1.0**: Excellent. Protect, prioritize, cite in specs.
- **0.6–0.8**: Good. Stable, low maintenance.
- **0.4–0.6**: Mid-range. May need adjustment.
- **0.2–0.4**: Weak. Candidates for deletion or expansion.
- **<0.2**: Poor. Delete if not spec-bound.

---

## Compaction Actions

The aggregation script recommends one action per entry:

### 1. EXPAND (High Misses + Spec-Bound)

**Condition**:
```
hit_rate < 0.3 AND spec_bindings > 0
```

**What to do**:
- Identify top N misses (which queries failed?)
- Manually patch the entry to cover missed cases
- Re-run metrics after patch to verify hit rate improves

**Example**:
```
Entry: languages/rust.md/async-patterns/select-with-timeout
Hits: 3, Misses: 12 (20% hit rate)
Spec bindings: 2 (forge-launch, async-runtime)

Top misses:
  - "select with timeout AND channels" (3 occurrences)
  - "select nested" (2 occurrences)
  - "select with guard clauses" (2 occurrences)

Action: Expand entry to cover channel patterns and guards.
Expected outcome: 25% hit rate → 75%+ hit rate
```

### 2. COMPACT (Stable + High Success)

**Condition**:
```
hit_rate > 0.8 AND misses < 3 AND score > 0.65
```

**What to do**:
- Identify redundancy (repeated examples, boilerplate)
- Compress without losing L1 success rate
- Test: re-run metrics after; if hit_rate drops, rollback

**Example**:
```
Entry: build/cargo.md/workspace-monorepo-patterns
Hits: 28, Misses: 1 (97% hit rate)
Current size: 8.4 KB
Redundancy: 4 workspace examples with similar patterns

Action: Compress to 1 canonical example + reference.
Expected outcome: 8.4 KB → 6.2 KB (26% reduction)
Success criterion: Hit rate ≥ 95%
```

**Rollback Checklist**:
```bash
# Before
metrics-before=$(scripts/analyze-cheatsheet-metrics.sh)
before-score=$(echo "$metrics-before" | jq '.score')

# Edit
vim cheatsheets/build/cargo.md

# Test (run cargo tests that exercise the cheatsheet)
cargo test cheatsheet_lookups

# After
metrics-after=$(scripts/analyze-cheatsheet-metrics.sh)
after-score=$(echo "$metrics-after" | jq '.score')

# Verify score didn't drop >5%
if (( $(echo "$after-score < $before-score * 0.95" | bc -l) )); then
  echo "ROLLBACK: score degraded"
  git restore cheatsheets/build/cargo.md
fi
```

### 3. DELETE (Low Score + No Spec Binding)

**Condition**:
```
hit_rate < 0.3 AND spec_bindings == 0 AND score < 0.2
```

**What to do**:
- Leave a `@tombstone obsolete:entry-name` marker (per CLAUDE.md)
- Remove the entry from markdown
- Commit with reasoning
- Mark for deletion after 3 releases

**Example**:
```markdown
<!--
@tombstone obsolete:perl-5-x-patterns
Removed in 0.1.170.1. Zero hits in 100+ sessions.
No spec binding. Perl implementation never happened.
Safe to delete after 0.1.170.4.
-->
```

### 4. PROTECT (High Score OR High Spec Criticality)

**Condition**:
```
score > 0.65 OR spec_bindings > 3
```

**What to do**:
- Mark as critical in cheatsheet metadata
- Ensure any refactoring includes regression testing
- Prioritize this entry when L-level verification fails

**Example**:
```markdown
## Async Context Variables

**PROTECTED ENTRY** (criticality: high, score: 0.81, cited by 4 specs)

Content...
```

---

## Implementation Roadmap

### Phase 4.1: Event Schema & Agent Hooks (Weeks 1–2)

- [ ] Finalize event schema (this document)
- [ ] Add logging wrapper functions to agent code
- [ ] Test: emit sample events, verify JSONL format
- [ ] Document in `cheatsheets/observability/cheatsheet-metrics.md`

**Deliverable**: Agents emit valid JSONL to external-logs; no parsing/aggregation yet.

### Phase 4.2: Aggregation Script (Weeks 3–4)

- [ ] Implement `scripts/analyze-cheatsheet-metrics.sh` (bash + jq)
- [ ] Parse JSONL, aggregate by (cheatsheet, entry)
- [ ] Compute scores per entry
- [ ] Generate `cheatsheet-metrics-report.jsonl`
- [ ] Test with synthetic event data

**Deliverable**: Script produces valid scored report; no recommendations yet.

### Phase 4.3: Recommendation Engine (Weeks 5–6)

- [ ] Implement EXPAND/COMPACT/DELETE/PROTECT logic
- [ ] Add human-friendly summary output
- [ ] Create manual compaction guide (process doc)
- [ ] Test recommendations against known cases

**Deliverable**: Script emits actionable recommendations; human reviews and applies them manually.

### Phase 4.4: CI Integration (Weeks 7–8)

- [ ] Create `scripts/ci-cheatsheet-validation.sh` for CI pipeline
- [ ] Add checks for orphaned/stale entries
- [ ] Add checks for verification mismatches
- [ ] Document in CLAUDE.md

**Deliverable**: CI warns on metrics anomalies; no blocking (warnings only in Phase 4).

---

## Hard Boundaries

### 1. **Zero Instrumentation in Released Code**

The tray binary (deployed to users) has:
- ✅ Zero metrics collection
- ✅ Zero telemetry hooks
- ✅ Zero calls to logging middleware
- ✅ Zero knowledge of the external-logs directory

Metrics collection happens ONLY inside forge containers (development-time).

**Verification**: `cargo build --release` must not include any `cheatsheet_event`, `log_lookup`, or `metrics_` code paths. CI check: scan release binary for these symbols; fail if found.

### 2. **Post-Session Analysis Only**

- No real-time scoring during agent execution
- No in-memory metrics state
- No metrics database
- Analysis runs AFTER agents exit the container

**Why**: Zero performance impact. Agents don't wait for metrics. Context doesn't leak metrics state.

### 3. **JSONL Append-Only Format**

- Events never overwrite; only append
- Phase 1 auditor handles rotation (10 MB cap)
- No in-container parsing or aggregation
- All aggregation happens post-session on host

**Why**: No race conditions between multiple agents. No complex serialization in containers.

### 4. **External-Logs Infrastructure (No New Infrastructure)**

- Metrics use the Phase 1 producer/consumer mount model
- No new environment variables (reuse `TILLANDSIAS_EXTERNAL_LOGS`)
- No new tray code (auditor already watches the file)
- No new container types

**Why**: Maximum leverage of existing Phase 1 work. Minimal blast radius.

---

## Success Criteria for Phase 4

- [ ] Event schema is defined and documented (this document + `cheatsheets/observability/cheatsheet-metrics.md`)
- [ ] Agents can emit valid JSONL events to external-logs (integration test)
- [ ] Aggregation script produces valid scored reports (unit tests with synthetic data)
- [ ] Recommendation engine identifies EXPAND/COMPACT/DELETE/PROTECT correctly (manual test cases)
- [ ] Zero code in released tray touches metrics (CI check)
- [ ] Post-session analysis runs in <2 seconds for 1000 events (performance bench)
- [ ] Documentation is complete and operator-ready
- [ ] Manual compaction workflow is tested and documented

---

## Future Phases (5+)

### Phase 5: Automated Compaction

Once Phase 4 is production-stable, Phase 5 will:
- Automatically apply COMPACT transformations (with rollback on failure)
- Auto-delete low-scoring orphaned entries
- Auto-expand high-miss spec-bound entries (with human review)
- Trigger re-scoring in CI after changes

**Guard**: Automated actions only if score is high confidence (>0.9). Manual review for edge cases.

### Phase 5+: Convergence Loop

Once metrics and automated compaction are stable:
- Real-time L-level verification with CI feedback
- Cheatsheet refresh cadence based on staleness metrics
- Cross-cheatsheet deduplication detection
- Generative expansion (LLM-assisted, human-reviewed)

---

## References

- `Monotonic reduction of uncertainty under verifiable constraints.yaml` (project root) — canonical YAML with scoring function, verification levels, phase roadmap
- `cheatsheets/observability/cheatsheet-metrics.md` — detailed metrics system documentation
- `cheatsheets/runtime/external-logs.md` — Phase 1 infrastructure (producer/consumer model)
- `docs/strategy/external-logs-observability-plan.md` — Phase 1 architecture decisions
- `CLAUDE.md` — project conventions including @tombstone, verification levels, OpenSpec workflow
