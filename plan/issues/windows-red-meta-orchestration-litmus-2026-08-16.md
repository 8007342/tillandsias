# Four meta-orchestration instant litmus tests are red on windows (3 step-budget timeouts + 1 seam logic)

- date: 2026-08-16
- host: windows (Yolanda, Git Bash / MSYS)
- discovered_by: windows meta-orchestration cycle 4, clean-tree run of
  `scripts/run-litmus-test.sh meta-orchestration --phase pre-build --size instant`
  at 781bb6e07 (post 770-f6u4/770-ifeg; none of the four touches files those
  changed — all four reproduce identically at the merged base)

## Failures

1. `litmus:e2e-eligibility-probe-shape` — STEP 4/7 "the probe emits exactly
   one well-formed verdict line" TIMEOUT at 5s. The probe passes standalone
   (`scripts/e2e-preflight.sh eligibility` → `eligible` in ~2s); the 5s step
   budget does not survive MSYS process-spawn pricing under the harness.
2. `litmus:meta-orchestration-dirty-tree-safety` — STEP 5/5 "canonical skills
   invalidate the forge image cache key" TIMEOUT at 10s. Same class.
3. `litmus:meta-orchestration-opsx-sync-merge` — STEP 4/5 "opsx sync-merge
   flows through the real guard without refusing" TIMEOUT at 10s. Same class.
4. `litmus:credential-channel-check-shape` — STEP 8/9 "forge with a
   mirror-resolved origin passes through the fixture seam" FAILS with
   `rc=1 out=missing:no-credential-channel` (expected the seam to yield the
   forge-mirror ok verdict). Not a timeout: the 756-2jnj fixture seam
   (linux-authored, commit b7850fadc) does not produce the mirror-authorized
   path on windows. Steps 6-7 (fail-closed directions) pass, so the guard
   fails SAFE here — the red is fixture fidelity, not a credential hole.

## Class

1-3 are the same platform tax measured in
`plan/issues/optimization/mcp-health-fixture-windows-spawn-tax-2026-08-16.md`
(~100x spawn cost): per-step `timeout_ms` values sized on linux. The
770-f6u4 change hit the identical wall in this same suite and sized its step
budget for the slowest host (30s → 180s) — the same treatment likely greens
1-3. Item 4 needs its fixture seam reproduced on windows by the 756-2jnj
owner (the seam's env/`git config` plumbing probably assumes a path shape or
a `gh`-less environment that differs here).

## Why it matters

The windows host cannot use this instant suite as a local gate while 4/15 of
it is ambient red — red-that-is-expected trains readers to ignore red
(672-4nts lesson). `./build.sh --check` does not currently run this suite, so
trunk safety is unaffected; the loss is local diagnostic power.

## Smallest next action

Resize the three step budgets for the slowest host (as 770-f6u4 did in the
same file family), and hand item 4's seam repro to the 756-2jnj owner with
the step-8 output above.
