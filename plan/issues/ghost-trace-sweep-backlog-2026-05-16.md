# Ghost Trace Sweep Backlog — 10 Traces with No Spec

**Date**: 2026-05-16
**Status**: Tracked (not in critical path, future wave work)
**Priority**: MEDIUM (technical debt, not blocking release)
**Suggested Wave**: ghost-trace-sweep-2026-Q3

---

## Summary

Audit of codebase identified 10 `@trace` annotations in `crates/tillandsias-headless/src/main.rs` that reference specs or capabilities that either do not exist or are incomplete.

These are "ghost traces" — code assertions with no formal spec backing.

**Impact**: Non-blocking for current release. Future maintenance risk if specs are never defined.

**Suggested Approach**: Batch as a separate wave (Q3 2026) with dedicated spec-authoring phase.

---

## Ghost Traces Inventory

All 10 traces located in: `crates/tillandsias-headless/src/main.rs`

| ID | Line | Trace Ref | Status | Spec Exists? | Type | Notes |
|----|----- |-----------|--------|--------------|------|-------|
| **GT-001** | ~187 | `@trace spec:podman-force-cleanup` | Active | ❌ | Behavior | Container cleanup on SIGTERM; no spec |
| **GT-002** | ~203 | `@trace spec:tray-signal-propagation` | Active | ❌ | Behavior | Forward SIGTERM to headless child; no spec |
| **GT-003** | ~215 | `@trace spec:tray-subprocess-teardown` | Active | ❌ | Behavior | Graceful shutdown waiting for child; no spec |
| **GT-004** | ~267 | `@trace spec:headless-json-events` | Active | ❌ | Behavior | Emit JSON events on stdout; partially spec'd (runtime-logging) |
| **GT-005** | ~283 | `@trace spec:headless-event-order-guarantee` | Active | ❌ | Behavior | Event delivery ordering semantics; no spec |
| **GT-006** | ~301 | `@trace spec:tray-singleton-detection-network` | Active | ⚠️ Partial | Behavior | Network-based singleton check; incomplete in singleton-guard |
| **GT-007** | ~318 | `@trace spec:headless-graceful-shutdown-timeout` | Active | ❌ | Behavior | 30s default shutdown timeout; undocumented |
| **GT-008** | ~334 | `@trace spec:podman-events-fallback` | Active | ❌ | Behavior | Polling fallback when `podman events` fails; no spec |
| **GT-009** | ~387 | `@trace spec:headless-config-reload` | Active | ❌ | Behavior | Config file change detection & reload; no spec |
| **GT-010** | ~401 | `@trace spec:headless-observability-hooks` | Active | ❌ | Behavior | Log emission coordination; incomplete |

---

## Analysis by Spec Existence

### Category A: No Spec (7 traces)

These require brand new specs to be authored:

| Trace | Spec Name (Proposed) | Effort | Cluster |
|-------|----------------------|--------|---------|
| GT-001 | podman-force-cleanup | Medium | Orchestration |
| GT-002 | tray-signal-propagation | Small | Tray Lifecycle |
| GT-003 | tray-subprocess-teardown | Medium | Tray Lifecycle |
| GT-005 | headless-event-order-guarantee | Medium | Observability |
| GT-007 | headless-graceful-shutdown-timeout | Small | Tray Lifecycle |
| GT-008 | podman-events-fallback | Medium | Orchestration |
| GT-009 | headless-config-reload | Medium | Runtime |

**Total Effort**: ~1 week (spec authoring + litmus tests)

---

### Category B: Partial Spec (2 traces)

These require existing specs to be augmented:

| Trace | Existing Spec | Gap | Effort |
|-------|---------------|-----|--------|
| GT-004 | runtime-logging | JSON event structure + ordering undocumented | Small |
| GT-010 | runtime-diagnostics (partial) | Logging coordination + hook timing not formalized | Medium |

**Total Effort**: ~2 days (spec enhancement)

---

### Category C: Incomplete Spec (1 trace)

Spec exists but is incomplete:

| Trace | Existing Spec | Gap | Effort |
|-------|---------------|-----|--------|
| GT-006 | singleton-guard | Network-based detection method undocumented; only ipc-socket covered | Medium |

**Total Effort**: ~3 days (spec expansion + litmus test)

---

## Proposed Wave Structure

### Wave Ghost-A: Category A Specs (Foundational)

**Effort**: ~3 days
**Scope**: 7 new specs + litmus tests

| Agent | Spec | Litmus Test |
|-------|------|-------------|
| Agent-1 | podman-force-cleanup | litmus:podman-force-cleanup-sigterm |
| Agent-2 | tray-signal-propagation + tray-subprocess-teardown | litmus:tray-signal-propagation |
| Agent-3 | headless-event-order-guarantee + headless-graceful-shutdown-timeout | litmus:headless-shutdown-semantics |
| Agent-4 | podman-events-fallback + headless-config-reload | litmus:podman-events-fallback-polling |

**Success Criteria**:
- 7 specs created with ≥6 requirements each
- 4 litmus tests passing (≥30% coverage each)
- All code has @trace annotations updated
- `./build.sh --test` passing

---

### Wave Ghost-B: Category B & C Specs (Enhancement)

**Effort**: ~2 days (depends on Ghost-A completion for reference links)
**Scope**: 2 enhanced + 1 expanded spec

| Agent | Task |
|-------|------|
| Agent-5 | Enhance runtime-logging spec: JSON event structure + ordering |
| Agent-6 | Enhance runtime-diagnostics spec: logging hook coordination |
| Agent-7 | Expand singleton-guard spec: network-based detection method |

**Success Criteria**:
- 3 specs updated (spec diffs show clear additions)
- New litmus tests for singleton-guard networking
- All references to Ghost-A specs valid
- `./build.sh --test` passing

---

## Timeline

**Phase 1**: Documentation debt payoff (immediate, May 2026)
- plan/steps/11a-doc-debt-payoff (Waves A-D)
- Closes 3 events + 3 specs + 1 litmus + 2 spec updates

**Phase 2**: Ghost trace sweep (Q3 2026, ~3 months later)
- Ghost-A wave (7 specs + litmus tests)
- Ghost-B wave (3 spec enhancements)

**Rationale**: Ghost traces are tech debt, not blocking release. Defer to post-release phase to avoid scope creep. Addresses long-term maintainability but not critical functionality.

---

## Integration Plan (After Ghost Waves)

When Ghost-A and Ghost-B complete:

1. **Spec Completeness Audit**: Run `openspec validate --strict` on all 10 new/enhanced specs
2. **Litmus Coverage**: All 10 traces should have binding in `openspec/litmus-bindings.yaml`
3. **Trace Index Update**: TRACES.md should have entries for all 10 references
4. **Archive PR**: Single PR with all ghost specs + litmus tests + trace updates

---

## Files to Create/Update (Ghost-A Wave)

**New Specs**:
- `openspec/specs/podman-force-cleanup/spec.md`
- `openspec/specs/tray-signal-propagation/spec.md`
- `openspec/specs/tray-subprocess-teardown/spec.md`
- `openspec/specs/headless-event-order-guarantee/spec.md`
- `openspec/specs/headless-graceful-shutdown-timeout/spec.md`
- `openspec/specs/podman-events-fallback/spec.md`
- `openspec/specs/headless-config-reload/spec.md`

**Litmus Tests**:
- `openspec/litmus-tests/litmus-podman-force-cleanup-sigterm.yaml`
- `openspec/litmus-tests/litmus-tray-signal-propagation.yaml`
- `openspec/litmus-tests/litmus-headless-shutdown-semantics.yaml`
- `openspec/litmus-tests/litmus-podman-events-fallback-polling.yaml`

**Updated**:
- `openspec/litmus-bindings.yaml` (4 new bindings)
- `crates/tillandsias-headless/src/main.rs` (annotations already present)

---

## Files to Create/Update (Ghost-B Wave)

**Enhanced Specs**:
- `openspec/specs/runtime-logging/spec.md` (update)
- `openspec/specs/runtime-diagnostics/spec.md` (update)
- `openspec/specs/singleton-guard/spec.md` (update)

**New Litmus Tests**:
- `openspec/litmus-tests/litmus-singleton-guard-network-detection.yaml`

**Updated**:
- `openspec/litmus-bindings.yaml` (3 additional bindings)

---

## Success Criteria (Full Sweep)

- [ ] 10 traces → 10 specs (7 new + 3 enhanced)
- [ ] 8 litmus tests created and passing
- [ ] All specs have `## Sources of Truth` section
- [ ] All new code has `@trace` annotations
- [ ] `./build.sh --ci-full --test` passing
- [ ] TRACES.md updated with all 10 references
- [ ] Single archive PR merged to main

---

## Related Issues

- plan/steps/11a-doc-debt-payoff.md (immediate doc debt, Waves A-D)
- crates/tillandsias-headless/src/main.rs (source of ghost traces)
- TRACES.md (trace index — needs update after ghost waves complete)

---

## Handoff Notes for Q3 Wave Lead

1. **Ghost traces are real code paths** — they execute at runtime; specs are just missing
2. **Ghost-A is critical path** — 7 specs unlock litmus test coverage
3. **Ghost-B can run in parallel** with Ghost-A Wave 2-3 (after Ghost-A Wave 1 completes)
4. **Integration is straightforward** — all specs are independent (no circular deps)
5. **No code changes needed** — only spec + litmus work; `@trace` annotations already present
6. **Estimated 2-week calendar time** (3-4 days spec work + 2-3 days litmus work + 1 day integration)

