# Step 11a — Documentation Debt Payoff (Waves A-D)

**Status**: In Progress (Wave A ready, Waves B-D pending)
**Order**: 11.5 (between release-readiness and post-release-polish)
**Depends On**: p3-backlog (order 9)
**Blocks**: post-release-polish (order 12)

---

## Context

Three recent implementation sessions (Waves 17-24) closed critical functionality but left documentation gaps:

- **Missing Event Records** (3) — Runtime events emitted without OpenSpec event definitions
- **Missing Spec Coverage** (3) — Implemented capabilities with no formal specs
- **Missing Litmus Tests** (1) — Specs with no executable validation
- **Incomplete Specs** (2) — Specs with outdated or incomplete requirements

This step records the documentation debt and orchestrates parallel agent waves to close the gaps post-implementation.

---

## Documentation Debt Triage

### Missing Event Records (3 events)

Events emitted at runtime but never formally registered in OpenSpec:

| Event ID | Title | Module | Category | Impact |
|----------|-------|--------|----------|--------|
| **EV-001** | i18n locale load | forge/localization.sh | Onboarding | P2: Spec-coverage gap |
| **EV-002** | model-pull-background-start | images/inference/ | Inference | P2: Spec-coverage gap |
| **EV-003** | podman-enclave-network-created | tillandsias-podman | Orchestration | P2: Spec-coverage gap |

**Action**: Create corresponding event definitions in `methodology/events/`.

---

### Missing Spec Definitions (3 specs)

Implemented capabilities with no formal OpenSpec specs:

| Spec ID | Title | Module | Category | Impact |
|---------|-------|--------|----------|--------|
| **SP-001** | forge-localization-pipeline | images/default/ | Onboarding | P2: Spec-coverage gap |
| **SP-002** | inference-lazy-model-pull | images/inference/ | Inference | P2: Spec-coverage gap |
| **SP-003** | podman-enclave-network-core | crates/tillandsias-podman/ | Security | P2: Spec-coverage gap |

**Action**: Create corresponding specs in `openspec/specs/`.

---

### Missing Litmus Test (1 test)

Specs with no executable validation:

| Spec ID | Title | Effort | Coverage |
|---------|-------|--------|----------|
| **LT-001** | litmus:podman-enclave-network | Small | 0% (placeholder only) |

**Action**: Write integration test covering enclave network naming and event emission.

---

### Incomplete Spec Coverage (2 specs)

Specs whose requirements diverged from implementation during development:

| Spec ID | Title | Gap | Impact |
|---------|-------|-----|--------|
| **UP-001** | podman-idiomatic-patterns | GAP-1, GAP-2 defer graphroot + secret-builder refactors | Implementation ahead of spec |
| **UP-002** | inference-host-side-pull | Model tier mapping incomplete; GPU detection logic needs formal definition | Spec outdated |

**Action**: Update specs to reflect implementation reality and defer refactor work to later waves.

---

## Wave Breakdown

### Wave A: Event Records & Specs (Small, Parallel)

**Effort**: 3-4 hours (3 agents, 1 event + 1 spec each, 1 shared spec)
**Owners**: Haiku-A, Haiku-B, Haiku-C

| Agent | Task | Deliverable | Verification |
|-------|------|-------------|--------------|
| **A** | EV-001 + SP-001 (forge-localization) | `methodology/events/ev-001-i18n-locale-load.yaml` + `openspec/specs/forge-localization-pipeline/spec.md` | Spec references ≥1 cheatsheet; event YAML valid; @trace annotations in forge/localization.sh |
| **B** | EV-002 + SP-002 (inference-pull) | `methodology/events/ev-002-model-pull-background-start.yaml` + `openspec/specs/inference-lazy-model-pull/spec.md` | Spec references cheatsheets/runtime/inference.md; event emitted in images/inference/ollama-*; @trace added |
| **C** | EV-003 + SP-003 (podman-enclave) | `methodology/events/ev-003-podman-enclave-network-created.yaml` + `openspec/specs/podman-enclave-network-core/spec.md` | Spec references podman-idiomatic-patterns; event emitted in tillandsias-podman/src/client.rs; @trace added |

**Acceptance Criteria**:
- 3 event YAML files created with proper schema
- 3 specs created with ≥6 requirements, Sources of Truth section, @trace annotations
- All new files merge cleanly (no conflicts)
- `cargo test --workspace` passes (no regressions)

**Success Gate**: All 3 agents report completion within 2 hours; merge to linux-next.

---

### Wave B: Litmus Test Implementation (Small, Single Agent)

**Effort**: 2-3 hours
**Owner**: Haiku-D (or Wave-A overflow agent)
**Dependency**: Wave A must complete (need podman-enclave-network-core spec finalized)

**Task**: Write `openspec/litmus-tests/litmus-podman-enclave-network-*.yaml` covering:

1. **Enclave Network Creation** — Create enclave network with correct naming (`tillandsias-<project>-enclave`)
2. **Event Emission** — Verify `podman-enclave-network-created` event emitted with correct metadata
3. **Isolation Verification** — Containers in enclave can reach each other; unreachable from host
4. **Cleanup** — Enclave network deleted when last container exits

**Deliverable**: `openspec/litmus-tests/litmus-podman-enclave-network-isolation.yaml`

**Verification**:
- `./build.sh --test --filter podman-enclave-network` passes (4/4 tests)
- Coverage: ≥50%
- No flaky tests (run 3x)

**Success Gate**: Litmus test fully passing; linked in `openspec/litmus-bindings.yaml`; merge to linux-next.

---

### Wave C: Spec Updates (Medium, Parallel)

**Effort**: 2-3 hours
**Owners**: Haiku-E, Haiku-F

**Task 1** (Agent E): Update `openspec/specs/podman-idiomatic-patterns/spec.md`

- Document GAP-1 (graphroot) and GAP-2 (secret-builder) as deferred work
- Link to plan/issues/podman-crate-audit.md for traceability
- Update `## Sources of Truth` section
- Add `## Deferred Refactors` section with migration notes
- Run `./build.sh --ci --filter podman-idiomatic` (no test changes needed)

**Task 2** (Agent F): Update `openspec/specs/inference-host-side-pull/spec.md`

- Formalize GPU tier detection logic (move from CLAUDE.md to spec requirements)
- Update model tier mapping table with T0-T5 definitions
- Add Sources of Truth references: cheatsheets/runtime/gpu-detection.md, CLAUDE.md Inference Container section
- Document lazy-pull trigger (after health check, non-blocking)
- Run `./build.sh --test --filter inference` (no new tests needed)

**Verification**:
- Both specs pass `openspec validate` (no errors)
- No new litmus tests required (pre-existing tests still pass)
- Specs marked `updated:2026-05-16` in metadata
- Merge to linux-next independently (no conflicts expected)

**Success Gate**: Both agents report completion; git diff shows spec updates only (no code changes); CI passes.

---

### Wave D: Integration & Verification (Medium, Single Agent)

**Effort**: 2-3 hours
**Owner**: Opus (or Wave-C overflow agent)
**Dependency**: Waves A, B, C must complete

**Task**: Full integration verification and merge coordination

1. **Event Schema Validation** — All 3 event YAML files conform to `methodology/event/schema.yaml`
2. **Spec Cross-References** — All 6 specs (3 new + 2 updated + podman-enclave-network-core) have valid `Sources of Truth` sections
3. **Litmus Binding** — New litmus test bound in `openspec/litmus-bindings.yaml` under `podman-enclave-network-isolation`
4. **Trace Audit** — All new code has `@trace spec:` annotations (run `git log --grep='@trace' -p` on new commits)
5. **Build & Test** — `./build.sh --ci-full --test` passes with no regressions
6. **Version Bump** — Increment build number (if agents modified code) or change count (if specs only)

**Deliverables**:
- `plan/steps/11a-doc-debt-payoff.md` → status: `completed`
- Single merge commit combining Waves A-C + Wave D verification
- Evidence report in step file

**Verification Checklist**:
- [ ] 3 events registered in methodology/events/
- [ ] 3 new specs created (forge-localization, inference-pull, podman-enclave)
- [ ] 2 specs updated (podman-idiomatic, inference-host-side-pull)
- [ ] 1 litmus test passing (podman-enclave-network-isolation)
- [ ] All 6 specs have Sources of Truth
- [ ] All new code has @trace annotations
- [ ] `./build.sh --ci-full` passing (no regressions)
- [ ] Git history clean (4 commits: 1 per wave)

**Success Gate**: Opus reports all checks passing; creates merge commit and pushes to origin/linux-next.

---

## Exit Criteria

**Wave A Complete**:
- 3 events + 3 specs created and passing validation
- All tests passing
- Merge to linux-next

**Wave B Complete**:
- 1 litmus test passing (≥50% coverage)
- All tests still passing
- Merge to linux-next

**Wave C Complete**:
- 2 specs updated (no regressions)
- Build passes
- Merge to linux-next

**Wave D Complete**:
- Full integration verified
- Single merge commit combining all work
- `./build.sh --ci-full --test` passing
- Documentation debt closed

**Step Status**: `completed` when Wave D finishes and merge is pushed.

---

## Estimated Timeline

- **Wave A**: 0-2h (3 parallel agents)
- **Wave B**: 2-4h (depends on Wave A; 1 agent)
- **Wave C**: 2-4h (parallel with Wave B; 2 agents)
- **Wave D**: 2-4h (depends on A+B+C; 1 agent)

**Total**: 6-10 hours wall-clock (if all waves run in parallel where possible)

**Checkpoint Schedule**:
- After Wave A: Commit + push (all 3 agents)
- After Wave B: Commit + push (1 agent)
- After Wave C: Commit + push (2 agents)
- After Wave D: Merge commit + push (1 agent)

---

## Files Modified in This Step

**Created**:
- plan/steps/11a-doc-debt-payoff.md (this file)
- plan/issues/documentation-debt-2026-05-16.md (triage summary)
- plan/issues/ghost-trace-sweep-backlog-2026-05-16.md (future work)
- methodology/events/ev-001-i18n-locale-load.yaml
- methodology/events/ev-002-model-pull-background-start.yaml
- methodology/events/ev-003-podman-enclave-network-created.yaml
- openspec/specs/forge-localization-pipeline/spec.md
- openspec/specs/inference-lazy-model-pull/spec.md
- openspec/specs/podman-enclave-network-core/spec.md
- openspec/litmus-tests/litmus-podman-enclave-network-*.yaml

**Updated**:
- openspec/specs/podman-idiomatic-patterns/spec.md (deferred work section)
- openspec/specs/inference-host-side-pull/spec.md (GPU tier formalization)
- openspec/litmus-bindings.yaml (new podman-enclave-network binding)
- plan/index.yaml (new step entry)
- plan.yaml (current_state update)

---

## Sign-Off

**Iteration**: 12 (after Wave 18 validation)
**Date**: 2026-05-15
**Status**: Ready for Wave A delegation

Next immediate action: Delegate Wave A to 3 Haiku agents in parallel; schedule Wave B start after Wave A completion.

