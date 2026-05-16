# Documentation Debt: Three Implementation Sessions (2026-05-15 to 2026-05-16)

## Summary

Three recent implementation sessions closed critical functionality but violated the Tillandsias core principle:
**SPEC is source of truth. Code implements what the spec declares.**

| Work Item | Status | Wave to Resolve |
|---|---|---|
| Litmus test sizing taxonomy (4-tier, --size filter, E2E composition) | IMPLEMENTED, **NOT DOCUMENTED** | Wave A (event 025) + Wave B (spec) + Wave C (litmus) |
| Rustls TLS strategy (reqwest native-tls → rustls-tls for musl-static) | IMPLEMENTED, **NOT DOCUMENTED** | Wave A (event 026) |
| Cache version fresh-start fix (unwrap_or semantics) | IMPLEMENTED, **NOT DOCUMENTED** | Wave A (event 027) + Wave B (spec) + Wave C (litmus) |

---

## Six Documentation Gaps Identified

### Gap 1: Missing Methodology Event 025 (Litmus Test Sizing Taxonomy)

**What's missing**: No event record for the 4-tier litmus taxonomy (instant, quick, long, e2e) + --size filter implementation

**Evidence of work completed**:
- `methodology/litmus.yaml` has `test_sizing` section with 4 tiers, phase→size defaults
- `scripts/run-litmus-test.sh` has `SIZE_FILTER` variable, `--size` flag, `size_matches_filter()` function
- `scripts/local-ci.sh` passes `--size quick` for pre-build, `--size e2e` for post-build/runtime
- `openspec/litmus-tests/litmus-binary-e2e-smoke.yaml` composed 4 independent binary tests into 1 e2e file
- All 79 litmus test YAML files have `size:` field

**Spec gap**: No methodology event documents the observed signals, expected model, violated/missing claims, closure criteria

**Resolution**: Create `methodology/event/025-litmus-test-sizing-taxonomy.yaml` (Wave A)

---

### Gap 2: Missing Methodology Event 026 (Rustls TLS Strategy)

**What's missing**: No event record for switching reqwest from native-tls to rustls-tls for musl-static

**Evidence of work completed**:
- `Cargo.toml`: reqwest features changed to `["json", "rustls-tls"]`, `default-features = false`
- `Cargo.lock`: regenerated; no openssl-sys or native-tls crate
- `CLAUDE.md`: TLS Strategy section added with rationale, CNCF audit, RFC 1721 reference

**Spec gap**: No event records architectural rationale, CNCF audit evidence, musl+Nix design decision rationale

**Resolution**: Create `methodology/event/026-rustls-musl-static-tls-strategy.yaml` (Wave A)

---

### Gap 3: Missing Methodology Event 027 (Cache Version Fresh-Start Fix)

**What's missing**: No event record for the `unwrap_or(false)` fix that treats absent cache_version as fresh-start

**Evidence of work completed**:
- `crates/tillandsias-headless/src/main.rs:549`: Changed `.unwrap_or(true)` to `.unwrap_or(false)`
- Commit `5e1c583c`: "Fix cache version check to allow fresh starts after system resets"

**Spec gap**: 
- No event documents the observed problem (podman system reset → "Cache version mismatch" error)
- No event records the behavioral contract change (absent file = OK, not an error)
- No litmus test verifies the fix (no regression detection)

**Resolution**: Create `methodology/event/027-cache-version-fresh-start-fix.yaml` (Wave A)

---

### Gap 4: Missing Spec — spec:headless-mode

**What's missing**: No `openspec/specs/headless-mode/spec.md`

**Evidence the spec should exist**:
- `openspec/litmus-bindings.yaml` lists `headless-mode` as `status: active`, `coverage_ratio: 100`
- `openspec/litmus-tests/litmus-binary-e2e-smoke.yaml` traces: `@trace spec:headless-mode`
- Binary has `--headless` flag and emits JSON events to stdout

**Spec gap**: No formal requirements for headless operation (no UI, JSON events, --status-check mode)

**Resolution**: Create `openspec/specs/headless-mode/spec.md` + `TRACES.md` (Wave B)

---

### Gap 5: Missing Spec — spec:graceful-shutdown

**What's missing**: No `openspec/specs/graceful-shutdown/spec.md`

**Evidence the spec should exist**:
- `openspec/litmus-bindings.yaml` lists `graceful-shutdown` as `status: active`, `coverage_ratio: 100`
- `openspec/litmus-tests/litmus-binary-e2e-smoke.yaml` traces: `@trace spec:graceful-shutdown`
- Binary handles SIGTERM/SIGINT; cleans up sockets, mounts, init logs before exit

**Spec gap**: No formal requirements for graceful shutdown (signal handling, cleanup, timeouts)

**Resolution**: Create `openspec/specs/graceful-shutdown/spec.md` + `TRACES.md` (Wave B)

---

### Gap 6: Missing Spec — spec:cache-recovery-mechanism

**What's missing**: No `openspec/specs/cache-recovery-mechanism/spec.md`

**Evidence the spec should exist**:
- `crates/tillandsias-headless/src/main.rs:1639`: `@trace spec:cache-recovery-mechanism`
- The fresh-start fix (unwrap_or(false)) is the implementation of this spec's invariant

**Spec gap**: No formal spec owns the behavioral contract: "absent cache_version file on fresh start is NOT an error"

**Critical issue**: Without this spec + litmus test, any agent can revert the fix (`unwrap_or(true)`) and no automated check would catch it

**Resolution**: Create `openspec/specs/cache-recovery-mechanism/spec.md` + `TRACES.md` (Wave B) + `litmus-cache-recovery-fresh-start.yaml` (Wave C)

---

### Gap 7: Incomplete Spec — spec:forge-staleness

**What's missing**: No requirement covering fresh-start semantics (absent cache_version)

**Why**: The unwrap_or fix changed how this spec interprets version checking

**Resolution**: Add fresh-start requirement section to `openspec/specs/forge-staleness/spec.md` (Wave C)

---

### Gap 8: Incomplete Spec — spec:forge-cache-dual

**What's missing**: No requirement documenting cache_version file lifecycle

**Why**: The file is written by `save_version()` (main.rs:1728) after init completes, but this lifecycle is not formally specified

**Resolution**: Add cache_version lifecycle requirement section to `openspec/specs/forge-cache-dual/spec.md` (Wave C)

---

## Closure Criteria

All gaps closed when:
- [ ] Events 025, 026, 027 exist with proper YAML structure and accurate content
- [ ] Specs headless-mode, graceful-shutdown, cache-recovery-mechanism exist with WHEN/THEN scenarios
- [ ] Litmus test litmus-cache-recovery-fresh-start passes (verifies unwrap_or(false) behavior)
- [ ] forge-staleness and forge-cache-dual updated with fresh-start cross-references
- [ ] openspec/litmus-bindings.yaml updated with all new bindings
- [ ] Pre-build litmus tests still pass (no regression)
- [ ] Build passes: `./build.sh --test`

---

## Wave Timeline

| Wave | Agent Count | Duration | Work Item |
|---|---|---|---|
| **A** | 3 parallel | 0.5-1h | Create events 025, 026, 027 + update event index |
| **B** | 3 parallel | 2-3h | Create specs headless-mode, graceful-shutdown, cache-recovery-mechanism |
| **C** | 2 parallel | 1-2h | Create litmus test + update 2 existing specs |
| **D** | 1 serial | 0.5-1h | Plan finalization + checkpoint + ghost-trace backlog |
| **Total** | — | 4-7h wall-clock | All gaps documented and bound to litmus validation |

---

## Notes

- **Not addressed in this wave**: 10 ghost traces in main.rs with no corresponding spec (deferred to Q3 2026)
- **Critical principle**: Specs are source of truth; code implements specs; litmus tests falsify specs
- **Success metric**: After Wave D, every implementation detail has a WHEN/THEN scenario in a spec, bound to a litmus test that would catch regression
