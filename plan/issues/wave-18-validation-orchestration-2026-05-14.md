---
task_id: p3-backlog/wave-18-validation-gate
wave: 18
iteration: 11
date: 2026-05-14
status: orchestration_ready
---

# Wave 18 Validation Gate — Agent Orchestration

**Intent**: multi_agent_orchestration (per methodology/bootstrap/router.yaml)

**Scope**: Implement 6 automated litmus tests + 1 E2E test for Podman idiomatic + browser isolation validation

**Release Gate**: All tests must pass before production release

---

## Parallel Work Structure

**Duration**: 1.5 days (Day 1: tests, Day 2: manual verification + release decision)

### Wave 18a — Tests 1-2 (Haiku Team A)
**File Scope**: openspec/litmus-tests/
**Tasks**:
- Test 1: Enclave network naming (tillandsias-<project>-enclave)
- Test 2: Transient error classification (is_transient() under network failure)
**Owned Files**:
- openspec/litmus-tests/litmus-podman-idiomatic-enclave-network.yaml
- openspec/litmus-tests/litmus-podman-idiomatic-error-classification.yaml
- openspec/litmus-bindings.yaml (add 2 bindings)
**Estimated Effort**: 1.5 hours
**Success Criteria**: Both litmus tests pass locally and in CI

### Wave 18b — Tests 3-4 (Haiku Team B)
**File Scope**: openspec/litmus-tests/
**Tasks**:
- Test 3: Event-driven monitoring (podman events arrival < 100ms)
- Test 4: Storage isolation (RO/RW/ephemeral per project)
**Owned Files**:
- openspec/litmus-tests/litmus-podman-idiomatic-event-driven.yaml
- openspec/litmus-tests/litmus-podman-idiomatic-storage-isolation.yaml
- openspec/litmus-bindings.yaml (add 2 bindings)
**Estimated Effort**: 2.5 hours
**Success Criteria**: Both litmus tests pass locally and in CI

### Wave 18c — Test 5 (Haiku Team C)
**File Scope**: openspec/litmus-tests/
**Tasks**:
- Test 5: Security flags (--userns=keep-id, --cap-drop=ALL enforced)
**Owned Files**:
- openspec/litmus-tests/litmus-podman-idiomatic-security-flags.yaml
- openspec/litmus-bindings.yaml (add 1 binding)
**Estimated Effort**: 0.75 hours
**Success Criteria**: Security flags litmus passes locally and in CI

### Wave 18d — Test 6 (Opus)
**File Scope**: openspec/litmus-tests/
**Tasks**:
- Test 6: Browser isolation E2E (forge→proxy→router→sidecar OTP validation chain)
**Owned Files**:
- openspec/litmus-tests/litmus-browser-isolation-e2e.yaml
- openspec/litmus-bindings.yaml (add 1 binding)
**Estimated Effort**: 2 hours
**Success Criteria**: E2E test launches all 4 containers, validates OTP chain, passes CI

---

## Handoff Protocol

**Before agents start**: Orchestrator (Haiku main) files this note.

**After each agent finishes**:
1. Agent merges its litmus bindings into openspec/litmus-bindings.yaml
2. Agent creates checkpoint commit: `feat(validation): add Test N litmus`
3. Agent runs `./build.sh --ci-full` to verify no regressions
4. Agent leaves a bootstrap refinement note in this file (section: "Progress")

**Between Day 1 and Day 2**:
1. Verify all 6 tests pass in CI
2. If any test fails: file issue, revert commit, create resolution task
3. If all tests pass: proceed to Day 2 manual smoke test

---

## File Scopes (No Conflicts)

All agents write to `openspec/litmus-tests/` (non-overlapping file names):
- Team A: litmus-podman-idiomatic-enclave-network.yaml, error-classification.yaml
- Team B: litmus-podman-idiomatic-event-driven.yaml, storage-isolation.yaml
- Team C: litmus-podman-idiomatic-security-flags.yaml
- Opus: litmus-browser-isolation-e2e.yaml
- All teams: Merge to openspec/litmus-bindings.yaml (sequential, no conflict)

---

## Progress (Updated by agents as they complete)

- [x] Team A (Tests 1-2): COMPLETED — Both litmus tests passing in CI (commit 1e74cddd)
  - litmus:podman-idiomatic-enclave-network — PASS
  - litmus:podman-idiomatic-error-classification — PASS
- [ ] Team B (Tests 3-4): Starting
- [ ] Team C (Test 5): Starting
- [ ] Opus (Test 6): Starting
- [ ] CI verification: Waiting for Teams B, C, Opus
- [ ] Manual smoke test: Pending all teams + CI green

---

## Release Gate Checklist

**Before shipping to production, ALL must be true:**

- [x] Test 1 (enclave network): ✅ PASSING (Team A, 2026-05-14)
- [x] Test 2 (transient error): ✅ PASSING (Team A, 2026-05-14)
- [ ] Test 3 (event-driven): ❌ PENDING (Team B)
- [ ] Test 4 (storage isolation): ❌ PENDING (Team B)
- [ ] Test 5 (security flags): ❌ PENDING (Team C)
- [ ] Test 6 (browser E2E): ❌ PENDING (Opus)
- [ ] ./build.sh --ci-full: ❌ PENDING (waiting for Teams B, C, Opus)
- [ ] Manual smoke test: ❌ PENDING (Day 2)
- [ ] All regressions resolved: ❌ PENDING (Day 2)

**If any unchecked**: Do not ship. File issue, fix, re-validate.

---

## Known Issues / Constraints

- Litmus tests may require live containers (cannot run in CI sandbox if CI uses lightweight containers)
  - Resolution: Define fallback to manual litmus if CI environment insufficient
- Browser E2E requires 4 containers running simultaneously (forge, git, proxy, router)
  - Resource requirement: 2GB RAM minimum, 10GB disk
  - Time requirement: 5-10 min per test run
- Manual smoke test is human-driven (not automated)
  - Time: 30 min

---

## Specs Governing This Work

- openspec/specs/podman-idiomatic-patterns/spec.md (7 requirements, Tests 1-5 validate 5)
- openspec/specs/subdomain-routing-via-reverse-proxy/spec.md (Test 6 validates critical path)

---

## Next Actions

1. **Launch 4 parallel agents** (Teams A, B, C, Opus)
2. **Each agent**:
   - Reads plan/steps/10-validation-gate.md (detailed test specs)
   - Implements assigned litmus test(s)
   - Updates openspec/litmus-bindings.yaml
   - Runs `./build.sh --ci-full` to verify
   - Creates checkpoint commit
   - Updates this note with completion
3. **After all agents finish**: Verify CI green, proceed to manual smoke test
4. **Manual smoke test** (Day 2): Full user workflow validation

---

**Orchestrator**: Haiku (main loop) — coordinates, verifies CI, gates release decision
**Execution**: 4 parallel agents (A, B, C, Opus) — implement tests independently
**Timeline**: ~1.5 days total (Day 1: tests, Day 2: manual + release decision)

