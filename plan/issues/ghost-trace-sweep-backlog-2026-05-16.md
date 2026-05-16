# Ghost Trace Sweep Backlog — 10 Traces with No Corresponding Spec

## Overview

The codebase contains 35+ `@trace spec:*` annotations in `crates/tillandsias-headless/src/main.rs` pointing to spec IDs that have no corresponding `openspec/specs/*/spec.md` file. These are "ghost traces" — implementation links to non-existent specs.

This document tracks 10 high-priority ghost traces that should be resolved as a future wave (deferred to Q3 2026).

---

## Ghost Traces Found in main.rs

### Tier 1: Known Missing (Direct Implementation References)

| Spec ID | Sites | Module | Priority | Estimated Effort |
|---|---|---|---|---|
| `spec:linux-native-portable-executable` | 9 | main.rs: 1, 210, 2671, 2677, 3378, 3389, 4014, 4048 | HIGH | Large (new spec, requires extensive documentation) |
| `spec:transparent-mode-detection` | 4 | main.rs: 210, 2671, 2677 | HIGH | Medium |
| `spec:containerfile-staleness` | 6 | main.rs: 477, 499, 665, 702, 1666, 1707 | MEDIUM | Medium |
| `spec:chromium-browser-isolation` | 1 | main.rs: 626 | MEDIUM | Medium (change dir exists: `openspec/changes/chromium-browser-isolation/`) |
| `spec:fix-router-loopback-port` | 2 | main.rs: 1104, 1139 | LOW | Small |

### Tier 2: Derived from Related Specs

| Spec ID | Sites | Reason Missing | Priority | Estimated Effort |
|---|---|---|---|---|
| `spec:opencode-web-dynamic-routes` | 2 | main.rs: 1271, 4278 | MEDIUM | Medium |
| `spec:tray-subprocess-management` | 1 | main.rs: 2677 | MEDIUM | Medium |
| `spec:signal-handling` | 3 | main.rs: 3389, 4014, 4048 | HIGH | Medium (graceful-shutdown spec should cross-reference this) |
| `spec:resource-metric-collection` | 3 | main.rs: 3389, 3410, 3993 | LOW | Large |
| `spec:observability-metrics` | 2 | main.rs: 3410, 3993 | LOW | Large |

---

## Critical Notes

### Why Defer This Wave?

1. **Not blocking release**: These traces refer to implemented code that is working. No regression risk immediately.
2. **Rust-only approach**: These specs would require refactoring to fit Tillandsias architecture (similar to the rustls/musl-static spec).
3. **Time constraint**: Doc-debt-payoff (this wave) focuses on **recent work** (3 sessions, 3 events, 3 specs, 1 litmus). Ghost-trace sweep is a separate initiative.
4. **Scope boundary**: The 10 traces represent ~20-30 hours of spec writing work. This wave is ~5-7 hours.

### Relationship to Current Work

- **rustls TLS choice**: Naturally belongs in `spec:linux-native-portable-executable` when that spec is created (currently untraced in code)
- **graceful-shutdown**: Should cross-reference `spec:signal-handling` when that spec exists
- **cache-recovery-mechanism**: May cross-reference `spec:containerfile-staleness` for file lifecycle consistency

### Recommended Approach

Create a dedicated **Ghost Trace Sweep Wave** (tentatively Q3 2026 or after release v0.1.27x) that:
1. Creates all 10 missing specs with WHEN/THEN scenarios
2. Binds each to at least one litmus test
3. Updates all @trace annotations in code to reference the new specs
4. Verifies no downstream dependencies are broken

---

## Ghost Trace Sweep Wave Structure (Future)

### Wave: ghost-trace-sweep (estimated Q3 2026)

| Agent Group | Count | Work |
|---|---|---|
| **GTG-A** | 2 parallel | Create specs: linux-native-portable-executable, transparent-mode-detection |
| **GTG-B** | 2 parallel | Create specs: containerfile-staleness, chromium-browser-isolation |
| **GTG-C** | 2 parallel | Create specs: fix-router-loopback-port, opencode-web-dynamic-routes |
| **GTG-D** | 2 parallel | Create specs: tray-subprocess-management, signal-handling |
| **GTG-E** | 2 parallel | Create specs: resource-metric-collection, observability-metrics |
| **GTG-F** | 1 serial | Create litmus tests for all 10 specs + update litmus-bindings |
| **GTG-G** | 1 serial | Verification + checkpoint |

**Estimated duration**: 10-14 hours wall-clock time, 10-20 hours agent time

---

## Tracking Status

- **Status**: `deferred`
- **Reason**: Not blocking release; orthogonal to current doc-debt-payoff wave
- **Date deferred**: 2026-05-16
- **Suggested resolution date**: Q3 2026 (after v0.1.27x release)
- **Escalation trigger**: If any ghost trace code is modified before specs exist, promote sweep to P1

---

## Reference: Ghost Trace Locations (for future sweep)

```bash
# Find all ghost traces
grep -n "@trace spec:" crates/tillandsias-headless/src/main.rs | wc -l
# Returns 38 traces

# Find traces with non-existent specs
for spec in $(grep -o 'spec:[a-z-]*' crates/tillandsias-headless/src/main.rs | sort | uniq); do
  id="${spec#spec:}"
  [[ ! -d "openspec/specs/$id" ]] && echo "$spec — MISSING"
done
```

---

## Not in Scope (This Wave or Future Ghost Trace Sweep)

- **Retired/obsolete traces**: Tombstoned code (e.g., browser-session) is already marked @tombstone; don't create specs for obsolete features
- **Changes-directory references**: If a spec is in `openspec/changes/*/`, don't create `openspec/specs/*/` until the change is promoted to active
- **Internal function traces**: Very narrow internal implementation details (e.g., single function) should live in comments, not specs

---

## Related Issues

- [documentation-debt-2026-05-16.md](./documentation-debt-2026-05-16.md) — Current wave: 3 events, 3 specs, 1 litmus
- [plan/steps/11a-doc-debt-payoff.md](../steps/11a-doc-debt-payoff.md) — Current wave execution plan
