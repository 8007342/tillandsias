---
task_id: release/pre-release-checklist
date: 2026-05-14
status: pending
---

# Release Checklist — Pre-Release Approval Gate

**Document**: Final checklist before shipping Tillandsias v0.1.X.X to production  
**Date**: 2026-05-14  
**Branch**: linux-next

---

## Approval Criteria

### ✅ Automated Phase Complete

- [x] All 11 documented plan steps (0-10) complete
- [x] Wave 18 validation: 6/6 automated tests passing
- [x] Wave 25 polish: 5 gaps closed, 38 new tests
- [x] Total: 661 workspace tests passing
- [x] Zero regressions from earlier waves
- [x] CI gate: ./build.sh --ci-full green
- [x] Trace coverage: 80% (threshold met)

**Evidence**: Commits 11a25b21 (Wave 25 checkpoint), e1ebaf69 (Wave 24)

---

### 🟡 Manual Phase In Progress

**Status**: Awaiting human execution

#### Phase 1: Pre-Test Environment
- [ ] User reads `plan/steps/11-release-readiness.md` (manual test checklist)
- [ ] User has access to clean development machine (or VM)
- [ ] Sufficient disk space: 10GB+ free (for image builds)
- [ ] Sufficient RAM: 2GB+ (for container runtime)

#### Phase 2: Execute Smoke Test
- [ ] Run: `./scripts/smoke-test.sh`
  - This coordinates: build → init → opencode-web → verify → shutdown
  - Automatically captures evidence logs
  - Prompts for manual verification of GUI (browser, tray)

#### Phase 3: Manual Verification (5 manual checks)
- [ ] **Browser**: Chromium opens, OTP form visible, auto-submits, OpenCode Web loads
- [ ] **Router**: .localhost requests route through proxy → router → service
- [ ] **Tray**: Icon transitions Initializing → Ready → Blushing → Blooming
- [ ] **Network**: No timeout errors (latency < 500ms)
- [ ] **Shutdown**: Graceful termination, all containers cleaned, <30s

#### Phase 4: Evidence Review
- [ ] Build logs: No errors, 500+ tests passing
- [ ] Init logs: All images built (no Nix errors, no proxy EOF)
- [ ] OpenCode logs: No errors, router validates OTP
- [ ] Shutdown logs: Clean termination, all containers stopped

---

## Release Decision Matrix

### Go/No-Go Decision

**GO CONDITIONS** (all must be true):
- ✅ Automated tests: 6/6 Wave 18 passing
- ✅ CI gate: ./build.sh --ci-full green, no new failures
- ✅ Manual test: All 5 verification checks passed
- ✅ Evidence: Logs reviewed, no blocking issues
- ✅ Zero regressions across all waves

**NO-GO CONDITIONS** (any blocks release):
- ❌ Manual smoke test fails any of 5 checks
- ❌ Critical errors in logs (crash, hang, security issue)
- ❌ Graceful shutdown not working (orphaned containers)
- ❌ Network routing broken (OpenCode Web unreachable)
- ❌ Chromium launch fails
- ❌ New regressions since Wave 25

### Acceptable Non-Blocking Issues
- Tray UI interactive test timeouts (pre-existing, known)
- Minor log warnings (deprecated features, expected)
- Slow image pulls on first run (expected, documented)
- Network latency > 500ms on slow systems (environment-dependent)

---

## Post-Go Actions

If all checks pass, proceed with:

### 1. Version & Tagging
```bash
# Verify VERSION file is updated (should be X.Y.Z.W)
cat VERSION

# Create release tag
git tag -a v$(cat VERSION) -m "Release v$(cat VERSION) - Manual smoke test approved"

# Push tag to remote
git push origin v$(cat VERSION)
```

### 2. Release Announcement
- [ ] Create GitHub Release from tag
- [ ] Add release notes summarizing:
  - Waves 17-25 P3 gaps closed
  - Test coverage: 661 tests, 0 regressions
  - Wave 18 validation complete
  - Manual smoke test approved

### 3. Branch Integration
- [ ] Merge linux-next → main (or use release workflow)
- [ ] Verify main branch has the release commit

### 4. Distribution
- [ ] Binary available in release assets
- [ ] Installation instructions updated
- [ ] User documentation reflects new version

---

## Post-Release Monitoring

After release ships:

### 1. Early Feedback (Day 1-2)
- Monitor GitHub issues for crash reports
- Watch for environment-specific problems
- Be ready with hotfix commits if critical issues surface

### 2. Wave 26 Planning (Post-Release)
- [ ] Triage any production issues
- [ ] Plan hotfixes if needed
- [ ] Document any surprises discovered in real usage
- [ ] Schedule Wave 26 for remaining P2 gaps

---

## Remaining Known Issues

### Non-Blocking (can defer to post-release)
- 3 undocumented P3 gaps (identified and implemented in Wave 25)
- Trace coverage still at 80% (threshold met, but not 90%)
- Tray UI interactive tests timeout (known, gated feature)

### Pre-Release Resolved
- ✅ All P0 gaps (Linux diagnostics, routing, security)
- ✅ All P1 gaps (BR-003, OBS-021/22, trace coverage)
- ✅ Wave 18 validation tests
- ✅ Wave 25 post-release polish

---

## Sign-Off

**Release Candidate**: linux-next branch, commit 11a25b21+

**Approval Required From**: Human tester (manual smoke test execution)

**Timeline**:
- Smoke test execution: ~1.5 hours
- Evidence review: ~30 minutes
- Total: ~2 hours to approval

**Next Step**: Execute `./scripts/smoke-test.sh`, review evidence, make go/no-go decision.

---

## Evidence Retention

All evidence captured by smoke-test.sh is saved to:
```
~/tillandsias-release-evidence-$(date +%Y-%m-%d)/
├── 01-build-full.log      # ./build.sh --ci-full output
├── 02-init.log            # ./init --debug output
├── 03-opencode-launch.log # ./opencode-web output
└── 05-shutdown.log        # ./stop graceful shutdown output
```

Keep evidence for:
- Release notes reference
- Post-release issue investigation
- Future release comparison

---

**Status**: Ready for manual smoke test execution  
**Owner**: Human tester  
**Blocker**: None (all automated work complete)
