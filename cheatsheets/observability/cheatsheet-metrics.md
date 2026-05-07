---
tags: [cheatsheet-metrics, observability, analytics, scoring, compaction, phase-4]
languages: []
since: 2026-05-02
last_verified: 2026-05-02
sources:
  - https://en.wikipedia.org/wiki/CRDT
  - https://en.wikipedia.org/wiki/Cache_(computing)#Replacement_policies
authority: high
status: design
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cheatsheet Metrics System — Phase 4 Design

@trace spec:cheatsheets-metrics-collection
@cheatsheet runtime/external-logs.md

**Use when**: you are designing or maintaining the cheatsheet metrics pipeline, which tracks how often agents successfully look up cheatsheet entries (hits), fall back to API calls (misses), and decide which entries to expand, compact, or delete.

## Provenance

- CRDT literature (Shapiro et al., "CRDTs: Consistency without concurrency control"): <https://en.wikipedia.org/wiki/CRDT>
- Cache replacement policies (LRU, LFU, adaptive): <https://en.wikipedia.org/wiki/Cache_(computing)#Replacement_policies>
- Weighted scoring in information retrieval: <https://en.wikipedia.org/wiki/Okapi_BM25>
- **Last updated:** 2026-05-02

---

## Phase 4 Context

**From the Monotonic Reduction YAML** (`openspec_system.cheatsheet_operations`), Phase 4 introduces metrics collection infrastructure that powers automated cheatsheet management. The system tracks:

1. **Hits** — agent resolved query from cheatsheet entry without fallback
2. **Misses** — agent looked at cheatsheet, found nothing, fell back to API/live lookup
3. **Spec bindings** — how many active specs cite each cheatsheet entry
4. **Verification deltas** — success rate changes at each verification level (L0-L3)
5. **Token size** — cost (in context window bytes) of keeping entry in loaded cache

These signals feed a unified **scoring function** that drives compaction decisions:

```
score = w1 * normalized_hits
      + w2 * spec_binding_strength
      + w3 * recency_decay
      + w4 * verification_success
      - w5 * size_cost
```

### Key Design Constraint

**Zero instrumentation in released code.** The tray binary (deployed to users) has zero metrics collection, zero telemetry, zero runtime hooks. Metrics exist ONLY inside forge containers, collected by agents during development sessions. The hard boundary:

- **Inside forge (agent-side, development)**: agents log cheatsheet lookup events to `external-logs/cheatsheet-telemetry/lookups.jsonl` (append-only).
- **On host (post-session analysis)**: scripts read the JSONL and compute aggregated metrics per cheatsheet.
- **Released tray**: zero knowledge of metrics, zero collection, zero calls to analytics.

---

## Architecture: Agent-Side Logging

### Event Collection Point

Agents (claude, opencode, opsx) running inside forge containers emit one event per cheatsheet lookup. The event is appended to:

```
/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl
```

(Alias: `$TILLANDSIAS_EXTERNAL_LOGS/cheatsheet-telemetry/lookups.jsonl`)

### Who Logs Events

| Agent | When | How |
|-------|------|-----|
| **claude-code** | After querying a cheatsheet file via `cat $TILLANDSIAS_CHEATSHEETS/<path>` | Wrapper function or shell hook logs event before returning content to agent |
| **opencode** | After `require('cheatsheets/<path>')` or direct file read | JavaScript/TypeScript middleware logs event |
| **opsx** (OpenSpec CLI) | After consulting a cheatsheet during proposal/design generation | Bash wrapper script logs event |

All agents use the same event schema (below).

### Why External-Logs Infrastructure Exists Already

Phase 1 (traces) created the `external-logs.yaml` manifests and the producer/consumer mount model. The forge is already a **producer** of `cheatsheet-telemetry` (declared in `images/default/external-logs.yaml`). Phase 4 leverages this existing infrastructure — agents simply emit events that the tray auditor already knows to rotate and preserve.

**No new infrastructure in tray binary needed.** The auditor already:
- Monitors `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl`
- Rotates files at 10 MB
- Flags leaks if new files appear
- Runs every 60 seconds

---

## Event Schema

Each agent logs one line per cheatsheet lookup. The line is a JSON object following this schema:

```json
{
  "ts": "ISO 8601 string (UTC)",
  "agent": "claude | opencode | opsx",
  "project": "project directory name (e.g., 'my-app')",
  "cheatsheet": "relative path from /opt/cheatsheets/ (e.g., 'languages/python.md')",
  "query": "what the agent asked (string, unstructured)",
  "resolved_via": "hit | miss | partial | live-api",
  "cheatsheet_entry": "section heading or key that matched (or null for miss)",
  "time_ms": "milliseconds to resolve (integer)",
  "spec": "spec name if lookup was spec-driven (string, optional)",
  "verification_level": "L0 | L1 | L2 | L3 (what level the code claimed)",
  "confidence": "0.0-1.0 (agent's confidence in the answer, 0 if miss)",
  "chars_consumed": "how many bytes the agent actually used from the cheatsheet"
}
```

### Field Semantics

| Field | Type | Meaning | Example |
|-------|------|---------|---------|
| `ts` | ISO 8601 | Event timestamp, UTC, set by agent | `"2026-05-02T14:30:00Z"` |
| `agent` | enum | Which agent looked it up | `"claude"` |
| `project` | string | Project name (from container env or cwd) | `"tillandsias"` |
| `cheatsheet` | string | Path under `/opt/cheatsheets/` | `"languages/rust.md"` |
| `query` | string | What the agent searched for (human-readable) | `"tokio::select! with partial timeout"` |
| `resolved_via` | enum | How it resolved: **`hit`** = entry matched and satisfied the query; **`miss`** = cheatsheet didn't help, agent fell back to API call or got no answer; **`partial`** = entry was relevant but incomplete; **`live-api`** = agent looked at cheatsheet first, then called an API to verify/extend | `"hit"` |
| `cheatsheet_entry` | string | Section heading or key that matched, or null if miss | `"Async Context Variables"` |
| `time_ms` | integer | Milliseconds from query to resolution (agent-local clock) | `245` |
| `spec` | string | Spec name if this lookup was driven by spec requirement (optional) | `"cheatsheets-license-tiered"` |
| `verification_level` | enum | What verification level the code claimed when it made the cheatsheet call | `"L1"` |
| `confidence` | float | 0.0–1.0, agent's confidence the answer is correct; 0 for misses | `0.85` |
| `chars_consumed` | integer | How many bytes of the cheatsheet entry the agent actually read/used | `1240` |

### Resolved_via Semantics

- **`hit`**: The agent found exactly what it needed in the cheatsheet entry, used it directly, did NOT call an API. This is the cache win case.
- **`miss`**: The agent looked at the cheatsheet, found nothing useful, and either gave up or fell back to a live API call. This signals the entry is incomplete or stale.
- **`partial`**: The agent found relevant information but it was incomplete (e.g., "covered Python 3.10, but I need 3.13 specifics"). The agent may or may not have called an API next. Partial hits count as partial success in compaction scoring.
- **`live-api`**: The agent consulted the cheatsheet AND made a live API call to verify or extend the information. This is a "cheatsheet + API" hit — the cheatsheet contributed useful context but was not sufficient alone.

### Example Events

**Hit case:**
```json
{"ts":"2026-05-02T14:30:15Z","agent":"claude","project":"tillandsias","cheatsheet":"languages/rust.md","query":"tokio::select! with timeout branch","resolved_via":"hit","cheatsheet_entry":"async-patterns/select-with-timeout","time_ms":145,"spec":"forge-launch","verification_level":"L1","confidence":0.95,"chars_consumed":1280}
```

**Miss case:**
```json
{"ts":"2026-05-02T14:31:02Z","agent":"opencode","project":"my-app","cheatsheet":"languages/typescript.md","query":"TypeScript 5.7 const type parameters","resolved_via":"miss","cheatsheet_entry":null,"time_ms":320,"spec":null,"verification_level":"L0","confidence":0.0,"chars_consumed":0}
```

**Partial hit case:**
```json
{"ts":"2026-05-02T14:32:44Z","agent":"opsx","project":"tillandsias","cheatsheet":"build/cargo.md","query":"cargo workspace with alternative registries","resolved_via":"partial","cheatsheet_entry":"registries-in-workspace","time_ms":210,"spec":"cheatsheets-license-tiered","verification_level":"L2","confidence":0.6,"chars_consumed":842}
```

**Live-API case:**
```json
{"ts":"2026-05-02T14:33:18Z","agent":"claude","project":"ai-way","cheatsheet":"runtime/local-inference.md","query":"ollama embedding model token limits","resolved_via":"live-api","cheatsheet_entry":"model-limits","time_ms":505,"spec":null,"verification_level":"L1","confidence":0.8,"chars_consumed":2156}
```

---

## Metrics Aggregation (Host-Side, Post-Session)

### Data Collection Window

After an agent exits a forge container, the JSONL event stream is closed. The host-side analytics pipeline reads the accumulated events and computes metrics per cheatsheet.

**Timing**: Post-session analysis runs:
- **Explicit**: `scripts/analyze-cheatsheet-metrics.sh` invoked by user or CI
- **Implicit**: Optional daemon that polls `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/` and summarizes completed sessions

This is **never real-time** and **never blocks agent execution**.

### Aggregation Logic (Pseudocode)

```bash
#!/bin/bash
# scripts/analyze-cheatsheet-metrics.sh
# @trace spec:cheatsheets-metrics-collection
#
# Post-session metrics aggregation — reads JSONL event stream from external-logs,
# computes per-cheatsheet hit/miss/partial rates, and scores each entry.

declare -A hit_count miss_count partial_count spec_binding chars_by_entry
declare -A L0_success L1_success L2_success L3_success
declare -A entry_size_bytes entry_last_updated

# Input: all events from the session (or multiple sessions)
events_jsonl="$TILLANDSIAS_EXTERNAL_LOGS/cheatsheet-telemetry/lookups.jsonl"

# Aggregate by cheatsheet and entry
while IFS= read -r line; do
  # Parse JSON fields (use jq for production)
  cheatsheet=$(echo "$line" | jq -r '.cheatsheet')
  resolved=$(echo "$line" | jq -r '.resolved_via')
  entry=$(echo "$line" | jq -r '.cheatsheet_entry // "unknown"')
  spec=$(echo "$line" | jq -r '.spec // null')
  level=$(echo "$line" | jq -r '.verification_level')
  chars=$(echo "$line" | jq -r '.chars_consumed')
  ts=$(echo "$line" | jq -r '.ts')

  key="${cheatsheet}/${entry}"

  # Count resolution outcomes
  case "$resolved" in
    hit)        ((hit_count[$key]++)) ;;
    miss)       ((miss_count[$key]++)) ;;
    partial)    ((partial_count[$key]++)) ;;
    live-api)   ((hit_count[$key]++)) ;;  # counts as hit for scoring
  esac

  # Track spec bindings (if this entry is cited by a spec)
  if [[ -n "$spec" && "$spec" != "null" ]]; then
    ((spec_binding[$key]++))
  fi

  # Accumulate bytes consumed
  ((chars_by_entry[$key] += chars))

  # Track verification level success rates
  if [[ "$resolved" == "hit" || "$resolved" == "partial" || "$resolved" == "live-api" ]]; then
    case "$level" in
      L0)  ((L0_success[$key]++)) ;;
      L1)  ((L1_success[$key]++)) ;;
      L2)  ((L2_success[$key]++)) ;;
      L3)  ((L3_success[$key]++)) ;;
    esac
  fi

  # Update freshness
  entry_last_updated[$key]="$ts"
done < "$events_jsonl"

# Compute scores per entry
declare -A scores recommendations
for key in "${!hit_count[@]}"; do
  h=${hit_count[$key]}
  m=${miss_count[$key]:-0}
  p=${partial_count[$key]:-0}
  total=$((h + m + p))
  
  # Normalized hit rate (0.0 to 1.0)
  hit_rate=$(( total > 0 ? h * 10000 / total : 0 ))  # Fixed-point for shell math
  hit_rate=$(echo "scale=4; $hit_rate / 10000" | bc)

  # Spec binding strength (0.0 to 1.0, capped at 1.0)
  binding_count=${spec_binding[$key]:-0}
  binding_strength=$(echo "scale=4; ($binding_count + 1) / ($binding_count + 2)" | bc)

  # Recency decay (entries used recently get higher score)
  now=$(date -u +%s)
  last_ts=${entry_last_updated[$key]}
  last_epoch=$(date -u -d "$last_ts" +%s 2>/dev/null || echo "$now")
  age_days=$(( (now - last_epoch) / 86400 ))
  recency=$(echo "scale=4; 1.0 / (1.0 + $age_days / 7)" | bc)

  # Verification success = proportion of successes at claimed levels
  L_total=$((L0_success[$key]:-0 + L1_success[$key]:-0 + L2_success[$key]:-0 + L3_success[$key]:-0))
  L_success=$((h + p))  # hits + partials count as success
  v_success=$(echo "scale=4; ($L_success + 1) / ($L_total + 2)" | bc)

  # Size cost (penalize large entries proportionally)
  size_bytes=${chars_by_entry[$key]}
  size_cost=$(echo "scale=4; $size_bytes / 10000" | bc)

  # Scoring function (from YAML, normalized weights)
  w1=0.30  # hit rate importance
  w2=0.20  # spec binding importance
  w3=0.15  # recency importance
  w4=0.25  # verification success importance
  w5=0.10  # size penalty importance

  score=$(echo "scale=4; \
    $w1 * $hit_rate + \
    $w2 * $binding_strength + \
    $w3 * $recency + \
    $w4 * $v_success - \
    $w5 * $size_cost" | bc)

  scores[$key]=$score

  # Recommend action based on score and signals
  if (( $(echo "$hit_rate < 0.3" | bc -l) )); then
    if (( $(echo "$binding_count == 0" | bc -l) )); then
      recommendations[$key]="DELETE (low hits, no spec binding)"
    else
      recommendations[$key]="EXPAND (high misses, spec-bound)"
    fi
  elif (( $(echo "$hit_rate > 0.8 && $m < 3" | bc -l) )); then
    recommendations[$key]="COMPACT (stable, high success)"
  else
    recommendations[$key]="PROTECT (mid-range, verify before change)"
  fi
done

# Output report (JSON for machine parsing, human summary for review)
echo "=== Cheatsheet Metrics Report ===" >&2
echo "Session: $events_jsonl" >&2
echo "Analyzed at: $(date -u)" >&2
echo "" >&2

# Machine-parseable JSON output
for key in "${!scores[@]}"; do
  cheatsheet="${key%/*}"
  entry="${key#*/}"
  score="${scores[$key]}"
  action="${recommendations[$key]}"
  
  jq -n \
    --arg cheatsheet "$cheatsheet" \
    --arg entry "$entry" \
    --arg score "$score" \
    --arg action "$action" \
    --arg hits "${hit_count[$key]:-0}" \
    --arg misses "${miss_count[$key]:-0}" \
    --arg partials "${partial_count[$key]:-0}" \
    '{
       cheatsheet,
       entry,
       score: ($score | tonumber),
       action,
       hits: ($hits | tonumber),
       misses: ($misses | tonumber),
       partials: ($partials | tonumber),
       spec_bindings: '${spec_binding[$key]:-0}',
       chars_consumed: '${chars_by_entry[$key]:-0}'
     }'
done | jq -s 'sort_by(.score) | reverse' > cheatsheet-metrics-report.jsonl

# Human-friendly summary (sorted by action)
echo "=== Recommendations ===" >&2
echo "" >&2
echo "DELETE (low utility, no specs):" >&2
for key in "${!recommendations[@]}"; do
  if [[ "${recommendations[$key]}" == DELETE* ]]; then
    echo "  ${key}: score=${scores[$key]}" >&2
  fi
done
echo "" >&2
echo "EXPAND (spec-driven, too many misses):" >&2
for key in "${!recommendations[@]}"; do
  if [[ "${recommendations[$key]}" == EXPAND* ]]; then
    echo "  ${key}: score=${scores[$key]}, hits=${hit_count[$key]:-0}, misses=${miss_count[$key]:-0}" >&2
  fi
done
echo "" >&2
echo "COMPACT (stable, high success rate):" >&2
for key in "${!recommendations[@]}"; do
  if [[ "${recommendations[$key]}" == COMPACT* ]]; then
    echo "  ${key}: score=${scores[$key]}, hit_rate=$(echo "scale=2; ${hit_count[$key]:-0} * 100 / (${hit_count[$key]:-0} + ${miss_count[$key]:-0} + ${partial_count[$key]:-0})" | bc)%" >&2
  fi
done

echo "" >&2
echo "Report written to: cheatsheet-metrics-report.jsonl" >&2
```

### Output Format

The aggregation script produces `cheatsheet-metrics-report.jsonl` with one line per entry:

```json
{
  "cheatsheet": "languages/rust.md",
  "entry": "async-patterns/select-with-timeout",
  "score": 0.72,
  "action": "PROTECT (mid-range, verify before change)",
  "hits": 14,
  "misses": 2,
  "partials": 1,
  "spec_bindings": 3,
  "chars_consumed": 5280
}
```

---

## Scoring Function

### Formula

From the YAML, with normalized weights:

```
score = w1 * normalized_hits
      + w2 * spec_binding_strength
      + w3 * recency_decay
      + w4 * verification_success
      - w5 * size_cost
```

### Weight Recommendations (v1.0)

| Weight | Default | Meaning |
|--------|---------|---------|
| `w1` | 0.30 | Hit rate is the primary signal; high hits = high utility |
| `w2` | 0.20 | Spec binding is a strong signal of importance; protect cited entries |
| `w3` | 0.15 | Recency favors entries used recently; stale entries get lower score |
| `w4` | 0.25 | Verification success matters nearly as much as hit rate; L3 > L2 > L1 > L0 |
| `w5` | 0.10 | Size cost is a minor penalty; prefer smaller entries if score is tied |

**Tuning**: Weights can be adjusted per-project via `.tillandsias/metrics.toml`:

```toml
[scoring]
w1 = 0.30  # hit_rate_weight
w2 = 0.20  # spec_binding_weight
w3 = 0.15  # recency_weight
w4 = 0.25  # verification_success_weight
w5 = 0.10  # size_cost_weight
```

### Component Definitions

**Normalized Hits** (`w1 * normalized_hits`):
```
normalized_hits = hits / (hits + misses + partials)
# Range: 0.0 (all misses) to 1.0 (all hits)
```

**Spec Binding Strength** (`w2 * spec_binding_strength`):
```
spec_binding_strength = (spec_bindings + 1) / (spec_bindings + 2)
# Smoothed by Laplace to avoid zero-division.
# 0 specs → 0.5; 1 spec → 0.67; 2+ specs → 0.75+
# Saturates toward 1.0, never reaches it (always penalizes low-binding entries slightly).
```

**Recency Decay** (`w3 * recency_decay`):
```
age_days = (now - last_used_timestamp) / 86400
recency_decay = 1.0 / (1.0 + age_days / 7)
# Range: 0.5 (49 days old) to 1.0 (used today)
# Half-life: 7 days. Entries unused >30 days score <0.15 from this component alone.
```

**Verification Success** (`w4 * verification_success`):
```
verification_success = (L0_success + L1_success + L2_success + L3_success + 1)
                     / (total_lookups + 2)
# Laplace-smoothed to prevent over-penalizing rarely-looked entries.
# High hit/partial rate at any claimed level → score rises.
# High miss rate → score falls.
```

**Size Cost** (`w5 * size_cost`):
```
size_cost = chars_consumed / 10000
# Normalized to a 0.0–1.0 range (entries >10KB get penalized ~0.1 points).
# Small entries (< 1KB) get nearly zero penalty.
```

### Score Interpretation

- **0.8–1.0**: Excellent entries. Protect, cite in specs, consider as reference implementations.
- **0.6–0.8**: Good entries. Stable, low maintenance required.
- **0.4–0.6**: Mid-range entries. May need expansion or contraction depending on signals.
- **0.2–0.4**: Weak entries. Candidates for compact-on-failure testing or expansion if spec-bound.
- **<0.2**: Poor entries. Delete if not spec-bound; expand if spec-bound but missing coverage.

---

## Compaction Strategy

### Actions

The aggregation script recommends one of four actions per entry:

#### 1. **EXPAND** (High misses + spec-bound)

**Condition**:
```
hit_rate < 0.3 AND spec_bindings > 0
```

**Action**:
- Identify top N misses (query strings that failed)
- Manually patch the entry to cover the missed cases
- Re-run metrics after patch to verify hit rate increases

**Example**:
```
Entry: languages/rust.md/async-patterns/select-with-timeout
Before: 3 hits, 12 misses (20% hit rate), cited by 2 specs
Query misses:
  - "select with timeout AND channels" (3 occurrences)
  - "select nested" (2 occurrences)
  - "select with guard clauses" (2 occurrences)
Recommendation: Expand to cover channel patterns and guard clauses
```

#### 2. **COMPACT** (Stable + high success rate)

**Condition**:
```
hit_rate > 0.8 AND misses < 3 AND score > 0.65
```

**Action**:
- Identify redundancy within the entry (repeated examples, boilerplate)
- Compress without losing L1 success rate (cheatsheet-only resolution)
- Test: re-run metrics after compaction; if hit_rate drops, rollback

**Example**:
```
Entry: build/cargo.md/workspace-monorepo-patterns
Before: 28 hits, 1 miss (97% hit rate), 8.4 KB
Redundancy detected: 4 workspace examples with similar patterns
Compact to: 1 canonical example + reference to Cargo book
After: 6.2 KB, maintained 97% hit rate
Savings: 2.2 KB per user session (estimated 5% context window reduction)
```

#### 3. **DELETE** (Low utility + no spec binding)

**Condition**:
```
hit_rate < 0.3 AND spec_bindings == 0 AND score < 0.2
```

**Action**:
- Leave a `@tombstone obsolete:entry-name` marker in the parent cheatsheet file
- Remove the entry from the markdown
- Commit with reasoning

**Example**:
```markdown
<!--
@tombstone obsolete:perl-5-x-patterns
Removed 2026-05-02. Zero hits in 100+ sessions. No spec binding.
Perl patterns were considered but never implemented. Safe to delete.
-->
```

#### 4. **PROTECT** (High score OR high spec criticality)

**Condition**:
```
score > 0.65 OR spec_bindings > 3
```

**Action**:
- Mark as critical in cheatsheet metadata
- Ensure any refactoring includes regression testing
- Prioritize this entry when L-level verification failures occur

**Example**:
```markdown
## Async Context Variables

**PROTECTED ENTRY** (criticality: high, score: 0.81, cited by 4 specs)

[Entry content...]
```

### Rollback Policy

For COMPACT and EXPAND actions, always follow this pattern:

```bash
# 1. Take baseline metrics
metrics-before=$(scripts/analyze-cheatsheet-metrics.sh --cheatsheet "languages/rust.md")

# 2. Make the change
vim cheatsheets/languages/rust.md

# 3. Simulate agent lookup (run test suite or manual spot checks)
cargo test cheatsheet_lookups

# 4. Re-run metrics
metrics-after=$(scripts/analyze-cheatsheet-metrics.sh --cheatsheet "languages/rust.md")

# 5. Compare L1 success rate
before_l1=$(echo "$metrics-before" | jq '.entries[] | select(.level == "L1") | .success_rate')
after_l1=$(echo "$metrics-after" | jq '.entries[] | select(.level == "L1") | .success_rate')

if (( $(echo "$after_l1 < $before_l1 * 0.95" | bc -l) )); then
  echo "FAILURE: L1 success rate dropped >5%. Rollback recommended."
  git restore cheatsheets/languages/rust.md
else
  echo "SUCCESS: L1 success rate maintained or improved."
  git add cheatsheets/languages/rust.md
fi
```

---

## Integration with External-Logs

The Phase 1 infrastructure already supports cheatsheet-telemetry as a producer role.

**No changes needed to `external-logs.md` or `images/default/external-logs.yaml`.** The event schema described above is compatible with the existing JSONL format.

### Verification Checklist

- [x] `images/default/external-logs.yaml` declares `cheatsheet-telemetry` role
- [x] `$TILLANDSIAS_EXTERNAL_LOGS/cheatsheet-telemetry/lookups.jsonl` is created by forge container launcher
- [x] Tray auditor monitors the file every 60 s, enforces 10 MB rotation
- [x] Agents have RW mount at `/var/log/tillandsias/external/cheatsheet-telemetry/`
- [ ] Agent code wraps all cheatsheet reads with event logging (implementation, Phase 4 onwards)

---

## Metrics Retention & Archival

### On-Host Storage

```
~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl
```

- **Rotation**: Every 10 MB, tray auditor truncates oldest 50%
- **Retention**: Across container restarts and project sessions (persistent)
- **Access**: `tillandsias-logs ls / tail / combine` commands (already supported by Phase 1)

### Archival (Future)

Post-session analysis can write a compressed summary to `.tillandsias/metrics.archive`:

```json
{
  "session_id": "uuid",
  "start_ts": "2026-05-02T10:00:00Z",
  "end_ts": "2026-05-02T14:30:00Z",
  "project": "tillandsias",
  "entry_count": 127,
  "hit_count": 342,
  "miss_count": 48,
  "total_chars_consumed": 156_480,
  "top_5_entries_by_score": [
    { "cheatsheet": "languages/rust.md", "entry": "async-patterns", "score": 0.89 },
    ...
  ]
}
```

This is optional and intended for cross-session trending (e.g., "did cheatsheet quality improve after last week's refresh?").

---

## Metrics for CI Validation

The CI validator (Phase 2 onwards) can use cheatsheet metrics to detect:

1. **Orphaned entries** (no hits, no specs) should be flagged for deletion
2. **Stale entries** (last used >30 days ago, no spec binding) should be refreshed
3. **Verification mismatches** (claimed L2, observed L0 success rate) should downgrade claims

**New CI checks** (added in Phase 3–4):

```bash
# In CI pipeline, after accumulating a week of metrics:
scripts/ci-cheatsheet-validation.sh \
  --source ~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/lookups.jsonl \
  --fail-on orphaned \
  --warn-on stale \
  --warn-on verification-mismatch
```

Exit code: 0 if clean, >0 if failures found.

---

## Sources of Truth

- `cheatsheets/runtime/external-logs.md` — Phase 1 infrastructure (cheatsheet-telemetry producer, event layout)
- `images/default/external-logs.yaml` — manifest declaring cheatsheet-telemetry role and lookups.jsonl file
- `Monotonic reduction of uncertainty under verifiable constraints.yaml` (project root) — scoring function, verification levels, compaction actions
- `docs/strategy/external-logs-observability-plan.md` — architectural decision record for Phase 1 external logs layer
