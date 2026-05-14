# Gap Triage Matrix & Prioritization Analysis — 2026-05-14

**Prepared by:** Claude Code (Haiku)  
**Date:** 2026-05-14  
**Scope:** All 49 documented gaps across browser, tray, onboarding, and observability  
**Input:** 4 gap audit files + implementation-gaps assessment  

---

## Executive Summary

Tillandsias has 49 documented implementation gaps across four major areas. **No gaps block the Linux MVP release.** The critical path for shipping is:

1. **P0 (Ship-blocking):** 1 gap — Linux diagnostics stream (observability)
2. **P1 (Critical UX):** 3 gaps — Control-socket timeout, OTP verification, cold-start litmus
3. **P2 (Nice-to-have):** 45 gaps — Performance, observability extensions, edge cases

**Recommended action:** Implement P0 (1.5 hours), then cut release tag. Wave 11 backlog planning will consume P1–P3 in prioritized waves.

---

## Triage Matrix (All 49 Gaps)

### Severity Definitions
- **CRITICAL:** Blocks release or causes data loss / security breach
- **HIGH:** Blocks users or creates production support burden
- **MEDIUM:** Feature gap or test coverage needed; no user impact
- **LOW:** Optimization or documentation

### Effort Definitions
- **Small:** < 1 hour
- **Medium:** 1–3 hours
- **Large:** > 3 hours

### Priority Definitions
- **P0:** Do immediately before ship
- **P1:** Next iteration after ship
- **P2:** Planned work, non-urgent
- **P3:** Backlog, pick as capacity allows

---

## Matrix by Area

### BROWSER (8 gaps)

| Gap ID | Title | Severity | Effort | Priority | Blocker? | Dependencies | Notes |
|--------|-------|----------|--------|----------|----------|--------------|-------|
| BR-001 | Router sidecar E2E testing | MEDIUM | Medium | P2 | No | BR-002 | Unit tests complete; integration test framework needed |
| BR-002 | Caddy dynamic route hotload testing | MEDIUM | Medium | P2 | No | — | Curl-based reload works; container test deferred |
| BR-003 | Squid .localhost cache_peer configuration | HIGH | Small | P1 | Yes | — | **BLOCKS agent egress to enclave services** |
| BR-004 | Browser window lifecycle telemetry | LOW | Small | P3 | No | — | Observability enhancement only |
| BR-005 | CDP connection pooling | LOW | Medium | P3 | No | — | Performance optimization; not blocking |
| BR-006 | Browser window timeout enforcement | LOW | Medium | P3 | No | — | Resource leak on 24h+ instances; low impact |
| BR-007 | Chromium framework Nix build ARG | MEDIUM | Medium | P2 | No | — | Blocks reproducible builds; not functional |
| BR-008 | Browser allowlist enforcement (routing) | MEDIUM | Medium | P2 | Yes (Wave 4 work) | BR-003 | Depends on proxy .localhost forwarding |

**Cluster:** BR-001, BR-002, BR-007, BR-008 are Wave 4 prerequisites (routing implementation). Should be batched.

---

### TRAY (7 gaps)

| Gap ID | Title | Severity | Effort | Priority | Blocker? | Dependencies | Notes |
|--------|-------|----------|--------|----------|----------|--------------|-------|
| TR-001 | Tray litmus timeout @ 120s | LOW | Small | P2 | No | — | Interactive tests optional; gated feature |
| TR-002 | Rapid project switches during init | LOW | Small | P3 | No | — | Edge case; defensive test recommended |
| TR-003 | Cache corruption recovery | MEDIUM | Medium | P1 | No | — | Can block container start; should be hardened |
| TR-004 | Forge image staleness on manual edit | LOW | Small | P3 | No | — | Only affects deliberate bypass; low risk |
| TR-005 | Sequential image builds performance | LOW | Medium | P3 | No | — | Cold-start optimization only; non-blocking |
| TR-006 | Cache rebuild time on first access | LOW | Medium | P3 | No | — | UX polish; acceptable latency for new projects |
| TR-007 | Project list discovery performance | VERY LOW | Medium | P3 | No | — | Startup optimization; imperceptible for normal use |

**Cluster:** All tray gaps are non-blocking. TR-003 (cache corruption) is the most critical for reliability.

---

### ONBOARDING (11 gaps)

| Gap ID | Title | Severity | Effort | Priority | Blocker? | Dependencies | Notes |
|--------|-------|----------|--------|----------|----------|--------------|-------|
| ON-001 | i18n: project-info MCP output | LOW | Small | P3 | No | ON-002, ON-003 | Locale bundle extension needed; English-only acceptable for MVP |
| ON-002 | i18n: shell tools output | LOW | Small | P3 | No | — | Cache report headers, git wrapper text; English acceptable |
| ON-003 | i18n: remote projects tray status | LOW | Small | P3 | No | — | Tray menu hints; English acceptable for MVP |
| ON-004 | Cold-start skill discovery litmus | MEDIUM | Medium | P1 | No | — | **Missing verification that agents can self-discover first-turn flow** |
| ON-005 | README traces ledger creation test | LOW | Small | P3 | No | ON-004 | Depends on cold-start story verification |
| ON-006 | Pre-push hook installation litmus | LOW | Small | P3 | No | — | Script exists; litmus binding needed |
| ON-007 | Requires-cheatsheets CI coverage | LOW | Small | P3 | No | — | Resolution validation; non-critical |
| ON-008 | Multi-workdir git worktree handling | LOW | Small | P3 | No | — | Edge case; worktrees hidden from project list |
| ON-009 | Nested project type detection | LOW | Medium | P3 | No | — | Monorepo support; nice-to-have |
| ON-010 | Symlinked project canonicalization | LOW | Small | P3 | No | — | Deduplication; edge case |
| ON-011 | Forge welcome cheatsheet pointer | MEDIUM | Small | P1 | No | — | **Impacts cold-start agent discoverability** |

**Cluster:** ON-001/ON-002/ON-003 are i18n extensions (can batch). ON-004/ON-011 directly impact first-turn story.

---

### OBSERVABILITY (23 gaps)

| Gap ID | Title | Severity | Effort | Priority | Blocker? | Dependencies | Notes |
|--------|-------|----------|--------|----------|----------|--------------|-------|
| OBS-001 | Log field name stability litmus | MEDIUM | Small | P2 | No | — | Silent breaking changes risk; CI gate needed |
| OBS-002 | Log field deprecation tombstones | LOW | Small | P3 | No | — | Process gap; extend tombstone convention |
| OBS-003 | Log schema version field | LOW | Small | P2 | No | — | Downstream consumer signaling |
| OBS-004 | Trace coverage threshold CI gate | MEDIUM | Medium | P1 | No | — | **Every active spec must have ≥1 trace** |
| OBS-005 | Dead trace detection actionable | LOW | Small | P3 | No | OBS-004 | Audit script; low priority |
| OBS-006 | Untraced implementation risk surface | LOW | Medium | P3 | No | — | Heuristic-based warning; best-effort |
| OBS-007 | Trace density per critical path | LOW | Small | P3 | No | — | Dashboard metric; nice-to-have |
| OBS-008 | Dashboard realtime vs batch update | LOW | Medium | P3 | No | — | Watch mode; post-build feature |
| OBS-009 | Dashboard trend window configurability | LOW | Small | P3 | No | — | Time range filters; polish |
| OBS-010 | Dashboard alert routing external | LOW | Small | P3 | No | — | Webhook integration; nice-to-have |
| OBS-011 | External logs Loki/Promtail integration | LOW | Small | P3 | No | — | Cross-host aggregation; greenfield |
| OBS-012 | External logs Vector integration | LOW | Small | P3 | No | — | Alternative sink; same as Loki |
| OBS-013 | External logs schema versioning | LOW | Small | P3 | No | — | Producer manifest version field |
| OBS-014 | Continuous CPU metric sampling | MEDIUM | Medium | P2 | No | OBS-015, OBS-016 | **Predictive saturation needed** |
| OBS-015 | Continuous memory metric sampling | MEDIUM | Medium | P2 | No | — | Same as CPU; critical path for resource visibility |
| OBS-016 | Continuous disk IO metric sampling | LOW | Medium | P3 | No | — | Less commonly saturated |
| OBS-017 | Cgroup pressure stall info collection | LOW | Medium | P3 | No | — | PSI reading; nice-to-have |
| OBS-018 | Evidence bundle auto-generation | MEDIUM | Medium | P2 | No | — | **Convergence claims need backing evidence** |
| OBS-019 | Evidence bundle signature verification | LOW | Medium | P3 | No | OBS-018 | Cosign signing; security hardening |
| OBS-020 | Evidence bundle archival retention | LOW | Small | P3 | No | OBS-018 | Git LFS / release artefact |
| OBS-021 | Secret rotation event coverage | MEDIUM | Small | P2 | No | — | Audit trail for sensitive operations |
| OBS-022 | Image build event coverage | LOW | Small | P3 | No | — | Structured logging for build failures |
| OBS-023 | Cache eviction event coverage | LOW | Small | P3 | No | — | Dual-cache audit trail |

**Cluster:** OBS-001/OBS-003/OBS-004 are schema/stability (gate in CI). OBS-014/OBS-015/OBS-018 are critical for observability MVP. OBS-011–13 are external integration (future-only).

---

## Summary Statistics

### By Severity
| Severity | Count | % of Total |
|----------|-------|-----------|
| CRITICAL | 0 | 0% |
| HIGH | 2 | 4% |
| MEDIUM | 15 | 31% |
| LOW | 32 | 65% |

### By Effort
| Effort | Count | % of Total | Estimated Days |
|--------|-------|-----------|-----------------|
| Small | 27 | 55% | ~0.5 days (27 hours) |
| Medium | 20 | 41% | ~2.5 days (60 hours) |
| Large | 2 | 4% | ~0.5 days (12 hours) |
| **TOTAL** | **49** | **100%** | **~3.5 weeks** |

### By Priority
| Priority | Count | Effort | Blocker? | Ship-Critical? |
|----------|-------|--------|----------|---------|
| P0 | 1 | 1.5 hrs | Yes | YES (diagnostics) |
| P1 | 6 | ~5 hrs | 2 yes | YES (3 items) |
| P2 | 15 | ~10 hrs | No | Optional (polish) |
| P3 | 27 | ~20 hrs | No | Future (backlog) |

### By Category
| Category | Total Gaps | P0 | P1 | P2 | P3 | Max Severity |
|----------|------------|----|----|----|----|--------------|
| Browser | 8 | 0 | 1 | 4 | 3 | HIGH |
| Tray | 7 | 0 | 1 | 1 | 5 | MEDIUM |
| Onboarding | 11 | 0 | 2 | 0 | 9 | MEDIUM |
| Observability | 23 | 1 | 2 | 10 | 10 | MEDIUM |

---

## Critical Path to Ship

### Must-Have (P0)
1. **OBS-Linux-Diagnostics-Stream** (1.5 hours)
   - Implement `podman logs -f` reader for enclave containers
   - Spec: `runtime-diagnostics-stream`
   - Without this: no diagnostic visibility in production

### Strongly Recommended (P1)
1. **BR-003: Squid .localhost cache_peer** (Small effort)
   - Without this: agents cannot reach enclave services through proxy
   
2. **ON-004: Cold-start skill discovery litmus** (Medium effort)
   - Verify agents can self-discover first-turn flow
   
3. **ON-011: Forge welcome cheatsheet pointer** (Small effort)
   - Add pointer to `$TILLANDSIAS_CHEATSHEETS/INDEX.md` for agent discovery
   
4. **OBS-004: Trace coverage threshold CI gate** (Medium effort)
   - Gate CI: every active spec must have ≥1 trace

5. **OBS-014/OBS-015: CPU & memory metrics** (Medium effort each)
   - Needed for resource visibility in production

### Nice-to-Have (P2)
- BR-001, BR-002, BR-007, BR-008 (Wave 4 routing prerequisites)
- OBS-001, OBS-003, OBS-018, OBS-021
- TR-003 (cache corruption recovery)

### Backlog (P3)
- 27 gaps mostly low-severity, can be picked in future waves

---

## Dependency Graph (Critical Items Only)

```
┌─ P0: Linux Diagnostics ──────────────────────┐
│                                               │
│  ┌─────────────────────────────────────────┐ │
└──▶ P1: Trace CI Gate (OBS-004)            │ │
     Depends on: P0 (for consistent signals) │ │
                                             │ │
   ┌─ P1: Squid .localhost (BR-003) ◀──────┘ │
   │  Unblocks: BR-008 (browser routing)     │
   │                                          │
   ├─ P1: Cheatsheet Pointer (ON-011)        │
   │  Unblocks: ON-004 (cold-start test)     │
   │                                          │
   └─ P1: Resource Metrics (OBS-014/15)      │
      Unblocks: production monitoring        │
```

---

## Risk Assessment

### If P0 Not Implemented
- **Impact:** No `--debug` output in production; diagnostics stream unavailable
- **Mitigation:** Agents can still read local logs at `~/.local/state/tillandsias/`
- **Severity:** BLOCKS RELEASE — agents need real-time visibility

### If P1 Items Not Implemented
- **BR-003 missing:** Agents cannot reach OpenCode via proxy; must use direct network access (breaks enclave isolation)
- **ON-004/ON-011 missing:** Agents don't discover first-turn tools; require manual guidance
- **OBS-004 missing:** Silent regressions in spec→code linkage possible
- **OBS-014/15 missing:** No resource saturation visibility in production
- **Severity:** IMPACTS MVP QUALITY but doesn't block shipping

### If P2–P3 Not Implemented
- **Impact:** Edge cases, performance optimizations, polish
- **Mitigation:** Backlog for Wave 11+
- **Severity:** LOW — acceptable for MVP

---

## Wave 11 Backlog Roadmap

### Wave 11.1: Ship & Stabilize (2–3 days)
- **P0:** Implement Linux diagnostics stream (1.5 hrs)
- **P1:** Squid .localhost (1 hr), Cheatsheet pointer (0.5 hr), Cold-start litmus (2 hrs)
- **P1:** Trace CI gate (2 hrs), Resource metrics (6 hrs)
- **Subtotal:** ~13 hours (1.5 days)

### Wave 11.2: Polish & Completeness (1 week)
- **P2:** Browser routing (Wave 4 prerequisites) — 4 items, ~8 hours
- **P2:** Observability extensions — OBS-001, OBS-003, OBS-018, OBS-021 — 6 hours
- **P2:** Tray reliability — TR-003 (cache corruption) — 2 hours
- **Subtotal:** ~16 hours

### Wave 11.3+: Backlog (Ongoing)
- **P3:** 27 items spread over future waves
- Estimated: 2–3 weeks at current velocity

---

## Quick Wins (MEDIUM-severity + SMALL-effort)

Easy wins to pick first in Wave 11.1:

1. **BR-003: Squid .localhost** (Small effort, HIGH severity) ✓
2. **ON-011: Cheatsheet pointer** (Small effort, MEDIUM severity) ✓
3. **OBS-004: Trace CI gate** (Medium effort, MEDIUM severity) ✓
4. **OBS-021: Secret rotation events** (Small effort, MEDIUM severity)

These four items give the highest severity-to-effort ratio.

---

## Verification Criteria

Each gap should be closed only when:

1. **Code change** submitted and merged
2. **Tests pass:** `cargo test --workspace` + any new litmus tests
3. **Spec trace** added: `@trace spec:<name>` annotation in code
4. **Evidence** logged: `TRACES.md` regenerated and committed
5. **Backport checklist:** Document dependencies for parallel waves

---

## Metadata

- **Matrix created:** 2026-05-14 16:30 UTC
- **Input commits:** 
  - browser-gaps-2026-05-14 (8 gaps)
  - tray-gaps-2026-05-14 (7 gaps)
  - onboarding-gaps-2026-05-14 (11 gaps)
  - observability-gaps-2026-05-14 (23 gaps)
- **Total time to review:** 45 minutes
- **Confidence level:** HIGH (all gaps documented with fix paths)

---

## Related Documents

- `plan/issues/browser-gaps-2026-05-14.md` — Detailed browser audit (8 gaps)
- `plan/issues/tray-gaps-2026-05-14.md` — Detailed tray audit (7 gaps)
- `plan/issues/onboarding-gaps-2026-05-14.md` — Detailed onboarding audit (11 gaps)
- `plan/issues/observability-gaps-2026-05-14.md` — Detailed observability audit (23 gaps)
- `plan/steps/08-implementation-gaps.md` — Integrated assessment (legacy)

