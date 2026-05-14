# Step 10 — Validation Gate (Wave 18)

**Status**: Ready to Start
**Order**: 9a (blocking pre-release step)
**Depends On**: p3-backlog/wave-17-i18n (completed)
**Scope**: End-to-end validation of critical architectural layers identified as implemented but unvalidated in code audit

---

## Context: The Validation Gap

**Audit Finding** (implementation-audit-2026-05-14.md):
- ✅ Podman idiomatic patterns: Code complete (is_transient, enclave_network_name, security flags, event-driven monitoring)
- ❌ **Never validated end-to-end with real containers**
- ✅ Browser isolation: Code complete (3-layer routing: Squid→Caddy→sidecar)
- ❌ **Never tested with actual forge→proxy→router→sidecar chain running live**
- ✅ Cache corruption recovery: Code exists
- ❌ **Untested under actual corruption scenarios**

**Release Blocker**: These are P0-equivalent validations — code can be correct but architecture can silently fail at integration boundaries.

**Wave 18 Purpose**: Remove the validation gap before shipping to production.

---

## Validation Scope: 3 Requirement Areas

### Area 1: Podman Idiomatic Patterns (5 E2E Tests)

**Spec**: openspec/specs/podman-idiomatic-patterns/spec.md
**Code Locations**: crates/tillandsias-podman/src/{client.rs, lib.rs}
**Gap**: Unit tests pass but live container behavior never observed

#### Test 1: Enclave Network Naming Convention

**Requirement**: Containers launched for a project use network named `tillandsias-<project>-enclave`

**Test Steps**:
```bash
1. Create test project "validation-test"
2. Launch forge, git-service, proxy, router containers via tillandsias
3. Run: podman network ls --filter name=tillandsias-validation-test-enclave
4. Verify network exists and all 4 containers are connected
5. Cleanup: podman network rm tillandsias-validation-test-enclave
```

**Success Criteria**:
- Network name matches pattern exactly
- All project containers are connected to the enclave network
- Network is isolated from host network and other projects

**Effort**: 45 min
**File**: openspec/litmus-tests/litmus-podman-idiomatic-enclave-network.yaml

---

#### Test 2: Transient Error Retry Logic

**Requirement**: Container launch retries correctly on transient errors (network timeout, connection refused) but fails fast on permanent errors

**Test Steps**:
```bash
1. Start podman, create test container
2. Monitor podman events stream
3. Simulate transient failure: kill network bridge momentarily while container starting
4. Verify is_transient() returns true and retry loop continues (3 attempts)
5. Simulate permanent failure: launch with invalid image name
6. Verify is_transient() returns false and error propagates immediately
```

**Success Criteria**:
- Transient (network error, timeout, connection refused): is_transient() = true, retry proceeds
- Permanent (not found, permission denied, parse error): is_transient() = false, error propagates
- Exponential backoff delays between retries: 100ms, 200ms, 400ms

**Effort**: 1 hour
**File**: openspec/litmus-tests/litmus-podman-idiomatic-error-classification.yaml

---

#### Test 3: Event-Driven Container Monitoring (No Polling)

**Requirement**: Container lifecycle is monitored via `podman events` stream, not polling loops

**Test Steps**:
```bash
1. Start podman events listener on background
2. Record event arrival times
3. Launch container, monitor start event
4. Stop container, monitor stop event
5. Verify all events arrive within 100ms of actual state change
```

**Success Criteria**:
- Events arrive within 100ms of state change (demonstrates event-driven, not polling)
- All container lifecycle transitions (create, start, running, stop, die) are captured
- No polling-based fallback activated (event listener stays active)

**Effort**: 1 hour
**File**: openspec/litmus-tests/litmus-podman-idiomatic-event-driven.yaml

---

#### Test 4: Storage Isolation Per Project

**Requirement**: Project path mounted RO, workspace RW, ephemeral tmpfs isolated per container

**Test Steps**:
```bash
1. Create two projects: project-a, project-b
2. Launch forge containers for each
3. In project-a forge: write to /workspace/file.txt, verify success
4. In project-a forge: attempt write to /src (project path), verify EROFS
5. In project-a forge: check /tmp is ephemeral (empty on each container start)
6. In project-b forge: verify /workspace is isolated (no project-a file.txt)
7. Kill project-a container, re-launch project-a forge
8. Verify /tmp is empty (ephemeral mount not persisted)
```

**Success Criteria**:
- Project path (/src) is read-only (EROFS on write)
- Workspace (/workspace) is read-write and isolated per project
- /tmp is ephemeral (recreated on each container launch)
- No cross-project workspace contamination

**Effort**: 1.5 hours
**File**: openspec/litmus-tests/litmus-podman-idiomatic-storage-isolation.yaml

---

#### Test 5: Security Flags Applied (--userns=keep-id, --cap-drop=ALL)

**Requirement**: Containers enforce security context with mandatory flags

**Test Steps**:
```bash
1. Launch forge container
2. Inside container: id -u (verify not uid 0)
3. Inside container: getcap /usr/bin/ping (verify ping has no capabilities)
4. Inside container: try to run privileged operation (e.g., ip link add), verify EPERM
5. Verify podman inspect shows: --userns=keep-id, --cap-drop=ALL
```

**Success Criteria**:
- Container runs as non-root (uid != 0)
- No capabilities set (--cap-drop=ALL enforced)
- Privileged operations rejected with permission denied
- podman inspect output contains security flags

**Effort**: 45 min
**File**: openspec/litmus-tests/litmus-podman-idiomatic-security-flags.yaml

---

### Area 2: Browser Isolation E2E (1 Integration Test)

**Spec**: openspec/specs/subdomain-routing-via-reverse-proxy/spec.md
**Code Locations**: images/router/Containerfile, images/proxy/squid.conf, crates/tillandsias-core/src/state.rs
**Gap**: Three-layer routing (Squid→Caddy→sidecar) integrated but never tested with all 4 containers running

#### Test 6: Forge→Proxy→Router→Sidecar E2E Chain

**Requirement**: OpenCode Web session request flows through proxy→router→sidecar for OTP validation

**Test Steps**:
```bash
1. Launch full enclave: forge, git-service, proxy, router (4 containers)
2. Create mock OpenCode service in forge container
3. Generate OTP via tillandsias-otp
4. From forge: curl to .localhost subdomain through proxy
5. Router intercepts, validates OTP via sidecar
6. Verify request reaches OpenCode service in forge
7. Verify response returns to forge client
```

**Success Criteria**:
- Request traverses proxy→router→sidecar without timeout
- OTP validation succeeds (router sidecar validates token)
- Request reaches target service in forge
- Response headers include router's validation status
- End-to-end latency < 500ms

**Effort**: 2 hours (container orchestration + network debugging)
**File**: openspec/litmus-tests/litmus-browser-isolation-e2e.yaml

---

### Area 3: Manual Smoke Test

**Scope**: Full user workflow validation (not automated)

#### Test 7: Full Init→Launch→OpenCode Web Workflow

**Test Steps**:
```bash
1. Clean slate: remove ~/.cache/tillandsias if present
2. Run: ./build.sh --ci-full --install
3. Verify: tillandsias binary installed to ~/.local/bin/tillandsias
4. Create test project: mkdir ~/test-opencode-web && cd ~/test-opencode-web && git init
5. Run: tillandsias --init --debug
6. Verify: all images built (proxy, git, forge, inference, chromium-core, router)
7. Wait for "ready" message in logs
8. Launch OpenCode Web: tillandsias --opencode-web ~/test-opencode-web
9. Verify: Chromium opens automatically
10. Verify: OTP form appears (data-URI injection)
11. Verify: OTP auto-submits and validates
12. Verify: OpenCode Web loads in browser
13. Verify: Tray shows "test-opencode-web" with status icon Blushing→Blooming
14. Manual verification: browser can access localhost services through router
15. Cleanup: tillandsias --stop (graceful shutdown with SIGTERM, 30s timeout)
16. Verify: all containers cleaned up (podman ps shows none running)
```

**Success Criteria**:
- --ci-full passes all tests (500+ tests)
- --install succeeds without permission errors
- --init builds all images (no Nix errors, no EOF from proxy)
- Chromium launches with data-URI form injection
- OTP submits and validates successfully
- OpenCode Web loads and is accessible
- Tray icon transitions: Initializing→Ready→Blushing→Blooming
- Graceful shutdown completes within 30s, all containers cleaned

**Effort**: 30 min (manual exploration)
**Verification**: Screenshots + logs saved to docs/validation-evidence-2026-05-14/

---

## Litmus Test Coverage

All 6 automated tests map to litmus definitions:

| Test ID | Spec | Litmus Binding | Coverage |
|---------|------|---|---|
| Test 1 | podman-idiomatic-patterns | litmus:podman-idiomatic-enclave-network | NEW |
| Test 2 | podman-idiomatic-patterns | litmus:podman-idiomatic-error-classification | NEW |
| Test 3 | podman-idiomatic-patterns | litmus:podman-idiomatic-event-driven | NEW |
| Test 4 | podman-idiomatic-patterns | litmus:podman-idiomatic-storage-isolation | NEW |
| Test 5 | podman-idiomatic-patterns | litmus:podman-idiomatic-security-flags | NEW |
| Test 6 | subdomain-routing-via-reverse-proxy | litmus:browser-isolation-e2e | NEW |

**Coverage Target**: 90% of podman-idiomatic-patterns requirements; 100% of subdomain-routing critical path

---

## Execution Plan (Wave 18)

**Duration**: 1.5 days (parallel execution)

### Day 1: Automated Test Implementation (4-5 parallel agents)

- **Haiku-A**: Test 1 + Test 2 (enclave network, error classification) — 1.5h
- **Haiku-B**: Test 3 + Test 4 (event-driven, storage isolation) — 2.5h
- **Haiku-C**: Test 5 (security flags) — 45 min
- **Opus**: Test 6 (browser E2E chain) — 2h

**Checkpoint**: After all agents merge, run `./build.sh --ci-full` to verify no regressions

### Day 2: Manual Smoke Test + Release Readiness

- Manual tester (human): Test 7 (full workflow)
- Generate evidence bundle (screenshots, logs)
- Final go/no-go decision for production release

**Criteria for Release**:
- ✅ All 6 automated tests passing
- ✅ ./build.sh --ci-full green (no regressions)
- ✅ Manual smoke test successful
- ✅ No new HIGH/CRITICAL issues in test output

---

## Success Criteria (Release Gate)

**Before shipping to production, ALL of the following must be true:**

1. **Podman Idiomatic Tests** (1-5): 5/5 passing
2. **Browser Isolation E2E** (6): passing
3. **Manual Smoke Test** (7): successful with evidence
4. **CI Gate**: ./build.sh --ci-full green, 500+ tests passing
5. **Regressions**: zero new test failures
6. **Trace Coverage**: ≥80% (already gated in CI)

**If any test fails**: File a new issue under plan/issues/, revert the failing commit, and make a decision (fix or defer).

---

## Files Modified in This Step

- plan/steps/10-validation-gate.md — this file (new)
- openspec/litmus-tests/litmus-podman-idiomatic-enclave-network.yaml (new)
- openspec/litmus-tests/litmus-podman-idiomatic-error-classification.yaml (new)
- openspec/litmus-tests/litmus-podman-idiomatic-event-driven.yaml (new)
- openspec/litmus-tests/litmus-podman-idiomatic-storage-isolation.yaml (new)
- openspec/litmus-tests/litmus-podman-idiomatic-security-flags.yaml (new)
- openspec/litmus-tests/litmus-browser-isolation-e2e.yaml (new)
- openspec/litmus-bindings.yaml (add 6 new bindings)

---

## Sign-Off

**Wave**: 18 (Pre-Release Validation)
**Blocking**: YES — production release depends on passing all tests
**Iteration**: 11 (after Wave 17)
**Date**: 2026-05-14

**Next Action**: Start Day 1 test implementation with 4-5 parallel agents (recommended Haiku teams).

