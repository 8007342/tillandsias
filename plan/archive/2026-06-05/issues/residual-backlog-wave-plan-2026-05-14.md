# Residual Backlog Wave Plan — 2026-05-14

**Iteration**: 5 (transition from cleanup-first to implementation-first)
**Task**: implementation-gaps/residual-backlog (order 8, second half)
**Author**: Claude Code (Opus 4.7)
**Branch**: linux-next
**Scope**: Synthesise the 4 Wave 10 gap audits + the Wave 11.1 triage matrix into a prioritised wave plan for Waves 12+

---

## Authoritative Inputs

This plan is a synthesis layer over:

- `plan/issues/gap-triage-matrix-2026-05-14.md` — 49-gap triage with severity, effort, priority, dependencies (Wave 11.1 output).
- `plan/issues/browser-gaps-2026-05-14.md` — 8 browser gaps.
- `plan/issues/tray-gaps-2026-05-14.md` — 7 tray gaps.
- `plan/issues/onboarding-gaps-2026-05-14.md` — 11 onboarding gaps.
- `plan/issues/observability-gaps-2026-05-14.md` — 23 observability gaps.
- `plan/index.yaml` — graph-plan selection / claim / checkpoint policy.

The triage matrix is the source of truth for per-gap priority. This document organises those priorities into Waves 12+ with parallelism, effort budgets, release-readiness gates, and risk callouts.

---

## Executive Summary

**Headline numbers** (from gap-triage-matrix):

| Priority | Count | Aggregate effort | Wave | Gate |
|----------|-------|------------------|------|------|
| **P0** | 1 (LIKELY ALREADY DONE) | ~1.5h | 12 (verify only) | Release blocker |
| **P1** | 6 | ~13h | 12–13 | Recommended for release |
| **P2** | 15 | ~16h | 14–15 | Polish; can defer past release |
| **P3** | 27 | ~20h | 16+ | Backlog |
| **Total** | **49** | **~50h** | | |

**Key transition**: Wave 11 (this synthesis) marks the formal end of cleanup-first mode. Waves 12+ are implementation-first: each wave closes specific gaps, adds a litmus binding, and ships a `@trace` annotation. No new specs unless required to bind a closure.

**P0 status check**: The matrix's single P0 (`OBS-Linux-Diagnostics-Stream`) appears to have already landed (commit `70cfc617 feat(runtime-diagnostics-stream): Implement Linux/macOS log streaming via podman logs -f`). Wave 12 should begin with a **verification pass** confirming the P0 is closed; if so, the wave proceeds directly to P1.

---

## Wave 12 (Iteration 6) — P0 Verification + P1 First Half

**Estimated duration**: 1 iteration (~1–2 agent-days)
**Goal**: confirm P0 closed; close 3 of 6 P1 gaps; ship-ready after wave.

### Wave 12 Step 1 — P0 verification

| Gap ID | Title | Action |
|--------|-------|--------|
| OBS-Linux-Diagnostics-Stream | Linux diagnostics stream | Verify commit `70cfc617` against `runtime-diagnostics-stream` spec; confirm `podman logs -f` reader works in a smoke test; add `@trace spec:runtime-diagnostics-stream` if missing; run `cargo test -p tillandsias-headless`. |

If P0 verification fails, the entire wave focuses on closing it before P1.

### Wave 12 Step 2 — P1 quick wins (3 gaps in parallel)

These three are the "highest severity-to-effort ratio" leaves from the matrix.

| Gap ID | Title | Severity | Effort | Suggested Agent | Owned Files |
|--------|-------|----------|--------|-----------------|-------------|
| **BR-003** | Squid `.localhost` cache_peer | HIGH | Small (~1h) | Haiku-A | `images/proxy/Containerfile`, `images/proxy/squid.conf` |
| **ON-011** | Forge welcome cheatsheet pointer | MEDIUM | Small (~30m) | Haiku-B | `images/default/forge-welcome.sh`, optionally locale bundle |
| **OBS-021** | Secret rotation event coverage | MEDIUM | Small (~1h) | Haiku-C | `crates/tillandsias-otp/src/lib.rs`, secret refresh paths |

**Wave 12 verification**: `./build.sh --ci-full` after the 3 Haiku PRs merge.

**Release readiness after Wave 12**: ship-eligible. BR-003 unblocks browser routing via proxy; ON-011 makes cold-start agent discoverability work; OBS-021 closes the secret-rotation audit-trail gap; trace coverage already enforced via existing TRACES.md regeneration.

---

## Wave 13 (Iteration 7) — P1 Second Half

**Estimated duration**: 1 iteration (~2–3 agent-days)
**Goal**: close the remaining 3 P1 gaps; production observability hardened.

### Wave 13 Gap List

| Gap ID | Title | Severity | Effort | Suggested Agent | Owned Files |
|--------|-------|----------|--------|-----------------|-------------|
| **OBS-004** | Trace coverage threshold CI gate | MEDIUM | Medium (~2h) | Haiku-A | `scripts/validate-traces.sh` (new), `build.sh`, `openspec/litmus-bindings.yaml` |
| **ON-004** | Cold-start skill discovery litmus | MEDIUM | Medium (~2h) | Haiku-B | `openspec/litmus-tests/litmus-onboarding-cold-start-shape.yaml` (new), `openspec/litmus-bindings.yaml` |
| **OBS-014 + OBS-015** | CPU + memory metric sampling | MEDIUM | Medium (~3h each, batched ~5h) | Opus | `crates/tillandsias-metrics/` (new crate), wiring in `tillandsias-headless`, dashboard hooks |

### Wave 13 Critical Path

`OBS-014/015` (CPU + memory metric sampling) creates the new `tillandsias-metrics` crate. This becomes a dependency for the remaining metric leaves in Wave 16 (`OBS-016`, `OBS-017`). Land the crate scaffold here.

### Wave 13 Parallel Plan

- Opus on the metrics crate (largest effort, owns own files).
- Haiku-A on trace gate (independent leaf, touches scripts + bindings).
- Haiku-B on cold-start litmus (independent leaf, touches openspec only).

No cross-dependencies; full parallel.

---

## Wave 14 (Iteration 8) — P2 First Tranche (Wave 4 routing prerequisites + reliability)

**Estimated duration**: 1 iteration (~3 agent-days)
**Goal**: close the routing-integration test cluster; harden cache.

### Wave 14 Gap List (6 gaps)

| Gap ID | Title | Source | Effort | Notes |
|--------|-------|--------|--------|-------|
| **BR-001** | Router sidecar E2E test | browser | Medium | Depends on BR-002 (run after) |
| **BR-002** | Caddy reload integration test | browser | Medium | Container test harness |
| **BR-007** | Chromium framework Nix build ARG | browser | Medium | Reproducibility fix |
| **BR-008** | Browser allowlist enforcement | browser | Medium | Depends on BR-003 (Wave 12); now unblocked |
| **TR-003** | Cache corruption recovery | tray | Medium | Reliability win |
| **OBS-001** | Log field name stability litmus | observability | Small | Schema regression gate |

### Wave 14 Critical Path

BR-001 depends on BR-002. Run BR-002 first; spawn BR-001 once it lands.

### Wave 14 Parallel Plan

Day 1 (4 parallel Haiku):
- Haiku-A: BR-002
- Haiku-B: BR-007
- Haiku-C: TR-003
- Haiku-D: OBS-001

Day 2:
- Haiku-E: BR-001 (after BR-002 lands)
- Haiku-F: BR-008 (after BR-003 confirmed in Wave 12)

---

## Wave 15 (Iteration 9) — P2 Second Tranche (Observability extensions + evidence)

**Estimated duration**: 1 iteration (~3 agent-days)
**Goal**: close the observability MVP gaps that aren't release-critical but matter for convergence claims.

### Wave 15 Gap List (5 gaps)

| Gap ID | Title | Source | Effort | Notes |
|--------|-------|--------|--------|-------|
| **OBS-003** | Log schema version field | observability | Small | Single field addition |
| **OBS-018** | Evidence bundle auto-generation in CI | observability | Medium | Backs convergence claims |
| **OBS-016** | Continuous disk IO metric sampling | observability | Medium | Extends metrics crate from Wave 13 |
| **OBS-017** | Cgroup PSI collection | observability | Medium | Extends metrics crate from Wave 13 |
| **TR-001** | Tray litmus timeout @ 120s docs | tray | Small | Cheatsheet write-up |

### Wave 15 Parallel Plan

- Haiku-A: OBS-003 + OBS-018 (related)
- Opus or Haiku-B: OBS-016 + OBS-017 (metrics crate extension)
- Haiku-C: TR-001 (cheatsheet)

---

## Wave 16 (Iteration 10) — P2 Third Tranche (Polish)

**Estimated duration**: 1 iteration (~2–3 agent-days)
**Goal**: close the remaining P2 polish gaps.

### Wave 16 Gap List (4 gaps)

| Gap ID | Title | Source | Effort |
|--------|-------|--------|--------|
| **TR-004** | Forge image staleness on manual edit | tray | Small |
| **TR-002** | Rapid project switch defensive test | tray | Small |
| **BR-004** | Browser window lifecycle telemetry | browser | Small |
| **BR-006** | Browser window timeout enforcement | browser | Medium |

---

## Waves 17+ (Future) — P3 Backlog

**Estimated duration**: indefinite; opportunistic
**Goal**: close P3 leaves as capacity allows.

### P3 Backlog (27 gaps, by cluster)

**i18n surface completion** (3 leaves): ON-001, ON-002, ON-003

**Onboarding edge cases** (4 leaves): ON-005, ON-006, ON-007, ON-008, ON-009, ON-010

**Browser optimisation** (1 leaf): BR-005 (CDP connection pooling)

**Tray performance** (3 leaves): TR-005, TR-006, TR-007

**Observability extensions** (10 leaves): OBS-002, OBS-005, OBS-006, OBS-007, OBS-008, OBS-009, OBS-010, OBS-011, OBS-012, OBS-013

**Evidence hardening** (2 leaves, post Wave 15): OBS-019, OBS-020

**Observability surface completion** (2 leaves): OBS-022, OBS-023

### P3 Wave Cadence

Pick 4–6 leaves per future wave; no fixed schedule. Most are Small effort, so a P3 wave fits in ~half a day.

---

## Cross-Platform Deferral (Out of Scope)

Per `plan/issues/deferral-windows-macos-2026-05-14.md`, all Windows/WSL/macOS work is deferred. The cross-platform leaves are NOT scheduled in any Wave 12+ slot. They will be reactivated as `cross-platform-phase-N` after Linux MVP ships.

---

## Risk Assessment

### If P0 is not actually closed (Wave 12 verification fails)

| Outcome | Mitigation |
|---------|------------|
| `runtime-diagnostics-stream` regressed or never landed cleanly | Wave 12 owns the full implementation (1.5h Opus task); P1 work slips one wave. Acceptable. |

### Shipping without P1 closure

| Gap | Risk | Mitigation |
|-----|------|------------|
| **BR-003** | Browser routing flow broken end-to-end via proxy | DO NOT ship without; user-visible blocker. |
| **ON-011** | Cold-start agents land confused | Cosmetic; would not block release in isolation but trivial to close. |
| **OBS-021** | Secret rotation has no audit trail | Security observability gap; support team will surface this. |
| **OBS-004** | Future spec regressions invisible | Process gap; could ship without if release frozen, not recommended. |
| **ON-004** | Cold-start story regressions invisible | Test gap; doesn't block but loses confidence. |
| **OBS-014/015** | No CPU/memory visibility in production | Predictive saturation impossible; manual `top` workaround viable for first weeks. |

**Conclusion**: BR-003 is the hard blocker among P1. Everything else is strongly recommended but not legally required.

### Deferring P2

If P2 slips past release:
- **User-visible**: minor — most P2 are extensions, not regressions.
- **Technical debt**: accumulates but manageable; no architectural drift.
- **Mitigation**: schedule P2 as periodic "polish waves".

### Deferring P3

P3 is explicitly future-scope. Deferral is the expected behaviour.

---

## Release Readiness Checklist

### Minimum Viable Release Scope (after Wave 12)

- [x] All 76 active specs implemented at ≥30% coverage
- [ ] P0: Linux diagnostics stream — VERIFIED closed (Wave 12 step 1)
- [ ] **BR-003**: Squid `.localhost` cache_peer (Wave 12)
- [ ] **ON-011**: Forge welcome cheatsheet pointer (Wave 12)
- [ ] **OBS-021**: Secret rotation event coverage (Wave 12)
- [x] All non-deferred specs trace-bound
- [x] Test suite green (`cargo test --workspace`)
- [x] Build pipeline green (`./build.sh --release`)

### Recommended Release Scope (after Wave 13)

Adds to minimum:
- [ ] **OBS-004**: Trace coverage CI gate (Wave 13)
- [ ] **ON-004**: Cold-start skill discovery litmus (Wave 13)
- [ ] **OBS-014/015**: CPU + memory metric sampling (Wave 13)

### Nice-to-Have Scope (after Waves 14–16)

- [ ] Wave 4 routing integration tests landed (BR-001, BR-002, BR-007, BR-008)
- [ ] Cache reliability hardening (TR-003)
- [ ] Observability MVP gaps closed (OBS-001, OBS-003, OBS-018, OBS-016, OBS-017)
- [ ] Tray polish (TR-001, TR-002, TR-004)
- [ ] Browser polish (BR-004, BR-006)

---

## Execution Plan

### Iteration 6 (Wave 12)

```
Day 1:
  - Primary coordinator runs P0 verification:
    - cargo test -p tillandsias-headless (diagnostics stream tests)
    - smoke test: launch a forge, --debug, verify per-container prefix output
  - If P0 verified, spawn 3 Haiku in parallel:
    - Haiku-A: BR-003 Squid
    - Haiku-B: ON-011 welcome pointer
    - Haiku-C: OBS-021 secret rotation events
  - Integrate, run ./build.sh --ci-full
Day 2 (if needed):
  - Tag release v0.1.<N>.<build>
  - Push origin/main with release tag
```

### Iteration 7 (Wave 13)

```
Day 1:
  - 2 Haiku + 1 Opus in parallel:
    - Haiku-A: OBS-004 trace gate
    - Haiku-B: ON-004 cold-start litmus
    - Opus: OBS-014/015 metrics crate scaffold
  - Coordinator integrates
Day 2:
  - --ci-full; tag release if releasing
```

### Iteration 8 (Wave 14)

```
Day 1: 4 Haiku parallel (BR-002, BR-007, TR-003, OBS-001)
Day 2: 2 Haiku (BR-001 after BR-002; BR-008 after BR-003 confirmed)
Day 3: --ci-full, integrate.
```

### Iteration 9 (Wave 15)

```
Day 1: 3 agents (Haiku/Opus mix) on observability + tray polish
Day 2: --ci, integrate.
```

### Iteration 10 (Wave 16)

```
Day 1: 4 Haiku parallel on tray/browser polish leaves
Day 2: --ci, integrate.
```

### Iteration 11+ (Waves 17+)

Opportunistic P3 cleanup; pick 4–6 leaves per wave.

---

## Handoff Notes for Wave 12 Coordinator

- **Current state**: Wave 10 audits complete, Wave 11.1 triage matrix complete, Wave 11.2 (this synthesis) complete. Implementation-first mode begins.
- **Branch**: `linux-next`
- **First action**: Wave 12 step 1 — verify P0 (`runtime-diagnostics-stream`) is actually closed; check commit `70cfc617`, run associated tests, confirm `@trace` annotation in code.
- **Second action**: If verified, spawn 3 Haiku agents on BR-003, ON-011, OBS-021 in parallel.
- **Verification**: each gap closure must add a litmus binding OR a trace annotation, NOT just a code change. Convergence requires evidence.
- **Risk**: Wave 12 is small and self-contained; no critical-path surprises expected.
- **Commit cadence**: per `plan/index.yaml` checkpoint policy, checkpoint after each gap closes (3 commits + integration commit minimum).

### Special Notes

- **OBS-014/015 (Wave 13)**: opening the new `tillandsias-metrics` crate is the only "large" effort in Wave 13. Opus should own it because crate scaffolding touches Cargo.toml workspace, dependency negotiation, and platform-specific cgroup reads (cgroup v1 vs v2 detection).
- **BR-008 dependency on BR-003**: BR-008 (browser allowlist enforcement after routing) cannot land until BR-003 (Squid `.localhost`) is shipping in the proxy image. Wave 14 schedules BR-008 only after Wave 12 confirms BR-003.
- **OBS-016/017 dependency on OBS-014/015**: the disk and PSI metric leaves extend the metrics crate that Wave 13 scaffolds. Do not start them in parallel with Wave 13.

---

## Files Reference

- `plan/issues/gap-triage-matrix-2026-05-14.md` — Authoritative gap triage (Wave 11.1).
- `plan/issues/browser-gaps-2026-05-14.md` — 8 browser gaps.
- `plan/issues/tray-gaps-2026-05-14.md` — 7 tray gaps.
- `plan/issues/onboarding-gaps-2026-05-14.md` — 11 onboarding gaps.
- `plan/issues/observability-gaps-2026-05-14.md` — 23 observability gaps.
- `plan/issues/deferral-windows-macos-2026-05-14.md` — Cross-platform deferral rationale.
- `plan/steps/08-implementation-gaps.md` — Step 8 finalisation (this wave plan's parent step).
- `plan/index.yaml` — Plan-graph state and selection policy.

---

## Sources of Truth

- `plan/issues/gap-triage-matrix-2026-05-14.md` — single source of truth for per-gap severity/effort/priority.
- `plan/issues/{browser,tray,onboarding,observability}-gaps-2026-05-14.md` — single source of truth for per-gap fix path / spec reference.
- `plan/index.yaml` — single source of truth for plan-graph status and claim rules.
- `methodology.yaml` and `methodology/cheatsheets.yaml` — convergence discipline.
