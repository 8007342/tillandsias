# Documentation Debt: Three Implementation Sessions

**Date**: 2026-05-16
**Status**: Tracked (Wave A ready for delegation)
**Priority**: P2 (post-release polish, non-blocking)

---

## Summary

Three recent implementation waves (17-24) closed critical functionality but left documentation gaps. This issue catalogs all gaps discovered during the audit and provides a prioritized breakdown for closure.

**Total Debt**:
- 3 missing event records
- 3 missing specs
- 1 missing litmus test
- 2 incomplete specs

**Estimated Closure Time**: 6-10 hours (4 waves, mixed parallel)

---

## Gap Triage Matrix

### Category 1: Missing Event Records (3 events)

Events are emitted at runtime but never formally registered in OpenSpec `methodology/events/`.

| Event | Module | Category | Emitted | Spec | Litmus | Notes |
|-------|--------|----------|---------|------|--------|-------|
| **EV-001** i18n-locale-load | forge/localization.sh | Onboarding | ✓ (14+ places) | ❌ | N/A | Occurs when locale files loaded on forge startup |
| **EV-002** model-pull-background-start | images/inference/ | Inference | ✓ (ollama startup) | ❌ | N/A | Triggers host-side lazy model pull |
| **EV-003** podman-enclave-network-created | tillandsias-podman | Orchestration | ✓ (client.rs) | ❌ | ❌ | Critical for observability; no litmus test coverage |

**Action**: Create event YAML in `methodology/events/` with schema conformance.

---

### Category 2: Missing Spec Definitions (3 specs)

Implemented capabilities with no formal OpenSpec specs. These enable post-release documentation + future maintenance.

| Spec | Module | Requirements | Sources | Litmus | Notes |
|------|--------|--------------|---------|--------|-------|
| **SP-001** forge-localization-pipeline | images/default/ | 8-10 (estimated) | cheatsheets/runtime/forge-localization.md | Pre-existing (Wave 17) | Maps locale selection → config file generation → shell sourcing |
| **SP-002** inference-lazy-model-pull | images/inference/ | 6-8 (estimated) | cheatsheets/runtime/inference.md, CLAUDE.md § Inference | Pre-existing (Wave 17) | GPU tier → model selection → background pull orchestration |
| **SP-003** podman-enclave-network-core | crates/tillandsias-podman/ | 5-7 (estimated) | podman-idiomatic-patterns, cheatsheets/utils/podman-networking.md | ❌ MISSING | Container network isolation, naming, event emission |

**Action**: Create specs in `openspec/specs/` with formal requirements + Sources of Truth.

---

### Category 3: Missing Litmus Test (1 test)

Specs with no executable validation binding.

| Spec | Requirement | Test Name | Coverage | Status |
|------|-------------|-----------|----------|--------|
| **LT-001** podman-enclave-network-core | "Container network isolation verified end-to-end" | litmus:podman-enclave-network-isolation | 0% → 50% target | ❌ MISSING |

**Action**: Write integration test in `openspec/litmus-tests/litmus-podman-enclave-network-*.yaml`.

**Test Scope**:
1. Create enclave network with correct naming
2. Launch 2 containers in enclave; verify can reach each other
3. Verify host cannot reach into enclave
4. Verify event `podman-enclave-network-created` emitted
5. Verify network deleted when last container exits

---

### Category 4: Incomplete Specs (2 specs)

Specs whose requirements diverged from implementation during development. Need updates to reflect implementation reality.

#### Spec UP-001: podman-idiomatic-patterns

**Current Status**: Spec 70% complete; implementation 100% complete

**Gaps**:
- GAP-1: `graphroot` configuration (storage graph location) — deferred to separate PR
- GAP-2: `secret-builder` (custom secret mounting) — deferred to separate PR

**Issue**: Spec documents these as open requirements, but implementation deferred them. Spec needs update to mark as deferred + link to plan/issues/podman-crate-audit.md.

**Action**: Update `## Deferred Refactors` section in spec; add migration notes for future work.

**Verification**: Run `./build.sh --ci --filter podman-idiomatic` (no test changes).

---

#### Spec UP-002: inference-host-side-pull

**Current Status**: Spec incomplete; implementation 100% complete

**Gaps**:
- GPU tier detection logic (T0-T5 mapping) lives in CLAUDE.md, not in spec
- Model selection logic undocumented (which models pull on which GPU tiers)
- Lazy-pull trigger conditions need formalization

**Issue**: Spec exists but is outdated. Implementation in images/inference/ and CLAUDE.md § Inference Container diverged.

**Action**: Formalize GPU tier detection + model selection in spec requirements; update CLAUDE.md Sources of Truth reference.

**Verification**: Run `./build.sh --test --filter inference` (no test changes; pre-existing tests still pass).

---

## Wave Execution Plan

See: `plan/steps/11a-doc-debt-payoff.md` for detailed wave breakdown.

### Wave A: Events + Specs (Small, 3h, Parallel)
- Agent A: EV-001 + SP-001
- Agent B: EV-002 + SP-002
- Agent C: EV-003 + SP-003

### Wave B: Litmus Test (Small, 2h, Serial)
- Agent D: LT-001 (depends on Wave A completion)

### Wave C: Spec Updates (Medium, 2h, Parallel)
- Agent E: UP-001 (podman-idiomatic-patterns)
- Agent F: UP-002 (inference-host-side-pull)

### Wave D: Integration (Medium, 2h, Serial)
- Agent Opus: Verification + merge

---

## Verification Checklist (Wave D)

- [ ] 3 events registered + schema-valid
- [ ] 3 new specs created + valid
- [ ] 2 specs updated + merged
- [ ] 1 litmus test passing (≥50% coverage)
- [ ] All specs have `## Sources of Truth` section
- [ ] All new code has `@trace` annotations
- [ ] `./build.sh --ci-full` passing (no regressions)
- [ ] Git history clean (1 merge commit)

---

## Files to Create/Update

**Wave A** (Events + Specs):
- `methodology/events/ev-001-i18n-locale-load.yaml`
- `methodology/events/ev-002-model-pull-background-start.yaml`
- `methodology/events/ev-003-podman-enclave-network-created.yaml`
- `openspec/specs/forge-localization-pipeline/spec.md`
- `openspec/specs/inference-lazy-model-pull/spec.md`
- `openspec/specs/podman-enclave-network-core/spec.md`

**Wave B** (Litmus):
- `openspec/litmus-tests/litmus-podman-enclave-network-isolation.yaml`
- `openspec/litmus-bindings.yaml` (add binding)

**Wave C** (Updates):
- `openspec/specs/podman-idiomatic-patterns/spec.md` (update)
- `openspec/specs/inference-host-side-pull/spec.md` (update)

**Wave D** (Integration):
- `plan/steps/11a-doc-debt-payoff.md` (update status: completed)
- Single merge commit

---

## Success Criteria

- [ ] All 3 events defined and registered
- [ ] All 3 new specs created with full requirements + Sources of Truth
- [ ] All 2 specs updated (deferred work documented)
- [ ] Litmus test passing (podman-enclave-network-isolation)
- [ ] `./build.sh --ci-full --test` passes with no regressions
- [ ] Git pushed to origin/linux-next
- [ ] Documentation debt marked complete

---

## Related Issues

- plan/issues/ghost-trace-sweep-backlog-2026-05-16.md (future work: 10 ghost traces)
- plan/issues/podman-crate-audit.md (deferred work: GAP-1, GAP-2)
- plan/steps/11a-doc-debt-payoff.md (execution plan)

---

## Next Steps

1. **Wave A delegation**: Haiku-A, B, C start events + specs in parallel
2. **Wave A completion**: Merge to linux-next
3. **Wave B start**: Wait for Wave A completion; Haiku-D starts litmus test
4. **Wave C start**: Parallel with Wave B; agents E+F start spec updates
5. **Wave D start**: After all waves complete; Opus runs verification + merge

**ETA**: 6-10 hours wall-clock (mixed parallel)

