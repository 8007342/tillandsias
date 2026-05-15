---
task_id: p3-backlog/wave-25-post-release-polish
wave: 25
iteration: 12
date: 2026-05-14
status: orchestration_ready
---

# Wave 25 — Post-Release Polish & P1 Consolidation

**Intent**: multi_agent_orchestration (parallel agents on remaining P1 + undocumented P3 gaps)

**Context**: Waves 17-24 complete (24/27 P3 gaps). Manual smoke test (Wave 18) pending for release gate. Wave 25 starts after release decision.

**Scope**: Consolidate high-priority P1 gaps + identify/implement remaining 3 undocumented P3 gaps

**Timeline**: ~2-2.5 hours (parallel execution with 4 agents)

---

## Parallel Work Structure

### Wave 25a — P1: Squid .localhost Cache Peer (Haiku Team A)

**Gap**: BR-003 (Squid .localhost cache_peer configuration)

**Deliverable**: Configure Squid to forward .localhost requests through cache_peer to Caddy (router)

**Owned Files**:
- images/proxy/squid.conf (add cache_peer config for .localhost)
- crates/tillandsias-headless/src/main.rs (verify cache_peer initialization)
- openspec/specs/subdomain-routing-via-reverse-proxy/spec.md (update if needed)
- Add @trace gap:BR-003

**Effort**: 1 hour

**Success Criteria**:
- Squid cache_peer targets Caddy on enclave network
- .localhost requests route to router (not internet)
- Agents inside forge can curl https://service.localhost through proxy
- DNS/CONNECT method works correctly
- 3+ unit tests for cache_peer configuration
- No regressions

---

### Wave 25b — P1/P2: Missing Observability Event Coverage (Haiku Team B)

**Gaps**: OBS-021 (Secret rotation events) + OBS-022 (Image build events)

**Deliverable**: Add structured event logging for sensitive operations (secret rotation, image builds)

**Owned Files**:
- crates/tillandsias-logging/src/event_collector.rs (new module for audit events)
- crates/tillandsias-headless/src/main.rs (wire event collection)
- openspec/specs/runtime-logging/spec.md (add event schema requirements)
- Add @trace gap:OBS-021, gap:OBS-022

**Effort**: 1.5 hours

**Success Criteria**:
- Secret rotation logged with timestamp, actor, resource (no secret value)
- Image build completion logged with image name, duration, success/failure
- All events have structured format: timestamp, event_type, metadata
- 4+ unit tests for event collection
- No PII leakage in logs
- No regressions

---

### Wave 25c — P3: Undocumented Gap Triage #1 (Haiku Team C)

**Gap**: OBS-024 (Undocumented observability gap TBD)

**Deliverable**: Identify and implement one undocumented P3 observability gap

**Owned Files**:
- plan/issues/undocumented-p3-gaps-wave-25.md (triage notes)
- Implementation files TBD based on gap
- Add @trace gap:OBS-024

**Effort**: 1 hour

**Success Criteria**:
- Gap clearly defined in issue file
- Implementation complete and tested
- Tests passing locally
- No regressions

**Notes**: Team C will triage remaining P3 gaps from gap-triage-matrix-2026-05-14.md and pick the highest-priority undocumented one.

---

### Wave 25d — P3: Undocumented Gaps #2 + #3 (Opus)

**Gaps**: OBS-025, TR-010 (Undocumented P3 gaps TBD)

**Deliverable**: Identify and implement two undocumented P3 gaps (one observability, one tray)

**Owned Files**:
- plan/issues/undocumented-p3-gaps-wave-25.md (triage notes)
- Implementation files TBD based on gaps
- Add @trace gap:OBS-025, gap:TR-010

**Effort**: 1.5 hours

**Success Criteria**:
- Both gaps clearly defined
- Implementation complete and tested
- Tests passing locally and in CI
- No regressions

**Notes**: Opus will identify the 2 highest-priority undocumented gaps from matrix and implement both.

---

## File Scopes (No Conflicts)

Each agent owns separate files:
- Team A: images/proxy/squid.conf (Squid BR-003)
- Team B: crates/tillandsias-logging/src/event_collector.rs (OBS-021, OBS-022)
- Team C: Implementation files for OBS-024 TBD
- Opus: Implementation files for OBS-025 + TR-010 TBD

No overlapping file ownership — safe for parallel execution.

---

## Progress (Updated by agents)

- [x] Team A (BR-003): Squid .localhost cache_peer — **COMPLETE** (implemented by Team B in OBS-021+OBS-022 commit)
- [x] Team B (OBS-021, OBS-022): Event coverage — **COMPLETE** (also included BR-003 cache_peer fix)
- [x] Team C (OBS-005): Dead trace detection — **COMPLETE** (a4f5f092, a2d22844, 15 tests passing, 226 dead traces detected)
- [ ] Opus (OBS-025, TR-010): Undocumented P3 gaps #2+#3 — in progress
- [ ] CI verification: Pending (Opus completion + all agents pass)

---

## Release Impact

**Important**: These are P1 + P3 gaps — not release-blocking, but improve MVP quality.

- ✅ Can ship WITHOUT Wave 25 (automated phase already complete)
- ✅ Wave 25 recommended for post-release stability
- ✅ If any fail: defer non-blocking items to Wave 26

---

## Timeline

**Concurrent execution**:
- 4 agents work in parallel (1–1.5h each)
- Expected finish: ~2 hours
- Recommended: After manual smoke test and release approval

---

## Gap Identification Process (Wave 25c + Opus)

Since the remaining 3 P3 gaps are undocumented, Teams C and Opus should:

1. **Analyze gap-triage-matrix-2026-05-14.md** for P3 items
2. **Check TRACES.md** for which gaps were already addressed in Waves 17-24
3. **Pick the 3 highest-priority unclaimed gaps** by:
   - Severity (prefer MEDIUM > LOW)
   - Effort (prefer SMALL < MEDIUM for faster iteration)
   - Impact (prefer gaps with clear acceptance criteria)
4. **Create issue files** in plan/issues/undocumented-p3-gaps-wave-25.md documenting:
   - Gap ID, title, severity, effort
   - Why it's important
   - Acceptance criteria
   - Implementation path
5. **Implement and verify** before merging

---

**Orchestrator**: Haiku — coordinates agents, verifies CI  
**Execution**: 4 parallel agents (A, B, C, Opus) — implement gaps independently  
**Timeline**: ~2 hours (parallel execution)  
**Release Impact**: Zero (post-release polish, non-blocking)
