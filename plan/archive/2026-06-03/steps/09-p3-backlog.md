# Step 09 — P3 Backlog Implementation (Waves 17+)

**Status**: In Progress (Wave 17 Completed, Wave 18 Ready)
**Order**: 9
**Depends On**: implementation-gaps-backlog (order 8)
**Scope**: P3 (27 gaps across 5 clusters) — optional enhancements, future optimizations, and edge cases

---

## Context

Waves 12-16 closed all P0-P2 gaps (release-critical and recommended work).
Waves 17+ target P3 gaps (backlog, opportunistic, optimization).

**Wave 17 Status**: ✅ COMPLETED
- Implemented i18n/localization (ON-001, ON-002, ON-003)
- Committed: `feat(onboarding): add i18n/localization support (French, Japanese, error templates, help system)`
- Evidence: 5 localized shell prompts, 5 help system scripts, 3 error message templates
- All tests passing (500+ total)

**Wave 18 Status**: ⚠️ VALIDATION GATE (NOT YET STARTED)
- Critical validation requirement identified in audit: Podman idiomatic layer code exists but never validated end-to-end
- This is a **blocking item before production release** (not a P3 backlog item)
- Recommend: Promote to Wave 18 (before Wave 17+ continues)

---

## P3 Cluster Breakdown (27 gaps total)

### Cluster 1: i18n Surface Completion (3 gaps)

**Scope**: Additional language support, RTL handling, locale-aware formatting

| Gap ID | Title | Effort | Description |
|--------|-------|--------|-------------|
| **ON-001** | Shell prompt localization | Done (Wave 17) | French, Japanese locale files with 82+ translated variables |
| **ON-002** | Help system localization | Done (Wave 17) | 5 help scripts (en/es/de/fr/ja) with locale-aware routing |
| **ON-003** | Error message localization | Done (Wave 17) | 5 error template functions with localized messages |

**Status**: ✅ COMPLETE (Wave 17)

---

### Cluster 2: Onboarding Edge Cases (6 gaps)

**Scope**: Cold-start improvements, multi-workspace handling, agent bootstrap, auth lifecycle

| Gap ID | Title | Effort | Priority | Description |
|--------|-------|--------|----------|-------------|
| **ON-005** | First-time forge image pull progress UX | Small | P3 | Show download progress % during initial model pull |
| **ON-006** | Multi-workspace directory detection | Small | P3 | Auto-detect sibling projects, offer quick-switch menu |
| **ON-007** | SSH key auto-discovery in forge | Small | P3 | Auto-populate SSH from `~/.ssh/` without manual bind-mount |
| **ON-008** | Agent onboarding profile auto-load | Medium | P3 | Load user's preferred agent profile (codex, opus, haiku) from config |
| **ON-009** | GitHub token refresh on expiry | Medium | P3 | Auto-refresh GitHub token via Secret Service when it expires |
| **ON-010** | Forge dependency resolver UX | Medium | P3 | Show which project deps are missing before launch |

**Status**: Not started (opportunistic)

---

### Cluster 3: Browser Optimization (1 gap)

**Scope**: Performance improvements, connection pooling

| Gap ID | Title | Effort | Priority | Description |
|--------|-------|--------|----------|-------------|
| **BR-005** | CDP connection pooling | Medium | P3 | Reuse CDP connections across multiple browser windows |

**Status**: Not started (opportunistic)

---

### Cluster 4: Tray Performance (3 gaps)

**Scope**: UI responsiveness, cache eviction, singleton detection

| Gap ID | Title | Effort | Priority | Description |
|--------|-------|--------|----------|-------------|
| **TR-005** | GTK event loop blocking prevention | Medium | P3 | Profile tray UI responsiveness under high container churn |
| **TR-006** | Cache eviction on low-disk detection | Small | P3 | Auto-clean old images/caches when disk usage > 85% |
| **TR-007** | Rapid project switch defensive test | Small | P3 | Stress test tray switching between projects in < 500ms |

**Status**: Not started (opportunistic)

---

### Cluster 5: Observability Extensions (10 gaps)

**Scope**: Log aggregation, trace enrichment, evidence hardening, surface completion

| Gap ID | Title | Effort | Priority | Description |
|--------|-------|--------|----------|-------------|
| **OBS-002** | Structured log query language | Medium | P3 | Add Loki-style query syntax to trace index CLI |
| **OBS-005** | Metrics retention policy | Small | P3 | Archive old metrics files, keep 30-day rolling window |
| **OBS-006** | Trace sampling by cost | Medium | P3 | Sample expensive traces (large serialization) for cost control |
| **OBS-007** | Cross-container span linkage | Medium | P3 | Link container logs to parent process traces via span IDs |
| **OBS-008** | Dashboard refresh auto-detection | Small | P3 | Trigger dashboard re-render when TRACES.md changes |
| **OBS-009** | Metrics export to Prometheus | Medium | P3 | Expose `/metrics` endpoint compatible with Prometheus scrape |
| **OBS-010** | Log field cardinality analysis | Small | P3 | Detect high-cardinality fields to prevent log explosion |
| **OBS-011** | Trace budget enforcement | Medium | P3 | Warn when trace generation exceeds user-configured cost threshold |
| **OBS-012** | Evidence bundle retention policy | Small | P3 | Auto-delete old convergence evidence bundles after N days |
| **OBS-013** | Log tail performance optimization | Small | P3 | Use mmap for large log file reads instead of buffered I/O |

**Status**: Not started (opportunistic)

---

### Cluster 6: Evidence Hardening & Surface Completion (4 gaps)

**Scope**: Post-release observability refinement

| Gap ID | Title | Effort | Priority | Description |
|--------|-------|--------|----------|-------------|
| **OBS-019** | Dashboard rendering performance | Small | P3 | Profile centicolon-dashboard JSON generation speed |
| **OBS-020** | Evidence bundle cryptographic signing | Medium | P3 | Sign bundles with project key for tamper-detection |
| **OBS-022** | Observability surface completeness | Medium | P3 | Validate that all subsystems emit traces (audit pass) |
| **OBS-023** | Coverage report improvements | Small | P3 | Add per-crate, per-subsystem coverage breakdown to CI output |

**Status**: Not started (opportunistic)

---

## Recommended Waves

### Wave 17 ✅ COMPLETE
- i18n surface completion (ON-001, ON-002, ON-003)
- Delivered: Localized shell, help, error messages

### Wave 18 ⚠️ **VALIDATION GATE (BLOCKING FOR RELEASE)**

**This is NOT a P3 backlog wave — it's a required validation step before production release.**

**Scope**: End-to-end validation of Podman idiomatic layer and browser isolation (identified in audit as critical gaps)

**Tests Needed**:
1. Podman enclave network naming: Create containers with `tillandsias-<project>-enclave` network, verify naming
2. Transient error retry: Kill network during container run, verify `is_transient()` classification and retry logic
3. Event-driven monitoring: Run `podman events` listener, verify events arrive within 100ms
4. Storage isolation: Mount project path RO, workspace RW, ephemeral tmpfs; verify isolation
5. Security flags validation: Run under `--userns=keep-id --cap-drop=ALL`, verify security context
6. Browser isolation E2E: forge→proxy→router→sidecar chain with real containers
7. Manual smoke test: `./build.sh --ci-full --install` + `tillandsias --init --debug` + `tillandsias --opencode-web ~/test-project`

**Effort**: 2-3 hours (5 integration tests + 1 E2E + manual smoke)
**Deliverable**: plan/steps/10-validation-gate.md
**Criteria**: All tests passing, no regressions, ready for release

---

### Future Waves 19+ — P3 Opportunistic Implementation

Pick 4-6 leaves per wave; no fixed schedule. Most are Small effort.

**Example Wave 19** (i18n edge cases + observability):
- ON-005: First-time forge image pull progress UX (Small)
- ON-006: Multi-workspace directory detection (Small)
- OBS-005: Metrics retention policy (Small)
- OBS-008: Dashboard refresh auto-detection (Small)

**Parallel approach**: 2 Haiku agents on independent leaves, checkpoint after each agent finishes.

---

## P3 Implementation Discipline

### Commitment
- No new specs unless required to close a gap
- Every gap is modelled as a concrete task (not abstract cleanup)
- Effort estimates are conservative (actual delivery often faster)
- Dependencies are explicit (run after pre-requisite waves)

### Testing
- Each gap must have at least one test (unit or integration)
- Litmus bindings required for gaps touching observable behavior
- Trace annotations required for all new code paths (`@trace spec:<name>` or `@trace gap:<id>`)

### Release Readiness
- **Before Wave 18 validation**: P0-P2 complete, P3 optional
- **After Wave 18 validation**: Release-eligible
- **After Wave 19+**: Polish improvements (may ship incrementally)

---

## Files Modified in This Step

- plan/index.yaml — new step 09 added, status: in_progress
- plan/steps/09-p3-backlog.md — this file (new)
- plan/steps/10-validation-gate.md — new (validation requirements)

---

## Sign-Off

**Iteration**: 11 (after Wave 17 completion)
**Date**: 2026-05-14
**Status**: Ready for Wave 18 validation planning

Next immediate action: Create plan/steps/10-validation-gate.md with detailed test specifications and success criteria.

