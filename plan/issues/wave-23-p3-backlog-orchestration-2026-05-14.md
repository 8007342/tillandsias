---
task_id: p3-backlog/wave-23-opportunistic
wave: 23
iteration: 9
date: 2026-05-14
status: orchestration_ready
---

# Wave 23 — P3 Backlog Continuation (Observability Extensions)

**Intent**: multi_agent_orchestration (4 parallel agents on independent gaps)

**Context**: Waves 17-22 complete. 12 P3 gaps implemented. 4 more observability + tray gaps ready.

**Scope**: 4 opportunistic gaps across observability and remaining tray work (no release impact)

**Timeline**: ~1.5-2 hours (parallel execution with 4 agents)

---

## Parallel Work Structure

### Wave 23a — Trace Coverage Threshold CI Gate (Haiku Team A)

**Gap**: OBS-004 (Trace coverage threshold CI gate)

**Deliverable**: Implement automated CI gate that enforces minimum trace coverage (90%)

**Owned Files**:
- scripts/validate-traces.sh (new, extend existing trace validator)
- build.sh (add CI gate integration)
- openspec/litmus-bindings.yaml (add litmus binding if needed)
- Add @trace gap:OBS-004

**Effort**: 1 hour

**Success Criteria**:
- CI gate checks that all active specs have ≥1 @trace annotation in code
- Failure blocks CI when coverage drops below 90%
- Clear error messages listing uncovered specs
- Configurable threshold (default 90%)
- No regressions

---

### Wave 23b — Cross-Container Span Linkage (Haiku Team B)

**Gap**: OBS-007 (Cross-container span linkage)

**Deliverable**: Link logs across containers via parent span IDs

**Owned Files**:
- crates/tillandsias-logging/src/span_context.rs (new module for span tracking)
- crates/tillandsias-logging/src/lib.rs (export span context)
- Add @trace gap:OBS-007

**Effort**: 1 hour

**Success Criteria**:
- Span context propagates across container boundaries
- Parent-child span relationships queryable
- Logs include `parent_span_id` field when applicable
- 5+ unit tests for span linkage
- No regressions

---

### Wave 23c — Rapid Project Switch Defensive Test (Haiku Team C)

**Gap**: TR-007 (Rapid project switch defensive test)

**Deliverable**: Stress test tray switching between projects in < 500ms

**Owned Files**:
- crates/tillandsias-headless/tests/rapid_project_switch_v2.rs (new stress test)
- docs/cheatsheets/tray-rapid-switch.md (benchmark documentation)
- Add @trace gap:TR-007

**Effort**: 45 min

**Success Criteria**:
- Stress test: switch projects 20x in sequence
- Each switch completes in < 500ms
- Menu consistency verified (no stale items)
- 3+ unit tests for rapid switch scenarios
- No regressions

---

### Wave 23d — Metrics Export to Prometheus (Opus)

**Gap**: OBS-009 (Metrics export to Prometheus)

**Deliverable**: Expose `/metrics` endpoint compatible with Prometheus scrape format

**Owned Files**:
- crates/tillandsias-metrics/src/prometheus_exporter.rs (new module)
- crates/tillandsias-headless/src/main.rs (wire prometheus endpoint)
- Add @trace gap:OBS-009

**Effort**: 1.5 hours (Opus for complexity)

**Success Criteria**:
- HTTP `/metrics` endpoint returns Prometheus text format
- Container CPU, memory, disk metrics exported
- Metric names follow Prometheus conventions (_total, _bytes, _seconds)
- 6+ unit tests for scrape format and metric encoding
- No regressions

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: scripts/validate-traces.sh (CI gate)
- Team B: crates/tillandsias-logging/src/span_context.rs (span linkage)
- Team C: crates/tillandsias-headless/tests/rapid_project_switch_v2.rs (tray stress)
- Team D: crates/tillandsias-metrics/src/prometheus_exporter.rs (prometheus export)

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [ ] Team A (OBS-004): Trace coverage CI gate — in progress
- [x] Team B (OBS-007): Cross-container span linkage — COMPLETE
- [x] Team C (TR-007): Rapid project switch test — COMPLETE
- [ ] Team D (OBS-009): Prometheus metrics export — in progress
- [ ] CI verification: Pending (all 4 agents complete)

---

## Release Impact

**Important**: These are P3 gaps — non-blocking for release.

- ✅ Can ship WITHOUT Wave 23
- ✅ Can run in parallel with any other work
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
**Release Impact**: Zero (P3 polish, non-blocking)
