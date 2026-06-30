---
task_id: p2-backlog/wave-26-hygiene
wave: 26
iteration: 13+
date: 2026-05-14
status: planning
---

# Wave 26+ — Post-Release Hygiene & Polish

**Intent**: Scheduled work after release ships (non-blocking)

**Context**: Waves 17-25 complete. Release approval pending manual smoke test. Wave 26+ covers post-release monitoring, user feedback integration, and remaining P2 gaps.

**Scope**: User issue triage, optional polish, performance optimizations

**Timeline**: Ongoing (low priority, asynchronous)

---

## Phase 1: Post-Release Monitoring (Days 1-7)

### Day 1-2: Hotfix Readiness
- Monitor GitHub issues for crash reports
- Triage severity (critical/high/low)
- Prepare hotfix commits if blocking issues surface
- Keep release branch (main) clean; hotfixes on hotfix/* branches

### Day 3-7: User Feedback Integration
- Collect environment-specific issues (macOS-reported issues despite Linux-only focus)
- Document edge cases discovered in real usage
- Identify performance regressions or surprises
- Update documentation based on user confusion points

---

## Phase 2: Remaining P2 Gaps (Optional Polish)

**Not required for release. Pick as capacity allows.**

### High-Value P2 Gaps (if resources available)

1. **OBS-001**: Log field name stability litmus
   - MEDIUM severity, MEDIUM effort (~3h)
   - Prevents silent breaking changes in log schema
   - Add CI gate that validates log field backwards compatibility

2. **OBS-003**: Log schema version field (if not already done)
   - LOW severity, SMALL effort (~1h)
   - Tracks schema version for downstream consumers
   - Add version field to all log records

3. **OBS-018**: Evidence bundle auto-generation
   - MEDIUM severity, MEDIUM effort (~3h)
   - Convergence claims need backing evidence
   - Auto-generate evidence bundles on test completion

4. **OBS-021 Extended**: Evidence bundle signature verification
   - LOW severity, MEDIUM effort (~2h)
   - Cryptographic validation of evidence
   - Optional hardening, can defer

5. **TR-003**: Cache corruption recovery
   - MEDIUM severity, MEDIUM effort (~2h)
   - Can block container start if cache corrupted
   - Add recovery path for corrupted cache files

### Lower-Priority P2 Gaps (backlog for Wave 27+)
- BR-001, BR-002, BR-007, BR-008 (Wave 4 routing prerequisites)
- OBS-006, OBS-010 (observability extensions)
- Other P2 items in gap-triage-matrix

---

## Phase 3: Post-Release Issue Investigation

**Format**: Each user-reported issue becomes a Wave 26.X sub-task

### Example Workflow
1. User reports issue on GitHub
2. Reproduce locally, categorize (bug / feature request / documentation)
3. If bug: create hotfix, test, merge to main
4. If feature: assess fit for Wave 26 or defer to Wave 27+
5. If documentation: update cheatsheets/wiki, link issue

---

## Phase 4: Release Retrospective (Day 7-14)

### Conducted By: Release team (async)

**Questions to Answer**:
- What surprised us in real usage?
- Which P3 gaps are now high-priority based on user feedback?
- Which undocumented P3 gaps should move to P2?
- What should we fix in Wave 26 vs defer to Wave 27?
- Documentation gaps discovered by users?

**Output**: Wave 26 recommendations memo for next iteration planning

---

## Unblocked Work (Can Start Immediately After Release)

These are ready to implement in parallel with post-release monitoring:

### High-Priority (if volunteers available)
1. OBS-001 (log field stability) — 3h, valuable gate
2. OBS-018 (evidence bundle generation) — 3h, convergence requirement
3. TR-003 (cache corruption recovery) — 2h, reliability improvement

### Medium-Priority
- OBS-003 (schema version) — 1h, low effort
- OBS-014/15 (resource metrics) — 6h, production observability

### Low-Priority
- All other P2 gaps from matrix
- P3 optimizations

---

## Known Issues to Monitor

Post-release, watch for:

1. **Nix/Image Build Issues**: Squid 6.x EOF on large pulls (mitigation: host-side pulling)
2. **Tray UI Flakiness**: GTK event loop timeouts under high load (pre-existing, known)
3. **Proxy Cache Issues**: .localhost routing edge cases with cache_peer
4. **Enclave Network Issues**: Container-to-container communication latency
5. **OTP Form Rendering**: Data-URI injection edge cases on different Chromium versions

---

## Success Criteria for Wave 26+

- [x] Release ships without critical blockers
- [ ] Any Day 1-2 hotfixes deployed
- [ ] User feedback collected and triaged
- [ ] P2 gap(s) tackled (optional, as capacity allows)
- [ ] Documentation updated based on user experience
- [ ] Release retrospective completed (Day 7-14)

---

## Escalation Criteria

**If any of these occur, invoke emergency Wave 26 hotfix**:
- ❌ Crash on init (cannot build images)
- ❌ Graceful shutdown not working (container orphaning)
- ❌ Security issue (credential leaks, unauthorized access)
- ❌ Data loss (cache corruption losing project state)
- ❌ Completely broken on common environment

**Hotfix Process**:
1. Create hotfix/* branch from main
2. Implement fix with tests
3. PR to main (fast-track review)
4. Tag v0.1.X.(X+1) and re-release

---

## Wave 26 Coordination

**Orchestrator**: Haiku (async monitoring, triage)  
**Agents**: Available for P2 gap implementation (on-demand)  
**Timeline**: Ongoing (asynchronous, low priority)  
**Scope**: Non-blocking enhancements + user issue triage

---

## Transition to Wave 27+

Once Wave 26 work is triaged and any critical issues addressed:

1. Update gap-triage-matrix with user feedback
2. Reprioritize P3 gaps based on real usage patterns
3. Plan Wave 27 for next batch of P2 work
4. Consider cross-platform support (Windows/macOS) if demand exists

---

**Status**: Planned (post-release work)  
**Owner**: Release team (async)  
**Blocker**: None (starts after release approval)

Next: Execute manual smoke test (Step 11), then activate Wave 26 post-release monitoring.
