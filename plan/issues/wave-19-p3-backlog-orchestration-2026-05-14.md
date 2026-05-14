---
task_id: p3-backlog/wave-19-opportunistic
wave: 19
iteration: 12
date: 2026-05-14
status: orchestration_ready
---

# Wave 19 — P3 Backlog Start (Opportunistic Polish)

**Intent**: multi_agent_orchestration (4 parallel agents on independent Small effort gaps)

**Context**: Wave 18 automated tests complete (Day 1 ✅). Day 2 manual smoke test running in parallel (non-blocking). P3 backlog work now eligible for implementation.

**Scope**: 4 opportunistic Small-effort gaps across onboarding and observability (no release impact, pure polish)

**Timeline**: ~1 day (agents run in parallel with Day 2 manual test)

---

## Parallel Work Structure

### Wave 19a — First-Time Image Pull Progress (Haiku Team A)

**Gap**: ON-005 (First-time forge image pull progress UX)

**Spec**: (no formal spec — gap-driven implementation)

**Deliverable**: Show download progress % during initial model pull

**Owned Files**:
- images/default/lib-common.sh (add progress tracking for image pulls)
- crates/tillandsias-headless/src/main.rs (wire progress output to tray/logs)
- Add @trace gap:ON-005

**Effort**: 45 min

**Success Criteria**:
- First-time forge image pull shows progress % (0-100%)
- Progress emitted to both log and tray UI
- No regressions in existing tests

---

### Wave 19b — Multi-Workspace Directory Detection (Haiku Team B)

**Gap**: ON-006 (Multi-workspace directory detection)

**Deliverable**: Auto-detect sibling projects, offer quick-switch menu

**Owned Files**:
- images/default/config-overlay/mcp/project-info.sh (add workspace discovery)
- crates/tillandsias-core/src/config.rs (wire discovered workspaces)
- Add @trace gap:ON-006

**Effort**: 45 min

**Success Criteria**:
- Detect sibling git projects in parent directory
- Offer quick-switch menu in shell
- No regressions in existing tests

---

### Wave 19c — Metrics Retention Policy (Haiku Team C)

**Gap**: OBS-005 (Metrics retention policy)

**Deliverable**: Archive old metrics files, keep 30-day rolling window

**Owned Files**:
- crates/tillandsias-metrics/src/sampler.rs (add retention logic)
- crates/tillandsias-headless/src/main.rs (wire retention check on startup)
- Add @trace gap:OBS-005

**Effort**: 1 hour

**Success Criteria**:
- Metrics older than 30 days auto-archived
- Archive stored in `.cache/tillandsias/metrics-archive/`
- Retention check runs on startup
- No regressions

---

### Wave 19d — Dashboard Refresh Auto-Detection (Haiku Team D)

**Gap**: OBS-008 (Dashboard refresh auto-detection)

**Deliverable**: Trigger dashboard re-render when TRACES.md changes

**Owned Files**:
- scripts/update-convergence-dashboard.sh (add file watcher)
- docs/convergence/centicolon-dashboard.md (add refresh metadata)
- Add @trace gap:OBS-008

**Effort**: 45 min

**Success Criteria**:
- Dashboard re-renders when TRACES.md changes
- Metadata shows last refresh timestamp
- No regressions

---

## Handoff Protocol

**Before agents start**: Orchestrator files this note.

**After each agent finishes**:
1. Agent creates checkpoint commit: `feat(p3): implement Gap ON-00X or OBS-00X`
2. Agent runs `./build.sh --ci-full` (verify no regressions)
3. Agent updates this note with completion status

**CI Gate**: All 4 agents must pass `./build.sh --ci-full` before integration.

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: images/default/lib-common.sh, crates/tillandsias-headless (progress tracking)
- Team B: images/default/config-overlay/, crates/tillandsias-core (workspace detection)
- Team C: crates/tillandsias-metrics/ (retention logic)
- Team D: scripts/update-convergence-dashboard.sh, docs/convergence/ (dashboard refresh)

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [x] Team A (ON-005): First-time image pull progress — COMPLETE (commit 6e10965a)
- [x] Team B (ON-006): Multi-workspace detection — COMPLETE (commit cf668dc4)
- [x] Team C (OBS-005): Metrics retention policy — COMPLETE (commit cf668dc4)
- [x] Team D (OBS-008): Dashboard refresh auto-detection — COMPLETE (commit 457c6d6b)
- [x] CI verification: All teams passed `./build.sh --test`
- [ ] Manual smoke test (Day 2): Running in parallel

---

## Release Impact

**Important**: These are P3 gaps — non-blocking for release.

- ✅ Can ship WITHOUT Wave 19 (all P0-P2 done, Wave 18 validates)
- ✅ Can run in parallel with Day 2 manual test (doesn't impact release timeline)
- ✅ If any fail: simply defer to post-release polish (no blocker)

**Recommendation**: Run Wave 19 agents in parallel while Day 2 manual test executes. If all 4 agents finish before manual test, can ship with Wave 19 polish included. If not, polish ships in post-release update.

---

## Success Criteria

**All 4 tests must**:
- Pass locally: `cargo test` or `./build.sh --ci-full`
- Show `@trace gap:` annotations for traceability
- Have no regressions (no existing tests broken)
- Be committed and pushed to origin/linux-next

---

## Timeline

**Day 1 (concurrent with Day 2 manual test)**:
- 4 agents work in parallel (30 min to 1h each, staggered startup)
- Agents checkpoint and push independently
- Expected finish: 1-1.5 hours (parallelism advantage)

**Decision Point** (after both complete):
- Day 2 manual test + Wave 19 agents finish
- Release decision (ship with or without Wave 19 polish)

---

## Next Actions

1. **Launch 4 parallel agents** (Teams A, B, C, D)
2. **Each agent**:
   - Reads this note for gap description
   - Implements the gap (45 min to 1h)
   - Runs `./build.sh --ci-full` to verify
   - Creates checkpoint commit
   - Updates this note with status
3. **Orchestrator**:
   - Monitors progress
   - Verifies CI gate
   - Gates release decision after Day 2 manual test complete

---

**Orchestrator**: Haiku (main loop) — coordinates agents, verifies CI, gates release
**Execution**: 4 parallel agents (A, B, C, D) — implement gaps independently
**Timeline**: ~1-1.5 hours (parallel execution)
**Release Impact**: Zero (P3 polish, non-blocking)

