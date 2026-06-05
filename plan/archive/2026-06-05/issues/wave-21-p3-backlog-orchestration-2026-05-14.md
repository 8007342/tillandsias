---
task_id: p3-backlog/wave-21-opportunistic
wave: 21
iteration: 14
date: 2026-05-14
status: orchestration_ready
---

# Wave 21 — P3 Backlog Continuation (Onboarding Advanced + Observability)

**Intent**: multi_agent_orchestration (4 parallel agents on independent gaps)

**Context**: Waves 17-20 complete. 4 more P3 gaps ready for implementation. Day 2 manual test independent.

**Scope**: 4 opportunistic gaps across onboarding and observability (no release impact)

**Timeline**: ~1.5-2 hours (parallel execution with 4 agents)

---

## Parallel Work Structure

### Wave 21a — GitHub Token Refresh on Expiry (Haiku Team A)

**Gap**: ON-009 (GitHub token refresh on expiry)

**Deliverable**: Auto-refresh GitHub token via Secret Service when it expires

**Owned Files**:
- crates/tillandsias-core/src/secrets.rs (token refresh logic)
- crates/tillandsias-headless/src/main.rs (wire refresh check on startup)
- Add @trace gap:ON-009

**Effort**: 1 hour

**Success Criteria**:
- Detect expired GitHub tokens via Secret Service API
- Auto-refresh token before expiry
- No manual intervention required
- No regressions

---

### Wave 21b — Forge Dependency Resolver UX (Haiku Team B)

**Gap**: ON-010 (Forge dependency resolver UX)

**Deliverable**: Show which project deps are missing before launch

**Owned Files**:
- images/default/config-overlay/mcp/dependency-resolver.sh (new)
- crates/tillandsias-headless/src/main.rs (wire pre-launch check)
- Add @trace gap:ON-010

**Effort**: 1 hour

**Success Criteria**:
- Scan project for missing dependencies (Cargo.toml, package.json, etc.)
- Display list before launch
- Offer install options
- No regressions

---

### Wave 21c — Cache Eviction on Low-Disk Detection (Haiku Team C)

**Gap**: TR-006 (Cache eviction on low-disk detection)

**Deliverable**: Auto-clean old images/caches when disk usage > 85%

**Owned Files**:
- scripts/manage-cache.sh (cache eviction logic)
- crates/tillandsias-headless/src/main.rs (wire disk check on startup)
- Add @trace gap:TR-006

**Effort**: 45 min

**Success Criteria**:
- Detect disk usage via `df`
- Auto-delete old cached images when > 85% used
- Preserve 30 days of recent cache
- Log cleanup actions
- No regressions

---

### Wave 21d — Structured Log Query Language (Opus)

**Gap**: OBS-002 (Structured log query language)

**Deliverable**: Add Loki-style query syntax to trace index CLI

**Owned Files**:
- scripts/query-traces.sh (new query parser)
- crates/tillandsias-logging/src/query.rs (new query engine)
- Add @trace gap:OBS-002

**Effort**: 1.5 hours (Opus for complexity)

**Success Criteria**:
- Parse queries like `{spec="browser-isolation"} | count`
- Support filters, aggregations, grouping
- Integrate with trace index CLI
- No regressions

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: crates/tillandsias-core/src/secrets.rs (token refresh)
- Team B: images/default/config-overlay/mcp/dependency-resolver.sh (dependency check)
- Team C: scripts/manage-cache.sh (cache eviction)
- Team D: scripts/query-traces.sh + crates/tillandsias-logging/src/query.rs (query language)

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [x] Team A (ON-009): GitHub token refresh — completed d80e2d2a
  - Spawns as background task, 1s timeout, non-blocking on startup
  - Uses gh CLI to read token from OS keyring (GNOME Keyring)
  - Detects expiry via GitHub API /user endpoint
  - 5 existing tests pass + 8 new secrets module unit tests
  - All 27 headless tests pass + signal handling tests pass
  
- [x] Team B (ON-010): Dependency resolver UX — completed bf62d384
- [x] Team C (TR-006): Cache eviction — completed
- [x] Team D (OBS-002): Log query language — completed 9a8e25d0
- [x] CI verification: ALL TESTS PASSING (cargo test --workspace + ./build.sh --test)

---

## Release Impact

**Important**: These are P3 gaps — non-blocking for release.

- ✅ Can ship WITHOUT Wave 21
- ✅ Can run in parallel with Day 2 manual test
- ✅ If any fail: defer to post-release polish

---

## Timeline

**Concurrent with Day 2 manual smoke test**:
- 4 agents work in parallel (45 min to 1.5h each)
- Expected finish: 1.5-2 hours
- Results integrated before release decision if all pass

---

**Orchestrator**: Haiku — coordinates agents, verifies CI
**Execution**: 4 parallel agents (A, B, C, D) — implement gaps independently
**Timeline**: ~1.5-2 hours (parallel execution)
**Release Impact**: Zero (P3 polish, non-blocking)

