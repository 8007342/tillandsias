---
task_id: p3-backlog/wave-24-opportunistic
wave: 24
iteration: 10
date: 2026-05-14
status: orchestration_ready
---

# Wave 24 — P3 Backlog Final Batch (Observability + Tray)

**Intent**: multi_agent_orchestration (4 parallel agents on final P3 gaps)

**Context**: Waves 17-23 complete. 20 P3 gaps implemented. Final batch of 4 gaps ready.

**Scope**: 4 final observability + tray gaps (no release impact)

**Timeline**: ~1.5-2 hours (parallel execution with 4 agents)

---

## Parallel Work Structure

### Wave 24a — Trace Budget Enforcement (Haiku Team A)

**Gap**: OBS-011 (Trace budget enforcement)

**Deliverable**: Warn when trace generation exceeds user-configured cost threshold

**Owned Files**:
- crates/tillandsias-logging/src/budget_enforcer.rs (new module)
- crates/tillandsias-headless/src/main.rs (wire budget checks)
- Add @trace gap:OBS-011

**Effort**: 1 hour

**Success Criteria**:
- Track cumulative trace cost per time window (configurable)
- Warn when cost threshold exceeded
- Support per-spec budgets and global limit
- 4+ unit tests for budget tracking
- No regressions

---

### Wave 24b — Tray Performance Profiling (Haiku Team B)

**Gap**: TR-008 (Tray performance profiling for optimization)

**Deliverable**: Add performance instrumentation for profiling tray responsiveness

**Owned Files**:
- crates/tillandsias-headless/src/tray/profiler.rs (new performance tracker)
- docs/cheatsheets/tray-performance-profiling.md (profiling guide)
- Add @trace gap:TR-008

**Effort**: 45 min

**Success Criteria**:
- Track menu operation latencies (open, switch, select)
- Export metrics for analysis
- Identify hotspots automatically
- 3+ unit tests
- No regressions

---

### Wave 24c — Log Aggregation Foundation (Haiku Team C)

**Gap**: OBS-013 (Log aggregation extension)

**Deliverable**: Foundation for aggregating logs from multiple containers

**Owned Files**:
- crates/tillandsias-logging/src/aggregator.rs (new log aggregation)
- crates/tillandsias-headless/src/main.rs (wire aggregator)
- Add @trace gap:OBS-013

**Effort**: 1 hour

**Success Criteria**:
- Aggregate logs from multiple container sources
- Merge into unified stream by timestamp
- Support filtering by container/spec
- 4+ unit tests for aggregation
- No regressions

---

### Wave 24d — Observability Surface Completion (Opus)

**Gap**: OBS-023 (Observability surface completion)

**Deliverable**: Polish observability interfaces and complete remaining gaps

**Owned Files**:
- crates/tillandsias-logging/src/surface.rs (new API surface)
- docs/cheatsheets/observability-api.md (API documentation)
- Add @trace gap:OBS-023

**Effort**: 1.5 hours (Opus for complexity)

**Success Criteria**:
- Comprehensive observability API surface
- Query, sampling, budget, aggregation unified interface
- Full type safety and error handling
- 6+ unit tests
- No regressions

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: crates/tillandsias-logging/src/budget_enforcer.rs (budget)
- Team B: crates/tillandsias-headless/src/tray/profiler.rs (tray profiling)
- Team C: crates/tillandsias-logging/src/aggregator.rs (log aggregation)
- Team D: crates/tillandsias-logging/src/surface.rs (observability API)

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [ ] Team A (OBS-011): Trace budget enforcement — in progress
- [ ] Team B (TR-008): Tray performance profiling — in progress
- [ ] Team C (OBS-013): Log aggregation foundation — in progress
- [ ] Team D (OBS-023): Observability surface completion — in progress
- [ ] CI verification: Pending (all 4 agents complete)

---

## Release Impact

**Important**: These are P3 gaps — non-blocking for release.

- ✅ Can ship WITHOUT Wave 24
- ✅ Final optional polish after all P0-P2 work
- ✅ If any fail: defer to post-release polish

---

## Timeline

**Concurrent execution**:
- 4 agents work in parallel (45 min to 1.5h each)
- Expected finish: 1.5-2 hours
- Results integrated before release decision if all pass

---

**Orchestrator**: Haiku — coordinates agents, verifies CI
**Execution**: 4 parallel agents (A, B, C, D) — implement gaps independently
**Timeline**: ~1.5-2 hours (parallel execution)
**Release Impact**: Zero (final P3 polish, non-blocking)
