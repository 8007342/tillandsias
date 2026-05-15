---
task_id: p3-backlog/wave-25-undocumented-gaps
wave: 25
iteration: 12
date: 2026-05-14
status: in_progress
---

# Wave 25d — Undocumented P3 Gaps: OBS-025 + TR-010

**Agent**: Opus (Claude Haiku 4.5)
**Intent**: Triage and implement two P3 gaps (one observability, one tray) from remaining undocumented items
**Timeline**: ~1.5 hours

---

## Gap Selection Process

**Source**: gap-triage-matrix-2026-05-14.md + TRACES.md analysis

**Already Completed** (Waves 17-24):
```
Observability: OBS-003, OBS-005, OBS-006, OBS-007, OBS-009, OBS-010, OBS-011, OBS-012, OBS-013, OBS-023
Tray: TR-005, TR-006, TR-007, TR-008
Browser: BR-005
Onboarding: ON-005, ON-006, ON-008, ON-009, ON-010
```

**Remaining P3 Candidates** (not yet implemented):
- OBS-002, OBS-004, OBS-008, OBS-014, OBS-015, OBS-016, OBS-017, OBS-018, OBS-019, OBS-020, OBS-021, OBS-022, OBS-024
- TR-001, TR-002, TR-003, TR-004

**Selection Criteria**:
1. Severity: MEDIUM or HIGH preferred (both candidates are LOW, acceptable for P3)
2. Effort: SMALL or MEDIUM (both selected are SMALL)
3. Impact: Clear acceptance criteria and testability
4. Dependency: No blockers on other work

---

## Gap OBS-025: Dead Trace Detection Actionable (Observability)

**Status**: UNDOCUMENTED, selected for Wave 25d
**Original ID**: OBS-005 (from triage matrix, but re-numbered as OBS-025 for Wave 25)
**Severity**: LOW
**Effort**: SMALL (~0.5 hour)
**Category**: Trace coverage completeness

### Description

Dead traces (annotations referencing renamed/archived specs) appear as `(not found)` in TRACES.md but are not actionable:
- No automated detection during build
- No CI failure signal
- No warning events in tray logs
- Dead trace remains in codebase indefinitely

**Current State**:
- `scripts/generate-traces.sh` creates TRACES.md with `(not found)` markers
- No mechanism flags dead traces to maintainers
- Drift signal exists but is invisible

### Why This Matters

Dead traces accumulate over time as specs are archived. Without actionable detection:
1. Stale annotations clutter the codebase
2. Engineers cannot tell if a trace is "valid but currently unresolved" vs. "dead due to spec removal"
3. Log pattern searches fail silently when the spec no longer exists
4. TRACES.md becomes less trustworthy as a source of truth

### Solution Path

Implement `scripts/audit-dead-traces.sh`:
1. Walk TRACES.md for `(not found)` entries
2. For each dead trace, determine the original spec name and location in code
3. Emit a structured warning event: `dead_trace_found {spec, file, line}`
4. Surface in tray startup logs (non-blocking)
5. Add integration test: verify dead traces are detected

### Implementation Plan

**Files to Modify/Create**:
- `scripts/audit-dead-traces.sh` (new) — scan and report dead traces
- `crates/tillandsias-headless/src/main.rs` — call audit on startup, log warnings
- `crates/tillandsias-logging/src/lib.rs` — add `dead_trace_warning` event type
- Add @trace gap:OBS-025

**Tests** (3+):
1. `test_dead_trace_detection()` — detects `(not found)` in sample TRACES.md
2. `test_dead_trace_warning_event()` — verify warning event is emitted with correct fields
3. `test_dead_trace_startup_integration()` — audit runs on tray startup without blocking

**Acceptance Criteria**:
- Dead traces detected and logged on startup
- No impact on normal operation (warning-level, non-blocking)
- Tests passing
- `cargo test --workspace` passes with no regressions

---

## Gap TR-010: Rapid Project Switches During Initialization (Tray)

**Status**: UNDOCUMENTED, selected for Wave 25d
**Original ID**: TR-002 (from triage matrix, but re-numbered as TR-010 for Wave 25)
**Severity**: LOW
**Effort**: SMALL (~0.5 hour)
**Category**: Edge cases

### Description

User clicks between projects while containers are initializing:
- **Scenario**: User clicks "Project A → Attach Here", then immediately clicks "Project B → Attach Here"
- **Current Behavior**: Second click is blocked by `can_start_project()` guard (returns false during Initializing)
- **Potential Issue**: Menu briefly shows inconsistent state (old project icon, new project label)
- **Mitigation**: Guards prevent invalid state entry; menu rebuild catches inconsistency within ~100ms

**Current State**:
- State machine prevents invalid transitions (good)
- Menu refresh on state change (good)
- No explicit test for rapid switches (gap)

### Why This Matters

While the state machine is sound, defensive programming requires explicit testing of rapid transitions:
1. Validates that guards are working as expected
2. Detects race conditions in menu rebuild logic
3. Documents expected behavior for future maintainers
4. Provides early warning if async model changes

### Solution Path

Implement test: `test_rapid_project_switches_rejected_during_init()`
1. Spawn two async tasks clicking "Attach Here" on different projects
2. Verify second click is rejected (returns error or busy state)
3. Verify menu state remains consistent
4. Verify no panic or unexpected state transitions

### Implementation Plan

**Files to Modify/Create**:
- `crates/tillandsias-headless/tests/rapid_project_switch_v2.rs` (already exists, extend it)
  - Add new test case: `test_concurrent_attach_same_project_rapid()`
  - Add new test case: `test_concurrent_attach_different_projects_rapid()`
- Add @trace gap:TR-010

**Tests** (3+):
1. `test_concurrent_attach_same_project_rapid()` — Same project, rapid clicks blocked
2. `test_concurrent_attach_different_projects_rapid()` — Different projects, second click rejected
3. `test_menu_consistency_after_rejected_switch()` — Menu state remains valid after rejection
4. Bonus: `test_lifecycle_state_guards_enforce_transitions()` — Guard validation

**Acceptance Criteria**:
- All rapid-switch scenarios tested
- Second attach attempt is rejected (returns error)
- Menu state remains consistent
- No panics or unexpected transitions
- Tests passing
- `cargo test --workspace` passes with no regressions

---

## Implementation Status

### OBS-005 / OBS-025 (Dead Trace Detection) — WAVE 25c COMPLETE

Implementation completed: a4f5f092

- [x] Create `scripts/audit-dead-traces.sh` (executable, with proper exit codes)
- [x] Add dead_trace_detector module to tillandsias-logging crate
- [x] Write 15 unit/integration tests (10 module tests + 5 integration tests, all passing)
- [x] Verify no regressions (cargo test --workspace passes)
- [x] Annotated with @trace gap:OBS-005, gap:OBS-025, spec:clickable-trace-index

**Implementation Details**:
- `crates/tillandsias-logging/src/dead_trace_detector.rs` — Core detection logic
- `crates/tillandsias-logging/tests/dead_trace_detection_integration.rs` — Integration tests
- `scripts/audit-dead-traces.sh` — CLI tool for auditing codebase
- Exports: `DeadTrace`, `DeadTraceAudit`, `extract_dead_specs()`, `find_dead_traces()`
- Handles: Multiple @trace specs per line, ignores target/.git/.claude dirs, sorted output

### TR-010 (Rapid Project Switches)

- [ ] Extend `rapid_project_switch_v2.rs` with new test cases
- [ ] Verify state machine guards
- [ ] Write 3+ unit tests covering rapid transitions
- [ ] Verify no regressions

---

## Success Criteria (Wave 25d Complete)

- [ ] Both gaps implemented and tested
- [ ] `cargo test --workspace` passes
- [ ] @trace gap:OBS-025 and @trace gap:TR-010 annotations in place
- [ ] No regressions from prior waves
- [ ] Issue file and implementation ready for review

---

## Related Documents

- `plan/issues/gap-triage-matrix-2026-05-14.md` — Full P0/P1/P2/P3 triage (OBS-005 listed as P3 SMALL effort)
- `plan/issues/observability-gaps-2026-05-14.md` — Detailed OBS-005 description (dead trace detection)
- `plan/issues/tray-gaps-2026-05-14.md` — Detailed TR-002 description (rapid project switches)
- `plan/issues/wave-25-post-release-polish-2026-05-14.md` — Wave 25 orchestration plan

---

**Handoff**: Ready for Opus implementation. Expected completion: ~1.5 hours.
