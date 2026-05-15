---
task_id: p3-backlog/wave-20-opportunistic
wave: 20
iteration: 13
date: 2026-05-14
status: orchestration_ready
---

# Wave 20 — P3 Backlog Continuation (Onboarding + Observability)

**Intent**: multi_agent_orchestration (4 parallel agents on independent gaps)

**Context**: Waves 17-19 complete. Wave 18 Day 2 manual test running independently (non-blocking). P3 backlog work continues in parallel.

**Scope**: 4 opportunistic gaps across onboarding and observability (no release impact, pure polish)

**Timeline**: ~1-1.5 hours (parallel execution with 4 agents)

---

## Parallel Work Structure

### Wave 20a — SSH Key Auto-Discovery (Haiku Team A)

**Gap**: ON-007 (SSH key auto-discovery in forge)

**Deliverable**: Auto-populate SSH from `~/.ssh/` without manual bind-mount

**Owned Files**:
- images/default/entrypoint.sh (add SSH detection)
- images/default/lib-common.sh (SSH export logic)
- Add @trace gap:ON-007

**Effort**: 45 min

**Success Criteria**:
- Forge automatically discovers host SSH keys
- Keys available at `~/.ssh/` inside forge
- No manual bind-mount required
- No regressions

---

### Wave 20b — Agent Profile Auto-Load (Haiku Team B)

**Gap**: ON-008 (Agent onboarding profile auto-load)

**Deliverable**: Load user's preferred agent profile (codex, opus, haiku) from config

**Owned Files**:
- crates/tillandsias-core/src/config.rs (profile detection)
- images/default/config-overlay/mcp/agent-profile.sh (profile sourcing)
- Add @trace gap:ON-008

**Effort**: 1 hour

**Success Criteria**:
- Detect user's preferred agent from config
- Auto-load profile on forge startup
- Profile variables available in shell
- No regressions

---

### Wave 20c — Log Field Cardinality Analysis (Haiku Team C)

**Gap**: OBS-010 (Log field cardinality analysis)

**Deliverable**: Detect high-cardinality fields to prevent log explosion

**Owned Files**:
- crates/tillandsias-logging/src/lib.rs (cardinality detector)
- crates/tillandsias-headless/src/main.rs (wire cardinality check)
- Add @trace gap:OBS-010

**Effort**: 45 min

**Success Criteria**:
- Detect fields with unbounded cardinality
- Warn user when cardinality exceeds threshold
- Log analysis runs on startup
- No regressions

---

### Wave 20d — Evidence Bundle Retention Policy (Haiku Team D)

**Gap**: OBS-012 (Evidence bundle retention policy)

**Deliverable**: Auto-delete old convergence evidence bundles after N days

**Owned Files**:
- scripts/update-convergence-dashboard.sh (retention logic)
- crates/tillandsias-headless/src/main.rs (wire retention check)
- Add @trace gap:OBS-012

**Effort**: 45 min

**Success Criteria**:
- Evidence bundles older than 30 days auto-deleted
- Retention check runs on startup
- User notified of cleanup
- No regressions

---

## Handoff Protocol

**After each agent finishes**:
1. Agent creates checkpoint commit: `feat(p3): implement Gap ON-00X or OBS-00X`
2. Agent runs `./build.sh --ci-full` (verify no regressions)
3. Agent updates this note with completion status

**CI Gate**: All 4 agents must pass `./build.sh --ci-full` before integration.

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: images/default/entrypoint.sh, lib-common.sh (SSH detection)
- Team B: crates/tillandsias-core/src/config.rs, images/default/config-overlay/ (profile loading)
- Team C: crates/tillandsias-logging/src/lib.rs (cardinality analysis)
- Team D: scripts/update-convergence-dashboard.sh (evidence retention)

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [x] Team A (ON-007): SSH key auto-discovery — **COMPLETE** (commit: b837eae0)
- [x] Team B (ON-008): Agent profile auto-load — **COMPLETE** (commit: 29a4aabe)
- [x] Team C (OBS-010): Log field cardinality — **COMPLETE** (commit: 01f8d8ff)
- [x] Team D (OBS-012): Evidence bundle retention — **COMPLETE** (commit: 0c0a290f)
- [ ] CI verification: All 4 agents complete, running final ci-full gate

---

## Release Impact

**Important**: These are P3 gaps — non-blocking for release.

- ✅ Can ship WITHOUT Wave 20 (all P0-P2 done, Wave 18 validates)
- ✅ Can run in parallel with Day 2 manual test (independent work)
- ✅ If any fail: simply defer to post-release polish (no blocker)

---

## Timeline

**Concurrent with Day 2 manual smoke test**:
- 4 agents work in parallel (45 min to 1h each)
- Expected finish: 1-1.5 hours
- Results integrated before release decision if all pass

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
   - Gates release decision

---

**Orchestrator**: Haiku (main loop) — coordinates agents, verifies CI
**Execution**: 4 parallel agents (A, B, C, D) — implement gaps independently
**Timeline**: ~1-1.5 hours (parallel execution)
**Release Impact**: Zero (P3 polish, non-blocking)

