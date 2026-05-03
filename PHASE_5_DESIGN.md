# Phase 5 Design: Automated Compaction, Eviction, and Convergence Loop

@trace spec:convergence-engine, spec:automated-cheatsheet-compaction, spec:convergence-health-metrics

**Status**: Design document. Implementation begins after Phase 4 (cheatsheet metrics) is production-stable.

**Timeline**: Phase 5 operates as a closed-loop system that continuously reduces drift. Phase 5.0 is manual (humans review recommendations), Phase 5.1+ brings safe automation with rollback guarantees.

**Author**: Claude (Agent)  
**Provenance**: `Monotonic reduction of uncertainty under verifiable constraints.yaml`

---

## Executive Summary

Phase 5 closes the loop by **converging all prior phases into a unified fitness function that minimizes uncertainty**. Where Phase 4 measures cheatsheet quality (hits, misses, scores), Phase 5 **detects and quantifies drift** in three dimensions and applies automated corrective actions.

**The Three Drift Axes**:

1. **Δ(spec ↔ code)**: Annotations point to non-existent specs, or code doesn't implement what specs declare
2. **Δ(code ↔ cheatsheet)**: Code uses tool X version Y, but cheatsheet documents version Z (tool upgrade, deprecated APIs)
3. **Δ(cheatsheet ↔ reality)**: Cheatsheet cites upstream source, but source has moved, changed, or API has breaking change

**Phase 5 Innovation**: A **convergence engine** that measures each delta as a scalar signal (0.0 = maximal drift, 1.0 = perfect alignment), then combines them into a single **convergence health score** (0–100%). When convergence health drops below thresholds, Phase 5 automatically:

- **Phase 5.0 (Manual)**: Flags degradation, humans review recommendations
- **Phase 5.1 (Safe automation)**: Auto-compacts stable entries (dry-run first, rollback on failure)
- **Phase 5.2 (Full automation)**: Auto-deletes orphaned entries (with 3-release `@tombstone` retention), auto-expands high-miss specs

**Key Constraint**: All Phase 5 operations happen **post-session, asynchronously**. Zero runtime impact on the tray or agents. Convergence health is a measure of "system stability", not a real-time metric.

---

## 1. Drift Detection & Measurement

### 1.1 Δ(spec ↔ code): Annotation-to-Intent Alignment

**What it measures**: Do code annotations match spec intent? Or are annotations orphaned?

**Signals**:

| Signal | Measurement | Target | Misalignment Indicator |
|--------|-------------|--------|------------------------|
| Spec existence | File exists at `openspec/specs/{spec-name}/spec.md` | 1.0 | Annotation points to non-existent spec (Phase 2 catches, rare) |
| Public function coverage | `(functions with @trace) / (total public fns)` | 1.0 | Function has no spec binding (unmaintained code path) |
| Spec activeness | Spec status is "active" not "deprecated" or "obsolete" | 1.0 | Code references deprecated spec (migration debt) |
| Cheatsheet binding | Spec has `## Sources of Truth` section citing cheatsheets OR spec name appears in a cheatsheet | 0.8+ | Spec defined but knowledge is missing (gap) |

**Scoring Function**:

```
Δ_spec_code = 1.0 - (
    0.35 * spec_exists +
    0.30 * public_fn_coverage +
    0.20 * spec_activeness +
    0.15 * cheatsheet_binding
)
```

**Range**: 0.0 (perfect) to 1.0 (maximal drift)

**Examples**:

- **All signals 1.0** → Δ = 0.0 (perfect alignment)
- **spec_exists = 0.0** (function annotated with non-existent spec) → Δ ≥ 0.35 (critical)
- **public_fn_coverage = 0.7** (30% of public functions unannotated) → Δ ≥ 0.09 (minor)
- **spec_activeness = 0.0** (code uses deprecated spec) → Δ ≥ 0.20 (warning-level)

**CI Integration**: Phase 2 validator already catches `spec_exists` failures. Phase 5 adds:
- Monthly audit: `scripts/audit-public-fn-coverage.sh` (report % unannotated)
- Flag deprecated specs in use: `cargo grep 'spec:.*-deprecated'` + cross-check `openspec/specs/*/spec.md` status field
- Cheatsheet binding: cross-reference specs against cheatsheet `## Sources of Truth` sections

---

### 1.2 Δ(code ↔ cheatsheet): Tool/Language Version Mismatch

**What it measures**: Is the cheatsheet's documented API version compatible with what the code actually uses?

**Signals** (from Phase 4 metrics):

| Signal | Measurement | Target | Misalignment Indicator |
|--------|-------------|--------|------------------------|
| Hit rate | `hits / (hits + misses + partials)` | 0.8+ | <30%: code uses API not in cheatsheet; gaps in coverage |
| API test success | Integration test passes against live API | 1.0 (L2+) | Test fails: cheatsheet docs outdated API surface |
| Verification L-level | Claimed level matches actual verification | 1.0 | L2 claimed, no API test: either test missing or cheatsheet wrong |
| Dependency recency | Cheatsheet's pinned versions match `Cargo.lock` or image `Containerfile` | 1.0 | Cheatsheet documents old version; code has moved to new version |

**Scoring Function**:

```
Δ_code_cheatsheet = 1.0 - (
    0.40 * normalized_hit_rate +
    0.30 * api_test_success +
    0.20 * verification_level_match +
    0.10 * dependency_recency
)
```

**Range**: 0.0 (perfect) to 1.0 (maximal drift)

**Examples**:

- **hit_rate = 0.95, all tests pass, L2 matches** → Δ = 0.02 (excellent)
- **hit_rate = 0.2 (many misses), L2 claimed but no test** → Δ ≥ 0.50 (critical gap)
- **Cargo.lock bumped tokio to 1.35, cheatsheet still documents 1.30 patterns** → dependency_recency = 0.5, Δ ≥ 0.05 (minor, but detectable)
- **Integration test flakes 3/5 times against live API** → api_test_success = 0.4, Δ ≥ 0.18 (warning)

**Detection Method**:

1. **Hit rate anomaly** (Phase 4): If hit_rate drops >20% from baseline, flag for manual investigation
2. **Integration test CI failures**: Phase 3 validator logs test presence; Phase 5 tracks test pass/fail rate over time
3. **L-level mismatch**: Code declares L2 but cheatsheet missing → flag automatically
4. **Version pin drift**: Compare cheatsheet version comments against actual pins in project:
   ```bash
   # In cheatsheet: "tokio 1.30 with select!"
   # In Cargo.lock: tokio = "1.35"
   # Δ signal: recency_decay
   ```

---

### 1.3 Δ(cheatsheet ↔ reality): Upstream Source Staleness

**What it measures**: Are the cheatsheet's cited sources still accurate? Has the upstream API changed?

**Signals**:

| Signal | Measurement | Target | Misalignment Indicator |
|--------|-------------|--------|------------------------|
| URL resolution | Cite URLs return 200 OK | 1.0 | Dead link: source moved or deprecated |
| Content hash stability | Page content matches when last checked | 1.0 | Content changed: API docs updated, new features, breaking changes |
| Last-updated age | Days since cheatsheet was verified against sources | <90 days | >90 days old: stale, needs re-verification |
| Provenance presence | `## Provenance` section exists with ≥1 authoritative source | 1.0 | No sources: uncheckable claims |

**Scoring Function**:

```
Δ_cheatsheet_reality = 1.0 - (
    0.35 * url_health +
    0.30 * content_stability +
    0.25 * freshness_score +
    0.10 * provenance_presence
)
```

**Range**: 0.0 (perfect) to 1.0 (maximal drift)

**Freshness Score**:
```
freshness_score = 1.0 / (1.0 + (days_since_verified / 90))
  Example: Last verified 45 days ago → score = 1.0 / (1 + 45/90) = 0.67
```

**Examples**:

- **All URLs resolve, content unchanged, verified 30 days ago** → Δ = 0.05 (excellent)
- **URL 404s on two of three sources, never verified** → url_health ≤ 0.33, Δ ≥ 0.48 (critical)
- **No `## Provenance` section** → provenance_presence = 0.0, Δ ≥ 0.10 (minor but blockers acceptance)
- **Last updated 180 days ago** → freshness_score = 0.33, Δ ≥ 0.08 (warning-level)

**Detection Method**:

1. **Automated URL health check**: `scripts/check-cheatsheet-staleness.sh`
   ```bash
   for url in $(grep -E '^\s*-\s*\[' cheatsheets/**/*.md); do
     curl -s -o /dev/null -w "%{http_code}" "$url"  # 200? 404? timeout?
   done
   ```

2. **Content hash tracking**: Store hash of each source page at verification time
   ```
   # In cheatsheet metadata (optional YAML front-matter):
   ---
   sources:
     - url: https://rust-lang.org/...
       hash_at_last_check: abc123def456  # SHA256 of page content
       checked: 2026-05-02
   ---
   ```

3. **Last-updated age** (already tracked in `**Last updated:**` field)

4. **Provenance presence**: Phase 4 already enforces this; Phase 5 re-checks compliance

---

## 2. Convergence Health: Unified Fitness Function

### 2.1 Overall Convergence Score

**Combination** (weighted average of three drift axes):

```
Convergence Health = 100 * (1.0 - (
    0.40 * Δ_spec_code +
    0.35 * Δ_code_cheatsheet +
    0.25 * Δ_cheatsheet_reality
))
```

**Range**: 0–100 (higher is better)

**Interpretation**:

| Health | Status | Implication | Action |
|--------|--------|-------------|--------|
| 95–100 | 🟢 Optimal | Specs align with code, cheatsheets match code patterns, sources verified | Continue normal operation |
| 85–94 | 🟡 Healthy | Minor gaps, typical during development | Monitor, mark TODOs for next quarter |
| 75–84 | 🟠 Caution | Several spec-code mismatches or source verification backlog | Schedule compaction review |
| <75 | 🔴 Degraded | Critical drift in one or more dimensions | Immediate investigation required |

**Weight Justification**:
- **40% Δ_spec_code**: Specs are the source of truth; drift here undermines the entire system
- **35% Δ_code_cheatsheet**: Code-cheatsheet misalignment directly impacts agent correctness (hits/misses)
- **25% Δ_cheatsheet_reality**: Source staleness is a slower drift; less urgent but essential long-term

### 2.2 Per-Category Scores (Observability)

Convergence engine reports **three dimension scores** separately (for diagnosis):

```json
{
  "timestamp": "2026-05-02T16:00:00Z",
  "convergence_health": 87.3,
  "dimensions": {
    "spec_code_alignment": 0.08,
    "code_cheatsheet_alignment": 0.12,
    "cheatsheet_reality_alignment": 0.05
  },
  "category_breakdown": {
    "runtime": { "health": 92, "drifts": ["cheatsheet_reality_alignment: 0.08"] },
    "languages": { "health": 84, "drifts": ["spec_code_alignment: 0.15"] },
    "build": { "health": 76, "drifts": ["code_cheatsheet_alignment: 0.28"] },
    "test": { "health": 89, "drifts": [] }
  },
  "alerts": [
    { "type": "source_staleness", "cheatsheet": "build/cargo.md", "age_days": 125, "severity": "warning" },
    { "type": "hit_rate_degradation", "cheatsheet": "languages/rust.md", "hits": 2, "misses": 8, "severity": "high" }
  ]
}
```

**Per-category diagnostics**: Converge engine groups cheatsheets by category (runtime, languages, build, test, web, utils, agents) and scores each cluster independently, so operators know which areas need attention.

---

## 3. Fitness Function (from YAML, Operationalized)

The YAML defines:
```
fitness = compile_success
        + spec_coverage
        - cheatsheet_violation
        - runtime_error_rate
        - drift_penalty
```

**Phase 5 Operationalization**:

| Component | Measurement | Range | Source | Weight |
|-----------|-------------|-------|--------|--------|
| `compile_success` | Cargo build --release exits 0 | 0–1 (binary) | CI workflow | 0.25 |
| `spec_coverage` | Fraction of public fns with @trace | 0–1 (normalized) | `audit-public-fn-coverage.sh` | 0.25 |
| `cheatsheet_violation` | Count of stale/broken cheatsheets | 0–N (penalized) | Phase 5 audit | 0.20 |
| `runtime_error_rate` | Count of L3 telemetry "failure" status | 0–N (penalized) | Phase 3 logs | 0.15 |
| `drift_penalty` | 1.0 - convergence_health (normalized 0–1) | 0–1 (penalized) | Phase 5 convergence engine | 0.15 |

**Fitness Function (Concrete)**:

```
fitness = (1.0 * compile_success)
        + (0.25 * min(spec_coverage, 1.0))
        - (0.20 * min(cheatsheet_violations / 50, 1.0))
        - (0.15 * min(runtime_errors / 100, 1.0))
        - (0.15 * drift_penalty)
```

**Range**: 0–1 (normalized)

**Thresholds**:

- **fitness ≥ 0.85**: "Ready to ship" — all systems nominal
- **0.75–0.84**: "Production-acceptable" — minor issues being tracked
- **0.65–0.74**: "Investigate required" — schedule compaction review
- **<0.65**: "Critical" — cannot ship until resolved

**Example Calculation**:

```
Scenario: Build passes, 95% fn coverage, 2 stale cheatsheets, 3 runtime errors, 92% convergence health

compile_success = 1.0
spec_coverage = 0.95
cheatsheet_violations = 2 / 50 = 0.04 (capped at 1.0)
runtime_error_rate = 3 / 100 = 0.03
drift_penalty = 1.0 - 0.92 = 0.08

fitness = 1.0
        + (0.25 * 0.95)
        - (0.20 * 0.04)
        - (0.15 * 0.03)
        - (0.15 * 0.08)
        = 1.0 + 0.238 - 0.008 - 0.0045 - 0.012
        = 1.212 (capped at 1.0)
        = 1.0 → "Ready to ship"
```

---

## 4. Automated Compaction Loop (Phase 5.1+)

### 4.1 Compaction Pseudocode

Once Phase 4 metrics are collected (post-session), Phase 5 runs the following loop (no runtime overhead):

```
FUNCTION run_convergence_loop():
  """
  Post-session, after all agents exit forge containers.
  Runs asynchronously, zero blocking on tray.
  """
  
  # Step 1: Collect phase 4 metrics
  metrics = load_cheatsheet_metrics_report()  # From Phase 4 analysis
  convergence = compute_convergence_health()  # All three drift dimensions
  fitness = compute_fitness_score()
  
  # Step 2: Detect drift anomalies
  anomalies = []
  FOR each (cheatsheet, entry) IN metrics:
    delta_score = compute_entry_delta_score(entry)  # Per-entry drift
    
    IF delta_score > DRIFT_THRESHOLD_WARNING:
      anomalies.append({
        type: "drift_detected",
        entry: entry,
        delta: delta_score,
        severity: "warning" if delta_score < 0.3 else "critical"
      })
  
  # Step 3: Recommend and apply actions (with guardrails)
  FOR each entry IN metrics:
    score = entry.score  # From Phase 4 scoring function
    action = recommend_action(score, entry.hit_rate, entry.spec_bindings)
    
    # Phase 5.0: Manual review (recommend only)
    IF phase == "5.0":
      log_recommendation(action, entry, reason)
      CONTINUE  # No automatic changes
    
    # Phase 5.1: Safe automation (COMPACT only, dry-run first)
    IF phase == "5.1" AND action == "COMPACT":
      IF score < 0.65:
        log_recommendation(action, entry, "skip: score too low")
        CONTINUE  # Manual review required
      
      # Dry-run: what would happen?
      compacted = compress_entry(entry)
      delta_size = len(entry) - len(compacted)
      
      IF delta_size < 100:  # Too small to bother
        log_action("skip_compact", "delta < 100 bytes")
        CONTINUE
      
      # Apply with rollback guard
      backup = git_stash(entry)
      update_cheatsheet(entry, compacted)
      
      # Test: verify hit_rate didn't drop >5%
      test_result = run_regression_tests()
      new_metrics = analyze_cheatsheet_metrics()
      new_score = new_metrics[entry].score
      
      IF new_score < score * 0.95:
        # Rollback!
        git_restore(backup)
        log_action("compact_rolled_back", {
          before_score: score,
          after_score: new_score,
          reason: "score degraded"
        })
      ELSE:
        # Success!
        log_action("compact_applied", {
          before_size: len(entry),
          after_size: len(compacted),
          before_score: score,
          after_score: new_score
        })
        git_commit("chore: auto-compact {entry} (score maintained)")
    
    # Phase 5.2: Full automation (includes DELETE)
    IF phase == "5.2":
      IF action == "DELETE":
        IF entry.spec_bindings == 0 AND score < 0.1:
          # Safe to delete: no spec deps, very low score
          add_tombstone(entry, "obsolete:entry-name")
          remove_from_markdown(entry)
          log_action("delete_applied", {
            reason: "orphaned, zero spec binding",
            score: score,
            tombstone_safe_until: current_version + "." + (patch + 3)
          })
          git_commit("chore: remove obsolete {entry}")
      
      IF action == "EXPAND":
        # Analyze top misses
        top_misses = get_top_missed_queries(entry, limit=5)
        
        IF any_queries_analyzable(top_misses):
          # Generate expansion patch (LLM-assisted, human-reviewed first)
          patch = generate_expansion_patch(entry, top_misses)
          apply_patch(entry, patch)
          log_action("expand_applied", {
            top_misses: top_misses,
            patch_size: len(patch)
          })
          # Don't commit until human reviews!
          git_add(entry)
          log_recommendation("human_review", "expansion patch staged, requires approval")

  # Step 4: Report & alerting
  report = {
    timestamp: now(),
    convergence_health: convergence.health,
    fitness_score: fitness,
    actions_applied: count(anomalies where status == "applied"),
    recommendations: count(anomalies where status == "pending_review"),
    alerts: anomalies
  }
  
  write_report("convergence-report.jsonl", report)
  IF convergence.health < 75:
    emit_alert("critical", "convergence health degraded", report)
  
  RETURN report
```

### 4.2 Action Decision Tree

```
FOR each cheatsheet entry:

  score = (from Phase 4 metrics)
  hit_rate = (from Phase 4 metrics)
  spec_bindings = (from Phase 4 metrics)
  
  # Tier 1: High-confidence actions (low risk)
  IF score > 0.65 AND hit_rate > 0.8 AND misses < 3:
    action = "COMPACT"  # Stable, can compress safely
  ELSE IF score < 0.2 AND spec_bindings == 0 AND hit_rate < 0.3:
    action = "DELETE"  # Orphaned, low utility
  
  # Tier 2: Medium-confidence actions (manual review)
  ELSE IF hit_rate < 0.3 AND spec_bindings > 0:
    action = "EXPAND"  # Spec-bound but missing coverage
  ELSE IF hit_rate > 0.8 AND score > 0.65:
    action = "PROTECT"  # Critical path, leave alone
  
  # Tier 3: No action
  ELSE:
    action = "MONITOR"  # In-range, stable

RETURN action
```

---

## 5. Verification Levels Integration (Phase 3 → Phase 5)

Phase 3 declares evidence levels (L0–L3). Phase 5 uses them to detect drift:

### 5.1 L3 Verification Mismatches

**Scenario**: Code claims L3 (runtime telemetry) but telemetry events show 60% "failure" status.

**Phase 5 Response**:
1. Parse Phase 3 annotation: `verified_at:L3`
2. Query Phase 3 telemetry logs: `spec = "forge-launch"`
3. Compute success_rate = (success events) / (total events)
4. If success_rate < 0.9:
   - Flag as **drift_alert**: "L3 claim failing verification"
   - Severity: high (runtime observable failure)
   - Trigger: immediate investigation, revert code or fix the bug

**Pseudocode**:
```
FOR each code location with `@trace spec:<name>, verified_at:L3`:
  events = query_telemetry_log(spec_name)
  success_rate = events.count(status="success") / len(events)
  
  IF success_rate < 0.9:
    alert(type="l3_verification_failure", {
      spec: spec_name,
      success_rate: success_rate,
      event_count: len(events),
      recommendation: "revert code or fix the bug"
    })
```

### 5.2 L-Level Upward/Downward Pressure

**Upward Pressure** (evidence improving):
- L0 code with 95%+ hit rate → candidate for L1 upgrade (add cheatsheet citation)
- L1 code with passing integration test → candidate for L2 (add test path to spec)
- L2 code with 100% L3 telemetry success → candidate for L3 promotion

**Downward Pressure** (evidence degrading):
- L3 code with 60% failure rate → downgrade to L2 (stop claiming telemetry)
- L2 code with flaky integration test → downgrade to L1 (still have cheatsheet)
- L1 code with 0 spec bindings → downgrade to L0 (orphaned)

**Phase 5 Recommendation**:
```
IF verification_level_actual < verification_level_claimed:
  action = "downgrade_annotation"
  log_recommendation({
    location: code_file,
    old_level: claimed_level,
    new_level: observed_level,
    reason: (evidence degrades)
  })

IF verification_level_actual > verification_level_claimed:
  action = "upgrade_annotation"
  log_recommendation({
    location: code_file,
    old_level: claimed_level,
    new_level: observed_level,
    reason: (evidence improves)
  })
```

---

## 6. Tray UI/UX Integration

### 6.1 Stability Chip (System Tray)

**Location**: Tray application, next to existing environment/project indicators

**Display**:
```
[🌱 aeranthos] [🔒 Secure] [📊 Stability: 87%]
```

**Behavior**:
- Shows convergence health as percentage (0–100%)
- Color changes: 🟢 (95+), 🟡 (85–94), 🟠 (75–84), 🔴 (<75)
- Clicking opens "Stability Report" popover

### 6.2 Stability Report Popover

**Layout**:
```
┌─────────────────────────────────────────┐
│ System Stability Report                  │
├─────────────────────────────────────────┤
│ Overall Health: 87% (Healthy)            │
│                                          │
│ Dimensions:                              │
│ ✅ Spec ↔ Code:       92% aligned        │
│ ⚠️  Code ↔ Cheatsheet: 78% aligned       │
│ ✅ Cheatsheet ↔ Reality: 95% current     │
│                                          │
│ Alerts (2):                              │
│ • Cheatsheet stale: build/cargo.md      │
│   Last verified: 120 days ago            │
│   → Verify against upstream sources      │
│                                          │
│ • High miss rate: languages/rust.md     │
│   Misses: 8/11 queries (27% hit rate)   │
│   → Expand entry or add examples        │
│                                          │
│ [ Run Convergence Check ]               │
│ [ Review Recommendations ]              │
│ [ Show Full Report ]                    │
└─────────────────────────────────────────┘
```

### 6.3 Background Metrics Daemon (Async)

**Runs**: After agent sessions end, once per 24 hours (default)

**Job**:
1. Collect Phase 4 metrics from `~/.local/state/tillandsias/external-logs/cheatsheet-telemetry/`
2. Compute convergence health
3. Update `~/.cache/tillandsias/convergence-report.json` (latest report)
4. If health < 75%, emit system notification: "Stability check: system health degraded to 70%"

**Pseudocode**:
```rust
// In src-tauri/src/background_tasks.rs (or similar)

#[tokio::task]
async fn convergence_health_monitor() {
    loop {
        // Run every 24 hours (or on-demand via `--converge`)
        tokio::time::sleep(Duration::from_secs(86400)).await;
        
        match run_convergence_loop().await {
            Ok(report) => {
                // Write report to cache
                let path = dirs::cache_dir()
                    .unwrap()
                    .join("tillandsias/convergence-report.json");
                
                tokio::fs::write(&path, serde_json::to_string(&report)?).await?;
                
                // Update tray chip
                tray_state.update_convergence_health(report.health);
                
                // Alert if critical
                if report.health < 75 {
                    notify_user("Stability check: system health degraded", &report);
                }
            }
            Err(e) => {
                warn!("convergence check failed: {}", e);
                // Non-blocking; tray continues running
            }
        }
    }
}

// @trace spec:convergence-engine
pub async fn run_convergence_loop() -> Result<ConvergenceReport> {
    let metrics = load_cheatsheet_metrics().await?;
    let health = compute_convergence_health(&metrics)?;
    let fitness = compute_fitness_score(&health)?;
    let recommendations = generate_recommendations(&metrics)?;
    
    Ok(ConvergenceReport {
        timestamp: Utc::now(),
        health,
        fitness,
        recommendations,
    })
}
```

---

## 7. Timeline & Phases (Roadmap)

### Phase 5.0: Design & Manual Review (This Document)

**Deliverables**:
- `PHASE_5_DESIGN.md` (this document)
- `CONVERGENCE_MODEL_SUMMARY.md` (quick reference)
- Design review, user approval

**Timeline**: 2026-05-02 (complete)

### Phase 5.1: Core Automation (COMPACT, dry-run rollback)

**Deliverables**:
- [ ] Implement drift detection: Δ_spec_code, Δ_code_cheatsheet, Δ_cheatsheet_reality (scripts/)
- [ ] Implement convergence health scoring function
- [ ] Implement Phase 5 validator: `scripts/validate-convergence.sh`
- [ ] Add COMPACT automation with rollback guard
- [ ] Tray UI: add Stability chip (static for now)
- [ ] Background daemon: post-session health check (async, non-blocking)
- [ ] Documentation: `cheatsheets/observability/convergence-engine.md`

**Timeline**: ~3 weeks after Phase 4 stabilizes

**Effort**: ~40 hours (2 weeks @ half-time)

### Phase 5.2: Full Automation (DELETE, EXPAND guidance)

**Deliverables**:
- [ ] Implement DELETE automation with `@tombstone` marker (Phase 5.1 foundation)
- [ ] Implement EXPAND guidance (generate candidate patches, stage for human review)
- [ ] Add L3 verification mismatch detection (from Phase 3 logs)
- [ ] Tray UI: interactive Stability Report with "Apply Recommendation" buttons
- [ ] CI integration: fail build if fitness < 0.65 (strict phase)
- [ ] Documentation: manual compaction guide

**Timeline**: ~4 weeks after Phase 5.1

**Effort**: ~35 hours

### Phase 5.3: Refinement (Metrics dashboard, ML-assisted expansion)

**Future**:
- Metrics dashboard: web UI showing health over time
- LLM-assisted expansion (generate new examples from top misses)
- Cross-cheatsheet deduplication detection
- Cheatsheet refresh cadence optimization (dynamically adjust staleness threshold)

---

## 8. Success Criteria

Phase 5 is complete when:

### Phase 5.0 (Design)
- [ ] Design document complete and approved
- [ ] Three drift axes clearly defined with measurement formulas
- [ ] Fitness function operationalized with concrete thresholds
- [ ] Compaction loop pseudocode documented with guardrails
- [ ] Tray UI/UX mockup complete
- [ ] User approves roadmap

### Phase 5.1 (Core)
- [ ] Drift detection scripts produce valid convergence health (0–100)
- [ ] Compaction automation applies COMPACT actions safely (dry-run + rollback)
- [ ] Tray Stability chip displays accurate health score
- [ ] Background daemon runs post-session without blocking tray
- [ ] Build script includes `validate-convergence.sh` and reports health
- [ ] No changes to existing code (Phase 1–4 unaffected)

### Phase 5.2 (Full)
- [ ] DELETE automation marks entries with `@tombstone` (3-release retention)
- [ ] EXPAND guidance stages patches, requires human approval
- [ ] L3 verification mismatches trigger immediate investigation alerts
- [ ] CI enforces fitness ≥ 0.65 before release
- [ ] Convergence health ≥ 95% across entire codebase at shipping time

---

## 9. Hard Boundaries & Constraints

### 1. **Post-Session Execution Only**

- Convergence checks run AFTER agents exit containers
- Zero blocking on tray, agents, or user workflows
- Async background task in Tauri, not main thread

### 2. **Falsifiable Claims**

Every drift measurement is testable:
- Δ_spec_code: File existence check (trivial)
- Δ_code_cheatsheet: Hit rate is recorded (Phase 4)
- Δ_cheatsheet_reality: URL checks are automated (can be scripted)

### 3. **Rollback Guarantees**

- COMPACT: Always test before/after; rollback if score drops
- DELETE: Only with zero spec bindings (always safe)
- EXPAND: Staged for human review, never auto-applied

### 4. **No New Instrumentation in Tray**

- Release binary has zero convergence check code
- All logic in host-side scripts or background daemon
- Tray only reads cached report, emits to UI

### 5. **Monotonic Convergence**

- Each phase strictly improves on prior phases
- Phase 5 adds automation on top of Phase 4, doesn't replace it
- Backward compatibility maintained (Phase 1–4 code valid as-is)

---

## 10. Integration Matrix (Phases 1–5)

| Phase | Deliverable | Phase 5 Input | Phase 5 Output |
|-------|-------------|---------------|----------------|
| **Phase 1** | Trace annotations, external-logs | Annotation presence + coverage | Δ_spec_code signal |
| **Phase 2** | CI spec validator | Spec existence checks | Input to Δ_spec_code |
| **Phase 3** | Verification levels (L0–L3) | L-level claims + telemetry logs | Input to drift detection (L-level mismatch) |
| **Phase 4** | Cheatsheet metrics (hits/misses/scores) | Phase 4 report (scores, hit rates) | Input to Δ_code_cheatsheet, recommendations |
| **Phase 5** | Convergence engine | All prior phases | Unified health score, automated actions, tray UI |

---

## 11. Example: Full Workflow (Phase 5 in Action)

### Scenario: Developer Upgrades Cargo, Cheatsheet Mismatches Detected

**Timeline**:

1. **Developer upgrades tokio 1.30 → 1.35** in `Cargo.lock`
2. **Agent runs, hit_rate drops 95% → 60%** on rust/async-patterns queries
3. **Phase 4 analysis flags**: "Entry hit_rate degraded"
4. **Phase 5 runs convergence check** (post-session):
   - Δ_code_cheatsheet = 0.28 (high misses)
   - Cheatsheet cites tokio 1.30 (outdated)
   - Δ_cheatsheet_reality = 0.10 (sources stale: not re-verified since Jan)
   - Convergence health = 100 * (1 - 0.40*0.08 - 0.35*0.28 - 0.25*0.10) = **85.5% (🟡 caution)**

5. **Phase 5.1 recommends**:
   - EXPAND entry: "tokio 1.35 added select! alternatives"
   - Top misses: "select with guarded match", "select! in spawn tasks" (2 each)
   - Recommendation staged for human review

6. **Developer reviews recommendations** in Stability Report:
   - Sees "High miss rate in languages/rust.md"
   - Clicks "Review Recommendations"
   - Sees candidate patch with tokio 1.35 patterns
   - Approves patch, applies to cheatsheet

7. **Metrics re-run** (after edit):
   - New hit_rate: 88% (up from 60%)
   - Score improved: 0.65 → 0.74
   - Δ_code_cheatsheet improves, convergence health → **91% (🟢 healthy)**

8. **Build passes, developer ships** with higher confidence

---

## 12. References

- `Monotonic reduction of uncertainty under verifiable constraints.yaml` (root) — canonical definition
- `PHASE_3_DESIGN.md` — verification levels (L0–L3)
- `PHASE_4_DESIGN.md` — cheatsheet metrics collection
- `CLAUDE.md` — @tombstone, OpenSpec workflow, verification levels
- `docs/cheatsheets/verification-levels.md` — user-facing L-level explanation
- `cheatsheets/observability/cheatsheet-metrics.md` — Phase 4 metrics system

---

## Appendix A: Drift Detection Formulas (Reference)

### Δ_spec_code (Annotation-Intent Alignment)

```
Signal 1: spec_exists = (all traced specs point to real specs?) ? 1.0 : 0.0
Signal 2: public_fn_coverage = (traced public fns) / (total public fns)
Signal 3: spec_activeness = (no deprecated specs used?) ? 1.0 : (1 - deprecated_fraction)
Signal 4: cheatsheet_binding = (specs have Sources of Truth?) ? 1.0 : 0.0

Δ = 1.0 - (0.35*spec_exists + 0.30*coverage + 0.20*activeness + 0.15*binding)
```

### Δ_code_cheatsheet (Tool Version Mismatch)

```
Signal 1: hit_rate = hits / (hits + misses + partials)
Signal 2: api_test_success = (integration tests pass?) ? 1.0 : (pass_rate)
Signal 3: l_level_match = (claimed_level == observed_level?) ? 1.0 : 0.0
Signal 4: dependency_recency = (pinned versions match?) ? 1.0 : (0.5 if mismatched)

Δ = 1.0 - (0.40*hit_rate + 0.30*api_test + 0.20*l_match + 0.10*recency)
```

### Δ_cheatsheet_reality (Source Staleness)

```
Signal 1: url_health = (healthy_urls) / (total_urls)
Signal 2: content_stability = (hash unchanged?) ? 1.0 : 0.0
Signal 3: freshness = 1.0 / (1.0 + (days_since_verified / 90))
Signal 4: provenance = (## Provenance section exists?) ? 1.0 : 0.0

Δ = 1.0 - (0.35*url_health + 0.30*stability + 0.25*freshness + 0.10*provenance)
```

### Convergence Health (Overall)

```
Convergence Health = 100 * (1.0 - (
    0.40 * Δ_spec_code +
    0.35 * Δ_code_cheatsheet +
    0.25 * Δ_cheatsheet_reality
))
Range: 0–100 (higher is better)
```

### Fitness Score (Shipping Readiness)

```
fitness = (1.0 * compile_success)
        + (0.25 * min(spec_coverage, 1.0))
        - (0.20 * min(cheatsheet_violations / 50, 1.0))
        - (0.15 * min(runtime_errors / 100, 1.0))
        - (0.15 * drift_penalty)
Range: 0–1.0 (≥0.85 ready to ship)
```

---

**End of Phase 5 Design Document**
