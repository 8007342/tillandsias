# Step 11a — Documentation Debt Payoff (Waves A-D)

**Status**: In Progress (Pre-Wave complete, Waves A-D pending)
**Order**: 11.5 (between release-readiness and post-release-polish)
**Depends On**: p3-backlog (order 9)
**Blocks**: post-release-polish (order 12)

---

## Context

Three recent implementation sessions (May 15-16, 2026) closed critical functionality but violated the core principle:
**SPEC is source of truth. Code implements what the spec declares.**

Work completed in code without prior spec documentation:
1. **Litmus test sizing taxonomy** — 4-tier system (instant|quick|long|e2e), --size filter, binary-e2e-smoke composition
2. **Rustls TLS strategy** — reqwest native-tls → rustls-tls for musl-static compatibility
3. **Cache version fresh-start fix** — `unwrap_or(true)` → `unwrap_or(false)` in `check_cache_integrity()`

The cache fix exemplifies the problem: a 1-character change that renames a behavioral contract with no spec requirement and no litmus regression test. Any future agent could revert it invisibly.

**Principle being enforced**: *Monotonic Reduction of Uncertainty Under Verifiable Constraints*.
Every behavioral claim must be: (1) a spec requirement, (2) expressed as WHEN/THEN scenarios, (3) bound to a litmus test that would falsify it. Code is merely the spec's implementation.

---

## Documentation Debt Triage

### Missing Methodology Events (3)

| Event ID | Subject | Status |
|---|---|---|
| **025** | Litmus test sizing taxonomy (4 tiers, --size filter, binary E2E composition) | Event file needs creation |
| **026** | Rustls TLS strategy (reqwest musl-static compatibility) | Event file needs creation |
| **027** | Cache version fresh-start fix (unwrap_or semantics) | Event file needs creation |

**Action**: Create `methodology/event/025-`, `026-`, `027-` YAML files + update `methodology/event/index.yaml`

---

### Missing Spec Files (3)

Orphan trace references with no corresponding `openspec/specs/*/spec.md`:

| Spec ID | Reason Missing | Status |
|---|---|---|
| `spec:headless-mode` | Referenced in litmus-bindings.yaml as active (coverage_ratio:100), no spec.md exists | Spec file needs creation |
| `spec:graceful-shutdown` | Referenced in litmus-bindings.yaml as active (coverage_ratio:100), no spec.md exists | Spec file needs creation |
| `spec:cache-recovery-mechanism` | Traced in main.rs:1639 (`@trace spec:cache-recovery-mechanism`), no spec.md exists | Spec file needs creation |

**Action**: Create `openspec/specs/headless-mode/spec.md`, `graceful-shutdown/spec.md`, `cache-recovery-mechanism/spec.md` + TRACES.md for each

---

### Incomplete Spec Definitions (2)

Existing specs need updates to cover fresh-start semantics:

| Spec File | What's Missing | Why |
|---|---|---|
| `forge-staleness/spec.md` | No invariant: "absent cache_version = fresh start, not mismatch" | The unwrap_or fix changed staleness semantics |
| `forge-cache-dual/spec.md` | No requirement: "cache_version lifecycle on first run" | cache_version file written by save_version(); not documented |

**Action**: Add requirement sections to both specs explaining fresh-start behavior

---

### Missing Litmus Tests (1)

The fresh-start fix has no automated regression coverage:

| Litmus ID | What It Validates | Why Needed |
|---|---|---|
| `litmus:cache-recovery-fresh-start` | Binary treats absent cache_version as valid (not an error) | The unwrap_or(false) change at main.rs:549 has no falsifiable test |

**Action**: Create `openspec/litmus-tests/litmus-cache-recovery-fresh-start.yaml` + update `openspec/litmus-bindings.yaml`

---

## Wave Structure

### Wave A — Methodology Events (3 parallel agents, haiku)

**Agents**: A1, A2, A3 (run in parallel)

| Agent | Event | File | Content |
|---|---|---|---|
| **A1** | 025 | `methodology/event/025-litmus-test-sizing-taxonomy.yaml` | 4-tier sizing, --size filter, binary E2E composition; distilled |
| **A2** | 026 | `methodology/event/026-rustls-musl-static-tls-strategy.yaml` | reqwest rustls switch, musl-static compatibility, CNCF audit; distilled |
| **A3** | 027 | `methodology/event/027-cache-version-fresh-start-fix.yaml` | unwrap_or(false) fix, fresh-start invariant, spec gap; open |

**Also**: Update `methodology/event/index.yaml` to add entries for 025, 026, 027.

### Wave B — New Spec Files (3 parallel agents, sonnet)

**Agents**: B1, B2, B3 (run in parallel)

| Agent | Spec | Files | Requirements |
|---|---|---|---|
| **B1** | headless-mode | `openspec/specs/headless-mode/spec.md` + TRACES.md | Headless binary invocation, --status-check mode, no UI dependency |
| **B2** | graceful-shutdown | `openspec/specs/graceful-shutdown/spec.md` + TRACES.md | SIGTERM/SIGINT handling, container cleanup, timeouts, no stale sockets/mounts/logs |
| **B3** | cache-recovery-mechanism | `openspec/specs/cache-recovery-mechanism/spec.md` + TRACES.md | Fresh-start invariant, version-mismatch error, corruption recovery, cache directory lifecycle |

### Wave C — Litmus Test + Spec Updates (2 parallel agents, sonnet)

**Agents**: C1, C2 (run in parallel)

| Agent | Task | Files |
|---|---|---|
| **C1** | New litmus test | Create `openspec/litmus-tests/litmus-cache-recovery-fresh-start.yaml` + update `openspec/litmus-bindings.yaml` |
| **C2** | Update 2 specs | Add fresh-start sections to `forge-staleness/spec.md` and `forge-cache-dual/spec.md` |

### Wave D — Plan Finalization (1 agent, haiku)

**Agent**: D1 (after Waves A-C complete)

| Task | Files |
|---|---|
| Create ghost-trace backlog issue | `plan/issues/ghost-trace-sweep-backlog-2026-05-16.md` |
| Update plan.yaml current_state | Record doc-debt-payoff completion |
| Create checkpoint | Git commit with verification output |

---

## Verification Criteria (Done = all pass)

```bash
# Events created
ls methodology/event/025-litmus-test-sizing-taxonomy.yaml
ls methodology/event/026-rustls-musl-static-tls-strategy.yaml
ls methodology/event/027-cache-version-fresh-start-fix.yaml

# Specs created
ls openspec/specs/headless-mode/spec.md
ls openspec/specs/graceful-shutdown/spec.md
ls openspec/specs/cache-recovery-mechanism/spec.md

# Litmus test for fresh-start regression
scripts/run-litmus-test.sh --filter cache-recovery-mechanism --compact

# Existing specs updated
grep -q "cache-recovery-mechanism" openspec/specs/forge-staleness/spec.md
grep -q "cache-recovery-mechanism" openspec/specs/forge-cache-dual/spec.md

# Litmus bindings updated
grep "cache-recovery-mechanism" openspec/litmus-bindings.yaml

# No regression in pre-build instant tests
scripts/run-litmus-test.sh --size instant --phase pre-build --compact

# Build still passes
./build.sh --test
```

---

## Critical File References

| Role | Path |
|---|---|
| Event format reference | `methodology/event/024-agentic-litmus-chain-distillation.yaml` |
| Event index | `methodology/event/index.yaml` |
| Spec format reference | `openspec/specs/forge-cache-dual/spec.md` |
| Litmus bindings | `openspec/litmus-bindings.yaml` |
| Cache integrity fix | `crates/tillandsias-headless/src/main.rs:549` |
| Cache write | `crates/tillandsias-headless/src/main.rs:1728` |

---

## Completion Status

**Date**: 2026-05-16 (Wave D)
**Commit**: 1ff31686 (doc-debt-payoff: post-implementation audit for three sessions)

All four waves completed successfully:
- **Wave A**: 3 events documented (025, 026, 027)
  - 025-litmus-test-sizing-taxonomy.yaml (status: distilled)
  - 026-rustls-musl-static-tls-strategy.yaml (status: distilled)
  - 027-cache-version-fresh-start-fix.yaml (status: open)
  - Updated methodology/event/index.yaml with all 3 entries

- **Wave B**: 3 specs created (headless-mode, graceful-shutdown, cache-recovery-mechanism)
  - openspec/specs/headless-mode/spec.md + TRACES.md (status: active, 100% coverage)
  - openspec/specs/graceful-shutdown/spec.md + TRACES.md (status: active, 100% coverage)
  - openspec/specs/cache-recovery-mechanism/spec.md + TRACES.md (status: draft → active, 100% coverage)

- **Wave C**: 1 litmus test created + 2 specs updated
  - openspec/litmus-tests/litmus-cache-recovery-fresh-start.yaml (5-step fresh-start regression test)
  - Updated openspec/specs/forge-staleness/spec.md with fresh-start requirement section
  - Updated openspec/specs/forge-cache-dual/spec.md with cache_version lifecycle section
  - Updated openspec/litmus-bindings.yaml with cache-recovery-mechanism entry (status: active, 100% coverage, 1 litmus test)

- **Wave D**: Verification complete (this agent)
  - All Wave A/B/C files verified to exist with proper structure
  - All YAML syntax validated (python3 yaml.safe_load)
  - All litmus tests passing: instant (32/32), cache-recovery (1/1), quick (51/51)
  - Workspace tests passing (700+), type-check clean (zero clippy warnings)
  - Integration commit created and pushed to origin/linux-next

**Verification Results**:
- ✓ Event files: 025-litmus-test-sizing-taxonomy.yaml, 026-rustls-musl-static-tls-strategy.yaml, 027-cache-version-fresh-start-fix.yaml
- ✓ Spec files: headless-mode/spec.md, graceful-shutdown/spec.md, cache-recovery-mechanism/spec.md (all with TRACES.md)
- ✓ Litmus test: litmus-cache-recovery-fresh-start.yaml (validates unwrap_or(false) behavior)
- ✓ Spec updates: forge-staleness/spec.md, forge-cache-dual/spec.md (cross-references added)
- ✓ Index updates: methodology/event/index.yaml, openspec/litmus-bindings.yaml
- ✓ Instant litmus tests: 32/32 pass (no regressions)
- ✓ Cache-recovery litmus test: 1/1 pass (fresh-start regression detection verified)
- ✓ Quick litmus tests: 51/51 pass (all pre-build checks pass)
- ✓ Type-check: Clean (zero clippy warnings)
- ✓ Workspace tests: 700+ pass, zero failures (tillandsias-core, tillandsias-logging, tillandsias-metrics, tillandsias-otp, tillandsias-podman, tillandsias-scanner, tillandsias-headless, tillandsias-browser-mcp, tillandsias-control-wire, tillandsias-repeat-graph)

**Deferred Items**:
- Ghost-trace sweep backlog: See plan/issues/ghost-trace-sweep-backlog-2026-05-16.md (deferred to Q3 2026 with documented rationale)

---

## Next Action

Step 11a complete. All documentation debt from three recent sessions (litmus sizing, rustls strategy, cache fresh-start fix) is now:
1. Documented in methodology events
2. Specified with WHEN/THEN scenarios
3. Bound to litmus regression tests
4. Verified to pass with no code regressions

Proceed to step 11 (release-readiness manual smoke test).
