# Convergence Model Summary: One-Page Reference

@trace spec:convergence-engine, spec:automated-cheatsheet-compaction

**For**: Quick understanding of Phase 5. Details in `PHASE_5_DESIGN.md`.

---

## The Three Drift Axes

Phase 5 measures misalignment in three directions:

```
        Spec (Intent)
             │
             │ Δ(spec ↔ code)
             │ "Are annotations valid? Is code coverage complete?"
             ▼
        Code (Implementation)
             │
             │ Δ(code ↔ cheatsheet)
             │ "Does cheatsheet match code's tool versions?"
             ▼
      Cheatsheet (Knowledge)
             │
             │ Δ(cheatsheet ↔ reality)
             │ "Are cited sources still accurate?"
             ▼
        Reality (Upstream)
```

---

## Drift Signals (Measured)

| Axis | Signals | Target | Red Flag |
|------|---------|--------|----------|
| **Δ(spec ↔ code)** | Spec exists? Functions annotated? Specs active? Cheatsheets bound? | 1.0 (none) | <0.8 (gaps) |
| **Δ(code ↔ cheatsheet)** | Hit rate? API tests pass? L-level matches? Dependencies current? | 1.0 (none) | >0.2 (drift) |
| **Δ(cheatsheet ↔ reality)** | URLs resolve? Content unchanged? Last verified <90 days? Provenance cited? | 1.0 (none) | >0.2 (stale) |

---

## Convergence Health (0–100%)

**Formula**:
```
Health = 100 * (1 - (0.40 * Δ_spec_code 
                    + 0.35 * Δ_code_cheatsheet 
                    + 0.25 * Δ_cheatsheet_reality))
```

**Interpretation**:

```
95–100 🟢 Optimal        → Continue; no action needed
85–94  🟡 Healthy        → Monitor; plan improvements
75–84  🟠 Caution        → Schedule compaction review
<75    🔴 Degraded       → Investigate immediately
```

---

## Fitness Score (Shipping Readiness)

**Formula**:
```
fitness = compile_success 
        + 0.25 * spec_coverage 
        - 0.20 * cheatsheet_violations 
        - 0.15 * runtime_errors 
        - 0.15 * drift_penalty
```

**Shipping Gate**:
- ✅ ≥0.85: Ready to ship
- ⚠️  0.75–0.84: Production-acceptable, track issues
- ❌ <0.75: Cannot ship until resolved

---

## Phase 5 State Machine

```
┌──────────────┐
│ Session End  │ (agents exit forge containers)
└──────┬───────┘
       │
       ▼
┌──────────────────────────────────────┐
│ Collect Phase 4 Metrics              │
│ (hits, misses, scores per entry)     │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│ Compute Drift Signals                │
│ (Δ_spec_code, Δ_code_cheatsheet,     │
│  Δ_cheatsheet_reality)               │
└──────┬───────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────┐
│ Convergence Health Score 0–100       │
└──────┬───────────────────────────────┘
       │
       ├─→ Health ≥ 95% → No action
       │
       ├─→ 85–94 → Log recommendations (L2)
       │
       ├─→ 75–84 → Recommend compaction review (L1)
       │
       └─→ <75 → 🔴 ALERT + require investigation (L0)
       
       (Parallel: Apply safe automations)
       
       ├─→ COMPACT if score >0.65 + hit_rate >0.8 (dry-run + rollback)
       ├─→ DELETE if orphaned + score <0.1 (with @tombstone)
       ├─→ EXPAND if high_miss + spec_bound (stage for review)
       └─→ UPDATE L-level if evidence changes (downgrade if degraded)
```

---

## Actions by Score

**Per-Entry Decision**:

```
IF score > 0.65 AND hit_rate > 0.8:
  ACTION = "COMPACT"  (compress stable entries safely)
ELSE IF score < 0.2 AND spec_bindings == 0:
  ACTION = "DELETE"   (remove orphaned entries)
ELSE IF hit_rate < 0.3 AND spec_bindings > 0:
  ACTION = "EXPAND"   (extend spec-bound entries)
ELSE IF score > 0.65 OR spec_bindings > 3:
  ACTION = "PROTECT"  (preserve critical entries)
ELSE:
  ACTION = "MONITOR"  (stable, no change needed)
```

---

## Automation Phases

| Phase | Level | Automation | Guard |
|-------|-------|-----------|-------|
| **5.0** | Manual | None; recommend only | N/A |
| **5.1** | COMPACT | Auto-compress stable | Dry-run, rollback on <5% score drop |
| **5.2** | DELETE + EXPAND | Delete orphaned (with @tombstone), stage expansion patches | Human review before apply |

---

## Tray Integration

### Stability Chip (System Tray)

```
[🌱 aeranthos] [🔒 Secure] [📊 Stability: 87%]
                                        ▲
                                        │
                           Convergence Health (0–100%)
                           Colors: 🟢 95+ | 🟡 85-94 | 🟠 75-84 | 🔴 <75
```

### Clicking → Stability Report

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
│ Top Alerts (show 3 highest-priority):    │
│ • Cheatsheet stale: build/cargo.md      │
│   Last verified: 120 days ago            │
│   [ Fix ] [ Ignore ] [ Remind in 7d ]   │
│                                          │
│ • High miss rate: languages/rust.md     │
│   Misses: 8/11 queries                  │
│   [ View Details ] [ Approve Patch ]    │
└─────────────────────────────────────────┘
```

---

## Background Daemon (Async)

**Runs**: Post-session (after agents exit), every 24h default

**Does**:
1. Collect Phase 4 metrics
2. Compute convergence health + fitness
3. Write report to `~/.cache/tillandsias/convergence-report.json`
4. Update tray Stability chip
5. Alert if health <75% (system notification)

**Zero blocking**: Daemon runs in background; tray continues operating.

---

## Timeline

| Phase | Duration | Deliverables |
|-------|----------|--------------|
| **5.0** (now) | 1 day | Design docs, user approval |
| **5.1** | 3 weeks | Drift detection, COMPACT automation, UI chip, daemon |
| **5.2** | 4 weeks | DELETE + EXPAND, L-level mismatch detection, CI gating |

---

## Example: Drift in Action

### Before (Unseen)

- Developer upgrades tokio 1.30 → 1.35
- Agent queries rust/async-patterns, gets cache miss
- Cheatsheet still documents old patterns
- No visibility into the problem

### After (Phase 5)

1. **Agent hit_rate drops**: 95% → 60% (Phase 4 detects)
2. **Phase 5 computes**:
   - Δ_code_cheatsheet = 0.28 (high misses)
   - Convergence health = 85.5% (🟡 Caution)
3. **Tray shows**: "Stability: 85% — Code ↔ Cheatsheet misaligned"
4. **Developer clicks**: Sees "rust/async-patterns misses", approves patch
5. **After patch**: Health → 91% (🟢 Healthy), dev ships with confidence

---

## Success Criteria

✅ Phase 5 is done when:

- [ ] Convergence health ≥ 95% across codebase (shipping time)
- [ ] Fitness score ≥ 0.85 at release (ready to ship)
- [ ] All drifts <0.1 in their respective axes (well-aligned)
- [ ] Tray Stability chip shows accurate health
- [ ] Zero manual intervention needed for routine compaction (Phase 5.1+)

---

## Links

- **Full Design**: `PHASE_5_DESIGN.md`
- **Phase 3** (Verification Levels): `PHASE_3_DESIGN.md`
- **Phase 4** (Metrics): `PHASE_4_DESIGN.md`
- **YAML Spec**: `Monotonic reduction of uncertainty under verifiable constraints.yaml`

---

**Version**: v0.1 (Phase 5 Design)  
**Last Updated**: 2026-05-02  
**Status**: Ready for implementation planning
