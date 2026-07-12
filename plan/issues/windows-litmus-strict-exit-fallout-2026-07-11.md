# Windows host: instant litmus suite fails 10 steps after the 2026-07-11 strict-exit repairs

- **Filed**: 2026-07-11 by `windows-bullo-claude-20260711T182324Z` (order 282 cycle)
- **Class**: exploration/ (triage), likely reduces to enhancement/ (host-eligibility gating)
- **Status**: open

## Observation

`scripts/run-litmus-test.sh --size instant --phase pre-build --compact` on the
Windows host at 18d78d99 (post linux-next merge) reports PASS 118 / FAIL 10 /
SKIP 123 (pass rate 92%). Previous windows-next cycles ran this suite green
(run 3 record, 2026-07-10). The failing step diagnostics cite the NEW
"strict-exit mode" from tonight's order-267 tail repairs to
`run-litmus-test.sh` ("no success_pattern/expected_behavior declared —
non-zero exit fails the step; strict-exit mode"), which converts previously
tolerated non-zero environmental exits into failures.

Failing tests (9 unique, 10 step failures):

| spec | test | windows-env suspicion |
|---|---|---|
| browser-isolation-tray-integration | litmus:podman-idiomatic-launch-routing | cargo source-audit exits 101 (headless unix-only tests don't compile on windows; see headless-integration-tests-not-macos-gated-2026-07-10.md — windows analog) |
| ci-release | litmus:guest-binary-embed-integrity | half-staged target-guest/ during order 282, fixed by staging both arches in the same cycle (VM-run verify: SUCCESS). Residual windows limitation: Git Bash `-x` doesn't recognize ELF exec bits, so the host-side run still fails on "not executable" — needs the same host-eligibility treatment |
| forge-staleness | litmus:image-build-convergence-shape | needs podman on host PATH (podman lives in the WSL VM on windows) |
| methodology-accountability | litmus:methodology-accountability-shape | step 4/4 trace-surface probe exits non-zero on windows bash |
| meta-orchestration | litmus:credential-channel-check-shape | shape probe env-dependent; the real guard passes on this host (`ok:gh-credentials-store`) |
| meta-orchestration | litmus:smoke-lock-fd-isolation-shape | NEW tonight; flock fd semantics are linux-specific |
| security-privacy-isolation | litmus:podman-path-availability | podman not on windows host PATH by design (VM-internal) |
| versioning | litmus:versioning-shape | unverified — needs per-step log |
| observability-convergence | litmus:observability-convergence-shape | unverified — needs per-step log |

## Working-tree mutation hazard (observed, HIGH)

During the same run, `litmus:image-build-convergence-shape`
(`scripts/test-image-build-convergence.sh`) left the REAL repo `VERSION`
mutated to `0.0.0-test-retag` (line 69 writes it; the `cleanup` EXIT trap
restores it — but a runner step-timeout kill terminates the process without
running bash EXIT traps, so the restore never fired). Every subsequent build
in that tree then embeds/verifies against the bogus version: the order 282
`build-guest-binaries.sh --verify` failed on exactly this before the cause
was found. A litmus that can fail must not mutate committed files in place —
it should copy the tree or the engine should support a
`TILLANDSIAS_VERSION_FILE` override. Same smallest-next-action owner.

## Why this matters (velocity)

The instant suite is the windows loop's pre-commit gate. At 10 permanent
fails the gate stops being falsifiable on windows — every cycle has to
eyeball whether a FAIL is "the known ten" or a real regression, exactly the
advisory-guard drift the reduction engine forbids.

## Recurrence 2026-07-12 (windows-bullo-fable5-20260712T1940Z)

Instant suite at 7eaa8319 (post v0.3.260712.1 merge): PASS 121 / FAIL 10 /
SKIP 123. The failing set is the SAME nine tests above **plus one new**:
`litmus:litmus-name-filter-fail-loud-shape` (spec-traceability) — the
order-300 litmus added 2026-07-12, failing the same windows-portability
class on this host. No product regressions among the fails; today's
destructive cold-provision e2e passed end-to-end on the same tree.

**VERSION-clobber hazard fired AGAIN** (2nd occurrence): after the two
suite runs, the repo `VERSION` was left at `0.0.0-test-retag`
(`litmus:image-build-convergence-shape` step-killed before its EXIT-trap
restore). Restored via `git checkout -- VERSION`. The hazard is now
recurrent, not theoretical — it silently corrupts any subsequent build in
the tree. Raising the priority of the copy-tree/`TILLANDSIAS_VERSION_FILE`
fix called out below.

## Smallest next action

Owner: any host with litmus DSL context (linux preferred — the strict-exit
change landed there). Add host-eligibility metadata (or `success_pattern`s)
to the affected shapes so windows hosts SKIP steps that require podman /
linux flock / unix-only compiles, mirroring `scripts/e2e-preflight.sh
eligibility` semantics; then windows re-runs the suite expecting FAIL only
on genuine drift. Verifiable constraint: instant suite exits 0 on a clean
windows host.
