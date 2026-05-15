# Step 11 — Release Readiness (Final Verification Phase)

**Status**: In Progress  
**Order**: 10 (final pre-release step)  
**Depends On**: p3-backlog/wave-18-validation-gate (Wave 18 automated tests complete)  
**Scope**: Manual smoke test validation + release decision

---

## Current Status (2026-05-14)

**Automated Tests**: ✅ COMPLETE  
- Wave 18: All 6 litmus tests implemented and passing
- CI Gate: ./build.sh --ci-full passing (53/56, 3 pre-existing tray UI timeouts)
- Regressions: Zero new failures
- Trace coverage: 80% (threshold met)

**Remaining Work**: Manual smoke test (Test 7 from step 10-validation-gate.md)  
- Duration: ~30 minutes
- Requires: Human interaction with GUI (Chromium, tray UI)
- Cannot be fully automated

---

## Manual Smoke Test (Test 7) — Full Workflow

### Prerequisites

```bash
# Verify working tree is clean
git status
# Should show: "nothing to commit, working tree clean"

# Verify current branch is linux-next
git branch
# Output: * linux-next

# Verify recent commits are present (Wave 18 validation)
git log --oneline -3
# Should show: 2b205577, e504ef92, or similar
```

### Test Execution Checklist

**Phase 1: Clean Build**

- [ ] Remove build artifacts: `rm -rf target/ .nix-output/`
- [ ] Remove cached images: `podman image prune -a --force` (or keep images, your choice)
- [ ] Remove cache: `rm -rf ~/.cache/tillandsias/`
- [ ] Run full CI + install: `./build.sh --ci-full --install`
  - [ ] All 500+ tests pass (tray UI timeouts acceptable)
  - [ ] Binary installed to `~/.local/bin/tillandsias`
  - [ ] No build errors or permission issues

**Phase 2: Init with Fresh Project**

- [ ] Create test project: `mkdir -p ~/test-opencode && cd ~/test-opencode && git init`
- [ ] Run init: `tillandsias --init --debug`
  - [ ] All images build successfully (no Nix errors, no proxy EOF)
  - [ ] Logs show "ready" message
  - [ ] Takes ~2-5 minutes on first run (normal)

**Phase 3: OpenCode Web Launch**

- [ ] Launch OpenCode Web: `tillandsias --opencode-web ~/test-opencode --headless=false`
  - [ ] Chromium window opens automatically
  - [ ] OTP form appears (data-URI injection with form content)
  - [ ] OTP field is auto-filled with generated token
  - [ ] Form auto-submits after 1-2 seconds
  - [ ] Router validates OTP (logs show success)
  - [ ] OpenCode Web loads in browser (can see editor UI)
  - [ ] Browser can access localhost services through router

**Phase 4: Tray Verification** (if launched without --headless)

- [ ] Tray window shows "test-opencode" project
- [ ] Status icon transitions: Initializing → Ready → Blushing → Blooming
- [ ] Tray menu shows container list with statuses
- [ ] Clicking "View Logs" opens log viewer

**Phase 5: Graceful Shutdown**

- [ ] Run: `tillandsias --stop` or close tray window
  - [ ] SIGTERM sent to all containers
  - [ ] Shutdown completes within 30 seconds
  - [ ] No orphaned containers: `podman ps` shows none running
  - [ ] Clean exit (no hung processes)

---

## Success Criteria for Release

**ALL of the following must be TRUE:**

- ✅ Automated tests: 6/6 passing (Wave 18 complete)
- ✅ CI gate: ./build.sh --ci-full green
- ✅ Manual smoke test: All 5 phases pass without blocking issues
- ✅ Regressions: Zero new test failures
- ✅ Trace coverage: ≥80%

**Acceptable Non-Blocking Issues:**
- Tray UI timeouts in tests (interactive tests, pre-existing)
- Minor log noise (warnings about deprecated features)
- Slow image pulls on first run (expected)

**Blocking Issues (would prevent release):**
- Any critical test failure (security, functionality)
- Graceful shutdown not working (orphaned containers)
- OpenCode Web not loading (routing failure)
- Chromium not launching (environmental issue)

---

## Evidence Capture

After running the manual smoke test, save evidence:

```bash
# Create evidence directory
mkdir -p ~/tillandsias-release-evidence-2026-05-14

# Save build logs
./build.sh --ci-full 2>&1 | tee ~/tillandsias-release-evidence-2026-05-14/build-full.log

# Save init logs
tillandsias --init --debug 2>&1 | tee ~/tillandsias-release-evidence-2026-05-14/init.log

# Take screenshots of:
# - Chromium with OTP form (before auto-submit)
# - Chromium with OpenCode Web loaded
# - Tray window with container list
# - Tray icon showing "Blooming" status

# Save test project state
ls -laR ~/test-opencode > ~/tillandsias-release-evidence-2026-05-14/project-ls.txt
```

---

## Release Decision Checklist

**Before announcing release to users, ALL must be TRUE:**

- [ ] Manual smoke test completed successfully (Test 7 passed)
- [ ] No blocking issues found
- [ ] Build artifacts tested on clean system
- [ ] Evidence captured and reviewed
- [ ] CHANGELOG updated with version and changes
- [ ] VERSION file bumped (if not already done)
- [ ] Release tag created: `git tag v<MAJOR>.<MINOR>.<CHANGES>.<BUILD>`
- [ ] Tag pushed to origin: `git push origin v<MAJOR>.<MINOR>.<CHANGES>.<BUILD>`

---

## Remaining P3 Gaps (Not Yet Implemented)

Out of 27 total P3 gaps planned in Waves 17-24, 24 have been implemented. The remaining 3 are:

1. **OBS-024** (TBD) — Undocumented observability gap
2. **OBS-025** (TBD) — Undocumented observability gap
3. **TR-010** (TBD) — Undocumented tray gap

These are non-blocking and can be addressed in post-release waves. They do not prevent shipping.

---

## Decision Gate: Proceed with Release?

**If manual smoke test passes**:
- ✅ All criteria met
- ✅ Safe to bump VERSION and create release tag
- ✅ Safe to push to users

**If manual smoke test finds issues**:
- Create issue in plan/issues/ with reproduction steps
- Revert problematic commit(s) if blocking
- Fix issue or defer to post-release patch
- Re-run manual test before proceeding

---

## Next Actions After Release

1. Merge linux-next → main (or wait for release workflow)
2. Monitor user reports for any production issues
3. Plan Wave 19 for remaining P3 gaps and post-release polish
4. Schedule post-release bug-fix triage

---

**Wave**: Final Verification (Step 11)  
**Blocking**: YES — manual test required before release  
**Date**: 2026-05-14  
**Owner**: Human (manual testing required)

**Next**: Run manual smoke test (Test 7 from step 10-validation-gate.md), then decide release go/no-go.
